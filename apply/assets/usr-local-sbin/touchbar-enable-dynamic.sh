#!/bin/bash
# Bring up the Apple T1 Touch Bar (iBridge). Run late, from a systemd oneshot.
#
# This is a local replacement for /usr/local/sbin/touchbar-enable.sh from
# mbp133-hardware-support 2.0.0. That version hard-codes the HID device ids
# 0003:05AC:8600.0001 (coordinator) and .0002 (the interface to reclaim).
#
# Those suffixes are NOT stable. The trailing field is the kernel's global HID
# device counter, so it depends on how many HID devices registered before the
# iBridge did. On this machine the two iBridge interfaces come up as .0007 and
# .0008, so the upstream script's fixed .0002 never matches and its unit's
# ConditionPathExistsGlob=...0001 skips the service outright at every boot.
#
# Everything else - the late start, insmod-over-a-blacklist, keyboard mode to
# dodge the apple_ib_set_tb_mode() self-deadlock - is kept from upstream, with
# the reasoning preserved in the comments below.
set -uo pipefail

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

KDIR="/lib/modules/$(uname -r)/updates/dkms"
WORK=/run/touchbar
HIDDRV=/sys/bus/hid/drivers

# The USB-backed iBridge HID interfaces, in enumeration order. Virtual HID
# devices that apple_ibridge itself creates carry the same VID:PID, so filter
# on HID_PHYS=usb-: rebinding a virtual device would be meaningless at best.
ib_usb_devs() {
	local d
	for d in /sys/bus/hid/devices/*05AC*8600*; do
		[ -e "$d/uevent" ] || continue
		grep -q '^HID_PHYS=usb-' "$d/uevent" 2>/dev/null && basename "$d"
	done
}

drv_of() {
	basename "$(readlink -f "/sys/bus/hid/devices/$1/driver" 2>/dev/null)" 2>/dev/null || echo none
}

# /sys/bus/hid/devices/<id> is a SYMLINK into /sys/devices/..., and `find` does
# not follow symlinks, so searching the bus directory for fnmode finds nothing
# even when the attribute exists. Resolve each link and test the target.
tb_attr_dir() {
	local d real
	for d in /sys/bus/hid/devices/*05AC*8600*; do
		real=$(readlink -f "$d" 2>/dev/null) || continue
		[ -n "$real" ] && [ -e "$real/fnmode" ] && { printf '%s' "$real"; return 0; }
	done
	return 1
}

# ── 0. is the T1 even alive? ─────────────────────────────────────────────────
found=""
for d in /sys/bus/usb/devices/*/; do
	[ "$(cat "$d/idVendor" 2>/dev/null)" = "05ac" ] || continue
	p=$(cat "$d/idProduct" 2>/dev/null)
	[ "$p" = "8600" ] && found=ok
	[ "$p" = "1281" ] && { log "T1 is in RECOVERY MODE (05ac:1281) - ESP firmware missing. Nothing to do."; exit 0; }
done
[ -n "$found" ] || { log "no iBridge (05ac:8600) present - nothing to do"; exit 0; }
log "iBridge present; USB HID interfaces: $(ib_usb_devs | tr '\n' ' ')"

# ── 1. unpack the DKMS modules (rebuilt on every kernel update) ──────────────
mkdir -p "$WORK"
for m in apple-ibridge apple-ib-tb apple-ib-als; do
	if [ -f "$KDIR/$m.ko.zst" ]; then
		zstd -qdf "$KDIR/$m.ko.zst" -o "$WORK/$m.ko" || { log "failed to unpack $m"; exit 1; }
	elif [ -f "$KDIR/$m.ko" ]; then
		cp -f "$KDIR/$m.ko" "$WORK/$m.ko"
	else
		log "module $m not found in $KDIR - is the DKMS build present?"; exit 1
	fi
done
log "modules unpacked"

# ── 2. coordinator first, in keyboard mode ──────────────────────────────────
# tb_mode_param=keyboard picks the USB configuration the device already boots
# in, so apple_ib_set_tb_mode() takes its early return and never calls
# usb_set_configuration(). That call re-binds interface drivers in the same
# task and re-enters the function, which self-deadlocks on appleib_tbmode_lock.
#
# insmod, not modprobe: the kernel cmdline blacklists these modules so nothing
# can pull them in early by accident. insmod ignores the blacklist, keeping
# that guard intact while still loading them deliberately here.
if ! grep -q '^apple_ibridge ' /proc/modules; then
	timeout 45 insmod "$WORK/apple-ibridge.ko" tb_mode_param=keyboard || { log "apple_ibridge failed to load"; exit 1; }
	log "apple_ibridge loaded (keyboard mode)"
	sleep 1
fi

# fnmode/idle/dim are settable at load time even though their sysfs entries
# are 0444.
#
# fnmode=1 shows the media/brightness strip and switches to F1-F12 while Fn is
# held, which is what the hardware does under macOS. idle_timeout=300 blanks
# the strip after five idle minutes and dim_timeout=-2 derives the dim point
# from it - upstream pinned both to -1 (never blank) while chasing the load
# deadlock, but that leaves an OLED lit around the clock for no reason.
if ! grep -q '^apple_ib_tb ' /proc/modules; then
	timeout 45 insmod "$WORK/apple-ib-tb.ko" fnmode=1 idle_timeout=300 dim_timeout=-2 || { log "apple_ib_tb failed to load"; exit 1; }
	log "apple_ib_tb loaded"
fi

# apple_ib_als pulls iio_triggered_buffer_setup_ext/cleanup from
# industrialio-triggered-buffer. Nothing else on this machine loads that
# module, and insmod - unlike modprobe - will not resolve the dependency
# itself, so the ambient light sensor fails with "Unknown symbol" without this.
if ! grep -q '^apple_ib_als ' /proc/modules; then
	modprobe -q industrialio-triggered-buffer || log "could not load industrialio-triggered-buffer"
	timeout 45 insmod "$WORK/apple-ib-als.ko" || log "apple_ib_als failed to load (ambient light sensor only; continuing)"
fi

# ── 3. take every iBridge interface back from the generic HID drivers ───────
# At boot hid-generic and hid-sensor-hub claim these. apple_ibridge reclaims
# only the first one, so the interface carrying the Touch Bar reports stays
# with hid-sensor-hub and appletb_probe never finds a device: no sysfs group,
# no input device, a dark strip, and no error logged anywhere.
for dev in $(ib_usb_devs); do
	cur=$(drv_of "$dev")
	log "interface $dev owned by: $cur"
	[ "$cur" = "apple-ibridge-hid" ] && continue
	if [ -e "$HIDDRV/$cur/unbind" ]; then
		printf '%s' "$dev" > "$HIDDRV/$cur/unbind" 2>/dev/null && log "  unbound from $cur"
		sleep 1
	fi
	if [ -e "$HIDDRV/apple-ibridge-hid/bind" ]; then
		printf '%s' "$dev" > "$HIDDRV/apple-ibridge-hid/bind" 2>/dev/null && log "  bound to apple-ibridge-hid"
		sleep 2
	fi
	log "  now owned by: $(drv_of "$dev")"
done

# ── 4. re-probe apple_ib_tb now that the device exists ──────────────────────
# Its probe already ran and found nothing, so it needs a reload to try again.
if ! tb_attr_dir >/dev/null; then
	log "no writable controls yet - reloading apple_ib_tb to re-probe"
	timeout 30 rmmod apple_ib_tb 2>/dev/null || log "rmmod apple_ib_tb failed (continuing)"
	sleep 1
	timeout 45 insmod "$WORK/apple-ib-tb.ko" fnmode=1 idle_timeout=300 dim_timeout=-2 || log "reload failed"
	sleep 2
fi

# ── 5. settings, and report ─────────────────────────────────────────────────
if d=$(tb_attr_dir); then
	printf '%s' '1'   > "$d/fnmode"       2>/dev/null || true
	printf '%s' '300' > "$d/idle_timeout" 2>/dev/null || true
	printf '%s' '-2'  > "$d/dim_timeout"  2>/dev/null || true
	log "SUCCESS: fnmode=$(cat "$d/fnmode") idle=$(cat "$d/idle_timeout") dim=$(cat "$d/dim_timeout")"
	log "  controls at: $d"
else
	log "FAILED: appletb_probe still did not complete; the strip will be dark"
fi

for d in /sys/bus/hid/devices/*05AC*8600*; do
	log "  $(basename "$d") -> $(drv_of "$(basename "$d")")"
done
awk '/^N: Name=.*[Tt]ouch ?[Bb]ar/{n=$0} /^H: Handlers=/{if (n) {print "  " n " " $0; n=""}}' /proc/bus/input/devices |
	while read -r l; do log "$l"; done
