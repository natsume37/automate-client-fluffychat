#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BUNDLE_DIR="${BUNDLE_DIR:-$PROJECT_ROOT/build/linux/x64/release/bundle}"
PACKAGE_NAME="${DEB_PACKAGE_NAME:-psygo}"
INSTALL_DIR="${DEB_INSTALL_DIR:-/opt/psygo}"
MAINTAINER="${DEB_MAINTAINER:-Creative Koalas Co., Ltd. <support@creativekoalas.com>}"
DESCRIPTION="${DEB_DESCRIPTION:-Your AI-powered automation assistant.}"
ARCHITECTURE="${DEB_ARCHITECTURE:-amd64}"
OUTPUT_FILE="${OUTPUT_FILE:-$PROJECT_ROOT/build/linux/psygo-linux-amd64.deb}"
STAGING_ROOT="${STAGING_ROOT:-$PROJECT_ROOT/build/linux/deb-staging}"
DESKTOP_FILE_SOURCE="$PROJECT_ROOT/linux/appimage/psygo.desktop"
ICON_SOURCE="$PROJECT_ROOT/assets/logo.png"

read_version() {
  python3 - "$PROJECT_ROOT/pubspec.yaml" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r"^version:\s*([^\s]+)\s*$", text, re.M)
if not match:
    raise SystemExit("Unable to read version from pubspec.yaml")
print(match.group(1))
PY
}

PACKAGE_VERSION="${DEB_VERSION:-$(read_version)}"
PACKAGE_DIR="$STAGING_ROOT/${PACKAGE_NAME}"

if [[ ! -d "$BUNDLE_DIR" ]]; then
  echo "Bundle directory not found: $BUNDLE_DIR" >&2
  exit 1
fi

if [[ ! -f "$DESKTOP_FILE_SOURCE" ]]; then
  echo "Desktop entry not found: $DESKTOP_FILE_SOURCE" >&2
  exit 1
fi

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Icon not found: $ICON_SOURCE" >&2
  exit 1
fi

rm -rf "$PACKAGE_DIR"
mkdir -p \
  "$PACKAGE_DIR/DEBIAN" \
  "$PACKAGE_DIR$INSTALL_DIR" \
  "$PACKAGE_DIR/usr/bin" \
  "$PACKAGE_DIR/usr/share/applications" \
  "$PACKAGE_DIR/usr/share/icons/hicolor/512x512/apps"

cp -a "$BUNDLE_DIR/." "$PACKAGE_DIR$INSTALL_DIR/"
install -m 755 /dev/stdin "$PACKAGE_DIR/usr/bin/$PACKAGE_NAME" <<EOF
#!/bin/sh
exec $INSTALL_DIR/psygo "\$@"
EOF
install -m 644 "$DESKTOP_FILE_SOURCE" "$PACKAGE_DIR/usr/share/applications/${PACKAGE_NAME}.desktop"
install -m 644 "$ICON_SOURCE" "$PACKAGE_DIR/usr/share/icons/hicolor/512x512/apps/${PACKAGE_NAME}.png"

cat >"$PACKAGE_DIR/DEBIAN/control" <<EOF
Package: $PACKAGE_NAME
Version: $PACKAGE_VERSION
Section: net
Priority: optional
Architecture: $ARCHITECTURE
Maintainer: $MAINTAINER
Depends: libgtk-3-0, libsecret-1-0, liblzma5, libayatana-appindicator3-1 | libappindicator3-1, libwebkit2gtk-4.1-0, libjsoncpp25 | libjsoncpp1
Description: $DESCRIPTION
EOF

find "$PACKAGE_DIR" -type d -exec chmod 755 {} +

mkdir -p "$(dirname "$OUTPUT_FILE")"
dpkg-deb --build --root-owner-group "$PACKAGE_DIR" "$OUTPUT_FILE" >/dev/null

echo "Built Debian package: $OUTPUT_FILE"
