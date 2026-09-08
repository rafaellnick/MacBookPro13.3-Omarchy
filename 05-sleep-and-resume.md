# 05 — Sleep and resume

The largest module, because **suspend was completely broken on this machine
until 2026-09-07** and nothing said so clearly.

Three separate devices do not survive a suspend cycle on their own. Each needed
its own fix, and one of them was preventing the machine from sleeping at all.

| Device | Symptom | Fix |
|---|---|---|
| Broadcom Wi-Fi | **aborted every suspend**, wake loop | unload across sleep (§5.1) |
| Touch Bar | strip dark after resume | reload module (see [01](01-touch-bar.md) §1.3) |
| `applespi` trackpad | SPI stream desync | reload module (see [07](07-input-devices.md)) |

Sleep mode is **s2idle**, forced by `mem_sleep_default=s2idle` on the kernel
command line and `MemorySleepMode=s2idle` in
`/etc/systemd/sleep.conf.d/10-macbook-s2idle.conf`. The `deep` path showed
`amdgpu: PM: failed to resume async: error -22` on every cycle; s2idle resumes
cleanly.

**Hibernate is impossible on this hardware** — see
[10-dead-ends.md](10-dead-ends.md) §10.1.

---

## 5.1 Wi-Fi aborted every suspend (the big one)

### Symptom

Close the lid and the machine would sleep, wake ~3 s later, sleep again, ~every
30 s indefinitely. Wi-Fi would then be "spotty" — scans failing — until reboot.

Both symptoms were the same bug.

### Evidence

```
brcmfmac 0000:03:00.0: brcmf_pcie_pm_enter_D3: Timeout on response for entering D3 substate
brcmfmac 0000:03:00.0: PM: pci_pm_suspend(): brcmf_pcie_pm_enter_D3 returns -5
brcmfmac 0000:03:00.0: PM: failed to suspend async: error -5
PM: Some devices failed to suspend, or early wake event detected
systemd-sleep: Failed to put system to sleep. System resumed again: Input/output error
```

### Cause

The BCM43602 firmware (**7.35.177.61, built Nov 2015**) never answers the D3
handshake. The kernel therefore **aborts the entire suspend**, and `logind`
retries about 25 s later — producing the loop.

Each aborted suspend also leaves the firmware wedged, which is the "spotty
Wi-Fi": scans start returning `-12` (ENOMEM) and never recover until the module
is reloaded.

**This was not intermittent: 241 D3 failures across 250 suspend attempts.**

### Fix

`/usr/lib/systemd/system-sleep/brcmfmac-reload`

- `pre` → `modprobe -r brcmfmac_wcc brcmfmac` (wcc first, it depends on brcmfmac)
- `post` → `modprobe brcmfmac`

With no driver bound there is no D3 handshake to time out, and the post-resume
load reinitialises the firmware from scratch.

**Cost:** Wi-Fi reconnects a few seconds after resume — measured **7 s** to
reassociate with the same SSID.

Everything is timed out and best-effort: if an unload fails, sleep proceeds
exactly as before rather than being blocked by the hook.

### Verified in a real cycle

```
20:01:21  brcmfmac-reload: unloaded before suspend-then-hibernate
20:05:42  brcmfmac-reload: loaded after suspend-then-hibernate
          → 0 aborts, a real 4m20s sleep
```

### What did not help

- **WoWLAN** was already disabled — not the cause.
- The card advertises full `PME(D0+,D1+,D2+,D3hot+,D3cold+)` support, so this is
  a firmware behaviour, not a missing capability.

---

## 5.2 The suspend loop also broke other things

Worth recording because the secondary damage looked like unrelated faults:

- `omarchy-sleep-lock.service` takes a `systemd-inhibit --what=sleep
  --mode=delay` lock, handles one `PrepareForSleep`, then exits and relies on
  `Restart=always` to re-arm. With suspends only ~80 s apart it kept trying to
  re-arm **while a sleep was already in flight**:
  `Failed to inhibit: The operation inhibition has been requested for is already
  running` — restart counter reached 9.
- `quickshell` (which hosts the bar, lock surface **and** screensaver) aborted
  with SIGABRT under that churn. All three appear to fail at once because they
  are one process.

Both were consequences of the Wi-Fi bug, and both stopped once suspend worked.

---

## 5.3 ⚠️ Two bugs in the sleep hooks themselves

Recorded because both are invisible to a syntax check and both were self-inflicted.

### `set -o pipefail` + `grep -q` inverts every module test

```bash
# WRONG — under `set -o pipefail` this is inverted
if ! lsmod | grep -q '^brcmfmac '; then ...
```

`grep -q` exits on its first match and closes the pipe. `lsmod` then dies of
**SIGPIPE (141)**, and `pipefail` makes that the pipeline's exit status. The
test returns the opposite of the truth.

Consequences before it was caught: the **unload never ran**, and
**NetworkManager was restarted on every single resume**.

It passed an interactive test because `pipefail` is not set in an interactive
shell. Only `bash -x` on the real script exposed it.

```bash
# RIGHT — no pipeline
if ! grep -q '^brcmfmac ' /proc/modules; then ...
```

> This is the **same trap** that produces a false warning in the packaged
> `mbp133-t1-check` — see [01-touch-bar.md](01-touch-bar.md) §1.2. It is
> apparently easy to write twice.

### `${((expr))}` is a runtime failure that `bash -n` accepts

```bash
echo "reloaded ${((now - last))}s ago"   # bash: bad substitution — at RUNTIME
echo "reloaded $((now - last))s ago"     # correct
```

`bash -n` parses it happily. **A syntax check does not validate these scripts.**
Exercise the actual code path.

---

## 5.4 Hooks currently installed

`/usr/lib/systemd/system-sleep/` — executed directly by `systemd-sleep` once per
cycle, with `$1` = `pre`|`post` and `$2` = the sleep type.

| Hook | When | Why there and not a unit |
|---|---|---|
| `brcmfmac-reload` | pre + post | must bracket the sleep itself |
| `touchbar-resume` | post | **backstop** — systemd merged the unit's job away (see [01](01-touch-bar.md) §1.4) |
| `applespi-reload` | post only | `applespi` does not block suspend, and it owns the **internal keyboard** — minimise the window it is absent |

All three are idempotent: `suspend-then-hibernate` invokes sleep hooks **more
than once per cycle** (the action goes `suspend` → `hibernate`), so repeat-safety
is required, not optional.

---

## 5.5 Lid behaviour

| Setting | Value | File |
|---|---|---|
| `HandleLidSwitch` | `suspend` | `40-lid-suspend-then-hibernate.conf` (now disarmed to plain suspend) |
| `HandleLidSwitchDocked` | `suspend` | `30-lid-suspend-when-docked.conf` |
| `HandlePowerKey` | `ignore` | `10-ignore-power-button.conf` |
| `InhibitDelayMaxSec` | `15` | `20-inhibit-delay.conf` |

`suspend-then-hibernate` was configured and then **reverted** once hibernate was
proven impossible. The drop-in retains the explanation.

---

## Verify

```bash
# a real cycle should show zero of these
journalctl -b | grep -c "Failed to put system to sleep"
journalctl -b | grep -c "brcmf_pcie_pm_enter_D3"

# and the hooks firing once each
journalctl -b | grep -E "brcmfmac-reload|apple_ib_tb reloaded|applespi-reload"

cat /sys/power/mem_sleep          # [s2idle] deep
```
