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
python3 - "${ICONSET_DIR}" <<'PY'
import struct
import sys
import zlib
from pathlib import Path

out = Path(sys.argv[1])
size = 1024
pixels = bytearray([0, 0, 0, 0] * size * size)

def blend(x, y, color):
    if not (0 <= x < size and 0 <= y < size):
        return
    i = (y * size + x) * 4
    sr, sg, sb, sa = color
    da = pixels[i + 3] / 255
    a = sa / 255
    oa = a + da * (1 - a)
    if oa == 0:
        return
    for offset, source in enumerate((sr, sg, sb)):
        dest = pixels[i + offset]
        pixels[i + offset] = int((source * a + dest * da * (1 - a)) / oa)
    pixels[i + 3] = int(oa * 255)

def rect(x0, y0, x1, y1, color):
    for y in range(max(0, y0), min(size, y1)):
        for x in range(max(0, x0), min(size, x1)):
            blend(x, y, color)

def circle(cx, cy, r, color):
    r2 = r * r
    for y in range(max(0, cy - r), min(size, cy + r + 1)):
        for x in range(max(0, cx - r), min(size, cx + r + 1)):
            dx = x - cx
            dy = y - cy
            if dx * dx + dy * dy <= r2:
                blend(x, y, color)

def capsule(x0, y0, x1, y1, r, color):
    rect(x0 + r, y0, x1 - r, y1, color)
    rect(x0, y0 + r, x1, y1 - r, color)
    circle(x0 + r, y0 + r, r, color)
    circle(x1 - r, y0 + r, r, color)
    circle(x0 + r, y1 - r, r, color)
    circle(x1 - r, y1 - r, r, color)

def line(x0, y0, x1, y1, width, color):
    steps = int(max(abs(x1 - x0), abs(y1 - y0))) + 1
    for i in range(steps):
        t = i / max(1, steps - 1)
        x = int(x0 + (x1 - x0) * t)
        y = int(y0 + (y1 - y0) * t)
        circle(x, y, width // 2, color)

def png(path, w, h, data):
    rows = bytearray()
    for y in range(h):
        rows.append(0)
        start = y * w * 4
        rows.extend(data[start:start + w * 4])
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(rows), 9))
        + chunk(b"IEND", b"")
    )

def rounded_rect(x0, y0, x1, y1, r, color):
    rect(x0 + r, y0, x1 - r, y1, color)
    rect(x0, y0 + r, x1, y1 - r, color)
    circle(x0 + r, y0 + r, r, color)
    circle(x1 - r, y0 + r, r, color)
    circle(x0 + r, y1 - r, r, color)
    circle(x1 - r, y1 - r, r, color)

def ring(cx, cy, outer, inner, color, fill):
    circle(cx, cy, outer, color)
    circle(cx, cy, inner, fill)

paper = (247, 248, 250, 255)
paper_edge = (222, 226, 232, 255)
ink = (43, 49, 57, 255)
shadow = (18, 24, 31, 22)
highlight = (255, 255, 255, 185)

rounded_rect(118, 118, 906, 906, 184, shadow)
rounded_rect(104, 96, 920, 912, 184, paper_edge)
rounded_rect(122, 114, 902, 894, 168, paper)
rounded_rect(158, 142, 866, 244, 52, highlight)

ring(336, 470, 150, 108, ink, paper)
circle(336, 470, 48, highlight)
line(468, 470, 734, 470, 44, ink)
line(718, 470, 808, 382, 44, ink)
line(724, 470, 810, 556, 44, ink)
line(624, 470, 706, 552, 36, ink)

png(out / "icon_512x512@2x.png", size, size, pixels)
PY

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
  <string>1.1</string>
  <key>CFBundleVersion</key>
  <string>2</string>
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
