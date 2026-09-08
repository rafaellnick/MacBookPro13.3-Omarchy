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
| `mem_sleep_default=s2idle` | `deep` fails to resume amdgpu (`error -22`) | [05](05-sleep-and-resume.md) |
| `pcie_ports=compat` | **required for USB-C after resume** — `mbp133-t1-check` asserts it | [10](10-dead-ends.md) §10.1 |
| `modprobe.blacklist=apple_ibridge,apple_ib_tb,apple_ib_als` | the Touch Bar service loads these itself, in the right order | [01](01-touch-bar.md) |
| `resume=/dev/mapper/omarchy_root resume_offset=1914441` | hibernate wiring — **correct but unusable**, firmware refuses S4 | [10](10-dead-ends.md) §10.1 |
| `initramfs_async=0` | pre-existing; slows boot slightly. Origin not documented — **do not remove without knowing why it was added** | — |
| `zswap.enabled=0` | zram is used instead | — |

> `pcie_ports=compat` is the one to be most careful with. It is why the
> Thunderbolt PCIe bridges have **no driver bound**, which in turn is why
> hibernate hits D3cold problems — but changing it trades working USB-C for a
> hibernate the firmware refuses anyway.

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

`linux-lts 6.18.46` is installed alongside `linux 7.1.9`.

> **⚠️ An LTS entry existing is not the same as an LTS entry being usable.**
> The three DKMS modules must build against 6.18 as well, and everything fixed
> in [05](05-sleep-and-resume.md) is kernel-adjacent — the `brcmfmac` D3
> handshake, `applespi` resync, Touch Bar probe — so behaviour may differ in
> either direction under 6.18.
>
> **Verify by booting it deliberately**, at a time of your choosing, and
> checking Wi-Fi, sound, Touch Bar and trackpad. Do not discover the answer on
> the night the primary kernel breaks.

Check which modules built:

```bash
dkms status                                    # expect entries for both kernels
ls /usr/lib/modules/*-lts/updates/dkms/        # apfs, apple-ib*, snd-hda-codec-cs8409
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
