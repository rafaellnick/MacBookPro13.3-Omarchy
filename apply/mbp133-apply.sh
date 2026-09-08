#!/bin/bash
#
# mbp133-apply.sh — apply every adaptation this MacBookPro13,3 needs on Omarchy.
#
# Companion to the documentation in ../. Every change made here is explained in
# a numbered module; the phase names below match them.
#
#   ./mbp133-apply.sh --list                 what it would do
#   sudo ./mbp133-apply.sh --check           dry run, changes nothing
#   sudo ./mbp133-apply.sh                   apply everything (except bootloader)
#   sudo ./mbp133-apply.sh --phase touchbar  apply one phase
#   sudo ./mbp133-apply.sh --allow-bootloader --phase bootloader
#
# Idempotent: re-running is safe and reports SKIP for anything already correct.
#
# It does NOT reproduce the external-display link work — that was deliberately
# reverted (see ../04-display-and-gpu.md).

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ASSETS="$HERE/assets"

CHECK=0
ALLOW_BOOTLOADER=0
PHASES=()
ALL_PHASES=(packages audio-dkms touchbar wifi sleep power shell maintenance)

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; DIM=$'\e[2m'; RST=$'\e[0m'
applied=0; skipped=0; failed=0; warned=0

say()   { printf '%s\n' "$*"; }
head_() { printf '\n%s==> %s%s\n' "$BLU" "$*" "$RST"; }
ok()    { printf '  %sAPPLY%s  %s\n' "$GRN" "$RST" "$*"; applied=$((applied+1)); }
skip()  { printf '  %sSKIP %s  %s\n' "$DIM" "$RST" "$*"; skipped=$((skipped+1)); }
warn()  { printf '  %sWARN %s  %s\n' "$YLW" "$RST" "$*"; warned=$((warned+1)); }
fail()  { printf '  %sFAIL %s  %s\n' "$RED" "$RST" "$*"; failed=$((failed+1)); }
would() { printf '  %sWOULD%s  %s\n' "$YLW" "$RST" "$*"; applied=$((applied+1)); }

usage() {
	sed -n '3,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,\} \{0,1\}//; /^$/d'
	printf '\nPhases: %s bootloader\n' "${ALL_PHASES[*]}"
	exit 0
}

while (($#)); do
	case "$1" in
	--check) CHECK=1; shift ;;
	--allow-bootloader) ALLOW_BOOTLOADER=1; shift ;;
	--phase) PHASES+=("$2"); shift 2 ;;
	--list|-h|--help) usage ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done
((${#PHASES[@]})) || PHASES=("${ALL_PHASES[@]}")

wants() { local p; for p in "${PHASES[@]}"; do [[ $p == "$1" ]] && return 0; done; return 1; }

# ---------------------------------------------------------------- preflight --

if [[ $EUID -ne 0 ]]; then
	echo "This needs root (it writes to /usr/local, /etc and /usr/lib/systemd)." >&2
	echo "Re-run with sudo. User-level files are written as \$SUDO_USER." >&2
	exit 1
fi

TARGET_USER=${SUDO_USER:-$(logname 2>/dev/null || echo root)}
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[[ -d $TARGET_HOME ]] || { echo "cannot resolve home for '$TARGET_USER'" >&2; exit 1; }

head_ "Preflight"
MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
if [[ $MODEL != MacBookPro13,3 ]]; then
	fail "This machine reports '$MODEL', not MacBookPro13,3. Refusing."
	echo
	echo "Much of this is model-specific (fan ranges, GPU mux, iBridge, codec IDs)."
	exit 1
fi
say "  model        : $MODEL"
say "  kernel       : $(uname -r)"
say "  target user  : $TARGET_USER ($TARGET_HOME)"
say "  assets       : $ASSETS"
((CHECK)) && say "  mode         : ${YLW}CHECK — nothing will be written${RST}"
[[ -d $ASSETS ]] || { fail "assets directory missing"; exit 1; }

# ------------------------------------------------------------------ helpers --

# install_file <src> <dst> <mode> [owner]
install_file() {
	local src=$1 dst=$2 mode=$3 owner=${4:-root:root}
	if [[ ! -e $src ]]; then fail "asset missing: $src"; return 1; fi
	if [[ -e $dst ]] && cmp -s "$src" "$dst"; then
		local cur; cur=$(stat -c '%a' "$dst")
		if [[ $cur == "$mode" ]]; then skip "$dst"; return 0; fi
	fi
	if ((CHECK)); then would "$dst"; return 0; fi
	install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$dst" \
		&& ok "$dst" || { fail "$dst"; return 1; }
}

enable_unit() {
	local unit=$1
	if [[ $(systemctl is-enabled "$unit" 2>/dev/null) == enabled ]]; then skip "enabled: $unit"; return 0; fi
	if ((CHECK)); then would "enable $unit"; return 0; fi
	systemctl enable "$unit" >/dev/null 2>&1 && ok "enabled: $unit" || fail "enable $unit"
}

need_pkg() {
	local p=$1
	if pacman -Q "$p" >/dev/null 2>&1; then skip "package: $p"; return 0; fi
	if ((CHECK)); then would "install package: $p"; return 0; fi
	pacman -S --noconfirm --needed "$p" >/dev/null 2>&1 && ok "package: $p" || fail "package: $p"
}

as_user() { sudo -u "$TARGET_USER" "$@"; }

# systemd --user cannot be driven without the target user's bus, which may not
# exist when this runs. `systemctl --user enable` only creates a .wants symlink,
# so create it directly - systemd picks it up at the next daemon-reload.
enable_user_unit() {
	local unit=$1 target=$2
	local link="$TARGET_HOME/.config/systemd/user/$target.wants/$unit"
	if [[ -L $link ]]; then skip "enabled (user): $unit"; return 0; fi
	if ((CHECK)); then would "enable (user) $unit"; return 0; fi
	install -d -o "$TARGET_USER" -g "$TARGET_USER" "$(dirname "$link")" \
		&& as_user ln -sf "../$unit" "$link" \
		&& ok "enabled (user): $unit" || fail "enable (user) $unit"
}

# ------------------------------------------------------------------ packages --

if wants packages; then
	head_ "Packages (01, 02)"
	# linux-headers MUST match the running kernel exactly. Do NOT pacman -Sy here:
	# a partial upgrade is how you end up with headers for a kernel you are not
	# running, and DKMS silently building against the wrong tree.
	if pacman -Q linux-headers >/dev/null 2>&1; then
		hv=$(pacman -Q linux-headers | awk '{print $2}')
		kv=$(uname -r | sed 's/-arch/.arch/')
		[[ $hv == "$kv" ]] && skip "linux-headers matches running kernel ($hv)" \
			|| warn "linux-headers $hv vs running kernel $kv — DKMS may build against the wrong tree"
	else
		need_pkg linux-headers
	fi
	need_pkg wget           # required by the audio DKMS pre-build step (02)
	need_pkg dkms
	need_pkg brightnessctl  # battery-low dim hook (06)
	need_pkg jq             # used by omarchy tooling this relies on
	need_pkg tlp            # power management (06); must not coexist with power-profiles-daemon
fi

# ---------------------------------------------------------------- audio DKMS --

if wants audio-dkms; then
	head_ "Audio — patched CS8409/CS42L83 codec (02)"
	if dkms status 2>/dev/null | grep -q "^snd_hda_macbookpro/.*, $(uname -r), .*: installed"; then
		skip "snd_hda_macbookpro built for $(uname -r)"
	elif ((CHECK)); then
		would "clone + install snd_hda_macbookpro DKMS (downloads ~150MB kernel source)"
	else
		warn "installing snd_hda_macbookpro — this downloads ~150MB and takes minutes"
		SRC=/usr/src/snd_hda_macbookpro-0.1
		# Clone IN PLACE. A previous install pointed the DKMS source symlink into
		# /tmp, which the reboot wiped, leaving dkms 'broken' and sound due to die
		# at the next kernel update. See ../02-audio.md §2.2.
		if [[ ! -d $SRC ]]; then
			git clone --depth 1 https://github.com/davidjo/snd_hda_macbookpro "$SRC" >/dev/null 2>&1 \
				|| fail "clone snd_hda_macbookpro"
		fi
		if [[ -d $SRC ]]; then
			( cd "$SRC" && ./install.cirrus.driver.sh -i ) >/dev/null 2>&1 \
				&& ok "snd_hda_macbookpro installed" \
				|| fail "snd_hda_macbookpro build — check /var/lib/dkms/snd_hda_macbookpro/0.1/build/make.log"
		fi
	fi
	if aplay -l 2>/dev/null | grep -qi CS8409; then
		skip "codec bound (CS8409/CS42L83 present)"
	else
		warn "codec NOT bound — no sound until this is resolved"
	fi
fi

# ----------------------------------------------------------------- touch bar --

if wants touchbar; then
	head_ "Touch Bar (01)"
	install_file "$ASSETS/usr-local-sbin/touchbar-enable-dynamic.sh" /usr/local/sbin/touchbar-enable-dynamic.sh 755
	install_file "$ASSETS/usr-local-sbin/touchbar-resume.sh"         /usr/local/sbin/touchbar-resume.sh 755
	install_file "$ASSETS/systemd-system/touchbar.service.d/override.conf" /etc/systemd/system/touchbar.service.d/override.conf 644
	install_file "$ASSETS/systemd-system/touchbar-resume.service"    /etc/systemd/system/touchbar-resume.service 644
	install_file "$ASSETS/systemd-sleep/touchbar-resume"             /usr/lib/systemd/system-sleep/touchbar-resume 755
	((CHECK)) || systemctl daemon-reload
	enable_unit touchbar-resume.service
fi

# ---------------------------------------------------------------------- wifi --

if wants wifi; then
	head_ "Wi-Fi (03, 05)"
	install_file "$ASSETS/systemd-sleep/brcmfmac-reload" /usr/lib/systemd/system-sleep/brcmfmac-reload 755
	install_file "$ASSETS/modprobe/brcmfmac.conf"        /etc/modprobe.d/brcmfmac.conf 644

	# Patch the regulatory domain IN PLACE. The NVRAM file carries this machine's
	# MAC address; overwriting it wholesale would install someone else's.
	NVRAM=/lib/firmware/brcm/brcmfmac43602-pcie.txt
	if [[ ! -e $NVRAM ]]; then
		warn "$NVRAM absent — Wi-Fi will come up 2.4GHz-only with a random MAC (see ../03-wifi.md §3.2)"
	elif grep -q '^ccode=BR' "$NVRAM" && grep -q '^regrev=0' "$NVRAM"; then
		skip "regulatory domain already ccode=BR regrev=0"
	elif ((CHECK)); then
		would "patch $NVRAM: ccode -> BR, regrev -> 0"
	else
		cp -n "$NVRAM" "$NVRAM.pre-apply-bak"
		sed -i 's/^ccode=.*/ccode=BR/; s/^regrev=.*/regrev=0/' "$NVRAM" \
			&& ok "regulatory domain -> ccode=BR regrev=0 (backup: $NVRAM.pre-apply-bak)" \
			|| fail "patching $NVRAM"
		warn "takes effect on next brcmfmac load (reboot, or stop NetworkManager and reload)"
	fi
fi

# --------------------------------------------------------------------- sleep --

if wants sleep; then
	head_ "Sleep and resume (05, 07)"
	install_file "$ASSETS/sleep-drop-ins/10-macbook-s2idle.conf" /etc/systemd/sleep.conf.d/10-macbook-s2idle.conf 644
	install_file "$ASSETS/systemd-sleep/applespi-reload"         /usr/lib/systemd/system-sleep/applespi-reload 755
	install_file "$ASSETS/modprobe/hid_apple.conf"               /etc/modprobe.d/hid_apple.conf 644
	for f in "$ASSETS"/logind-drop-ins/*.conf; do
		install_file "$f" "/etc/systemd/logind.conf.d/$(basename "$f")" 644
	done
	install_file "$ASSETS/systemd-system/omarchy-nvme-suspend-fix.service" /etc/systemd/system/omarchy-nvme-suspend-fix.service 644
	((CHECK)) || { systemctl daemon-reload; systemctl reload systemd-logind 2>/dev/null; }
	enable_unit omarchy-nvme-suspend-fix.service
fi

# --------------------------------------------------------------------- power --

if wants power; then
	head_ "Power (06)"
	install_file "$ASSETS/usr-local-sbin/macbook-power-tuning.sh" /usr/local/sbin/macbook-power-tuning.sh 755
	install_file "$ASSETS/systemd-system/macbook-power-tuning.service" /etc/systemd/system/macbook-power-tuning.service 644
	install_file "$ASSETS/usr-local-sbin/gpu-mode"   /usr/local/sbin/gpu-mode 755
	install_file "$ASSETS/usr-local-sbin/gpu-switch" /usr/local/sbin/gpu-switch 755
	((CHECK)) || systemctl daemon-reload
	enable_unit macbook-power-tuning.service
	install_file "$ASSETS/omarchy-hooks/dim-panel-on-low-battery.hook" \
		"$TARGET_HOME/.config/omarchy/hooks/battery-low.d/dim-panel-on-low-battery.hook" 755 "$TARGET_USER:$TARGET_USER"

	# TLP. Its stock RADEON_DPM_PERF_LEVEL=auto overwrites the GPU clock clamp on
	# every AC/battery transition - this drop-in is what stops it (06 §6.2).
	install_file "$ASSETS/tlp/01-macbook-power.conf" /etc/tlp.d/01-macbook-power.conf 644
	if [[ $(systemctl is-active power-profiles-daemon 2>/dev/null) == active ]]; then
		warn "power-profiles-daemon is active - it conflicts with TLP; disable one"
	fi
	enable_unit tlp.service

	# Powering the dGPU off: -5.75 W, the largest single win (04 §4.4).
	# The system unit has NO [Install] section on purpose - running this at boot
	# hangs the machine. The user unit runs it after the graphical session, which
	# is the only safe moment. Neither does anything unless the mux is already on
	# the iGPU; dgpu-power refuses otherwise, so this is safe to install in dgpu
	# mode too.
	install_file "$ASSETS/usr-local-sbin/dgpu-power" /usr/local/sbin/dgpu-power 755
	install_file "$ASSETS/systemd-system/disable-dgpu.service" /etc/systemd/system/disable-dgpu.service 644
	install_file "$ASSETS/systemd-user/dgpu-off.service" \
		"$TARGET_HOME/.config/systemd/user/dgpu-off.service" 644 "$TARGET_USER:$TARGET_USER"
	enable_user_unit dgpu-off.service graphical-session.target
	if [[ -e /var/lib/dgpu-power/attempt-incomplete ]]; then
		warn "dgpu-power circuit breaker is TRIPPED - 'off' will refuse until you investigate and rm /var/lib/dgpu-power/attempt-incomplete"
	fi
fi

# --------------------------------------------------------------------- shell --

if wants shell; then
	head_ "Desktop shell (09)"
	install_file "$ASSETS/uwsm/env-hyprland" "$TARGET_HOME/.config/uwsm/env-hyprland" 644 "$TARGET_USER:$TARGET_USER"
	install_file "$ASSETS/omarchy-bar-scripts/fan-speed" \
		"$TARGET_HOME/.config/omarchy/bar/scripts/fan-speed" 755 "$TARGET_USER:$TARGET_USER"
	for f in "$ASSETS"/omarchy-plugin-idle-suspend/*; do
		b=$(basename "$f")
		m=644; [[ $b == *.sh ]] && m=755
		install_file "$f" "$TARGET_HOME/.config/omarchy/plugins/local.idle-suspend/$b" "$m" "$TARGET_USER:$TARGET_USER"
	done

	# shell.json is the user's own layout. Edit it surgically, never overwrite.
	SJ="$TARGET_HOME/.config/omarchy/shell.json"
	if [[ ! -e $SJ ]]; then
		warn "$SJ absent — skipping plugin/widget registration"
	elif ((CHECK)); then
		# Actually inspect it rather than assuming a change is needed - a check
		# run that cries wolf on an already-correct system is worse than useless.
		if as_user python3 -c '
import json,sys,pathlib
cfg=json.loads(pathlib.Path(sys.argv[1]).read_text())
need=[]
if not any(isinstance(e,dict) and e.get("id")=="local.idle-suspend" for e in cfg.get("plugins",[])):
    need.append("plugin")
r=cfg.get("bar",{}).get("layout",{}).get("right")
if isinstance(r,list) and not any(isinstance(w,dict) and w.get("id")=="fan" for w in r):
    need.append("fan widget")
print(",".join(need))
sys.exit(1 if need else 0)' "$SJ" >/dev/null 2>&1; then
			skip "shell.json already registers plugin and fan widget"
		else
			would "register local.idle-suspend plugin and/or fan bar widget in shell.json"
		fi
	else
		as_user python3 - "$SJ" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
cfg = json.loads(p.read_text())
changed = []

plugins = cfg.setdefault("plugins", [])
if not any(isinstance(e, dict) and e.get("id") == "local.idle-suspend" for e in plugins):
    plugins.append({"id": "local.idle-suspend", "timeout": 900,
                    "cooldown": 300, "onBatteryOnly": True})
    changed.append("plugins[local.idle-suspend]")

right = cfg.get("bar", {}).get("layout", {}).get("right")
if isinstance(right, list) and not any(isinstance(w, dict) and w.get("id") == "fan" for w in right):
    entry = {"id": "fan", "type": "command",
             "exec": "~/.config/omarchy/bar/scripts/fan-speed", "interval": 5}
    idx = next((i for i, w in enumerate(right)
                if isinstance(w, dict) and w.get("id") == "omarchy.power"), len(right))
    right.insert(idx, entry)
    changed.append("bar.layout.right[fan]")

if changed:
    p.write_text(json.dumps(cfg, indent=2) + "\n")
    print("CHANGED " + " ".join(changed))
else:
    print("UNCHANGED")
PY
		# shellcheck disable=SC2181
		if [[ $? -eq 0 ]]; then ok "shell.json registration"; else fail "shell.json registration"; fi
	fi
fi

# --------------------------------------------------------------- maintenance --

if wants maintenance; then
	head_ "Maintenance and health checks (11, 08)"
	install_file "$ASSETS/omarchy-hooks/verify-hardware.hook" \
		"$TARGET_HOME/.config/omarchy/hooks/post-boot.d/verify-hardware.hook" 755 "$TARGET_USER:$TARGET_USER"
	install_file "$ASSETS/udev/60-nvme-scheduler.rules" /etc/udev/rules.d/60-nvme-scheduler.rules 644
	((CHECK)) || { udevadm control --reload-rules; udevadm trigger --subsystem-match=block --action=change; }

	for t in snapper-timeline.timer btrfs-scrub@-.timer paccache.timer fstrim.timer; do
		# A templated unit (btrfs-scrub@-.timer) never appears under its instance
		# name in list-unit-files - only as btrfs-scrub@.timer - so ask systemd
		# about the instance directly instead.
		if systemctl is-enabled "$t" >/dev/null 2>&1 \
			|| systemctl cat "$t" >/dev/null 2>&1; then
			enable_unit "$t"
		else
			warn "timer not available: $t"
		fi
	done

	# Timeline snapshots: the safety net. Every snapshot also becomes a boot
	# entry, so the limits are kept deliberately modest.
	if command -v snapper >/dev/null 2>&1 && snapper -c root get-config >/dev/null 2>&1; then
		# NB: snapper separates columns with U+2502, not ASCII '|'.
		if snapper -c root get-config | grep -E '^TIMELINE_CREATE[[:space:]]' | grep -qw yes; then
			skip "snapper timeline already enabled"
		elif ((CHECK)); then
			would "enable snapper timeline (hourly 5 / daily 3)"
		else
			snapper -c root set-config TIMELINE_CREATE=yes TIMELINE_LIMIT_HOURLY=5 \
				TIMELINE_LIMIT_DAILY=3 TIMELINE_LIMIT_WEEKLY=0 TIMELINE_LIMIT_MONTHLY=0 \
				TIMELINE_LIMIT_YEARLY=0 && ok "snapper timeline (hourly 5 / daily 3)" \
				|| fail "snapper set-config"
		fi
	else
		warn "snapper not configured — no bootable rollback points (see ../08 §8.3)"
	fi
fi

# ---------------------------------------------------------------- bootloader --

if wants bootloader; then
	head_ "Kernel command line (08 §8.2)"
	REQUIRED=(mem_sleep_default=s2idle pcie_ports=compat
	          "modprobe.blacklist=apple_ibridge,apple_ib_tb,apple_ib_als")
	missing=()
	for p in "${REQUIRED[@]}"; do
		grep -qF -- "$p" /proc/cmdline || missing+=("$p")
	done
	if ((${#missing[@]} == 0)); then
		skip "all required kernel parameters already present"
	elif ((ALLOW_BOOTLOADER == 0)); then
		warn "missing kernel parameters: ${missing[*]}"
		say  "        Bootloader edits are the one step that can leave this machine"
		say  "        unbootable, so they are opt-in. Add them to KERNEL_CMDLINE in"
		say  "        /etc/default/limine and run 'limine-update', or re-run with"
		say  "        --allow-bootloader --phase bootloader"
	elif ((CHECK)); then
		would "append to /etc/default/limine: ${missing[*]}"
	else
		cp -n /etc/default/limine /etc/default/limine.pre-apply-bak
		printf 'KERNEL_CMDLINE[default]+=" %s"\n' "${missing[*]}" >>/etc/default/limine \
			&& ok "appended: ${missing[*]} (backup: /etc/default/limine.pre-apply-bak)"
		if command -v limine-update >/dev/null 2>&1; then
			limine-update >/dev/null 2>&1 && ok "limine-update" || fail "limine-update — CHECK BEFORE REBOOTING"
		else
			warn "limine-update not found — regenerate boot entries manually"
		fi
		warn "reboot required for kernel parameters to take effect"
	fi
fi

# -------------------------------------------------------------------- verify --

head_ "Verify"
chk() { # chk <label> <command...>
	local label=$1; shift
	if "$@" >/dev/null 2>&1; then printf '  %sok  %s  %s\n' "$GRN" "$RST" "$label"
	else printf '  %snot %s  %s\n' "$YLW" "$RST" "$label"; fi
}
chk "DKMS: appleibridge for $(uname -r)"        bash -c "dkms status | grep -q \"^appleibridge/.*, \$(uname -r), .*: installed\""
chk "DKMS: snd_hda_macbookpro for $(uname -r)"  bash -c "dkms status | grep -q \"^snd_hda_macbookpro/.*, \$(uname -r), .*: installed\""
chk "audio codec bound"                          bash -c "aplay -l 2>/dev/null | grep -qi CS8409"
chk "Touch Bar module loaded"                    grep -q '^apple_ib_tb ' /proc/modules
chk "Wi-Fi module loaded"                        grep -q '^brcmfmac ' /proc/modules
chk "sleep hooks installed (3)"                  bash -c "[ \$(ls /usr/lib/systemd/system-sleep/ | grep -cE 'brcmfmac-reload|touchbar-resume|applespi-reload') -eq 3 ]"
chk "s2idle selected"                            bash -c "grep -q '\[s2idle\]' /sys/power/mem_sleep"
# Either state is correct, and "off" is the better one. A switched-off dGPU
# returns EBUSY on that sysfs read, so testing only for "low" reports a failure
# in exactly the configuration that saves the most power (04 §4.4).
chk "dGPU off, or clamped to low"                bash -c "grep -q ':Off:' /sys/kernel/debug/vgaswitcheroo/switch 2>/dev/null || grep -qx low /sys/class/drm/card*/device/power_dpm_force_performance_level"

printf '\n%s==> %d applied, %d already correct, %d warnings, %d failed%s\n' \
	"$BLU" "$applied" "$skipped" "$warned" "$failed" "$RST"
((CHECK)) && printf '%s(check mode — nothing was written)%s\n' "$YLW" "$RST"
say "Documentation: $HERE/.."
exit $((failed > 0 ? 1 : 0))
