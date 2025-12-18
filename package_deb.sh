#!/bin/bash
set -e

APP_NAME="zlsnasdisplay"
VERSION="0.1.0"
ARCH="amd64" # Detect or set based on target. Assuming amd64 for now, but RPi is arm64.
# Let's try to detect architecture
if [ "$(uname -m)" = "aarch64" ]; then
    ARCH="arm64"
elif [ "$(uname -m)" = "x86_64" ]; then
    ARCH="amd64"
else
    ARCH="armhf"
fi

echo "Packaging $APP_NAME version $VERSION for $ARCH..."

# 1. Build Release
echo "Building release..."
zig build -Doptimize=ReleaseSafe

# 2. Create directory structure
PKG_DIR="${APP_NAME}_${VERSION}_${ARCH}"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/DEBIAN"
mkdir -p "$PKG_DIR/usr/bin"
mkdir -p "$PKG_DIR/lib/systemd/system"
mkdir -p "$PKG_DIR/etc/$APP_NAME"

# 3. Copy binary
cp zig-out/bin/$APP_NAME "$PKG_DIR/usr/bin/"

# 4. Create control file
cat > "$PKG_DIR/DEBIAN/control" <<EOF
Package: $APP_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Depends: libc6, libcairo2, libfreetype6, libfontconfig1, libgpiod3
Maintainer: Zales <zales@example.com>
Description: ZLS NAS Display Driver
 A Zig implementation of the NAS display driver using Cairo and e-Paper display.
EOF

# 5. Create systemd service
cat > "$PKG_DIR/lib/systemd/system/$APP_NAME.service" <<EOF
[Unit]
Description=ZLS NAS Display Service
After=network.target

[Service]
ExecStart=/usr/bin/$APP_NAME
Restart=always
User=root
Group=root
WorkingDirectory=/etc/$APP_NAME
EnvironmentFile=-/etc/default/$APP_NAME

[Install]
WantedBy=multi-user.target
EOF

# 5.5 Create default environment file
mkdir -p "$PKG_DIR/etc/default"
cat > "$PKG_DIR/etc/default/$APP_NAME" <<EOF
# Configuration for zlsnasdisplay

# Export BMP image for web display
EXPORT_BMP=false
BMP_EXPORT_PATH=/mnt/web-display/tmp/display.bmp

# Update intervals (seconds)
INTERVAL_FAST=30
INTERVAL_SLOW=10800

# Thresholds
THRESHOLD_CPU_HIGH=70
THRESHOLD_CPU_CRITICAL=90
THRESHOLD_TEMP_HIGH=70
THRESHOLD_TEMP_CRITICAL=85
THRESHOLD_MEM_HIGH=80
THRESHOLD_MEM_CRITICAL=95
THRESHOLD_DISK_HIGH=85
THRESHOLD_DISK_CRITICAL=95

# Logging
LOG_LEVEL=INFO
EOF

# 6. Create postinst script
cat > "$PKG_DIR/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if [ "\$1" = "configure" ]; then
    systemctl daemon-reload
    systemctl enable $APP_NAME
    systemctl start $APP_NAME
fi
EOF
chmod 755 "$PKG_DIR/DEBIAN/postinst"

# 7. Create prerm script
cat > "$PKG_DIR/DEBIAN/prerm" <<EOF
#!/bin/sh
set -e
if [ "\$1" = "remove" ]; then
    systemctl stop $APP_NAME
    systemctl disable $APP_NAME
fi
EOF
chmod 755 "$PKG_DIR/DEBIAN/prerm"

# 8. Build package
dpkg-deb --build "$PKG_DIR"

echo "Package created: ${PKG_DIR}.deb"
