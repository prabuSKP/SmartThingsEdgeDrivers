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

## Non-Negotiable Discovery Rules

1. **One hub = exactly one bridge device — and that bridge must be visible *during* the scan window.** A hub is reachable through several discovery sources (mDNS, fixed-IP/manual entry, a vendor find-service), but all of them must converge on a **single** bridge in the app. Create the manual/fixed-IP placeholder **up front, at the start of `discover()`** (idempotent, DNI-guarded), so the user always has a bridge to configure even when the hub never answers mDNS (many hubs — Fibaro HC2/HC3 included — do not advertise over mDNS). **"One hub = one bridge" comes from reconciliation, NOT from deferring the placeholder.** Do **not** move the placeholder to *after* the scan loop as a "fallback" — that hides the bridge for the entire scan window when mDNS is silent, which is the #1 reason a hub "never shows up." Singleness is guaranteed by rule #2 (reconcile by identity) plus removing the stale unconfigured stub once a real bridge is found. See "Single-Bridge Reconciliation" below — this is mandatory.
2. **Reconcile by hub identity, not by DNI alone.** Before `driver:try_create_device()`, look for an existing bridge by **DNI, serial, OR host** and update it in place if found. Two sources that resolve the same hub (e.g. mDNS serial vs. a manually entered IP) must update one device, not mint two DNIs.
3. Network scan results must be validated before `driver:try_create_device()`. Match on manufacturer, model, service name, TXT payload, serial, or fetched description/API identity.
4. Avoid `upnp:rootdevice` as the only SSDP filter for production generation. It wakes the driver for unrelated devices. If broad SSDP is unavoidable, treat it as a candidate source only and reject non-target devices before creating anything.
5. Cache discovered host/port/scheme/serial data before `try_create_device()`, then apply it during lifecycle init.
6. Emit hub-visible logs for discovery start, manual fallback creation, each accepted network candidate, each rejected broad candidate, and every create failure.
7. If automatic LAN discovery is part of the requested driver behavior, generate a real discovery provider using `st.mdns` or the selected LAN mechanism. Do not leave discovery as a placeholder loop that only sleeps.

## Discovery Architecture

```
User taps "Scan for devices" in SmartThings app
  ↓
SmartThings Hub calls discovery.discover(driver, opts, should_continue)
  ↓
┌─────────────────────────────────────────────┐
│  Discovery Handler (single-bridge)           │
│                                              │
│  UP FRONT (before the loop):                 │
│    If NO bridge exists at all → create the   │
│    manual / fixed-IP placeholder NOW so a    │
│    configurable bridge is visible during the │
│    scan (idempotent, DNI-guarded).           │
│                                              │
│  Loop while should_continue():               │
│    1. Run mDNS / SSDP scan                   │
│    2. Validate each candidate (serial/TXT)   │
│    3. Reconcile by DNI / serial / host →     │
│         update in place, else create ONE     │
│    4. If a usable bridge now exists:         │
│         remove stale manual placeholder, stop│
└─────────────────────────────────────────────┘
```

### Single-Bridge Reconciliation — why a hub shows up twice (and how this prevents it)

The most common discovery defect is a hub appearing as **two bridges** — "one from mDNS,
one for the fixed IP." It happens when the driver does both of these independently:

```
create_manual_bridge()        -- DNI "vendor-manual"      (the fixed-IP device)
do_mdns_scan() → create        -- DNI "vendor-<serial>"    (the discovered device)
```

Two different DNIs ⇒ two devices for one physical hub. The fix is **reconciliation, not
deferral**: create the manual placeholder up front so the user sees a bridge during the
scan, but make every creation path reconcile by **DNI/serial/host** so the mDNS result
*adopts/updates* the existing placeholder instead of minting a second device — and delete
the stale unconfigured stub once a real bridge is confirmed. The sources converge on one
device because they look each other up before creating, not because one of them is delayed.

> **Do not "fix" the duplicate by deferring the manual placeholder to after the scan
> loop.** That is the opposite over-correction: it removes the duplicate by removing the
> bridge entirely for the whole scan window, so on a hub that does not answer mDNS (HC2/HC3)
> the user taps "Scan" and *nothing appears*. Keep the placeholder up front; rely on
> `find_existing_bridge()` + `remove_stale_manual_placeholder()` for singleness.

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

-- A bridge we can talk to: any auto-discovered bridge, or the manual placeholder once
-- the user has entered a host. A bare, unconfigured placeholder does NOT count, so the
-- scan keeps looking for the real hub.
local function usable_bridge_exists(driver)
  for _, device in ipairs(driver:get_devices()) do
    if utils.is_bridge(device) then
      if device.device_network_id ~= MANUAL_BRIDGE_DNI then return true end
      local host = device:get_field(fields.BRIDGE_HOST)
        or (device.preferences and device.preferences.host)
      if host ~= nil and host ~= "" then return true end
    end
  end
  return false
end

local function any_bridge_exists(driver)
  for _, device in ipairs(driver:get_devices()) do
    if utils.is_bridge(device) then return true end
  end
  return false
end

-- Once a real hub is discovered, delete a leftover unconfigured manual placeholder so
-- the hub is represented by exactly one device.
local function remove_stale_manual_placeholder(driver)
  local manual = driver:get_device_by_dni(MANUAL_BRIDGE_DNI)
  if manual == nil then return end
  local host = manual:get_field(fields.BRIDGE_HOST)
    or (manual.preferences and manual.preferences.host)
  if host ~= nil and host ~= "" then return end   -- user configured it → keep
  if type(driver.try_delete_device) == "function" then
    log.info_with({ hub_logs = true },
      "[Discovery] Removing stale manual placeholder; real bridge discovered")
    driver:try_delete_device(manual.id)
  end
end

function discovery.discover(driver, opts, should_continue)
  log.info_with({ hub_logs = true }, "[Discovery] Starting hub discovery")

  -- 1. UP-FRONT placeholder. Create the manual/fixed-IP bridge NOW, before the scan
  --    loop, so the user always has a configurable bridge visible during the scan
  --    window — critical for hubs that do not answer mDNS (Fibaro HC2/HC3). This is
  --    idempotent (DNI-guarded), so a re-scan never adds a second one. Singleness is
  --    guaranteed by reconciliation (step 3) + stale-stub removal (step 4), NOT by
  --    deferring this call. Deferring it to after the loop hides the bridge for the
  --    whole scan and is the #1 cause of "the hub never shows up."
  if not any_bridge_exists(driver) then
    discovery.create_manual_bridge(driver)
  end

  -- 2. Auto-discovery. mDNS results RECONCILE against the placeholder (by DNI/serial/
  --    host) so they update it in place instead of creating a duplicate.
  while should_continue() do
    local ok, err = pcall(discovery.do_mdns_scan, driver)
    if not ok then
      log.warn_with({ hub_logs = true }, "[Discovery] mDNS scan error: " .. tostring(err))
    end

    -- 4. A real/configured bridge now exists → drop the unconfigured stub so the
    --    hub maps to exactly one device, then stop.
    if usable_bridge_exists(driver) then
      remove_stale_manual_placeholder(driver)
      break
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

-- If using broad SSDP/mDNS search terms, every result must pass this check
-- before `process_mdns_result` or any `try_create_device` call.
function discovery.validate_network_candidate(service)
  if not discovery.is_target_hub(service) then
    log.info(string.format(
      "[Discovery] Rejected non-target LAN candidate: name=%s host=%s port=%s",
      tostring(service.name), tostring(service.host), tostring(service.port)
    ))
    return false
  end

  return true
end

-- Match an existing bridge by DNI, serial, OR host. This is what prevents a second
-- device: a manually configured bridge (different DNI) is found by its host and updated
-- in place instead of being duplicated by the mDNS path.
local function find_existing_bridge(driver, dni, serial, host)
  for _, device in ipairs(driver:get_devices()) do
    if utils.is_bridge(device) then
      if device.device_network_id == dni then return device end
      if serial and serial ~= "" and device:get_field(fields.SERIAL_NUMBER) == serial then
        return device
      end
      if host and host ~= "" then
        local dev_host = device:get_field(fields.BRIDGE_HOST)
          or (device.preferences and device.preferences.host)
        if dev_host == host then return device end
      end
    end
  end
  return nil
end

-- Process a confirmed mDNS discovery result
function discovery.process_mdns_result(driver, service)
  if not discovery.validate_network_candidate(service) then
    return
  end

  local txt = service.txt or {}
  local serial = txt.serialNumber or txt.serial_number or ""

  if serial == "" then
    log.warn("[Discovery] mDNS service has no serial number, generating from host")
    serial = (service.host or "unknown"):gsub("%.", "-")
  end

  local dni = "fibaro-" .. serial

  -- Reconcile against ALL bridges by DNI, serial, OR host so a re-scan or a
  -- user-configured manual placeholder is updated in place (never duplicated).
  local existing = find_existing_bridge(driver, dni, serial, service.host)
  if existing then
    existing:set_field(fields.SERIAL_NUMBER, serial, { persist = true })
    existing:set_field(fields.BRIDGE_HOST, service.host, { persist = true })
    existing:set_field(fields.BRIDGE_PORT, service.port, { persist = true })
    existing:set_field(fields.BRIDGE_SCHEME,
      service.port == 443 and "https" or "http", { persist = true })
    log.info("[Discovery] Updated existing bridge: " .. existing.device_network_id)
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

## Discovery Provider (mDNS) — correct `st.mdns` API

The discovery handler above calls `provider.scan_mdns_services()`. Generate it as a **real**
provider using the actual `st.mdns` API. The function is **`mdns.discover(service_type, domain)`**
— there is **no `mdns.resolve`** (a frequent hallucination; it does not exist and the driver
will error at scan time). `mdns.discover` returns a table whose `.found` array holds entries
shaped `{ host_info = { address, port }, service_info = { name, service_type, domain }, txt = { text = { "k=v", ... } } }`.
Normalize each entry into the flat `{ name, host, port, txt }` shape the handler consumes:

```lua
-- discovery_provider.lua
local log = require "log"

local provider = {}

local SERVICE_TYPE = "_http._tcp"   -- from search-parameters.yml / mdns-analysis
local DOMAIN       = "local"

-- mDNS TXT records arrive as an array of "key=value" strings; flatten to a table.
local function parse_txt(entry)
  local txt = {}
  local raw = entry.txt and entry.txt.text
  if type(raw) == "table" then
    for _, kv in ipairs(raw) do
      local k, v = tostring(kv):match("^([^=]+)=(.*)$")
      if k then txt[k] = v end
    end
  end
  return txt
end

-- Scan for hubs via mDNS. Returns an array of { name, host, port, txt } tables.
-- Returns an empty table on any failure — non-fatal, because the up-front manual
-- placeholder already gives the user a bridge to configure by IP.
function provider.scan_mdns_services()
  local results = {}

  local ok, mdns = pcall(require, "st.mdns")
  if not ok then
    log.warn("[Discovery] st.mdns not available on this hub runtime")
    return results
  end

  -- CORRECT API: mdns.discover(service_type, domain). NOT mdns.resolve(...).
  local ok_scan, answer = pcall(mdns.discover, SERVICE_TYPE, DOMAIN)
  if not ok_scan or type(answer) ~= "table" or type(answer.found) ~= "table" then
    log.info("[Discovery] mDNS discover returned no services")
    return results
  end

  for _, entry in ipairs(answer.found) do
    local host_info = entry.host_info or {}
    table.insert(results, {
      name = entry.service_info and entry.service_info.name or "",
      host = host_info.address,
      port = host_info.port or 80,
      txt  = parse_txt(entry),
    })
  end

  return results
end

return provider
```

> Target-hub filtering (manufacturer/platform/serial) is done by `discovery.is_target_hub`
> in the handler, so the provider returns all candidates and stays vendor-agnostic.

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

## `search-parameters.yml` Guidance

Use the narrowest discovery filters available for the target hub. For Fibaro HC3-style discovery, prefer mDNS service types confirmed by packet capture or mock-server behavior. Avoid generating this as the only discovery filter:

```yaml
ssdp:
  - searchTerm: upnp:rootdevice
```

That term matches many unrelated LAN devices. If it is included for exploration, the Lua discovery handler must validate each result by fetching/parsing the candidate identity before creating a bridge.

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
