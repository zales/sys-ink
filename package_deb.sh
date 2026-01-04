#!/bin/bash
set -e

APP_NAME="sys-ink"
VERSION="${VERSION:-1.0.10}"
TARGET_ARCH="${TARGET_ARCH:-amd64}" # debian architecture name: amd64, arm64, armhf
BINARY_PATH="${BINARY_PATH:-zig-out/bin/sys-ink}"

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
mkdir -p "$PKG_DIR/etc/$APP_NAME"

# 3. Copy binary
if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: Binary not found at $BINARY_PATH"
    exit 1
fi
cp "$BINARY_PATH" "$PKG_DIR/usr/bin/$APP_NAME"
chmod 755 "$PKG_DIR/usr/bin/$APP_NAME"

# 4. Create control file
# Dependencies removed as we are building static binaries
cat > "$PKG_DIR/DEBIAN/control" <<EOF
Package: $APP_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: $TARGET_ARCH
Maintainer: Zales <zales@example.com>
Description: SysInk Display Driver
 A Zig implementation of the NAS display driver for Waveshare e-Paper display.
EOF

# 5. Create systemd service
cat > "$PKG_DIR/lib/systemd/system/$APP_NAME.service" <<EOF
[Unit]
Description=SysInk Display Service
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
# Configuration for sys-ink

# Export BMP image for web display
EXPORT_BMP=false
BMP_EXPORT_PATH=/tmp/sys-ink.bmp

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

# 5.6 Create conffiles to prevent overwriting config
cat > "$PKG_DIR/DEBIAN/conffiles" <<EOF
/etc/default/$APP_NAME
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
