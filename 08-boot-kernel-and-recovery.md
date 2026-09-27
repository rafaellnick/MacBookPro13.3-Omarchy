# 08 — Boot, kernel and recovery

How this machine boots, and — more importantly — **how to get back in when
something breaks**. Two separate incidents on 2026-09-07 required dropping to a
TTY because there was no easier way back. There is now.

---

## 8.1 The boot chain

```
Apple EFI firmware
  └─ limine  (/boot/EFI/limine/limine_x64.efi, ESP is /boot, vfat 2 GB)
      └─ UKI  /boot/EFI/Linux/omarchy_linux.efi   (~78 MB)
          └─ LUKS2 → btrfs subvolume @
```

- Root is **LUKS2**: `cryptdevice=UUID=9c799ccb-…:omarchy_root`
- btrfs subvolumes: `@` (root), `@home`, `@log`, `@pkg`
- initramfs is **systemd-based**:
  `HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole
  block sd-encrypt filesystems fsck)`
- The UKI is rebuilt by `/usr/share/libalpm/scripts/limine-mkinitcpio-install`,
  triggered by the pacman hook `90-mkinitcpio-install.hook` on
  `usr/lib/modules/*/pkgbase` — which is why installing a second kernel produces
  its own UKI and boot entry automatically, with no preset to write.

`default_entry: 2` is the live system (`/+Omarchy`,
`rootflags=subvol=@`). **Snapshot entries never become the default.**

---

## 8.2 Kernel command line, annotated

Every non-obvious parameter and why it is there:

| Parameter | Reason | Reference |
|---|---|---|
| `mem_sleep_default=s2idle` | Selects the only exposed suspend variant; suspend remains blocked by policy | [05](05-sleep-and-resume.md) |
| `pcie_ports=compat` | Preserves the established USB-C/PCIe topology on this machine | [05](05-sleep-and-resume.md) |
| `resume=/dev/mapper/omarchy_root resume_offset=1914441` | Old hibernate wiring; firmware refuses S4, so it is currently unused | [10](10-dead-ends.md) |
| `initramfs_async=0` | pre-existing; slows boot slightly. Origin not documented — **do not remove without knowing why it was added** | — |
| `zswap.enabled=0` | zram is used instead | — |

The legacy `modprobe.blacklist=apple_ibridge,apple_ib_tb,apple_ib_als` argument
is no longer part of the live command line. T1Bridge owns the current T1 stack.

---

## 8.3 Bootable snapshots — the safety net

`limine-snapper-sync` runs continuously, watching `/.snapshots` with
`inotifywait`, and writes a boot entry for each snapshot:

```
//Snapshots
  cmdline: ... rootflags=subvol=/@/.snapshots/<N>/snapshot ...
```

### The gap that was closed on 2026-09-07

The infrastructure was already working — but **nothing was creating snapshots**.
`TIMELINE_CREATE` was `no` and `snapper-timeline.timer` was disabled, so there
was exactly **one** snapshot, from the previous day. Two logins were broken that
day with no recent rollback point to return to.

Now:

| Setting | Value |
|---|---|
| `TIMELINE_CREATE` | `yes` |
| `TIMELINE_LIMIT_HOURLY` | 5 |
| `TIMELINE_LIMIT_DAILY` | 3 |
| `NUMBER_LIMIT` | 5 (pacman-triggered) |

Limits are kept modest deliberately: **every snapshot becomes a boot menu
entry**, and an unbounded list makes the menu unusable.

### To roll back

1. Reboot, and at the limine menu open **Snapshots**.
2. Boot the snapshot from before the breakage. It mounts
   `subvol=/@/.snapshots/<N>/snapshot` read-write.
3. Confirm the system is good, then promote it with `snapper rollback` if you
   want it permanent.

```bash
sudo snapper -c root list                # what exists
sudo snapper -c root create --description "before <risky thing>"
```

---

## 8.4 Fallback kernel

Until 2026-09-07 there was **exactly one kernel installed**. Given that Wi-Fi,
Touch Bar and trackpad all broke in driver-level ways that day, a second
bootable kernel is real insurance.

The live system currently uses `linux-lts` 6.18.49. Keep at least one known
bootable fallback entry when updating kernels.

### DKMS checks

The audio codec and T1Bridge kernel components must be built for the kernel that
actually boots. `dkms status` should list `snd_hda_macbookpro` and
`t1bridge-dkms` components for `uname -r`. Building successfully does not prove
suspend works; keep the suspend safety policy after kernel updates until it has
been deliberately retested.

Check which modules built:

```bash
dkms status
find "/usr/lib/modules/$(uname -r)/updates/dkms" -maxdepth 1 -type f
```

---

## 8.5 Recovery routes, in order of preference

| Situation | Route |
|---|---|
| Bad config / broken login | **Boot a snapshot** from the limine menu |
| Kernel or driver regression | **Boot `linux-lts`** from the limine menu |
| Graphical session fails, system otherwise fine | **Ctrl+Alt+F2** for a TTY — this worked twice on 2026-09-07 |
| Black screen after a GPU mux change | **⌘ + ⌥ + P + R** at the chime, through two more chimes — resets NVRAM, mux returns to AMD |
| Shell (bar/lock/screensaver) broken | `omarchy-restart-shell` — refuses while the session is locked |

> A black screen at the password prompt is **not necessarily** a decryption
> failure. omarchy themes the sddm greeter and the plymouth decrypt prompt
> identically — a Hyprland crash loop looks exactly like being stuck at
> decryption. Check with `journalctl -b | grep -i hyprland` from a TTY before
> assuming the disk is the problem. See [09](09-desktop-shell.md) §9.1.

---

## Verify

```bash
sudo grep -E "^default_entry|subvol=" /boot/limine.conf   # default = subvol=@
sudo snapper -c root list
systemctl is-enabled snapper-timeline.timer               # enabled
df -h /boot                                               # ESP has room for both UKIs
pacman -Q linux linux-lts
```
