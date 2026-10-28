#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MACOS_DIR="${ROOT_DIR}/apps/desktop-macos"
BUILD_DIR="${MACOS_DIR}/build"
APP_DIR="${BUILD_DIR}/AirControl.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_BIN_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
CACHE_DIR="/tmp/aircontrol-clang-cache"

echo "==> Building AirControl macOS Host Agent..."
mkdir -p "${MACOS_BIN_DIR}" "${RESOURCES_DIR}" "${CACHE_DIR}"

if [ -d "/Applications/Xcode-beta.app/Contents/Developer" ]; then
    DEV_DIR="/Applications/Xcode-beta.app/Contents/Developer"
elif [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    DEV_DIR="/Applications/Xcode.app/Contents/Developer"
else
    DEV_DIR="$(xcode-select -p 2>/dev/null || echo "")"
fi

if [ -z "${DEV_DIR}" ] || [ ! -d "${DEV_DIR}" ]; then
    echo "Error: Could not locate Xcode Developer Directory"
    exit 1
fi

SDK_PATH=$(DEVELOPER_DIR="${DEV_DIR}" xcrun --sdk macosx --show-sdk-path)

DEVELOPER_DIR="${DEV_DIR}" xcrun swiftc -O \
    -module-cache-path "${CACHE_DIR}" \
    -disable-sandbox \
    -sdk "${SDK_PATH}" \
    "${MACOS_DIR}/Sources/Core/"*.swift \
    "${MACOS_DIR}/Sources/Network/"*.swift \
    "${MACOS_DIR}/Sources/App/"*.swift \
    -o "${MACOS_BIN_DIR}/AirControl"

if [ -f "${MACOS_DIR}/Resources/AppIcon.icns" ]; then
    cp "${MACOS_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

cat << 'EOF' > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AirControl</string>
    <key>CFBundleIdentifier</key>
    <string>com.aircontrol.host</string>
    <key>CFBundleName</key>
    <string>AirControl</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>AirControl requires permission to inject keyboard and mouse events.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>AirControl requires local network access to communicate with iOS devices.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_aircontrol-p2p._tcp</string>
        <string>_aircontrol-p2p._udp</string>
        <string>_aircontrol._tcp</string>
        <string>_aircontrol._udp</string>
    </array>
</dict>
</plist>
EOF

echo "==> Performing ad-hoc codesigning on AirControl.app..."
dot_clean "${APP_DIR}" || true
xattr -cr "${APP_DIR}" || true
xattr -d com.apple.FinderInfo "${APP_DIR}" 2>/dev/null || true
xattr -d "com.apple.fileprovider.fpfs#P" "${APP_DIR}" 2>/dev/null || true
codesign --force --deep --sign - "${APP_DIR}"

echo "==> Packaging macOS artifacts into dist/..."
DIST_DIR="${ROOT_DIR}/dist"
mkdir -p "${DIST_DIR}"
rm -rf "${DIST_DIR}/AirControl.app" "${DIST_DIR}/AirControl-macOS.zip"
cp -R "${APP_DIR}" "${DIST_DIR}/AirControl.app"
(cd "${BUILD_DIR}" && zip -qr9 "${DIST_DIR}/AirControl-macOS.zip" AirControl.app)

echo "==> Successfully built and signed AirControl.app at: ${APP_DIR} and updated ${DIST_DIR}"
