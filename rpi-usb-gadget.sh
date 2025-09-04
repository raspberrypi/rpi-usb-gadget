#!/bin/bash

# check if the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo -e "\e[31mPlease run this script as root\e[0m"
    exit
fi

# check if the script is run on a Raspberry Pi
if ! grep -q "Raspberry Pi" /proc/device-tree/model; then
    echo -e "\e[31mThis script is for Raspberry Pi devices only\e[0m"
    exit
fi

# --- settings for NetworkManager profile ---
NM_CONN_NAME='USB Gadget (client)'
NM_IFACE="${USB_GADGET_IFACE:-usb0}"
NM_STATIC_ADDR="10.12.194.1/28"
NM_ROUTE_METRIC=100

have_nmcli() { command -v nmcli >/dev/null 2>&1; }

nm_configure_client() {
    if ! have_nmcli; then
        echo -e "\e[33mNetworkManager not found (nmcli missing). Skipping NM config.\e[0m"
        return 0
    fi

    # Create or modify the connection
    if nmcli -t -f NAME connection show | grep -Fxq "$NM_CONN_NAME"; then
        nmcli connection modify "$NM_CONN_NAME" \
            connection.type ethernet \
            connection.interface-name "$NM_IFACE" \
            ipv4.method auto \
            ipv4.addresses "$NM_STATIC_ADDR" \
            ipv4.may-fail no \
            ipv4.route-metric "$NM_ROUTE_METRIC" \
            ipv6.method ignore || true
    else
        nmcli connection add type ethernet ifname "$NM_IFACE" con-name "$NM_CONN_NAME" \
            ipv4.method auto \
            ipv4.addresses "$NM_STATIC_ADDR" \
            ipv4.may-fail no \
            ipv4.route-metric "$NM_ROUTE_METRIC" \
            ipv6.method ignore || true
    fi

    # Try to bring it up now (it will auto-connect on boot regardless)
    nmcli connection up "$NM_CONN_NAME" >/dev/null 2>&1 || true
}

nm_remove_client() {
    if ! have_nmcli; then
        return 0
    fi
    if nmcli -t -f NAME connection show | grep -Fxq "$NM_CONN_NAME"; then
        nmcli connection down "$NM_CONN_NAME" >/dev/null 2>&1 || true
        nmcli connection delete "$NM_CONN_NAME" >/dev/null 2>&1 || true
    fi
}

TURN_ON=true
case "$1" in
    on)      TURN_ON=true ;;
    off)     TURN_ON=false ;;
    toggle)
        if [ -f /usr/lib/modules-load.d/usb-gadget.conf ]; then
            TURN_ON=false
        fi
        ;;
    status)
        if [ -f /usr/lib/modules-load.d/usb-gadget.conf ]; then
            echo -e "\e[33mUSB Gadget mode is on\e[0m"
        else
            echo -e "\e[33mUSB Gadget mode is off\e[0m"
        fi
        if have_nmcli; then
            if nmcli -t -f NAME connection show | grep -Fxq "$NM_CONN_NAME"; then
                echo "NM connection: $NM_CONN_NAME (present)"
            else
                echo "NM connection: (none)"
            fi
        fi
        exit 0
        ;;
    help|""|*)
        echo "Usage: rpi-usb-gadget [on|off|toggle|status|help]"
        exit 1
        ;;
esac

cfg_fw=/boot/firmware/config.txt
cfg_legacy=/boot/config.txt
overlay_line='dtoverlay=dwc2,dr_mode=peripheral'
#rm /etc/modprobe.d/g_ether.conf

if [ "$TURN_ON" = false ]; then
    echo -e "Turning \e[31moff\e[0m USB Gadget mode"
    rm -f /usr/lib/modules-load.d/usb-gadget.conf
    sed -i "/^${overlay_line//\//\\/}$/d" "$cfg_fw" 2>/dev/null || true
    sed -i "/^${overlay_line//\//\\/}$/d" "$cfg_legacy" 2>/dev/null || true

    # Remove NM client profile (safe no-op if missing)
    nm_remove_client

else
    echo -e "Turning \e[32mon\e[0m USB Gadget mode"
    printf "g_ether\n" > /usr/lib/modules-load.d/usb-gadget.conf
    sed -i "/^${overlay_line//\//\\/}$/d" "$cfg_fw" 2>/dev/null || true
    sed -i "/^${overlay_line//\//\\/}$/d" "$cfg_legacy" 2>/dev/null || true
    echo "$overlay_line" >> "$cfg_fw" 2>/dev/null || echo "$overlay_line" >> "$cfg_legacy"

    # Configure NetworkManager client profile for usb0 with static alias + DHCP
    nm_configure_client
fi

echo "Reboot to apply changes"
