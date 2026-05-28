---
name: packet-analysis
description: >
  Capture and analyze local network packets to debug or reverse-engineer SmartThings
  Edge driver communication. Covers monitoring SSDP/mDNS UDP broadcasts, sniffing
  TCP API requests, intercepting WebSocket frames, and using Wireshark or tcpdump. Use
  when: (1) reverse-engineering undocumented LAN device APIs, (2) diagnosing discovery
  failures, or (3) validating request/response byte sequences between the hub and a device.
---

# SmartThings Edge LAN Packet Analysis

This skill explains how to sniff, trace, and inspect local network packets between a SmartThings Hub and a 3rd-party local device or bridge. This is essential when reverse-engineering undocumented local APIs or troubleshooting SSDP, mDNS, and TCP connection issues.

---

## 1. Network Setup for Sniffing LAN Traffic

Because local switch traffic is typically routed only to the destination port, you cannot inspect traffic between the SmartThings Hub and a LAN device from your laptop without configuring your network:

### Capture Method A: Port Mirroring (Recommended)
If you have a managed network switch:
1. Connect the SmartThings Hub, the vendor device, and your development machine to the managed switch.
2. Mirror the switch port connected to the SmartThings Hub to the port connected to your development machine.
3. Open Wireshark on your development machine and capture on the local ethernet interface.

### Capture Method B: Wi-Fi Hotspot Bridge
If you don't have a managed switch:
1. Configure your development machine as a software Wi-Fi Access Point / Hotspot or a bridged Ethernet interface.
2. Connect the vendor device or the SmartThings Hub to this Hotspot.
3. Sniff the virtual or bridged interface (e.g. `wlan0` or `br0`) using Wireshark or tcpdump.

---

## 2. SSDP and mDNS Packet Inspection

Discovery protocols communicate via UDP multicast. You can capture these directly from your laptop without port mirroring, as long as you are on the same Wi-Fi/Ethernet subnet.

### A. SSDP (Simple Service Discovery Protocol)
SSDP uses UDP multicast address `239.255.255.250` on port `1900`.

#### Wireshark Display Filter:
```
ssdp || udp.port == 1900
```

#### Key SSDP Packets to Analyze:
1. **M-SEARCH Requests**: Sent by the SmartThings Hub to search for devices.
2. **SSDP NOTIFY**: Sent by devices to advertise their presence. Check the `USN`, `NT`, and `LOCATION` headers:
   ```http
   NOTIFY * HTTP/1.1
   HOST: 239.255.255.250:1900
   CACHE-CONTROL: max-age=1800
   LOCATION: http://192.168.1.50:80/description.xml
   NT: urn:schemas-upnp-org:device:Basic:1
   USN: uuid:my-device-unique-id::urn:schemas-upnp-org:device:Basic:1
   ```

---

### B. mDNS (Multicast DNS)
mDNS uses UDP multicast address `224.0.0.251` (IPv4) or `ff02::fb` (IPv6) on port `5353`.

#### Wireshark Display Filter:
```
mdns || udp.port == 5353
```

#### What to inspect:
- **PTR Query**: SmartThings looking for a service type (e.g. `_http._tcp.local`).
- **SRV & TXT Records**: The device responding with its hostname, port, and key/value metadata (e.g. model name, mac address, setup ID).

---

## 3. Sniffing and Decoding TCP/HTTP APIs

Once discovery is complete, the driver communicates via HTTP/TCP or WebSockets.

### Wireshark Display Filter:
```
ip.addr == <Hub_IP> && ip.addr == <Device_IP> && (tcp || http)
```

### Inspecting Request Headers and Payloads:
- **HTTP Methods**: Confirm if the driver is sending `GET`, `POST`, or `PUT` requests.
- **Content-Type**: Check if the headers specify `application/json`, `application/xml`, or `x-www-form-urlencoded`.
- **Keep-Alive**: Ensure connection headers (`Connection: keep-alive` vs `close`) behave as expected to prevent high socket churn.

### Extracting Payloads:
In Wireshark:
1. Right-click any packet in the TCP connection stream.
2. Select **Follow** -> **TCP Stream**.
3. This opens a window showing the complete ASCII conversation between the SmartThings Hub (red) and the vendor device (blue). Use this raw payload to build accurate parser structures in your `api.lua` or `mapper.lua`.
