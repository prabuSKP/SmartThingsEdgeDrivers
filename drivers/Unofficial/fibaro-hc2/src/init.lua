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
    capabilities.powerMeter,
    capabilities.energyMeter,
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

-- Persistent queue of child devices waiting to be created. Discovering a hub with
-- hundreds of devices can exceed the SmartThings cloud device-creation rate limit,
-- so creates are paced out of this queue across multiple poll ticks and retried
-- with backoff if they fail. Survives hub reboots so no device is permanently lost.
if fibaro_hc2.datastore.pending_create_queue == nil then
  fibaro_hc2.datastore.pending_create_queue = {}
end

-- Tracks child creates already submitted to the platform (keyed by bridge|child key)
-- so a slow create that has not yet materialized is not enqueued again.
if fibaro_hc2.datastore.inflight_creates == nil then
  fibaro_hc2.datastore.inflight_creates = {}
end

-- fibaro_hc2:call_with_delay(3, discovery.do_mdns_scan, "Fibaro HC3 mDNS initial scan")
-- fibaro_hc2:call_on_schedule(MDNS_SCAN_INTERVAL_SECONDS, discovery.do_mdns_scan, "Fibaro HC3 mDNS scan")

log.info_with({hub_logs = true}, "[Fibaro] Starting driver")
fibaro_hc2:run()
