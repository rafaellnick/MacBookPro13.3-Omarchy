#!/bin/bash
# Last step of omarchy's idle ladder: screensaver (150s) -> lock (300s) ->
# display off (~305s) -> suspend (this).
#
# omarchy's idle service implements only the screensaver and lock steps, and
# logind's IdleAction cannot cover the gap: it fires on the session's IdleHint,
# which a Hyprland session never sets (loginctl reports IdleHint=no while
# idle), so IdleAction=suspend would sit armed forever. The wake-up is instead
# driven by the shell's own IdleMonitor, which reads the Wayland idle-notify
# protocol - the same source the screensaver and lock steps already use.
#
# DO NOT ADD A LOCK CALL HERE. omarchy already locks before every suspend:
# omarchy-sleep-lock.service holds a `systemd-inhibit --what=sleep --mode=delay`
# lock and runs omarchy-system-sleep-lock when logind broadcasts
# PrepareForSleep. An earlier version of this script called
# omarchy-system-lock itself, which raced that path - during a burst of
# suspends the monitor kept trying to re-arm its inhibitor while a sleep was
# already in flight ("Failed to inhibit: The operation inhibition has been
# requested for is already running"), restarted 9 times, and the shell process
# holding the bar, lock surface and screensaver aborted. The only lock here is
# the fallback below, for when that service is not running at all.
#
# Guards live in this script rather than in QML so the decision can be read and
# tested from a shell:
#
#   idle-suspend.sh --dry-run     print the verdict, suspend nothing

set -uo pipefail

dry_run=0
battery_only=1

while (( $# > 0 )); do
  case "$1" in
  --dry-run) dry_run=1; shift ;;
  --any-power) battery_only=0; shift ;;
  *) echo "idle-suspend: unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { echo "idle-suspend: $*"; }

# Stay-awake is omarchy's own "do not idle" switch, shared with the screensaver
# and lock steps. The plugin already disarms its monitor when it is set; this
# re-check exists so a manual or misconfigured invocation obeys it too.
if [[ -f "$HOME/.local/state/omarchy/indicators/stay-awake" ]]; then
  say "skip: stay-awake is on"
  exit 0
fi

# An idle machine on AC is usually a machine working slowly with nobody typing
# - a build, a sync, a long download. Suspending that costs more than the power
# it saves. The battery is the thing worth protecting, so that is the only
# state this acts in by default.
if (( battery_only )); then
  on_ac=0
  for f in /sys/class/power_supply/A*/online; do
    [[ -r $f ]] || continue
    [[ $(cat "$f" 2>/dev/null) == 1 ]] && on_ac=1
  done
  if (( on_ac )); then
    say "skip: on AC"
    exit 0
  fi
fi

# Fallback only. In normal operation omarchy-sleep-lock.service locks on the
# PrepareForSleep signal and this branch is never taken; locking here as well
# is what caused the crash described above. If that service is dead, nothing
# else will lock, and resuming onto an unlocked desktop is the worse outcome.
if ! systemctl --user is-active --quiet omarchy-sleep-lock.service; then
  say "omarchy-sleep-lock.service is not active - locking here instead"
  if (( dry_run == 0 )); then
    omarchy-system-lock
    sleep 1
  fi
fi

if (( dry_run )); then
  say "would suspend now"
  exit 0
fi

say "suspending"
# No -i: a block inhibitor means something explicitly asked the machine to stay
# up, and overriding that is not this script's call.
systemctl suspend
