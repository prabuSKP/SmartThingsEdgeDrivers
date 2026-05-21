local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local log = require "log"

local commands = require "handlers.commands"
local discovery = require "discovery"
local lifecycle = require "handlers.lifecycle"

local MDNS_SCAN_INTERVAL_SECONDS = 300

local fibaro_hc2 = Driver("fibaro", {
  discovery = discovery.discover,
  lifecycle_handlers = {
    init = lifecycle.init,
    added = lifecycle.added,
    infoChanged = lifecycle.info_changed,
    removed = lifecycle.removed,
  },
  capability_handlers = commands.capability_handlers,
  supported_capabilities = {
    capabilities.refresh,
    capabilities.switch,
    capabilities.switchLevel,
    capabilities.contactSensor,
    capabilities.motionSensor,
    capabilities.windowShade,
    capabilities.windowShadeLevel,
    capabilities.smokeDetector,
    capabilities.temperatureMeasurement,
    capabilities.relativeHumidityMeasurement,
    capabilities.illuminanceMeasurement,
    capabilities.waterSensor,
  },
})

if fibaro_hc2.datastore.pending_child_data == nil then
  fibaro_hc2.datastore.pending_child_data = {}
end

if fibaro_hc2.datastore.pending_bridge_data == nil then
  fibaro_hc2.datastore.pending_bridge_data = {}
end

-- fibaro_hc2:call_with_delay(3, discovery.do_mdns_scan, "Fibaro HC3 mDNS initial scan")
-- fibaro_hc2:call_on_schedule(MDNS_SCAN_INTERVAL_SECONDS, discovery.do_mdns_scan, "Fibaro HC3 mDNS scan")

log.info_with({hub_logs = true}, "[Fibaro] Starting driver")
fibaro_hc2:run()
