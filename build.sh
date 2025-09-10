#!/usr/bin/env bash
set -Eeuo pipefail

# Usage:
#   ./build.sh           # build arm64 (host) + armhf
#   ./build.sh arm64     # build only arm64
#   ./build.sh armhf     # build only armhf

if (( $# == 0 )); then ARCHES=(arm64 armhf); else ARCHES=("$@"); fi
OUT="${OUT:-out}"

# Non-.deb artefacts created in parent dir by dpkg-buildpackage/debuild
EXTRA_PATTERNS=( "*.build" "*.buildinfo" "*.changes" "*.dsc" "*.tar.*" )

clean_tree() {
  # Clean package staging + dh state
  debian/rules clean || true
  rm -rf debian/.debhelper debian/*-dbgsym debian/*-stamp \
         debian/rpi-usb-gadget debian/tmp ics-watch || true
}

move_and_prune_parent() {
  local arch="$1"
  mkdir -p "$OUT/$arch"
  shopt -s nullglob
  for f in ../*.deb; do mv -v "$f" "$OUT/$arch/"; done
  for pat in "${EXTRA_PATTERNS[@]}"; do
    for f in ../$pat; do rm -f "$f"; done
  done
}

build_one() {
  local arch="$1"
  echo "==> Building for $arch"
  clean_tree

  if [[ "$arch" == "armhf" ]]; then
    # --- cross build pre-reqs (one-time setup) ---
    # sudo dpkg --add-architecture armhf
    # sudo apt update
    # sudo apt install gcc-arm-linux-gnueabihf pkgconf \
    #                  libnm-dev:armhf libglib2.0-dev:armhf
    command -v arm-linux-gnueabihf-gcc >/dev/null \
      || { echo "Missing arm-linux-gnueabihf-gcc (install gcc-arm-linux-gnueabihf)"; exit 2; }
    [[ -f /usr/lib/arm-linux-gnueabihf/pkgconfig/libnm.pc ]] \
      || { echo "Missing libnm-dev:armhf (and likely libglib2.0-dev:armhf)"; exit 2; }

    export CC=arm-linux-gnueabihf-gcc
    export PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig

    # Build binary-only for the target arch
    dpkg-buildpackage -b -us -uc -tc -aarmhf
  else
    # Native arm64 (host)
    dpkg-buildpackage -b -us -uc -tc
  fi

  move_and_prune_parent "$arch"
  clean_tree
}

mkdir -p "$OUT"
for arch in "${ARCHES[@]}"; do
  build_one "$arch"
done

echo "✅ Done. .deb files are in:"
find "$OUT" -maxdepth 2 -type f -name "*.deb" -print
