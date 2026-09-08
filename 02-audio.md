# 02 — Audio

Working, and the **most fragile thing on this machine** across kernel updates.
Read §2.3 before your next `pacman -Syu`.

---

## 2.1 Sound was silent at install

### Cause

The CS8409 codec bound fine, but mainline's `snd-hda-codec-cs8409` quirk table
targets **Dell machines only** — `bullseye`, `warlock`, `cyborg`, `dolphin`,
`odin`, with no Apple entries at all. The codec fell through to the generic
parser, and the **CS42L83 sub-codec that actually drives the speakers was never
initialised**.

`mbp133-t1-check` flags this correctly.

### Fix

- Installed `wget` — **this was the real blocker on the first attempt.**
  `install.cirrus.driver.sh` downloads matching kernel source to patch against.
  Without `wget` it failed, printed the error into the DKMS pre-build log, **and
  still exited 0**. The wrapper reported success while the module had not built.
- Installed <https://github.com/davidjo/snd_hda_macbookpro> via DKMS
  (`sudo ./install.cirrus.driver.sh -i`). This machine's codec subsystem ID,
  `0x106b3900`, has an explicit branch in that driver (labelled 14,3 there).
  The patched module lands in `/lib/modules/<kernel>/updates/dkms/` and
  overrides the in-tree one; the original is archived by DKMS.

### Result

PCM enumerates as **`CS8409/CS42L83 Analog`** where mainline showed only a
generic "Built-in Audio". A 440 Hz test tone plays through the speakers.

Internal mic: unmuted, `Internal Mic Boost` set to `1`. At the default boost of
`2` it clipped (peak pinned at 32767); boost `1` measured ~34 % peak / 6.5 % RMS
on room ambience. Saved with `alsactl store`.

> **There is no ALSA playback volume control on this device.** That is by design
> in this driver — volume is applied in software by PipeWire. Playing to
> `hw:0,0` or `plughw:0,0` directly bypasses all volume control and will be
> **very loud**.

---

## 2.2 The DKMS source symlink was dangling (fixed 2026-09-07)

`/var/lib/dkms/snd_hda_macbookpro/0.1/source` pointed into a temporary working
directory under `/tmp`, which the reboot wiped. `dkms status` read `broken` —
*"Missing the module source directory"*.

The danger is that this is **silent**: the already-built `.ko` in
`/lib/modules/<kernel>/updates/dkms/` keeps working until the kernel changes, so
sound would have died at the next kernel update with no obvious cause.

Fixed by cloning the repository in place at `/usr/src/snd_hda_macbookpro-0.1`,
so it survives reboots. `dkms status` reads `installed (Original modules exist)`.

---

## 2.3 ⚠️ The kernel-update failure mode

DKMS rebuilds this module by **re-downloading ~150 MB of kernel source from
kernel.org** in its pre-build step. That requires working network and `wget`
*at update time*.

If the build fails:

1. The error scrolls past in the pacman output.
2. The existing `.ko` for the **old** kernel keeps working.
3. You reboot into the new kernel and have **no sound**, with nothing pointing
   at the cause.

### Mitigation added 2026-09-07

`~/.config/omarchy/hooks/post-boot.d/verify-hardware.hook` checks on every boot
that `snd_hda_macbookpro` is `installed` **for the running kernel** and that the
codec is actually bound, and fires a persistent critical notification naming the
problem if not. It is silent when healthy.

See [11-maintenance.md](11-maintenance.md).

### Manual diagnosis

```bash
dkms status
sudo cat /var/lib/dkms/snd_hda_macbookpro/0.1/build/make.log
aplay -l | grep CS42L83
```

---

## Verify

```bash
aplay -l | grep -i cs42l83        # card 1: PCH [HDA Intel PCH], CS8409/CS42L83 Analog
dkms status | grep snd_hda        # installed (Original modules exist), for $(uname -r)
speaker-test -c2 -twav -l1        # audible through speakers
```
