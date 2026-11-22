#!/usr/bin/env bash
set -euo pipefail

# SoundChord for macOS: Native .app Bundle & .dmg Packaging Script
# Uses built-in macOS tools plus Cargo/Rust for the RustDSP static library.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="SoundChord"
BUNDLE_ID="com.viannh.soundchord"
APP_VERSION="2.0.0"
BUILD_NUMBER="1"
MIN_MACOS="15.0"
TARGET_ARCH="${SOUNDCHORD_ARCH:-x86_64}"

DIST_DIR="${PROJECT_ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
DMG_PATH="${DIST_DIR}/${APP_NAME}-macOS-${TARGET_ARCH}.dmg"
ICON_PNG="${PROJECT_ROOT}/Assets/AppIcon-1024.png"

WORK_TMP="$(mktemp -d /tmp/soundchord-pkg.XXXXXX)"
cleanup() {
    rm -rf "${WORK_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

# Sandbox-safe caches in /tmp so builds work cleanly in both restricted and standard shells
export TMPDIR="/tmp"
export CLANG_MODULE_CACHE_PATH="/tmp/swift-module-cache"
mkdir -p "${CLANG_MODULE_CACHE_PATH}" /tmp/swiftpm-cache /tmp/swiftpm-config /tmp/swiftpm-security

echo "==> [0/7] Building RustDSP static library (${TARGET_ARCH}-apple-darwin, release)..."
export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
    echo "Error: cargo not found in PATH or \$HOME/.cargo/bin" >&2
    exit 1
fi
cargo build --release --manifest-path "${PROJECT_ROOT}/RustDSP/Cargo.toml" --target "${TARGET_ARCH}-apple-darwin"

echo "==> [1/7] Building ${APP_NAME} (${TARGET_ARCH}, release)..."
cd "${PROJECT_ROOT}"

SWIFT_BUILD_ARGS=(
    -c release
    --arch "${TARGET_ARCH}"
    --disable-sandbox
    --cache-path /tmp/swiftpm-cache
    --config-path /tmp/swiftpm-config
    --security-path /tmp/swiftpm-security
    -Xswiftc -module-cache-path
    -Xswiftc "${CLANG_MODULE_CACHE_PATH}"
)

swift build "${SWIFT_BUILD_ARGS[@]}"

BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
BINARY_PATH="${BIN_DIR}/${APP_NAME}"

if [[ ! -x "${BINARY_PATH}" ]]; then
    echo "Error: Expected release binary not found at ${BINARY_PATH}" >&2
    exit 1
fi

echo "    Built binary: ${BINARY_PATH}"
file "${BINARY_PATH}"

echo "==> [2/7] Generating AppIcon.icns..."
ICONSET_DIR="${WORK_TMP}/AppIcon.iconset"
ICNS_PATH="${WORK_TMP}/AppIcon.icns"

ICON_ARGS=()
if [[ -f "${ICON_PNG}" ]]; then
    echo "    Using custom icon artwork: ${ICON_PNG}"
    ICON_ARGS+=(--icon "${ICON_PNG}")
fi

swift -module-cache-path "${CLANG_MODULE_CACHE_PATH}" \
    "${SCRIPT_DIR}/generate_icon.swift" "${ICONSET_DIR}" "${ICON_ARGS[@]}"

if ! iconutil -c icns "${ICONSET_DIR}" -o "${ICNS_PATH}" 2>/dev/null; then
    echo "    iconutil unavailable in current environment; assembling multi-resolution ICNS directly..."
    swift -module-cache-path "${CLANG_MODULE_CACHE_PATH}" \
        "${SCRIPT_DIR}/generate_icon.swift" "${ICONSET_DIR}" --icns "${ICNS_PATH}" "${ICON_ARGS[@]}"
fi
echo "    Generated icon: $(du -h "${ICNS_PATH}" | awk '{print $1}')"

echo "==> [3/7] Assembling ${APP_BUNDLE}..."
mkdir -p "${DIST_DIR}"
rm -rf "${APP_BUNDLE}" "${DIST_DIR}/BitChord.app" "${DIST_DIR}/BitChord-macOS-${TARGET_ARCH}.dmg"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"

cp "${BINARY_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "${ICNS_PATH}" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
cp "${SCRIPT_DIR}/SoundChord.sdef" "${APP_BUNDLE}/Contents/Resources/SoundChord.sdef"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © SoundChord Contributors. Licensed under GNU GPLv3.</string>
    <key>NSAppleScriptEnabled</key>
    <true/>
    <key>OSAScriptingDefinition</key>
    <string>SoundChord.sdef</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> [4/7] Validating Info.plist..."
plutil -lint "${APP_BUNDLE}/Contents/Info.plist"

echo "==> [5/7] Ad-hoc codesigning ${APP_BUNDLE}..."
codesign --force --deep --identifier "${BUNDLE_ID}" --sign - "${APP_BUNDLE}"
codesign --verify --deep --strict "${APP_BUNDLE}"

echo "==> [6/7] Creating compressed DMG at ${DMG_PATH}..."
DMG_STAGING="${WORK_TMP}/dmg-root"
mkdir -p "${DMG_STAGING}"
ditto "${APP_BUNDLE}" "${DMG_STAGING}/${APP_NAME}.app"
ln -s /Applications "${DMG_STAGING}/Applications"

rm -f "${DMG_PATH}"
if ! hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" 2>/dev/null; then
    echo "    hdiutil create unavailable in current environment; using hdiutil makehybrid + convert (UDZO)..."
    HYBRID_DMG="${WORK_TMP}/${APP_NAME}-hybrid.dmg"
    hdiutil makehybrid \
        -hfs \
        -hfs-volume-name "${APP_NAME}" \
        -o "${HYBRID_DMG}" \
        "${DMG_STAGING}"
    hdiutil convert "${HYBRID_DMG}" \
        -format UDZO \
        -ov \
        -o "${DMG_PATH}"
fi

echo "==> [7/7] Verifying DMG..."
hdiutil verify "${DMG_PATH}"

echo ""
echo "Packaging complete:"
echo "  App Bundle : ${APP_BUNDLE} ($(du -sh "${APP_BUNDLE}" | awk '{print $1}'))"
echo "  Disk Image : ${DMG_PATH} ($(du -sh "${DMG_PATH}" | awk '{print $1}'))"
