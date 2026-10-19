# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed
- **The bar label is compact by default** — the full form (`↓768.0 KiB/s ↑12.0 KiB/s`) needs 27 characters, most of them fixed-width padding, so at bar sizes it claimed a third of the bar for two short numbers. The default label is now `↓768K ↑12K` (13 characters, less than half the width) with a single space between the halves. Width still never changes between samples, so nothing to its right moves. The hover tooltip and the dropdown hero keep spelling the exact figures out; set `compactSpeed: false` to go back to full units in the bar

### Added
- **`compactSpeed` setting** — a short unit in the bar (`↓768K ↑12K` instead of `↓768.0 KiB/s ↑12.5 KiB/s`), **on by default**. Set it to `false` for full units. It is fixed width like the full form, and the hover tooltip always spells the unit out, so the precision is still one hover away

### Fixed
- **The bar arrows sat far from their own figures** — the label read `↓  12.5 KiB/s  ↑  1.9 KiB/s`. Two paddings stacked up in front of each figure: the fixed-width cell that stops the label resizing, plus a space after the arrow. The arrow therefore floated three or four characters away from the number it labels, further away the shorter the number got. The figure is now padded behind itself instead of in front, and nothing separates an arrow from its figure
- **The download and upload halves sat five characters apart** — the same fixed-width cell padded *after* the unit, so the slack landed in the gap between the two stats rather than inside either of them. A three-character figure therefore spent five blank characters of bar separating two numbers, and the gap changed width as the figures changed length. The slack now goes inside the cell, so the gap between the halves is the single-character separator and nothing else, on every sample. Both arrows and both units stay put
- **The dropdown's download/upload values were indented** — they were built with the table formatter, so a short figure carried its leading figure-field padding into a block that has no column to line up with: `↓    4.6 MiB/s` rather than `↓ 4.6 MiB/s`. They now use the unpadded formatter, which is what that layout wants
- **The bar label jitters** — the speed string changed length between readings (`0 B/s` is 5 characters, `1024.0KiB/s` is 11), so every sample resized the label and moved whatever sits to its right. Every value is now padded into a fixed cell: 12 characters for the full form, 5 for compact. `fmtBytes` shares the same width so the totals in the tooltip line up with the speeds above them
- **The unit-promotion rollover** — `fmtSpeed(1023.9)` rendered `1024 B/s`, a round number in bytes for a value that is just under 1 KiB/s, and `fmtSpeed(1048575)` rendered `1024.0KiB/s`, which is not a value that can exist in that unit. Promotion now happens before rounding can cross the boundary (at 1023.5 rather than 1024), so no unit short of the top one can ever display a number at or above 1024

### Added (tests)
- **`tests/model_test.js`** — Node-runnable unit tests for the formatters: fixed-width cells, the promotion rollover and the no-number-over-1024 invariant, `compactSpeed` on and off, and the negative / non-finite / zero inputs. No dependencies; run with `node tests/model_test.js`

## [2.2.0] - 2026-10-01

### Changed
- **The dropdown is now built from the shell's own UI kit** — `PanelHero`, `PanelSectionHeader`, `PanelSeparator`, `PanelActionButton`, `CursorSurface` and `BorderSurface` instead of hand-rolled equivalents, so the popup tracks the active theme's colours, border specs, corner radius and control states exactly like the first-party panels
- **Hero** — `PanelHero` with the link's live rate promoted into its detail pill (e.g. `866.7 Mbit/s`), and refresh/close moved onto its `trailingControl` edge
- **Spacing** — raw `Style.space(N)` calls replaced with `Style.spacing.*` tokens, so a theme's `[spacing]` density settings now apply to this panel
- **Chart** — gradient-filled areas instead of flat polygons, round-capped strokes, a live head marker on each series, a dashed guide at the top of scale, and a "Collecting samples…" state before enough history exists
- **Per-app rows** — two-line `CursorSurface` rows (identity + connection count, then live rate + session totals) with the shell's shared hover-cursor fill and border; row height now accounts for both lines

### Added
- **Scrollbar** — the dropdown scrolls with a visible `ScrollBar`, with a reserved gutter so it can never clip the right-aligned values
- **Link-state tone** — a link that is present but not up dims the hero glyph and switches STATUS to the theme's urgent colour
- **`nmcli` AP rate as a LINK RATE fallback** — for drivers where `iw` prints nothing
- **IPv4/IPv6-aware status** — STATUS uses the cleaned state word (`CONNECTED`) instead of nmcli's raw `100 (connected)`

### Fixed
- **Chart-window pills** were plain rectangles with a hardcoded hover tint; they are now real pills using `Border.controlSpec` and the shared hover fill
- **Row/table separators** were hardcoded at 5–6% opacity, well below the shell's hairline weight; they now use `PanelSeparator`
- **"sampled every 2s"** misreported the 1.5s poll interval; it now shows `1.5s`
- **BAND row** could render empty where every other row falls back to `--`
- **Per-app name/pid placement** — the pid was pushed to the far right by an over-wide name field; the name now shrinks to fit so the pair reads together

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