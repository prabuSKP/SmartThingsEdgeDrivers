local log = require "log"

local energy_utils = {}

-- Structured logging for electrical measurements
function energy_utils.log_electrical(endpoint, voltage_V, current_A, power_W)
  log.debug(string.format(
    "EPM[EP%d]: V=%.2fV I=%.2fA P=%.2fW",
    endpoint, voltage_V or 0, current_A or 0, power_W or 0
  ))
end

function energy_utils.log_energy(endpoint, energy_Wh, direction)
  log.debug(string.format(
    "EEM[EP%d]: %s=%.2fWh",
    endpoint, direction or "imported", energy_Wh or 0
  ))
end

-- Throttle guard (returns true if enough time has passed, always passes on first call)
local MINIMUM_REPORT_INTERVAL = 2 -- seconds
function energy_utils.should_report(device, field_name, endpoint)
  local key = string.format("%s_%d", field_name, endpoint)
  local last_time = device:get_field(key)
  local now = os.time()
  if last_time == nil or now - last_time >= MINIMUM_REPORT_INTERVAL then
    device:set_field(key, now)
    return true
  end
  return false
end

return energy_utils
