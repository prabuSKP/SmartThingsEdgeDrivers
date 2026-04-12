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

local ELECTRICAL_SENSOR_EP = 2

local ELECTRICAL_SENSOR_DEVICE_TYPE_ID = 0x0510

if version.api < 11 then
  clusters.ElectricalEnergyMeasurement = require "ElectricalEnergyMeasurement"
  clusters.ElectricalPowerMeasurement = require "ElectricalPowerMeasurement"
end

local mock_device = test.mock_device.build_test_matter_device({
  profile = t_utils.get_profile_definition("electrical-sensor-voltage-current.yml"),
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
      endpoint_id = ELECTRICAL_SENSOR_EP,
      clusters = {
        { cluster_id = clusters.ElectricalEnergyMeasurement.ID, cluster_type = "SERVER", feature_map = 6 }, -- CUME & PERE
        { cluster_id = clusters.ElectricalPowerMeasurement.ID,  cluster_type = "SERVER", attributes = { { attribute_id = 0x0004 } } },
      },
      device_types = {
        { device_type_id = ELECTRICAL_SENSOR_DEVICE_TYPE_ID, device_type_revision = 1 },
      }
    },
  }
})

-- Build subscribe list matching the actual driver subscribed_attributes iteration order:
-- powerSource (PowerMode), voltageMeasurement (Voltage), powerMeter (ActivePower),
-- currentMeasurement (ActiveCurrent), energyMeter (PeriodicEnergyExported),
-- powerConsumptionReport (PeriodicEnergyImported)
local function build_subscribe_request()
  local cluster_subscribe_list = {
    clusters.ElectricalPowerMeasurement.attributes.PowerMode,
    clusters.ElectricalPowerMeasurement.attributes.Voltage,
    clusters.ElectricalPowerMeasurement.attributes.ActivePower,
    clusters.ElectricalPowerMeasurement.attributes.ActiveCurrent,
    clusters.ElectricalEnergyMeasurement.attributes.PeriodicEnergyExported,
    clusters.ElectricalEnergyMeasurement.attributes.PeriodicEnergyImported,
  }
  local subscribe_request = cluster_subscribe_list[1]:subscribe(mock_device)
  for i, cluster in ipairs(cluster_subscribe_list) do
    if i > 1 then subscribe_request:merge(cluster:subscribe(mock_device)) end
  end
  return subscribe_request
end

local function test_init()
  test.disable_startup_messages()
  test.mock_device.add_test_device(mock_device)
  test.socket.device_lifecycle:__queue_receive({ mock_device.id, "added" })
  test.socket.device_lifecycle:__queue_receive({ mock_device.id, "init" })
  test.socket.matter:__expect_send({ mock_device.id, build_subscribe_request() })

  test.socket.device_lifecycle:__queue_receive({ mock_device.id, "doConfigure" })
  mock_device:expect_metadata_update({ profile = "electrical-sensor-voltage-current" })
  mock_device:expect_metadata_update({ provisioning_state = "PROVISIONED" })
end
test.set_test_init_function(test_init)

-- ── Test 1: PowerMode → powerSource ─────────────────────────────────────────
test.register_coroutine_test(
  "PowerMode AC report must emit powerSource.powerSource = mains",
  function()
    test.socket.matter:__queue_receive({
      mock_device.id,
      clusters.ElectricalPowerMeasurement.attributes.PowerMode:build_test_report_data(
        mock_device, ELECTRICAL_SENSOR_EP, clusters.ElectricalPowerMeasurement.types.PowerModeEnum.AC)
    })
    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.powerSource.powerSource.mains()))
  end
)

-- ── Test 2: Voltage conversion ───────────────────────────────────────────────
test.register_coroutine_test(
  "Voltage report: mV must be converted to V for voltageMeasurement capability",
  function()
    test.socket.matter:__queue_receive({
      mock_device.id,
      clusters.ElectricalPowerMeasurement.attributes.Voltage:build_test_report_data(
        mock_device, ELECTRICAL_SENSOR_EP, 230000) -- 230 V in mV
    })
    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.voltageMeasurement.voltage({ value = 230.0, unit = "V" })))
  end
)

-- ── Test 2: Current conversion ───────────────────────────────────────────────
test.register_coroutine_test(
  "ActiveCurrent report: mA must be converted to A for currentMeasurement capability",
  function()
    test.socket.matter:__queue_receive({
      mock_device.id,
      clusters.ElectricalPowerMeasurement.attributes.ActiveCurrent:build_test_report_data(
        mock_device, ELECTRICAL_SENSOR_EP, 6500) -- 6.5 A in mA
    })
    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.currentMeasurement.current({ value = 6.5, unit = "A" })))
  end
)

-- ── Test 3: ActivePower conversion ──────────────────────────────────
test.register_coroutine_test(
  "ActivePower report: mW must be converted to W for powerMeter capability",
  function()
    test.socket.matter:__queue_receive({
      mock_device.id,
      clusters.ElectricalPowerMeasurement.attributes.ActivePower:build_test_report_data(
        mock_device, ELECTRICAL_SENSOR_EP, 1500000) -- 1500 W in mW
    })
    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.powerMeter.power({ value = 1500.0, unit = "W" })))
  end
)

-- ── Test 4: CumulativeEnergyImported → energyMeter ──────────────────────────
test.register_coroutine_test(
  "CumulativeEnergyImported report must emit energyMeter with converted Wh value",
  function()
    test.mock_time.advance_time(901) -- move time 15+ minutes past 0

    test.socket.matter:__queue_receive({
      mock_device.id,
      clusters.ElectricalEnergyMeasurement.attributes.CumulativeEnergyImported:build_test_report_data(
        mock_device, ELECTRICAL_SENSOR_EP,
        clusters.ElectricalEnergyMeasurement.types.EnergyMeasurementStruct({
          energy = 45000000, -- 45 kWh in mWh
          start_timestamp = 0, end_timestamp = 0,
          start_systime = 0, end_systime = 0,
          apparent_energy = 0, reactive_energy = 0
        }))
    })

    test.socket.capability:__expect_send(
      mock_device:generate_test_message("main",
        capabilities.energyMeter.energy({ value = 45000, unit = "Wh" })))

    test.socket.capability:__expect_send(
      mock_device:generate_test_message("main",
        capabilities.powerConsumptionReport.powerConsumption({
          energy = 45000,
          deltaEnergy = 0.0,
          start = "1970-01-01T00:00:00Z",
          ["end"] = "1970-01-01T00:15:00Z"
        })))
  end
)

test.run_registered_tests()
