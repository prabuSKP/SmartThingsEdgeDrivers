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
-- it via the hub's own LAN IP. The authoritative source is the platform-provided
-- driver.environment_info.hub_ipv4 — callers pass the driver handle (or set
-- M.set_driver once) so we can read it. The old socket.dns self-lookup is kept only
-- as a fallback: it silently fails in the driver sandbox on some firmware (observed
-- returning nothing -> we connected to a stale hard-coded IP and creds never arrived).
M._driver = nil

-- Remember the driver handle so ops called without one (e.g. M.discover()) can
-- still resolve the hub IP from environment_info.
function M.set_driver(driver)
  M._driver = driver
end

function M.hub_ip(driver)
  local d = driver or M._driver
  local env = d and d.environment_info
  if env and type(env.hub_ipv4) == "string" and env.hub_ipv4 ~= "" then
    return env.hub_ipv4
  end
  local ok, ip = pcall(function() return socket.dns.toip(socket.dns.hostname()) end)
  if ok and type(ip) == "string" and ip ~= "" and ip ~= "127.0.0.1" then
    return ip
  end
  return "192.168.68.101" -- last-resort fallback (historical dev-hub address)
end

-- Send one newline-terminated JSON line; return the response line, or nil + error.
-- Optional per-call timeout (seconds) overrides M.TIMEOUT for slow ops like discover.
function M.send(line, timeout)
  local sock, err = socket.tcp()
  if not sock then return nil, "tcp: " .. tostring(err) end
  sock:settimeout(timeout or M.TIMEOUT)

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

-- [single_bridge] Tell the daemon to drop one camera: the bridged Matter endpoint AND its
-- cameras.json entry (logs "remove_camera dni=..." — adb-visible). Unlike upsert's nested
-- camera object, the keys sit at the TOP level of the request (see PROTOCOL.md).
-- Key precedence: `dni` (the daemon's stable camera id = the child's Matter UniqueID,
-- e.g. "onvif-mac-<12hex>") when known; otherwise `endpoint` — hub-core does not forward
-- driver reads of BridgedDeviceBasicInformation, so at delete time the driver often only
-- knows the endpoint (the trailing number of the child's device_network_id); the daemon
-- resolves endpoint -> dni itself. Removal is idempotent either way.
function M.remove_camera(dni, endpoint)
  local line
  if dni and dni ~= "" then
    line = string.format('{"v":1,"id":"bridge-remove","op":"remove_camera","dni":"%s"}', esc(dni))
  elseif endpoint then
    line = string.format('{"v":1,"id":"bridge-remove","op":"remove_camera","endpoint":%d}', endpoint)
  else
    return nil, "remove_camera needs a dni or an endpoint"
  end
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

-- [single_bridge] Ask the daemon to run a full LAN rescan (mDNS + WS-Discovery) and
-- onboard any new cameras (logs "discover found=.. added=.." — adb-visible). The scan
-- blocks on the daemon: two sequential ~4 s scans plus a SOAP/RTSP resolve per new
-- camera — 8.5 s measured on-hub with zero new cameras — so it needs a much longer
-- timeout than the default 5 s ops.
function M.discover()
  return M.send('{"v":1,"id":"bridge-discover","op":"discover"}', 20)
end

return M
