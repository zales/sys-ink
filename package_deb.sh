#!/bin/bash
set -euo pipefail

APP_NAME="sys-ink"
VERSION="${VERSION:-1.5.0}"
TARGET_ARCH="${TARGET_ARCH:-amd64}" # debian architecture name: amd64, arm64, armhf
BINARY_PATH="${BINARY_PATH:-zig-out/bin/sys-ink}"
# Override to publish under your own address.
MAINTAINER="${MAINTAINER:-Zales <zales@users.noreply.github.com>}"
HOMEPAGE="${HOMEPAGE:-https://github.com/zales/sys-ink}"

if [ -z "$VERSION" ]; then
    echo "Usage: VERSION=1.0.0 TARGET_ARCH=arm64 BINARY_PATH=... ./package_deb.sh"
    exit 1
fi

echo "Packaging $APP_NAME version $VERSION for $TARGET_ARCH..."

# 2. Create directory structure
PKG_DIR="${APP_NAME}_${VERSION}_${TARGET_ARCH}"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/DEBIAN"
mkdir -p "$PKG_DIR/usr/bin"
mkdir -p "$PKG_DIR/lib/systemd/system"
mkdir -p "$PKG_DIR/etc/default"

# 3. Copy binary
if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: Binary not found at $BINARY_PATH"
    exit 1
fi
cp "$BINARY_PATH" "$PKG_DIR/usr/bin/$APP_NAME"
chmod 755 "$PKG_DIR/usr/bin/$APP_NAME"

# 4. Create control file
# No Depends: the binary is statically linked against musl.
cat > "$PKG_DIR/DEBIAN/control" <<EOF
Package: $APP_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: $TARGET_ARCH
Maintainer: $MAINTAINER
Homepage: $HOMEPAGE
Description: System monitor for Waveshare e-Paper displays
 SysInk renders CPU, memory, disk, fan, network and APT status onto a
 Waveshare 2.9" e-Paper display attached to a Raspberry Pi, and can
 optionally publish the same metrics to MQTT for Home Assistant.
EOF

# 5. Create systemd service
cat > "$PKG_DIR/lib/systemd/system/$APP_NAME.service" <<EOF
[Unit]
Description=SysInk Display Service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/$APP_NAME
Restart=always
RestartSec=5
User=root
Group=root
EnvironmentFile=-/etc/default/$APP_NAME

[Install]
WantedBy=multi-user.target
EOF

# 5.5 Create default environment file
cat > "$PKG_DIR/etc/default/$APP_NAME" <<EOF
# Configuration for sys-ink.
# Every value below is a default; uncomment to override.

# --- Hardware -----------------------------------------------------------
# Auto-detected from the GPIO chip label when unset.
#GPIO_CHIP=/dev/gpiochip0
#SPI_DEVICE=/dev/spidev0.0

# --- Update intervals (seconds) -----------------------------------------
# Fast: CPU, memory, disk, fan, traffic, signal, uptime, display.
INTERVAL_FAST=30
# Slow: IP address, APT updates, internet reachability.
INTERVAL_SLOW=10800
# How often to force a full refresh to clear e-paper ghosting.
INTERVAL_FULL_REFRESH=600

# --- Thresholds (values at or above these are shown inverted) -----------
THRESHOLD_CPU_CRITICAL=90
THRESHOLD_TEMP_CRITICAL=85
THRESHOLD_MEM_CRITICAL=95
THRESHOLD_DISK_CRITICAL=95

# --- Internet reachability probe ----------------------------------------
#INTERNET_CHECK_IP=8.8.8.8
#INTERNET_CHECK_PORT=53

# --- Logging ------------------------------------------------------------
# DEBUG, INFO, WARN or ERROR.
LOG_LEVEL=INFO
#LOG_TO_FILE=false
#LOG_FILE_PATH=/var/log/sys-ink.log

# --- BMP export (for previewing the rendered frame) ---------------------
EXPORT_BMP=false
BMP_EXPORT_PATH=/tmp/sys-ink.bmp

# --- MQTT / Home Assistant ----------------------------------------------
#MQTT_ENABLED=true
#MQTT_HOST=192.168.1.100
#MQTT_PORT=1883
#MQTT_USERNAME=homeassistant
# Keep credentials out of this world-readable file if you can; see README.
#MQTT_PASSWORD=secret
#MQTT_CLIENT_ID=sysink
#MQTT_TOPIC_PREFIX=sysink
#MQTT_DISCOVERY=true
EOF

# 5.6 Create conffiles to prevent overwriting config
cat > "$PKG_DIR/DEBIAN/conffiles" <<EOF
/etc/default/$APP_NAME
EOF

# 6. Create postinst script
cat > "$PKG_DIR/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if [ "\$1" = "configure" ]; then
    # Skip in chroots and containers, where systemd is not running.
    if [ -d /run/systemd/system ]; then
        systemctl daemon-reload || true
        systemctl enable $APP_NAME.service || true
        systemctl restart $APP_NAME.service || true
    fi
fi
EOF
chmod 755 "$PKG_DIR/DEBIAN/postinst"

# 7. Create prerm script
cat > "$PKG_DIR/DEBIAN/prerm" <<EOF
#!/bin/sh
set -e
if [ "\$1" = "remove" ]; then
    # '|| true': the service may already be stopped or never have started,
    # and a non-zero exit here would abort the removal.
    if [ -d /run/systemd/system ]; then
        systemctl stop $APP_NAME.service || true
        systemctl disable $APP_NAME.service || true
    fi
fi
EOF
chmod 755 "$PKG_DIR/DEBIAN/prerm"

# 7.5 Create postrm script
cat > "$PKG_DIR/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
if [ "\$1" = "remove" ] || [ "\$1" = "purge" ]; then
    if [ -d /run/systemd/system ]; then
        systemctl daemon-reload || true
    fi
fi
EOF
chmod 755 "$PKG_DIR/DEBIAN/postrm"

# 8. Build package. --root-owner-group keeps files owned by root rather than
# whichever uid happened to run the build.
dpkg-deb --root-owner-group --build "$PKG_DIR"

echo "Package created: ${PKG_DIR}.deb"
