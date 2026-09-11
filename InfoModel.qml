import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root
  property int refreshMs: 4000
  property bool active: true
  property bool demoMode: false
  property var snap: ({})
  readonly property var cluster: snap.cluster || ({})
  readonly property double fetchedAtMs: Number(cluster.fetchedAtMs || 0)
  property double nowMs: Date.now()
  property bool ready: false
  property string error: ""
  readonly property string title: Quickshell.env("CLUSTER_DESK_TITLE") || "CLUSTER DESK"
  property string collectorPath: decodeURIComponent(Qt.resolvedUrl("collector.ts").toString().replace(/^file:\/\//, ""))
  property bool bunAvailable: true
  property bool bunChecked: false
  readonly property string missingDependencyHint: "Install bun: omarchy pkg add bun"
  Timer { interval: 1000; running: root.active; repeat: true; onTriggered: root.nowMs = Date.now() }
  function plainText(value, limit) { return String(value || "").slice(0, limit).replace(/[\u0000-\u001f\u007f]/g, " ") }
  // --- theme ---------------------------------------------------------------
  // Omarchy's Color singleton gives fg/bg/accent/urgent/muted. The ANSI roles
  // (green/yellow/red/blue…) live in the theme's colors.toml; read them here
  // with fallbacks so any theme works even if it omits a key.
  property color green: Color.accent
  property color yellow: Color.foreground
  property color red: Color.urgent
  property color blue: Color.accent
  property color magenta: Color.accent
  property color cyan: Color.accent
  property color themeBackground: Color.background
  property color themeForeground: Color.foreground

  function parseColors(text) {
    var map = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([A-Za-z0-9_]+)\s*=\s*"?(#[0-9A-Fa-f]{6,8})"?/)
      if (m) map[m[1].toLowerCase()] = m[2]
    }
    function pick(keys, fallback) {
      for (var k = 0; k < keys.length; k++) if (map[keys[k]]) return map[keys[k]]
      return fallback
    }
    green = pick(["green", "color2"], Color.accent)
    yellow = pick(["yellow", "color3"], Color.foreground)
    red = pick(["red", "color1"], Color.urgent)
    blue = pick(["blue", "color4"], Color.accent)
    magenta = pick(["magenta", "color5"], Color.accent)
    cyan = pick(["cyan", "color6"], Color.accent)
    themeBackground = pick(["background"], Color.background)
    themeForeground = pick(["foreground"], Color.foreground)
  }

  FileView {
    id: colorsFile
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.parseColors(text())
    onFileChanged: reload()
  }
  // The theme dir is a symlink swap; watching the file alone can miss it.
  // Color.* changes when the shell learns about a new theme → re-read.
  Connections {
    target: Color
    function onAccentChanged() { colorsFile.reload() }
    function onBackgroundChanged() { colorsFile.reload() }
    function onForegroundChanged() { colorsFile.reload() }
  }

  // --- collector -----------------------------------------------------------
  Process {
    id: collector
    property string lastStderr: ""
    property string outputBuffer: ""
    property int outputBytes: 0
    property int stderrBytes: 0
    property bool protocolFailed: false
    property bool frameComplete: false
    readonly property int maxOutputBytes: 2 * 1024 * 1024
    readonly property int maxStderrBytes: 4096
    command: root.demoMode
      ? ["bun", root.collectorPath, "--demo"]
      : ["bun", root.collectorPath]

    function fail(message) {
      protocolFailed = true
      outputBuffer = ""
      outputBytes = 0
      root.error = root.plainText(message, 256)
      root.snap = ({})
      if (running) running = false
    }
    function acceptStdout(rawLine) {
      if (protocolFailed || frameComplete) return
      var line = String(rawLine || "")
      // Producer frames are 12 KiB; refuse a malformed line before parsing it.
      if (line.length > 65536) { fail("collector frame exceeded 64 KiB"); return }
      var frame
      try { frame = JSON.parse(line) }
      catch (e) { fail("bad collector frame"); return }
      if (!frame || frame.v !== 1) { fail("unsupported collector protocol"); return }
      if (frame.type === "error") { fail(frame.message || "collector failed safely"); return }
      if (frame.type === "chunk" && typeof frame.data === "string") {
        // QString is UTF-16. Counting two bytes per code unit is a hard cap on
        // the shell-side accumulation, independent of collector input.
        var added = frame.data.length * 2
        if (outputBytes + added > maxOutputBytes) { fail("collector output exceeded 2 MiB"); return }
        outputBuffer += frame.data
        outputBytes += added
        return
      }
      if (frame.type !== "end" || Number(frame.chars) !== outputBuffer.length) { fail("incomplete collector snapshot"); return }
      try {
        // ready first: onSnapChanged consumers (notification dispatch) check
        // it, and the first snapshot after a restart carried events that were
        // dropped because ready flipped a line too late.
        var parsed = JSON.parse(outputBuffer)
        root.ready = true
        root.snap = parsed
        root.error = parsed.error || ""
        frameComplete = true
        outputBuffer = ""
        outputBytes = 0
      } catch (e2) { fail("bad snapshot: " + root.plainText(e2, 160)) }
    }
    function acceptStderr(rawLine) {
      if (stderrBytes >= maxStderrBytes) return
      var line = root.plainText(String(rawLine || ""), 512)
      var added = Math.min(maxStderrBytes - stderrBytes, line.length * 2)
      if (added <= 0) return
      lastStderr += line.slice(0, Math.floor(added / 2))
      stderrBytes += added
    }
    onRunningChanged: if (running) {
      outputBuffer = ""
      outputBytes = 0
      stderrBytes = 0
      lastStderr = ""
      protocolFailed = false
      frameComplete = false
    }
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { collector.acceptStdout(line) }
    }
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { collector.acceptStderr(line) }
    }
    onExited: function(exitCode) {
      if (collector.protocolFailed) return
      if (!collector.frameComplete) { root.snap = ({}); root.error = collector.lastStderr || (exitCode === 0 ? "collector ended without a complete snapshot" : "collector exited " + exitCode) }
    }
  }
  function refresh() {
    if (!root.active || collector.running || bunProbe.running) return
    if (root.bunChecked && root.bunAvailable) collector.running = true
    else bunProbe.running = true
  }
  Process {
    id: bunProbe
    command: ["sh", "-c", "command -v bun >/dev/null 2>&1"]
    onExited: function(exitCode) {
      root.bunChecked = true
      root.bunAvailable = exitCode === 0
      if (root.bunAvailable) { if (!collector.running) collector.running = true }
      else root.error = root.missingDependencyHint
    }
  }

  Timer {
    interval: root.refreshMs
    running: root.active
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  function bytes(n) {
    n = Number(n || 0)
    var u = ["B", "K", "M", "G", "T"], i = 0
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++ }
    return (i === 0 ? n.toFixed(0) : n.toFixed(n >= 100 ? 0 : 1)) + u[i]
  }
}
