# Changelog

All notable changes to this project will be documented in this file.

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