local log = require "log"
local mdns = require "st.mdns"
local socket = require "cosock.socket"

local fields = require "fields"
local utils = require "utils"
local discovery_provider = require "discovery_provider"

local discovery = {}


local MDNS_DOMAIN = "local"
local MDNS_SERVICE_TYPE = "_http._tcp"

local function bridge_by_dni(driver, dni)
  for _, device in ipairs(driver:get_devices()) do
    if device.device_network_id == dni and utils.is_bridge(device) then
      return device
    end
  end

  return nil
end

local function byte_array_to_plain_text(byte_array)
  return string.char(table.unpack(byte_array))
end

local function text_list_for_found_item(found_item)
  local text_list = {}

  for _, raw_text in pairs(((found_item or {}).txt or {}).text or {}) do
    table.insert(text_list, byte_array_to_plain_text(raw_text))
  end

  return text_list
end

local function get_text_by_srvname(srvname, discovery_responses)
  for _, answer_item in pairs(discovery_responses.answers or {}) do
    if answer_item.kind.TxtRecord ~= nil and answer_item.name == srvname then
      return answer_item.kind.TxtRecord.text
    end
  end

  return nil
end

local function get_srvname_by_hostname(hostname, discovery_responses)
  for _, answer_item in pairs(discovery_responses.answers or {}) do
    if answer_item.kind.SrvRecord ~= nil and answer_item.kind.SrvRecord.target == hostname then
      return answer_item.name
    end
  end

  return nil
end

local function get_hostname_by_ip(ip, discovery_responses)
  for _, answer_item in pairs(discovery_responses.answers or {}) do
    if answer_item.kind.ARecord ~= nil and answer_item.kind.ARecord.ipv4 == ip then
      return answer_item.name
    end
  end

  return nil
end

local function find_text_in_answers_by_ip(ip, discovery_responses)
  local hostname = get_hostname_by_ip(ip, discovery_responses)
  local srvname = hostname and get_srvname_by_hostname(hostname, discovery_responses) or nil
  local answer_text = srvname and get_text_by_srvname(srvname, discovery_responses) or nil
  local text_list = {}

  for _, raw_text in pairs(answer_text or {}) do
    table.insert(text_list, byte_array_to_plain_text(raw_text))
  end

  return text_list
end

local function parse_txt_items(text_list)
  local parsed = {}

  for _, item in ipairs(text_list or {}) do
    local key, value = tostring(item):match("^([^=]+)=(.*)$")
    if key and value then
      parsed[key] = value
    end
  end

  return parsed
end


local function cache_bridge_metadata(driver, bridge_data)
  driver.datastore.pending_bridge_data = driver.datastore.pending_bridge_data or {}
  driver.datastore.pending_bridge_data[bridge_data.device_network_id] = bridge_data
end

local function set_bridge_identity_fields(device, bridge_data)
  if type(bridge_data) ~= "table" then
    return
  end

  device:set_field(fields.BRIDGE_HOST, bridge_data.host, { persist = true })
  device:set_field(fields.BRIDGE_PORT, bridge_data.port, { persist = true })
  device:set_field(fields.BRIDGE_SCHEME, bridge_data.scheme, { persist = true })
  device:set_field(fields.DISCOVERY_SOURCE, bridge_data.discovery_source, { persist = true })
  device:set_field(fields.PLATFORM, bridge_data.platform, { persist = true })
  device:set_field(fields.SERIAL_NUMBER, bridge_data.serial_number, { persist = true })
  device:set_field(fields.API_VERSION, bridge_data.api_version, { persist = true })
  device:set_field(fields.CONTROLLER_KIND, bridge_data.controller_kind, { persist = true })
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

local function create_or_update_mdns_bridge(driver, bridge_data)
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



function discovery.do_mdns_scan(driver)
  log.info_with({hub_logs = true}, "[Fibaro] Starting mDNS scan for Fibaro HC3 devices")
  
  local discovery_responses, err = mdns.discover(MDNS_SERVICE_TYPE, MDNS_DOMAIN)
  if err ~= nil then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] HC3 mDNS discovery failed: %s", tostring(err)))
    return
  end

  -- Log raw discovery responses for debugging
  local json = require "st.json"
  local raw_response_str = ""
  if discovery_responses then
    local ok, json_str = pcall(json.encode, discovery_responses)
    if ok then
      raw_response_str = json_str
    else
      raw_response_str = tostring(discovery_responses)
    end
  end
  log.info_with({hub_logs = true}, string.format("[Fibaro] Raw mDNS discovery responses: %s", raw_response_str))

  local found_count = #(discovery_responses or {}).found or 0
  log.info_with({hub_logs = true}, string.format("[Fibaro] mDNS scan found %d responses", found_count))

  -- Log ALL raw mDNS responses (including non-Fibaro)
  for i, found_item in ipairs((discovery_responses or {}).found or {}) do
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] Raw mDNS response #%d: service_type=%s, name=%s, host=%s, port=%s",
      i,
      tostring((found_item.service_info or {}).service_type),
      tostring((found_item.service_info or {}).name),
      tostring((found_item.host_info or {}).address),
      tostring((found_item.service_info or {}).port)
    ))
  end

  for _, found_item in ipairs((discovery_responses or {}).found or {}) do
    local candidate = discovery_provider.normalize_candidate(found_item, discovery_responses or {})
    if candidate ~= nil then
      log.info_with({hub_logs = true}, string.format(
        "[Fibaro] Discovered Fibaro HC3 via mDNS: serial=%s host=%s port=%s",
        tostring(candidate.serial_number),
        tostring(candidate.host),
        tostring(candidate.port)
      ))
      create_or_update_mdns_bridge(driver, candidate)
    end
  end
  
  log.info_with({hub_logs = true}, "[Fibaro] mDNS scan completed")
end

function discovery.discover(driver, _, should_continue)
  log.info_with({hub_logs = true}, "[Fibaro] ========================================")
  log.info_with({hub_logs = true}, "[Fibaro] Starting Fibaro Discovery Loop with Fallback")
  log.info_with({hub_logs = true}, "[Fibaro] ========================================")
  
  while should_continue() do
    local devices = discovery_provider.discover_with_fallback(driver, {
      hardcoded_ip = "192.168.0.126"  -- Can be made configurable via preferences
    })
    
    log.info_with({hub_logs = true}, string.format("[Fibaro] Processing %d discovered devices", #devices))
    
    for i, device in ipairs(devices) do
      log.info_with({hub_logs = true}, string.format(
        "[Fibaro] Creating/updating device #%d: dni=%s, host=%s, port=%d, source=%s",
        i,
        tostring(device.device_network_id),
        tostring(device.host),
        device.port,
        tostring(device.discovery_source)
      ))
      create_or_update_mdns_bridge(driver, device)
    end
    
    socket.sleep(1.0)
  end
  
  log.info_with({hub_logs = true}, "[Fibaro] Discovery loop ended")
end

return discovery
