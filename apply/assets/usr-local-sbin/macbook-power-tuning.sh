#!/bin/bash
# Idle power tuning for MacBookPro13,3 (Radeon Pro 455 + worn battery).
#
# Measured at the battery terminals, idle desktop, two A/B rounds:
#   power_dpm_force_performance_level=auto -> sclk pinned 855 MHz -> 22.9 W
#   power_dpm_force_performance_level=low  -> sclk        214 MHz -> 18.8 W
#
# amdgpu leaves this Polaris part at its TOP shader clock while reporting 0%
# busy, so "auto" costs ~4 W for nothing.
#
# Trade-off: mclk also drops to 300 MHz. If the panel ever flickers or video
# stutters, set the level back to "auto".
#
# NOTE: the amdgpu card is located by DRIVER, not by a hardcoded cardN. The
# numbering is not stable - it already changed from card1 to card2 once today
# when i915 was unbound and rebound, and it will change again if the display
# mux moves the panel to the iGPU.
set -uo pipefail

find_amdgpu() {
	local c
	for c in /sys/class/drm/card[0-9]; do
		[ -e "$c/device/driver" ] || continue
		[ "$(basename "$(readlink -f "$c/device/driver")")" = "amdgpu" ] && { printf '%s' "$c/device"; return 0; }
	done
	return 1
}

for _ in {1..15}; do
	GPU=$(find_amdgpu) && [ -w "$GPU/power_dpm_force_performance_level" ] && break
	sleep 1
done

if GPU=$(find_amdgpu) && [ -w "$GPU/power_dpm_force_performance_level" ]; then
	echo low > "$GPU/power_dpm_force_performance_level"
	echo "amdgpu at $GPU: level=$(cat "$GPU/power_dpm_force_performance_level") sclk=$(grep '\*' "$GPU/pp_dpm_sclk" 2>/dev/null | tr -d ' ')"
	# Let the card runtime-suspend when nothing holds it. Matters a great deal
	# if the panel is being driven by the iGPU: then nothing holds it at all.
	dev=$(basename "$(readlink -f "$GPU")")
	[ -w "/sys/bus/pci/devices/$dev/power/control" ] && echo auto > "/sys/bus/pci/devices/$dev/power/control"
else
	echo "amdgpu dpm control not available; nothing to do"
fi
