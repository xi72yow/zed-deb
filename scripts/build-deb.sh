#!/bin/bash
set -euo pipefail

# Build a .deb package from Zed's official Linux tarball
# Usage: ./scripts/build-deb.sh [VERSION] [REVISION]

VERSION="${1:-}"
REVISION="${2:-1}"

if [ -z "$VERSION" ]; then
  echo "Fetching latest Zed release version..."
  VERSION=$(curl -sL "https://api.github.com/repos/zed-industries/zed/releases/latest" | jq -r ".tag_name" | sed "s/^v//")
fi

VERSION="${VERSION#v}"

echo "Building zed ${VERSION}-${REVISION} for amd64..."

WORKDIR=$(mktemp -d)
trap "rm -rf ${WORKDIR}" EXIT

TARBALL_URL="https://github.com/zed-industries/zed/releases/download/v${VERSION}/zed-linux-x86_64.tar.gz"
DEB_VERSION="${VERSION}-${REVISION}"
PKG_DIR="${WORKDIR}/zed_${DEB_VERSION}_amd64"

echo "Downloading ${TARBALL_URL}..."
curl -fSL "${TARBALL_URL}" -o "${WORKDIR}/zed.tar.gz"
mkdir -p "${WORKDIR}/extract"
tar xzf "${WORKDIR}/zed.tar.gz" -C "${WORKDIR}/extract"

ZED_DIR=$(find "${WORKDIR}/extract" -maxdepth 1 -type d -name "zed*" | head -1 || true)
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
  # Ensure StartupWMClass is set so GNOME dock can match the window to the .desktop entry
  if ! grep -q '^StartupWMClass=' "${PKG_DIR}/usr/share/applications/zed.desktop"; then
    echo 'StartupWMClass=dev.zed.Zed' >> "${PKG_DIR}/usr/share/applications/zed.desktop"
  fi
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
StartupWMClass=dev.zed.Zed
Keywords=text;editor;code;
DSKEOF
fi

# Licenses from upstream
if [ -f "${ZED_DIR}/licenses.md" ]; then
  cp "${ZED_DIR}/licenses.md" "${PKG_DIR}/usr/share/doc/zed/licenses.md"
fi

# Changelog from GitHub release notes
echo "Fetching release notes for v${VERSION}..."
RELEASE_JSON=$(curl -sL "https://api.github.com/repos/zed-industries/zed/releases/tags/v${VERSION}")
RELEASE_BODY=$(echo "$RELEASE_JSON" | jq -r '.body // empty')
RELEASE_DATE=$(echo "$RELEASE_JSON" | jq -r '.published_at // empty')

if [ -n "$RELEASE_DATE" ]; then
  CHANGELOG_DATE=$(date -d "$RELEASE_DATE" -R 2>/dev/null || date -R)
else
  CHANGELOG_DATE=$(date -R)
fi

{
  echo "zed (${DEB_VERSION}) stable; urgency=medium"
  echo ""
  if [ -n "$RELEASE_BODY" ]; then
    echo "$RELEASE_BODY" | while IFS= read -r line; do
      # Convert markdown list items to changelog entries
      if echo "$line" | grep -qE '^\s*[-*]'; then
        cleaned=$(echo "$line" | sed 's/^\s*[-*]\s*//')
        echo "  * $cleaned"
      elif [ -n "$line" ]; then
        echo "  $line"
      fi
    done
  else
    echo "  * New upstream release v${VERSION}"
  fi
  echo ""
  echo " -- zed-deb repository <noreply@github.com>  ${CHANGELOG_DATE}"
} > "${PKG_DIR}/usr/share/doc/zed/changelog.Debian"

gzip -9n "${PKG_DIR}/usr/share/doc/zed/changelog.Debian"

# AppStream metainfo with release notes
mkdir -p "${PKG_DIR}/usr/share/metainfo"
RELEASE_DATE_ISO=$(echo "$RELEASE_DATE" | sed 's/T.*//')
if [ -z "$RELEASE_DATE_ISO" ]; then
  RELEASE_DATE_ISO=$(date -I)
fi

# Convert markdown list items to XML <li> elements via sed
# First strip markdown link syntax [text](url) to plain text, escape XML entities, then wrap in <li>
if [ -n "$RELEASE_BODY" ]; then
  RELEASE_LI=$(echo "$RELEASE_BODY" \
    | tr -d '\r' \
    | grep -E '^\s*[-*]\s' \
    | sed 's/^\s*[-*]\s*//' \
    | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g' \
    | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' \
    | sed 's/^/          <li>/; s/$/<\/li>/')
fi

cat > "${PKG_DIR}/usr/share/metainfo/zed.metainfo.xml" << METAEOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>zed</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>GPL-3.0-or-later</project_license>
  <name>Zed</name>
  <summary>A high-performance, multiplayer code editor</summary>
  <description>
    <p>Zed is a high-performance, multiplayer code editor from the creators of Atom and Tree-sitter.</p>
  </description>
  <launchable type="desktop-id">zed.desktop</launchable>
  <url type="homepage">https://zed.dev</url>
  <url type="bugtracker">https://github.com/zed-industries/zed/issues</url>
  <releases>
    <release version="${VERSION}" date="${RELEASE_DATE_ISO}">
      <description>
        <ul>
${RELEASE_LI:-          <li>New upstream release v${VERSION}</li>}
        </ul>
      </description>
    </release>
  </releases>
</component>
METAEOF

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

cat > "${PKG_DIR}/DEBIAN/control" << CTLEOF
Package: zed
Version: ${DEB_VERSION}
Architecture: amd64
Maintainer: zed-deb repository <noreply@github.com>
Installed-Size: ${INSTALLED_SIZE}
Depends: libc6, libstdc++6, libgcc-s1, libasound2, libvulkan1
Recommends: libwayland-client0, pipewire-alsa | pulseaudio, xdg-desktop-portal
Suggests: fonts-noto, gnome-keyring | kwalletmanager
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
