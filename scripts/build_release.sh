#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-${ROOT_DIR}/dist}"
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"
RELEASE_WORK="$(mktemp -d)"
trap 'rm -rf "${RELEASE_WORK}"' EXIT
APP_DIR="${RELEASE_WORK}/payload/Clinklet.app"
mkdir -p "${RELEASE_WORK}/payload"
KEYCHAIN_SECRETS_APP_DIR="${APP_DIR}" bash "${ROOT_DIR}/scripts/install_macos_app.sh" >/dev/null
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_DIR}/Contents/Info.plist")"
BASE_NAME="Clinklet-${VERSION}-macOS-universal"
cp "${ROOT_DIR}/docs/INSTALL.txt" "${RELEASE_WORK}/payload/Install.txt"
cp "${ROOT_DIR}/LICENSE" "${APP_DIR}/Contents/Resources/LICENSE"
# Local ad-hoc signing gives the bundle an integrity seal. Developer ID notarization is separate.
codesign --force --sign - "${APP_DIR}"
codesign --verify --deep --strict "${APP_DIR}"
lipo "${APP_DIR}/Contents/MacOS/KeychainSecrets" -verify_arch arm64 x86_64
if find "${APP_DIR}" -name '*.py' -o -iname '*python*' | /usr/bin/grep -q .; then
  echo 'Unexpected Python dependency in release bundle' >&2
  exit 1
fi
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${OUTPUT_DIR}/${BASE_NAME}.zip"
ln -s /Applications "${RELEASE_WORK}/payload/Applications"
hdiutil create -volname "Clinklet ${VERSION}" -srcfolder "${RELEASE_WORK}/payload" \
  -format UDZO -ov "${OUTPUT_DIR}/${BASE_NAME}.dmg" >/dev/null
(
  cd "${OUTPUT_DIR}"
  shasum -a 256 "${BASE_NAME}.dmg" "${BASE_NAME}.zip" > "SHA256SUMS.txt"
)
echo "${OUTPUT_DIR}/${BASE_NAME}.dmg"
echo "${OUTPUT_DIR}/${BASE_NAME}.zip"
