---
name: hub-discovery
description: >
  Complete hub discovery flow for SmartThings Edge drivers. Covers the full pipeline:
  mDNS/SSDP scan → device info extraction → bridge device creation → manual IP
  fallback → scheduled re-discovery → pending bridge data caching. Combines mDNS
  and SSDP sub-skills into a unified discovery handler. Use when building the
  discovery.lua module for a hub bridge driver.
---

# Hub Discovery — Complete Flow

This skill combines mDNS and SSDP discovery with manual IP fallback into a complete
hub discovery handler.

## Discovery Architecture

```
User taps "Scan for devices" in SmartThings app
  ↓
SmartThings Hub calls discovery.discover(driver, opts, should_continue)
  ↓
┌─────────────────────────────────────────────┐
│  Discovery Handler                           │
│                                              │
│  1. Check for existing bridges               │
│  2. Create manual bridge placeholder (HC2)   │
│  3. Run mDNS scan (HC3/modern hubs)          │
│  4. Run SSDP scan (UPnP devices)             │
│  5. Match against known device patterns      │
│  6. Create bridge devices for new finds       │
│                                              │
│  Loop while should_continue() returns true   │
└─────────────────────────────────────────────┘
```

## Complete Discovery Handler

```lua
-- discovery.lua
local cosock = require "cosock"
local socket = require "cosock.socket"
local log = require "log"
local fields = require "fields"
local utils = require "utils"

local discovery = {}

-- Manual bridge placeholder for hubs without auto-discovery (e.g., HC2)
local MANUAL_BRIDGE_DNI = "fibaro-manual-bridge"

function discovery.discover(driver, opts, should_continue)
  log.info_with({ hub_logs = true }, "[Discovery] Starting hub discovery")

  -- Create manual placeholder if no bridges exist yet
  local bridges = utils.get_bridge_devices(driver)
  if #bridges == 0 then
    discovery.create_manual_bridge(driver)
  end

  -- Discovery loop
  while should_continue() do
    -- mDNS scan for modern hubs
    local ok, err = pcall(discovery.do_mdns_scan, driver)
    if not ok then
      log.warn("[Discovery] mDNS scan error: " .. tostring(err))
    end

    socket.sleep(5)
  end

  log.info_with({ hub_logs = true }, "[Discovery] Discovery session ended")
end

-- Manual bridge for hubs that need manual IP entry
function discovery.create_manual_bridge(driver)
  log.info_with({ hub_logs = true }, "[Discovery] Creating manual bridge placeholder")

  -- Check if already exists
  local existing = driver:get_device_by_dni(MANUAL_BRIDGE_DNI)
  if existing then
    log.info("[Discovery] Manual bridge already exists, skipping")
    return
  end

  local metadata = {
    type = "LAN",
    device_network_id = MANUAL_BRIDGE_DNI,
    label = "Fibaro Hub (configure in settings)",
    profile = "hc2-bridge",
    manufacturer = "Fibaro",
    model = "HC2/HCL",
    vendor_provided_label = MANUAL_BRIDGE_DNI,
  }

  local ok, err = driver:try_create_device(metadata)
  if ok then
    log.info_with({ hub_logs = true },
      "[Discovery] Manual bridge created successfully")
  else
    log.error_with({ hub_logs = true },
      "[Discovery] Failed to create manual bridge: " .. tostring(err))
  end
end

-- mDNS scan for hubs that advertise via Bonjour
function discovery.do_mdns_scan(driver)
  log.info("[Discovery] Running mDNS scan for _http._tcp")

  -- Use the discovery_provider module for actual scanning
  local provider = require "discovery_provider"
  local services = provider.scan_mdns_services()

  for _, service in ipairs(services or {}) do
    if discovery.is_target_hub(service) then
      discovery.process_mdns_result(driver, service)
    end
  end
end

-- Check if a discovered service is a target hub
function discovery.is_target_hub(service)
  local txt = service.txt or {}
  local name = (service.name or ""):lower()
  local platform = (txt.platform or ""):lower()
  local manufacturer = (txt.manufacturer or ""):lower()

  -- Fibaro HC3 detection
  if name:find("hc3") or name:find("hc2")
    or platform:find("hc3") or platform:find("hc2")
    or manufacturer:find("fibaro") then
    return true
  end

  -- Home Assistant detection
  if name:find("home%-assistant") or name:find("homeassistant") then
    return true
  end

  return false
end

-- Process a confirmed mDNS discovery result
function discovery.process_mdns_result(driver, service)
  local txt = service.txt or {}
  local serial = txt.serialNumber or txt.serial_number or ""

  if serial == "" then
    log.warn("[Discovery] mDNS service has no serial number, generating from host")
    serial = (service.host or "unknown"):gsub("%.", "-")
  end

  local dni = "fibaro-" .. serial

  -- Check if bridge already exists
  local existing = driver:get_device_by_dni(dni)
  if existing then
    -- Update host/port if changed (IP may have changed via DHCP)
    existing:set_field(fields.BRIDGE_HOST, service.host, { persist = true })
    existing:set_field(fields.BRIDGE_PORT, service.port, { persist = true })
    existing:set_field(fields.BRIDGE_SCHEME,
      service.port == 443 and "https" or "http", { persist = true })
    log.info("[Discovery] Updated existing bridge: " .. dni)
    return
  end

  -- Cache pending bridge data for lifecycle handler
  driver.datastore.pending_bridge_data = driver.datastore.pending_bridge_data or {}
  driver.datastore.pending_bridge_data[dni] = {
    host = service.host,
    port = service.port,
    scheme = service.port == 443 and "https" or "http",
    serial = serial,
    platform = txt.platform or "",
  }

  -- Create bridge device
  local platform = txt.platform or "Hub"
  local metadata = {
    type = "LAN",
    device_network_id = dni,
    label = "Fibaro " .. platform,
    profile = "hc2-bridge",
    manufacturer = txt.manufacturer or "Fibaro",
    model = platform,
    vendor_provided_label = string.format(
      "fibaro|serial:%s|platform:%s|host:%s|port:%s",
      serial, platform, service.host, tostring(service.port)
    ),
  }

  local ok, err = driver:try_create_device(metadata)
  if ok then
    log.info_with({ hub_logs = true },
      "[Discovery] Created bridge from mDNS: " .. dni)
  else
    log.error_with({ hub_logs = true },
      "[Discovery] Failed to create bridge: " .. tostring(err))
  end
end

return discovery
```

## Applying Pending Bridge Data in Lifecycle

```lua
-- In lifecycle.lua, init handler:
function lifecycle.init(driver, device)
  if utils.is_bridge(device) then
    -- Apply pending bridge data from discovery
    local pending = driver.datastore.pending_bridge_data
      and driver.datastore.pending_bridge_data[device.device_network_id]

    if pending then
      device:set_field(fields.BRIDGE_HOST, pending.host, { persist = true })
      device:set_field(fields.BRIDGE_PORT, pending.port, { persist = true })
      device:set_field(fields.BRIDGE_SCHEME, pending.scheme, { persist = true })
      device:set_field(fields.SERIAL_NUMBER, pending.serial, { persist = true })
      device:set_field(fields.PLATFORM, pending.platform, { persist = true })
      driver.datastore.pending_bridge_data[device.device_network_id] = nil
    end

    -- Start polling
    local poll_interval = get_poll_interval(device)
    device.thread:call_on_schedule(poll_interval, function()
      pcall(sync.poll_bridge, driver, device)
    end, device.id .. "-poll")

    -- Trigger initial sync
    device.thread:call_with_delay(2, function()
      pcall(sync.sync_bridge_inventory, driver, device)
    end)
  end
end
```

## Hardcoded IP Fallback (Discovery Provider)

For environments where mDNS is unreliable:

```lua
-- discovery_provider.lua
local provider = {}

-- Hardcoded fallback IPs to check
local FALLBACK_HOSTS = {
  { host = "192.168.1.100", port = 80, scheme = "http" },
  { host = "192.168.1.101", port = 443, scheme = "https" },
}

function provider.scan_mdns_services()
  local results = {}

  -- Try mDNS first
  -- ... (mDNS scanning code)

  -- If no mDNS results, try hardcoded IPs
  if #results == 0 then
    for _, fallback in ipairs(FALLBACK_HOSTS) do
      local ok = try_connect(fallback.host, fallback.port)
      if ok then
        table.insert(results, {
          name = "manual",
          host = fallback.host,
          port = fallback.port,
          txt = {},
        })
      end
    end
  end

  return results
end

return provider
```

## Scheduled Re-Discovery

```lua
-- In init.lua
local MDNS_SCAN_INTERVAL = 300  -- 5 minutes

-- Initial scan after 3-second delay
driver:call_with_delay(3, discovery.do_mdns_scan,
  "Initial mDNS scan")

-- Recurring scans
driver:call_on_schedule(MDNS_SCAN_INTERVAL, discovery.do_mdns_scan,
  "Periodic mDNS scan")
```

## DTH Migration — Carrying Over IP/Port

When migrating devices from legacy Groovy Device Type Handlers (DTH) to an Edge driver,
the IP and port stored in `device.data` are hex-encoded. Use the SmartThings
`st.net_utils` module to convert them:

```lua
local net_utils = require "st.net_utils"

local function migrate_dth_network_data(device)
  -- Only run if persistent fields are not already set
  if not device:get_field("host_ip") and device.data and device.data.ip then
    local ip = net_utils.convert_ipv4_hex_to_dotted_decimal(device.data.ip)
    local port = device.data.port
      and tonumber(device.data.port, 16)
      or nil

    device:set_field("host_ip", ip, { persist = true })
    if port then
      device:set_field("port", port, { persist = true })
    end

    log.info_with({ hub_logs = true },
      string.format("[Migration] Converted DTH data: %s:%s", ip, tostring(port)))
  end
end
```

> **Note:** `device.data` is only populated during the `added` lifecycle event, not `init`.
> Always persist critical fields with `{persist = true}` so they survive hub reboots.

