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

## 10.2 ✅ NOT a dead end — the iGPU path, resolved

**This section used to say the iGPU switch was a loss. That was wrong, and the
mistake is instructive enough to keep.** The configuration now runs on the Intel
iGPU with the AMD card powered off, at **13.29 W against a 19.04 W baseline**.
The full writeup lives in [04-display-and-gpu.md](04-display-and-gpu.md) §4.4;
what follows is only why it looked like a dead end for a day.

### The trap: the intermediate state is genuinely worse

Moving the panel to the iGPU and stopping there measures **~2 W worse**, twice,
a day apart. Both GPUs are then powered and you pay for two. The saving is
entirely in the *second* step — switching the AMD card off — and Polaris 11 in a
gmux Mac cannot get there by itself:

```
amdgpu 0000:01:00.0: Runtime PM not available
```

No ATPX, no `_PR3`, so the `power/` directory has no `runtime_usage`,
`runtime_enabled` or `autosuspend_delay_ms` at all. Waiting for the card to
runtime-suspend, no matter how thoroughly nothing is holding it, waits forever.

### The second trap: measuring a half-built configuration

The original 20.69 W was recorded **before** the `AQ_DRM_DEVICES` pinning
existed — it was written 14 minutes after that measurement. Hyprland and
Xwayland still held the AMD card. So the number was real but the conclusion
drawn from it was not, and it was written into these docs as settled fact.

> **Lesson worth more than the watts:** a negative result measured on an
> incomplete configuration is not a negative result. Record what was actually
> in place at the time, or the number will be believed later for the wrong
> reason.

### ⚠️ The naked `echo OFF` genuinely does wedge the machine

```
echo OFF > /sys/kernel/debug/vgaswitcheroo/switch
```

On 2026-09-07 this never returned, every later read of the switch file blocked,
amdgpu sat in an uninterruptible kernel wait, and the machine had to be power
cycled. **Never run it directly.** The cause was a missing precondition — live
file descriptors on the AMD card — and `/usr/local/sbin/dgpu-power` exists to
check that precondition, plus a circuit breaker, before it writes. Use that.

### `force_igd` does not apply to this machine

Published recipes switch the mux with `options apple-gmux force_igd=1`. That
parameter arrived with the T2 **MMIO** gmux support (MacBookPro15,x / 16,x).
This machine has

```
apple_gmux: Found gmux version 4.0.29 [indexed]
```

a pre-T2 **indexed** gmux, and `modinfo -p apple_gmux` prints nothing — the
driver has no module parameters at all. The EFI-variable route
(`gpu-power-prefs`, i.e. `gpu-mode igpu`) is this generation's equivalent, so
those recipes transfer with that one substitution.

### Still true: external outputs die

Every external DisplayPort output hangs off the AMD card. On the iGPU they do
not work at all. Low power and external displays remain mutually exclusive on
this hardware — `sudo gpu-mode dgpu` plus a reboot before docking.

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
| Panel on iGPU *alone* | Works, but ~2 W **worse** — the card cannot sleep by itself |
| Panel on iGPU **+ dGPU off** | ✅ **Works. −5.75 W (−30 %).** Kills external outputs. See 04 §4.4 |
| `vgaswitcheroo` OFF, unguarded | **Wedges the kernel.** Never run directly — use `dgpu-power` |
| Touch ID | Impossible, and unsafe to probe |
| Authentic Wi-Fi NVRAM | Does not exist on this system |
| `pcie_ports=native` | Not tried — `compat` is required for USB-C after resume |
