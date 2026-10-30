#!/bin/bash
set -euo pipefail

# Build the zed-acp-pin .deb from acp-deb/, which ships no agent code
# Usage: ./scripts/build-acp-deb.sh [VERSION]

VERSION="${1:-1.0.0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/../acp-deb"
OUTPUT_DIR="${SCRIPT_DIR}/../packages"

WORKDIR=$(mktemp -d)
trap "rm -rf ${WORKDIR}" EXIT

PKG_DIR="${WORKDIR}/zed-acp-pin_${VERSION}_all"

mkdir -p "${PKG_DIR}/DEBIAN"
mkdir -p "${PKG_DIR}/usr/lib/systemd/user"
mkdir -p "${PKG_DIR}/usr/share/doc/zed-acp-pin"

install -D -m 755 "${SOURCE_DIR}/zed-acp-pin" "${PKG_DIR}/usr/bin/zed-acp-pin"
install -D -m 755 "${SOURCE_DIR}/zed-acp-pin-update" "${PKG_DIR}/usr/bin/zed-acp-pin-update"
install -m 644 "${SOURCE_DIR}"/zed-acp-pin-update.{service,timer} "${PKG_DIR}/usr/lib/systemd/user/"
install -m 644 "${SOURCE_DIR}/README.md" "${PKG_DIR}/usr/share/doc/zed-acp-pin/README.md"

INSTALLED_SIZE=$(du -sk "${PKG_DIR}" | cut -f1)

cat > "${PKG_DIR}/DEBIAN/control" << CTLEOF
Package: zed-acp-pin
Version: ${VERSION}
Architecture: all
Maintainer: zed-deb repository <noreply@github.com>
Installed-Size: ${INSTALLED_SIZE}
Depends: podman, libglib2.0-bin, nodejs-24 | nodejs-22 | nodejs (>= 22)
Recommends: zed
Section: editors
Priority: optional
Homepage: https://github.com/xi72yow/zed-deb
Description: Pinned, delayed updates for the Claude ACP agent in Zed
 Installs the Claude ACP agent from npm per user and updates it weekly,
 only to releases older than seven days. Ships no agent code itself.
CTLEOF

cat > "${PKG_DIR}/DEBIAN/postinst" << 'POSTEOF'
#!/bin/bash
set -e
if [ "$1" = "configure" ]; then
  systemctl --global enable zed-acp-pin-update.timer 2>/dev/null || true
fi
POSTEOF
chmod 755 "${PKG_DIR}/DEBIAN/postinst"

cat > "${PKG_DIR}/DEBIAN/prerm" << 'POSTEOF'
#!/bin/bash
set -e
if [ "$1" = "remove" ]; then
  systemctl --global disable zed-acp-pin-update.timer 2>/dev/null || true
fi
POSTEOF
chmod 755 "${PKG_DIR}/DEBIAN/prerm"

dpkg-deb --build --root-owner-group "${PKG_DIR}"

mkdir -p "${OUTPUT_DIR}"
mv "${PKG_DIR}.deb" "${OUTPUT_DIR}/zed-acp-pin_${VERSION}_all.deb"

echo "Built: packages/zed-acp-pin_${VERSION}_all.deb"
