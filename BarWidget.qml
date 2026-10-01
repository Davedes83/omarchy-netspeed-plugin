import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

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
  // Optional exact-name allowlist of interfaces to monitor. Empty (the
  // default) means "every non-virtual interface"; see Model.VIRTUAL_IFACE_RE
  // for what counts as virtual.
  readonly property var ifaceAllow: Model.ifaceAllowList(setting("interfaces"))

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

  // Continuous-usage state. One sampler (sampleProc below) feeds both the bar
  // label and the dropdown panel; the panel binds to these instead of owning
  // its own /proc/net/dev reads. History survives hot reloads that leave the
  // widget instance in place, and "session" is this widget's lifetime.
  property var history: []           // [{down, up}, ...] newest last
  readonly property var ifaceRates: ifaceSpeeds
  property real sessionDown: 0       // bytes attributed this session
  property real sessionUp: 0
  // Enough samples for the panel's longest (30 min) chart window at any interval.
  readonly property int historyMax: Math.ceil(30 * 60 * 1000 / sampleInterval) + 1

  // Cached formatted speed strings to avoid recomputation
  property string cachedDownSpeedStr: "--"
  property string cachedUpSpeedStr: "--"
  property string cachedTotalRxStr: "--"
  property string cachedTotalTxStr: "--"

  readonly property bool ready: downSpeed >= 0
  readonly property string label: ready
    ? "\u2193 " + cachedDownSpeedStr + "  \u2191 " + cachedUpSpeedStr
    : ""

  // Formatting and /proc/net/dev parsing live in Model.js so this widget and
  // the dropdown can never drift apart on units or on which interfaces count.

  function applySample(sample) {
    if (!sample) return
    totalRx = sample.rx
    totalTx = sample.tx
    cachedTotalRxStr = Model.fmtBytes(totalRx)
    cachedTotalTxStr = Model.fmtBytes(totalTx)
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
      cachedDownSpeedStr = Model.fmtSpeed(smoothDown)
      cachedUpSpeedStr = Model.fmtSpeed(smoothUp)

      // Continuous usage: session totals + the history chart use the raw
      // aggregate delta between samples, not the smoothed label value.
      history = Model.pushHistory(history, { down: downSpeed, up: upSpeed, t: now / 1000 }, historyMax)
      sessionDown += downSpeed * secs
      sessionUp += upSpeed * secs
    }
    // Per-interface speed breakdown (raw delta, not smoothed)
    var prevIfaces = ifaceSpeeds
    var prevMap = {}
    for (var j = 0; j < prevIfaces.length; j++) {
      prevMap[prevIfaces[j].name] = prevIfaces[j]
    }
    var newIfaces = []
    for (var i = 0; i < sample.ifaces.length; i++) {
      var iface = sample.ifaces[i]
      var prev = prevMap[iface.name] || null
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
    // Quickshell ignores `running = true` on a live process, so assigning it
    // unconditionally would silently drop a refresh requested mid-sample
    // (middle-click, or the refresh IPC function).
    if (!sampleProc.running) sampleProc.running = true
    // Only hand the refresh to the panel when it is open -- the panel polls
    // ss/nmcli on demand and must stay idle otherwise.
    if (opened && panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  // ---- Details dropdown. Shape contract for shell.summon/hide/toggle
  //      and for Bar.findPanelWidget (open/close/opened on the widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  // The slot fills more than the bar paints for a mark: it's a padded text
  // label, so the open-panel dot takes the label width.
  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  function setSize(px) {
    var v = Math.round(Number(px))
    if (!isFinite(v)) return
    v = Math.max(minSize, Math.min(maxSize, v))
    if (v === textSize) return
    // updateEntryInline *replaces* the shell.json layout entry with the
    // object it is handed, so send the whole entry back: a bare
    // { fontSize: v } would delete every other key on it (interval,
    // interfaces, ...) the first time anyone scrolled the widget.
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.fontSize = v
    // Apply locally first so the label resizes on this event rather than
    // waiting for the write to come back through the bar.
    root.settings = entry
    if (root.bar && root.bar.shell) {
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    }
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

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  Process {
    id: sampleProc
    // Read the file directly. The previous `sh -c "head -n 34 ... | head -c 4096"`
    // wrapper silently dropped interfaces past the 32nd and could cut a
    // counter in half, corrupting the total for a sample; the budget now
    // lives in Model.parseDev, which skips any line it cannot read whole.
    command: ["cat", "/proc/net/dev"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySample(Model.parseDev(text, root.ifaceAllow))
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
          tip += "\n  " + f.name + ": \u2193 " + Model.fmtSpeed(f.down) + "  \u2191 " + Model.fmtSpeed(f.up)
      }
      tip += "\nLeft: details \u2022 Scroll: fine-tune \u2022 Middle: refresh \u2022 Right: network"
      return tip
    }
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
      else if (b === Qt.MiddleButton) root.refresh()
      else if (root.bar) root.bar.run("omarchy-shell shell toggle omarchy.network")
    }
    onWheelMoved: function(delta) {
      root.setSize(root.textSize + (delta > 0 ? 1 : -1))
    }
  }
}