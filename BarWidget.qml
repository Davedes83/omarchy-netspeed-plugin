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
  property real smoothDown: -1
  property real smoothUp: -1
  property real totalRx: 0
  property real totalTx: 0

  // Per-interface breakdown for tooltip
  property var ifaceSpeeds: []

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
    while (v >= 1024 && u < units.length - 1) {
      v /= 1024
      u++
    }
    return (u === 0 ? Math.round(v) + " " : v.toFixed(1)) + units[u]
  }

  readonly property int maxInterfaces: 32

  function parseSample(text) {
    var lines = text.split("\n")
    var rx = 0
    var tx = 0
    var ifaces = []
    var ifaceCount = 0
    for (var i = 0; i < lines.length && ifaceCount < maxInterfaces; i++) {
      var line = lines[i]
      var idx = line.indexOf(":")
      if (idx < 0) continue
      var name = line.substring(0, idx).trim()
      if (!name || excludeRe.test(name)) continue
      var parts = line.substring(idx + 1).trim().split(/\s+/)
      if (parts.length < 9) continue
      var ifaceRx = parseInt(parts[0], 10) || 0
      var ifaceTx = parseInt(parts[8], 10) || 0
      rx += ifaceRx
      tx += ifaceTx
      ifaces.push({ name: name, rx: ifaceRx, tx: ifaceTx })
      ifaceCount++
    }
    return ifaceCount > 0 ? { rx: rx, tx: tx, ifaces: ifaces } : null
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
      // EMA smoothing (alpha = 0.3)
      if (smoothDown < 0) {
        smoothDown = downSpeed
        smoothUp = upSpeed
      } else {
        smoothDown = 0.3 * downSpeed + 0.7 * smoothDown
        smoothUp = 0.3 * upSpeed + 0.7 * smoothUp
      }
      cachedDownSpeedStr = formatSpeed(smoothDown)
      cachedUpSpeedStr = formatSpeed(smoothUp)
    }
    // Per-interface speed breakdown (raw delta, not smoothed)
    var prevIfaces = ifaceSpeeds
    var newIfaces = []
    for (var i = 0; i < sample.ifaces.length; i++) {
      var iface = sample.ifaces[i]
      var prev = null
      for (var j = 0; j < prevIfaces.length; j++) {
        if (prevIfaces[j].name === iface.name) { prev = prevIfaces[j]; break }
      }
      var dRx = 0, dTx = 0
      if (prev && lastStamp > 0) {
        var isecs = Math.max((now - lastStamp) / 1000.0, 0.001)
        dRx = Math.max((iface.rx - prev.rx) / isecs, 0)
        dTx = Math.max((iface.tx - prev.tx) / isecs, 0)
      }
      newIfaces.push({ name: iface.name, down: dRx, up: dTx })
    }
    ifaceSpeeds = newIfaces
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
    var next = Object.assign({}, root.settings)
    delete next.id
    delete next.fontSize
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
    command: ["sh", "-c", "head -c 4096 /proc/net/dev"]
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
    tooltipText: {
      if (!root.ready) return ""
      var tip = "\u2193 " + root.cachedDownSpeedStr + "   \u2191 " + root.cachedUpSpeedStr
        + "\nTotal \u2193 " + root.cachedTotalRxStr + "  \u2191 " + root.cachedTotalTxStr
      // Per-interface breakdown
      var ifaces = root.ifaceSpeeds
      for (var i = 0; i < ifaces.length; i++) {
        var f = ifaces[i]
        if (f.down > 0 || f.up > 0)
          tip += "\n  " + f.name + ": \u2193 " + root.formatSpeed(f.down) + "  \u2191 " + root.formatSpeed(f.up)
      }
      tip += "\nClick: resize \u2022 Scroll: fine-tune \u2022 Middle: refresh \u2022 Right: network"
      return tip
    }
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
