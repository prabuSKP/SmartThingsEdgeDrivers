---
name: ssdp-analysis
description: >
  Analyze SSDP/UPnP advertisements for SmartThings Edge driver discovery. Covers
  SSDP M-SEARCH requests, device description XML parsing, search-parameters.yml
  configuration for SSDP filters, and the UPnP discovery handler pattern. Use when
  building auto-discovery for devices that use UPnP/SSDP (Wemo, Sonos, etc.).
---

# SSDP Analysis for Edge Driver Discovery

SSDP (Simple Service Discovery Protocol) is the UPnP discovery mechanism.
Some devices (Wemo, Sonos, many media devices) use SSDP instead of or alongside mDNS.

## How SSDP Discovery Works

```
SmartThings Hub → M-SEARCH multicast (239.255.255.250:1900) → LAN
                                                                ↓
Device → SSDP Response → Hub receives device URL
                                    ↓
Hub → GET device description XML → Extracts model, serial, capabilities
```

## Step 1: Identify the SSDP Search Target

| Search Target (ST) | Used By |
|---|---|
| `urn:schemas-upnp-org:device:Basic:1` | Generic UPnP devices |
| `urn:Belkin:device:*` | Wemo devices |
| `urn:schemas-upnp-org:device:MediaRenderer:1` | Media renderers |
| `urn:schemas-upnp-org:device:ZonePlayer:1` | Sonos speakers |
| `ssdp:all` | All UPnP devices (broad) |

### Scanning for SSDP Devices

```bash
# Using gssdp-discover (Linux)
gssdp-discover --timeout=5

# Using Python
python3 -c "
import socket, struct

msg = b'M-SEARCH * HTTP/1.1\r\n' \
      b'HOST: 239.255.255.250:1900\r\n' \
      b'MAN: \"ssdp:discover\"\r\n' \
      b'MX: 3\r\n' \
      b'ST: ssdp:all\r\n' \
      b'\r\n'

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
s.settimeout(5)
s.sendto(msg, ('239.255.255.250', 1900))

while True:
    try:
        data, addr = s.recvfrom(4096)
        print(f'From {addr}:')
        print(data.decode())
        print('---')
    except socket.timeout:
        break
"
```

## Step 2: Build search-parameters.yml

```yaml
# search-parameters.yml (SSDP only)
ssdp:
  filter: urn:schemas-upnp-org:device:Basic:1

# Combined mDNS + SSDP
mdns:
  serviceType: _http._tcp
  domain: local
ssdp:
  filter: urn:schemas-upnp-org:device:Basic:1
```

## Step 3: Parse Device Description XML

SSDP responses include a `LOCATION` header pointing to an XML description:

```xml
<!-- http://192.168.1.100:49152/setup.xml -->
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
    <friendlyName>My Smart Device</friendlyName>
    <manufacturer>Vendor</manufacturer>
    <modelName>Model X</modelName>
    <serialNumber>ABC123</serialNumber>
    <UDN>uuid:abcd-1234-5678</UDN>
  </device>
</root>
```

Parsing in the Edge driver:

```lua
local xml2lua = require "xml2lua"
local handler = require "xmlhandler.tree"

local function parse_device_description(xml_body)
  local parser = xml2lua.parser(handler:new())
  parser:parse(xml_body)

  local device = handler.root.root.device
  return {
    friendly_name = device.friendlyName,
    manufacturer = device.manufacturer,
    model = device.modelName,
    serial = device.serialNumber,
    udn = device.UDN,
  }
end
```

## Step 4: SSDP Discovery Handler

```lua
-- discovery.lua
local cosock = require "cosock"
local socket = require "cosock.socket"

local SSDP_MULTICAST_IP = "239.255.255.250"
local SSDP_PORT = 1900

local function ssdp_search(search_target, timeout)
  local msg = string.format(
    "M-SEARCH * HTTP/1.1\r\n" ..
    "HOST: %s:%d\r\n" ..
    "MAN: \"ssdp:discover\"\r\n" ..
    "MX: %d\r\n" ..
    "ST: %s\r\n" ..
    "\r\n",
    SSDP_MULTICAST_IP, SSDP_PORT, timeout, search_target
  )

  local sock = socket.udp()
  sock:settimeout(timeout + 1)
  sock:sendto(msg, SSDP_MULTICAST_IP, SSDP_PORT)

  local responses = {}
  while true do
    local data, ip, port = sock:receivefrom()
    if data == nil then break end
    table.insert(responses, { data = data, ip = ip, port = port })
  end

  sock:close()
  return responses
end
```

## Key Differences: mDNS vs SSDP

| Feature | mDNS | SSDP |
|---|---|---|
| Protocol | UDP multicast (5353) | UDP multicast (1900) |
| Response | Service records (SRV, TXT) | HTTP-like text headers |
| Metadata | TXT records (key=value) | XML description document |
| Follow-up | Direct connection | Fetch XML from LOCATION URL |
| Used by | Fibaro HC3, Home Assistant, Hue | Wemo, Sonos, generic UPnP |
| Edge SDK | `st.mdns` library | Raw UDP socket |
