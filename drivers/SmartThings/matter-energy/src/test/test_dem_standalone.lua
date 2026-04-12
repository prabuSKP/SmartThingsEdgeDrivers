-- Copyright 2025 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local test = require "integration_test"
local clusters = require "st.matter.clusters"
local capabilities = require "st.capabilities"
local t_utils = require "integration_test.utils"
local version = require "version"

local DEM_STANDALONE_EP = 3

local DEVICE_ENERGY_MANAGEMENT_DEVICE_TYPE_ID = 0x050D

if version.api < 12 then
  clusters.DeviceEnergyManagementMode = require "DeviceEnergyManagementMode"
end

local mock_device = test.mock_device.build_test_matter_device({
  profile = t_utils.get_profile_definition("dem-standalone.yml"),
  manufacturer_info = {
    vendor_id = 0x0000,
    product_id = 0x0000,
  },
  endpoints = {
    {
      endpoint_id = 0,
      clusters = {
        { cluster_id = clusters.Basic.ID, cluster_type = "SERVER" },
      },
      device_types = {
        { device_type_id = 0x0016, device_type_revision = 1 }, -- RootNode
      }
    },
    {
      endpoint_id = DEM_STANDALONE_EP,
      clusters = {
        { cluster_id = clusters.DeviceEnergyManagementMode.ID, cluster_type = "SERVER" },
      },
      device_types = {
        { device_type_id = DEVICE_ENERGY_MANAGEMENT_DEVICE_TYPE_ID, device_type_revision = 1 },
      }
    },
  }
})

local function test_init()
  test.disable_startup_messages()
  test.mock_device.add_test_device(mock_device)
  local cluster_subscribe_list = {
    clusters.DeviceEnergyManagementMode.attributes.SupportedModes,
    clusters.DeviceEnergyManagementMode.attributes.CurrentMode,
  }
  local subscribe_request = cluster_subscribe_list[1]:subscribe(mock_device)
  for i, cluster in ipairs(cluster_subscribe_list) do
    if i > 1 then
      subscribe_request:merge(cluster:subscribe(mock_device))
    end
  end
  test.socket.device_lifecycle:__queue_receive({ mock_device.id, "added" })
  test.socket.device_lifecycle:__queue_receive({ mock_device.id, "init" })
  test.socket.matter:__expect_send({ mock_device.id, subscribe_request })

  test.socket.device_lifecycle:__queue_receive({ mock_device.id, "doConfigure" })
  mock_device:expect_metadata_update({ profile = "dem-standalone" })
  mock_device:expect_metadata_update({ provisioning_state = "PROVISIONED" })
end
test.set_test_init_function(test_init)

test.register_coroutine_test(
  "SupportedModes report must emit mode.supportedModes capability",
  function()
    test.socket.matter:__queue_receive({
      mock_device.id,
      clusters.DeviceEnergyManagementMode.attributes.SupportedModes:build_test_report_data(mock_device,
        DEM_STANDALONE_EP,
        {
          clusters.DeviceEnergyManagementMode.types.ModeOptionStruct({ label = "Normal", mode = 0, mode_tags = {} }),
          clusters.DeviceEnergyManagementMode.types.ModeOptionStruct({ label = "Eco", mode = 1, mode_tags = {} }),
        })
    })

    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.mode.supportedModes({ "Normal", "Eco" }, { visibility = { displayed = false } })))
    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.mode.supportedArguments({ "Normal", "Eco" }, { visibility = { displayed = false } })))
  end
)

test.register_coroutine_test(
  "CurrentMode report must emit mode.mode capability with correct label",
  function()
    test.socket.matter:__queue_receive({
      mock_device.id,
      clusters.DeviceEnergyManagementMode.attributes.SupportedModes:build_test_report_data(mock_device,
        DEM_STANDALONE_EP,
        {
          clusters.DeviceEnergyManagementMode.types.ModeOptionStruct({ label = "Normal", mode = 0, mode_tags = {} }),
          clusters.DeviceEnergyManagementMode.types.ModeOptionStruct({ label = "Eco", mode = 1, mode_tags = {} }),
        })
    })

    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.mode.supportedModes({ "Normal", "Eco" }, { visibility = { displayed = false } })))
    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.mode.supportedArguments({ "Normal", "Eco" }, { visibility = { displayed = false } })))

    test.socket.matter:__queue_receive({
      mock_device.id,
      clusters.DeviceEnergyManagementMode.attributes.CurrentMode:build_test_report_data(mock_device,
        DEM_STANDALONE_EP,
        1) -- mode index 1 = "Eco"
    })

    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.mode.mode("Eco")))
  end
)

test.register_coroutine_test(
  "setMode command for standalone DEM must send ChangeToMode to DeviceEnergyManagementMode cluster",
  function()
    test.socket.matter:__queue_receive({
      mock_device.id,
      clusters.DeviceEnergyManagementMode.attributes.SupportedModes:build_test_report_data(mock_device,
        DEM_STANDALONE_EP,
        {
          clusters.DeviceEnergyManagementMode.types.ModeOptionStruct({ label = "Normal", mode = 0, mode_tags = {} }),
          clusters.DeviceEnergyManagementMode.types.ModeOptionStruct({ label = "Eco", mode = 1, mode_tags = {} }),
        })
    })

    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.mode.supportedModes({ "Normal", "Eco" }, { visibility = { displayed = false } })))
    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.mode.supportedArguments({ "Normal", "Eco" }, { visibility = { displayed = false } })))

    test.wait_for_events()

    test.socket.capability:__queue_receive({
      mock_device.id,
      { capability = "mode", component = "main", command = "setMode", args = { "Eco" } }
    })

    test.socket.matter:__expect_send({
      mock_device.id,
      clusters.DeviceEnergyManagementMode.commands.ChangeToMode(mock_device, DEM_STANDALONE_EP, 1) -- index 1 = "Eco"
    })
  end
)

test.run_registered_tests()
