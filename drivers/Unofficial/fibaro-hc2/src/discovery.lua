local log = require "log"
local mdns = require "st.mdns"
local net_utils = require "st.net_utils"
local socket = require "cosock.socket"

local fields = require "fields"
local utils = require "utils"

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

local function normalize_candidate(found_item, discovery_responses)
  if type(found_item) ~= "table" then
    return nil
  end

  if ((found_item.service_info or {}).service_type) ~= MDNS_SERVICE_TYPE then
    return nil
  end

  local ip = ((found_item.host_info or {}).address)
  if not net_utils.validate_ipv4_string(ip) then
    return nil
  end

  local txt_list = text_list_for_found_item(found_item)
  for _, item in ipairs(find_text_in_answers_by_ip(ip, discovery_responses)) do
    table.insert(txt_list, item)
  end

  local txt = parse_txt_items(txt_list)
  local serial_number = utils.trim(txt.serialNumber or txt.serialnumber or "")
  local platform = tostring(txt.platform or ""):upper()
  local api_version = utils.safe_tonumber(txt.apiVersion)
  local inferred_kind = utils.controller_kind_from_info({
    platform = platform,
    serialNumber = serial_number,
  })

  if inferred_kind ~= "hc3" then
    return nil
  end

  local port = utils.safe_tonumber((found_item.service_info or {}).port) or 80
  local label = serial_number ~= "" and ("Fibaro " .. serial_number) or "Fibaro HC3"

  return {
    api_version = api_version or 5,
    controller_kind = "hc3",
    device_network_id = serial_number ~= "" and ("fibaro-hc3:" .. serial_number) or ("fibaro-hc3:" .. ip:gsub("%.", "-")),
    discovery_source = "mdns",
    host = ip,
    label = label,
    platform = platform ~= "" and platform or "HC3",
    port = port,
    scheme = port == 443 and "https" or "http",
    serial_number = serial_number,
  }
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
  local discovery_responses, err = mdns.discover(MDNS_SERVICE_TYPE, MDNS_DOMAIN)
  if err ~= nil then
    log.warn(string.format("Fibaro HC3 mDNS discovery failed: %s", tostring(err)))
    return
  end

  for _, found_item in ipairs((discovery_responses or {}).found or {}) do
    local candidate = normalize_candidate(found_item, discovery_responses or {})
    if candidate ~= nil then
      log.info(string.format(
        "Discovered Fibaro HC3 via mDNS: serial=%s host=%s port=%s",
        tostring(candidate.serial_number),
        tostring(candidate.host),
        tostring(candidate.port)
      ))
      create_or_update_mdns_bridge(driver, candidate)
    end
  end
end

function discovery.discover(driver, _, should_continue)
  while should_continue() do
    discovery.do_mdns_scan(driver)
    socket.sleep(1.0)
  end
end

return discovery
