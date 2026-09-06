// Data parsing + formatting for the Net Speed dropdown panel.
// Pure JS so it stays testable with node; all input is kernel/NM output
// reached through this plugin's own Processes.

.pragma library

function excludeRx() {
  return /^lo$|^docker\d*|^br-.+|^virbr\d*|^veth.*|^vboxnet\d*/i
}

// ------------------------------------------------------------------ dev

function parseDev(text) {
  var lines = String(text).split("\n")
  var ifaces = []
  var rx = 0
  var tx = 0
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var idx = line.indexOf(":")
    if (idx < 0) continue
    var name = line.substring(0, idx).trim()
    if (!name || excludeRx().test(name)) continue
    var parts = line.substring(idx + 1).trim().split(/\s+/)
    if (parts.length < 9) continue
    var ifRx = parseInt(parts[0], 10) || 0
    var ifTx = parseInt(parts[8], 10) || 0
    rx += ifRx
    tx += ifTx
    ifaces.push({ name: name, rx: ifRx, tx: ifTx })
  }
  return { rx: rx, tx: tx, ifaces: ifaces }
}

function rates(prev, cur, secs) {
  if (!prev || !cur || !secs || secs <= 0) return null
  var prevMap = {}
  for (var i = 0; i < prev.ifaces.length; i++) prevMap[prev.ifaces[i].name] = prev.ifaces[i]
  var out = []
  var totalDown = 0
  var totalUp = 0
  for (var j = 0; j < cur.ifaces.length; j++) {
    var c = cur.ifaces[j]
    var p = prevMap[c.name] || null
    var down = 0
    var up = 0
    if (p) {
      down = Math.max((c.rx - p.rx) / secs, 0)
      up = Math.max((c.tx - p.tx) / secs, 0)
    }
    totalDown += down
    totalUp += up
    out.push({ name: c.name, down: down, up: up })
  }
  return { ifaces: out, down: totalDown, up: totalUp }
}

function pushHistory(arr, sample, max) {
  var next = arr.slice(0, Math.max(0, max - 1))
  next.push(sample)
  return next
}

function maxOf(history, field) {
  var m = 0
  for (var i = 0; i < history.length; i++) {
    var v = history[i][field]
    if (v > m) m = v
  }
  return m
}

// ----------------------------------------------------------------- route

function parseDefaultRoute(text) {
  var arr = null
  try { arr = JSON.parse(text) } catch (e) { return "" }
  if (!Array.isArray(arr)) return ""
  for (var i = 0; i < arr.length; i++) {
    var r = arr[i]
    if (r && r.dev) return String(r.dev)
  }
  return ""
}

// ----------------------------------------------------------------- nmcli

// Pick the AP block flagged IN-USE so the connected access point's own
// fields (5GHz band, channel, link rate) come out instead of the first
// BSSID's.
function parseNmcli(text) {
  var lines = String(text).split("\n")
  var out = {}
  var useIdx = -1
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    if (line.indexOf("AP[") === 0 && line.indexOf("].IN-USE:") !== -1) {
      var mm = line.match(/^AP\[(\d+)\]\./)
      if (mm && line.indexOf("*") !== -1) useIdx = parseInt(mm[1], 10)
    }
  }
  for (var j = 0; j < lines.length; j++) {
    var raw = lines[j].trim()
    if (raw === "") continue
    var idx = raw.indexOf(":")
    if (idx < 0) continue
    var key = raw.substring(0, idx).trim()
    var val = raw.substring(idx + 1).trim()
    if (key.indexOf("DHCP4.OPTION") === 0) {
      var dm = val.match(/^expiry\s*=\s*(\d+)/)
      if (dm) out.leaseUntil = parseInt(dm[1], 10)
      continue
    }
    // AP fields: only keep the block that is in use
    if (key.indexOf("AP[") === 0) {
      var em = key.match(/^AP\[(\d+)\]\.(\w+)$/)
      if (!em) continue
      var apIdx = parseInt(em[1], 10)
      if (apIdx !== useIdx) continue
      out["wifi." + em[2].toLowerCase()] = val
      continue
    }
    if (key.indexOf("IP6.ADDRESS[") === 0 || key.indexOf("IP4.ADDRESS[") === 0) {
      var im = key.match(/^IP(\d)\./)
      if (im) {
        var ver = im[1] === "6" ? "ip6" : "ip"
        if (!Array.isArray(out[ver])) out[ver] = []
        out[ver].push(val)
      }
      continue
    }
    if (key.indexOf("IP4.DNS[") === 0) {
      if (!Array.isArray(out.dns)) out.dns = []
      out.dns.push(val)
      continue
    }
    out[key] = val
  }

  var info = {}
  info.iface = out["GENERAL.IP-IFACE"] || out["GENERAL.DEVICE"] || ""
  info.device = out["GENERAL.DEVICE"] || ""
  info.type = out["GENERAL.TYPE"] || ""
  info.vendor = out["GENERAL.VENDOR"] || ""
  info.product = out["GENERAL.PRODUCT"] || ""
  info.driver = out["GENERAL.DRIVER"] || ""
  info.firmware = out["GENERAL.FIRMWARE-VERSION"] || ""
  info.mac = out["GENERAL.HWADDR"] || ""
  info.mtu = out["GENERAL.MTU"] || ""
  info.connection = out["GENERAL.CONNECTION"] || ""
  info.state = out["GENERAL.STATE"] || ""
  info.metered = out["GENERAL.METERED"] || ""
  info.gateway = out["IP4.GATEWAY"] || ""
  info.ip = Array.isArray(out.ip) ? out.ip : []
  info.ip6 = Array.isArray(out.ip6) ? out.ip6 : []
  info.dns = Array.isArray(out.dns) ? out.dns : []
  info.leaseUntil = out.leaseUntil || 0
  info.wifiSsid = out["wifi.ssid"] || ""
  info.wifiBand = out["wifi.band"] || ""
  info.wifiChan = out["wifi.chan"] || ""
  info.wifiRate = out["wifi.rate"] || ""
  info.wifiSignal = out["wifi.signal"] || ""
  info.wifiBars = out["wifi.bars"] || ""
  info.wifiSecurity = out["wifi.security"] || ""
  return info
}

// ------------------------------------------------------------------- ss

var SS_LINE_RE = /^(\S+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)/
var SS_PROC_RE = /users:\(\(\"([^"]*)",\s*pid=(\d+),\s*fd=(\d+)\)\)/
var SS_INFO_RE = /bytes_sent:(\d+).*?bytes_received:(\d+)/i

// `prev` maps "pid|local|remote|fd" -> { sent, recv } from the last poll.
// Returns the deltas per process and the next map to feed forward.
function parseSS(text, prev) {
  var lines = String(text).split("\n")
  var apps = {}
  var next = {}
  for (var i = 0; i < lines.length; i++) {
    var m = SS_LINE_RE.exec(lines[i])
    if (!m) continue
    var p = SS_PROC_RE.exec(lines[i])
    if (!p) continue  // no process attribution (foreign/root sockets)
    var proc = p[1]
    var pid = p[2]
    var local = m[4]
    var remote = m[5]
    var fd = p[3]
    var sent = 0
    var recv = 0
    if (i + 1 < lines.length) {
      var ii = SS_INFO_RE.exec(lines[i + 1])
      if (ii) {
        sent = parseInt(ii[1], 10) || 0
        recv = parseInt(ii[2], 10) || 0
      }
    }
    var key = pid + "|" + local + "|" + remote + "|" + fd
    var p = prev ? prev[key] : null
    var dSent = 0
    var dRecv = 0
    if (p && typeof p.sent === "number" && sent >= p.sent && recv >= p.recv) {
      dSent = sent - p.sent
      dRecv = recv - p.recv
    }
    next[key] = { sent: sent, recv: recv }
    var app = apps[pid] || (apps[pid] = { pid: pid, name: proc, deltaDown: 0, deltaUp: 0, conns: 0 })
    app.deltaDown += dRecv
    app.deltaUp += dSent
    app.conns++
  }
  var list = []
  for (var k in apps) list.push(apps[k])
  list.sort(function(a, b) { return (b.deltaDown + b.deltaUp) - (a.deltaDown + a.deltaUp) })
  return { apps: list, next: next }
}

// ------------------------------------------------------------- formatting

function fmtSpeed(bytesPerSec) {
  if (!isFinite(bytesPerSec) || bytesPerSec < 0) return "--"
  var units = ["B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s"]
  var v = bytesPerSec
  var u = 0
  while (v >= 1024 && u < units.length - 1) { v /= 1024; u++ }
  return (u === 0 ? Math.round(v) + " " : v.toFixed(1)) + units[u]
}

function fmtBytes(bytes) {
  if (!isFinite(bytes) || bytes < 0) return "--"
  var units = ["B", "KiB", "MiB", "GiB", "TiB"]
  var v = bytes
  var u = 0
  while (v >= 1024 && u < units.length - 1) { v /= 1024; u++ }
  return (u === 0 ? Math.round(v) + " " : v.toFixed(1)) + units[u]
}

function fmtRemaining(secs) {
  if (!isFinite(secs) || secs <= 0) return "--"
  var s = Math.round(secs)
  var d = Math.floor(s / 86400)
  var h = Math.floor((s % 86400) / 3600)
  var m = Math.floor((s % 3600) / 60)
  if (d > 0) return d + "d " + h + "h"
  if (h > 0) return h + "h " + m + "m"
  return m + "m " + (s % 60) + "s"
}