# MacBookPro13,3 on Omarchy — adaptation catalogue

Everything this machine needed beyond a stock Omarchy install, why it needed it,
and how to tell whether it is still working.

This supersedes the single-file `~/mbp133-linux-fixes.md`, whose content is
absorbed here and expanded. Keep that file as the original record if you like;
nothing reads it.

---

## The machine

| | |
|---|---|
| Model | MacBookPro13,3 — 15-inch, 2016, Touch Bar, **T1** security chip |
| CPU | Intel Skylake, 4 cores / 8 threads |
| GPU | AMD Radeon Pro 455 (Polaris11, `1002:67ef`, 2 GB) + Intel HD 530 iGPU (`8086:191b`) |
| Panel | 2880x1800 internal eDP, muxed between both GPUs by `apple_gmux` |
| RAM | 15 GiB |
| Storage | APPLE SSD SM0512L NVMe, LUKS2 → btrfs (`@`, `@home`, `@log`, `@pkg`) |
| Wi-Fi | Broadcom BCM43602 (`106b:015a`), firmware 7.35.177.61 (Nov 2015) |
| Audio | Cirrus CS8409 + CS42L83 |
| Battery | 1245 cycles, **67.7 % of design capacity** |
| OS | Omarchy 4.0.2 / Arch, Hyprland 0.56.2 + aquamarine 0.14.0, quickshell |
| Kernels | `linux` 7.1.9-arch1-2 (primary), `linux-lts` 6.18.46 (fallback) |

Baseline package: `mbp133-hardware-support 2.0.0`
(<https://github.com/nohzafk/omarchy-macbookpro-t1>), which does most of the
platform work. Everything catalogued here is what remained broken, or broke
later, on top of that.

---

## The modules

| Doc | Covers |
|---|---|
| [01-touch-bar.md](01-touch-bar.md) | Touch Bar: DKMS build, HID enumeration, resume race |
| [02-audio.md](02-audio.md) | CS8409/CS42L83 patched codec, and its kernel-update fragility |
| [03-wifi.md](03-wifi.md) | Regulatory domain, the generic NVRAM profile, D3 sleep failure |
| [04-display-and-gpu.md](04-display-and-gpu.md) | External DP link training, GPU mux, panel selection, powering the dGPU off |
| [05-sleep-and-resume.md](05-sleep-and-resume.md) | **The largest module.** s2idle, and the three drivers that do not survive it |
| [06-power-and-battery.md](06-power-and-battery.md) | Measured draw, what actually saved watts, what did not |
| [07-input-devices.md](07-input-devices.md) | `applespi` keyboard and trackpad, SPI desync on resume |
| [08-boot-kernel-and-recovery.md](08-boot-kernel-and-recovery.md) | limine, UKI, snapshots, LTS fallback, how to recover |
| [09-desktop-shell.md](09-desktop-shell.md) | Hyprland/quickshell adaptations, idle suspend, bar widgets |
| [10-dead-ends.md](10-dead-ends.md) | Things that are **not possible** here, with the evidence |
| [11-maintenance.md](11-maintenance.md) | Timers, health checks, config debt, verification |

---

## Current status at a glance

| Subsystem | State | Doc |
|---|---|---|
| Touch Bar | Working, survives resume | 01 |
| Audio | Working, **fragile across kernel updates** | 02 |
| Wi-Fi | Working; regulatory domain corrected; unloaded across sleep by design | 03 |
| Internal display | Working on the **Intel iGPU**, AMD card powered off (−5.75 W) | 04 |
| External display | **No adaptations applied** — link fixes were reverted | 04 |
| Suspend (s2idle) | **Working** — was completely broken until 2026-09-07 | 05 |
| Hibernate | **Impossible.** Firmware refuses S4 | 10 |
| Trackpad / keyboard | Working, resynced on resume | 07 |
| Touch ID | **Impossible** | 10 |
| Idle suspend | Live, 15 min, battery only | 09 |
| Fallback kernel | `linux-lts` installed | 08 |
| Snapshots | Hourly + daily, bootable | 08 |

---

## Fast verification after a reboot

```bash
mbp133-t1-check                      # 0 failures (1 known-false warning, see 01)
systemctl status touchbar.service    # active (exited), "SUCCESS: fnmode=1 ..."
aplay -l | grep CS42L83              # patched audio codec is bound
iw dev wlp3s0 link                   # signal / bitrate
hyprctl monitors | grep -A2 eDP-1    # 2880x1800
omarchy-shell idle-suspend status    # timeout=900 dryRun=False armed=True
dkms status                          # all modules "installed" for $(uname -r)
```

A post-boot hook (`~/.config/omarchy/hooks/post-boot.d/verify-hardware.hook`)
already runs the critical subset of these automatically and notifies **only on
failure** — see [11-maintenance.md](11-maintenance.md).

---

## Conventions used in these docs

- **Symptom → cause → fix**, in that order. The cause matters more than the fix,
  because several of these look like something they are not.
- Where a fix was wrong and later corrected, both are recorded. The wrong first
  answer is usually the more useful half.
- Sections headed **"What did not work, and why"** are load-bearing. They exist
  so the same dead end is not walked twice.
- Measured numbers are labelled as measured. Anything unverified says so.
