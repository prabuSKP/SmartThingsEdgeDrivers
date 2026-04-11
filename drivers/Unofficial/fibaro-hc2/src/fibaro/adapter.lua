local hc2 = require "fibaro.adapters.hc2"
local hc3 = require "fibaro.adapters.hc3"

local adapter = {}

local ADAPTERS = {
  [hc2.NAME] = hc2,
  [hc3.NAME] = hc3,
}

local function normalize_list_payload(payload)
  if type(payload) ~= "table" then
    return {}
  end

  if type(payload.devices) == "table" then
    return payload.devices
  end

  return payload
end

function adapter.for_name(name)
  return ADAPTERS[name] or nil
end

function adapter.default_for_scheme(scheme)
  if tostring(scheme or ""):lower() == "https" then
    return hc3
  end

  return hc2
end

function adapter.detect_devices(payload, scheme)
  local raw_devices = normalize_list_payload(payload)

  for _, raw_device in ipairs(raw_devices) do
    if hc3.is_match(raw_device) then
      return hc3
    end
  end

  for _, raw_device in ipairs(raw_devices) do
    if hc2.is_match(raw_device) then
      return hc2
    end
  end

  return adapter.default_for_scheme(scheme)
end

return adapter
