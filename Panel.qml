import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Net Speed dropdown: left-click the bar widget to open a live network
// popup anchored under it.
//
// Data is gathered by this panel's own pipeline and runs even while the
// popup is closed, so "this session" numbers and the history chart are
// meaningful the moment the panel opens:
//
//   - /proc/net/dev every interval        -> history chart + iface rates
//   - `ss -tinp` every 3s                 -> per-app bytes (deltas between polls)
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
  readonly property color textDim2: Qt.darker(root.contentForeground, 1.7)

  readonly property string connectionName: root.wifi
    ? root.info.wifiSsid || "Wi-Fi"
    : (root.info.type ? root.info.type.toUpperCase() : "Net speed")

  // nmcli's GENERAL.STATE is "N (word)" — keep just the word, upper-cased.
  readonly property string stateLabel: (function() {
    var s = String(root.info.state || "")
    var m = s.match(/^\d+\s*\(([^)]+)\)/)
    return (m ? m[1] : s).toUpperCase()
  })()

  function intSetting(name, fallback, min, max) {
    var v = Number(setting(name))
    if (!isFinite(v)) v = Number(fallback)
    if (!isFinite(v)) v = min
    return Math.max(min, Math.min(max, Math.round(v)))
  }

  readonly property int devPollMs: intSetting("interval", 2000, 250, 60000)
  readonly property int ssPollMs: 1500
  readonly property int infoPollMs: 5000

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

  function refresh() {
    refreshSS()
    pollInfo()
  }

  function refreshSS() { if (!ssProc.running) ssProc.running = true }
  function pollInfo() { if (!routeProc.running) routeProc.running = true }

  function runNmcli() {
    if (root.iface === "") return
    nmcliProc.command = ["nmcli", "-t", "-e", "no",
      "-f", "GENERAL,IP4,DHCP4,IP6,AP", "device", "show", root.iface]
    if (!nmcliProc.running) nmcliProc.running = true
  }

  // ---- data handlers ----------------------------------------------------

  function onSS(text) {
    if (!root.appCum || !root.prevConn) return  // torn down mid hot-reload
    var now = Date.now()
    var dt = root.lastSSAt > 0 ? Math.max(now - root.lastSSAt, 1) : root.ssPollMs
    root.lastSSAt = now
    var res = Model.parseSS(text, root.prevConn)
    root.prevConn = res.next

    var keep = {}
    for (var i = 0; i < res.apps.length; i++) {
      var a = res.apps[i]
      keep[a.pid] = true
      var c = root.appCum[a.pid]
      if (!c) c = root.appCum[a.pid] = { name: a.name, down: 0, up: 0 }
      c.name = a.name
      c.down += a.deltaDown
      c.up += a.deltaUp
      c.lastPoll = now
    }
    // Drop apps that have had no attributable connections for 30s.
    for (var p in root.appCum) {
      if (!keep[p] && now - root.appCum[p].lastPoll > 30000) delete root.appCum[p]
    }

    var rows = []
    for (var k in root.appCum) {
      var c2 = root.appCum[k]
      rows.push({
        pid: k, name: c2.name || "?", down: c2.down, up: c2.up,
        conns: 0, rateDown: 0, rateUp: 0
      })
    }
    for (var j = 0; j < res.apps.length; j++) {
      var a2 = res.apps[j]
      for (var q = 0; q < rows.length; q++) {
        if (rows[q].pid === a2.pid) {
          rows[q].conns = a2.conns
          rows[q].rateDown = a2.deltaDown / dt * 1000
          rows[q].rateUp = a2.deltaUp / dt * 1000
          break
        }
      }
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
    iwProc.command = ["iw", "dev", root.iface, "link"]
    if (!iwProc.running) iwProc.running = true
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

  Component.onCompleted: {
    refresh()
  }

  Process {
    id: ssProc
    command: ["ss", "-tinp"]
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

  component InfoRow: Item {
    id: row
    property string label: ""
    property string value: ""
    property bool showDivider: false
    width: parent ? parent.width : 0
    height: Style.space(26)

    Text {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: row.label
      color: root.textDim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.bodySmall
      font.letterSpacing: 0.4
      textFormat: Text.PlainText
    }
    Text {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: row.value
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
      textFormat: Text.PlainText
    }
    Rectangle {
      visible: row.showDivider
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: 1
      color: root.contentForeground
      opacity: 0.06
    }
  }

  // Selectable chart-window pill: agnostic chip that lights up with the theme
  // accent when its window is active, echoing Omarchy's pill-style toggles.
  component WindowChip: Item {
    id: cap
    property string caption: ""
    property int seconds: 300
    property bool active: root.chartWindow === cap.seconds

    width: Style.space(42)
    height: Style.space(18)

    Rectangle {
      anchors.fill: parent
      radius: Math.round(height / 2)
      color: cap.active ? root.accented : "transparent"

      Rectangle {
        anchors.fill: parent
        radius: parent.radius
        visible: capHover.containsMouse && !cap.active
        color: Qt.darker(root.contentForeground, 1.4)
        opacity: 0.25
      }

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: cap.caption
        color: cap.active ? Color.background : root.textDim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 0.5
      }
    }

    MouseArea {
      id: capHover
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
      anchors.rightMargin: Style.space(8)
      textFormat: Text.PlainText
      text: "LIVE THROUGHPUT \u00b7 LAST " + Math.round(chart.windowSecs / 60) + " MIN"
      color: Qt.darker(root.contentForeground, 1.4)
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
      spacing: Style.space(2)

      WindowChip { caption: "5 MIN";  seconds: 300 }
      WindowChip { caption: "15 MIN"; seconds: 900 }
      WindowChip { caption: "30 MIN"; seconds: 1800 }
    }

    // Download above the axis, upload mirrored below — both directions share
    // one scale so the asymmetry is honest. Polygon fill under a 1.4 px line,
    // like nexthop. Hover draws a crosshair plus a readout of the nearest
    // sample.
    Canvas {
      id: flow
      anchors.top: header.bottom
      anchors.topMargin: Style.space(6)
      anchors.left: parent.left
      anchors.right: parent.right
      height: Style.space(84)

      property real hoverX: -1
      onHoverXChanged: requestPaint()

      // Sample time window: last 3 minutes of the widget's history.
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
        ctx.strokeStyle = Qt.rgba(root.contentForeground.r, root.contentForeground.g,
                                  root.contentForeground.b, 0.22)
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(0, mid + 0.5)
        ctx.lineTo(width, mid + 0.5)
        ctx.stroke()

        var p = flow.pts
        if (!p || p.length < 2) return
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
            ctx.beginPath()
            ctx.moveTo(run[0][0], mid)
            for (var j = 0; j < run.length; j++) ctx.lineTo(run[j][0], run[j][1])
            ctx.lineTo(run[run.length - 1][0], mid)
            ctx.closePath()
            ctx.fillStyle = Qt.rgba(tint.r, tint.g, tint.b, 0.2)
            ctx.fill()
            ctx.beginPath()
            for (j = 0; j < run.length; j++) {
              if (j === 0) ctx.moveTo(run[j][0], run[j][1])
              else ctx.lineTo(run[j][0], run[j][1])
            }
            ctx.strokeStyle = tint
            ctx.lineWidth = 1.4
            ctx.stroke()
          }
        }
        draw("down", true, chart.tintDown)
        draw("up", false, chart.tintUp)

        // Top-of-scale label so the silhouette has magnitude.
        ctx.font = "10px " + root.contentFontFamily
        ctx.textBaseline = "top"
        ctx.fillStyle = Qt.darker(root.contentForeground, 1.4)
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
    contentHeight: panel.fittedContentHeight(contentCol.implicitHeight)

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

        Column {
          id: contentCol
          width: parent.width
          spacing: Style.space(12)

          // ---- Hero: network glyph · connection name + state · actions
          Item {
            width: parent.width
            implicitHeight: heroIcon.implicitHeight

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.wifi ? "󰖩" : "󰈀"
              color: root.accented
              opacity: root.info.type ? 1.0 : 0.55
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: heroActions.width + Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                id: heroTitle
                textFormat: Text.PlainText
                width: parent.width
                text: root.connectionName
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: text !== ""
                text: root.iface !== ""
                  ? (root.iface.toUpperCase() + (root.stateLabel ? " · " + root.stateLabel : ""))
                  : root.stateLabel
                color: root.textDim1
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
              }
            }

            Row {
              id: heroActions
              spacing: Style.space(4)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

              PanelActionButton {
                iconText: "󰑓"
                tooltipText: "Refresh (R)"
                foreground: root.contentForeground
                onClicked: root.refresh()
              }
              PanelActionButton {
                iconText: "󰅖"
                tooltipText: "Close (Esc)"
                foreground: root.contentForeground
                onClicked: root.close()
              }
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---- Hero: live down/up
          Row {
            width: parent.width
            spacing: Style.space(24)

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.space(2)

              Text {
                text: "DOWNLOAD"
                color: root.textDim1
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
              }
              Text {
                text: root.heroDown
                color: root.accented
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }
              Text {
                text: "session \u2193 " + root.sessionDownStr
                color: root.textDim2
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
              Text {
                text: "total " + root.totalDown
                color: root.textDim1
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
            }
            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.space(2)

              Text {
                text: "UPLOAD"
                color: root.textDim1
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
              }
              Text {
                text: root.heroUp
                color: root.secondary
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }
              Text {
                text: "session \u2193 " + root.sessionUpStr
                color: root.textDim2
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
              Text {
                text: "total " + root.totalUp
                color: root.textDim1
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---- Usage history chart
          Item {
            width: parent.width
            height: Style.space(110)

            HistoryChart {
              anchors.fill: parent
              history: root.history
              windowSecs: root.chartWindow
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---- Connection details
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
              value: (root.info.wifiBand ? root.info.wifiBand + "" : "")
                + (root.info.wifiChan ? "  \u00b7  ch " + root.info.wifiChan : "")
            }
            InfoRow {
              visible: root.wifi
              label: "LINK RATE"
              value: root.wifiLinkRate ? root.wifiLinkRate + " Mbit/s" : "--"
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
            InfoRow {
              label: "STATUS"
              value: root.info.state || "--"
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

          // ---- Per-app usage
          PanelTitle { text: "PER-APP USAGE" }
          Text {
            width: parent.width
            text: "Bytes attributed from live TCP sockets, sampled every "
              + Math.round(root.ssPollMs / 1000) + "s. Totals are this session."
            color: Qt.darker(root.contentForeground, 1.8)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Column {
            width: parent.width
            spacing: Style.space(2)

            // Column headings above the per-app rows.
            Item {
              width: parent.width
              height: Style.space(26)
              Text {
                anchors.left: parent.left
                anchors.top: parent.top
                text: "APP"
                color: root.textDim1
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.2
              }
              Text {
                anchors.right: parent.right
                anchors.top: parent.top
                text: "CONN"
                color: root.textDim1
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.2
              }
              Text {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.topMargin: Style.space(13)
                text: "\u2193 / \u2191 LIVE RATE"
                color: root.textDim1
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.2
              }
              Text {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: Style.space(13)
                text: "\u2193 / \u2191 THIS SESSION"
                color: root.textDim1
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.2
              }
            }

            Repeater {
              model: root.appRows.length > 12 ? root.appRows.slice(0, 12) : root.appRows
              delegate: Item {
                required property var modelData
                id: appRow
                readonly property string safeName: String(modelData.name)
                  .replace(/[<>\u0000-\u001F\u007F]/g, " ")
                width: parent ? parent.width : 0
                height: Style.space(44)

                Text {
                  id: appName
                  anchors.top: parent.top
                  anchors.left: parent.left
                  text: appRow.safeName
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  width: Math.min(Style.space(210), parent.width - Style.space(120))
                }
                Text {
                  anchors.top: parent.top
                  anchors.left: appName.right
                  anchors.leftMargin: Style.space(6)
                  anchors.topMargin: Style.space(1)
                  text: "(" + String(modelData.pid) + ")"
                  color: Qt.darker(root.contentForeground, 1.8)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.top: appName.bottom
                  anchors.topMargin: Style.space(2)
                  anchors.left: parent.left
                  text: "\u2193 " + Model.fmtSpeed(modelData.rateDown)
                    + "   \u2191 " + Model.fmtSpeed(modelData.rateUp)
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  anchors.right: parent.right
                  anchors.top: appName.bottom
                  anchors.topMargin: Style.space(3)
                  text: "\u2193 " + Model.fmtBytes(modelData.down)
                    + "   \u2191 " + Model.fmtBytes(modelData.up)
                  color: Qt.darker(root.contentForeground, 1.6)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  anchors.right: parent.right
                  anchors.top: parent.top
                  text: modelData.conns === 1 ? "1 conn" : modelData.conns + " conns"
                  color: Qt.darker(root.contentForeground, 1.6)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
                Rectangle {
                  anchors.bottom: parent.bottom
                  anchors.left: parent.left
                  anchors.right: parent.right
                  height: 1
                  color: root.contentForeground
                  opacity: 0.05
                }
              }
            }

            InfoRow {
              visible: root.appRows.length === 0
              label: ""
              value: "No attributable connections yet."
            }
          }
        }
      }
    }
  }
}