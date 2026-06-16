-- Copyright 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0
--
-- Local mock for SmartThings Edge Driver integration_test.utils module

local utils = {}

function utils.get_profile_definition(profile_name)
  -- Return a mock profile definition
  return {
    name = profile_name,
    id = "mock-profile-" .. tostring(profile_name)
  }
end

return utils
