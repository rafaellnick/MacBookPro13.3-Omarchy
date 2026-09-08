#!/bin/bash
# Re-init the Touch Bar display after a resume.
#
# The strip goes dark across s2idle and nothing brings it back on its own.
# touchbar-enable-dynamic.sh is NOT enough here: every one of its steps is
# guarded on state that survives the suspend - the modules are still loaded,
# the HID interfaces are still bound to apple-ibridge-hid, and fnmode is still
# readable - so it short-circuits to the end and reports SUCCESS having done
# nothing. Only reloading apple_ib_tb re-runs appletb_probe and repaints it.
set -uo pipefail

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

KO=/run/touchbar/apple-ib-tb.ko
STAMP=/run/touchbar/last-resume-reload
DEBOUNCE=10

# Two things trigger this now: the unit's WantedBy=suspend.target, and the
# systemd-sleep hook that backstops it (see
# /usr/lib/systemd/system-sleep/touchbar-resume). On a normal resume both fire
# within a second or so of each other, and reloading twice makes the strip
# flash and races rmmod against the previous insmod. Whichever gets here first
# wins; the other no-ops.
if [ -f "$STAMP" ]; then
	now=$(date +%s)
	last=$(cat "$STAMP" 2>/dev/null || echo 0)
	if [ $((now - last)) -lt "$DEBOUNCE" ]; then
		log "reloaded $((now - last))s ago - skipping (debounce ${DEBOUNCE}s)"
		exit 0
	fi
fi

# /run is a tmpfs, so the unpacked module is only there if touchbar.service has
# run this boot. If it has not, let it do the full cold bring-up instead.
if [ ! -f "$KO" ]; then
	log "no unpacked module at $KO - deferring to touchbar.service"
	exec systemctl restart touchbar.service
fi

# The iBridge sits on the internal xHCI controller, which comes back before
# the TB ones, but give it a moment to re-enumerate anyway.
for _ in {1..10}; do
	compgen -G "/sys/bus/hid/devices/*05AC*8600*" >/dev/null && break
	sleep 1
done
compgen -G "/sys/bus/hid/devices/*05AC*8600*" >/dev/null || { log "no iBridge HID device after resume - nothing to do"; exit 0; }

timeout 30 rmmod apple_ib_tb 2>/dev/null || log "rmmod apple_ib_tb failed (continuing)"
sleep 1
if timeout 45 insmod "$KO" fnmode=1 idle_timeout=300 dim_timeout=-2; then
	mkdir -p "$(dirname "$STAMP")" && date +%s > "$STAMP"
	log "apple_ib_tb reloaded"
else
	log "insmod failed; falling back to full bring-up"
	exec systemctl restart touchbar.service
fi
