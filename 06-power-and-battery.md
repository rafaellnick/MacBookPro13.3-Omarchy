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

### GPU clock clamp — **−4.1 W**, the largest single win

amdgpu leaves this Polaris part at its **top shader clock while reporting 0 %
busy**:

| `power_dpm_force_performance_level` | sclk | draw |
|---|---|---|
| `auto` | 855 MHz | 22.9 W |
| `low` | 214 MHz | **18.8 W** |

Applied by `/usr/local/sbin/macbook-power-tuning.sh` via
`macbook-power-tuning.service` (enabled).

**Trade-off:** mclk also drops to 300 MHz. If the panel ever flickers or video
stutters, raise the level.

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

- CPU: `governor=powersave`, `EPP=power`
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

### The iGPU switch — measured *worse*

See [10-dead-ends.md](10-dead-ends.md) §10.2. Running the panel on the Intel GPU
measured **20.69 W** against 18.7 W on AMD, because both GPUs stay powered and
amdgpu cannot runtime-suspend while the compositor holds it.

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
cat /sys/class/power_supply/ADP1/online                                   # 0 = on battery
cat /sys/class/drm/card1/device/power_dpm_force_performance_level         # low
grep '\*' /sys/class/drm/card1/device/pp_dpm_sclk                         # 214Mhz*
systemctl is-enabled macbook-power-tuning.service
omarchy-shell idle-suspend status
```
