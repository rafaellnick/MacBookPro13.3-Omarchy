# 06 — Power and battery

The battery is at **67.7 % of design capacity after 1245 cycles**. Every
software lever below has been pulled; the remaining gap is hardware.

All figures were measured at the battery terminals while **discharging**, idle
desktop. **Measurement noise floor is ±0.2 W** — anything smaller is not a
result.

---

## 6.1 ⚠️ How to measure correctly

```bash
B=/sys/class/power_supply/BAT0
t=0; for i in $(seq 1 12); do
  V=$(cat $B/voltage_now); I=$(cat $B/current_now)
  t=$(awk "BEGIN{print $t + $V*$I/1e12}"); sleep 1.5
done; awk "BEGIN{printf \"%.2f W\n\", $t/12}"
```

**On AC, `current_now` is CHARGE current, not consumption.** A reading taken
while plugged in is meaningless — this produced a bogus "39 W" during testing.
Always check `/sys/class/power_supply/ADP1/online` is `0` first.

Beware also that a busy foreground process inflates every figure, and that
omarchy's screensaver can start mid-measurement and contaminate it.

---

## 6.2 What actually saved power

### Powering the dGPU off — **−5.75 W**, the largest single win

Moving the panel to the Intel iGPU and switching the AMD card off with
`vga_switcheroo` takes idle from **19.04 W to 13.29 W**, a 30 % cut. It is worth
more than everything else on this page combined, and it costs you external
display output entirely.

Full measurements, mechanism, guard rails and the reason the obvious version of
this wedges the machine: [04-display-and-gpu.md](04-display-and-gpu.md) §4.4.

Note this **supersedes** the clock clamp below whenever it is active — a card
that is powered off has no clocks to clamp, and writes to its sysfs return
`EBUSY`. The clamp still matters in `dgpu` mode, which is what you run when
docked.

### GPU clock clamp — **−4.1 W**, the largest win *in `dgpu` mode*

amdgpu leaves this Polaris part at its **top shader clock while reporting 0 %
busy**:

| `power_dpm_force_performance_level` | sclk | draw |
|---|---|---|
| `auto` | 855 MHz | 22.9 W |
| `low` | 214 MHz | **18.8 W** |

Applied by `/usr/local/sbin/macbook-power-tuning.sh` via
`macbook-power-tuning.service` (enabled) **and** by TLP — see below. Both are
in place deliberately; the service covers boot, TLP covers every AC/battery
transition.

**Trade-off:** mclk also drops to 300 MHz. If the panel ever flickers or video
stutters, raise the level.

Re-measured 2026-09-08 in a clean window with Chrome closed: 22.98 → 19.47 W,
i.e. **−3.5 W**. The −4.1 W above was the first round; treat the win as
3.5–4.5 W.

### ⚠️ TLP, and how it silently undid the clamp

TLP was installed 2026-09-08 (`power-profiles-daemon` is inactive; the two must
never both run). Its stock config contains:

```
RADEON_DPM_PERF_LEVEL_ON_AC=auto
RADEON_DPM_PERF_LEVEL_ON_BAT=auto
```

**TLP writes that on every run and every AC↔battery transition**, so it
overwrote `low` within minutes of being installed and the 3.5 W came back as a
mystery regression. Fixed natively rather than fought:

`/etc/tlp.d/01-macbook-power.conf`

```
RADEON_DPM_PERF_LEVEL_ON_AC=low
RADEON_DPM_PERF_LEVEL_ON_BAT=low
CPU_BOOST_ON_BAT=0
CPU_HWP_DYN_BOOST_ON_BAT=0
```

`CPU_BOOST_ON_BAT=0` caps at base clock (2.7 GHz) on battery. **No effect at
idle** — turbo does not engage there — and ~0.8 W under a browser load. Remove
it if the machine feels sluggish unplugged.

Deliberately *not* set, with reasons:

- `CPU_ENERGY_PERF_POLICY_ON_BAT=power` — A/B'd at idle: 23.52 → 23.37 W, i.e.
  inside the noise floor, and a repeat run came out *higher*. **No result.**
  Left at TLP's `balance_power` default.
- `PCIE_ASPM_*` — ASPM is BIOS-controlled here; the sysfs knob is read-only.
- amdgpu runtime PM — correctly on TLP's denylist by default while the dGPU
  drives the panel. It could never suspend anyway.

### Panel backlight — a **3.1 W** span, the biggest lever available

| Backlight | Draw |
|---|---|
| 75 % | 19.43 W |
| 50 % | 18.84 W |
| 30 % | 17.41 W |
| 10 % | 16.36 W |

Monotonic and clean — the most trustworthy measurement taken.

Exploited by `~/.config/omarchy/hooks/battery-low.d/dim-panel-on-low-battery.hook`,
which caps the panel at 30 % when omarchy fires its low-battery warning (10 %,
discharging, once per discharge). Worth ~2 W exactly when it matters. It only
ever dims, never raises, and no-ops if already below the cap.

### Idle suspend — **~19 W → ~1 W**, by far the largest saving

The idle ladder had no suspend step at all. Added 2026-09-07; see
[09-desktop-shell.md](09-desktop-shell.md) §9.3.

### Already correct before any of this

- CPU: `governor=powersave`. EPP is now TLP's (`balance_performance` on AC,
  `balance_power` on battery) — the earlier `EPP=power` claim was overtaken,
  and the A/B above shows it makes no measurable difference either way.
- ASPM **L1 enabled on every link** (NVMe, Wi-Fi, both bridges)
- USB autosuspend active, nothing stuck on
- `snd_hda_intel power_save=10`
- `systemd-oomd` active
- btrfs: `noatime,compress=zstd:3,space_cache=v2,ssd`

---

## 6.3 What did not help

### PCI runtime PM — **inconclusive, reverted**

Setting `power/control=auto` on 34 PCI devices (excluding the USB host
controllers, which carry the T1) suspended 16 of them but measured:

```
A/B/A:  19.45 → 19.93 → 19.46 W
```

That reads as ~0.5 W **worse**, but a later triple-read of plain idle gave
`19.96 / 19.78 / 19.89` — the baseline itself had drifted, because the
screensaver launched mid-measurement.

**Honest verdict: inconclusive, not a clean negative.** Reverted either way. The
USB controllers were deliberately excluded — a wedged xhci resume costs input,
not watts.

### Bluetooth idle

Running with nothing connected. Turning it off is a real but **sub-noise-floor**
saving — no number is quoted because none could be measured.

### The iGPU switch *on its own* — measured worse, and that was the whole trap

Running the panel on the Intel GPU while leaving the AMD card powered measured
**21.23 W** against 19.04 W on AMD, because both GPUs stay powered. That result
is real and reproducible — it was measured twice, a day apart — but it is **not**
the verdict on the iGPU path. Switching the card off afterwards takes it to
13.29 W. See [04-display-and-gpu.md](04-display-and-gpu.md) §4.4.

---

## 6.4 Battery health — and why charge limiting is impossible

```
design capacity : 6669000
current full    : 4515000   → 67.7 %
cycle count     : 1245
```

`/sys/class/power_supply/BAT0/` exposes **no `charge_control_*` attributes at
all**. Intel Macs do not support charge thresholds under Linux, so the common
"cap at 80 %" longevity trick is unavailable. This was checked, not assumed.

The software work here is finished. The remaining improvement is a new battery.

---

## Verify

```bash
sudo dgpu-power status                                                    # 1:DIS: :Off:  D3cold
systemctl is-active tlp; systemctl is-active power-profiles-daemon         # active / inactive
cat /sys/class/power_supply/ADP1/online                                   # 0 = on battery
cat /sys/class/drm/card1/device/power_dpm_force_performance_level         # low
grep '\*' /sys/class/drm/card1/device/pp_dpm_sclk                         # 214Mhz*
systemctl is-enabled macbook-power-tuning.service
omarchy-shell idle-suspend status
```
