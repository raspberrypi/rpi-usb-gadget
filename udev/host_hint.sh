#!/bin/sh
set -eu

MSG="[rpi-usb-gadget] Windows users: to use USB Ethernet, install the Raspberry Pi RNDIS driver on the Windows PC. See: https://www.raspberrypi.com/documentation/computers/usb-gadget.html#rndis-driver"
if [ -w /dev/kmsg ]; then
  /usr/bin/printf "<5>%s\n" "$MSG" > /dev/kmsg || true     # <5>=KERN_NOTICE
else
  /usr/bin/logger -p kern.notice -t rpi-usb-gadget "$MSG" || true
fi
