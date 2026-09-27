# MacBookPro13,3 on Omarchy

This repository records the working Arch/Omarchy configuration for a 15-inch
2016 MacBook Pro with an Intel HD 530, Radeon Pro 455 and Apple T1 chip. It
includes reproducible assets and an idempotent installer in [`apply/`](apply/).

The current machine runs Omarchy 4.0.4 on `linux-lts` 6.18.49, T1Bridge 0.1.12
and TLP 1.10.2. Package and kernel versions are observations, not pins, except
for the optional T1Bridge low-wakeup source patch.

## Current state

| Subsystem | State |
|---|---|
| Touch Bar | T1Bridge renderer, Omarchy controls, 10-second idle blanking |
| Touch ID | `libfprint-t1bridge`/`fprintd-t1bridge`; kept available at lock screen |
| Internal display | Driven by Intel HD 530 |
| Radeon Pro 455 | Powered off after graphical login with guarded `vga_switcheroo` control |
| External display | Unavailable in the low-power iGPU configuration; outputs are wired to Radeon |
| Idle battery draw | About 9–10 W at the quiet desktop on the worn battery; active work is higher |
| Shutdown/reboot | Working after removing the dGPU power-on stop action |
| Suspend | Deliberately blocked; current upstream/kernel stack is not reliable on this machine |
| Keyboard/trackpad | Usable, with an intermittent sticky-input issue still to investigate |

The aspirational 5–7 W figure has not been reproduced. The lowest repeatable
whole-machine reading is roughly 9 W. A package-only figure near 5 W is not the
same as battery-terminal draw: the panel, SSD, radios, T1 and voltage-conversion
losses remain outside the CPU package measurement.

## Documentation

| Document | Subject |
|---|---|
| [01-touch-bar.md](01-touch-bar.md) | T1Bridge, Touch Bar blanking, Touch ID and wakeup reduction |
| [02-audio.md](02-audio.md) | CS8409/CS42L83 audio DKMS |
| [03-wifi.md](03-wifi.md) | Broadcom Wi-Fi and regulatory data |
| [04-display-and-gpu.md](04-display-and-gpu.md) | iGPU boot, Radeon isolation and external-display trade-off |
| [05-sleep-and-resume.md](05-sleep-and-resume.md) | Suspend failures, research and current safety policy |
| [06-power-and-battery.md](06-power-and-battery.md) | Measured power work and interpretation |
| [07-input-devices.md](07-input-devices.md) | Keyboard and trackpad |
| [08-boot-kernel-and-recovery.md](08-boot-kernel-and-recovery.md) | Boot, kernels, snapshots and recovery |
| [09-desktop-shell.md](09-desktop-shell.md) | Omarchy plugins and bar widgets |
| [10-dead-ends.md](10-dead-ends.md) | Unsafe or disproved approaches |
| [11-maintenance.md](11-maintenance.md) | Verification and update checklist |

## Quick verification

```bash
systemctl is-active t1-touchbar-hw.service
systemctl --user is-active t1-touchbar.service
sudo /usr/local/sbin/dgpu-power status
test ! -e /sys/bus/pci/devices/0000:01:00.1 && echo 'Radeon HDMI audio removed'
systemctl is-active tlp.service macbook-thunderbolt-powersave.service
grep HandleLidSwitch /etc/systemd/logind.conf.d/99-macbook-suspend-safety.conf
```

The installer does not switch the EFI GPU preference automatically and does
not claim suspend is fixed. Read the relevant document before changing either.
