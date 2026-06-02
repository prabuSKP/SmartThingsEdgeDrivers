---
name: mdns-analysis
description: >
  Analyze mDNS (Bonjour/Avahi) advertisements from LAN devices and 3rd-party hubs
  to build SmartThings Edge driver discovery handlers. Covers mDNS service type
  detection (_http._tcp, _hap._tcp, etc.), TXT record extraction for serial numbers
  and platform identification, search-parameters.yml configuration, and the
  dns_sd library usage within the Edge runtime. Use when building auto-discovery
  for hubs or devices that advertise via mDNS/DNS-SD.
---

# mDNS Analysis for Edge Driver Discovery

mDNS (Multicast DNS) / DNS-SD (DNS-based Service Discovery) is the primary auto-discovery
method for LAN devices on home networks. Devices broadcast their services on the local network,
and the SmartThings Hub can listen for these broadcasts to find devices automatically.

## How mDNS Discovery Works

```
3rd-Party Hub → broadcasts _http._tcp.local → SmartThings Hub listens
                                                      ↓
                                              Edge Driver receives service info
                                                      ↓
                                              Creates bridge device with
                                              host, port, serial from TXT records
```

## Step 1: Identify the mDNS Service Type

### Common Service Types

| Service Type | Used By |
|---|---|
| `_http._tcp` | Fibaro HC3, generic HTTP devices |
| `_hap._tcp` | HomeKit devices |
| `_home-assistant._tcp` | Home Assistant |
| `_hue._tcp` | Philips Hue bridges |
| `_sonos._tcp` | Sonos speakers |
| `_googlecast._tcp` | Google Chromecast |
| `_printer._tcp` | Network printers |

### Scanning for Services

On the SmartThings hub, use `dns_sd` from the Edge SDK:

```lua
local mdns = require "st.mdns"

-- Scan for services
local results = mdns.discover("_http._tcp", "local")
```

From your development machine (for analysis before coding):

```bash
# macOS
dns-sd -B _http._tcp local

# Linux (avahi)
avahi-browse -art

# Windows (Bonjour SDK)
dns-sd -B _http._tcp local.

# Python (for scripted scanning)
pip install zeroconf
python3 -c "
from zeroconf import Zeroconf, ServiceBrowser
import time

class Listener:
    def add_service(self, zc, type_, name):
        info = zc.get_service_info(type_, name)
        if info:
            print(f'Found: {name}')
            print(f'  Host: {info.server}')
            print(f'  Port: {info.port}')
            print(f'  TXT:  {info.properties}')

zc = Zeroconf()
ServiceBrowser(zc, '_http._tcp.local.', Listener())
time.sleep(10)
zc.close()
"
```

## Step 2: Analyze TXT Records

TXT records carry metadata about the device. Key fields to extract:

### Fibaro HC3 TXT Records (Example)

```
_http._tcp.local.
  Name: HC3-012345._http._tcp.local.
  Host: HC3-012345.local.
  Port: 443
  TXT:
    serialNumber=HC3-012345
    platform=HC3
    firmwareVersion=5.120.17
    manufacturer=Fibaro
```

### Fields to Extract

| TXT Field | Usage in Driver |
|---|---|
| `serialNumber` | Unique bridge identifier → `device_network_id` |
| `platform` | Controller family detection (HC2/HC3/Yubii) |
| `firmwareVersion` | API compatibility check |
| `manufacturer` | Vendor identification |

## Step 3: Build search-parameters.yml

```yaml
# search-parameters.yml
mdns:
  serviceType: _http._tcp
  domain: local
```

For SSDP-only devices:

```yaml
ssdp:
  filter: urn:schemas-upnp-org:device:Basic:1
```

## Step 4: Discovery Handler Implementation

```lua
-- discovery.lua
local mdns = require "st.mdns"
local log = require "log"

local discovery = {}

function discovery.discover(driver, opts, should_continue)
  log.info("[Discovery] Starting mDNS scan")

  while should_continue() do
    -- Option A: Leverage built-in mDNS from search-parameters
    -- (Hub automatically provides discovered services via opts)

    -- Option B: Manual mDNS scan (for custom service types)
    local found = mdns.discover("_http._tcp", "local")

    for _, service in ipairs(found or {}) do
      local serial = service.txt and service.txt.serialNumber
      if serial and is_target_device(service) then
        local dni = "fibaro-" .. serial
        if not driver:get_device_by_dni(dni) then
          create_bridge_device(driver, service, dni)
        end
      end
    end

    socket.sleep(5)
  end
end

local function is_target_device(service)
  local platform = service.txt and service.txt.platform or ""
  return platform:lower():find("hc") ~= nil
    or platform:lower():find("fibaro") ~= nil
end

local function create_bridge_device(driver, service, dni)
  -- Cache bridge identity for lifecycle handler
  driver.datastore.pending_bridge_data = driver.datastore.pending_bridge_data or {}
  driver.datastore.pending_bridge_data[dni] = {
    host = service.host,
    port = service.port,
    scheme = service.port == 443 and "https" or "http",
    serial = service.txt and service.txt.serialNumber or "",
    platform = service.txt and service.txt.platform or "",
  }

  local metadata = {
    type = "LAN",
    device_network_id = dni,
    label = "Fibaro " .. (service.txt and service.txt.platform or "Hub"),
    profile = "hc2-bridge",
    manufacturer = "Fibaro",
    model = service.txt and service.txt.platform or "HC",
    vendor_provided_label = dni,
  }

  local ok, err = driver:try_create_device(metadata)
  if ok then
    log.info("[Discovery] Created bridge: " .. dni)
  else
    log.error("[Discovery] Failed: " .. tostring(err))
  end
end

return discovery
```

## Step 5: Manual IP Fallback

For hubs that don't support mDNS, provide a manual entry via the bridge profile preferences:

```lua
-- In discovery handler, create a placeholder bridge for manual config
local function create_manual_bridge(driver)
  local metadata = {
    type = "LAN",
    device_network_id = "manual-hub-bridge",
    label = "My Hub (configure in settings)",
    profile = "hc2-bridge",
    manufacturer = "Manual",
    model = "Hub",
  }
  driver:try_create_device(metadata)
end
```

The user then enters the hub IP, port, and credentials in the SmartThings device settings.

> **Gate this — do not call it unconditionally.** The manual placeholder is a *fallback*.
> If you create it before/alongside the mDNS scan that also creates a bridge, the same hub
> shows up **twice** (one mDNS device + one manual device). Call `create_manual_bridge`
> only **after** the discovery loop and only when no bridge was found
> (`if not any_bridge_exists(driver) then ...`), and reconcile mDNS creates by
> DNI/serial/host. Full pattern: `discovery/hub-discovery` → "Single-Bridge Reconciliation".

## Step 6: Scheduled Re-Discovery

For hubs with dynamic IPs, schedule periodic mDNS re-scans:

```lua
-- In init.lua, after driver construction
local MDNS_SCAN_INTERVAL = 300  -- 5 minutes

driver:call_with_delay(3, discovery.do_mdns_scan, "Initial mDNS scan")
driver:call_on_schedule(MDNS_SCAN_INTERVAL, discovery.do_mdns_scan, "Periodic mDNS scan")
```

## Debugging mDNS Issues

1. **No services found**: Check hub and SmartThings hub are on the same VLAN/subnet
2. **Service found but wrong type**: Verify the service type string matches exactly
3. **TXT records missing**: Some hubs only provide TXT on the A/AAAA record, not the SRV
4. **Intermittent discovery**: mDNS is UDP-based; add retry logic
