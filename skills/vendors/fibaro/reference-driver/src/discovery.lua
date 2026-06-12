local log = require "log"
local socket = require "cosock.socket"

local fields = require "fields"
local utils = require "utils"
local discovery_provider = require "discovery_provider"

local discovery = {}

local function bridge_by_dni(driver, dni)
  for _, device in ipairs(driver:get_devices()) do
    if device.device_network_id == dni and utils.is_bridge(device) then
      return device
    end
  end

  return nil
end

local function has_existing_bridge(driver)
  for _, device in ipairs(driver:get_devices()) do
    if utils.is_bridge(device) then
      return true
    end
  end

  return false
end

-- Remove the manual-entry placeholder once the finder has actually discovered the HC3, so the
-- user is never left with an empty "Fibaro HC3" card next to the real one. Only deletes the
-- placeholder while it is UNCONFIGURED (no host / no username): a manual bridge the user has
-- already set up may be in active use and must never be deleted.
local function remove_unconfigured_manual_bridge(driver)
  local manual = bridge_by_dni(driver, discovery_provider.MANUAL_BRIDGE_DNI)
  if manual == nil then
    return
  end

  local prefs = manual.preferences or {}
  local host = utils.trim(tostring(prefs.host or ""))
  local username = utils.trim(tostring(prefs.username or ""))
  if host ~= "" or username ~= "" then
    return  -- user-configured; leave it alone
  end

  if type(driver.try_delete_device) == "function" then
    log.info_with({hub_logs = true},
      "[Fibaro] HC3 discovered by finder; removing the unconfigured manual-entry placeholder")
    driver:try_delete_device(manual.id)
  end
end

local function cache_bridge_metadata(driver, bridge_data)
  driver.datastore.pending_bridge_data = driver.datastore.pending_bridge_data or {}
  driver.datastore.pending_bridge_data[bridge_data.device_network_id] = bridge_data
end

-- Only persist values that actually carry information. The manual-entry bridge is
-- (re)discovered with empty host/serial placeholders on every scan; without this guard
-- a re-scan would wipe the host, serial, and controller identity that sync.lua learned
-- from the live hub, knocking a working bridge back offline.
local function set_field_if_present(device, key, value)
  if value == nil then
    return
  end
  if type(value) == "string" and utils.trim(value) == "" then
    return
  end
  device:set_field(key, value, { persist = true })
end

local function set_bridge_identity_fields(device, bridge_data)
  if type(bridge_data) ~= "table" then
    return
  end

  set_field_if_present(device, fields.BRIDGE_HOST, bridge_data.host)
  set_field_if_present(device, fields.BRIDGE_PORT, bridge_data.port)
  set_field_if_present(device, fields.BRIDGE_SCHEME, bridge_data.scheme)
  set_field_if_present(device, fields.DISCOVERY_SOURCE, bridge_data.discovery_source)
  set_field_if_present(device, fields.PLATFORM, bridge_data.platform)
  set_field_if_present(device, fields.SERIAL_NUMBER, bridge_data.serial_number)
  set_field_if_present(device, fields.API_VERSION, bridge_data.api_version)
  set_field_if_present(device, fields.CONTROLLER_KIND, bridge_data.controller_kind)
end

function discovery.apply_pending_bridge_metadata(driver, device)
  if not utils.is_bridge(device) then
    return
  end

  driver.datastore.pending_bridge_data = driver.datastore.pending_bridge_data or {}
  local pending = driver.datastore.pending_bridge_data[device.device_network_id]
  if pending ~= nil then
    set_bridge_identity_fields(device, pending)
    driver.datastore.pending_bridge_data[device.device_network_id] = nil
  end
end

local function create_or_update_bridge(driver, bridge_data)
  local existing = bridge_by_dni(driver, bridge_data.device_network_id)
  if existing ~= nil then
    set_bridge_identity_fields(existing, bridge_data)
    return
  end

  cache_bridge_metadata(driver, bridge_data)
  driver:try_create_device({
    type = "LAN",
    device_network_id = bridge_data.device_network_id,
    label = bridge_data.label,
    profile = "hc2-bridge",
    manufacturer = "Fibaro",
    model = bridge_data.platform or "HC3",
    vendor_provided_label = bridge_data.label,
  })
end

function discovery.discover(driver, _, should_continue)
  log.info_with({hub_logs = true}, "[Fibaro] ========================================")
  log.info_with({hub_logs = true}, "[Fibaro] Starting Fibaro find-server discovery")
  log.info_with({hub_logs = true}, "[Fibaro] ========================================")

  -- Loop-scoped flags. found_controller: did the finder ever locate the HC3 this scan?
  -- manual_created: have we already placed the fallback card this scan? Both keep the manual
  -- fallback to a single placeholder.
  local found_controller = false
  local manual_created = false

  while should_continue() do
    local devices = discovery_provider.discover_via_finder(driver)

    if #devices > 0 then
      found_controller = true
      for i, device in ipairs(devices) do
        log.info_with({hub_logs = true}, string.format(
          "[Fibaro] Creating/updating bridge #%d: dni=%s, host=%s, port=%d, source=%s",
          i,
          tostring(device.device_network_id),
          tostring(device.host),
          device.port,
          tostring(device.discovery_source)
        ))
        create_or_update_bridge(driver, device)
      end
      -- The HC3 is found: drop any unconfigured manual placeholder (created this scan after an
      -- early finder miss, or left over from a prior scan) so only the real card remains.
      remove_unconfigured_manual_bridge(driver)
      manual_created = false
    elseif not found_controller and not manual_created and not has_existing_bridge(driver) then
      -- Finder found nothing yet and no Fibaro bridge exists. Create the manual-entry card
      -- NOW, INSIDE the scan window (while should_continue() is true) -- a try_create_device
      -- issued after the window closes is not reliably honored by the platform, which is why
      -- the card never appeared before. The found_controller / manual_created guards keep it
      -- to a single placeholder and avoid duplicating an existing or just-found bridge.
      log.info_with({hub_logs = true}, "[Fibaro] Fibaro find server found no devices; creating manual-entry fallback bridge")
      create_or_update_bridge(driver, discovery_provider.build_manual_bridge())
      manual_created = true
    end

    socket.sleep(1.0)
  end

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Discovery loop ended (found_controller=%s, manual_created=%s)",
    tostring(found_controller), tostring(manual_created)))
end

return discovery
