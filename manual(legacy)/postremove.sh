#!/bin/bash

# undo mod loading
sed -i 's/dtoverlay=dwc2,dr_mode=peripheral//g' /boot/firmware/config.txt || sed -i 's/dtoverlay=dwc2,dr_mode=peripheral//g' /boot/config.txt
