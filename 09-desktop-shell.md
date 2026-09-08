# 09 — Desktop shell (Hyprland + quickshell)

Omarchy runs Hyprland 0.56.2 on aquamarine 0.14.0, with the desktop shell
(`omarchy-shell`) as a single **quickshell** process hosting the bar, the lock
surface, the screensaver and the idle service.

> **One process hosts all of them.** When quickshell dies, the bar, lock screen
> and screensaver all appear to fail simultaneously. That is one fault, not
> three.

---

## 9.1 ⚠️ `AQ_DRM_DEVICES` cannot contain a colon

**This one cost a login loop and CLI recovery.**

### Symptom

Every graphical login failed. sddm autologin started, Hyprland crashed, sddm
fell back to its greeter — and because omarchy themes the greeter and the
plymouth decrypt prompt identically, it looked like the machine was **stuck at
the disk decryption screen**. Decryption had in fact succeeded and the system
was fully booted.

### Evidence

```
drm: Explicit device list /dev/dri/by-path/pci-0000:01:00.0-card
ERR: Failed to canonicalize path /dev/dri/by-path/pci-0000
ERR: Failed to canonicalize path 01
ERR: Failed to canonicalize path 00.0-card
ERR: drm: Found no gpus to use, cannot continue
CRIT: Cannot open backend: no allocator available
terminate called after throwing an instance of 'std::runtime_error'
  what():  CBackend::create() failed!
```

### Cause

**Aquamarine splits `AQ_DRM_DEVICES` on `:` — not on `,`.** Every
`/dev/dri/by-path/` name embeds a PCI address full of colons, so the value was
torn into three nonexistent paths.

The `by-path` form had been chosen deliberately *because* card numbers are
unstable (they shifted twice in one day). That reasonable choice is exactly what
made the value unparseable.

### Fix

`~/.config/uwsm/env-hyprland` resolves the symlink to a **colon-free**
`/dev/dri/cardN` node before exporting, re-derived every session so no unstable
card number is baked in, and refuses any value containing a colon:

```sh
_node=$(readlink -f "/dev/dri/by-path/pci-$_pci-card")
case "$_node" in
    /dev/dri/card*) [ -e "$_node" ] && export AQ_DRM_DEVICES="$_node" && break ;;
esac
```

An unset `AQ_DRM_DEVICES` means "use every GPU", which always boots — so the
guard fails safe.

### Selecting the right card

The card holding the panel is identified by **which eDP connector has real
modes**, not by `status`. With the mux on the iGPU, the AMD card advertises a
phantom eDP that reports `connected` but is `enabled: disabled`, `dpms: Off`
and carries **zero modes** — and Hyprland will happily latch onto it at 0x0 and
display nothing.

Note also that `[ -s "$file" ]` is **always true on sysfs** (files report 4096
bytes regardless of content), so the modes test must read the content.

---

## 9.2 Plugins in use

| Plugin | Kind | Purpose |
|---|---|---|
| `rafaellnick.lock` | service | clone of `omarchy.lock`; blanks the panel 5 s after lock |
| `local.window-dock` | service | auto-hiding window dock |
| `local.idle-suspend` | service | **added 2026-09-07** — the missing suspend step (§9.3) |

Third-party plugins are enabled **iff their id appears in `shell.json`**.

> **Editing plugin QML requires `omarchy-restart-shell`, not
> `rescanPlugins`.** A rescan served a **cached QML component**, so edited code
> silently did not load — the running service reported the old schema while the
> file on disk had the new one. This wasted real debugging time and caused an
> unintended suspend. Confirm the load by reading a value only the new code
> emits.

---

## 9.3 The idle ladder, and the step that was missing

omarchy implements only **screensaver** and **lock**. There was no display-off
step visible in the shell source — but there is one, spelled as a shell call
(`omarchy-brightness-display off`) inside the lock service, fired 5 s after the
lock screen appears.

What was genuinely missing was **suspend**.

| Idle | Action |
|---|---|
| 150 s | screensaver launches (renders — costs power) |
| 300 s | lock; screensaver killed |
| ~305 s | panel + keyboard backlight off |
| **900 s** | **suspend — battery only** ← added |

### Why not `logind`

`IdleAction=suspend` keys off the session's `IdleHint`, and **a Hyprland session
never sets it** — `loginctl` reports `IdleHint=no` while genuinely idle. That
setting would sit armed forever doing nothing. Verified, not assumed.

The plugin instead uses Quickshell's `IdleMonitor` (the Wayland idle-notify
protocol) — the same source omarchy's own screensaver and lock steps use.

### Configuration

```json
{ "id": "local.idle-suspend", "timeout": 900, "cooldown": 300, "onBatteryOnly": true }
```

Policy lives in `idle-suspend.sh` so it can be read and dry-run from a terminal:

```bash
~/.config/omarchy/plugins/local.idle-suspend/idle-suspend.sh --dry-run
```

Guards: stay-awake honoured (so the toggle governs all four steps, not three);
AC skipped (an idle machine on power is usually building or syncing); idle
inhibitors respected; locks only as a **fallback** if `omarchy-sleep-lock.service`
is inactive.

### ⚠️ Two bugs found the hard way

**Do not add a lock call.** omarchy already locks before every suspend via
`omarchy-sleep-lock.service`. An earlier version locked as well, which raced
that inhibitor — during a burst of suspends the monitor could not re-arm
(`Failed to inhibit: ... already running`, restart counter 9) and **quickshell
aborted**, taking bar, lock and screensaver with it.

**A cooldown is mandatory.** A resume does not imply a person: idle-notify
restarts its clock on wake, so a wake with no user input goes idle again on its
own and re-fires. A 60 s test timeout produced **four suspends in three
minutes**. An "active" transition cannot detect this — it happens on resume
without anyone touching the machine — so the guard must be wall-clock. Enforced
at a single choke point covering both the idle path and the `now` IPC.

---

## 9.4 Bar: fan RPM widget

`applesmc` registers its hwmon node **without a `name` file**, and libsensors
skips any node lacking one. That is why `sensors`, btop and omarchy's own
monitor widget all report **zero fans** on a machine with two working ones.

`~/.config/omarchy/bar/scripts/fan-speed` reads the platform sysfs directly and
reports the busier of the two fans as a percentage of **its own** range (they
differ: 2160–5927 and 2000–5489), with CPU/GPU/SSD temps in the tooltip.

---

## Verify

```bash
tr '\0' '\n' < /proc/$(pgrep -x Hyprland)/environ | grep AQ_DRM_DEVICES  # /dev/dri/cardN, no colon
omarchy-shell shell ping
omarchy-shell idle-suspend status
~/.config/omarchy/bar/scripts/fan-speed | python3 -m json.tool
```
