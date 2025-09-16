#!/bin/sh
set -eu

IFACE="${1:-usb0}"
STAMP_DIR=/run/rpi-usb-gadget
STAMP="$STAMP_DIR/hint-$IFACE"

mkdir -p "$STAMP_DIR"
[ -e "$STAMP" ] && exit 0
: > "$STAMP"

MSG="Windows users: to use USB Ethernet, install the Raspberry Pi RNDIS driver on the Windows PC. See: https://www.raspberrypi.com/documentation/computers/usb-gadget.html#rndis-driver"
logger -p kern.notice -t rpi-usb-gadget -- "$MSG"
