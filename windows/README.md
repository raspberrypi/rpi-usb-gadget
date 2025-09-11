# Raspberry Pi USB RNDIS Driver (Windows)

This installer adds support for the **Raspberry Pi USB Remote NDIS Network Device** on Windows.
When a Raspberry Pi is configured in USB gadget mode, Windows will recognize it as a USB Ethernet adapter and create a new network interface. This enables networking between your PC and the Pi over a single USB cable and allows features provided by the `rpi-usb-gadget` package (e.g., Internet Connection Sharing to the Pi).

## What this installs

* Driver package for device ID: `USB\VID_2E8A&PID_0013`
* Uses Microsoft’s in-box RNDIS components (`netrndis.inf`/`usbrndis6`)
* Display name: **Raspberry Pi USB Remote NDIS Network Device**
* Files are staged in the Windows Driver Store via `pnputil`.

## Supported systems

* **Windows 10** (64-bit) and **Windows 11** (64-bit), including ARM64 (not tested)
* Admin rights are required to install drivers.
* Secure Boot/driver enforcement: the provided catalog (`raspberrypi-rndis.cat`) must be properly signed in production environments.

## Prerequisites on the Raspberry Pi

On the Pi, install and enable the gadget stack (for example using the `rpi-usb-gadget` package).
Use a **data-capable** USB-C cable connected to the Pi’s USB-C port.

## Installation (on Windows)

1. Close applications that might alter network settings (VPNs, firewalls, etc.).
2. Run **Raspberry Pi USB RNDIS Driver** setup **as Administrator**.
3. After setup completes, **plug the Pi** into the PC via USB-C.
4. Windows will detect and bind the **Raspberry Pi USB Remote NDIS Network Device**.
   You should see a new “Ethernet” adapter in *Settings → Network & Internet* (or Device Manager → Network adapters).

## First connection & networking

You have two typical ways to network the Pi and PC:

### A) Host-shares-Internet to the Pi (Windows ICS)

1. On Windows, open **Settings → Network & Internet → Advanced network settings**.
2. Select your primary Internet adapter → **Allow other network users to connect** (Internet Connection Sharing).
3. Choose the **Raspberry Pi USB…** adapter as the shared connection.
   Windows usually assigns gateway **192.168.137.1** to the shared adapter.

### B) Pi provides a shared network (Pi NAT/DHCP)

If you configured the Pi to serve DHCP/NAT on the gadget interface (e.g. `10.12.194.0/28`), Windows will obtain an IP from the Pi automatically once the interface is up.

> The `rpi-usb-gadget-ics` service can automatically switch between **client** (DHCP via host ICS) and **shared** modes, depending on whether a gateway is detected on the USB link.

## Verifying

* **Device Manager → Network adapters** should list **Raspberry Pi USB Remote NDIS Network Device** without warnings.
* `Control Panel → Network Connections` shows a new **Ethernet** adapter; `ipconfig` should display an IPv4 address once connected.

## Uninstall

* Use **Apps & features** to remove **Raspberry Pi USB RNDIS Driver**, or
* The uninstaller runs a PowerShell script to remove matching driver packages from the Driver Store using `pnputil`.
* Manual removal (advanced):

  ```
  pnputil /enum-drivers | findstr /I "Raspberry Pi RNDIS"
  pnputil /delete-driver <PublishedName>.inf /uninstall /force
  ```

## Troubleshooting

* **Device shows as Unknown / Code 10:** try a different USB-C cable/port; ensure the Pi is in gadget mode.
* **Driver refused / signature error:** ensure the catalog is properly signed and timestamped; Secure Boot may block unsigned drivers.
* **No IP connectivity:** check whether you expect ICS (host gateway `192.168.137.1`) or Pi-side DHCP/NAT; only enable one at a time.
* **Firewall/VPN interference:** some security software blocks RNDIS or ICS; temporarily disable or add an allow-rule.
* **Corporate policy blocks RNDIS:** some environments disable RNDIS for security; contact your administrator.

## Security note

RNDIS is a legacy USB networking protocol. Use only with trusted devices and networks. Keep your OS and security software up to date.

## License & support

* Copyright © 2025 Raspberry Pi Ltd.
* Driver uses Microsoft in-box components; this package supplies matching metadata and catalog.
* Project page: [https://github.com/raspberrypi/rpi-usb-gadget](https://github.com/raspberrypi/rpi-usb-gadget)
