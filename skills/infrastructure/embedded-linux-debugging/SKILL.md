---
name: embedded-linux-debugging
description: >
  Debug network routing, multicast (SSDP/mDNS), and local subnet issues between the hub
  and LAN devices. Covers diagnosing subnet mismatches, troubleshooting IGMP snooping/multicast
  blocking in routers, and verifying open TCP ports. Use when: (1) discovery protocols
  fail to find devices, (2) the hub cannot connect to a local device's open ports, or
  (3) analyzing router configuration issues that block driver communication.
---

# Embedded Linux Hub & Network Debugging

The SmartThings Hub runs a custom embedded Linux environment. When developing LAN/HTTP Edge drivers, network routing and firewall settings on your router or vendor devices can block communication.

This skill covers how to diagnose network routing, multicast discovery, and firewall issues.

---

## 1. Subnet Mismatches

SmartThings Hubs communicate only with devices residing on the **same local subnet**.

### Diagnosis
Verify the IPv4 addresses of both the SmartThings Hub and the target vendor device:
- **Subnet Mask**: `255.255.255.0` (/24)
- **Hub IP**: `192.168.1.10`
- **Device IP**: `192.168.1.50` (Matches subnet: OK)
- **Alternative Device IP**: `192.168.2.50` (Different subnet: **Failed**)

### Rules
- **No double NATs**: If the hub is plugged into the primary modem/router and the device is connected to a secondary router acting as a DHCP server, they cannot communicate directly.
- *Fix*: Configure the secondary router in **Bridge/Access Point Mode** to combine the networks into a single subnet.

---

## 2. Multicast Filtering & IGMP Snooping

SSDP (Simple Service Discovery Protocol) and mDNS (multicast DNS) rely on network UDP multicast. Many consumer routers filter out multicast packets to save Wi-Fi bandwidth.

### Common Router Settings to Check:
- **Multicast Filtering / Wireless Isolation**: If enabled, this prevents Wi-Fi devices from receiving multicast packets sent by wired devices (like the hub).
  - *Fix*: Disable "AP Isolation", "Wireless Isolation", or "Multicast Filter" in the router configuration.
- **IGMP Snooping**: This optimizes multicast delivery by forwarding packets only to ports that explicitly request them. If the router's IGMP querier is disabled, the switch will drop multicast discovery packets.
  - *Fix*: Enable "IGMP Snooping" and ensure "IGMP Querier" is active on the router, or disable IGMP snooping if it continues to block packets.

---

## 3. Local Firewalls and Port Scanning

If the SmartThings Hub cannot connect to your vendor device or your developer callback server:

### A. Port Verification from Developer Laptop
Verify if the target device is listening on the expected port by running a connection test from your machine:
```bash
# Check if port 80 is open on the device
curl -I http://192.168.1.50:80/
```
Or use a port checker utility.

### B. Developer Machine Firewall Rules
If your Edge driver connects to a callback server running on your laptop (e.g. for Hubitat event callbacks or test suites):
- Windows Firewall or macOS Application Firewall will block incoming connections from the hub's IP.
- *Fix*: Add an inbound firewall rule allowing traffic on your callback port (e.g., port `8080`) specifically from the local network subnet.

---

## 4. IP Lease Times & Static IPs

By default, routers assign IP addresses dynamically. If a vendor hub's IP changes, your Edge driver will lose connection and fail.
- **Always recommend Static DHCP leases**: Advise users to assign a static IP address to the vendor hub or device in their router's DHCP reservation list.
- **Manual IP Fallback**: Implement a setting in your driver's preferences (as documented in `smartthings-hub-discovery`) allowing the user to type in the IP address manually if dynamic discovery fails.
