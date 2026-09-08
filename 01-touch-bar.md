# 01 — Touch Bar

The OLED strip, its ambient light sensor, and the T1 (iBridge) USB device they
hang off. Three separate faults, fixed on two different days.

---

## 1.1 The strip was dark at install (2026-09-06)

Two independent causes, both of which had to be fixed.

### No driver was ever built

`linux-headers` is only an **optional** dependency of `mbp133-hardware-support`,
and it was not installed. The `appleibridge` DKMS module therefore sat at status
`added` and never compiled. `dkms status` said so plainly; nothing else did.

### The service could never start

`touchbar.service` gates on
`ConditionPathExistsGlob=/sys/bus/hid/devices/0003:05AC:8600.0001`, and the
shipped script hard-codes `.0002` as the interface to reclaim from
`hid-sensor-hub`.

That trailing field is the kernel's **global HID device counter**, not a fixed
address. On this machine the two iBridge interfaces enumerate as `.0007` and
`.0008`. So the unit logged "start condition unmet" at every boot, and the
script would have targeted the wrong device even if it had run.

### Fix

- Installed `linux-headers` `7.1.9.arch1-2`, matching the running kernel exactly
  — no `pacman -Sy`, so no partial upgrade. The DKMS hook then built
  `apple-ibridge`, `apple-ib-tb` and `apple-ib-als` automatically.
- `/usr/local/sbin/touchbar-enable-dynamic.sh` — local rewrite of the packaged
  script that **discovers both iBridge interfaces at runtime** instead of
  assuming their numbers, and loads `industrialio-triggered-buffer` before
  `apple-ib-als`. That module needs `iio_triggered_buffer_setup_ext`, and
  `insmod` — unlike `modprobe` — will not resolve the dependency, so the ambient
  light sensor was failing with "Unknown symbol".
- `/etc/systemd/system/touchbar.service.d/override.conf` — widens the condition
  to `0003:05AC:8600.*` and points `ExecStart` at that script.

Settings: `fnmode=1` (media strip by default, F1–F12 while `Fn` held — matching
macOS), `idle_timeout=300`, `dim_timeout=-2`. Upstream pinned the timeouts to
`-1` (never blank) while chasing a load deadlock; that leaves an OLED lit around
the clock for no reason.

> If a future `mbp133-hardware-support` fixes this upstream, delete the drop-in
> and the script.

---

## 1.2 `mbp133-t1-check` reports two false warnings here

Both are bugs in the packaged check, not faults on this machine. Left unpatched
because `/usr/bin/mbp133-t1-check` is pacman-owned and would drift on update.

### "appleibridge not registered with DKMS"

The check runs `dkms status 2>/dev/null | grep -q '^appleibridge'` under
`set -o pipefail`. `appleibridge` is the *first* line, so `grep -q` matches and
exits immediately, `dkms` dies of **SIGPIPE**, and the pipeline returns 141. The
condition is inverted by its own success.

Capturing first fixes it: `out=$(dkms status)`, then `grep -q <<<"$out"`.

> This exact trap bit us again on 2026-09-07 in code we wrote ourselves — see
> [05-sleep-and-resume.md](05-sleep-and-resume.md) §5.3. `lsmod | grep -q` under
> `pipefail` is never safe. Read `/proc/modules` directly.

### "no Touch Bar sysfs controls — the strip is dark"

The check resolves the hardcoded path
`/sys/bus/hid/devices/0003:05AC:8600.0001`. Same global-HID-counter mistake as
above; the controls are really at `.0007`, and the check even prints that two
lines later.

Ground truth: `touchbar.service` is `active (exited)` with
`SUCCESS: fnmode=1 idle=300 dim=-2`, and `fnmode` exists at
`…/0003:05AC:8600.0007/fnmode`.

---

## 1.3 The strip went dark after resume (2026-09-07)

### Symptom

Touch Bar dark after waking from s2idle, and staying dark. Modules still loaded,
HID interfaces still bound — nothing looked wrong.

### Cause

`apple-ibridge` stops driving the strip across suspend. The state it needs is
re-established by `appletb_probe`, which only runs when the module is
(re)loaded.

Crucially, `touchbar-enable-dynamic.sh` is **not** enough here: every one of its
steps is guarded on state that survives the suspend — the modules are still
loaded, the HID interfaces are still bound to `apple-ibridge-hid`, and `fnmode`
is still readable — so it short-circuits to the end and reports SUCCESS having
done nothing.

### Fix

`/etc/systemd/system/touchbar-resume.service` (oneshot,
`WantedBy=suspend.target hibernate.target hybrid-sleep.target
suspend-then-hibernate.target`) runs `/usr/local/sbin/touchbar-resume.sh`, which
reloads `apple_ib_tb` from the unpacked module at `/run/touchbar/apple-ib-tb.ko`.

If that unpacked module is absent (i.e. `touchbar.service` has not run this
boot, since `/run` is tmpfs), the script defers to a full
`systemctl restart touchbar.service` instead.

---

## 1.4 The resume hook could be raced away (2026-09-07)

### Symptom

After two suspends in quick succession, the strip stayed dark even though the
resume service existed and worked.

### Cause — a systemd job merge

`touchbar-resume.service` is `Type=oneshot`, pulled in by
`WantedBy=suspend.target`. When a second suspend begins **while the previous
resume's run is still in flight**, systemd merges the new start job into the one
already running, and it never runs again.

Observed directly:

```
resumes:    18:09:56.062      18:11:12.605
hook runs:  18:09:57.377      (none)
```

The second suspend started at `18:09:57.35` — a **30 ms** overlap with the first
run finishing at `18:09:57.38`.

### Fix — a systemd-sleep backstop

`/usr/lib/systemd/system-sleep/touchbar-resume` is executed directly by
`systemd-sleep` for every cycle. It is not a systemd job, so there is nothing to
merge. It calls `systemctl restart --no-block touchbar-resume.service` —
`restart` supersedes a run still in flight, `--no-block` keeps resume from
waiting on an `rmmod`/`insmod`.

It is a **backstop, not a replacement**: the unit keeps its own `WantedBy`
trigger, so neither path is a single point of failure. To stop both firing and
reloading the module twice (which flashes the strip and races `rmmod` against
the previous `insmod`), `touchbar-resume.sh` debounces on
`/run/touchbar/last-resume-reload` with a 10 s window. Whichever fires first
wins; the other no-ops.

Verified in a real cycle: one `apple_ib_tb reloaded` at `20:05:43`, no double.

---

## Verify

```bash
systemctl status touchbar.service          # active (exited), SUCCESS: fnmode=1 ...
ls /sys/bus/hid/devices/ | grep 05AC:8600  # two interfaces
cat /sys/bus/hid/devices/*05AC*8600.*/fnmode 2>/dev/null
journalctl -u touchbar-resume.service -b   # one reload per resume, no doubles
```

## Files

| Path | Role |
|---|---|
| `/usr/local/sbin/touchbar-enable-dynamic.sh` | runtime interface discovery, cold bring-up |
| `/usr/local/sbin/touchbar-resume.sh` | module reload after resume + debounce |
| `/etc/systemd/system/touchbar.service.d/override.conf` | widened condition |
| `/etc/systemd/system/touchbar-resume.service` | resume trigger |
| `/usr/lib/systemd/system-sleep/touchbar-resume` | backstop trigger |
