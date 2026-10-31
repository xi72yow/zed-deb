#!/bin/bash
set -euo pipefail

# Build the zed-acp-pin and zed-acp-sandbox .debs from acp-deb/, which ship no agent code
# Usage: ./scripts/build-acp-deb.sh [VERSION]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/../acp-deb"
SANDBOX_DIR="${SOURCE_DIR}/sandbox"
OUTPUT_DIR="${SCRIPT_DIR}/../packages"

# every commit touching the packages raises the version, so apt picks up changes
VERSION="${1:-1.0.$(git -C "${SCRIPT_DIR}/.." rev-list --count HEAD -- acp-deb scripts/build-acp-deb.sh)}"

NODE_IMAGE=$(sed -n 's/^FROM \(.*@sha256:[0-9a-f]\{64\}\) AS node$/\1/p' "${SANDBOX_DIR}/Containerfile")
if [ -z "${NODE_IMAGE}" ]; then
  echo "no digest-pinned node stage in acp-deb/sandbox/Containerfile" >&2
  exit 1
fi

# the local image is rebuilt exactly when its sources change
IMAGE_ID=$(cd "${SANDBOX_DIR}" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12)

WORKDIR=$(mktemp -d)
trap "rm -rf ${WORKDIR}" EXIT

# Usage: write_control <package dir> <name> <depends> <summary> <long description>
write_control() {
  local pkg_dir="$1" name="$2" depends="$3" summary="$4" long="$5"
  cat > "${pkg_dir}/DEBIAN/control" << CTLEOF
Package: ${name}
Version: ${VERSION}
Architecture: all
Maintainer: zed-deb repository <noreply@github.com>
Installed-Size: $(du -sk "${pkg_dir}" | cut -f1)
Depends: ${depends}
Recommends: zed
Section: editors
Priority: optional
Homepage: https://github.com/xi72yow/zed-deb
Description: ${summary}
${long}
CTLEOF
}

finish_package() {
  local pkg_dir="$1" name="$2"
  dpkg-deb --build --root-owner-group "${pkg_dir}"
  mkdir -p "${OUTPUT_DIR}"
  mv "${pkg_dir}.deb" "${OUTPUT_DIR}/${name}_${VERSION}_all.deb"
  echo "Built: packages/${name}_${VERSION}_all.deb"
}

build_pin() {
  local pkg_dir="${WORKDIR}/zed-acp-pin_${VERSION}_all"
  mkdir -p "${pkg_dir}/DEBIAN" "${pkg_dir}/usr/lib/systemd/user" "${pkg_dir}/usr/share/doc/zed-acp-pin"

  install -D -m 755 "${SOURCE_DIR}/zed-acp-pin" "${pkg_dir}/usr/bin/zed-acp-pin"
  install -D -m 755 "${SOURCE_DIR}/zed-acp-pin-update" "${pkg_dir}/usr/bin/zed-acp-pin-update"
  sed -i "s|@NODE_IMAGE@|${NODE_IMAGE}|" "${pkg_dir}/usr/bin/zed-acp-pin-update"
  install -m 644 "${SOURCE_DIR}"/zed-acp-pin-update.{service,timer} "${pkg_dir}/usr/lib/systemd/user/"
  install -m 644 "${SOURCE_DIR}/README.md" "${pkg_dir}/usr/share/doc/zed-acp-pin/README.md"

  write_control "${pkg_dir}" zed-acp-pin \
    "podman, libglib2.0-bin, nodejs-24 | nodejs-22 | nodejs (>= 22)" \
    "Pinned, delayed updates for the Claude ACP agent in Zed" \
" Installs the Claude ACP agent from npm per user and updates it daily,
 only to releases older than seven days. Ships no agent code itself."

  cat > "${pkg_dir}/DEBIAN/postinst" << 'POSTEOF'
#!/bin/bash
set -e
if [ "$1" = "configure" ]; then
  systemctl --global enable zed-acp-pin-update.timer 2>/dev/null || true
fi
POSTEOF
  cat > "${pkg_dir}/DEBIAN/prerm" << 'POSTEOF'
#!/bin/bash
set -e
if [ "$1" = "remove" ]; then
  systemctl --global disable zed-acp-pin-update.timer 2>/dev/null || true
fi
POSTEOF
  chmod 755 "${pkg_dir}/DEBIAN/postinst" "${pkg_dir}/DEBIAN/prerm"

  finish_package "${pkg_dir}" zed-acp-pin
}

build_sandbox() {
  local pkg_dir="${WORKDIR}/zed-acp-sandbox_${VERSION}_all"
  mkdir -p "${pkg_dir}/DEBIAN" "${pkg_dir}/usr/share/zed-acp-sandbox/image" "${pkg_dir}/usr/share/doc/zed-acp-sandbox"

  install -D -m 755 "${SOURCE_DIR}/zed-acp-sandbox" "${pkg_dir}/usr/bin/zed-acp-sandbox"
  sed -i "s|@IMAGE_ID@|${IMAGE_ID}|" "${pkg_dir}/usr/bin/zed-acp-sandbox"
  install -m 644 "${SANDBOX_DIR}"/* "${pkg_dir}/usr/share/zed-acp-sandbox/image/"
  install -m 644 "${SOURCE_DIR}"/{claude-token,keyring,dbus}.mjs "${pkg_dir}/usr/share/zed-acp-sandbox/"
  install -m 644 "${SOURCE_DIR}/README.md" "${pkg_dir}/usr/share/doc/zed-acp-sandbox/README.md"

  write_control "${pkg_dir}" zed-acp-sandbox \
    "zed-acp-pin (= ${VERSION}), podman, jq, git" \
    "Claude ACP agent for Zed in a podman sandbox" \
" Starts the pinned Claude ACP agent in a rootless podman container with a
 firewall, protected git hooks and podman inside, as profiles work and yolo."

  finish_package "${pkg_dir}" zed-acp-sandbox
}

build_pin
build_sandbox
