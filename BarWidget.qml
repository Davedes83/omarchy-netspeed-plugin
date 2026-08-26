import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "davedes.netspeed"

  readonly property var sizeSteps: [10, 12, 14, 16, 18]
  readonly property int minSize: 8
  readonly property int maxSize: 28

  // shell.json settings arrive as untyped JSON: reject non-numeric values
  // and clamp the result before anything depends on it
  function intSetting(name, fallback, min, max) {
    var v = Number(setting(name))
    if (!isFinite(v)) v = Number(fallback)
    if (!isFinite(v)) v = min
    return Math.max(min, Math.min(max, Math.round(v)))
  }

  // Sample interval in ms; floored at 250 so a zero/negative entry can't
  // drive the poll timer into a busy loop
  readonly property int sampleInterval: intSetting("interval", 2000, 250, 60000)
  // Label text size in px; falls back to the bar caption size when unset
  readonly property int textSize: intSetting("fontSize", Style.font.caption, minSize, maxSize)
  // Interface names to ignore (loopback and virtual bridges/veth pairs)
  readonly property var excludeRe: /^lo$|^docker\d*|^br-.+|^virbr\d*|^veth.*|^vboxnet\d*/i

  property real lastRx: -1
  property real lastTx: -1
  property real lastStamp: 0
  property real downSpeed: -1
  property real upSpeed: -1
  property real totalRx: 0
  property real totalTx: 0

  // Cached formatted speed strings to avoid recomputation
  property string cachedDownSpeedStr: "--"
  property string cachedUpSpeedStr: "--"
  property string cachedTotalRxStr: "--"
  property string cachedTotalTxStr: "--"

  readonly property bool ready: downSpeed >= 0
  readonly property string label: ready
    ? "\u2193 " + cachedDownSpeedStr + "  \u2191 " + cachedUpSpeedStr
    : ""

  function formatSpeed(bytesPerSec) {
    if (bytesPerSec < 0) return "--"
    var units = ["B", "KB", "MB", "GB", "TB"]
    var v = bytesPerSec
    var u = 0
    while (v >= 1000 && u < units.length - 1) {
      v /= 1000
      u++
    }
    return (u === 0 ? Math.round(v) + " " : v.toFixed(1)) + units[u]
  }

  readonly property int maxInterfaces: 32

  function parseSample(text) {
    var lines = text.split("\n")
    var rx = 0
    var tx = 0
    var ifaceCount = 0
    for (var i = 0; i < lines.length && ifaceCount < maxInterfaces; i++) {
      var line = lines[i]
      var idx = line.indexOf(":")
      if (idx < 0) continue
      var name = line.substring(0, idx).trim()
      if (!name || excludeRe.test(name)) continue
      var parts = line.substring(idx + 1).trim().split(/\s+/)
      if (parts.length < 9) continue
      // Parse directly without substring truncation—parseInt handles overflow
      rx += parseInt(parts[0], 10) || 0
      tx += parseInt(parts[8], 10) || 0
      ifaceCount++
    }
    return ifaceCount > 0 ? { rx: rx, tx: tx } : null
  }

  function applySample(sample) {
    if (!sample) return
    totalRx = sample.rx
    totalTx = sample.tx
    cachedTotalRxStr = formatSpeed(totalRx)
    cachedTotalTxStr = formatSpeed(totalTx)
    var now = Date.now()
    if (lastRx >= 0 && lastStamp > 0) {
      var secs = Math.max((now - lastStamp) / 1000.0, 0.001)
      // Counter reset (reboot/interface recreate) shows as a negative delta
      downSpeed = Math.max((sample.rx - lastRx) / secs, 0)
      upSpeed = Math.max((sample.tx - lastTx) / secs, 0)
      cachedDownSpeedStr = formatSpeed(downSpeed)
      cachedUpSpeedStr = formatSpeed(upSpeed)
    }
    lastRx = sample.rx
    lastTx = sample.tx
    lastStamp = now
  }

  function refresh() {
    if (!sampleProc.running) sampleProc.running = true
  }

  function setSize(px) {
    var v = Math.round(Number(px))
    if (!isFinite(v)) return
    v = Math.max(minSize, Math.min(maxSize, v))
    if (v === textSize) return
    // Create a shallow copy of settings, preserving all keys except fontSize
    var cur = root.settings || {}
    var next = {}
    for (var k in cur) {
      if (k !== "id" && k !== "fontSize") next[k] = cur[k]
    }
    next.fontSize = v
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  function cycleSize() {
    var steps = sizeSteps
    for (var i = 0; i < steps.length; i++)
      if (steps[i] === textSize) return setSize(steps[(i + 1) % steps.length])
    // Current size is between presets: step up to the next one above it
    for (var j = 0; j < steps.length; j++)
      if (steps[j] > textSize) return setSize(steps[j])
    return setSize(steps[0])
  }

  Component.onCompleted: refresh()

  IpcHandler {
    target: "davedes.netspeed"

    function refresh(): void {
      root.broadcast("refresh")
    }

    function fontSizeUp(): void {
      root.setSize(root.textSize + 1)
    }

    function fontSizeDown(): void {
      root.setSize(root.textSize - 1)
    }

    function setFontSize(px: int): void {
      root.setSize(px)
    }
  }

  Process {
    id: sampleProc
    command: ["sh", "-c", "head -n 34 /proc/net/dev | head -c 4096"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySample(root.parseSample(text))
    }
  }

  Timer {
    interval: root.sampleInterval
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: root.refresh()
  }

  visible: ready
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    fontSize: root.textSize
    tooltipText: root.ready
      ? "\u2193 " + root.cachedDownSpeedStr + "   \u2191 " + root.cachedUpSpeedStr
        + "\nTotal \u2193 " + root.cachedTotalRxStr + "  \u2191 " + root.cachedTotalTxStr
        + "\nClick: resize \u2022 Scroll: fine-tune"
      : ""
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.cycleSize()
      else if (b === Qt.MiddleButton) root.refresh()
      else if (root.bar) root.bar.run("omarchy-shell shell toggle omarchy.network")
    }
    onWheelMoved: function(delta) {
      root.setSize(root.textSize + (delta > 0 ? 1 : -1))
    }
  }
}
