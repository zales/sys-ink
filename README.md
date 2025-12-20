# SysInk

A high-performance, lightweight system monitor for Raspberry Pi with Waveshare e-Paper display, written in Zig.

## Features

- **Real-time Monitoring**: CPU load, temperature, memory usage, disk usage, fan speed.
- **Network Stats**: IP address, signal strength (WiFi), upload/download speeds.
- **System Info**: Uptime, APT updates availability, Internet connection status.
- **Optimized Rendering**: Partial updates for e-Paper display to minimize flickering and maximize refresh rate.
- **Standalone**: Statically linked binary, no external runtime dependencies (libc-free/musl).

## Hardware Requirements

- Raspberry Pi (tested on Pi 4/5)
- Waveshare 2.9inch e-Paper Module (B/W)
- Enabled SPI and GPIO interfaces

## Build Instructions

### Prerequisites

- [Zig Compiler](https://ziglang.org/download/) (latest master or 0.12+)

### Building for Raspberry Pi (AArch64)

To build a minimal, statically linked binary for Raspberry Pi:

```bash
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall
```

The resulting binary will be located at `zig-out/bin/sys-ink`.

## Installation

### Option A: Debian Package (Recommended)

1. **Download the `.deb` package** for your architecture (`arm64` for Pi 3/4/5, `armhf` for Pi Zero/2) from the [Releases](https://github.com/yourusername/sys-ink/releases) page.
2. **Install**:
   ```bash
   sudo dpkg -i sys-ink_*.deb
   ```
   The service will start automatically.

### Option B: Manual Binary Installation

1. **Download the binary** (`sys-ink-aarch64` or `sys-ink-armhf`) from the Releases page.
2. **Transfer to Raspberry Pi**:
   ```bash
   scp sys-ink-aarch64 user@raspberrypi:/usr/local/bin/sys-ink
   ```
3. **Set Permissions**:
   ```bash
   ssh user@raspberrypi
   sudo chmod +x /usr/local/bin/sys-ink
   ```
   Ensure the user running the application is in `gpio` and `spi` groups.

### Systemd Service (Manual Install Only)

If you installed manually (Option B), create a service file:

`/etc/systemd/system/sys-ink.service`:

```ini
[Unit]
Description=SysInk Service
After=network.target

[Service]
ExecStart=/usr/local/bin/sys-ink
Restart=always
User=root
Environment=LOG_LEVEL=INFO

[Install]
WantedBy=multi-user.target
```

Enable and start the service:

```bash
sudo systemctl enable --now sys-ink
```

## Configuration

The application is configured via environment variables. You can set these in the systemd service file or export them before running.

| Variable | Default | Description |
|----------|---------|-------------|
| `GPIO_CHIP` | `/dev/gpiochip0` | Path to GPIO chip device (check with `gpiodetect`) |
| `LOG_LEVEL` | `INFO` | Logging level (DEBUG, INFO, WARN, ERROR) |
| `THRESHOLD_CPU_CRITICAL` | `90` | CPU load critical threshold (%) |
| `THRESHOLD_TEMP_CRITICAL` | `85` | CPU temperature critical threshold (°C) |
| `THRESHOLD_DISK_CRITICAL` | `95` | Disk usage critical threshold (%) |
| `EXPORT_BMP` | `false` | Enable BMP export for web debugging |
| `BMP_EXPORT_PATH` | `/tmp/sys-ink.bmp` | Path for exported BMP |

## License

MIT
