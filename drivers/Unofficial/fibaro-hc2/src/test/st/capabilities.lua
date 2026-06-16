-- Copyright 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0
--
-- Local mock for SmartThings Edge Driver st.capabilities module

local capabilities = {}

-- Helper to create capability event
local function make_event(capability_name, attribute_name, value)
  return {
    capability = capability_name,
    attribute = attribute_name,
    value = value
  }
end

-- Switch capability
capabilities.switch = {
  switch = {
    on = function() return make_event("switch", "switch", "on") end,
    off = function() return make_event("switch", "switch", "off") end
  }
}

-- Switch Level capability
capabilities.switchLevel = {
  level = function(value) return make_event("switchLevel", "level", value) end
}

-- Window Shade capability
capabilities.windowShade = {
  windowShade = {
    open = function() return make_event("windowShade", "windowShade", "open") end,
    closed = function() return make_event("windowShade", "windowShade", "closed") end,
    partially_open = function() return make_event("windowShade", "windowShade", "partially_open") end
  }
}

-- Window Shade Level capability
capabilities.windowShadeLevel = {
  shadeLevel = function(value) return make_event("windowShadeLevel", "shadeLevel", value) end
}

-- Refresh capability
capabilities.refresh = {
  refresh = function() return make_event("refresh", "refresh", nil) end
}

-- Sensor capabilities
capabilities.temperatureMeasurement = {
  temperature = function(value) return make_event("temperatureMeasurement", "temperature", value) end
}

capabilities.humidityMeasurement = {
  humidity = function(value) return make_event("humidityMeasurement", "humidity", value) end
}

capabilities.illuminanceMeasurement = {
  illuminance = function(value) return make_event("illuminanceMeasurement", "illuminance", value) end
}

capabilities.contactSensor = {
  contact = {
    open = function() return make_event("contactSensor", "contact", "open") end,
    closed = function() return make_event("contactSensor", "contact", "closed") end
  }
}

capabilities.motionSensor = {
  motion = {
    active = function() return make_event("motionSensor", "motion", "active") end,
    inactive = function() return make_event("motionSensor", "motion", "inactive") end
  }
}

capabilities.smokeDetector = {
  smoke = {
    detected = function() return make_event("smokeDetector", "smoke", "detected") end,
    clear = function() return make_event("smokeDetector", "smoke", "clear") end
  }
}

capabilities.waterSensor = {
  water = {
    wet = function() return make_event("waterSensor", "water", "wet") end,
    dry = function() return make_event("waterSensor", "water", "dry") end
  }
}

capabilities.powerMeter = {
  power = function(value) return make_event("powerMeter", "power", value) end
}

capabilities.energyMeter = {
  energy = function(value) return make_event("energyMeter", "energy", value) end
}

capabilities.voltageMeasurement = {
  voltage = function(value) return make_event("voltageMeasurement", "voltage", value) end
}

capabilities.currentMeasurement = {
  current = function(value) return make_event("currentMeasurement", "current", value) end
}

return capabilities
