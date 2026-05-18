local log = require "log"
local mdns = require "st.mdns"
local json = require "st.json"
local socket = require "cosock.socket"
local http = require "socket.http"
local ltn12 = require "ltn12"

local utils = require "utils"

local discovery_provider = {}

-- Discovery method enum
discovery_provider.METHOD = {
  MDNS = "mdns",
  FIND_FIBARO = "find_fibaro",
  HARDCODED = "hardcoded"
}

-- Constants
local MDNS_DOMAIN = "local"
local MDNS_SERVICE_TYPE = "_http._tcp"
local FIND_FIBARO_URL = "http://find.fibaro.com/api/find/devices"
local FIND_FIBARO_TIMEOUT = 10
local DEFAULT_HARDCODED_IP = "192.168.0.126"
local DEFAULT_PORT = 80

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
-- Main Fallback Discovery Function
-- ============================================

function discovery_provider.discover_with_fallback(driver, options)
  options = options or {}
  local devices = {}
  
  log.info_with({hub_logs = true}, "[Fibaro] ========================================")
  log.info_with({hub_logs = true}, "[Fibaro] Starting Discovery with Fallback")
  log.info_with({hub_logs = true}, string.format("[Fibaro] Hardcoded IP option: %s", tostring(options.hardcoded_ip or DEFAULT_HARDCODED_IP)))
  log.info_with({hub_logs = true}, "[Fibaro] ========================================")
  
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
