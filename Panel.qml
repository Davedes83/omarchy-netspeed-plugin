import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Net Speed dropdown: left-click the bar widget to open a live network
// popup anchored under it.
//
// Presentation is built from the shell's own UI kit rather than hand-rolled
// chrome — PanelHero, PanelSectionHeader, PanelSeparator, PanelActionButton,
// CursorSurface and the Style.spacing.* density tokens — so the popup tracks
// the active theme (colours, border specs, corner radius, row density)
// exactly like the first-party panels.
//
// Data is gathered by this panel's own pipeline and runs even while the
// popup is closed, so "this session" numbers and the history chart are
// meaningful the moment the panel opens:
//
//   - /proc/net/dev every interval        -> history chart + iface rates
//   - `ss -tinp state established` / 1.5s -> per-app bytes (deltas between polls)
//   - default route + nmcli every 5s      -> connection details
//
// The bar widget (hostWidget) keeps feeding the little label; the panel only
// reads the widget for the live down/up hero numbers.
Panel {
  id: root
  moduleName: "davedes.netspeed"
  ipcTarget: "davedes.netspeed"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // Theme-derived tones shared across hero, chart and rows. The primary
  // direction (DOWN) uses the theme accent; the secondary (UP) uses the
  // theme's muted tone; text hierarchy dims via darker foreground steps.
  readonly property color accented: Color.accent
  readonly property color secondary: Color.muted
  readonly property color textDim1: Qt.darker(root.contentForeground, 1.4)
  readonly property color textDim2: Qt.darker(root.contentForeground, 1.55)
  readonly property color textDim3: Qt.darker(root.contentForeground, 1.8)

  // Shared interaction fill, derived from the bar foreground the same way the
  // first-party panels do, so the hover tint matches the rest of the shell
  // instead of being a hardcoded rectangle opacity.
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"

  // A carried-but-not-active link is worth flagging: the hero glyph dims and
  // STATUS picks up the theme's urgent tone.
  readonly property bool linkUp: root.stateLabel === "CONNECTED" || root.stateLabel === "ACTIVATED"
  readonly property bool haveLink: root.stateLabel !== "" && root.stateLabel !== "UNMANAGED" && root.stateLabel !== "UNKNOWN"

  readonly property string connectionName: root.wifi
    ? root.info.wifiSsid || "Wi-Fi"
    : (root.info.type ? root.info.type.toUpperCase() : "Net speed")

  // The single most glanceable fact about a link, promoted out of the
  // NETWORK list into the hero's detail pill.
  readonly property string heroDetail: root.wifi
    ? (root.wifiLinkRate ? root.wifiLinkRate + " Mbit/s" : (root.info.wifiBand || ""))
    : (root.info.type && root.info.type !== "wifi" ? root.info.type.toUpperCase() : "")

  // nmcli's GENERAL.STATE is "N (word)" — keep just the word, upper-cased.
  readonly property string stateLabel: (function() {
    var s = String(root.info.state || "")
    var m = s.match(/^\d+\s*\(([^)]+)\)/)
    return (m ? m[1] : s).toUpperCase()
  })()

  // Panel-side poll intervals. The /proc/net/dev cadence belongs to the bar
  // widget (it owns the sampler), so the panel only schedules its own work:
  // per-app attribution and connection details.
  readonly property int ssPollMs: 1500
  readonly property int infoPollMs: 5000

  // "1.5s" rather than a rounded "2s", which used to misstate the interval.
  readonly property string ssPollLabel: (root.ssPollMs % 1000 === 0)
    ? (root.ssPollMs / 1000) + "s"
    : (Math.round(root.ssPollMs / 100.0) / 10) + "s"

  // ---- live state -------------------------------------------------------
  // The bar widget (hostWidget) owns all continuous sampling of /proc/net/dev
  // and exposes history, session totals and per-interface rates; this panel
  // only binds to them. ss (per-app) and route/nmcli (connection details) are
  // queried by this panel while open.
  property string iface: ""
  property var info: ({})
  property string wifiTxRate: ""
  property string wifiRxRate: ""
  readonly property string wifiLinkRate: root.wifiTxRate || root.wifiRxRate

  // Chart time window in seconds (5 / 15 / 30 minutes), driven by the pills
  // in the chart header.
  property int chartWindow: 300
  readonly property var history: hostWidget ? (hostWidget.history || []) : []

  property var prevConn: ({})        // ss byte baselines pid|local|remote|fd
  property var appCum: ({})          // pid -> { name, down, up }
  property var appRows: []           // [{pid, name, down, up, conns, rateDown, rateUp}]
  property real lastSSAt: 0

  // Index of the hovered per-app row. The rows are CursorSurfaces, so the
  // highlight chrome (fill + border) is the shell's shared hover-cursor spec
  // rather than a local effect. Cursor state lives here at the panel root so
  // exactly one row can be lit at a time.
  property int hoverApp: -1

  readonly property bool wifi: root.info.wifiSsid !== undefined && root.info.wifiSsid !== ""
  readonly property string heroDown: hostWidget ? hostWidget.cachedDownSpeedStr : "--"
  readonly property string heroUp: hostWidget ? hostWidget.cachedUpSpeedStr : "--"
  readonly property string totalDown: hostWidget ? hostWidget.cachedTotalRxStr : "--"
  readonly property string totalUp: hostWidget ? hostWidget.cachedTotalTxStr : "--"
  readonly property string sessionDownStr: hostWidget ? Model.fmtBytes(hostWidget.sessionDown) : "--"
  readonly property string sessionUpStr: hostWidget ? Model.fmtBytes(hostWidget.sessionUp) : "--"

  function open() {
    refresh()
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // Explicit refresh (hero button, R key, IPC, and the prime call in open()).
  // Deliberately not gated on `opened`: open() primes before showing, and the
  // rest only arrive while the popup is up.
  function refresh() {
    refreshSS()
    pollInfo()
  }

  function refreshSS() { if (!ssProc.running) ssProc.running = true }
  function pollInfo() { if (!routeProc.running) routeProc.running = true }

  function runNmcli() {
    if (root.iface === "") return
    // Never rewrite `command` on a live process. A run already in flight is
    // either for this interface or will be superseded by the next poll.
    if (nmcliProc.running) return
    nmcliProc.command = ["nmcli", "-t", "-e", "no",
      "-f", "GENERAL,IP4,DHCP4,IP6,AP", "device", "show", root.iface]
    nmcliProc.running = true
  }

  // ---- data handlers ----------------------------------------------------

  function onSS(text) {
    if (!root.appCum || !root.prevConn) return  // torn down mid hot-reload
    var now = Date.now()
    var dt = root.lastSSAt > 0 ? Math.max(now - root.lastSSAt, 1) : root.ssPollMs
    root.lastSSAt = now
    var res = Model.parseSS(text, root.prevConn)
    root.prevConn = res.next

    // One pass to fold this poll into the retained session totals, keeping the
    // live rate/count alongside; a second pass emits the rows. Doing it this
    // way means no per-row lookup table and no O(n^2) pid matching.
    var live = {}
    for (var i = 0; i < res.apps.length; i++) {
      var a = res.apps[i]
      var pid = String(a.pid)
      var c = root.appCum[pid]
      if (!c) c = root.appCum[pid] = { name: a.name, down: 0, up: 0, lastPoll: now }
      c.name = a.name
      c.down += a.deltaDown
      c.up += a.deltaUp
      c.lastPoll = now
      live[pid] = {
        conns: a.conns,
        rateDown: a.deltaDown / dt * 1000,
        rateUp: a.deltaUp / dt * 1000
      }
    }
    // Drop apps that have had no attributable connections for 30s.
    for (var p in root.appCum) {
      if (!live[p] && now - root.appCum[p].lastPoll > 30000) delete root.appCum[p]
    }

    var rows = []
    for (var k in root.appCum) {
      var c2 = root.appCum[k]
      // A retained app that is no longer live keeps its session totals but
      // shows no live rate and no connections.
      var l = live[k] || { conns: 0, rateDown: 0, rateUp: 0 }
      rows.push({
        pid: k, name: c2.name || "?", down: c2.down, up: c2.up,
        conns: l.conns, rateDown: l.rateDown, rateUp: l.rateUp
      })
    }
    rows.sort(function(x, y) { return (y.down + y.up) - (x.down + x.up) })
    root.appRows = rows
  }

  function onRoute(text) {
    var next = Model.parseDefaultRoute(text)
    root.iface = next || root.iface
    runNmcli()
    runIw()
  }

  function runIw() {
    if (root.iface === "") return
    if (iwProc.running) return
    iwProc.command = ["iw", "dev", root.iface, "link"]
    iwProc.running = true
  }

  function onIW(text) {
    var tx = 0, rx = 0
    var lines = String(text).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var t = lines[i].trim()
      var m = t.match(/^(rx|tx) bitrate:\s*([\d.]+)/)
      if (m && m[1] === "rx") rx = m[2]
      else if (m && m[1] === "tx") tx = m[2]
    }
    root.wifiRxRate = rx > 0 ? rx + "" : ""
    root.wifiTxRate = tx > 0 ? tx + "" : ""
  }

  function onNM(text) {
    var parsed = Model.parseNmcli(text)
    if (!parsed || parsed.iface === "") return
    root.info = parsed
  }

  function scrollFlick(dy) {
    var f = dealScroller
    var max = Math.max(0, f.contentHeight - f.height)
    var target = dy > 0
      ? Math.min(max, f.contentY + Style.space(42))
      : Math.max(0, f.contentY - Style.space(42))
    f.contentY = target
  }

  // ------------------------------------------------------------ lifecycle

  // No polling until the popup is actually opened: `open()` primes the
  // first poll, and the timers below take over from there. This matters
  // because the panel is instantiated with the bar widget, not lazily on
  // open, so anything started here would run for the whole shell session.

  Process {
    id: ssProc
    // Restricted to established sockets: a socket only moves bytes while it
    // is established, and the unfiltered listing emits a full info line per
    // socket in every state, which is the most expensive thing this plugin
    // runs.
    command: ["ss", "-tinp", "state", "established"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSS(text)
    }
  }

  Process {
    id: routeProc
    command: ["ip", "-j", "route", "show", "default"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onRoute(text)
    }
  }

  Process {
    id: nmcliProc
    command: ["true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onNM(text)
    }
  }

  Process {
    id: iwProc
    command: ["true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onIW(text)
    }
  }

  // ss and route/nmcli only run while open.
  Timer {
    interval: root.ssPollMs
    running: root.opened
    repeat: true
    triggeredOnStart: false
    onTriggered: root.refreshSS()
  }

  Timer {
    interval: root.infoPollMs
    running: root.opened
    repeat: true
    triggeredOnStart: false
    onTriggered: root.pollInfo()
  }

  // ------------------------------------------------------------ components

  // Shared section title driver: Omarchy's PanelSectionHeader tinted to the
  // panel's foreground/font so it inherits the popup's colouring.
  component PanelTitle: PanelSectionHeader {
    foreground: root.contentForeground
    fontFamily: root.contentFontFamily
    font.letterSpacing: 1
  }

  // Label/value line for the NETWORK table. `tone` lets a row opt into the
  // theme's urgent colour (a link that is present but not up) without the
  // caller restyling the text itself.
  component InfoRow: Item {
    id: row
    property string label: ""
    property string value: ""
    property bool urgent: false
    property int valueSpacing: 6
    width: parent ? parent.width : 0
    height: Style.spacing.popupRowHeight

    readonly property color labelColor: row.urgent ? Color.urgent : root.textDim1
    readonly property color valueColor: row.urgent ? Color.urgent : root.contentForeground

    Text {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: row.label
      color: row.labelColor
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
      textFormat: Text.PlainText
    }
    Text {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: row.value
      color: row.valueColor
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
      textFormat: Text.PlainText
    }
    PanelSeparator {
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      foreground: root.contentForeground
    }
  }

  // Chart-window selector pill. A genuine pill: BorderSurface so the border
  // comes from the theme's control spec (normal / hover-cursor / selected)
  // rather than a fixed outline, and the hover fill is the shared hover tint.
  component WindowChip: BorderSurface {
    id: cap
    property string caption: ""
    property int seconds: 300
    readonly property bool selected: root.chartWindow === cap.seconds

    implicitWidth: chipText.implicitWidth + Style.spacing.xl
    implicitHeight: Style.space(20)
    radius: Math.round(height / 2)
    // BorderSurface has no `foreground` of its own, so the theme's foreground
    // is threaded straight into the control spec, the way PanelActionButton
    // and CursorSurface consume it.
    color: cap.selected
      ? root.accented
      : (chipMouse.containsMouse ? root.hoverFill : "transparent")
    borderSpec: cap.selected
      ? Border.controlSpec("selected", root.contentForeground, Color.accent)
      : (chipMouse.containsMouse
        ? Border.controlSpec("hover-cursor", root.contentForeground, Color.accent)
        : Border.none())

    Behavior on color { ColorAnimation { duration: 60 } }

    Text {
      id: chipText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: cap.caption
      color: cap.selected ? Color.background : root.textDim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 0.5
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.chartWindow = cap.seconds
    }
  }

  component HistoryChart: Item {
    id: chart
    property var history: []
    property int windowSecs: 300
    // Series tones come from the active theme: the accent for DOWN (primary)
    // and the theme's secondary/`muted` tone for UP, so the two directions
    // read as one hierarchy and every colour follows the running theme.
    readonly property color tintDown: Color.accent
    readonly property color tintUp: Color.muted

    // Caption matches PanelSectionHeader's treatment so the chart reads as a
    // section of its own despite living above the separators. The window pills
    // sit on the same baseline, right-aligned.
    Text {
      id: header
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: rangeRow.left
      anchors.rightMargin: Style.spacing.lg
      textFormat: Text.PlainText
      text: "LIVE THROUGHPUT \u00b7 LAST " + Math.round(chart.windowSecs / 60) + " MIN"
      color: root.textDim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
      elide: Text.ElideRight
      topPadding: Math.ceil(font.pixelSize * 0.15)
    }

    Row {
      id: rangeRow
      anchors.top: parent.top
      anchors.right: parent.right
      spacing: Style.spacing.xs

      WindowChip { caption: "5 MIN";  seconds: 300 }
      WindowChip { caption: "15 MIN"; seconds: 900 }
      WindowChip { caption: "30 MIN"; seconds: 1800 }
    }

    // Download above the axis, upload mirrored below — both directions share
    // one scale so the asymmetry is honest. Each direction is a gradient-filled
    // area under a round-capped stroke, with a dashed guide at the window peak
    // for scale. Hover draws a crosshair plus a readout of the nearest sample.
    Canvas {
      id: flow
      anchors.top: header.bottom
      anchors.topMargin: Style.spacing.sm
      anchors.left: parent.left
      anchors.right: parent.right
      height: Style.space(92)

      property real hoverX: -1
      onHoverXChanged: requestPaint()

      // Sample time window: the selected range of the widget's history.
      readonly property var pts: {
        var cut = Date.now() / 1000 - chart.windowSecs
        var out = []
        for (var i = 0; i < chart.history.length; i++) {
          var p = chart.history[i]
          if (p && p.t >= cut) out.push(p)
        }
        return out
      }
      onPtsChanged: requestPaint()
      onWidthChanged: requestPaint()

      HoverHandler {
        onPointChanged: flow.hoverX = hovered ? point.position.x : -1
        onHoveredChanged: if (!hovered) flow.hoverX = -1
      }

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.clearRect(0, 0, width, height)
        var mid = Math.round(height / 2)
        var axis = Qt.rgba(root.contentForeground.r, root.contentForeground.g,
                           root.contentForeground.b, 0.22)

        // Zero axis: the two directions mirror around it.
        ctx.strokeStyle = axis
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(0, mid + 0.5)
        ctx.lineTo(width, mid + 0.5)
        ctx.stroke()

        var p = flow.pts
        if (!p || p.length < 2) {
          ctx.font = "10px " + root.contentFontFamily
          ctx.textBaseline = "middle"
          ctx.fillStyle = root.textDim3
          ctx.textAlign = "center"
          ctx.fillText("Collecting samples\u2026", width / 2, mid)
          ctx.textAlign = "left"
          return
        }
        var peak = 10 * 1024
        for (var i = 0; i < p.length; i++) {
          if (p[i].down !== null) peak = Math.max(peak, p[i].down)
          if (p[i].up !== null) peak = Math.max(peak, p[i].up)
        }
        peak *= 1.1
        // The x-axis always spans the full selected window (now-window → now);
        // samples hug the live right edge, so switching 5/15/30 min is
        // immediately visible even before that much history has accumulated.
        var tNow = Date.now() / 1000
        var tStart = tNow - chart.windowSecs
        var span = chart.windowSecs

        function xOf(t) {
          return Math.max(0, Math.min(width - 1, (t - tStart) * (width - 1) / span))
        }
        var half = mid - 2

        // Dashed guide at the top of scale so the silhouette reads against a
        // known magnitude rather than floating in space.
        ctx.save()
        ctx.strokeStyle = Qt.rgba(root.contentForeground.r, root.contentForeground.g,
                                  root.contentForeground.b, 0.16)
        ctx.lineWidth = 1
        if (typeof ctx.setLineDash === "function") ctx.setLineDash([2, 3])
        ctx.beginPath()
        ctx.moveTo(0, Math.round(mid - half) + 0.5)
        ctx.lineTo(width, Math.round(mid - half) + 0.5)
        ctx.stroke()
        ctx.restore()

        function draw(key, up, tint) {
          var runs = [], cur = []
          for (var i = 0; i < p.length; i++) {
            var v = p[i][key]
            if (v === null || v === undefined) {
              if (cur.length > 1) runs.push(cur)
              cur = []
            } else {
              cur.push([xOf(p[i].t),
                        mid + (up ? -1 : 1) * half * Math.min(1, v / peak)])
            }
          }
          if (cur.length > 1) runs.push(cur)
          for (var r = 0; r < runs.length; r++) {
            var run = runs[r]
            // Area: fade from the tone at the axis to nothing at the peak, so
            // overlapping up/down fills stack instead of muddying.
            var fill = ctx.createLinearGradient(0, mid, 0, up ? mid - half : mid + half)
            fill.addColorStop(0, Qt.rgba(tint.r, tint.g, tint.b, 0.34))
            fill.addColorStop(1, Qt.rgba(tint.r, tint.g, tint.b, 0.02))
            ctx.beginPath()
            ctx.moveTo(run[0][0], mid)
            for (var j = 0; j < run.length; j++) ctx.lineTo(run[j][0], run[j][1])
            ctx.lineTo(run[run.length - 1][0], mid)
            ctx.closePath()
            ctx.fillStyle = fill
            ctx.fill()
            ctx.beginPath()
            for (j = 0; j < run.length; j++) {
              if (j === 0) ctx.moveTo(run[j][0], run[j][1])
              else ctx.lineTo(run[j][0], run[j][1])
            }
            ctx.strokeStyle = tint
            ctx.lineWidth = 1.5
            ctx.lineJoin = "round"
            ctx.lineCap = "round"
            ctx.stroke()
            // Head marker: where the series is live right now.
            var last = run[run.length - 1]
            ctx.beginPath()
            ctx.arc(last[0], last[1], 2, 0, Math.PI * 2)
            ctx.fillStyle = tint
            ctx.fill()
          }
        }
        draw("down", true, chart.tintDown)
        draw("up", false, chart.tintUp)

        // Top-of-scale label so the silhouette has magnitude.
        ctx.font = "10px " + root.contentFontFamily
        ctx.textBaseline = "top"
        ctx.fillStyle = root.textDim3
        ctx.fillText("\u2264 " + Model.fmtSpeed(peak), 4, 3)

        if (flow.hoverX >= 0) {
          var tAt = tStart + flow.hoverX * span / (width - 1)
          var best = null, bestD = Infinity
          for (var h = 0; h < p.length; h++) {
            var d = Math.abs(p[h].t - tAt)
            if (d < bestD) { bestD = d; best = p[h] }
          }
          if (best) {
            var cx = xOf(best.t)
            ctx.strokeStyle = Qt.rgba(root.contentForeground.r, root.contentForeground.g,
                                      root.contentForeground.b, 0.4)
            ctx.lineWidth = 1
            ctx.beginPath()
            ctx.moveTo(cx + 0.5, 0)
            ctx.lineTo(cx + 0.5, height)
            ctx.stroke()
            var label = Qt.formatTime(new Date(best.t * 1000), "HH:mm:ss")
              + "  \u00b7  \u2193 " + Model.fmtSpeed(best.down)
              + "  \u00b7  \u2191 " + Model.fmtSpeed(best.up)
            var fg = root.contentForeground
            ctx.font = "10px " + root.contentFontFamily
            var w = ctx.measureText(label).width + 12
            var bx = Math.max(2, Math.min(width - w - 2, cx - w / 2))
            var bg = Color.popups.background
            ctx.fillStyle = Qt.rgba(bg.r, bg.g, bg.b, 0.92)
            ctx.fillRect(bx, 2, w, 16)
            ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.25)
            ctx.lineWidth = 1
            ctx.strokeRect(bx + 0.5, 2.5, w - 1, 15)
            ctx.fillStyle = fg
            ctx.textBaseline = "alphabetic"
            ctx.fillText(label, bx + 6, 2 + 8 + 3.6)
          }
        }
      }
    }
  }

// ---- One direction's live figure. `caption` is the small-caps label,
  //      `value` the headline rate, and the two trailing lines give the
  //      session and lifetime totals so the headline has context.
  component StatBlock: Column {
    id: stat
    property string caption: ""
    property string value: "--"
    property string sessionText: "--"
    property string totalText: "--"
    property color tone: root.contentForeground
    property string glyph: ""

    width: (parent.width - Style.space(24)) / 2
    spacing: Style.spacing.xxs

    Text {
      textFormat: Text.PlainText
      text: stat.caption
      color: root.textDim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }
    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: stat.glyph + " " + stat.value
      color: stat.tone
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.display
      font.bold: true
      elide: Text.ElideRight
    }
    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: "session " + stat.glyph + " " + stat.sessionText
      color: root.textDim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: "total " + stat.glyph + " " + stat.totalText
      color: root.textDim3
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  // ---- One per-app row. CursorSurface gives the row the shell's shared
  //      hover-cursor fill and border; the panel root owns `hoverApp` so
  //      exactly one row is ever lit.
  component AppRow: CursorSurface {
    id: appRow
    required property var modelData
    // Repeater injects `index` and `modelData` only, so the row key is
    // `index` itself — naming it anything else leaves it unset.
    required property int index

    readonly property string safeName: String(modelData.name)
      .replace(/[<\u0000-\u001F\u007F]/g, " ")
    readonly property string pidText: "(" + String(modelData.pid) + ")"

    hasCursor: root.hoverApp === appRow.index
    foreground: root.contentForeground
    fill: root.hoverFill

    // Two lines: identity + connection count, then live rate + session totals.
    // Height has to cover both lines or they overprint each other.
    implicitHeight: appName.implicitHeight + Style.spacing.xs
      + rateText.implicitHeight + Style.spacing.xl

    Text {
      id: appName
      anchors.top: parent.top
      anchors.topMargin: Style.spacing.xs
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.sm
      text: appRow.safeName
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
      // Shrink to the name so the pid sits against it, but never past the
      // space the right-hand column needs.
      width: Math.min(implicitWidth, parent.width - Style.space(110))
      elide: Text.ElideRight
    }
    Text {
      id: appPid
      anchors.baseline: appName.baseline
      anchors.left: appName.right
      anchors.leftMargin: Style.spacing.xs
      text: appRow.pidText
      color: root.textDim3
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      anchors.baseline: appName.baseline
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.sm
      text: modelData.conns === 1 ? "1 conn" : modelData.conns + " conns"
      color: root.textDim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      id: rateText
      anchors.top: appName.bottom
      anchors.topMargin: Style.spacing.xs
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.sm
      text: "\u2193 " + Model.fmtSpeed(modelData.rateDown)
        + "   \u2191 " + Model.fmtSpeed(modelData.rateUp)
      color: root.textDim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      anchors.top: appName.bottom
      anchors.topMargin: Style.spacing.xs + 1
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.sm
      text: "\u2193 " + Model.fmtBytes(modelData.down)
        + "   \u2191 " + Model.fmtBytes(modelData.up)
      color: root.textDim3
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onContainsMouseChanged: {
        if (containsMouse) root.hoverApp = appRow.index
        else if (root.hoverApp === appRow.index) root.hoverApp = -1
      }
    }
  }

  // ------------------------------------------------------------ panel body

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(contentCol.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.scrollFlick(dy) }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
      }

      Flickable {
        id: dealScroller
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: contentCol.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        ScrollBar.vertical: ScrollBar {
          id: vScroll
          policy: ScrollBar.AsNeeded
          width: Style.spacing.sm
        }

        Column {
          id: contentCol
          // Reserve the scrollbar gutter unconditionally: the policy is
          // AsNeeded, so letting the column claim the full width would let
          // the bar clip the right-aligned values (and reflow the wrapped
          // copy) every time the app list grew past the fold.
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.rightMargin: vScroll.width
          spacing: Style.spacing.xxl

          // ---- Hero: glyph, connection name, interface/state meta, link-rate
          //      pill, and the panel's two actions on the trailing edge.
          PanelHero {
            id: hero
            width: parent.width
            title: root.connectionName
            meta: root.iface !== ""
              ? (root.iface.toUpperCase() + (root.stateLabel ? " \u00b7 " + root.stateLabel : ""))
              : root.stateLabel
            detail: root.heroDetail
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            iconOpacity: root.info.type ? (root.linkUp ? 1.0 : 0.5) : 0.55

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.wifi ? "󰖩" : "󰈀"
                color: root.linkUp ? root.accented : root.textDim2
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.spacing.xxs

                PanelActionButton {
                  iconText: "󰑓"
                  tooltipText: "Refresh (R)"
                  foreground: hero.foreground
                  fontFamily: hero.fontFamily
                  onClicked: root.refresh()
                }
                PanelActionButton {
                  iconText: "󰅖"
                  tooltipText: "Close (Esc)"
                  foreground: hero.foreground
                  fontFamily: hero.fontFamily
                  onClicked: root.close()
                }
              }
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---- Live down/up, each with session and lifetime totals
          Row {
            width: parent.width
            spacing: Style.space(24)

            StatBlock {
              caption: "DOWNLOAD"
              glyph: "\u2193"
              value: root.heroDown
              sessionText: root.sessionDownStr
              totalText: root.totalDown
              tone: root.accented
            }
            StatBlock {
              caption: "UPLOAD"
              glyph: "\u2191"
              value: root.heroUp
              sessionText: root.sessionUpStr
              totalText: root.totalUp
              tone: root.secondary
            }
          }

          // ---- Usage history chart
          Item {
            width: parent.width
            height: Style.space(118)

            HistoryChart {
              anchors.fill: parent
              history: root.history
              windowSecs: root.chartWindow
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---- Connection details
          Column {
            width: parent.width
            spacing: Style.spacing.lg

            PanelTitle { text: "NETWORK" }
            Column {
              width: parent.width
              spacing: 0

              InfoRow { label: "CONNECTION"; value: root.info.connection || "--" }
              InfoRow { label: "INTERFACE"; value: root.info.iface || root.iface || "--" }
              InfoRow { label: "TYPE"; value: root.info.type ? root.info.type.toUpperCase() : "--" }
              InfoRow {
                visible: root.wifi
                label: "SSID"
                value: root.info.wifiSsid || "--"
              }
              InfoRow {
                visible: root.wifi
                label: "SIGNAL"
                value: root.info.wifiSignal !== undefined
                  ? root.info.wifiSignal + "%  " + (root.info.wifiBars || "")
                  : "--"
              }
              InfoRow {
                visible: root.wifi
                label: "BAND"
                value: ((root.info.wifiBand ? root.info.wifiBand + "" : "")
                  + (root.info.wifiChan ? "  \u00b7  ch " + root.info.wifiChan : "")) || "--"
              }
              InfoRow {
                visible: root.wifi
                label: "LINK RATE"
                // iw is the live figure; nmcli's AP rate is the fallback for
                // drivers where iw prints nothing.
                value: root.wifiLinkRate
                  ? root.wifiLinkRate + " Mbit/s"
                  : (root.info.wifiRate || "--")
              }
              InfoRow {
                visible: root.wifi
                label: "SECURITY"
                value: root.info.wifiSecurity || "--"
              }
              InfoRow {
                label: "IP ADDRESS"
                value: root.info.ip && root.info.ip.length > 0 ? root.info.ip.join("  ") : "--"
              }
              InfoRow {
                label: "GATEWAY"
                value: root.info.gateway || "--"
              }
              InfoRow {
                label: "DNS"
                value: root.info.dns && root.info.dns.length > 0 ? root.info.dns.join(", ") : "--"
              }
              // stateLabel strips nmcli's "N (word)" code, matching the hero.
              InfoRow {
                label: "STATUS"
                value: root.stateLabel || root.info.state || "--"
                urgent: root.haveLink && !root.linkUp
              }
              InfoRow {
                label: "MAC"
                value: root.info.mac || "--"
              }
              InfoRow {
                label: "MTU"
                value: root.info.mtu ? root.info.mtu + " bytes" : "--"
              }
              InfoRow {
                visible: root.info.leaseUntil > 0
                label: "LEASE"
                value: Model.fmtRemaining(root.info.leaseUntil - Date.now() / 1000) + " left"
              }
              InfoRow {
                label: "DRIVER"
                value: root.info.driver || "--"
              }
              InfoRow {
                label: "METERED"
                value: root.info.metered || "--"
              }
            }
          }

          // ---- Per-app usage
          Column {
            width: parent.width
            spacing: Style.spacing.lg

            PanelTitle { text: "PER-APP USAGE" }
            Text {
              width: parent.width
              text: "Bytes attributed from live TCP sockets, sampled every "
                + root.ssPollLabel + ". Totals are this session."
              color: root.textDim3
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Column {
              width: parent.width
              spacing: Style.spacing.xxs

              // Column headings above the per-app rows.
              Item {
                width: parent.width
                height: Style.spacing.xl
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.sm
                  anchors.bottom: parent.bottom
                  text: "APP"
                  color: root.textDim3
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1.2
                }
                Text {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.sm
                  anchors.bottom: parent.bottom
                  text: "CONN"
                  color: root.textDim3
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1.2
                }
              }

              Repeater {
                model: root.appRows.length > 12 ? root.appRows.slice(0, 12) : root.appRows
                delegate: AppRow {
                  width: parent ? parent.width : 0
                }
              }

              Text {
                visible: root.appRows.length === 0
                width: parent.width
                text: "No attributable connections yet."
                color: root.textDim3
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                horizontalAlignment: Text.AlignHCenter
                topPadding: Style.spacing.sm
                bottomPadding: Style.spacing.sm
              }
            }
          }
        }
      }
    }
  }
}