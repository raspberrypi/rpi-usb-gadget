#!/usr/bin/env bash
set -euo pipefail

PKG_NAME="rpi-usb-gadget"   # adjust if your binary package name differs
OUT_DIR="$(pwd)/out"

# ---------- helpers ----------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1"; exit 1; }; }
have_pkg() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

clean_artifacts() {
  echo "==> Cleaning build artifacts"
  # devscripts
  if command -v debclean >/dev/null 2>&1; then debclean -d || true; fi

  # Parent-dir artifacts that debuild/dpkg-buildpackage usually drop
  rm -f ../*.build ../*.buildinfo ../*.changes ../*.dsc ../*.tar.* 2>/dev/null || true

  # In-tree dh cruft (just in case)
  rm -rf debian/.debhelper debian/${PKG_NAME} debian/tmp debian/*-dbgsym 2>/dev/null || true
}

move_debs() {
  mkdir -p "${OUT_DIR}"
  shopt -s nullglob
  for f in ../*.deb; do
    echo "==> Moving $(basename "$f") -> out/"
    mv -f "$f" "${OUT_DIR}/"
  done
  shopt -u nullglob
}

preflight_cross_armhf() {
  # Enable armhf multiarch if not already
  if ! dpkg --print-foreign-architectures | grep -qx "armhf"; then
    echo "==> Enabling armhf multiarch"
    sudo dpkg --add-architecture armhf
    sudo apt update
  fi

  # Tools + dev headers for cross
  local missing=()
  have_pkg gcc-arm-linux-gnueabihf || missing+=(gcc-arm-linux-gnueabihf)
  have_pkg pkgconf                  || missing+=(pkgconf)
  have_pkg libnm-dev:armhf         || missing+=(libnm-dev:armhf)
  have_pkg libglib2.0-dev:armhf    || missing+=(libglib2.0-dev:armhf)

  if ((${#missing[@]})); then
    echo "==> Installing cross build deps: ${missing[*]}"
    sudo apt install -y "${missing[@]}"
  fi

  # For native (arm64) build, ensure headers exist too (helps IntelliSense and native build)
  local native_missing=()
  have_pkg libnm-dev:arm64      || native_missing+=(libnm-dev:arm64)
  have_pkg libglib2.0-dev:arm64 || native_missing+=(libglib2.0-dev:arm64)
  if ((${#native_missing[@]})); then
    echo "==> Installing native dev headers: ${native_missing[*]}"
    sudo apt install -y "${native_missing[@]}"
  fi
}

# ---------- main ----------
need debuild
need dpkg-buildpackage

clean_artifacts

echo "==> Building native .deb (host arch)"
# -b = binary-only (no source); -us -uc = unsigned
debuild -us -uc -b
move_debs

echo "==> Preparing cross build for armhf"
preflight_cross_armhf
clean_artifacts

echo "==> Building armhf .deb (cross)"
# Ensure pkg-config finds the armhf .pc files and use the armhf compiler.
export CC=arm-linux-gnueabihf-gcc
export PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig
# Tell dpkg-buildpackage to build for armhf; -b = binary-only
dpkg-buildpackage -us -uc -b -a armhf
move_debs

# Final tidy: remove anything left in ../ that isn’t a .deb (just in case)
rm -f ../*.build ../*.buildinfo ../*.changes ../*.dsc ../*.tar.* 2>/dev/null || true

echo "==> Done. Artifacts:"
ls -1 "${OUT_DIR}"/*.deb
