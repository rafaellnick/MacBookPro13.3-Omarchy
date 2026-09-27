import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// The T1Bridge renderer already knows how to turn the OLED off when its
// desktop provider reports display power off. Publish a second, short idle
// state from Wayland's idle-notify protocol so no input device polling is
// needed. The provider combines this with the real panel DPMS state.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: "local.touchbar-idle"
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR")
  readonly property string statePath: runtimeDir + "/t1bridge-touchbar-awake"
  readonly property string lockStatePath: runtimeDir + "/t1bridge-touchbar-lock"
  readonly property var shellConfig: shell && shell.shellConfig ? shell.shellConfig : ({})
  readonly property var entry: entryFor(shellConfig)
  readonly property int timeoutSeconds: secondsFromConfig(entry.timeout, 10)

  property bool awake: true
  property bool lockActive: false
  property int publishedMode: 1
  property int pendingMode: 1
  property bool hasPendingWrite: false
  property string lastEventAt: ""

  function entryFor(config) {
    var entries = config && config.plugins ? config.plugins : []
    for (var i = 0; i < entries.length; i++) {
      var candidate = entries[i]
      if (candidate && String(candidate.id || "") === root.pluginId) return candidate
    }
    return ({})
  }

  function secondsFromConfig(value, fallback) {
    var n = Number(value)
    if (!isFinite(n) || n < 1) return fallback
    return Math.floor(n)
  }

  function publishCurrentState() {
    // Mode 2 asks the desktop provider to keep the Touch Bar available even
    // after the lock screen powers down the main panel. Mode 1 follows panel
    // power, and mode 0 is the normal short-idle blanking state.
    var mode = root.lockActive ? 2 : (idleMonitor.isIdle ? 0 : 1)
    root.publishedMode = mode
    root.awake = mode !== 0
    root.lastEventAt = new Date().toISOString()
    console.log("touchbar idle " + root.lastEventAt + " "
      + (mode === 2 ? "lock-auth" : (root.awake ? "awake" : "blank")))

    if (stateWriter.running) {
      root.pendingMode = mode
      root.hasPendingWrite = true
      return
    }
    root.writeState(mode)
  }

  function writeState(mode) {
    stateWriter.command = [
      "/usr/bin/bash", "-c",
      "umask 077; printf '%s %s\\n' \"$1\" \"$PPID\" > \"$2.tmp\" && mv -f \"$2.tmp\" \"$2\"",
      "touchbar-idle", String(mode), root.statePath
    ]
    stateWriter.running = true
  }

  IdleMonitor {
    id: idleMonitor
    enabled: root.timeoutSeconds > 0
    timeout: root.timeoutSeconds
    // A video may inhibit the main screensaver, but the small OLED can still
    // turn off safely and wake on the next seat input.
    respectInhibitors: false
    onIsIdleChanged: root.publishCurrentState()
  }

  FileView {
    id: lockState
    path: root.lockStatePath
    watchChanges: true
    printErrors: false

    function applyState() {
      var fields = String(text() || "").trim().split(/\s+/)
      root.lockActive = fields.length >= 1 && fields[0] === "1"
    }

    onLoaded: applyState()
    onFileChanged: reload()
    onLoadFailed: root.lockActive = false
  }

  Process {
    id: stateWriter
    onExited: function() {
      if (!root.hasPendingWrite) return
      var mode = root.pendingMode
      root.hasPendingWrite = false
      root.writeState(mode)
    }
  }

  onLockActiveChanged: root.publishCurrentState()

  Component.onCompleted: root.publishCurrentState()

  IpcHandler {
    target: "touchbar-idle"

    function lockState(active: string): string {
      var next = active === "1" || active === "true"
      if (root.lockActive === next) root.publishCurrentState()
      else root.lockActive = next
      return next ? "lock-auth" : "normal"
    }

    function status(): string {
      return JSON.stringify({
        enabled: idleMonitor.enabled,
        timeout: root.timeoutSeconds,
        idle: idleMonitor.isIdle,
        awake: root.awake,
        mode: root.publishedMode,
        lockActive: root.lockActive,
        statePath: root.statePath,
        lastEventAt: root.lastEventAt
      })
    }
  }
}
