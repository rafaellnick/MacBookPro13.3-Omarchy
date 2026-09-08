# 11 — Maintenance, health checks and known debt

What runs on a schedule, what watches for breakage, and what is still untidy.

---

## 11.1 Automatic health check

`~/.config/omarchy/hooks/post-boot.d/verify-hardware.hook` runs on every boot
and is **silent when healthy** — it only speaks when something is actually wrong,
so it stays worth reading.

It verifies:

| Check | Guards against |
|---|---|
| DKMS `snd_hda_macbookpro`, `appleibridge`, `linux-apfs-rw` built **for the running kernel** | the silent kernel-update failure in [02](02-audio.md) §2.3 |
| `CS8409/CS42L83` bound in `aplay -l` | module built but not attached |
| `apple_ib_tb` loaded | Touch Bar |
| `brcmfmac` loaded | the sleep hook failing to reload it |

On failure it fires a **persistent critical notification** naming exactly what is
missing, and logs to the journal under tag `verify-hardware`. It records the
last-verified kernel, so the message reads *"After kernel update X → Y"* rather
than just "something is broken".

Verified in both directions — a check that never fires is worthless:

```
healthy    → no output, exit 0
simulated  → FAIL: After kernel update old-kernel-1.2.3 → 9.9.9-fake:
             DKMS snd_hda_macbookpro: not installed for 9.9.9-fake ...
```

---

## 11.2 Timers

| Timer | Schedule | Added | Purpose |
|---|---|---|---|
| `snapper-timeline.timer` | hourly | 2026-09-07 | hourly ×5 / daily ×3 rollback points |
| `snapper-cleanup.timer` | hourly | pre-existing | prunes per the limits |
| `btrfs-scrub@-.timer` | monthly | 2026-09-07 | data integrity — **was disabled** |
| `paccache.timer` | weekly | 2026-09-07 | caps pacman cache — **was disabled** |
| `fstrim.timer` | weekly | pre-existing | SSD trim (healthy; runs) |

Before 2026-09-07 there was exactly **one** snapshot, from the previous day, and
no periodic snapshots at all. See [08-boot-kernel-and-recovery.md](08-boot-kernel-and-recovery.md).

---

## 11.3 Verification commands

```bash
# whole-machine
mbp133-t1-check                      # 0 failures; 1 known-false warning (01 §1.2)
systemctl --failed                   # 0
dkms status                          # all installed for $(uname -r)

# per subsystem
systemctl status touchbar.service    # active (exited), SUCCESS: fnmode=1 ...
aplay -l | grep CS42L83              # audio bound
iw dev wlp3s0 link                   # wifi
grep -E "Apple SPI" /proc/bus/input/devices   # keyboard + trackpad
hyprctl monitors | grep -A2 eDP-1    # 2880x1800
omarchy-shell idle-suspend status    # timeout=900 dryRun=False armed=True

# after a suspend — all three should be zero / present
journalctl -b | grep -c "Failed to put system to sleep"
journalctl -b | grep -c "Received corrupted packet"
journalctl -b | grep -E "brcmfmac-reload|apple_ib_tb reloaded|applespi-reload"
```

---

## 11.4 ⚠️ Known config debt

### Three conflicting `wifi.powersave` files

```
/etc/NetworkManager/conf.d/30-wifi-powersave.conf        wifi.powersave=3
/etc/NetworkManager/conf.d/omarchy-wifi-powersave.conf   wifi.powersave = 2
/etc/NetworkManager/conf.d/wifi-powersave.conf           wifi.powersave = 2
```

Three files, two different values. NetworkManager reads `conf.d` in lexical
order so the last would win — but the **effective** setting is `3`, which comes
from the *connection profile*, not from any of these files. All three are
therefore misleading.

**Not cleaned up**, because deciding which to keep is a policy choice. Consolidate
to one file when convenient.

### Passwordless sudo still installed

```
/etc/sudoers.d/99-claude-temp   →   rafaellnick ALL=(ALL) NOPASSWD: ALL
```

Added for this work and flagged in the original notes as temporary. It grants
unconditional passwordless root, and it is mode **0644** while every other file
in `sudoers.d` is **0440**.

```bash
sudo rm /etc/sudoers.d/99-claude-temp
```

`10-timestamp` already gives a 60-minute global sudo timestamp, so removing this
costs very little friction.

### Smaller items

- **pacman cache** ~937 MB. `paccache.timer` now caps it weekly; `sudo paccache -r`
  reclaims immediately.
- **5 orphan packages**: `python-build`, `python-hatchling`, `python-installer`,
  `python-wheel`, `obs-shaderfilter-git-debug`. The four python ones are AUR
  build dependencies that return whenever you build a package — leaving them is
  reasonable.
- **journald is uncapped** — 288 MB now, `SystemMaxUse` unset (defaults to ~10 %
  of `/var`). A `SystemMaxUse=500M` drop-in would bound it.

### No backup exists

Snapshots live on the **same disk** as the data. They protect against a bad
update or a broken config; they do nothing for a failed SSD, theft, or a
mistaken `rm`. Home is only 8.9 GB. **This is the largest remaining risk on the
machine** and needs a target chosen (external drive, another host, or cloud).

---

## 11.5 Superseded files, safe to delete

| Path | Why |
|---|---|
| `/usr/local/bin/omarchy-dp3-link-fix` | old force-4-lanes version, replaced by `dp3-link-hbr2` |
| `/etc/systemd/system/omarchy-dp3-link-fix.service` | disabled; udev rule already gone |
| `~/mbp133-linux-fixes.md` | absorbed into this documentation set |
