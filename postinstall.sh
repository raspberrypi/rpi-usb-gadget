#!/bin/bash

chmod +x /usr/bin/rpi-usb-ether-gadget

echo "dtoverlay=dwc2,dr_mode=peripheral" >> /boot/firmware/config.txt || echo "dtoverlay=dwc2,dr_mode=peripheral" >> /boot/config.txt

SERIAL=$(grep Serial /proc/cpuinfo | awk '{print $3}')
sed -i "s/<serial>/$SERIAL/g" /etc/modprobe.d/g_ether.conf

systemctl enable systemd-networkd

echo "- - USB Ethernet Gadget configured, please reboot for changes to take effect. - -"
