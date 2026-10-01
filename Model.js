// Data parsing + formatting for the Net Speed dropdown panel.
// Pure JS so it stays testable with node; all input is kernel/NM output
// reached through this plugin's own Processes.

.pragma library

// ---------------------------------------------------------------- interfaces

// Never real WAN traffic: loopback, container bridges/veth pairs, and VPN or
// tunnel overlays. The tunnel entries matter most -- a WireGuard/Tailscale
// interface re-counts every byte that already crossed the physical NIC, so
// including one double-reports throughput and inflates the totals for the
// lifetime of the session.
var VIRTUAL_IFACE_RE = /^lo\d*$|^docker\d*|^br-|^virbr\d*|^veth|^vboxnet\d*|^vmnet\d*|^vnic|^zt|^ham\d|^wg\d|^tailscale\d|^tun\d|^tap\d|^sit\d|^gre\d|^ip6tnl\d|^ip6gre\d|^cni\d|^podman\d|^flannel|^lxcbr|^kube|^nomad|^dummy\d|^ifb\d|^teql\d|^bond_slave/i

// Kernel interface names are capped at IFNAMSIZ (16 bytes incl. NUL) and
// dev_valid_name() rejects whitespace and control characters, so these budgets
// are about bounding work per sample, not about taming hostile input.
var MAX_SCAN_LINES = 512
var MAX_IFACES = 64
var MAX_FIELD_LEN = 20

// Interface names reach the shell tooltip: strip rich-text markup and
// control characters.
function sanitizeIface(value) {
  return String(value).replace(/[<>]/g, "").replace(/[\u0000-\u001F\u007F]/g, " ")
}

// Resolve the `interfaces` setting into an exact-name allowlist. Accepts an
// array or a comma/whitespace separated string; empty means "every
// non-virtual interface". An explicitly named interface is always honoured,
// including a virtual one -- listing tailscale0 or docker0 is how you ask to
// watch exactly that and nothing else.
function ifaceAllowList(value) {
  if (value === undefined || value === null) return []
  var raw = Array.isArray(value) ? value : String(value).split(/[\s,]+/)
  var names = []
  for (var i = 0; i < raw.length; i++) {
    var n = sanitizeIface(String(raw[i]).trim())
    if (n && n.length <= 16 && names.indexOf(n) === -1) names.push(n)
  }
  return names
}

// Parse /proc/net/dev into aggregate counters plus a per-interface breakdown.
// Returns null when the read yielded no usable interface, so a failed or
// garbled read keeps the previous sample instead of reporting zeroes.
function parseDev(text, allow) {
  var allowList = allow || []
  var explicit = allowList.length > 0
  var lines = String(text).split("\n")
  // A read that did not end in a newline was cut off mid-line (an upstream
  // output cap, a short read). Drop the fragment rather than read a partial
  // counter as if it were whole.
  if (lines.length > 1 && lines[lines.length - 1] !== "") lines.pop()
  var rx = 0
  var tx = 0
  var ifaces = []
  var counted = 0
  var scanned = 0
  for (var i = 0; i < lines.length; i++) {
    if (scanned >= MAX_SCAN_LINES || counted >= MAX_IFACES) break
    var line = lines[i]
    var idx = line.indexOf(":")
    if (idx < 0) continue
    scanned++
    var name = line.substring(0, idx).trim()
    if (!name) continue
    if (explicit ? allowList.indexOf(name) === -1 : VIRTUAL_IFACE_RE.test(name)) continue
    var parts = line.substring(idx + 1).trim().split(/\s+/)
    // The kernel writes exactly 16 counter columns per interface, so anything
    // short of that is a line we did not receive in full.
    if (parts.length < 16) continue
    // A counter wider than any real byte count means a garbled read. Skip the
    // interface rather than accept a nonsensical value. Never "fix" this by
    // trimming the field: a shortened number is a different number, whereas
    // counting above 2^53 only costs sub-byte precision on the delta, which
    // is irrelevant at display resolution.
    if (parts[0].length > MAX_FIELD_LEN || parts[8].length > MAX_FIELD_LEN) continue
    var ifRx = parseInt(parts[0], 10)
    var ifTx = parseInt(parts[8], 10)
    if (!isFinite(ifRx) || !isFinite(ifTx)) continue
    rx += ifRx
    tx += ifTx
    counted++
    var safeName = sanitizeIface(name)
    if (safeName) ifaces.push({ name: safeName, rx: ifRx, tx: ifTx })
  }
  return counted > 0 ? { rx: rx, tx: tx, ifaces: ifaces } : null
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

// Anchored on the process group rather than on fixed column offsets: `ss`
// omits the leading State column when a `state` filter is in effect (e.g.
// `ss -tinp state established`), so the Recv-Q/Send-Q/Local/Peer columns shift
// left by one. Everything before the process group ends with Local then Peer,
// which holds for both layouts.
var SS_PROC_RE = /users:\(\(\"([^"]*)",\s*pid=(\d+),\s*fd=(\d+)\)\)/
var SS_INFO_RE = /bytes_sent:(\d+).*?bytes_received:(\d+)/i

// `prev` maps "pid|local|remote|fd" -> { sent, recv } from the last poll.
// Returns the deltas per process and the next map to feed forward.
function parseSS(text, prev) {
  var lines = String(text).split("\n")
  var apps = {}
  var next = {}
  for (var i = 0; i < lines.length; i++) {
    var pm = SS_PROC_RE.exec(lines[i])
    if (!pm) continue  // no process attribution (foreign/root sockets, headers)
    var cols = lines[i].substring(0, pm.index).trim().split(/\s+/)
    // Need at least Recv-Q, Send-Q, Local and Peer ahead of the process group.
    if (cols.length < 4) continue
    var proc = pm[1]
    var pid = pm[2]
    var local = cols[cols.length - 2]
    var remote = cols[cols.length - 1]
    var fd = pm[3]
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
    var baseline = prev ? prev[key] : null
    var dSent = 0
    var dRecv = 0
    if (baseline && sent >= baseline.sent && recv >= baseline.recv) {
      dSent = sent - baseline.sent
      dRecv = recv - baseline.recv
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