#!/bin/bash

echo "dtoverlay=dwc2,dr_mode=peripheral" >> /boot/firmware/config.txt || echo "dtoverlay=dwc2,dr_mode=peripheral" >> /boot/config.txt

chmod +x /usr/sbin/configure-usb-ether-gadget-once.sh

echo "- - USB Ethernet Gadget configured, please reboot for changes to take effect. - -"
