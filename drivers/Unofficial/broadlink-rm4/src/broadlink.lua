-- src/broadlink.lua
--
-- BroadLink protocol layer: packet framing, the 0x65 login handshake, IR send (0x6a),
-- and IR learning. Offsets follow python-broadlink and must be confirmed against a real
-- capture (plan test T3) -- a wrong checksum/offset makes the RM4 silently ignore you.
--
-- IR is one-way: send_ir/send_packet confirm only that the RM4 *received and emitted* the
-- command (via its reply/error code), never that the appliance obeyed.
local socket = require "cosock.socket"
local crypto = require "crypto"
local utils  = require "utils"
local log    = require "log"

local Device = {}
Device.__index = Device

local BROADLINK_PORT = 80

-- Construct a handle. mac is a 6-byte array (in discovery-reply order), devtype a number,
-- ip a string.
function Device.new(ip, mac, devtype)
  return setmetatable({
    ip = ip, mac = mac, devtype = devtype,
    count = math.random(0xffff),           -- rolling packet counter
    id  = {0, 0, 0, 0},                     -- device id, filled by auth()
    key = crypto.INITIAL_KEY,               -- session key, replaced by auth()
    iv  = crypto.IV,
  }, Device)
end

-- Build + encrypt a full BroadLink packet for `command` carrying `payload`
-- (payload is a byte array; must be a multiple of 16 bytes).
function Device:build_packet(command, payload)
  local p = utils.zeros(0x38)

  local magic = {0x5a,0xa5,0xaa,0x55,0x5a,0xa5,0xaa,0x55}
  for i = 1, 8 do p[i] = magic[i] end       -- offsets 0x00..0x07

  p[0x24 + 1] = utils.lo(self.devtype)
  p[0x25 + 1] = utils.hi(self.devtype)
  p[0x26 + 1] = command

  self.count = (self.count + 1) % 0x10000
  p[0x28 + 1] = utils.lo(self.count)
  p[0x29 + 1] = utils.hi(self.count)

  -- MAC at 0x2a..0x2f. Copied in discovery order (no reversal). If a T3 capture shows
  -- the login MAC reversed vs the discovery MAC, reverse this loop.
  for i = 1, 6 do p[0x2a + i] = self.mac[i] end
  -- device id at 0x30..0x33
  for i = 1, 4 do p[0x30 + i] = self.id[i] end

  -- payload checksum (over PLAINTEXT payload), stored at 0x34..0x35
  local pcs = utils.checksum(payload)
  p[0x34 + 1] = utils.lo(pcs)
  p[0x35 + 1] = utils.hi(pcs)

  -- encrypt payload and append at 0x38
  local enc = crypto.encrypt(self.key, self.iv, payload)
  for i = 1, #enc do p[0x38 + i] = enc[i] end

  -- whole-packet checksum, stored at 0x20..0x21 (computed AFTER everything above,
  -- while 0x20/0x21 are still zero)
  local wcs = utils.checksum(p)
  p[0x20 + 1] = utils.lo(wcs)
  p[0x21 + 1] = utils.hi(wcs)

  return p
end

-- Send a packet and wait for one UDP reply, retrying on loss.
-- Returns (reply_bytes | nil, err).
function Device:send_packet(command, payload, retries)
  retries = retries or 2
  local pkt  = self:build_packet(command, payload)   -- byte array (build once)
  local wire = utils.from_bytes(pkt)
  -- Step-0 diagnostics: full outgoing (encrypted) datagram, for a Wireshark cross-check
  -- against the Python script's on-the-wire bytes.
  log.info_with({hub_logs = true}, string.format(
    "[BroadLink] TX cmd=0x%02x %d bytes: %s", command, #pkt, utils.bytes_to_hex(pkt)))
  for attempt = 0, retries do
    local udp = socket.udp()
    udp:setsockname("0.0.0.0", 0)           -- bind to a random source port
    udp:settimeout(2)
    log.info_with({hub_logs = true}, string.format(
      "[BroadLink] -> %s:%d cmd=0x%02x len=%d (try %d/%d)",
      tostring(self.ip), BROADLINK_PORT, command, #wire, attempt + 1, retries + 1))
    udp:sendto(wire, self.ip, BROADLINK_PORT)
    local data = udp:receivefrom()
    udp:close()
    if data then
      local resp = utils.to_bytes(data)
      -- Step-0 diagnostics: the device's per-packet error code (0x22..0x23). python-broadlink
      -- checks this and raises on non-zero; we were previously ignoring it entirely.
      local errcode = (resp[0x22 + 1] or 0) + (resp[0x23 + 1] or 0) * 256
      log.info_with({hub_logs = true}, string.format(
        "[BroadLink] <- %s reply len=%d errcode=%d%s", tostring(self.ip), #data, errcode,
        errcode ~= 0 and "  <<< DEVICE REPORTED ERROR" or ""))
      return resp
    end
    log.warn_with({hub_logs = true}, string.format(
      "[BroadLink] no reply from %s (try %d/%d)", tostring(self.ip), attempt + 1, retries + 1))
    socket.sleep(0.2 * (attempt + 1))       -- brief wait before retry
  end
  return nil, "no reply after " .. (retries + 1) .. " attempts"
end

-- Login handshake (command 0x65). Fills self.id and self.key on success.
function Device:auth()
  -- Always authenticate from a clean slate: the login request MUST be encrypted with the
  -- INITIAL key/IV and carry a zero device id. Re-auth on an already-authed handle otherwise
  -- reuses the session key + old id, and the device replies -7 "control key expired"
  -- (seen in shortVersion4 line 901/1496).
  self.key = crypto.INITIAL_KEY
  self.iv  = crypto.IV
  self.id  = {0, 0, 0, 0}
  local payload = utils.zeros(0x50)
  for i = 0x04, 0x12 do payload[i + 1] = 0x31 end  -- 0x31 filler block
  payload[0x1e + 1] = 0x01
  payload[0x2d + 1] = 0x01
  local name = "Test  1"                            -- any client name
  for i = 1, #name do payload[0x30 + i] = name:byte(i) end

  log.info_with({hub_logs = true}, "[BroadLink] login (0x65) to " .. tostring(self.ip)
    .. " mac=" .. utils.bytes_to_hex(self.mac) .. string.format(" devtype=%04x", self.devtype))
  local resp, err = self:send_packet(0x65, payload)
  if not resp then
    log.error_with({hub_logs = true}, "[BroadLink] login: no reply (" .. tostring(err) .. ")")
    return false, err
  end

  local errcode = resp[0x22 + 1] + resp[0x23 + 1] * 256
  if errcode ~= 0 then
    log.error_with({hub_logs = true}, string.format("[BroadLink] login rejected, error code %d", errcode))
    return false, "login error " .. errcode
  end

  -- decrypt the reply body (from 0x38) with the INITIAL key
  local enc = {}
  for i = 0x38 + 1, #resp do enc[#enc + 1] = resp[i] end
  local dec = crypto.decrypt(crypto.INITIAL_KEY, crypto.IV, enc)

  -- device id = dec[0x00..0x03], new session key = dec[0x04..0x13]
  self.id = {dec[1], dec[2], dec[3], dec[4]}
  local k = {}
  for i = 1, 16 do k[i] = dec[0x04 + i] end
  self.key = k
  log.info_with({hub_logs = true}, "[BroadLink] login OK, device id=" .. utils.bytes_to_hex(self.id))
  return true
end

-- Every 0x6a sub-command (send / enter-learning / check-learned) uses the RM4 (rm4mini →
-- rmminib) framing: a 2-byte LE length (= #data + 4) + a 4-byte LE sub-command, THEN the data,
-- padded to 16. The older RM-Mini format (python-broadlink `rmmini`) omits the length prefix —
-- sending THAT to an RM4 makes it read the sub-command byte as the length and reject the packet
-- with error -5. devtype 0x520c is rm4mini, so we must use the length-prefixed form.
--   rmminib._send: packet = struct.pack("<HI", len(data)+4, command) + data
function Device:cmd_6a(command, data)
  data = data or {}
  local n = #data + 4
  local payload = { n % 256, math.floor(n / 256) % 256, command % 256, 0, 0, 0 }
  for i = 1, #data do payload[#payload + 1] = data[i] end
  while #payload % 16 ~= 0 do payload[#payload + 1] = 0 end   -- pad to 16
  return self:send_packet(0x6a, payload)
end

-- Send a raw IR blob (byte array, 0x26-prefixed BroadLink format).
function Device:send_ir(ir_bytes)
  -- diagnostics: the exact IR blob handed to the RM4 (directly comparable to the `data` the
  -- Python script passes to send_data()).
  log.info_with({hub_logs = true}, string.format(
    "[BroadLink] send_ir: %d IR bytes -> %s : %s",
    #ir_bytes, tostring(self.ip), utils.bytes_to_hex(ir_bytes)))
  local resp, err = self:cmd_6a(0x02, ir_bytes)
  if not resp then return nil, err end
  -- A non-zero error code means the RM4 received the packet but refused to emit. We used to
  -- treat any reply as success; now a rejected send fails (and re-login/retry kicks in).
  local errcode = (resp[0x22 + 1] or 0) + (resp[0x23 + 1] or 0) * 256
  if errcode ~= 0 then
    log.error_with({hub_logs = true}, string.format(
      "[BroadLink] send_ir REJECTED by RM4 (errcode=%d) — received but not emitted", errcode))
    return nil, "send error " .. errcode
  end
  return resp
end

-- Enter IR learning mode (sub-command 0x03).
function Device:enter_learning()
  log.info_with({hub_logs = true}, "[BroadLink] enter_learning on " .. tostring(self.ip))
  return self:cmd_6a(0x03)
end

-- Poll for a learned code (sub-command 0x04). Returns (ir_bytes | nil, err).
function Device:check_learned()
  local resp, err = self:cmd_6a(0x04)
  if not resp then return nil, err end

  local errcode = (resp[0x22 + 1] or 0) + (resp[0x23 + 1] or 0) * 256
  if errcode ~= 0 then return nil, "not ready (" .. errcode .. ")" end

  local enc = {}
  for i = 0x38 + 1, #resp do enc[#enc + 1] = resp[i] end
  local dec = crypto.decrypt(self.key, self.iv, enc)
  -- rmminib reply mirrors the request: [2-byte LE length][4-byte command echo][learned IR ...].
  -- The learned bytes start at offset 0x06 and run to (length + 2). (Old RM-Mini put them at 0x04.)
  local plen = (dec[1] or 0) + (dec[2] or 0) * 256
  local last = math.min(plen + 2, #dec)
  local ir = {}
  for i = 0x06 + 1, last do ir[#ir + 1] = dec[i] end
  log.info_with({hub_logs = true}, string.format(
    "[BroadLink] check_learned: captured %d IR bytes : %s", #ir, utils.bytes_to_hex(ir)))
  return ir
end

return Device
