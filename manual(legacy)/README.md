# The manual version

In the manual version systemd-networkd is currently
unable to auto-configure the network for usb1 or to 
put ECM and RNDIS on the same usb interface.
Therefore it currently only supports the RNDIS interface (Windows).

It would be possible to do manuall configuration of usb1 after enabling the ECM interface.

```bash
# Assign the IP address
sudo ip addr add 10.9.37.1/28 dev usb1

# Bring the interface up
sudo ip link set usb1 up
```

> Note: This doesn't engage any DHCP server on the USB interface.

# NetworkManager support

NetworkManager is a system network service that manages your network devices and connections, attempting to keep active network connectivity when available. It manages Ethernet, WiFi, mobile broadband (WWAN), and PPPoE devices, and provides VPN integration with a variety of different VPN services.

NetworkManager is now the default on Raspberry Pi OS. 
The `usb0.nmconnection` file provided is currently only a test file and may not work as expected.
