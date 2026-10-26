#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${KEYCHAIN_SECRETS_APP_DIR:-${HOME}/Applications/KeychainSecrets.app}"
mkdir -p "$(dirname "${APP_DIR}")"
STAGING_DIR="$(mktemp -d "$(dirname "${APP_DIR}")/.keychain-secrets-build.XXXXXX")"
PREVIOUS_DIR="${STAGING_DIR}/previous.app"
cleanup() {
  if [[ -d "${PREVIOUS_DIR}" && ! -e "${APP_DIR}" ]]; then
    mv "${PREVIOUS_DIR}" "${APP_DIR}"
  fi
  rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT
CONTENTS_DIR="${STAGING_DIR}/KeychainSecrets.app/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
BINARY_PATH="${MACOS_DIR}/KeychainSecrets"
ICONSET_DIR="${RESOURCES_DIR}/KeychainSecrets.iconset"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

clang \
  -fobjc-arc \
  -framework Cocoa \
  "${ROOT_DIR}/macos/KeychainSecretsApp.m" \
  -o "${BINARY_PATH}"

cp "${ROOT_DIR}/scripts/keychain_secrets.py" "${RESOURCES_DIR}/keychain_secrets.py"
chmod +x "${RESOURCES_DIR}/keychain_secrets.py"

mkdir -p "${ICONSET_DIR}"
sips -z 1024 1024 "${ROOT_DIR}/macos/KeychainSecretsIcon.png" --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null

sips -z 16 16 "${ICONSET_DIR}/icon_512x512@2x.png" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
sips -z 32 32 "${ICONSET_DIR}/icon_512x512@2x.png" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "${ICONSET_DIR}/icon_512x512@2x.png" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
sips -z 64 64 "${ICONSET_DIR}/icon_512x512@2x.png" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "${ICONSET_DIR}/icon_512x512@2x.png" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
sips -z 256 256 "${ICONSET_DIR}/icon_512x512@2x.png" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "${ICONSET_DIR}/icon_512x512@2x.png" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
sips -z 512 512 "${ICONSET_DIR}/icon_512x512@2x.png" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "${ICONSET_DIR}/icon_512x512@2x.png" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/KeychainSecrets.icns"
rm -rf "${ICONSET_DIR}"

cat > "${CONTENTS_DIR}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>KeychainSecrets</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.zpzjzj.keychain-secrets</string>
  <key>CFBundleName</key>
  <string>KeychainSecrets</string>
  <key>CFBundleDisplayName</key>
  <string>KeychainSecrets</string>
  <key>CFBundleIconFile</key>
  <string>KeychainSecrets</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.3</string>
  <key>CFBundleVersion</key>
  <string>4</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# Publish only a fully built bundle; restore the previous installation if publishing fails.
if [[ -e "${APP_DIR}" ]]; then mv "${APP_DIR}" "${PREVIOUS_DIR}"; fi
mv "${STAGING_DIR}/KeychainSecrets.app" "${APP_DIR}"
echo "${APP_DIR}"
