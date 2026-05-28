# Discovery Patterns for Edge Drivers

Load this when building or debugging device discovery.

## 1. mDNS Discovery

Devices that advertise via mDNS (Bonjour/Avahi) are discovered automatically by the hub.

### search-parameters.yml
```yaml
mdns:
  - service: _http._tcp
```

### Discovery handler

```lua
local discovery = require "discovery"  -- custom module

local function discovery_handler(driver, _, should_continue)
  local known_devices = {}
  local found_devices = {}

  -- Build set of already-known devices
  for _, device in ipairs(driver:get_devices()) do
    known_devices[device.device_network_id] = true
  end

  while should_continue() do
    discovery.find(nil, function(discovered)
      local id = discovered.network_id  -- or discovered.id (varies by protocol)
      local ip = discovered.ip

      if not known_devices[id] and not found_devices[id] then
        found_devices[id] = true

        local create_device_msg = {
          type = "LAN",
          device_network_id = id,
          label = discovered.name or "Unknown Device",
          profile = "my-profile",
          manufacturer = discovered.manufacturer or "Unknown",
          model = discovered.model or "unknown",
          vendor_provided_label = discovered.name,
        }
        log.info_with({ hub_logs = true },
          string.format("Creating device: %s at %s", discovered.name, ip))
        assert(driver:try_create_device(create_device_msg))
      end
    end)
  end
end
```

### discovered_info structure

The callback receives a table with fields that vary by implementation, but typically includes:

| Field | Description |
|---|---|
| `network_id` or `id` | Unique identifier |
| `name` | Human-readable name |
| `ip` | IP address |
| `port` | Port number |
| `manufacturer` | Manufacturer string |
| `model` | Model string |
| `serial_num` | Serial number (wemo-style) |

## 2. SSDP Discovery

UPnP-based discovery.

```yaml
# search-parameters.yml
ssdp:
  - searchTerm: urn:schemas-upnp-org:device:MediaRenderer:1
```

Multiple filters supported:
```yaml
ssdp:
  - searchTerm: urn:Belkin:device:*
```

Can combine mDNS and SSDP:
```yaml
mdns:
  - service: _http._tcp
ssdp:
  - searchTerm: urn:schemas-upnp-org:device:Basic:1
```

## 3. Manual IP Entry (Onboarding Flow)

When devices can't auto-discover (or you want it as a fallback), users can enter IP + credentials during pairing. The SmartThings app shows fields based on the driver's config. The entered values are available as `device.data` in the `added` lifecycle handler.

Example — Hub App pairing flow:
1. User selects "Add Device" → "By brand/device type"
2. Selects your driver
3. App shows fields (IP, port, username, password)
4. User enters values, taps Done
5. `added` handler fires with `device.data.ip_addr`, `device.data.port`, etc.

Store these in `added`/`init`:
```lua
local function device_added(driver, device)
  local dd = device.data or {}
  if dd.host_ip then
    device:set_field("host_ip", dd.host_ip, {persist = true})
  end
  if dd.port then
    device:set_field("port", tonumber(dd.port), {persist = true})
  end
  -- start listening / polling
end
```

**Important:** `device.data` is only set during `added`, not `init`. Always persist critical fields with `{persist = true}` for hub restart recovery.

## 4. DTH Migration — Carrying Over IP/Port

When migrating from Device Type Handlers (DTH):
```lua
if not device:get_field("host_ip") and device.data and device.data.ip then
  local nu = require "st.net_utils"
  local ip = nu.convert_ipv4_hex_to_dotted_decimal(device.data.ip)
  local port = device.data.port and tonumber(device.data.port, 16) or nil
  device:set_field("host_ip", ip, {persist = true})
  if port then device:set_field("port", port, {persist = true}) end
end
```

## 5. Init Re-Discovery Pattern

Official LAN drivers perform re-discovery on `init` because hub restarts lose network state:

```lua
local function device_init(driver, device)
  if device:get_field("init_started") then return end
  device:set_field("init_started", true)

  cosock.spawn(function()
    local backoff = backoff_builder(300, 1, 0.25)  -- see driver-framework.md
    local info

    while true do
      discovery.find(device_id, function(found) info = found end)
      if info then break end
      local tm = backoff()
      device.log.info_with({ hub_logs = true },
        string.format("Re-discovering device, retry in %.1fs", tm))
      socket.sleep(tm)
    end

    if not info or not info.ip then
      device.log.error_with({ hub_logs = true }, "Device not found on network")
      device:offline()
      return
    end

    device.log.info_with({ hub_logs = true }, "Device re-discovered on LAN")
    device:set_field("host_ip", info.ip, {persist = true})
    device:online()

    -- start periodic polling / event listening
  end, device.id .. "-init")
end
```

## 6. Full Pairing Flow (LAN Gateway)

```
App: Add Device
  → Hub broadcasts mDNS / SSDP (if configured in search-parameters.yml)
  → discovery_handler triggered
  → driver:try_create_device() called

App: User selects and adds the discovered gateway
  → lifecycle: added fires
     → Store config from device.data
     → Start discovery for child devices
  → lifecycle: init fires (if separate from added)
     → Re-establish connections, start polling

Driver polls gateway for child device states
  → Child devices update via emit_event()

Hub restart:
  → init fires for all previously-paired devices
  → Re-discover on LAN, restore state
```

## 7. IP Change Handling

Devices may change IP (DHCP). Two approaches used in official drivers:

### a) Periodic check via driver:call_on_schedule
```lua
local function ip_change_check(driver)
  for _, device in ipairs(driver:get_devices()) do
    discovery.find(device.device_network_id, function(found)
      if found and found.ip and found.ip ~= device:get_field("host_ip") then
        log.info_with({ hub_logs = true }, "IP changed for " .. device.label)
        device:set_field("host_ip", found.ip, {persist = true})
      end
    end)
  end
end

driver:call_on_schedule(600, ip_change_check, "IP Change Check")
```

### b) On-demand check during init
Re-discovery during `init` automatically updates the IP if changed.

## 8. Zigbee / Z-Wave Discovery

These use radio-level pairing — no search-parameters.yml needed.

```lua
-- Zigbee join handler
zigbee_join = function(driver, device) end

-- Z-Wave inclusion handler
zwave_inclusion = function(driver, device) end
```
