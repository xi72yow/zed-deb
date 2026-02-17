#!/bin/bash
set -euo pipefail

# Build a .deb package from Zed's official Linux tarball
# Usage: ./scripts/build-deb.sh [VERSION] [REVISION]

VERSION="${1:-}"
REVISION="${2:-1}"

if [ -z "$VERSION" ]; then
  echo "Fetching latest Zed release version..."
  VERSION=$(curl -sL "https://api.github.com/repos/zed-industries/zed/releases/latest"     | grep '"tag_name"' | head -1 | sed 's/.*"v\(.*\)".*//')
fi

VERSION="${VERSION#v}"

echo "Building zed ${VERSION}-${REVISION} for amd64..."

WORKDIR=$(mktemp -d)
trap "rm -rf ${WORKDIR}" EXIT

TARBALL_URL="https://github.com/zed-industries/zed/releases/download/v${VERSION}/zed-linux-x86_64.tar.gz"
DEB_VERSION="${VERSION}-${REVISION}"
PKG_DIR="${WORKDIR}/zed_${DEB_VERSION}_amd64"

echo "Downloading ${TARBALL_URL}..."
curl -sL "${TARBALL_URL}" -o "${WORKDIR}/zed.tar.gz"
mkdir -p "${WORKDIR}/extract"
tar xzf "${WORKDIR}/zed.tar.gz" -C "${WORKDIR}/extract"

ZED_DIR=$(find "${WORKDIR}/extract" -maxdepth 1 -type d -name "zed*" | head -1)
if [ -z "$ZED_DIR" ]; then
  ZED_DIR="${WORKDIR}/extract"
fi

mkdir -p "${PKG_DIR}/DEBIAN"
mkdir -p "${PKG_DIR}/usr/bin"
mkdir -p "${PKG_DIR}/usr/lib/zed/bin"
mkdir -p "${PKG_DIR}/usr/lib/zed/lib"
mkdir -p "${PKG_DIR}/usr/lib/zed/libexec"
mkdir -p "${PKG_DIR}/usr/share/applications"
mkdir -p "${PKG_DIR}/usr/share/icons/hicolor/512x512/apps"
mkdir -p "${PKG_DIR}/usr/share/icons/hicolor/1024x1024/apps"
mkdir -p "${PKG_DIR}/usr/share/doc/zed"

# Preserve original directory structure so relative path lookups work
# CLI binary (bin/zed) looks for ../libexec/zed-editor relative to itself
cp "${ZED_DIR}/bin/zed" "${PKG_DIR}/usr/lib/zed/bin/zed"
if [ -d "${ZED_DIR}/lib" ]; then
  cp -r "${ZED_DIR}/lib/"* "${PKG_DIR}/usr/lib/zed/lib/" 2>/dev/null || true
fi
if [ -d "${ZED_DIR}/libexec" ]; then
  cp -r "${ZED_DIR}/libexec/"* "${PKG_DIR}/usr/lib/zed/libexec/" 2>/dev/null || true
fi

# Wrapper script
printf '#!/bin/bash
exec /usr/lib/zed/bin/zed "$@"
' > "${PKG_DIR}/usr/bin/zed"
chmod 755 "${PKG_DIR}/usr/bin/zed"

# Icons
for icon in "${ZED_DIR}/share/icons/hicolor/"*/"apps/"*; do
  if [ -f "$icon" ]; then
    size_dir=$(basename "$(dirname "$(dirname "$icon")")")
    mkdir -p "${PKG_DIR}/usr/share/icons/hicolor/${size_dir}/apps"
    cp "$icon" "${PKG_DIR}/usr/share/icons/hicolor/${size_dir}/apps/"
  fi
done 2>/dev/null || true

# .desktop file
if [ -f "${ZED_DIR}/share/applications/zed.desktop" ]; then
  cp "${ZED_DIR}/share/applications/zed.desktop" "${PKG_DIR}/usr/share/applications/"
else
  cat > "${PKG_DIR}/usr/share/applications/zed.desktop" << DSKEOF
[Desktop Entry]
Type=Application
Name=Zed
Comment=A high-performance, multiplayer code editor
Exec=/usr/lib/zed/zed %F
Icon=zed
Terminal=false
Categories=Development;TextEditor;IDE;
MimeType=text/plain;inode/directory;
StartupWMClass=Zed
Keywords=text;editor;code;
DSKEOF
fi

# Licenses from upstream
if [ -f "${ZED_DIR}/licenses.md" ]; then
  cp "${ZED_DIR}/licenses.md" "${PKG_DIR}/usr/share/doc/zed/licenses.md"
fi

# Copyright
cat > "${PKG_DIR}/usr/share/doc/zed/copyright" << CPEOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Zed
Upstream-Contact: Zed Industries, Inc.
Source: https://github.com/zed-industries/zed

Files: *
Copyright: 2022-2026 Zed Industries, Inc.
License: GPL-3.0-or-later
 On Debian systems, the full text of the GPL-3 license can be found
 in /usr/share/common-licenses/GPL-3.
CPEOF

INSTALLED_SIZE=$(du -sk "${PKG_DIR}" | cut -f1)

# Auto-detect dependencies from system libraries (exclude bundled ones)
BUNDLED_DIR="${PKG_DIR}/usr/lib/zed/lib"
AUTO_DEPS=$(ldd "${PKG_DIR}/usr/lib/zed/libexec/zed-editor" 2>/dev/null \
  | grep "=> /" \
  | grep -v "${BUNDLED_DIR}" \
  | awk '{print $3}' \
  | xargs -r dpkg -S 2>/dev/null \
  | cut -d: -f1 \
  | sort -u \
  | paste -sd ", ")

echo "Auto-detected dependencies: ${AUTO_DEPS}"

cat > "${PKG_DIR}/DEBIAN/control" << CTLEOF
Package: zed
Version: ${DEB_VERSION}
Architecture: amd64
Maintainer: zed-deb repository <noreply@github.com>
Installed-Size: ${INSTALLED_SIZE}
Depends: ${AUTO_DEPS}
Recommends: fonts-noto, libvulkan1, libwayland-client0
Section: editors
Priority: optional
Homepage: https://zed.dev
Description: A high-performance, multiplayer code editor
 Zed is a high-performance, multiplayer code editor from the creators
 of Atom and Tree-sitter.
CTLEOF

dpkg-deb --build --root-owner-group "${PKG_DIR}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/../packages"
mkdir -p "${OUTPUT_DIR}"
mv "${PKG_DIR}.deb" "${OUTPUT_DIR}/zed_${DEB_VERSION}_amd64.deb"

echo "Built: packages/zed_${DEB_VERSION}_amd64.deb"
echo "${DEB_VERSION}" > "${OUTPUT_DIR}/.latest-version"
