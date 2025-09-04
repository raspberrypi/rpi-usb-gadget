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

# --- settings ---
NM_IFACE="${USB_GADGET_IFACE:-usb0}"

CLIENT_NAME='USB Gadget (client)'
SHARED_NAME='USB Gadget (shared)'

SHARED_ADDR="10.12.194.1/28"
CLIENT_DHCP_TIMEOUT=6
CLIENT_ROUTE_METRIC=100

# modules-load + overlay
mods_conf="/usr/lib/modules-load.d/usb-gadget.conf"
cfg_fw=/boot/firmware/config.txt
cfg_legacy=/boot/config.txt
overlay_line='dtoverlay=dwc2,dr_mode=peripheral'

have_nmcli() { command -v nmcli >/dev/null 2>&1; }

nm_ensure_client() {
    # DHCP client (for ICS); IPv6 disabled; short timeout; prefer routes via DHCP
    if nmcli -t -f NAME connection show | grep -Fxq "$CLIENT_NAME"; then
        nmcli connection modify "$CLIENT_NAME" \
            connection.type ethernet \
            connection.interface-name "$NM_IFACE" \
            autoconnect yes \
            autoconnect-priority 100 \
            ipv4.method auto \
            ipv4.may-fail no \
            ipv4.route-metric "$CLIENT_ROUTE_METRIC" \
            ipv4.dhcp-timeout "$CLIENT_DHCP_TIMEOUT" \
            ipv6.method disabled || true
    else
        nmcli connection add type ethernet ifname "$NM_IFACE" con-name "$CLIENT_NAME" \
            autoconnect yes \
            autoconnect-priority 100 \
            ipv4.method auto \
            ipv4.may-fail no \
            ipv4.route-metric "$CLIENT_ROUTE_METRIC" \
            ipv4.dhcp-timeout "$CLIENT_DHCP_TIMEOUT" \
            ipv6.method disabled || true
    fi
}

nm_ensure_shared() {
    # Pi serves DHCP+NAT on 10.12.194.0/28; IPv6 disabled; do NOT autoconnect
    if nmcli -t -f NAME connection show | grep -Fxq "$SHARED_NAME"; then
        nmcli connection modify "$SHARED_NAME" \
            connection.type ethernet \
            connection.interface-name "$NM_IFACE" \
            autoconnect no \
            autoconnect-priority 10 \
            ipv4.method shared \
            ipv4.addresses "$SHARED_ADDR" \
            ipv6.method disabled || true
    else
        nmcli connection add type ethernet ifname "$NM_IFACE" con-name "$SHARED_NAME" \
            autoconnect no \
            autoconnect-priority 10 \
            ipv4.method shared \
            ipv4.addresses "$SHARED_ADDR" \
            ipv6.method disabled || true
    fi
}

nm_install_dispatcher() {
    local d="/etc/NetworkManager/dispatcher.d"
    local f="$d/20-usb-gadget-fallback"
    install -d -m 0755 "$d"
    cat > "$f" <<'EOF'
#!/bin/sh
# Auto-switch usb0 between client (ICS) and shared (fallback)
IF="$1"
ACTION="$2"

IFACE="${USB_GADGET_IFACE:-usb0}"
CLIENT_NAME='USB Gadget (client)'
SHARED_NAME='USB Gadget (shared)'

[ "$IF" = "$IFACE" ] || exit 0

# When DHCP4 state changes, NM exports DHCP4_* variables.
# If we have a gateway, ICS is active -> use client.
# If we don't, bring up shared so host gets an IP.
case "$ACTION" in
  dhcp4-change)
    if [ -n "$DHCP4_ROUTE_GATEWAY" ]; then
      # Got lease/gateway: ensure shared is down, client is up
      nmcli con down "$SHARED_NAME" >/dev/null 2>&1 || true
      nmcli con up   "$CLIENT_NAME" >/dev/null 2>&1 || true
    else
      # No lease: fallback to shared
      nmcli con up   "$SHARED_NAME" >/dev/null 2>&1 || true
    fi
    ;;
  down)
    # Interface went down; stop shared if it was up
    nmcli con down "$SHARED_NAME" >/dev/null 2>&1 || true
    ;;
esac
EOF
    chmod 0755 "$f"
}

nm_remove_dispatcher() {
    rm -f /etc/NetworkManager/dispatcher.d/20-usb-gadget-fallback
}

nm_remove_profiles() {
    nmcli -t -f NAME connection show | grep -Fxq "$CLIENT_NAME" && \
        nmcli connection delete "$CLIENT_NAME" >/dev/null 2>&1 || true
    nmcli -t -f NAME connection show | grep -Fxq "$SHARED_NAME" && \
        nmcli connection delete "$SHARED_NAME" >/dev/null 2>&1 || true
}

TURN_ON=true
case "$1" in
    on)      TURN_ON=true ;;
    off)     TURN_ON=false ;;
    toggle)
        if [ -f "$mods_conf" ]; then
            TURN_ON=false
        fi
        ;;
    status)
        if [ -f "$mods_conf" ]; then
            echo -e "\e[33mUSB Gadget mode is on\e[0m"
        else
            echo -e "\e[33mUSB Gadget mode is off\e[0m"
        fi
        if have_nmcli; then
            echo ":: NetworkManager:"
            nmcli device status | awk 'NR==1 || $1 ~ /^usb[0-9]+$/'
            nmcli -g GENERAL.STATE,IP4.ADDRESS,IP4.GATEWAY device show "$NM_IFACE" 2>/dev/null || true
            nmcli -t -f NAME connection show | grep -E "^(${CLIENT_NAME}|${SHARED_NAME})$" || echo "(no gadget profiles)"
        fi
        exit 0
        ;;
    help|""|*)
        echo "Usage: rpi-usb-gadget [on|off|toggle|status|help]"
        exit 1
        ;;
esac

if [ "$TURN_ON" = false ]; then
    echo -e "Turning \e[31moff\e[0m USB Gadget mode"

    # stop NM bits first
    if have_nmcli; then
        nmcli con down "$SHARED_NAME" >/dev/null 2>&1 || true
        nmcli con down "$CLIENT_NAME" >/dev/null 2>&1 || true
        nm_remove_profiles
        nm_remove_dispatcher
        nmcli connection reload >/dev/null 2>&1 || true
    fi

    # kernel gadget off
    rm -f "$mods_conf"
    sed -i "/^${overlay_line//\//\\/}$/d" "$cfg_fw" 2>/dev/null || true
    sed -i "/^${overlay_line//\//\\/}$/d" "$cfg_legacy" 2>/dev/null || true

else
    echo -e "Turning \e[32mon\e[0m USB Gadget mode"
    printf "g_ether\n" > "$mods_conf"
    # ensure overlay present once
    sed -i "/^${overlay_line//\//\\/}$/d" "$cfg_fw" 2>/dev/null || true
    sed -i "/^${overlay_line//\//\\/}$/d" "$cfg_legacy" 2>/dev/null || true
    echo "$overlay_line" >> "$cfg_fw" 2>/dev/null || echo "$overlay_line" >> "$cfg_legacy"

    # NetworkManager: client + shared + dispatcher
    if have_nmcli; then
        nm_ensure_client
        nm_ensure_shared
        nm_install_dispatcher
        nmcli connection reload >/dev/null 2>&1 || true

        # Try client first; dispatcher will flip to shared if no DHCP/gateway
        nmcli con down "$SHARED_NAME" >/dev/null 2>&1 || true
        nmcli con up "$CLIENT_NAME"   >/dev/null 2>&1 || true
    else
        echo -e "\e[33mNetworkManager (nmcli) not found; skipping NM auto-config.\e[0m"
    fi
fi

echo "Reboot to apply changes"
