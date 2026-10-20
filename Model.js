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

// The socket row cap. This is the plugin's own ceiling, not the producer's:
// iproute2 `ss` has no output-size option (`-b` is `--bpf`, root-only, and
// unrelated), so the only way to bound the work is to stop READING. The socket
// table is machine-wide -- any local account in the shared network namespace can
// open established sockets -- and every row costs a split and a regex scan even
// when it is discarded for having no `users:` attribution. Counting rows here
// means the shell's work per poll is proportional to this constant rather than
// to whatever the rest of the machine is doing.
//
// Chosen well above a busy desktop's established-socket count (this machine
// idles at ~20) so it never bites in normal use; when it does bite the panel
// says so rather than quietly under-reporting.
var SS_MAX_ROWS = 512

// One socket occupies a record LINE (the columns plus `users:(...)`) followed by
// an info LINE starting with a tab that carries `bytes_sent`/`bytes_received`.
// Both are needed for one attribution, so the reader carries the previous line
// forward as `pending` and only emits when it can pair the two.
//
// This is deliberately a per-line step rather than a whole-text parse: the
// panel now feeds it line by line from a SplitParser, which is what lets the
// reader stop mid-stream once the row cap is reached. Streaming also means no
// second copy of the output exists as a split array.
function ssLineStep(line, state) {
  var text = String(line)
  var st = state || { pending: null, apps: {}, next: {}, rows: 0 }

  // An info line belongs to the socket row that preceded it.
  if (st.pending !== null) {
    var held = st.pending
    st.pending = null
    var ii = SS_INFO_RE.exec(text)
    if (ii) emitSS(held, parseInt(ii[1], 10) || 0, parseInt(ii[2], 10) || 0, st)
    return st
  }

  // Otherwise this must be a socket row to be usable at all.
  if (!SS_PROC_RE.test(text)) return st
  st.pending = text
  return st
}

// Fold one paired socket into the accumulated apps and the baselines.
function emitSS(rowLine, sent, recv, st) {
  var pm = SS_PROC_RE.exec(rowLine)
  var cols = rowLine.substring(0, pm.index).trim().split(/\s+/)
  // Need at least Recv-Q, Send-Q, Local and Peer ahead of the process group.
  if (cols.length < 4) return
  var proc = pm[1]
  var pid = pm[2]
  var local = cols[cols.length - 2]
  var remote = cols[cols.length - 1]
  var fd = pm[3]
  var key = pid + "|" + local + "|" + remote + "|" + fd
  var baseline = st.baseline ? st.baseline[key] : null
  var dSent = 0
  var dRecv = 0
  if (baseline && sent >= baseline.sent && recv >= baseline.recv) {
    dSent = sent - baseline.sent
    dRecv = recv - baseline.recv
  }
  st.next[key] = { sent: sent, recv: recv }
  var app = st.apps[pid]
  if (!app) app = st.apps[pid] = { pid: pid, name: proc, deltaDown: 0, deltaUp: 0, conns: 0 }
  app.deltaDown += dRecv
  app.deltaUp += dSent
  app.conns++
  st.rows++
}

function ssState(prev) {
  return { pending: null, apps: {}, next: {}, rows: 0, baseline: prev || {} }
}

// Finalise a stream of `ss` lines into the same shape parseSS has always
// returned. Kept as the batch entry point (and the shape the tests exercise);
// the panel drives ssLineStep directly so it can stop at the cap.
function parseSS(text, prev) {
  var lines = String(text).split("\n")
  var st = ssState(prev)
  for (var i = 0; i < lines.length; i++) ssLineStep(lines[i], st)
  return finishSS(st)
}

function finishSS(st) {
  var list = []
  for (var k in st.apps) list.push(st.apps[k])
  list.sort(function(a, b) { return (b.deltaDown + b.deltaUp) - (a.deltaDown + a.deltaUp) })
  // `rows` is how many sockets were actually attributed, so the caller can tell
  // a complete reading from one that ran into the row cap.
  return { apps: list, next: st.next, rows: st.rows }
}

// ------------------------------------------------------------- formatting

// Left/right pad to an exact character width. Not String.padStart/padEnd:
// this file is deliberately ES5 and runs under QJSEngine/Quickshell, where
// those are not reliably present.
function padLeft(s, w) {
  var out = String(s)
  while (out.length < w) out = " " + out
  return out
}

function padRight(s, w) {
  var out = String(s)
  while (out.length < w) out = out + " "
  return out
}

// Rendered widths. The bar repaints the label on every sample, so a string that
// changes LENGTH moves everything to its right; toFixed() guarantees a decimal
// point but not a width, which is why the widget used to swing between 5 and 11
// characters. Every value is padded into a fixed cell instead.
//
// The separating space is its own column and is NOT counted in the unit width:
// unit width is 5 for both formatters, so fmtSpeed and fmtBytes produce the
// same 12-character cell and the totals in the tooltip line up with the speeds
// above them. That consistency is the point of sharing the two widths rather
// than sizing each formatter to its own longest unit.
var SPEED_UNIT_WIDTH = 5
var SPEED_NUM_WIDTH = 6
var BYTES_UNIT_WIDTH = 5
var BYTES_NUM_WIDTH = 6
// Compact form ("768K") drops the /s, spells the unit as one letter, and shows
// a whole number of that unit: the request was "768K", not "768.4K", and a
// figure this short is read at a glance rather than measured, so the decimal
// is noise. The cell is 5 characters instead of 12. Rounding to whole units
// costs at most half a unit, which is why the tooltip keeps the full form --
// see BarWidget's tooltip, which re-formats from the raw values rather than
// reusing the compact label string.
var COMPACT_UNIT_WIDTH = 1
var COMPACT_NUM_WIDTH = 4

// Promote at 1023.5, not 1024. Promotion has to happen before ROUNDING can
// push the rendered number across the unit boundary, and the two branches round
// at different points: the integer B/s branch rounds at 1023.5 (Math.round),
// the decimal branches at 1023.95 (toFixed(1)). Testing >= 1024 left both holes
// open -- 1023.9 rendered as "1024 B/s", and 1048575 as the impossible
// "1024.0KiB/s". One threshold at the earliest of the two covers both: nothing
// below 1023.5 can round up to 1024 in either branch.
//
// Consequence, relied on by the tests: a value in a non-maximum unit always
// renders below 1024. Only the top unit (TiB) is allowed to exceed it, because
// there is nothing to promote into.
var PROMOTE_AT = 1023.5

// Shared scale/format core: divide down into the largest unit where the value
// sits below the promotion threshold, and report the unit index. Callers decide
// how to render the number in that unit.
function scaleUnits(value, units, promoteAt) {
  var v = value
  var u = 0
  while (v >= promoteAt && u < units.length - 1) { v /= 1024; u++ }
  return { v: v, u: u }
}

// Speed with the figure and its unit decided, but neither rendered yet. Both
// the padded formatters and the bar's bare formatter go through this, so the
// two can never disagree about what a value is.
function speedParts(bytesPerSec, compact) {
  if (compact) {
    var cUnits = ["B", "K", "M", "G", "T"]
    var c = scaleUnits(bytesPerSec, cUnits, PROMOTE_AT)
    // Always a whole number of the chosen unit: the point of the compact form
    // is fewer characters, and a decimal point is one of them. Promotion still
    // happens at PROMOTE_AT, so no unit can render a number >= 1024.
    return { num: String(Math.round(c.v)), unit: cUnits[c.u] }
  }
  var units = ["B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s"]
  var s = scaleUnits(bytesPerSec, units, PROMOTE_AT)
  return { num: s.u === 0 ? String(Math.round(s.v)) : s.v.toFixed(1), unit: units[s.u] }
}

function fmtSpeed(bytesPerSec, compact) {
  // "--" is returned unpadded, deliberately. It is the no-reading case: the
  // bar hides its label entirely until the first sample (BarWidget's `visible:
  // ready`), and a 12-character block of spaces and dashes in the tooltip would
  // read as a broken column rather than as "nothing yet". Padding a value that
  // exists, and leaving a value that does not alone, is the only combination
  // that is never wrong.
  if (!isFinite(bytesPerSec) || bytesPerSec < 0) return "--"
  var p = speedParts(bytesPerSec, compact)
  if (compact) {
    return padLeft(p.num, COMPACT_NUM_WIDTH)
      + padRight(p.unit, COMPACT_UNIT_WIDTH)
  }
  return padLeft(p.num, SPEED_NUM_WIDTH) + " " + padRight(p.unit, SPEED_UNIT_WIDTH)
}

// Width of one bar cell: the arrow, then exactly the fields the padded form
// above reserves. See fmtSpeedCell for how a cell is laid out inside them.
var BAR_ARROW_WIDTH = 1
var BAR_CELL_WIDTH = BAR_ARROW_WIDTH + SPEED_NUM_WIDTH + 1 + SPEED_UNIT_WIDTH
var BAR_CELL_WIDTH_COMPACT = BAR_ARROW_WIDTH + COMPACT_NUM_WIDTH + COMPACT_UNIT_WIDTH

function barCellWidth(compact) {
  return compact ? BAR_CELL_WIDTH_COMPACT : BAR_CELL_WIDTH
}

// A rate as a plain string: figure, separator, unit, and no padding anywhere.
//
// fmtSpeed's cell is right-aligned for tables, where a unit column that lines
// up down the page is the point. Everywhere else the padding is in the way: it
// puts three blank characters in front of a short figure, and a figure followed
// by blank space renders as if it were indented. This is what the dropdown's
// download/upload values use, each of which sits in its own block next to its
// own glyph rather than in a column with anything.
function fmtSpeedBare(bytesPerSec, compact) {
  if (!isFinite(bytesPerSec) || bytesPerSec < 0) return "--"
  var p = speedParts(bytesPerSec, compact)
  return compact ? p.num + p.unit : p.num + " " + p.unit
}

// One bar cell: the arrow, the figure, the separator, the unit.
//
// The figure is padded on its RIGHT, into a fixed field, rather than the cell
// being padded after the unit. Both give a cell of the same width for every
// figure -- which is the point, since a label that changes width moves
// everything to its right in the bar -- but they put the slack in different
// places, and it shows.
//
// Padding the cell puts the slack at the end, so the gap between the download
// half and the upload half is that slack plus the separator between the two
// cells: five characters of blank for a three-character figure, and the two
// stats look like they belong to different widgets while the bar spends the
// width on nothing. Padding the figure instead puts the slack between the
// figure and its own unit, which is inside the stat, so the gap between the
// two stats is the separator and nothing else, the same on every sample.
//
// The arrow still sits against the figure -- the slack is behind the figure, not
// in front of it -- so the arrow stays glued to the number it labels. And the
// figure is still LEFT-aligned, so the figure and its unit never come apart by
// more than the slack; it is the unit that ends up in a different column from
// one sample to the next, which reads as the figure growing.
function fmtSpeedCell(arrow, bytesPerSec, compact) {
  var num = "--"
  var unit = ""
  if (isFinite(bytesPerSec) && bytesPerSec >= 0) {
    var p = speedParts(bytesPerSec, compact)
    num = p.num
    unit = p.unit
  }
  // Compact drops both the separator and the /s, so its figure and unit are one
  // run of characters with nothing to align to: pad the whole run rather than
  // the figure alone, which would put a gap inside "768K".
  if (compact) return padRight(arrow + num + unit, barCellWidth(true))
  return padRight(arrow + padRight(num, SPEED_NUM_WIDTH) + " "
                  + padRight(unit, SPEED_UNIT_WIDTH), barCellWidth(false))
}

function fmtBytes(bytes) {
  if (!isFinite(bytes) || bytes < 0) return "--"
  var units = ["B", "KiB", "MiB", "GiB", "TiB"]
  var b = scaleUnits(bytes, units, PROMOTE_AT)
  var num = b.u === 0 ? String(Math.round(b.v)) : b.v.toFixed(1)
  return padLeft(num, BYTES_NUM_WIDTH) + " " + padRight(units[b.u], BYTES_UNIT_WIDTH)
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