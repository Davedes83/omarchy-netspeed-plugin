[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/O3N726LJT4)
<img width="967" height="502" alt="Net Speed Plugin" src="https://github.com/user-attachments/assets/a8fb7575-3669-4524-9e7c-c20219e98e98" />


# Net Speed Widget for Omarchy

A real-time network speed widget for the Omarchy bar. Shows live download and upload speeds in your shell status bar, with a themed details dropdown covering the traffic chart, connection details, and per-app usage.

## Features

- **Live Speed Monitoring** — Real-time download and upload speeds from `/proc/net/dev`
- **Smoothed Display** — Exponential moving average prevents jittery speed numbers
- **Smart Formatting** — Auto-scales from B/s to TiB/s (binary units: KiB, MiB, GiB, TiB)
- **Configurable Interval** — Adjust sampling rate via settings (default: 2000ms)
- **Resizable Font** — Scroll to fine-tune the widget font size
- **Total Counters** — Hover for cumulative RX/TX totals and per-interface breakdown
- **Tunnel-aware** — VPN and container interfaces are excluded by default so a WireGuard/Tailscale session is not counted twice; pin the exact set with `interfaces`
- **Theme-Aware Dropdown** — One click opens a fully Omarchy-styled panel coloured entirely from your active theme (no hardcoded colours):
  - **Hero** — Connection name, live state (e.g. CONNECTED), and refresh/close buttons
  - **Live Throughput Chart** — Stacked down/up traffic with a **5 / 15 / 30-minute window selector**
  - **Connection Details** — SSID, signal, band, `iw` link rate, security, IP, gateway, DNS, status, MAC, MTU, DHCP lease, driver, metered flag
  - **Per-App Usage** — Live down/up rates + session totals and connection counts per app (TCP socket attribution)
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

- **Left-click** — Toggle the details dropdown panel
- **Middle-click** — Force refresh the speed sample
- **Right-click** — Open Omarchy network settings
- **Scroll up/down** — Fine-tune font size by ±1px
- **Esc** — Close the dropdown (standard Omarchy keyboard-panel behaviour)

### Customization

Edit the widget entry in your `~/.config/omarchy/shell.json`:

```json
{
  "bar": {
    "layout": {
      "right": [
        {
          "id": "davedes.netspeed",
          "interval": 2000,
          "fontSize": 12
        }
      ]
    }
  }
}
```

**Settings:**
- `interval` (ms) — Sample rate (bar + chart). Lower = more accurate but higher CPU (default: 2000). Clamped to 250–60000 ms; non-numeric or zero/negative values fall back to the default
- `fontSize` (px) — Widget text size (default: bar caption size). Clamped to 8–28 px
- `interfaces` — Optional list of interfaces to monitor, e.g. `"enp5s0"` or `["wlan0", "enp5s0"]`. Defaults to every non-virtual interface (see [Excluded Interfaces](#excluded-interfaces)). Listing a virtual interface explicitly is allowed and opts you into counting it

### Per-App Usage notes

- Speeds and session totals come from live TCP sockets sampled via `ss` (default every 1.5s)
- Totals accumulate for the current session and reset when the shell/widget restarts
- Only established sockets are sampled. A socket only moves bytes once it is established, so nothing is lost, and the connection count reflects live connections instead of every `SYN-SENT`/`TIME-WAIT` transient
- Only TCP sockets are attributed; QUIC/UDP traffic (e.g. YouTube or Google over HTTP/3) is not visible per-app, so apps doing heavy QUIC can look quiet while the bar still shows the real throughput

### IPC Commands

Control the widget programmatically:

```bash
# Adjust font size
omarchy shell send davedes.netspeed fontSizeUp
omarchy shell send davedes.netspeed fontSizeDown
omarchy shell send davedes.netspeed setFontSize 14

# Force refresh
omarchy shell send davedes.netspeed refresh

# Open / close the details dropdown
omarchy shell send davedes.netspeed open
omarchy shell send davedes.netspeed close
omarchy shell send davedes.netspeed toggle
```

## How It Works

1. **Reads** `/proc/net/dev` every `interval` milliseconds
2. **Filters** loopback, container, and VPN/tunnel interfaces (see [Excluded Interfaces](#excluded-interfaces))
3. **Calculates** deltas from the previous sample
4. **Smooths** speed values with an exponential moving average
5. **Formats** as human-readable speeds (B/s, KiB/s, MiB/s, etc.)
6. **Dropdown** — connection details come from `nmcli`/`ip`/`iw`, per-app usage from `ss -tinp state established`

### Excluded Interfaces

The following interface patterns are excluded by default (case-insensitive):

- `lo*` — Loopback
- `docker*` — Docker bridges
- `br-*` — Linux bridges
- `virbr*` — libvirt bridges
- `veth*` — Virtual Ethernet pairs
- `vboxnet*`, `vmnet*`, `vnic*` — VirtualBox/VMware host-only networks
- `wg*`, `tailscale*`, `tun*`, `tap*`, `sit*`, `gre*`, `ip6tnl*`, `ip6gre*`, `ham*`, `zt*` — VPN and tunnel overlays
- `cni*`, `podman*`, `flannel*`, `lxcbr*`, `kube*`, `nomad*` — Container and cluster networks
- `dummy*`, `ifb*`, `teql*`, `bond_slave*` — Traffic shaping and bond slaves

Tunnel interfaces matter most here: a VPN re-counts every byte that already crossed the physical NIC, so including one double-reports throughput and inflates the totals. If you do want to watch one, name it explicitly in `interfaces`.

The default covers the common virtual interfaces, but it is a fixed list rather than a rule. Check what is actually on your machine with `ip -br link` and pin anything you need (or need to skip) via `interfaces`.

## Troubleshooting

**Widget not appearing?**
- Check that your bar layout includes the right section
- Verify the plugin loads: `omarchy plugin list | grep davedes.netspeed`

**Speeds stuck at "--"?**
- The widget waits for the first sample interval before displaying
- Force a refresh: middle-click or run `omarchy shell send davedes.netspeed refresh`

**High CPU usage?**
- Increase `interval` in shell.json (e.g., 2000ms for less frequent sampling)
- The dropdown's per-app table is the most expensive part while it is open — it samples `ss` every 1.5s. Close it when you are not looking at it (nothing runs while it is closed)

**Numbers higher than my real traffic?**
- A VPN/tunnel interface is double-counting your physical NIC. Check `ip -br link` for `wg*`/`tailscale*`/`tun*`, and pin `interfaces` to just the interface you care about

**One of my interfaces is missing from the tooltip?**
- If its name matches an excluded pattern above, list it explicitly in `interfaces`

**Total jumped to a nonsense value?**
- Please report it — the parser should now discard an incomplete `/proc/net/dev` read rather than act on a partial counter

## License

MIT License — See LICENSE for details.

## Feedback

Found a bug or have a feature idea? Open an issue on GitHub.

---

Made with ❤ for Omarchy
