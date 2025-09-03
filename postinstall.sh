#!/bin/sh
set -e

chmod +x /usr/bin/rpi-usb-gadget

# Ensure overlay present exactly once
OL='dtoverlay=dwc2,dr_mode=peripheral'
CFG_FW=/boot/firmware/config.txt
CFG_LEG=/boot/config.txt
grep -qxF "$OL" "$CFG_FW" 2>/dev/null || echo "$OL" >> "$CFG_FW" 2>/dev/null || \
grep -qxF "$OL" "$CFG_LEG" 2>/dev/null || echo "$OL" >> "$CFG_LEG"

# Stamp serial into g_ether options
SERIAL=$(awk '/^Serial/{print $3}' /proc/cpuinfo)
sed -i "s/<serial>/$SERIAL/g" /etc/modprobe.d/g_ether.conf

udevadm control --reload-rules || true
udevadm trigger --subsystem-match=net || true

systemctl enable systemd-networkd || true

echo "- - USB CDC Ethernet+Serial Gadget configured, please reboot. - -"
