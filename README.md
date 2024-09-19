# USB Ethernet Gadget for Raspberry Pi OS

This package enables your Raspberry Pi to act as a USB Ethernet gadget, providing network connectivity over USB. It’s particularly useful for headless environments, where you don’t have access to a Wi-Fi network, monitor, keyboard, or mouse. The gadget supports network sharing from your PC/laptop to the Raspberry Pi, making it ideal for various environments like hotels, schools, or public spaces where direct Wi-Fi communication might be restricted. 

Additionally, it offers ultra-low latency (sub 1 millisecond), perfect for large data transfers, remote development using tools like Visual Studio Code, and other performance-critical tasks.

## Features

- **Plug-and-play**: No complex configuration required.
- **Network Sharing**: Share your PC/laptop's internet connection with the Raspberry Pi.
- **Low Latency**: Sub 1ms ping for faster communication and data transfers.
- **Headless Operation**: Operate the Pi without a Wi-Fi network, wired ethernet, monitor, or keyboard.
- **Wide Compatibility**: Supports Raspberry Pi models A/A+, 3A+, 4B, 5B, Zero (W), and Zero 2 W.

## Subnetwork Configuration

- **IP Range**: 10.12.194.1 to 10.12.194.14
- **Usable IPs**: 14
- **Network Address**: 10.12.194.0
- **Broadcast Address**: 10.12.194.15
- **Subnet Mask**: 255.255.255.240 (_/28_)

(This configuration ensures minimal IP conflicts, even when multiple Raspberry Pi devices are connected to the same host.) \[Maybe, needs testing\]

## How It Works
This package sets up the Raspberry Pi to act as a USB Ethernet Gadget, creating a network interface over USB. The default IP address is `10.12.194.1`, but you can also access the device using its `hostname.local`.

## Installation

1. Download the `.deb` package from the [releases page](https://github.com/paulober/rpi-usb-ethernet-gadget/releases).
2. Install the package using:
   ```bash
   sudo dpkg -i rpi-usb-ethernet-gadget.deb
   ```
3. Reboot your Raspberry Pi.
   ```bash
   sudo reboot
   ```

## Usage

Simply plug your Raspberry Pi into your PC/laptop using a USB cable, and it will be recognized as an Ethernet device. 

> Important: Not all USB ports on your Raspberry Pi support USB OTG (which is required for this to work). On Pi 4 / 5 models, use the USB-C port, and on other models, use the USB port closest to the HDMI port.

You can then connect to it via SSH, transfer files, or use remote development tools like VS Code.

## Contributions

Contributions are welcome! Please submit a pull request or open an issue for feedback and improvements.
