local cluster_base = require "st.matter.cluster_base"
local data_types = require "st.matter.data_types"
local TLVParser = require "st.matter.TLV.TLVParser"

local ActiveCurrent = {
  ID = 0x0005,
  NAME = "ActiveCurrent",
  base_type = require "st.matter.data_types.Int64",
}

function ActiveCurrent:new_value(...)
  local o = self.base_type(table.unpack({...}))

  return o
end

function ActiveCurrent:read(device, endpoint_id)
  return cluster_base.read(
    device,
    endpoint_id,
    self._cluster.ID,
    self.ID,
    nil
  )
end

function ActiveCurrent:subscribe(device, endpoint_id)
  return cluster_base.subscribe(
    device,
    endpoint_id,
    self._cluster.ID,
    self.ID,
    nil
  )
end

function ActiveCurrent:set_parent_cluster(cluster)
  self._cluster = cluster
  return self
end

function ActiveCurrent:build_test_report_data(
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

function ActiveCurrent:deserialize(tlv_buf)
  local data = TLVParser.decode_tlv(tlv_buf)

  return data
end

setmetatable(ActiveCurrent, {__call = ActiveCurrent.new_value, __index = ActiveCurrent.base_type})
return ActiveCurrent
