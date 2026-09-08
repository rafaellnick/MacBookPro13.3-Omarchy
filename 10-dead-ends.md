# 10 — Dead ends

Things that are **not possible** on this machine, each with the evidence that
settled it. This module exists so none of these is attempted a second time.

---

## 10.1 Hibernate — the firmware refuses S4

### Verdict

**Impossible.** Not a configuration problem.

### Everything was configured correctly

Checked before attempting, and all correct:

| | |
|---|---|
| `resume_offset=1914441` | matches `btrfs inspect-internal map-swapfile -r` exactly |
| swapfile | 15.5 G ≥ 15 GiB RAM |
| `resume=` | `/dev/mapper/omarchy_root`, correct |
| `CanHibernate` | `yes` |

> The **zram** device is also 15.5 G but **cannot hold a hibernation image** —
> it lives in RAM.

### Attempt 1 — aborted on Thunderbolt D3cold

```
ACPI: PM: Preparing to enter system sleep state S4
ACPI: PM: Waking up from system sleep state S4
pci 0000:05:00.0:         Unable to change power state from D3cold to D0
thunderbolt 0000:06:00.0: Unable to change power state from D3cold to D0
xhci_hcd 0000:07:00.0:    Unable to change power state from D3cold to D0
tb_cfg_read: -108
WARNING: drivers/thunderbolt/ctl.c:1131 at tb_cfg_read
```

**28 devices** — both Thunderbolt controllers, their PCIe bridges and the USB
controllers behind them — dropped to D3cold and could not be brought back.

### Attempt 2 — the D3cold fix worked, and it still failed

A sleep hook set `d3cold_allowed=0` on all 12 affected devices before the
transition (the documented per-device opt-out, used by the 2016/2017 MacBook Pro
Linux notes for the same failure class on the Apple NVMe controller).

**It worked for what it targeted: D3cold failures went from 28 to 0.**

S4 still aborted, now with *no device errors at all*:

```
20:26:21.567  ACPI: PM: Preparing to enter system sleep state S4
20:26:21.570  ACPI: PM: Waking up from system sleep state S4     ← 3 ms later
```

Three milliseconds, clean, nothing left to blame. That is the Apple firmware
declining S4 itself.

### Ground truth

**No hibernation image was ever written on any attempt** —
`hibernation: writing`/`Image saved` never appears in any journal, and the
swapfile shows `0B` used. What looked like "it hibernated" was the machine going
dark mid-abort: devices torn down, nothing saved, no power-off. The password
prompt afterwards was an ordinary cold boot, not a resume.

This matches the community trackers for this generation: suspend works,
hibernate does not.

### The one lead not taken, deliberately

`pcie_ports=compat` is on the kernel command line, which is why those PCIe
bridges have **no driver bound**. Switching to `pcie_ports=native` is the
documented counter-measure for D3cold-to-D0 failures generally.

**It was not tried**, because `mbp133-t1-check` reports
`PASS  pcie_ports=compat active` under *"USB-C after resume"* — the parameter is
deliberate and load-bearing for working USB-C. Trading working USB-C for a
firmware-refused hibernate is a bad trade, and the downside of a bad boot
parameter is a machine that will not boot.

### Scaffolding removed

The `thunderbolt-d3cold` sleep hook and the `HibernateDelaySec` drop-in were
deleted once the verdict was clear. `HandleLidSwitch` is back to plain
`suspend`; the logind drop-in retains the explanation.

---

## 10.2 Running the panel on the Intel iGPU — works, but is worse

### It does work

Switching the mux via the EFI variable `gpu-power-prefs` genuinely succeeded:

```
card1-eDP-1  [i915]  connected        ← panel on the Intel GPU
mux:  0:IGD:+:Pwr:0000:00:02.0
```

Earlier attempts had failed because i915 dropped the connector at probe with
`failed to retrieve link info` — an AUX/DPCD read failure. The gmux switches the
panel's data lanes **and its AUX channel** together, so with the mux on AMD,
i915's DDI A is wired to nothing. Only a firmware-level switch resolves that
chicken-and-egg.

### But it measured *worse*

**20.69 W** on the iGPU against **18.7 W** on AMD, because both GPUs stay
powered and amdgpu cannot runtime-suspend while the compositor holds it. The
saving only materialises if the AMD card can actually be powered down.

### ⚠️ And powering the AMD card down wedges the machine

```
echo OFF > /sys/kernel/debug/vgaswitcheroo/switch
```

**Never do this.** The write never returned, subsequent reads of that file
blocked, and amdgpu was left in an uninterruptible kernel wait — taking the
machine down with it. The 13,3 guides warn about exactly this.

The safe equivalent is restricting `AQ_DRM_DEVICES` to the card holding the
panel, letting the other drop to D3cold on its own — see
[09-desktop-shell.md](09-desktop-shell.md) §9.1.

### Also: external outputs die

Every external DisplayPort output hangs off the AMD card. With the mux on the
iGPU they do not work at all. The two goals are mutually exclusive on this
hardware.

---

## 10.3 Touch ID — not possible, and dangerous to chase

The T1 exposes **three USB configurations**. Linux runs config 1 ("Default
iBridge Interfaces": two UVC video interfaces plus two HID). macOS uses config
2, which adds CDC-NCM ethernet and a **vendor-specific interface, class `0xff`
subclass `0xf9` protocol `0x11`** — that is where Touch ID lives.

Reading the iBridge HID keybits directly confirms Linux sees only ESC, F1–F12,
brightness, keyboard illumination, media and volume keys. **No biometric event
of any kind reaches the host.**

Why it cannot be bridged: matching happens inside the T1's Secure Enclave, the
sensor is cryptographically paired to it, the template never leaves the chip,
and enrollment is bound to macOS over an authenticated pairing channel.

Every project that would host such a driver — Dunedan's tracker, xtocdra's
macbookpro13-2, t1-touchbar, t2linux/apple-ib-drv — lists Touch ID as "not
working" with no active work. libfprint has no Apple device at all. Asahi has
not achieved it on Apple Silicon either, with full-time engineers.

> **⚠️ Do not switch the T1 to USB configuration 2** to reach those interfaces.
> It detaches `uvcvideo` and the working `apple-ibridge` HID bindings — you would
> lose the camera and Touch Bar and gain nothing. Poking the T1 is a known way to
> hang these machines.

Touch ID continues to work normally when booted into macOS.

**The practical substitute** is `/etc/sudoers.d/10-timestamp` — see
[07-input-devices.md](07-input-devices.md) §7.3. The stronger option, if wanted
later, is a **FIDO2 key with `pam-u2f`**: tap to authenticate for sudo, polkit
and the lock screen, and `systemd-cryptenroll --fido2-device=auto` would
additionally unlock the LUKS root at boot — something Touch ID never did here.

Howdy via the built-in camera is possible but that camera is **RGB-only with no
IR**, so it is defeatable by a photograph. Convenience only, never login.

---

## 10.4 Authentic Wi-Fi NVRAM — cannot be recovered

Three independent findings rule out every source. Full evidence in
[03-wifi.md](03-wifi.md) §3.2.

---

## 10.5 Summary

| Attempted | Verdict |
|---|---|
| Hibernate / S4 | **Impossible** — firmware refuses, 3 ms abort with no device errors |
| Panel on iGPU | Works, but measured worse and kills external outputs |
| `vgaswitcheroo` OFF | **Wedges the kernel.** Never run |
| Touch ID | Impossible, and unsafe to probe |
| Authentic Wi-Fi NVRAM | Does not exist on this system |
| `pcie_ports=native` | Not tried — `compat` is required for USB-C after resume |
