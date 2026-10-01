# Changelog

All notable changes to this project will be documented in this file.

## [2.1.0] - 2026-10-01

### Added
- **`interfaces` setting** — monitor an explicit set of interfaces (`"enp5s0"` or `["wlan0", "enp5s0"]`) instead of every non-virtual one. A named interface is always honoured, including a virtual one, so you can opt back into counting a tunnel
- **VPN and tunnel interfaces are excluded by default** — `wg*`, `tailscale*`, `tun*`, `tap*`, `sit*`, `gre*`, `ip6tnl*`, `ip6gre*`, `ham*`, `zt*`, plus container/cluster networks (`cni*`, `podman*`, `flannel*`, `lxcbr*`, `kube*`, `nomad*`, `vmnet*`, `vnic*`) and traffic-shaping devices (`dummy*`, `ifb*`, `teql*`, `bond_slave*`)

### Fixed
- **Scroll-to-resize deleted your other settings** — `setSize()` sent a bare `{ fontSize }` to `updateEntryInline`, which *replaces* the whole `shell.json` layout entry. The first scroll over the widget dropped `interval` (and any other key) from your config and silently reverted it to the default. The full entry is now merged back, and applied locally so the label resizes on the same event
- **Throughput double-counted behind a VPN** — a WireGuard/Tailscale interface re-counts every byte that already crossed the physical NIC, so the bar read up to 2× real speed and the session totals were inflated for the life of the shell
- **Interfaces past the 32nd were silently dropped** — the `/proc/net/dev` read was capped with `head -n 34`, and `head -c 4096` could cut a counter mid-number, reading a truncated value as if it were whole (a bogus speed spike and a wrong total for that sample). The file is now read directly with `cat` and the budget lives in the parser: an incomplete trailing line is discarded, and a line short of the kernel's 16 counter columns is skipped rather than misread
- **Refresh could be silently dropped** — `sampleProc.running = true` is a no-op on an already-running process, so a middle-click or `omarchy shell send davedes.netspeed refresh` landing mid-sample did nothing. Now guarded like the panel's own processes
- **The dropdown spawned processes at shell start** — `Component.onCompleted` ran `ss`/`ip`/`nmcli` even though the panel is never open then. Polling now starts on open
- **`nmcli`/`iw` command rewritten mid-run** — the command was reassigned while the process could still be running; the update is now deferred to the next poll instead
- **Parser could misreport a failed read as zero** — a read with no usable interface returns `null`, keeping the previous sample rather than collapsing the totals
- **README shell.json snippet was wrong** — it showed `bar.right` instead of `bar.layout.right`, so a pasted config was silently ignored

### Changed
- **`ss` is limited to established sockets** (`ss -tinp state established`) — a socket only moves bytes once established, so nothing is lost, while the `SYN-SENT`/`TIME-WAIT` noise per poll disappears and the connection count reflects live connections
- **`ss` parser no longer relies on fixed column offsets** — adding a `state` filter makes `ss` drop the leading `State` column, shifting every column left; the parser now anchors on the process group and takes the last two address fields before it, which is correct for both layouts
- **Per-app row assembly is single-pass** — the nested pid lookup is gone (`rows` is built in one pass over `appCum`), and pids are normalised to strings so the match cannot silently stop working
- **One source of truth for parsing and units** — the widget's private copies of the `/proc/net/dev` parser, the interface filter and the byte/speed formatters are gone; everything goes through `Model.js`, so the bar label, tooltip and dropdown cannot drift apart

## [2.0.0] - 2026-09-06

### Added
- **Theme-aware dropdown** — The whole panel (hero, chart, rows, buttons) is coloured entirely from the active Omarchy theme (accent/muted tones, no hardcoded hex colours)
- **Hero** — Connection name, live state label, and refresh/close buttons
- **Chart window selector** — 5 / 15 / 30-minute pills; the axis always spans the full selected window with live data right-aligned at the edge
- **30-minute history buffer** — History length scales with the configured sample interval
- **NETWORK section** — Full connection details from `nmcli`/`ip`/`iw`: connection, interface, type, SSID, signal, band, live link rate, security, IP, gateway, DNS, status, MAC, MTU, DHCP lease, driver, metered flag
- **PER-APP USAGE** — Live down/up rates plus session totals and connection counts per app, with column headings (`APP`, `CONN`, `LIVE RATE`, `THIS SESSION`)

### Fixed
- **Per-app uploads misread** — `ss -i` inserts a `bytes_retrans:` field when a connection retransmits, which the parser required between `bytes_sent` and `bytes_acked`; upload-heavy sockets read as 0 in/out. Parser now matches `bytes_sent`/`bytes_received` order-independently
- **Per-app never populated** — `property var X: {}` object-literal initialisers were dropped by the QML engine (leaving `appCum`/`prevConn` undefined so the `ss` handler returned early); initialised with `({})`
- **Per-app burst loss** — ss poll interval lowered from 3s to 1.5s so short-lived streams are more likely to span a sample

### Changed
- Panel content height now autosizes (`fittedContentHeight`) instead of a fixed 660px
- Removed the redundant INTERFACES section; BAND and LINK RATE split into their own rows

## [1.2.1] - 2026-08-29

### Security
- **Process**: Restored the hard output cap (`head -n 34 | head -c 4096`) on `/proc/net/dev` produced per sample
- **parseSample**: Restored the per-field length budget before integer parsing
- **sanitizeLabel**: Interface names are now stripped of rich-text angle brackets and control characters before entering the shell tooltip

## [1.2.0] - 2026-08-26

### Changed
- **formatSpeed**: Use proper binary unit labels (KiB/s, MiB/s, GiB/s, TiB/s) matching 1024-base calculation
- **formatTotal**: New function for formatting cumulative totals with binary units (KiB, MiB, GiB, TiB)
- **applySample**: Optimized per-interface lookup from O(n²) to O(n) using a map
- **setSize**: Simplified settings update to only send changed fontSize property
- **Process**: Changed `head -c 4096` to `cat` to support systems with many interfaces
- **Process**: Added error handling for failed `/proc/net/dev` reads

### Fixed
- Total counters in tooltip now display as data amounts (KiB/MiB) instead of speeds (KiB/s)

## [1.1.0] - 2026-08-26

### Added
- Initial release with live network speed monitoring
- EMA smoothing for stable display
- Per-interface breakdown in tooltip
- IPC controls for font size and refresh
- Configurable sample interval and font size