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

-- Minimal JSON-string escape for the few user-entered fields.
local function esc(s)
  return (tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"'))
end

-- Spike: send an upsert_camera so the bridge LOGS it (adb-visible:
-- "upsert dni=... onboarded on endpoint N"), proving the fork -> bridge path end to end.
function M.upsert(cam)
  local line = string.format(
    '{"v":1,"id":"fork-spike","op":"upsert_camera","camera":{"dni":"%s","name":"%s","control_url":"%s","userid":"%s","password":"%s","stream":"%s"}}',
    esc(cam.dni), esc(cam.name), esc(cam.control_url), esc(cam.userid), esc(cam.password), esc(cam.stream or "mainstream"))
  return M.send(line)
end

-- [single_bridge] Set the one default ONVIF login applied to every camera. The daemon
-- stores it and re-resolves all cameras with it (logs "set_default_creds ..." — adb-visible).
function M.set_default_creds(user, pass)
  local line = string.format(
    '{"v":1,"id":"bridge-creds","op":"set_default_creds","userid":"%s","password":"%s"}',
    esc(user), esc(pass))
  return M.send(line)
end

return M
