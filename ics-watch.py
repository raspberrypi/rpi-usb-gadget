#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (C) 2025 Raspberry Pi Ltd.
#
# “ICS” = Internet Connection Sharing (host-side NAT/DHCP).
#
import time, subprocess, sys, socket, struct
import os, gi
gi.require_version("NM", "1.0")
from gi.repository import GLib, NM


ICS_DEBUG = os.environ.get("ICS_DEBUG", "0") != "0"
#IFACE = os.environ.get("USB_GADGET_IFACE", "usb0")
IFACE = "usb0"
#CLIENT_ID = os.environ.get("CLIENT_NAME", "USB Gadget (client)")
#SHARED_ID = os.environ.get("SHARED_NAME", "USB Gadget (shared)")
CLIENT_ID = "USB Gadget (client)"
SHARED_ID = "USB Gadget (shared)"

# win/mac/linux defaults
ICS_GWS = ["192.168.137.1", "192.168.2.1", "10.42.0.1"]

# Tunables
LOOP_MS = 4000          # periodic check in ms
FALLBACK_DELAY = 5      # in s
MINDWELL = 1            # in s
GW_STABLE = 3           # in s
GW_UNREACH_GRACE = 1    # in s
PROBE_EVERY = 12        # in s
PROBE_TIMEOUT = 4       # in s

last_switch = 0
last_link_up = 0
last_probe = 0
last_gw_ok = 0
client: NM.Client | None = None


def now() -> int: return int(time.time())


def log(*a, force: bool = False) -> None:
    if ICS_DEBUG or force:
        print(f"[ics-watch | {time.strftime('%Y-%m-%d %H:%M:%S')}]", *a, flush=True)


def device() -> NM.Device | None:
    d = client.get_device_by_iface(IFACE)
    if d and d.get_device_type() == NM.DeviceType.ETHERNET:
        return d
    return None


def active_con_name(dev: NM.Device) -> str:
    assert dev is not None
    ac: NM.ActiveConnection | None = dev.get_active_connection()
    if not ac: return ""
    s: NM.RemoteConnection = ac.get_connection()
    return s and s.get_id() or ""


def conn_by_id(name: str) -> NM.Connection | None:
    for c in client.get_connections():
        if c.get_id() == name:
            return c
    return None


def up(name: str) -> None:
    """Activate the named connection (idempotent)."""
    c = conn_by_id(name)
    if not c:
        log(f"up(): connection '{name}' not found")
        return
    dev = device()
    if not dev:
        log("up(): device not found")
        return

    def _cb(cli, result, user_data):
        try:
            ac = cli.activate_connection_finish(result)
            if ac:
                log(f"Activated '{name}'")
        except Exception as e:
            log(f"Activate '{name}' failed: {e}")

    log(f"Activating '{name}'")
    client.activate_connection_async(c, dev, None, None, _cb, None)


def down_and_wait(name: str, timeout_ms: int = 5000) -> bool:
    """
    Deactivate the *active* connection with id `name` on IFACE.
    Blocks (nested GLib loop) until it completes or times out.
    Returns True if the connection is no longer active after completion.
    """
    dev = device()
    if not dev:
        log("down(): no device")
        return False

    ac = dev.get_active_connection()
    if not ac:
        log("down(): no active connection on device")
        return True
    if ac.get_id() != name:
        log(f"down(): '{name}' not active (active is '{ac.get_id()}'), skipping")
        return True

    try:
        client.deactivate_connection(ac, None)  # DEPRECATED
        log(f"Disconnected from '{name}'")
        return True
    except Exception as e:
        log(f"Disconnect ignored: {e}")
        return False


def _ip4_to_str(val: int | tuple[bytes, bytearray]) -> str:
    # NM’s GI returns an int (host-order) for IPv4 addresses
    if isinstance(val, int):
        return socket.inet_ntoa(struct.pack('!I', val))
    if isinstance(val, (bytes, bytearray)) and len(val) == 4:
        return socket.inet_ntoa(val)
    # already a string (fallback)
    return str(val)


def ip4_config(dev: NM.Device) -> tuple[list[str], str | None]:
    cfg = dev.get_ip4_config()
    if not cfg:
        return [], None
    addrs = []
    addrobjs = cfg.get_addresses() or []
    for a in addrobjs:
        try:
            addrs.append(_ip4_to_str(a.get_address()))
        except Exception:
            pass
    gw = cfg.get_gateway() or None
    return addrs, gw

def has_non_apipa(addrs: list[str]) -> bool:
    for a in addrs:
        if not a.startswith("169.254."):
            return True
    return False

def arping(gw: str) -> bool:
    try:
        # prefer arping; fallback to ping
        subprocess.run(["arping","-q","-c","1","-w","1","-I",IFACE,gw],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception:
        try:
            subprocess.run(["ping","-c","1","-W","1","-I",IFACE,gw],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except Exception:
            return False

def any_ics_gateway_reachable() -> bool:
    return any(arping(gw) for gw in ICS_GWS)

def maybe_switch(target: str) -> None:
    """Switch profiles with anti-flap and a tiny disconnect->activate handoff."""
    global last_switch
    dev = device()
    if not dev:
        log("maybe_switch(): device not found")
        return
    active = active_con_name(dev)
    if active == target:
        log(f"maybe_switch(): already on {target}")
        return
    if now() - last_switch < MINDWELL:
        log(f"maybe_switch(): switched too recently ({now()-last_switch}s ago)")
        return

    other = CLIENT_ID if target == SHARED_ID else SHARED_ID
    log(f"Switching to {target}")
    # drop the current attachment (if it's the other profile)
    if down_and_wait(other):
        last_switch = now()
        up(target)
        if target == CLIENT_ID:
            log("ICS Gateway detected; switched to DHCP client mode", force=True)
        else:
            log("No ICS Gateway detected; switched to shared mode", force=True)
        return
    log("maybe_switch(): failed to drop other profile; not switching")


def client_probe() -> None:
    """Briefly ensure client is up; if no gw appears within timeout, revert to shared."""
    global last_probe, last_switch, last_gw_ok
    if now() - last_probe < PROBE_EVERY:
        return
    last_probe = now()
    log("Client probe: trying DHCP in CLIENT")
    up(CLIENT_ID)
    t0 = now()
    while now() - t0 < PROBE_TIMEOUT:
        dev = device()
        addrs, gw = ip4_config(dev) if dev else ([], None)
        if gw and arping(gw):
            log("Client probe succeeded; staying CLIENT")
            last_switch = now(); last_gw_ok = now()
            return
        time.sleep(1)
    log("Client probe failed; reverting to SHARED")
    up(SHARED_ID); last_switch = now()


def carrier_up(dev: NM.Device) -> bool:
    try:
        return bool(dev.get_carrier())  # NMDeviceEthernet
    except Exception:
        # Fallback: consider “activated” as effectively up for our use-case
        return dev.get_state() == NM.DeviceState.ACTIVATED


def periodic_check() -> bool:
    global last_link_up, last_gw_ok
    log("Periodic check")

    dev = device()
    if not dev:
        log(f"No device {IFACE}")
        return True
    # Track link
    if carrier_up(dev):
        log("Link is up")
        if last_link_up == 0:
            last_link_up = now()
    else:
        log("Link is down")
        return True

    name = active_con_name(dev)
    addrs, gw = ip4_config(dev)
    # CLIENT mode
    if name == CLIENT_ID:
        log(f"CLIENT: addrs={addrs} gw={gw}")
        if gw and arping(gw):
            log("CLIENT: gateway reachable")
            last_gw_ok = now()
            return True
        # Gw unreachable
        log("CLIENT: gateway unreachable")
        since_ok = now() - (last_gw_ok or last_link_up)
        if since_ok >= GW_UNREACH_GRACE:
            #log(f"CLIENT: gateway lost for {since_ok}s; trying renew before fallback")
            #up(CLIENT_ID)
            #t0 = now()
            #while now() - t0 < PROBE_TIMEOUT:
            #    dev2 = device()
            #    _, gw2 = ip4_config(dev2)
            #    if gw2 and arping(gw2):
            #        log("CLIENT: renew succeeded; staying CLIENT")
            #        last_gw_ok = now()
            #        return True
            #    time.sleep(1)
            log("CLIENT: no gateway after renew; switching to SHARED")
            maybe_switch(SHARED_ID)
        elif (now()-last_link_up) >= FALLBACK_DELAY and not has_non_apipa(addrs):
            log("CLIENT: APIPA only; switching to SHARED")
            maybe_switch(SHARED_ID)
        else:
            log("CLIENT: waiting")
        return True

    # SHARED mode
    if name == SHARED_ID:
        log(f"SHARED: addrs={addrs} gw={gw}")
        if any_ics_gateway_reachable():
            log("SHARED: ICS gw detected; switching to CLIENT")
            maybe_switch(CLIENT_ID)
        else:
            log("SHARED: no ICS gw detected; staying SHARED")
        return True

    # No profile active yet: prefer CLIENT
    up(CLIENT_ID)
    last_link_up = now()
    return True

#def on_dev_state_changed(dev, old, new, reason):
#    # When NM changes state (link up/down, activation), re-evaluate soon
#    GLib.timeout_add_seconds(1, periodic_check)

if __name__ == "__main__":
    loop = GLib.MainLoop()
    client = NM.Client.new(None)
    #d = device()
    #if d:
    #    d.connect("state-changed", on_dev_state_changed)
    log(f"Starting ICS watcher on {IFACE}")
    GLib.timeout_add(LOOP_MS, periodic_check)

    import signal
    def _sigint(_s, _f):
        log("SIGINT received, exiting")
        loop.quit()
        exit(0)
    signal.signal(signal.SIGINT, _sigint)

    loop.run()
