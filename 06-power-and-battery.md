# 06 — Power and battery

The current repeatable quiet-desktop floor is about **9–10 W at the battery
terminals**. A PowerTOP interval measured 9.09 W. One measured boot settled at
10.79 W after a minute. Readings of 12–15 W while terminals, monitoring tools
or the coding agent are active are load measurements; they should not be used
as the idle baseline.

The original target was 5–7 W. It has not been reached. Intel package power was
observed near 5.1 W, but that excludes the display, SSD, Wi-Fi, T1, memory,
fans and conversion loss. A worn 1,260-cycle battery also makes short samples
noisy; replacing it will improve runtime and measurement quality, but does not
by itself reduce the computer's electrical load.

## Changes that remain enabled

| Change | Result or reason |
|---|---|
| Internal panel on Intel; Radeon rails off | Largest stable platform saving; external output unavailable |
| Radeon HDMI audio removed before login | Removes an unused PCI function while Radeon is still safely accessible |
| TLP battery EPP `power`, 60% ceiling, turbo/dynamic boost off | Cuts CPU spikes while retaining usable responsiveness |
| Radeon DPM `low` fallback | Controls the card before it is powered off or when using dGPU mode |
| Unused Thunderbolt NHI unbound on battery | Avoids idle wakeups while preserving attached devices and AC behavior |
| Touch Bar polling patch and 10-second OLED blank | Reduced renderer wakeups and OLED-on time |
| Touch Bar brightness polling every 10 s, battery cap 10% | Avoids a one-second loop and unnecessary panel brightness |
| Bluetooth disabled on battery when unused | TLP restores it on AC |
| Bar power widget every 10 s; fan widget every 60 s | Gives useful telemetry without rapid shell polling |

TLP's relevant battery policy lives in
`/etc/tlp.d/01-macbook-power.conf`. `power-profiles-daemon` must not manage the
same settings concurrently.

## Measuring correctly

Use at least a 60-second sample after the session has settled. Disconnect AC,
stop active downloads, leave the pointer still, and record panel brightness.
The bar widget calculates `current_now × voltage_now`; it is an instantaneous
value and will jump when the CPU wakes.

```bash
watch -n 2 '~/.config/omarchy/bar/scripts/power-draw'
sudo powertop --time=60 --html=/tmp/powertop.html
tlp-stat -s -p
```

Do not stop or modify the active coding session to manufacture a lower number.
Measure it as workload when it is running, then measure the quiet desktop after
it has completed.

## Boot expectations

The Radeon begins powered because EFI initializes it. The HDMI-audio function
is removed before display-manager startup; the GPU is turned off two seconds
after the graphical session exists and SDDM has released its DRM handles. Draw
during that interval will be higher. Once `dgpu-off.service` reports success,
the same 9–10 W quiet floor should be available without manual commands.

```bash
systemctl status radeon-audio-remove.service
systemctl --user status dgpu-off.service
sudo dgpu-power status
```

If idle remains above 12 W after several minutes, first check that the Radeon
is `Off`, its audio function is absent, the Thunderbolt service is active, and
no process is keeping the CPU busy. A momentary spike is expected; a sustained
plateau is the useful symptom.
