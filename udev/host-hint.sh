set -eu

MSG="[rpi-usb-gadget] Windows users: to use USB Ethernet, install the Raspberry Pi RNDIS driver (.inf) on the Windows PC. See: https://docs-url"
if [ -w /dev/kmsg ]; then
  printf "<5>%s\n" "$MSG" > /dev/kmsg || true     # <5>=KERN_NOTICE
else
  logger -p kern.notice -t rpi-usb-gadget "$MSG" || true
fi
