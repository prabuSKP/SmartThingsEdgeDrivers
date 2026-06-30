-- [single_bridge spike] bridge_ipc.lua
--
-- Minimal client to the native ONVIF->Matter bridge's IPC server, used to prove that
-- a FORKED matter-switch (a Matter driver) — given the `lan` permission — can reach the
-- bridge on the hub. Newline-JSON over TCP, one request -> one response -> close
-- (see ../../../../../../onvif-camera-bridge/matter-bridge/ipc/PROTOCOL.md).
--
-- Spike scope: just `ping` (proves reachability). The real flow would send
-- `upsert_camera` keyed off the camera's DNI.

local socket = require "cosock.socket"

local M = {}
M.PORT = 9444
M.TIMEOUT = 5

-- The bridge listens on 0.0.0.0:9444; Edge drivers have no host loopback, so we reach
-- it via the hub's own LAN IP (brokered by hub-core), exactly like the onboarder did.
function M.hub_ip()
  local ok, ip = pcall(function() return socket.dns.toip(socket.dns.hostname()) end)
  if ok and type(ip) == "string" and ip ~= "" and ip ~= "127.0.0.1" then
    return ip
  end
  return "192.168.68.101" -- fallback
end

-- Send one newline-terminated JSON line; return the response line, or nil + error.
function M.send(line)
  local sock, err = socket.tcp()
  if not sock then return nil, "tcp: " .. tostring(err) end
  sock:settimeout(M.TIMEOUT)

  local ip = M.hub_ip()
  local ok, cerr = sock:connect(ip, M.PORT)
  if not ok then sock:close(); return nil, "connect " .. ip .. ":" .. M.PORT .. ": " .. tostring(cerr) end

  local _, serr = sock:send(line .. "\n")
  if serr then sock:close(); return nil, "send: " .. tostring(serr) end

  local resp, rerr = sock:receive("*l")
  sock:close()
  if not resp then return nil, "recv: " .. tostring(rerr) end
  return resp
end

function M.ping()
  return M.send('{"v":1,"id":"single-bridge-spike","op":"ping"}')
end

return M
