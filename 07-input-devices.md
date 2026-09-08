# 07 — Input devices (keyboard and trackpad)

Both the internal keyboard and the trackpad are driven by a **single** module,
`applespi`, over SPI at `spi-APP000D:00`.

> **That single fact governs everything here.** Losing `applespi` costs keyboard
> *and* trackpad together, which is why the resume fix is deliberately
> conservative.

---

## 7.1 Trackpad dead after resume

### Symptom

Trackpad unresponsive after waking from s2idle. The device is **still present
and still bound** — `Apple SPI Touchpad` appears in `/proc/bus/input/devices`,
the driver is attached — so nothing looks wrong.

### Evidence

```
applespi spi-APP000D:00: Received corrupted packet
                         (invalid message length 8 - num-fingers 0, tp-len 48)
applespi_got_data: 375 callbacks suppressed
```

Measured at **40 corrupted packets per minute** after the 20:01→20:05 suspend.

### Cause

The SPI stream desynchronises across suspend. Every packet is rejected, so no
input events are produced. The link needs the driver's mode switch re-run, which
only happens at probe.

### Fix

`/usr/lib/systemd/system-sleep/applespi-reload` reloads the module on resume.
Success is visible as `applespi spi-APP000D:00: modeswitch done.` and the
corrupted-packet rate returning to **0**.

### Two deliberate design choices

**`post` only — never `pre`.** Unlike `brcmfmac`, `applespi` does **not** block
suspend; the same cycle recorded 0 aborts. So there is no reason to unload on
the way down, and a strong reason not to: the window in which the internal
keyboard is absent should be as short as possible, and only while the machine is
already coming back up.

**Retries up to 3×.** A single failed `modprobe` would cost keyboard and
trackpad together. The hook retries, and logs
`FAILED to reload - internal keyboard and trackpad may be unavailable` if all
attempts fail.

It debounces on `/run/applespi-reload.stamp` with a 10 s window, because
`suspend-then-hibernate` fires post hooks more than once per cycle.

### Manual recovery

If the trackpad is ever dead and the hook did not fire:

```bash
sudo modprobe -r applespi && sleep 1 && sudo modprobe applespi
```

Safe to run from a terminal — you keep the shell you already have, and both
devices return within a second or two.

---

## 7.2 Function key behaviour

`/etc/modprobe.d/hid_apple.conf` sets `options hid_apple fnmode=2`.

The Touch Bar strip has its own, separate `fnmode=1` (media by default, F-keys
with `Fn` held) applied as an `apple_ib_tb` module parameter — see
[01-touch-bar.md](01-touch-bar.md).

---

## 7.3 Touch ID

**Not possible.** Full evidence in [10-dead-ends.md](10-dead-ends.md) §10.3,
including why it must not be chased by switching the T1's USB configuration.

The practical substitute in use is `/etc/sudoers.d/10-timestamp`:

```
Defaults timestamp_timeout=60
Defaults timestamp_type=global
```

One password per hour shared across all terminals, instead of sudo's default of
5 minutes tracked **separately per TTY** — that per-terminal re-prompting is most
of the friction a fingerprint reader would have removed.

---

## Verify

```bash
grep -E "Apple SPI" /proc/bus/input/devices        # Keyboard and Touchpad
basename $(readlink -f /sys/bus/spi/devices/spi-APP000D:00/driver)   # applespi
journalctl -b | grep -c "Received corrupted packet"                  # 0
journalctl -b | grep "applespi-reload"                               # one per resume
```
