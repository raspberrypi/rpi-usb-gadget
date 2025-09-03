#!/bin/sh
set -e

# remove overlay line from either location
OL='dtoverlay=dwc2,dr_mode=peripheral'
for f in /boot/firmware/config.txt /boot/config.txt; do
  [ -f "$f" ] || continue
  sed -i "s/^$OL$//g" "$f" || true
  # collapse stray blank lines
  awk 'NF{p=1}p' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done

# Disable networkd only if truly unused
set -- /etc/systemd/network/*.network
[ -e "$1" ] || systemctl disable systemd-networkd || true

# Reload udev rules so the removal takes effect
udevadm control --reload-rules || true
