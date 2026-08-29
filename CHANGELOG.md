# Changelog

All notable changes to this project will be documented in this file.

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