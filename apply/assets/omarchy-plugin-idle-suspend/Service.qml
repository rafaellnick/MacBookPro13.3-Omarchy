import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Adds a suspend step to omarchy's idle ladder, which stops at lock.
//
// The wake-up source is Quickshell's IdleMonitor - the Wayland idle-notify
// protocol - because that is the only thing on this system that actually knows
// the session is idle. logind's IdleAction is not an option: it keys off the
// session IdleHint, which a Hyprland session never sets.
//
// This runs its own monitor rather than extending omarchy.idle's, so a package
// update cannot clobber it and a fault here cannot take the screensaver and
// lock steps down with it. Both monitors watch the same protocol; idle-notify
// is a broadcast, so two listeners is normal and they do not contend.
//
// All of the "should we really suspend" policy lives in idle-suspend.sh, where
// it can be read and dry-run from a terminal.
Item {
  id: root

  // Injected by omarchy-shell (the first-party service loader).
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginId: "local.idle-suspend"
  readonly property string suspendScript: home + "/.config/omarchy/plugins/" + pluginId + "/idle-suspend.sh"
  readonly property string stayAwakeStateDir: home + "/.local/state/omarchy/indicators"
  readonly property string stayAwakeStatePath: stayAwakeStateDir + "/stay-awake"

  readonly property int defaultTimeoutSeconds: 900

  // A resume does not imply a person. idle-notify restarts its clock when the
  // machine comes back, so a wake with no user input (an RTC alarm, a lid
  // opened and left alone, a network wake) goes idle again on its own and
  // fires this a second time. Seen for real: a 60s test timeout produced four
  // suspends in three minutes, which broke omarchy's pre-sleep lock inhibitor
  // and aborted the shell. An "active" transition cannot be used to detect
  // this - it happens on resume without anyone touching the machine - so the
  // guard has to be wall-clock: refuse to fire again this soon after the last
  // attempt, whatever the monitor says.
  readonly property int defaultCooldownSeconds: 300

  readonly property var shellConfig: shell && shell.shellConfig ? shell.shellConfig : ({})

  // Service plugins are handed `shell`, `manifest` and the registries - not
  // their own shell.json entry - so settings declared inline on the entry
  // (plugin contract rule 3) have to be looked up by id.
  readonly property var entry: entryFor(shellConfig)
  readonly property int timeoutSeconds: secondsFromConfig(entry.timeout, defaultTimeoutSeconds)
  readonly property bool onBatteryOnly: entry.onBatteryOnly === undefined ? true : !!entry.onBatteryOnly
  readonly property int cooldownSeconds: secondsFromConfig(entry.cooldown, defaultCooldownSeconds)
  readonly property bool dryRun: !!entry.dryRun

  // Matches omarchy.idle: the monitor is disarmed entirely while stay-awake is
  // set, so the indicator means the same thing for every idle step.
  readonly property bool suspendEnabled: stayAwakeStateLoaded && !stayAwake && timeoutSeconds > 0

  property bool stayAwake: false
  property bool stayAwakeStateLoaded: false
  property double lastFireAt: 0
  property string lastEvent: "starting"
  property string lastEventAt: ""

  function secondsFromConfig(value, fallback) {
    var n = Number(value)
    if (!isFinite(n) || n < 0) return fallback
    return Math.floor(n)
  }

  function entryFor(config) {
    var entries = config && config.plugins ? config.plugins : []
    for (var i = 0; i < entries.length; i++) {
      var candidate = entries[i]
      if (candidate && String(candidate.id || "") === root.pluginId) return candidate
    }
    return ({})
  }

  function logEvent(event, details) {
    var suffix = details === undefined || details === null || details === "" ? "" : ": " + String(details)
    root.lastEventAt = new Date().toISOString()
    root.lastEvent = event + suffix
    console.log("omarchy idle-suspend " + root.lastEventAt + " " + root.lastEvent)
  }

  function cooldownRemainingMs() {
    if (root.lastFireAt <= 0) return 0
    return Math.max(0, root.cooldownSeconds * 1000 - (Date.now() - root.lastFireAt))
  }

  // Single choke point: the idle monitor and the `now` IPC both land here, so
  // the cooldown cannot be bypassed by either.
  function runSuspend() {
    if (suspendProcess.running) {
      logEvent("suspend-skip", "already running")
      return
    }

    var remaining = cooldownRemainingMs()
    if (remaining > 0) {
      logEvent("suspend-skip", "cooldown, " + Math.ceil(remaining / 1000) + "s left")
      return
    }

    var command = [root.suspendScript]
    if (!root.onBatteryOnly) command.push("--any-power")
    if (root.dryRun) command.push("--dry-run")

    root.lastFireAt = Date.now()
    logEvent("suspend-start", command.join(" "))
    suspendProcess.command = ["bash", "-lc", "\"$@\"", "bash"].concat(command)
    suspendProcess.running = true
  }

  function handleIdleChanged() {
    logEvent("idle-monitor", idleMonitor.isIdle ? "idle" : "active")
    if (!root.suspendEnabled || !idleMonitor.isIdle) return
    runSuspend()
  }

  function statusJson() {
    return JSON.stringify({
      enabled: root.suspendEnabled,
      timeout: root.timeoutSeconds,
      onBatteryOnly: root.onBatteryOnly,
      cooldown: root.cooldownSeconds,
      cooldownRemainingMs: root.cooldownRemainingMs(),
      dryRun: root.dryRun,
      stayAwake: root.stayAwake,
      stayAwakeStateLoaded: root.stayAwakeStateLoaded,
      idle: idleMonitor.isIdle,
      monitorArmed: idleMonitor.enabled,
      suspendRunning: suspendProcess.running,
      script: root.suspendScript,
      lastEvent: root.lastEvent,
      lastEventAt: root.lastEventAt
    })
  }

  function applyStayAwake(value) {
    var enabled = !!value
    var changed = !root.stayAwakeStateLoaded || root.stayAwake !== enabled

    root.stayAwake = enabled
    root.stayAwakeStateLoaded = true

    if (changed) logEvent("stay-awake", enabled ? "enabled" : "disabled")
  }

  function refreshStayAwakeState() {
    if (!stayAwakeStateProbe.running) stayAwakeStateProbe.running = true
  }

  IdleMonitor {
    id: idleMonitor
    enabled: root.suspendEnabled
    timeout: root.timeoutSeconds
    // Anything holding an idle inhibitor - a video, a presentation, a long
    // running job that asked to stay up - keeps this from firing.
    respectInhibitors: true
    onIsIdleChanged: root.handleIdleChanged()
  }

  Process {
    id: suspendProcess
    stdout: SplitParser {
      onRead: function(line) { root.logEvent("script", String(line).trim()) }
    }
    onExited: function(exitCode) { root.logEvent("suspend-exit", "exitCode=" + exitCode) }
  }

  Process {
    id: stayAwakeStateProbe
    command: ["bash", "-c", "if [[ -f \"$HOME/.local/state/omarchy/indicators/stay-awake\" ]]; then echo yes; else echo no; fi"]
    stdout: SplitParser {
      onRead: function(line) { root.applyStayAwake(String(line).trim() === "yes") }
    }
    onExited: function() { stayAwakeStateDirWatcher.reload() }
  }

  FileView {
    id: stayAwakeStateDirWatcher
    path: root.stayAwakeStateDir
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshStayAwakeState()
  }

  // These are bindings on shell.shellConfig, which is not populated yet when
  // Component.onCompleted runs - so the startup line reported the DEFAULTS and
  // not the entry's real values, which is misleading when the whole point of
  // the log line is to prove which code and which settings are live. Log again
  // whenever a setting actually resolves.
  function logSettings(reason) {
    logEvent("settings", reason + ": timeout=" + root.timeoutSeconds
      + " cooldown=" + root.cooldownSeconds
      + " onBatteryOnly=" + root.onBatteryOnly
      + (root.dryRun ? " DRY-RUN" : " LIVE"))
  }

  onTimeoutSecondsChanged: logSettings("resolved")
  onCooldownSecondsChanged: logSettings("resolved")
  onDryRunChanged: logSettings("resolved")
  onOnBatteryOnlyChanged: logSettings("resolved")

  Component.onCompleted: {
    logSettings("startup-defaults")
    refreshStayAwakeState()
  }

  IpcHandler {
    target: "idle-suspend"

    function status(): string {
      return root.statusJson()
    }

    function now(): string {
      root.runSuspend()
      return "ok"
    }
  }
}
