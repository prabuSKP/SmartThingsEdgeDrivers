-- src/discovery.lua
--
-- BroadLink discovery over UDP broadcast (port 80). Sends the "hello" packet, reads
-- replies, stashes each RM4's network info in driver.datastore, and creates one LAN
-- "parent" device per blaster. Uses the hub's own IP from driver.environment_info
-- (getsockname() on a 0.0.0.0-bound socket returns 0.0.0.0, which is useless here) and
-- adds a subnet-directed broadcast so routers that drop 255.255.255.255 still get it.
local log    = require "log"
local socket = require "cosock.socket"

local utils = require "utils"

local discovery = {}

local BROADLINK_PORT   = 80
local LIMITED_BROADCAST = "255.255.255.255"

local function hub_ipv4(driver)
  local env = driver and driver.environment_info or {}
  return env.hub_ipv4
end

-- Subnet-directed broadcast (x.y.z.255) derived from the hub's IPv4, if readable.
local function directed_broadcast(driver)
  local ip = hub_ipv4(driver)
  if type(ip) == "string" then
    local a, b, c = ip:match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
    if a then return string.format("%s.%s.%s.255", a, b, c) end
  end
  return nil
end

local function hello_packet(local_ip, local_port)
  local p = utils.zeros(0x30)

  -- Timestamp block (0x0c..0x13). Cosmetic for discovery; guard os.date in case the
  -- sandbox restricts it. Zeros are accepted by current firmware.
  local ok, now = pcall(os.date, "*t")
  if ok and type(now) == "table" then
    p[0x0c + 1] = now.year % 256
    p[0x0d + 1] = math.floor(now.year / 256)
    p[0x0e + 1] = now.min
    p[0x0f + 1] = now.hour
    p[0x10 + 1] = tonumber(tostring(now.year):sub(3, 4)) or 0
    p[0x11 + 1] = (now.wday - 1)          -- 0=Sun
    p[0x12 + 1] = now.day
    p[0x13 + 1] = now.month
  end

  local o = {}
  for oct in tostring(local_ip or ""):gmatch("%d+") do o[#o + 1] = tonumber(oct) end
  for i = 1, 4 do p[0x18 + i] = o[i] or 0 end

  p[0x1c + 1] = utils.lo(local_port or 0)
  p[0x1d + 1] = utils.hi(local_port or 0)
  p[0x26 + 1] = 0x06

  local cs = utils.checksum(p)
  p[0x20 + 1] = utils.lo(cs)
  p[0x21 + 1] = utils.hi(cs)
  return p
end

local function parse_reply(data, ip)
  local b = utils.to_bytes(data)
  if #b < 0x40 then return nil end
  local devtype = b[0x34 + 1] + b[0x35 + 1] * 256      -- device type code
  local mac = {}
  for i = 1, 6 do mac[i] = b[0x3a + i] end              -- MAC at 0x3a..0x3f
  return { ip = ip, mac = utils.bytes_to_hex(mac), devtype = devtype }
end

-- Broadcast scan. Returns a list of { ip=, mac=<hex>, devtype= }.
-- Pass unicast_ip to target a known RM4 when broadcast is blocked (plan test T5).
function discovery.scan(driver, timeout, unicast_ip)
  timeout = timeout or 5
  local sock, err = socket.udp()
  if not sock then
    log.warn_with({hub_logs = true}, "[BroadLink] udp() failed: " .. tostring(err))
    return {}
  end
  sock:setsockname("0.0.0.0", 0)
  sock:setoption("broadcast", true)

  local _, local_port = sock:getsockname()
  local pkt = utils.from_bytes(hello_packet(hub_ipv4(driver), tonumber(local_port) or 0))

  local targets
  if unicast_ip then
    targets = { unicast_ip }
  else
    targets = { LIMITED_BROADCAST }
    local directed = directed_broadcast(driver)
    if directed then table.insert(targets, directed) end
  end
  for _, t in ipairs(targets) do
    sock:sendto(pkt, t, BROADLINK_PORT)
  end

  local found, seen = {}, {}
  local deadline = socket.gettime() + timeout
  while socket.gettime() < deadline do
    sock:settimeout(math.max(0, math.min(1, deadline - socket.gettime())))
    local data, rip = sock:receivefrom()
    if data then
      local dev = parse_reply(data, rip)
      if dev and not seen[dev.mac] then
        seen[dev.mac] = true
        found[#found + 1] = dev
        log.info_with({hub_logs = true}, string.format(
          "[BroadLink] found %04x at %s (mac %s)", dev.devtype, tostring(dev.ip), dev.mac))
      end
    elseif rip and rip ~= "timeout" then
      break   -- a real socket error, not just a receive timeout
    end
  end
  sock:close()
  return found
end

-- SmartThings discovery handler: create one RM4 PARENT device per unit found.
function discovery.handler(driver, _, should_continue)
  log.info_with({hub_logs = true}, "[BroadLink] ===== starting discovery =====")
  driver.datastore.pending_rm4 = driver.datastore.pending_rm4 or {}

  local seen = {}
  while should_continue() do
    local results = discovery.scan(driver, 4)
    if #results == 0 then
      log.info_with({hub_logs = true}, "[BroadLink] scan pass: no RM4 replied yet")
    end
    for _, dev in ipairs(results) do
      local dni = "broadlink-" .. dev.mac
      if not seen[dni] then                        -- create/log each unit once per scan session
        seen[dni] = true
        driver.datastore.pending_rm4[dni] = dev    -- init will persist ip/mac/devtype
        log.info_with({hub_logs = true}, string.format(
          "[BroadLink] creating/updating RM4 parent dni=%s ip=%s", dni, tostring(dev.ip)))
        driver:try_create_device({
          type = "LAN",
          device_network_id = dni,
          label = "BroadLink RM4",
          profile = "rm4-hub",
          manufacturer = "BroadLink",
          model = string.format("%04x", dev.devtype),
          vendor_provided_label = "BroadLink RM4 (" .. tostring(dev.ip) .. ")",
        })
      end
    end
    socket.sleep(1.0)
  end

  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  log.info_with({hub_logs = true}, string.format("[BroadLink] discovery loop ended (%d RM4 seen)", n))
end

return discovery
