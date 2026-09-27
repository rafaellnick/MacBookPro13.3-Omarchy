# 09 — Omarchy shell integration

All shell changes are user overrides under `~/.config/omarchy`; package-owned
files under `/usr/share/omarchy` remain untouched.

## Touch Bar idle service

`local.touchbar-idle` is a small Quickshell service plugin. Its `IdleMonitor`
turns the Touch Bar off after 10 seconds and wakes it on seat input. The lock
plugin reports lock state through the `touchbar-idle` IPC endpoint, allowing
the fingerprint surface to remain ready at the lock screen.

```json
{"id": "local.touchbar-idle", "timeout": 10}
```

Status is available with:

```bash
omarchy-shell ipc call touchbar-idle status
```

## Power widget

The right side of the bar contains a command widget that reads BAT0 current and
voltage every 10 seconds:

```json
{
  "id": "power-draw",
  "type": "command",
  "exec": "~/.config/omarchy/bar/scripts/power-draw",
  "interval": 10,
  "tooltip": "Current battery power"
}
```

The fan widget refreshes every 60 seconds. `battery-lite` is available as a
lower-wakeup replacement, but the live bar currently uses `omarchy.power` with
percentage display.

## Idle suspend

`local.idle-suspend` is registered with a 15-minute timeout, battery-only policy
and five-minute cooldown, but `dryRun` is true. This is deliberate: suspend is
unsafe on the current stack. The plugin remains useful for validating idle
detection without sleeping the machine.

## GPU selection

`~/.config/uwsm/env-hyprland` selects the DRM node owning the real internal
panel and exports `AQ_DRM_DEVICES`. It runs before Hyprland and avoids opening
the unused Radeon card. See [04-display-and-gpu.md](04-display-and-gpu.md).

The apply script installs these plugins and scripts, then edits `shell.json`
as JSON to preserve the rest of the user's layout.

## Hyprland update and bar warnings

After the Hyprland 0.56.2-2 update, `hyprpm reload` reported `hyprbars` loaded
even though Hyprland rejected it with a version mismatch. `hyprpm update -f`
rebuilt the plugin; `hyprctl plugin list` then confirmed `hyprbars` loaded and
`hyprctl configerrors` remained empty after a compositor reload. Check the
compositor state after future Hyprland updates rather than trusting the plugin
manager's success message alone.

The Omarchy shell also logs `Cannot assign to read-only property "moduleName"`
for inline command widgets. This is a known package-side issue with widgets
such as `fan` and `power-draw`; both continue to display and update. Keep the
user widgets in place and allow the packaged Omarchy fix to arrive through
normal updates.
