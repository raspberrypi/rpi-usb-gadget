#!/bin/sh

# undo mod loading
sed -i 's/dtoverlay=dwc2,dr_mode=peripheral//g' /boot/firmware/config.txt || sed -i 's/dtoverlay=dwc2,dr_mode=peripheral//g' /boot/config.txt

# disable systemd-networkd if no files in /etc/systemd/network with .network
if [ ! -f /etc/systemd/network/*.network ]; then
    systemctl disable systemd-networkd
fi
