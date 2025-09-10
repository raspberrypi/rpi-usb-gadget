# Raspberry Pi USB Gadget

This package turns your Raspberry Pi into a **USB Ethernet gadget** using the kernel’s `g_ether` driver. On the host it appears as:

* **CDC-ECM** on Linux and macOS
* **RNDIS** on Windows (use the included Raspberry Pi USB RNDIS driver for fastest onboarding)

It’s designed for headless setups and for places where Wi-Fi isn’t available or allowed. With a single Micro USB or USB-C cable you get a network link that’s ideal for SSH, file copy, and remote dev (e.g. VS Code), with **very low latency**.

## What’s new / how it behaves

* **Auto client/shared switching (NetworkManager):**
  We install two NM profiles on the gadget interface (default `usb0`) and run a small watcher service:

  * **USB Gadget (client):** Pi is a **DHCP client** of the host (used when host Internet Connection Sharing is detected; typical host gateways: `192.168.137.1`, `192.168.2.1`, `10.42.0.1`).
  * **USB Gadget (shared):** Pi provides **DHCP + NAT** to the host at `10.12.194.1/28`.

  The watcher automatically flips between these modes based on whether an ICS gateway is reachable.

* **USB Ethernet only by default:**
  We do **not** enable a serial gadget (`/dev/ttyGS0`) by default.

* **Host support:**
  Windows (with RNDIS driver), macOS, and Linux hosts.

## Features

* **Plug-and-play**: Just connect a Micro USB or USB-C cable; NM profiles and the watcher handle networking.
* **Headless operation**: No Wi-Fi, monitor, or keyboard required.
* **Low latency**: Typically sub-millisecond round-trips on the USB link.
* **Internet sharing either way**:

  * Via **host ICS** (Pi is client), or
  * Via **Pi shared** (Pi serves DHCP/NAT at `10.12.194.1/28`).
* **Wide compatibility**: Works on Raspberry Pi Zero/Zero 2 W, 3A+, 4B, 5, and similar models with USB device mode.

> Tip: If you attach multiple Pis to the same host, prefer **host ICS** (so each Pi gets a unique host-assigned IP), or adjust each Pi’s shared subnet (`nmcli con modify "USB Gadget (shared)" ipv4.addresses …`).

## Addressing & Modes

This package creates **two NetworkManager profiles** on the Pi’s USB gadget interface (default `usb0`) and a small watcher that **auto-switches** between them:

* **CLIENT mode** – the Pi is a DHCP **client** of the host.

  * Used when an Internet Connection Sharing (ICS) **gateway is detected on the host**.
  * Typical host ICS gateways: **192.168.137.1** (Windows), **192.168.2.1** (macOS), **10.42.0.1** (Linux).
  * The Pi receives its IP and default route **from the host**. No NAT on the Pi.

* **SHARED mode** – the Pi **serves** DHCP/NAT to the host (via NM “shared”).

  * Default address on the Pi: **10.12.194.1/28**
  * DHCP pool to the host: **10.12.194.2–10.12.194.14** (short 2-minute leases)
  * NAT is performed **on the Pi** to its other uplink(s).

The watcher (`rpi-usb-gadget-ics.service`) checks for a reachable ICS gateway on `usb0`. If found, it switches to **CLIENT**; otherwise it runs **SHARED**.

### Default subnetwork (SHARED mode)

* **Network:** `10.12.194.0/28`
* **Pi address (gateway):** `10.12.194.1`
* **Usable host pool:** `10.12.194.2`–`10.12.194.14` (14 IPs)
* **Broadcast:** `10.12.194.15`
* **Mask:** `255.255.255.240` (`/28`)

This narrow subnet minimizes the chance of colliding with the host’s other networks.

> **Multiple Pis on one host:** If you plug several Pis into the same machine **at the same time**, and they all run **SHARED** mode with the default `/28`, the host will see overlapping subnets. Prefer enabling **host ICS** so devices run in **CLIENT** mode, or change each Pi’s SHARED subnet, e.g.:
>
> ```bash
> sudo nmcli connection modify "USB Gadget (shared)" ipv4.addresses 10.12.195.1/28
> sudo nmcli connection down "USB Gadget (shared)"; sudo nmcli connection up "USB Gadget (shared)"
> ```
>
> mDNS (`<hostname>.local`) is still a convenient way to reach a specific Pi.

## How It Works

This package enables the **USB Ethernet gadget** (`g_ether`) and configures NetworkManager to manage the gadget link:

* **Interface:** `usb0` (or set `USB_GADGET_IFACE` in the service environment)
* **Profiles:**

  * **USB Gadget (client)** – DHCP client of the host (for host ICS)
  * **USB Gadget (shared)** – NM “shared” (DHCP+NAT served by the Pi)
* **Auto-switcher:** `rpi-usb-gadget-ics.service` probes for a host ICS gateway via ARP and flips profiles accordingly.

> **Note:** The current package ships **USB Ethernet only**. A serial gadget (`/dev/ttyGS0`) is **not** enabled by default.

### Accessing the Pi

* **In SHARED mode:** the Pi is `10.12.194.1`. SSH: `ssh pi@10.12.194.1`
* **In CLIENT mode:** the Pi receives its IP from the host’s ICS network (check the host adapter); you can also try `ssh pi@<hostname>.local` (mDNS).

On Windows, installing the supplied **Raspberry Pi USB RNDIS Driver** helps the host bind quickly to the gadget as an Ethernet adapter.

## Installation

// install via apt with apt update before
### a) Using the APT repository (recommended for easy updates)

1. Update your package list and install the package:
   ```bash
   sudo apt update
   sudo apt install rpi-usb-gadget
   ```
2. Enable the feature:
   ```bash
   sudo rpi-usb-gadget on
   ```
3. Reboot your Raspberry Pi.
   ```bash
   sudo reboot
   ```

### b) Manual installation

1. Download the `.deb` package from the [releases page](https://github.com/raspberrypi/rpi-usb-gadget/releases).
2. Install the package using:
   ```bash
   sudo apt install ./rpi-usb-gadget.deb
   ```
3. Enable the feature:
   ```bash
   sudo rpi-usb-gadget on
   ```
4. Reboot your Raspberry Pi.
   ```bash
   sudo reboot
   ```

## Usage

Simply plug your Raspberry Pi into your PC/laptop using a USB cable, and it will be recognized as an Ethernet device. 

> Important: Not all USB ports on your Raspberry Pi support USB OTG (which is required for this to work). On Pi 4 / 5 models, use the USB-C port, and on Pi Zero models, use the micro-USB port closest to the mini-HDMI port. For the A / A+ models, you'll need to use a custom USB-A to USB-A cable with the 5V wire snipped.

You can then connect to it via SSH, transfer files, or use remote development tools like VS Code.

## Using Raspberry Pi Imager

You can also configure this functionality directly within the [Raspberry Pi Imager](https://raspberrypi.com/software) tool. Simply select "USB Gadget mode" in the `Interfaces & Features` customization tab to enable it and make sure you have also configured ssh for remote access in imager.

For command-line users, this feature can also be activated with the `--usb-ether-gadget` flag when using the rpi-imager-cli.

```bash
rpi-imager-cli --usb-gadget
```

## Contributions

Contributions are welcome! Please submit a pull request or open an issue for feedback and improvements.
