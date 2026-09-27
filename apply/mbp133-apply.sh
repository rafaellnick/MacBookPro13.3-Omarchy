#!/bin/bash
# Reproduce the stable MacBookPro13,3 configuration documented in this repo.

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
	cat <<EOF
Usage: $(basename "$0") [--check] [--phase NAME] [--allow-bootloader]

Phases: ${ALL_PHASES[*]} bootloader

The default run applies every phase except bootloader. --check makes no
changes. The separate build-t1bridge-low-wakeup.sh helper compiles the pinned
renderer patch; this installer never downloads or compiles it implicitly.
EOF
}

while (($#)); do
	case $1 in
		--check) CHECK=1; shift ;;
		--allow-bootloader) ALLOW_BOOTLOADER=1; shift ;;
		--phase) [[ $# -ge 2 ]] || { echo '--phase needs a name' >&2; exit 2; }; PHASES+=("$2"); shift 2 ;;
		--list|-h|--help) usage; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done
((${#PHASES[@]})) || PHASES=("${ALL_PHASES[@]}")
wants() { local p; for p in "${PHASES[@]}"; do [[ $p == "$1" ]] && return 0; done; return 1; }

if [[ $EUID -ne 0 ]]; then
	echo 'Run with sudo; this writes system and per-user configuration.' >&2
	exit 1
fi

TARGET_USER=${SUDO_USER:-$(logname 2>/dev/null || printf root)}
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
TARGET_GROUP=$(id -gn "$TARGET_USER")
[[ -d $TARGET_HOME ]] || { echo "cannot resolve home for $TARGET_USER" >&2; exit 1; }

head_ Preflight
MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || printf unknown)
if [[ $MODEL != MacBookPro13,3 ]]; then
	fail "machine is $MODEL; these changes are only for MacBookPro13,3"
	exit 1
fi
say "  model       : $MODEL"
say "  kernel      : $(uname -r)"
say "  target user : $TARGET_USER ($TARGET_HOME)"
((CHECK)) && say '  mode        : check only'

install_file() {
	local src=$1 dst=$2 mode=$3 owner=${4:-root:root} current
	[[ -e $src ]] || { fail "missing asset: $src"; return 1; }
	if [[ -e $dst ]] && cmp -s "$src" "$dst"; then
		current=$(stat -c '%a:%U:%G' "$dst")
		if [[ $current == "$mode:${owner%%:*}:${owner##*:}" ]]; then skip "$dst"; return 0; fi
	fi
	if ((CHECK)); then would "$dst"; return 0; fi
	install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$dst" \
		&& ok "$dst" || { fail "$dst"; return 1; }
}

remove_path() {
	local path=$1
	[[ -e $path || -L $path ]] || { skip "absent obsolete file: $path"; return 0; }
	if ((CHECK)); then would "remove obsolete file: $path"; return 0; fi
	rm -f -- "$path" && ok "removed obsolete file: $path" || fail "remove $path"
}

enable_unit() {
	local unit=$1
	if systemctl is-enabled "$unit" >/dev/null 2>&1; then skip "enabled: $unit"; return 0; fi
	if ((CHECK)); then would "enable $unit"; return 0; fi
	systemctl enable "$unit" >/dev/null && ok "enabled: $unit" || fail "enable $unit"
}

disable_unit() {
	local unit=$1
	if ! systemctl cat "$unit" >/dev/null 2>&1 && ! systemctl is-enabled "$unit" >/dev/null 2>&1; then return 0; fi
	if ((CHECK)); then would "disable obsolete $unit"; return 0; fi
	systemctl disable --now "$unit" >/dev/null 2>&1 || true
}

need_pkg() {
	local package=$1
	if pacman -Q "$package" >/dev/null 2>&1; then skip "package: $package"; return 0; fi
	if ((CHECK)); then would "install package: $package"; return 0; fi
	pacman -S --needed --noconfirm "$package" >/dev/null \
		&& ok "package: $package" || fail "package: $package"
}

enable_user_unit() {
	local unit=$1 target=$2 link
	link="$TARGET_HOME/.config/systemd/user/$target.wants/$unit"
	if [[ -L $link ]]; then skip "enabled user unit: $unit"; return 0; fi
	if ((CHECK)); then would "enable user unit: $unit"; return 0; fi
	install -d -o "$TARGET_USER" -g "$TARGET_GROUP" "$(dirname "$link")"
	ln -s "../$unit" "$link" && chown -h "$TARGET_USER:$TARGET_GROUP" "$link" \
		&& ok "enabled user unit: $unit" || fail "enable user unit: $unit"
}

if wants packages; then
	head_ Packages
	kernel_package=$(cat "/usr/lib/modules/$(uname -r)/pkgbase" 2>/dev/null || printf linux)
	for package in "${kernel_package}-headers" wget dkms brightnessctl jq tlp git patch; do need_pkg "$package"; done
	for package in t1bridge t1bridge-dkms t1bridge-omarchy libfprint-t1bridge fprintd-t1bridge; do
		pacman -Q "$package" >/dev/null 2>&1 && skip "package: $package" \
			|| warn "$package is missing; install the T1Bridge packages from their Arch repository"
	done
fi

if wants audio-dkms; then
	head_ 'Audio DKMS'
	dkms_status=$(dkms status 2>/dev/null || true)
	if grep -q "^snd_hda_macbookpro/.*, $(uname -r), .*: installed" <<< "$dkms_status"; then
		skip "snd_hda_macbookpro built for $(uname -r)"
	elif ((CHECK)); then
		would 'clone and install snd_hda_macbookpro DKMS'
	else
		SRC=/usr/src/snd_hda_macbookpro-0.1
		[[ -d $SRC ]] || git clone --depth 1 https://github.com/davidjo/snd_hda_macbookpro "$SRC"
		( cd "$SRC" && ./install.cirrus.driver.sh -i ) \
			&& ok 'snd_hda_macbookpro installed' || fail 'snd_hda_macbookpro build'
	fi
fi

if wants touchbar; then
	head_ 'T1Bridge, Touch Bar and Touch ID'
	install_file "$ASSETS/local-bin/t1bridge-desktop-provider-cached" \
		/usr/local/lib/t1bridge/t1bridge-desktop-provider-cached 755
	install_file "$ASSETS/local-bin/t1bridge-auto-brightness-power" \
		"$TARGET_HOME/.local/bin/t1bridge-auto-brightness-power" 755 "$TARGET_USER:$TARGET_GROUP"
	install_file "$ASSETS/systemd-user/t1-touchbar.service.d/60-power-cache.conf" \
		"$TARGET_HOME/.config/systemd/user/t1-touchbar.service.d/60-power-cache.conf" 644 "$TARGET_USER:$TARGET_GROUP"
	install_file "$ASSETS/systemd-user/t1bridge-auto-brightness.service.d/60-power-poll.conf" \
		"$TARGET_HOME/.config/systemd/user/t1bridge-auto-brightness.service.d/60-power-poll.conf" 644 "$TARGET_USER:$TARGET_GROUP"
	if [[ -x /usr/local/lib/t1bridge/t1-touchbar-power && -x /usr/local/lib/t1bridge/t1-touchbar-hw-power ]]; then
		install_file "$ASSETS/systemd-user/t1-touchbar.service.d/70-power-idle.conf" \
			"$TARGET_HOME/.config/systemd/user/t1-touchbar.service.d/70-power-idle.conf" 644 "$TARGET_USER:$TARGET_GROUP"
		install_file "$ASSETS/systemd-system/t1-touchbar-hw.service.d/70-power-idle.conf" \
			/etc/systemd/system/t1-touchbar-hw.service.d/70-power-idle.conf 644
	else
		warn 'low-wakeup binaries absent; run sudo ./build-t1bridge-low-wakeup.sh'
	fi
	disable_unit touchbar-resume.service
	for old in \
		/etc/systemd/system/touchbar-resume.service \
		/etc/systemd/system/touchbar.service.d/override.conf \
		/usr/lib/systemd/system-sleep/touchbar-resume; do remove_path "$old"; done
fi

if wants wifi; then
	head_ Wi-Fi
	install_file "$ASSETS/modprobe/brcmfmac.conf" /etc/modprobe.d/brcmfmac.conf 644
	NVRAM=/lib/firmware/brcm/brcmfmac43602-pcie.txt
	if [[ ! -e $NVRAM ]]; then
		warn "$NVRAM is absent"
	elif grep -q '^ccode=BR' "$NVRAM" && grep -q '^regrev=0' "$NVRAM"; then
		skip 'Wi-Fi regulatory domain: BR/0'
	elif ((CHECK)); then
		would "patch $NVRAM to BR/0"
	else
		cp -n "$NVRAM" "$NVRAM.pre-apply-bak"
		sed -i 's/^ccode=.*/ccode=BR/; s/^regrev=.*/regrev=0/' "$NVRAM" \
			&& ok 'Wi-Fi regulatory domain: BR/0' || fail "patch $NVRAM"
	fi
	remove_path /usr/lib/systemd/system-sleep/brcmfmac-reload
fi

if wants sleep; then
	head_ 'Suspend safety'
	install_file "$ASSETS/logind-drop-ins/99-macbook-suspend-safety.conf" \
		/etc/systemd/logind.conf.d/99-macbook-suspend-safety.conf 644
	for old in 10-ignore-power-button.conf 20-inhibit-delay.conf 30-lid-suspend-when-docked.conf 40-lid-suspend-then-hibernate.conf; do
		remove_path "/etc/systemd/logind.conf.d/$old"
	done
	disable_unit omarchy-nvme-suspend-fix.service
	remove_path /etc/systemd/system/omarchy-nvme-suspend-fix.service
	remove_path /usr/lib/systemd/system-sleep/applespi-reload
	install_file "$ASSETS/systemd-sleep/macbook-thunderbolt-power" \
		/usr/lib/systemd/system-sleep/macbook-thunderbolt-power 755
fi

if wants power; then
	head_ Power
	install_file "$ASSETS/usr-local-sbin/macbook-power-tuning.sh" /usr/local/sbin/macbook-power-tuning.sh 755
	install_file "$ASSETS/systemd-system/macbook-power-tuning.service" /etc/systemd/system/macbook-power-tuning.service 644
	install_file "$ASSETS/tlp/01-macbook-power.conf" /etc/tlp.d/01-macbook-power.conf 644
	install_file "$ASSETS/usr-local-sbin/gpu-switch" /usr/local/sbin/gpu-switch 755
	install_file "$ASSETS/usr-local-sbin/gpu-mode" /usr/local/sbin/gpu-mode 755
	install_file "$ASSETS/usr-local-sbin/dgpu-power" /usr/local/sbin/dgpu-power 755
	install_file "$ASSETS/sudoers/mbp133-dgpu-power" /etc/sudoers.d/mbp133-dgpu-power 440
	install_file "$ASSETS/systemd-system/disable-dgpu.service" /etc/systemd/system/disable-dgpu.service 644
	install_file "$ASSETS/systemd-user/dgpu-off.service" \
		"$TARGET_HOME/.config/systemd/user/dgpu-off.service" 644 "$TARGET_USER:$TARGET_GROUP"
	enable_user_unit dgpu-off.service graphical-session.target
	install_file "$ASSETS/usr-local-sbin/radeon-audio-remove" /usr/local/sbin/radeon-audio-remove 755
	install_file "$ASSETS/systemd-system/radeon-audio-remove.service" /etc/systemd/system/radeon-audio-remove.service 644
	install_file "$ASSETS/usr-local-sbin/macbook-thunderbolt-power" /usr/local/sbin/macbook-thunderbolt-power 755
	install_file "$ASSETS/systemd-system/macbook-thunderbolt-powersave.service" /etc/systemd/system/macbook-thunderbolt-powersave.service 644
	install_file "$ASSETS/omarchy-hooks/dim-panel-on-low-battery.hook" \
		"$TARGET_HOME/.config/omarchy/hooks/battery-low.d/dim-panel-on-low-battery.hook" 755 "$TARGET_USER:$TARGET_GROUP"
	for unit in macbook-power-tuning.service tlp.service radeon-audio-remove.service macbook-thunderbolt-powersave.service; do enable_unit "$unit"; done
	[[ ! -e /var/lib/dgpu-power/attempt-incomplete ]] \
		|| warn 'dgpu-power circuit breaker is tripped; investigate before clearing it'
fi

if wants shell; then
	head_ 'Desktop shell'
	install_file "$ASSETS/uwsm/env-hyprland" "$TARGET_HOME/.config/uwsm/env-hyprland" 644 "$TARGET_USER:$TARGET_GROUP"
	for script in fan-speed power-draw battery-lite; do
		install_file "$ASSETS/omarchy-bar-scripts/$script" \
			"$TARGET_HOME/.config/omarchy/bar/scripts/$script" 755 "$TARGET_USER:$TARGET_GROUP"
	done
	for plugin in local.idle-suspend local.touchbar-idle; do
		source_dir="$ASSETS/omarchy-plugin-${plugin#local.}"
		for source in "$source_dir"/*; do
			mode=644; [[ $source == *.sh ]] && mode=755
			install_file "$source" "$TARGET_HOME/.config/omarchy/plugins/$plugin/$(basename "$source")" "$mode" "$TARGET_USER:$TARGET_GROUP"
		done
	done
	lock_service=
	for manifest in "$TARGET_HOME"/.config/omarchy/plugins/*/manifest.json; do
		[[ -f $manifest ]] || continue
		if grep -q '"clonedFrom"[[:space:]]*:[[:space:]]*"omarchy.lock"' "$manifest"; then
			lock_service="$(dirname "$manifest")/Service.qml"
			break
		fi
	done
	if [[ -z $lock_service ]]; then
		warn 'no cloned omarchy.lock plugin found; lock-state Touch Bar integration was not applied'
	elif grep -q 'touchbarLockStatePath' "$lock_service"; then
		skip 'lock plugin publishes Touch Bar authentication state'
	elif ((CHECK)); then
		if patch --dry-run --silent -d "$(dirname "$lock_service")" -p1 \
			< "$ASSETS/source-patches/omarchy-lock-touchbar-state.patch"; then
			would "patch $lock_service for Touch Bar lock authentication"
		else
			warn "lock plugin differs from Omarchy 4.0.4; patch needs rebasing: $lock_service"
		fi
	elif patch --forward --silent -d "$(dirname "$lock_service")" -p1 \
		< "$ASSETS/source-patches/omarchy-lock-touchbar-state.patch"; then
		chown "$TARGET_USER:$TARGET_GROUP" "$lock_service"
		ok 'lock plugin publishes Touch Bar authentication state'
	else
		warn "lock plugin patch failed; rebase it before relying on fingerprint while blanked"
	fi
	SJ="$TARGET_HOME/.config/omarchy/shell.json"
	if [[ ! -e $SJ ]]; then
		warn "$SJ absent; plugins and power widget were not registered"
	else
		if ((CHECK)); then
			result=$(python3 "$HERE/reconcile-shell.py" --check "$SJ") || result=ERROR
			[[ $result == UNCHANGED ]] && skip 'shell.json plugins and widgets' \
				|| would 'reconcile shell.json plugins and widgets'
		else
			cp -n "$SJ" "$SJ.pre-mbp133-apply"
			result=$(python3 "$HERE/reconcile-shell.py" "$SJ") || result=ERROR
			chown "$TARGET_USER:$TARGET_GROUP" "$SJ"
			case $result in
				CHANGED) ok 'shell.json plugins and widgets' ;;
				UNCHANGED) skip 'shell.json plugins and widgets' ;;
				*) fail 'shell.json plugins and widgets' ;;
			esac
		fi
	fi
fi

if wants maintenance; then
	head_ Maintenance
	install_file "$ASSETS/omarchy-hooks/verify-hardware.hook" \
		"$TARGET_HOME/.config/omarchy/hooks/post-boot.d/verify-hardware.hook" 755 "$TARGET_USER:$TARGET_GROUP"
	install_file "$ASSETS/udev/60-nvme-scheduler.rules" /etc/udev/rules.d/60-nvme-scheduler.rules 644
	for timer in snapper-timeline.timer btrfs-scrub@-.timer paccache.timer fstrim.timer; do
		systemctl cat "$timer" >/dev/null 2>&1 && enable_unit "$timer" || warn "timer unavailable: $timer"
	done
fi

if wants bootloader; then
	head_ Bootloader
	REQUIRED=(pcie_ports=compat mem_sleep_default=s2idle)
	missing=()
	for argument in "${REQUIRED[@]}"; do grep -qw "$argument" /proc/cmdline || missing+=("$argument"); done
	if ((${#missing[@]} == 0)); then
		skip 'required kernel arguments are present'
	elif ((ALLOW_BOOTLOADER == 0)); then
		warn "missing: ${missing[*]}; use --allow-bootloader --phase bootloader after reviewing"
	elif ((CHECK)); then
		would "append to /etc/default/limine: ${missing[*]}"
	else
		cp -n /etc/default/limine /etc/default/limine.pre-mbp133-apply
		printf 'KERNEL_CMDLINE[default]+=" %s"\n' "${missing[*]}" >> /etc/default/limine
		limine-update && ok "boot arguments: ${missing[*]}" || fail 'limine-update'
	fi
fi

((CHECK)) || {
	systemctl daemon-reload
	udevadm control --reload-rules 2>/dev/null || true
}

head_ Verify
check() { local label=$1; shift; if "$@" >/dev/null 2>&1; then printf '  %sok  %s  %s\n' "$GRN" "$RST" "$label"; else printf '  %snot %s  %s\n' "$YLW" "$RST" "$label"; fi; }
check 'T1Bridge hardware service active' systemctl is-active --quiet t1-touchbar-hw.service
check 'T1Bridge renderer package installed' pacman -Q t1bridge
check 'audio codec bound' bash -c 'aplay -l 2>/dev/null | grep -qi CS8409'
check 'Wi-Fi driver loaded' grep -q '^brcmfmac ' /proc/modules
check 'internal panel on Intel' bash -c 'for c in /sys/class/drm/card*-eDP-*; do [[ -n $(cat "$c/modes" 2>/dev/null) ]] && [[ $(basename "$(readlink -f "${c%%-eDP-*}/device/driver")") == i915 ]] && exit 0; done; exit 1'
check 'dGPU powered off' bash -c "grep -q 'DIS:.*:Off:' /sys/kernel/debug/vgaswitcheroo/switch 2>/dev/null"
check 'Radeon HDMI audio removed' test ! -e /sys/bus/pci/devices/0000:01:00.1
check 'automatic lid suspend blocked' grep -q '^HandleLidSwitch=ignore' /etc/systemd/logind.conf.d/99-macbook-suspend-safety.conf

printf '\n%s==> %d applied, %d already correct, %d warnings, %d failed%s\n' \
	"$BLU" "$applied" "$skipped" "$warned" "$failed" "$RST"
((CHECK)) && say '(check mode: nothing was written)'
exit $((failed > 0 ? 1 : 0))
