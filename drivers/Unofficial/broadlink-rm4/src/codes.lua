-- src/codes.lua
--
-- Optional SEED codes, keyed by appliance type then slot. This is a *fallback* only —
-- code_store.get() checks a device's LEARNED codes first, then falls back here. Learning
-- in the app (Learn mode) always wins and is the reliable path.
--
-- ⚠️ The `tv` set below is GENERATED from the standard Samsung IR protocol (not captured from
-- a real device). It targets Samsung TVs / smart monitors (e.g. M5) that have an IR receiver
-- and use the classic Samsung codeset. It is UNVERIFIED:
--   * the Samsung M5's bundled remote is Bluetooth, and not every Samsung monitor exposes an
--     IR receiver — if the monitor ignores IR entirely, no code here can help;
--   * bit-order / command values are from the published protocol, not a capture.
-- If a button does nothing, just LEARN it in the app (Learn mode) — that overrides these.
--
-- Encoding: 38 kHz, Samsung leader 4500/4500 us, bit0 560/560, bit1 560/1690, 32-bit value
-- MSB-first, ~102 ms trailing gap. (See the generator in the commit history / chat.)
return {
  generic = {
    -- learn these in the app, or paste captured hex here for dev seeding
  },

  -- Standard Samsung TV/monitor codeset (GENERATED, UNVERIFIED — see header).
  tv = {
    -- power TOGGLE (0xE0E040BF): one code that flips power. Many Samsung smart monitors (e.g. M5)
    -- ignore the discrete on/off codes and only obey this. Selected via the "Power style" preference.
    power        = "2600460093931237123712371212121212121212121212371237123712121212121212121212121212371212121212121212121212121237121212371237123712371237123712000d05",
    power_on     = "2600460093931237123712371212121212121212121212371237123712121212121212121212123712121212123712371212121212371212123712371212121212371237121212000d05",
    power_off    = "2600460093931237123712371212121212121212121212371237123712121212121212121212121212121212123712371212121212371237123712371212121212371237121212000d05",
    vol_up       = "2600460093931237123712371212121212121212121212371237123712121212121212121212123712371237121212121212121212121212121212121237123712371237123712000d05",
    vol_down     = "2600460093931237123712371212121212121212121212371237123712121212121212121212123712371212123712121212121212121212121212371212123712371237123712000d05",
    mute         = "2600460093931237123712371212121212121212121212371237123712121212121212121212123712371237123712121212121212121212121212121212123712371237123712000d05",
    channel_up   = "2600460093931237123712371212121212121212121212371237123712121212121212121212121212371212121212371212121212121237121212371237121212371237123712000d05",
    channel_down = "2600460093931237123712371212121212121212121212371237123712121212121212121212121212121212121212371212121212121237123712371237121212371237123712000d05",
    play         = "2600460093931237123712371212121212121212121212371237123712121212121212121212123712371237121212121212123712121212121212121237123712371212123712000d05",
    pause        = "2600460093931237123712371212121212121212121212371237123712121212121212121212121212371212123712121212123712121237121212371212123712371212123712000d05",
    stop         = "2600460093931237123712371212121212121212121212371237123712121212121212121212121212371237121212121212123712121237121212121237123712371212123712000d05",
    ff           = "2600460093931237123712371212121212121212121212371237123712121212121212121212121212121212123712121212123712121237123712371212123712371212123712000d05",
    rew          = "2600460093931237123712371212121212121212121212371237123712121212121212121212123712121237121212121212123712121212123712121237123712371212123712000d05",
  },

  -- NO SEED CODES FOR AC — this is a deliberate decision, not an omission.
  --
  -- A TV sends one 32-bit NEC code per button, so codes can be generated from the published
  -- codeset (see `tv` above). An air conditioner does NOT: every press transmits the remote's
  -- ENTIRE STATE. For Samsung that means a 14-byte frame (2 x 7-byte sections), completely
  -- different timings (hdr 690/17844 us, section 3086/8864, bit 586/1432/436), and a
  -- per-section CHECKSUM — and the frame layout differs across AC generations (14-byte vs
  -- 21-byte extended). Any table we generated would be model-specific and unverifiable, and a
  -- wrong AC code is indistinguishable from a right one in the logs: the RM4 still replies
  -- errcode=0, the AC just ignores it.
  --
  -- => Teach your AC with LEARN MODE instead. One code per combination you actually use, keyed
  --    "<mode>_<setpoint>_<fan>" (e.g. "cool_24_auto"), plus "power_off" for Off.
  --    See docs/broadlink-rm4/USER_GUIDE.md, "Teaching an air conditioner".
  ac = {},
}
