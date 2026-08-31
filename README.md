<img width="967" height="502" alt="Net Speed Plugin" src="https://github.com/user-attachments/assets/a8fb7575-3669-4524-9e7c-c20219e98e98" />


<a href="https://paypal.me/DavidDesousa13"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="40px"></a>


# Net Speed Widget for Omarchy

A real-time network speed widget for the Omarchy Quattro bar. Displays live download and upload speeds in your shell status bar.

## Features

- **Live Speed Monitoring** — Real-time download and upload speeds from `/proc/net/dev`
- **Smoothed Display** — Exponential moving average prevents jittery speed numbers
- **Smart Formatting** — Auto-scales from B/s to TiB/s (binary units: KiB, MiB, GiB, TiB)
- **Configurable Interval** — Adjust sampling rate via settings (default: 2000ms)
- **Resizable Font** — Left-click to cycle through preset sizes, or scroll to fine-tune
- **Total Counters** — Hover for cumulative RX/TX totals and per-interface breakdown
- **IPC Controls** — Programmatic control via `omarchy shell` commands

## Installation

```bash
omarchy plugin clone github.com/Davedes83/omarchy-netspeed-plugin
```

Or manually:
```bash
git clone https://github.com/Davedes83/omarchy-netspeed-plugin ~/.config/omarchy/plugins/davedes.netspeed
```

## Usage

The widget appears in the right section of your bar by default. No configuration needed—it works out of the box.

### Interactions

- **Left-click** — Cycle through font sizes (10, 12, 14, 16, 18px)
- **Middle-click** — Force refresh the speed sample
- **Right-click** — Open Omarchy network settings
- **Scroll up/down** — Fine-tune font size by ±1px

### Customization

Edit the widget entry in your `~/.config/omarchy/shell.json`:

```json
{
  "bar": {
    "right": [
      {
        "id": "davedes.netspeed",
        "interval": 2000,
        "fontSize": 12
      }
    ]
  }
}
```

**Settings:**
- `interval` (ms) — Sample rate. Lower = more accurate but higher CPU (default: 2000). Clamped to 250–60000 ms; non-numeric or zero/negative values fall back to the default
- `fontSize` (px) — Widget text size (default: bar caption size). Clamped to 8–28 px

### IPC Commands

Control the widget programmatically:

```bash
# Adjust font size
omarchy shell send davedes.netspeed fontSizeUp
omarchy shell send davedes.netspeed fontSizeDown
omarchy shell send davedes.netspeed setFontSize 14

# Force refresh
omarchy shell send davedes.netspeed refresh
```

## How It Works

1. **Reads** `/proc/net/dev` every `interval` milliseconds
2. **Filters** loopback, Docker, and virtual interfaces (see [Excluded Interfaces](#excluded-interfaces))
3. **Calculates** deltas from the previous sample
4. **Smooths** speed values with an exponential moving average
5. **Formats** as human-readable speeds (B/s, KiB/s, MiB/s, etc.)

### Excluded Interfaces

The following interface patterns are excluded from monitoring (case-insensitive):

- `lo` — Loopback
- `docker*` — Docker bridges
- `br-*` — Linux bridges
- `virbr*` — libvirt bridges
- `veth*` — Virtual Ethernet pairs
- `vboxnet*` — VirtualBox host-only networks

## Troubleshooting

**Widget not appearing?**
- Check that your bar layout includes the right section
- Verify the plugin loads: `omarchy plugin list | grep davedes.netspeed`

**Speeds stuck at "--"?**
- The widget waits for the first sample interval before displaying
- Force a refresh: middle-click or run `omarchy shell send davedes.netspeed refresh`

**High CPU usage?**
- Increase `interval` in shell.json (e.g., 2000ms for less frequent sampling)

## License

MIT License — See LICENSE for details.

## Feedback

Found a bug or have a feature idea? Open an issue on GitHub.

---

Made with ❤ for Omarchy
