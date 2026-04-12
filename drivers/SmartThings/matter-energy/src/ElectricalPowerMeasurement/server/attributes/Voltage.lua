local cluster_base = require "st.matter.cluster_base"
local data_types = require "st.matter.data_types"
local TLVParser = require "st.matter.TLV.TLVParser"

local Voltage = {
  ID = 0x0004,
  NAME = "Voltage",
  base_type = require "st.matter.data_types.Int64",
}

function Voltage:new_value(...)
  local o = self.base_type(table.unpack({...}))

  return o
end

function Voltage:read(device, endpoint_id)
  return cluster_base.read(
    device,
    endpoint_id,
    self._cluster.ID,
    self.ID,
    nil
  )
end

function Voltage:subscribe(device, endpoint_id)
  return cluster_base.subscribe(
    device,
    endpoint_id,
    self._cluster.ID,
    self.ID,
    nil
  )
end

function Voltage:set_parent_cluster(cluster)
  self._cluster = cluster
  return self
end

function Voltage:build_test_report_data(
  device,
  endpoint_id,
  value,
  status
)
  local data = data_types.validate_or_build_type(value, self.base_type)

  return cluster_base.build_test_report_data(
    device,
    endpoint_id,
    self._cluster.ID,
    self.ID,
    data,
    status
  )
end

function Voltage:deserialize(tlv_buf)
  local data = TLVParser.decode_tlv(tlv_buf)

  return data
end

setmetatable(Voltage, {__call = Voltage.new_value, __index = Voltage.base_type})
return Voltage
