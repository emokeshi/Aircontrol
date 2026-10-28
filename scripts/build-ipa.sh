#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IOS_DIR="${ROOT_DIR}/apps/mobile-ios"
OUTPUT_DIR="${IOS_DIR}/build"
TEMP_DIR="/tmp/aircontrol-ipa-build"
PAYLOAD_DIR="${TEMP_DIR}/Payload"
APP_DIR="${PAYLOAD_DIR}/AirControl.app"
CACHE_DIR="/tmp/aircontrol-clang-cache"

echo "==> Building Native iOS AirControl Application (.ipa)..."

# Locate iPhoneOS SDK
if [ -d "/Applications/Xcode-beta.app/Contents/Developer" ]; then
    DEV_DIR="/Applications/Xcode-beta.app/Contents/Developer"
elif [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    DEV_DIR="/Applications/Xcode.app/Contents/Developer"
else
    DEV_DIR="$(xcode-select -p 2>/dev/null || echo "")"
fi

if [ -z "${DEV_DIR}" ] || [ ! -d "${DEV_DIR}" ]; then
    echo "Error: Xcode not found at ${DEV_DIR}"
    exit 1
fi

SDK_PATH=$(DEVELOPER_DIR="${DEV_DIR}" xcrun --sdk iphoneos --show-sdk-path)

rm -rf "${TEMP_DIR}"
mkdir -p "${APP_DIR}" "${CACHE_DIR}" "${OUTPUT_DIR}"

echo "==> Compiling arm64 Swift/SwiftUI iOS sources..."
DEVELOPER_DIR="${DEV_DIR}" xcrun swiftc \
  -module-cache-path "${CACHE_DIR}" \
  -disable-sandbox \
  -target arm64-apple-ios16.0 \
  -sdk "${SDK_PATH}" \
  -O \
  "${IOS_DIR}/Sources/Network/"*.swift \
  "${IOS_DIR}/Sources/UI/"*.swift \
  "${IOS_DIR}/Sources/App/"*.swift \
  -o "${APP_DIR}/AirControl"

echo "==> Copying App metadata and Info.plist..."
cp "${IOS_DIR}/Info.plist" "${APP_DIR}/Info.plist"
if [ -f "${IOS_DIR}/AppIcon.png" ]; then
    cp "${IOS_DIR}/AppIcon.png" "${APP_DIR}/AppIcon.png"
fi
echo "APPL????" > "${APP_DIR}/PkgInfo"

echo "==> Performing ad-hoc codesign on AirControl.app..."
codesign -s - --force --preserve-metadata=identifier,entitlements,flags "${APP_DIR}"

echo "==> Packaging into AirControl.ipa..."
IPA_PATH="${OUTPUT_DIR}/AirControl.ipa"
rm -f "${IPA_PATH}"
(cd "${TEMP_DIR}" && zip -qr9 "${IPA_PATH}" Payload)

rm -rf "${TEMP_DIR}"

DIST_DIR="${ROOT_DIR}/dist"
mkdir -p "${DIST_DIR}"
cp "${IPA_PATH}" "${DIST_DIR}/AirControl.ipa"

FILESIZE=$(ls -lh "${IPA_PATH}" | awk '{print $5}')
echo "=========================================================="
echo "==> SUCCESS! Built native iOS IPA: ${IPA_PATH} (${FILESIZE})"
echo "==> Updated release artifact at: ${DIST_DIR}/AirControl.ipa"
echo "==> Ready for installation via TrollStore, AltStore, SideStore, or Apple Configurator!"
echo "=========================================================="
