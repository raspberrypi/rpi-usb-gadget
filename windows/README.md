<!-- pandoc --from=gfm --to=rtf --standalone README.md -o README.rtf -->

# Raspberry Pi USB RNDIS Driver (Windows)

This installer adds support for the **Raspberry Pi USB Remote NDIS Network Device** on Windows.
When a Raspberry Pi is configured in USB gadget mode, Windows will recognize it as a USB Ethernet adapter and create a new network interface. This enables networking between your PC and the Pi over a single USB cable and allows features provided by the `rpi-usb-gadget` package (e.g., Internet Connection Sharing to the Pi).

## What this installs

* Driver INF: **raspberrypi-rndis.inf**
* Catalog: **raspberrypi-rndis.cat**
* Hardware ID: `USB\VID_2E8A&PID_0013`
* Uses Microsoft’s in-box RNDIS components (`netrndis.inf`/`usbrndis6`)
* Display name: **Raspberry Pi USB Remote NDIS Network Device**
* Files are signed and staged in the Windows Driver Store via `pnputil`.

## Supported systems

* **Windows 11** (64-bit), including ARM64 (not tested)
* Administrator rights required
* Secure Boot: requires a properly signed catalog (`.cat`) with a trusted publisher certificate

## Prerequisites on the Raspberry Pi

The Raspberry Pi must be configured to run in **USB Gadget mode**.
This enables the Pi to act as a USB Ethernet device when connected to a host.

You can enable this feature with:

```bash
sudo rpi-usb-gadget on
```

This command sets up the gadget stack and creates the required NetworkManager profiles automatically.

> **Note:**
> Use a **data-capable** USB-C cable connected to the Pi’s **USB-C port** (for Pi 4 / 5).
> On Pi Zero / Zero 2 W models, use the **micro-USB port closest to the HDMI connector**.
> The USB port labeled “PWR IN” on some models does **not** support gadget mode.

## Installation (on Windows)

1. Close applications that might alter network settings (VPNs, firewalls, etc.).
2. Download `rpi-usb-gadget-driver-setup.exe` from the [Releases page](https://github.com/raspberrypi/rpi-usb-gadget/releases)
3. Run the installer **as Administrator**. It stages and signs the driver in the Driver Store.
4. After setup completes, plug in the Raspberry Pi via USB-C (or Micro-USB on Pi Zero).
5. Windows will detect and bind the **Raspberry Pi USB Remote NDIS Network Device** automatically.
   You should see a new “Ethernet” adapter in *Settings → Network & Internet* (or Device Manager → Network adapters).

## First connection & networking

You have two typical ways the Pi and PC establish a network link — both handled automatically depending on whether Internet Connection Sharing (ICS) is enabled on Windows.

### A) Host-shares-Internet to the Pi (Windows ICS)

1. On Windows, open **Settings → Network & Internet → Advanced network settings**.
2. Select your main Internet adapter → **Allow other network users to connect** (Internet Connection Sharing).
3. Choose the **Raspberry Pi USB…** adapter as the shared connection.
   Windows will assign **192.168.137.1** to the shared adapter and provide DHCP service to the Pi.

> **Note (Windows quirk):**
> After a reboot **without the Pi connected**, Windows may leave ICS assigned to the RNDIS adapter but fail to start its DHCP service.
> When this happens, connecting the Pi will appear to hang or get a 169.254.x.x address.
> To fix it, open the adapter’s **Sharing** tab, **turn ICS off**, click **OK**, then re-enable it once the Pi is plugged in or leave it off to let the Pi use its own DHCP/NAT service.

### B) Pi provides a shared network (Pi NAT/DHCP)

If Internet Connection Sharing (ICS) is disabled on Windows, the Raspberry Pi automatically switches to its own shared mode and runs a built-in DHCP/NAT service on the USB link.
In this mode, Windows will automatically receive an IP address from the Pi (typically in the 10.12.194.x range) once the interface is up.

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
* **Signature error or "Windows can’t verify publisher"**
  - Ensure the `.cat` file is signed with a trusted publisher certificate.
  - If using a test certificate, make sure it is installed under **Trusted Root Certification Authorities** and **Trusted Publishers**, and Windows is in **test mode**.
* **No IP connectivity:** check whether you expect ICS (host gateway `192.168.137.1`) or Pi-side DHCP/NAT; only enable one at a time.
* **Firewall/VPN interference:** some security software blocks RNDIS or ICS; temporarily disable or add an allow-rule.
* **Corporate policy blocks RNDIS:** some environments disable RNDIS for security; contact your administrator.

## Security note

RNDIS is a legacy USB networking protocol. Use only with trusted devices and networks. Keep your OS and security software up to date.

## License & support

* Copyright © 2025 Raspberry Pi Ltd.
* Licensed under the Apache 2.0 License (see `LICENSE.txt` file).
* This package bundles only metadata; the driver binaries remain © Microsoft.
* The INF file was derived from the generic Microsoft RNDIS template and adapted for Raspberry Pi devices (VID 2E8A, PID 0013).
* Project page: [https://github.com/raspberrypi/rpi-usb-gadget](https://github.com/raspberrypi/rpi-usb-gadget)
