local log = require "log"

local utils = require "utils"
local fibaro_finder = require "fibaro_finder"

local discovery_provider = {}

local DEFAULT_PORT = 80

-- Stable DNI for the manual-entry bridge. When the Fibaro find server cannot locate the
-- controller automatically (HC off, different subnet, UDP blocked), we still create this
-- single bridge so the user has a settings card to enter the HC3 IP (or serial) into.
-- Stable DNI => repeated scans never spawn duplicates.
local MANUAL_BRIDGE_DNI = "fibaro-hc3:manual"
discovery_provider.MANUAL_BRIDGE_DNI = MANUAL_BRIDGE_DNI

-- Discovery method enum.
discovery_provider.METHOD = {
  FINDER = "fibaro_finder",
  MANUAL = "manual",
}

-- ============================================
-- TIER 1: Fibaro find server (UDP 44444/9999)
-- ============================================

-- The native local discovery used by the official Fibaro app/web (per the HC manual's
-- factory-default interface table). UDP broadcast request -> the HC replies with its info.
-- This is the only auto-discovery a real HC3 supports: it advertises no SSDP/UPnP, and its
-- Avahi is hostname-resolution only (no browsable mDNS service). See fibaro_finder.lua -- it
-- is heavily logged so the response format can be tuned from a real run.
function discovery_provider.discover_via_finder(driver)
  log.info_with({hub_logs = true}, "[Fibaro] ========== TIER 1: Starting Fibaro find-server Discovery ==========")

  local devices = fibaro_finder.scan(driver)
  for _, candidate in ipairs(devices) do
    candidate.discovery_source = discovery_provider.METHOD.FINDER
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] finder candidate added: host=%s, port=%d, serial=%s, platform=%s",
      tostring(candidate.host), candidate.port,
      tostring(candidate.serial_number), tostring(candidate.platform)))
  end

  log.info_with({hub_logs = true}, string.format("[Fibaro] Fibaro find-server discovery complete: %d valid devices found", #devices))
  return devices, nil
end

-- ============================================
-- Manual-entry bridge (fallback)
-- ============================================

-- A placeholder bridge with no host. The user opens its settings and enters the HC3 IP (or
-- serial) plus credentials. Used only when the find server returns nothing.
function discovery_provider.build_manual_bridge()
  return {
    host = "",
    port = DEFAULT_PORT,
    scheme = "http",
    serial_number = "",
    platform = "HC3",
    discovery_source = discovery_provider.METHOD.MANUAL,
    controller_kind = "hc3",
    device_network_id = MANUAL_BRIDGE_DNI,
    label = "Fibaro HC3",
    api_version = 5,
  }
end

return discovery_provider
