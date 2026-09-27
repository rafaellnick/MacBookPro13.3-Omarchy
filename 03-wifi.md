# 03 — Wi-Fi (Broadcom BCM43602)

The regulatory configuration is corrected. Earlier attempts also reloaded the
driver around suspend, but those hooks have been removed because suspend itself
is currently blocked; see [05-sleep-and-resume.md](05-sleep-and-resume.md).

---

## 3.1 Weak signal — restrictive regulatory domain

This was **not** broken the way the Touch Bar and audio were; it was already
largely working.

### Cause

The NVRAM profile set `ccode=00` (world regulatory domain) with `regrev=245`, so
the radio ran under the most restrictive worldwide limits.

### Fix

- `/lib/firmware/brcm/brcmfmac43602-pcie.txt`: `ccode=00` → `ccode=BR`,
  `regrev=245` → `regrev=0`. Backup at `…txt.pre-claude-bak`.
  Verified live by reloading `brcmfmac` — NVRAM is only parsed at module load,
  and NetworkManager holds the interface, so this needs NetworkManager stopped.
- `wifi.powersave` set in NetworkManager. **See [11-maintenance.md](11-maintenance.md)
  §11.4 — there are now three conflicting files setting this.**

### What did not work, and why

- **`iw reg set BR` is a dead end on this driver.** `brcmfmac` registers a
  hardcoded custom regulatory domain (`country 99: DFS-UNSET`, every channel
  capped at 20 dBm) via `REGULATORY_CUSTOM_REG`, so the phy ignores the kernel
  regdb. Only the NVRAM `ccode` reaches the firmware.
- **`ccode=ALL`** (recommended by the Gentoo wiki for this model) was tested and
  changed nothing measurable here.

### Measured after the change

- Signal −67 to −70 dBm, steady.
- **151 Mbit/s** (18.9 MB/s) on a real download — likely ISP-limited, not
  radio-limited.
- Link negotiates 40 MHz / 2 spatial streams, though the card advertises VHT80
  with 3 streams and the AP advertises 80 MHz. Most likely the firmware
  narrowing the channel because of weak signal — narrower channel, better SNR
  per subcarrier — rather than a separate defect.

---

## 3.2 The NVRAM profile is not this board's

`/lib/firmware/brcm/brcmfmac43602-pcie.txt` is a **generic dump that did not come
from this machine's board.** It declares `subvid=0x14e4` (Broadcom) while the
card's actual PCI subsystem is `106b:015a` (Apple). It is MikeRatcliffe's widely
copied gist with the MAC substituted.

Every RF calibration table in it — TX power (`tssi_*`, `gain_index_*`), RX gain
(`rxgains*`, `rxgainerr*`) and the RSSI correction tables (`rssi_delta_*`,
`rssicorrnorm_*`) — belongs to different hardware. So **the reported −68 dBm may
be partly a miscalibrated reading**, not a true measure of received power.

### Extraction was attempted and is a dead end

Three independent findings, each ruling out a source of authentic board data:

1. **No EFI variable.** `brcmf_fw_nvram_from_efi()` reads genuine Apple board
   data from an EFI variable with GUID
   `74b00bd9-805a-4d61-b51f-43268123d113`. All 91 EFI variables on this machine
   were listed; it is not among them.
2. **No board data on the card.** Moved the NVRAM file aside and reloaded
   `brcmfmac`: the card came up with a **random locally-administered MAC** and
   **2.4 GHz only**, logging no OTP messages at all. The file is genuinely
   mandatory, and it is what gives you 5 GHz.
3. **macOS has no BCM43602 firmware.** The macOS 15.7.9 install on
   `/dev/nvme0n1p2` was mounted read-only via `linux-apfs-rw`.
   `/usr/share/firmware/wifi/` holds only `C-4364`, `C-4377`, `C-4378`,
   `C-4387`, `C-4388` — all T2-era and Apple Silicon. This Mac's Wi-Fi works
   under macOS 15 only through OpenCore's injected legacy kexts, and Apple's
   driver reads the card's SPROM by a path `brcmfmac` does not implement.

**The one knob deliberately left alone:** `sar5g=15` is an RF human-exposure
transmit cap inherited from that other board. Raising it toward `sar2g`'s 18
would likely lift the uplink, which is the visibly weaker direction (TX ~81
Mbit/s against 240–300 Mbit/s RX). Not changed — it is a safety-related limit
and the gain is unverified. A deliberate choice available later, not an
oversight.

---

## 3.3 Suspend status

The 2015 firmware did fail D3 handshakes during earlier suspend experiments.
The old `brcmfmac-reload` system-sleep hook has since been removed. Automatic
suspend is blocked because GPU and T1 failures make the whole path unsafe, and
maintaining a Wi-Fi-specific workaround adds no benefit to the stable awake
configuration. The post-boot health check still verifies that `brcmfmac` is
loaded.

---

## Verify

```bash
iw dev wlp3s0 link                                    # signal, bitrate
grep ^ccode /lib/firmware/brcm/brcmfmac43602-pcie.txt  # ccode=BR
grep '^brcmfmac ' /proc/modules                        # loaded
journalctl -b | grep "brcmf_pcie_pm_enter_D3"          # historical suspend symptom
```
