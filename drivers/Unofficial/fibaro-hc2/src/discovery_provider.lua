local log = require "log"
local mdns = require "st.mdns"
local json = require "st.json"
local socket = require "cosock.socket"
local http = require "socket.http"
local ltn12 = require "ltn12"
local net_utils = require "st.net_utils"

local utils = require "utils"

local discovery_provider = {}

-- Constants
local MDNS_DOMAIN = "local"
local MDNS_SERVICE_TYPE = "_http._tcp"
local FIND_FIBARO_URL = "http://find.fibaro.com/api/find/devices"
local FIND_FIBARO_TIMEOUT = 10
local DEFAULT_HARDCODED_IP = "192.168.0.126"
local DEFAULT_PORT = 80

-- Ping hosts
local PING_HOSTS = {
  "192.168.0.126",
  "192.168.0.123",
  "hc3-00033787.local"
}

-- ============================================
-- Enhanced normalize_candidate function with IPv6 support
-- ============================================

local function normalize_candidate(found_item, discovery_responses)
  if type(found_item) ~= "table" then
    log.info_with({hub_logs = true}, "[Fibaro] normalize_candidate: found_item is not a table")
    return nil
  end

  -- Log raw mDNS response data as JSON for debugging
  local json = require "st.json"
  local raw_item_str = ""
  local ok, json_str = pcall(json.encode, found_item)
  if ok then
    raw_item_str = json_str
  else
    raw_item_str = tostring(found_item)
  end
  log.info_with({hub_logs = true}, string.format("[Fibaro] Raw mDNS found_item: %s", raw_item_str))

  -- Log raw mDNS response data
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] mDNS Response: service_type=%s, name=%s",
    tostring((found_item.service_info or {}).service_type),
    tostring((found_item.service_info or {}).name)
  ))
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] mDNS Response: host_info=%s, port=%s",
    tostring((found_item.host_info or {}).address),
    tostring((found_item.service_info or {}).port)
  ))
  
  -- Log the entire found_item structure for debugging
  log.info_with({hub_logs = true}, string.format("[Fibaro] Found item service_info structure: %s", tostring(found_item.service_info)))
  
  -- Log detailed port information
  local service_info = found_item.service_info or {}
  log.info_with({hub_logs = true}, string.format("[Fibaro] Service info port field: %s (type: %s)", tostring(service_info.port), type(service_info.port)))
  
  -- Log all keys in service_info
  local service_keys = {}
  for k, v in pairs(service_info) do
    table.insert(service_keys, tostring(k))
  end
  log.info_with({hub_logs = true}, string.format("[Fibaro] Service info keys: %s", table.concat(service_keys, ", ")))

  if ((found_item.service_info or {}).service_type) ~= MDNS_SERVICE_TYPE then
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] normalize_candidate: service_type mismatch, expected %s, got %s",
      MDNS_SERVICE_TYPE,
      tostring((found_item.service_info or {}).service_type)
    ))
    return nil
  end

  local ip = ((found_item.host_info or {}).address)
  local ip_type = "unknown"
  
  -- Validate IP address - only process IPv4 addresses to avoid runtime errors
  if net_utils.validate_ipv4_string(ip) then
    ip_type = "IPv4"
  else
    -- Check if it's an IPv6 address and skip it gracefully
    if ip and (ip:match(":") or ip:match("^fe80::") or ip:match("^fdab:")) then
      log.info_with({hub_logs = true}, string.format("[Fibaro] normalize_candidate: skipping IPv6 address: %s", tostring(ip)))
      return nil
    else
      log.info_with({hub_logs = true}, string.format("[Fibaro] normalize_candidate: invalid IP address: %s", tostring(ip)))
      return nil
    end
  end

  log.info_with({hub_logs = true}, string.format("[Fibaro] normalize_candidate: processing mDNS response from %s address: %s", ip_type, ip))

  local txt_list = {}
  -- Try to get TXT records from the found_item first
  if found_item.txt and found_item.txt.text then
    for _, raw_text in pairs(found_item.txt.text or {}) do
      if type(raw_text) == "table" and raw_text[1] then
        -- Handle array format
        table.insert(txt_list, string.char(table.unpack(raw_text)))
      elseif type(raw_text) == "string" then
        -- Handle string format
        table.insert(txt_list, raw_text)
      end
    end
  end

  -- Log TXT records
  log.info_with({hub_logs = true}, string.format("[Fibaro] mDNS TXT records: %s", table.concat(txt_list, ", ")))

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

  local txt = parse_txt_items(txt_list)
  local serial_number = utils.trim(txt.serialNumber or txt.serialnumber or "")
  local platform = tostring(txt.platform or ""):upper()
  local api_version = utils.safe_tonumber(txt.apiVersion)
  
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] normalize_candidate: serial=%s, platform=%s, api_version=%s",
    serial_number, platform, tostring(api_version)
  ))
  
  local inferred_kind = utils.controller_kind_from_info({
    platform = platform,
    serialNumber = serial_number,
  })

  if inferred_kind ~= "hc3" then
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] normalize_candidate: inferred_kind=%s, not hc3, skipping",
      tostring(inferred_kind)
    ))
    return nil
  end

  -- Extract port from host_info first, then service_info, then default to 80
  local port = utils.safe_tonumber((found_item.host_info or {}).port) or 
               utils.safe_tonumber((found_item.service_info or {}).port) or 80
  local label = serial_number ~= "" and ("Fibaro " .. serial_number) or "Fibaro HC3"

  -- Generate DNI - handle IPv6 addresses by replacing colons with hyphens
  local dni_suffix = serial_number ~= "" and serial_number or (ip:gsub(":", "-"):gsub("%.", "-"))
  local device_network_id = "fibaro-hc3:" .. dni_suffix

  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] normalize_candidate: valid HC3 candidate found: serial=%s, host=%s, port=%d, type=%s, dni=%s",
    serial_number, ip, port, ip_type, device_network_id
  ))

  return {
    api_version = api_version or 5,
    controller_kind = "hc3",
    device_network_id = device_network_id,
    discovery_source = "mdns",
    host = ip,
    label = label,
    platform = platform ~= "" and platform or "HC3",
    port = port,
    scheme = port == 443 and "https" or "http",
    serial_number = serial_number,
  }
end

-- Make the function public so it can be accessed from other modules
discovery_provider.normalize_candidate = normalize_candidate

-- Discovery method enum
discovery_provider.METHOD = {
  MDNS = "mdns",
  FIND_FIBARO = "find_fibaro",
  HARDCODED = "hardcoded"
}

-- ============================================
-- Helper Functions
-- ============================================

local function safe_tonumber(value)
  if value == nil then return nil end
  if type(value) == "number" then return value end
  if type(value) == "string" and value ~= "" then
    return tonumber(value)
  end
  return nil
end

local function extract_port(device_info)
  -- Try multiple possible port field names
  local port = safe_tonumber(device_info.port)
  if port then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Port found in response: %d", port))
    return port
  end
  
  port = safe_tonumber(device_info.localPort)
  if port then
    log.info_with({hub_logs = true}, string.format("[Fibaro] localPort found in response: %d", port))
    return port
  end
  
  -- Default to 80 if no port specified
  log.info_with({hub_logs = true}, string.format("[Fibaro] No port in response, using default: %d", DEFAULT_PORT))
  return DEFAULT_PORT
end

-- ============================================
-- TIER 1: mDNS Discovery
-- ============================================

function discovery_provider.discover_via_mdns(driver)
  log.info_with({hub_logs = true}, "[Fibaro] ========== TIER 1: Starting mDNS Discovery ==========")
  
  local discovery_responses, err = mdns.discover(MDNS_SERVICE_TYPE, MDNS_DOMAIN)
  if err ~= nil then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] mDNS discovery failed with error: %s", tostring(err)))
    return {}, err
  end
  
  -- Log raw discovery responses for debugging
  local raw_response_str = ""
  if discovery_responses then
    local json = require "st.json"
    local ok, json_str = pcall(json.encode, discovery_responses)
    if ok then
      raw_response_str = json_str
    else
      raw_response_str = tostring(discovery_responses)
    end
  end
  log.info_with({hub_logs = true}, string.format("[Fibaro] Raw mDNS discovery responses: %s", raw_response_str))
  
  local found_count = #(discovery_responses or {}).found or 0
  log.info_with({hub_logs = true}, string.format("[Fibaro] mDNS returned %d responses", found_count))
  
  local devices = {}
  for _, found_item in ipairs((discovery_responses or {}).found or {}) do
    local candidate = normalize_candidate(found_item, discovery_responses)
    if candidate ~= nil then
      candidate.discovery_source = discovery_provider.METHOD.MDNS
      table.insert(devices, candidate)
      log.info_with({hub_logs = true}, string.format(
        "[Fibaro] mDNS candidate added: host=%s, port=%d, serial=%s, platform=%s",
        tostring(candidate.host),
        candidate.port,
        tostring(candidate.serial_number),
        tostring(candidate.platform)
      ))
    end
  end
  
  log.info_with({hub_logs = true}, string.format("[Fibaro] mDNS discovery complete: %d valid devices found", #devices))
  return devices, nil
end

-- ============================================
-- TIER 2: find.fibaro.com Discovery
-- ============================================

function discovery_provider.discover_via_find_fibaro(driver)
  log.info_with({hub_logs = true}, "[Fibaro] ========== TIER 2: Starting find.fibaro.com Discovery ==========")
  log.info_with({hub_logs = true}, string.format("[Fibaro] Requesting: %s", FIND_FIBARO_URL))
  
  -- HTTP GET request to find.fibaro.com
  local response_body = {}
  local start_time = socket.gettime()
  
  local res, code = http.request({
    url = FIND_FIBARO_URL,
    method = "GET",
    sink = ltn12.sink.table(response_body),
    timeout = FIND_FIBARO_TIMEOUT
  })
  
  local elapsed_time = socket.gettime() - start_time
  log.info_with({hub_logs = true}, string.format("[Fibaro] find.fibaro.com response: status=%s, elapsed=%.2fs", tostring(code), elapsed_time))
  
  if code ~= 200 then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] find.fibaro.com request failed with status: %s", tostring(code)))
    return {}, "API request failed with status: " .. tostring(code)
  end
  
  -- Parse JSON response
  local body = table.concat(response_body)
  log.info_with({hub_logs = true}, string.format("[Fibaro] find.fibaro.com response body (first 500 chars): %s", body:sub(1, 500)))
  
  local ok, devices_data = pcall(json.decode, body)
  if not ok then
    log.warn_with({hub_logs = true}, string.format("[Fibaro] Failed to parse find.fibaro.com JSON response: %s", tostring(devices_data)))
    return {}, "JSON parse failed"
  end
  
  if type(devices_data) ~= "table" then
    log.warn_with({hub_logs = true}, "[Fibaro] find.fibaro.com response is not a valid array")
    return {}, "Invalid response format"
  end
  
  log.info_with({hub_logs = true}, string.format("[Fibaro] find.fibaro.com returned %d device entries", #devices_data))
  
  -- Build device list from response
  local devices = {}
  for i, device_info in ipairs(devices_data) do
    log.info_with({hub_logs = true}, string.format("[Fibaro] Processing device entry #%d: %s", i, tostring(device_info)))
    
    local ip = device_info.localAddress or device_info.ipAddress or device_info.ip
    if ip then
      local port = extract_port(device_info)
      local serial = device_info.serialNumber or device_info.serial or ""
      local platform = device_info.gatewayType or device_info.platform or "HC3"
      
      log.info_with({hub_logs = true}, string.format(
        "[Fibaro] Device entry parsed: ip=%s, port=%d, serial=%s, platform=%s",
        tostring(ip), port, tostring(serial), tostring(platform)
      ))
      
      local device = {
        host = ip,
        port = port,
        scheme = port == 443 and "https" or "http",
        serial_number = serial,
        platform = platform,
        discovery_source = discovery_provider.METHOD.FIND_FIBARO,
        controller_kind = "hc3",
        device_network_id = "fibaro-hc3:" .. (serial ~= "" and serial or ip:gsub("%.", "-")),
        label = "Fibaro HC3",
        api_version = 5
      }
      table.insert(devices, device)
    else
      log.warn_with({hub_logs = true}, string.format("[Fibaro] Device entry #%d has no IP address, skipping", i))
    end
  end
  
  log.info_with({hub_logs = true}, string.format("[Fibaro] find.fibaro.com discovery complete: %d valid devices found", #devices))
  return devices, nil
end

-- ============================================
-- TIER 3: Hardcoded IP Fallback
-- ============================================

function discovery_provider.discover_via_hardcoded(driver, ip)
  ip = ip or DEFAULT_HARDCODED_IP
  log.info_with({hub_logs = true}, "[Fibaro] ========== TIER 3: Starting Hardcoded IP Fallback ==========")
  log.info_with({hub_logs = true}, string.format("[Fibaro] Using hardcoded IP: %s, port: %d", ip, DEFAULT_PORT))
  
  local device = {
    host = ip,
    port = DEFAULT_PORT,
    scheme = "http",
    serial_number = "",
    platform = "HC3",
    discovery_source = discovery_provider.METHOD.HARDCODED,
    controller_kind = "hc3",
    device_network_id = "fibaro-hc3:" .. ip:gsub("%.", "-"),
    label = "Fibaro HC3 (Hardcoded)",
    api_version = 5
  }
  
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] Hardcoded device created: host=%s, port=%d, dni=%s",
    tostring(device.host),
    device.port,
    tostring(device.device_network_id)
  ))
  
  return {device}, nil
end

-- ============================================
-- Helper function for ping operations
-- ============================================

local function ping_host(host)
  log.info_with({hub_logs = true}, string.format("[Fibaro] Checking connectivity to host: %s", host))
  
  -- Try to create a TCP connection to check if host is reachable
  local sock = socket.tcp()
  if not sock then
    log.info_with({hub_logs = true}, string.format("[Fibaro] Failed to create socket for host: %s", host))
    return false
  end
  
  sock:settimeout(3)  -- 3 second timeout
  local result, err = sock:connect(host, 80)
  sock:close()
  
  local success = (result == 1 or result == true)
  log.info_with({hub_logs = true}, string.format("[Fibaro] Host connectivity check %s: %s", host, success and "SUCCESS" or "FAILED"))
  return success
end

-- ============================================
-- Main Fallback Discovery Function
-- ============================================

function discovery_provider.discover_with_fallback(driver, options)
  options = options or {}
  local devices = {}
  
  log.info_with({hub_logs = true}, "[Fibaro] ========================================")
  log.info_with({hub_logs = true}, "[Fibaro] Starting Discovery with Fallback")
  log.info_with({hub_logs = true}, string.format("[Fibaro] Hardcoded IP option: %s", tostring(options.hardcoded_ip or DEFAULT_HARDCODED_IP)))
  log.info_with({hub_logs = true}, "[Fibaro] ========================================")
  
  -- Perform ping operations before any discovery
  log.info_with({hub_logs = true}, "[Fibaro] Performing ping operations before discovery")
  for _, host in ipairs(PING_HOSTS) do
    ping_host(host)
  end
  
  -- Tier 1: mDNS
  devices, _ = discovery_provider.discover_via_mdns(driver)
  if #devices > 0 then
    log.info_with({hub_logs = true}, string.format("[Fibaro] ✓ Discovery successful via mDNS: %d devices", #devices))
    return devices
  end
  
  -- Tier 2: find.fibaro.com
  log.info_with({hub_logs = true}, "[Fibaro] mDNS found no devices, falling back to find.fibaro.com")
  devices, _ = discovery_provider.discover_via_find_fibaro(driver)
  if #devices > 0 then
    log.info_with({hub_logs = true}, string.format("[Fibaro] ✓ Discovery successful via find.fibaro.com: %d devices", #devices))
    return devices
  end
  
  -- Tier 3: Hardcoded IP
  log.info_with({hub_logs = true}, "[Fibaro] find.fibaro.com found no devices, falling back to hardcoded IP")
  local hardcoded_ip = options.hardcoded_ip or DEFAULT_HARDCODED_IP
  devices, _ = discovery_provider.discover_via_hardcoded(driver, hardcoded_ip)
  if #devices > 0 then
    log.info_with({hub_logs = true}, string.format("[Fibaro] ✓ Using hardcoded IP: %s", hardcoded_ip))
    return devices
  end
  
  log.warn_with({hub_logs = true}, "[Fibaro] ✗ All discovery methods failed, no devices found")
  return {}
end

return discovery_provider
