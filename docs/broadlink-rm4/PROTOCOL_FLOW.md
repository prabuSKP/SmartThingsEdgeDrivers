# BroadLink RM4 — Protocol-Level Flow

How every implemented feature maps down to the BroadLink UDP protocol. This is the
"what actually goes on the wire" companion to the user/testing docs.

Source of truth: `src/broadlink.lua` (protocol), `src/discovery.lua` (discovery),
`src/crypto.lua` + `src/vendor/aes.lua` (AES), `src/init.lua` (command → slot mapping).

---

## 1. The layers

```
 SmartThings app  (tap a control / Routine / voice)
        │  capability command  e.g. audioVolume.volumeUp
        ▼
 init.lua   handler → action(slot) → learn or send
        │  "vol_up"  (a named code slot)
        ▼
 code_store.lua   slot → hex blob  (learned code, else codes.lua seed)
        │  "2600...0d05"
        ▼
 broadlink.lua   Device:send_ir → build_packet(0x6a) → send_packet
        │  0x38-byte header + AES-encrypted payload
        ▼
 crypto.lua / aes.lua   AES-128-CBC (session key + fixed IV)
        ▼
 cosock UDP   →  RM4 @ <ip>:80   →  RM4 blasts IR
```

Everything below the app layer is one of **five protocol operations**: **discovery**,
**login (auth)**, **send IR**, **enter learning**, **check learned**.

---

## 2. Packet anatomy (the command frame)

Every command after discovery uses the same `0x38`-byte (56-byte) header followed by an
AES-encrypted payload. Built in `Device:build_packet(command, payload)`:

| Offset | Bytes | Field | Notes |
|---|---|---|---|
| `0x00`–`0x07` | 8 | Magic | `5a a5 aa 55 5a a5 aa 55` |
| `0x20`–`0x21` | 2 | **Whole-packet checksum** (LE) | computed last, over the whole frame |
| `0x24`–`0x25` | 2 | Device type (LE) | e.g. `0c 52` for devtype `0x520c` |
| `0x26` | 1 | **Command** | `0x65` login · `0x6a` data (send/learn) |
| `0x28`–`0x29` | 2 | Packet counter (LE) | increments per packet |
| `0x2a`–`0x2f` | 6 | MAC | from discovery, copied straight (no reversal — verified) |
| `0x30`–`0x33` | 4 | Device id | zeros before login; real id after |
| `0x34`–`0x35` | 2 | **Payload checksum** (LE) | over the **plaintext** payload |
| `0x38`… | n | **Encrypted payload** | AES-128-CBC, 16-byte aligned |

### Checksum (`utils.checksum`)
Seed `0xBEAF`; add every byte; keep 16 bits (`sum % 0x10000`). Two are computed:
1. **Payload checksum** over the plaintext payload → stored at `0x34`.
2. **Whole-packet checksum** over the entire frame (header + encrypted payload, with
   `0x20/0x21` still zero) → stored at `0x20`.

A wrong checksum → the RM4 **silently drops** the packet (no reply).

### Encryption (`crypto.lua` → `aes.lua`)
- Algorithm: **AES-128-CBC**, no padding (payloads are pre-aligned to 16 bytes).
- **Before login:** BroadLink's fixed `INITIAL_KEY` + fixed `IV`.
- **After login:** the **per-session key** returned by the device, with the **same fixed IV**.
- Only the payload (`0x38+`) is encrypted; the header is plaintext.

---

## 3. The five protocol operations

### 3.1 Discovery — `discovery.scan()` (UDP broadcast, **unencrypted**)

```
HUB ──[ hello, 0x30 bytes, plaintext ]──► 255.255.255.255:80  (and x.y.z.255)
        hello: local IP@0x18, port@0x1c, marker 0x06@0x26, checksum@0x20
RM4 ──[ reply ]──► HUB
        reply: devtype@0x34, MAC@0x3a ; RM4's IP = datagram source
```
- No AES, no session — discovery is the only plaintext exchange.
- The driver reads the **source IP** of the reply (that's the RM4's address) plus `devtype`
  and `MAC` from the payload, dedups by MAC, and creates one LAN parent per unit.

### 3.2 Login / auth — `Device:auth()`, command `0x65`

```
HUB: build_packet(0x65, payload[0x50])           payload: 0x31 filler @0x04-0x12,
     encrypt payload with INITIAL_KEY/IV          flags @0x1e,0x2d, client name @0x30
HUB ──[ 0x65 frame ]──► RM4:80
RM4 ──[ reply ]──► HUB
     errcode @0x22-0x23 (0 = OK)
     decrypt reply[0x38:] with INITIAL_KEY/IV →
        device id   = dec[0x00..0x03]   → stored, used @0x30 on every later packet
        session key = dec[0x04..0x13]   → replaces the key for all later packets
```
- `errcode != 0` → login rejected (often **cloud-locked**). `errcode == 0` proves framing,
  checksums, MAC order, and AES-encrypt are all correct (the device decrypted our payload).
- Success is cached in `handles[rm4.id]`; reused by every later command (no re-login per press).

> **RM4 payload framing (`rmminib`) — the format that actually works.** Every `0x6a`
> sub-command below is wrapped by `Device:cmd_6a(command, data)` in the **RM4 (`rm4mini` →
> `rmminib`) format**: a **2-byte little-endian length** (`#data + 4`) + a **4-byte
> little-endian sub-command**, then `data`, zero-padded to ×16 —
> `python-broadlink`'s `rmminib._send: struct.pack("<HI", len(data)+4, command) + data`.
> The older RM-Mini (`rmmini`) format omits the 2-byte length prefix; sending *that* to an RM4
> (devtype `0x520c` is `rm4mini`) makes the device read the sub-command byte as the length and
> reject the packet with **error `-5`** (EXPECTED_LOGS **F5b**). This was the real cause of
> "login works, sends never control the device."

### 3.3 Send IR — `Device:send_ir(ir_bytes)`, command `0x6a`, sub-command `0x02`

```
payload = { len_lo, len_hi, 0x02, 0x00, 0x00, 0x00 } .. ir_bytes .. zero-pad to x16
          len = #ir_bytes + 4   (2-byte LE)
HUB: build_packet(0x6a, payload) with SESSION key
HUB ──[ 0x6a frame ]──► RM4:80
RM4 ──[ reply, errcode @0x22-0x23 ]──► HUB   (errcode 0 = "received & emitted"; ≠0 = rejected,
                                              never "appliance obeyed")
RM4 blasts the IR waveform
```
- The `ir_bytes` are the captured/seed blob: `0x26`, repeat, length (LE), pulse durations in
  ~30.5 µs ticks, `…0d05` trailing gap.
- `0x02` (a 4-byte LE field) is the "send this IR data" sub-command; the leading 2-byte length
  is `#ir_bytes + 4`.
- `send_ir` reads the reply's `errcode` and **fails on non-zero** — a rejected send drops the
  session and re-logs in once (§5.4).

### 3.4 Enter learning — `Device:enter_learning()`, command `0x6a`, sub-command `0x03`

```
payload = { 0x04, 0x00, 0x03, 0x00, 0x00, 0x00 } .. zero-pad to 16   (len = 4)
HUB ──[ 0x6a frame, SESSION key ]──► RM4:80      → RM4's IR receiver starts listening
```

### 3.5 Check learned — `Device:check_learned()`, command `0x6a`, sub-command `0x04`

```
payload = { 0x04, 0x00, 0x04, 0x00, 0x00, 0x00 } .. zero-pad to 16   (len = 4)
HUB ──[ 0x6a frame ]──► RM4:80
RM4 ──[ reply ]──► HUB
     errcode @0x22-0x23 (0 = a code is ready; non-zero = "not ready yet")
     decrypt reply[0x38:] with SESSION key →
        payload length = dec[0x00..0x01] (LE)
        learned IR bytes = dec[0x06..(len+2)]   (after the 2-byte length + 4-byte command echo)
```
- Polled ~once/second for ~15 s after `enter_learning`; first non-zero result is stored.

---

## 4. Feature → slot → protocol mapping

Every app control resolves to a **code slot** name, then either **sends** it (`0x6a`/`0x02`)
or **learns** it (`0x6a`/`0x03`+`0x04`) depending on the device's **Learn-mode** preference.

| App capability command | Code slot | Protocol op (normal / learn mode) |
|---|---|---|
| `switch.on` / `switch.off` | `power` (toggle) if **Power style**=toggle, else `power_on` / `power_off` | send `0x6a` / learn |
| `audioVolume.volumeUp` / `volumeDown` | `vol_up` / `vol_down` | send / learn |
| `audioVolume.setVolume(n)` | `vol_up` or `vol_down` (one step toward n) | send / learn |
| `audioMute.*` | `mute` | send / learn |
| `tvChannel.channelUp` / `channelDown` | `channel_up` / `channel_down` | send / learn |
| `mediaPlayback.play/pause/stop/fastForward/rewind` | `play/pause/stop/ff/rew` | send / learn |
| `mediaTrackControl.nextTrack` / `previousTrack` | `next` / `prev` | send / learn |
| `thermostatMode.setThermostatMode(m)` / cool/heat/auto | `"<mode>_<setpoint>_<fan>"` | send / learn |
| `thermostatMode.off` | `power_off` | send / learn |
| `thermostatCoolingSetpoint.setCoolingSetpoint(t)` | `"<mode>_<t>_<fan>"` | send / learn |
| `airConditionerFanMode.setFanMode(f)` | `"<mode>_<setpoint>_<f>"` | send / learn |
| `fanSpeed.setFanSpeed(n)` | `speed_<n>` | send / learn |
| `fanOscillationMode.setFanOscillationMode(m)` | `oscillate` | send / learn |
| `momentary.push` (generic child, `buttonN`) | `buttonN` | send / learn |
| **preference Save** on the parent (`applianceName` changes) | — | **no protocol op** — `info_changed` creates a typed child device (app-level) |
| **`init` lifecycle** on a child | — | **no protocol op** — `seed_child_state` emits placeholder attributes so the card isn't blank (see below) |
| `refresh` (parent) | — | **discovery** (3.1) + **login** (3.2) |
| `refresh` (child) | — | **login** (3.2) if not cached |

**Seeding note (app-only, never transmits):** SmartThings attributes start `null`, and the app
renders `null` as `NaN`/`–`. IR is one-way, so nothing ever reports state back and the attributes
would stay null forever. `seed_child_state` (child `init`) fills them via **`emit_event` only** —
it must **never** reach `send_ir`/`cmd_6a`. It seeds an attribute only when currently null
(`get_latest_state`), so restarts don't clobber user-set values; the `supported*` lists are always
re-emitted because they gate which transport buttons / dropdown entries the app enables. The
values are **optimistic placeholders, not readings**. *Acceptance check: a driver restart produces
the `seeded initial state` lines and **zero** `TX cmd=0x6a` lines.*

**AC note:** the AC's slot is the *full state* `mode_setpoint_fan` (e.g. `cool_24_auto`) — because
an AC remote transmits its entire state per button. `ac_apply()` builds the slot from the
**proposed** values and commits `ac_mode`/`ac_setpoint`/`ac_fan` (and emits the attribute) **only
if the op took effect**: on a learn (the selection defines the slot being taught, so the card
updates — an AC-only exception) or on a successful send. A send with **no code** commits nothing,
so the card snaps back and the driver stays on the last working combination instead of stranding
`ac_key` on a slot nobody taught. **No AC codes ship** (`codes.ac = {}`): a
Samsung AC frame is 14 bytes / 2×7-byte sections with different timings and a per-section
checksum, and the layout varies by AC generation, so a generated table would be model-specific
and unverifiable — and a wrong AC code is indistinguishable from a right one in the logs
(`errcode=0`, the AC simply ignores it). ACs are taught with Learn mode, one code per combo plus
`power_off`. **Only the `tv` type ships seed codes**; `fan`/`media` have no seed table at all and
`generic`/`ac` are empty, so `no code for <type>/<slot>` before learning is expected.

**Power-style note (TV):** the TV profile has a `powerStyle` preference (`toggle` default /
`discrete`). With `toggle`, both `switch.on` and `switch.off` send the single `power` slot
(Samsung toggle `0xE0E040BF`) — most Samsung smart monitors (e.g. M5) ignore the discrete
codes and only obey the toggle. With `discrete`, they send `power_on`/`power_off`. Types
without the preference (media/generic/fan) always use discrete `power_on`/`power_off`.

---

## 5. End-to-end flows

### 5.1 Onboarding (Scan nearby → controllable device)
```
Scan nearby
  → discovery.scan: broadcast hello → RM4 reply → parse devtype/MAC/IP        [3.1]
  → try_create_device(LAN parent "BroadLink RM4")
  → lifecycle added:  persist ip/mac/devtype   (no child auto-created)
  → lifecycle init (parent): get_handle → Device.auth (0x65)                  [3.2]
  → "login OK" → session cached ; parent online
  → user later: Settings → type + name → Save → info_changed → create typed child
```

### 5.2 Sending a code (e.g. tap Volume Up on a TV)
```
audioVolume.volumeUp
  → action(device,"vol_up")  (learnMode = off)
  → send_slot: code_store.get(device,"vol_up") → hex  (learned, else codes.tv seed)
  → get_handle (cached session)
  → with_lock(rm4.id):  Device:send_ir(hex) → cmd_6a(0x02) → build_packet(0x6a) → UDP   [3.3]
  → reply errcode=0 → set_health(online) → emit optimistic volume event
       (errcode≠0 → send_ir fails → drop session, re-login once, retry [5.4])
```

### 5.3 Learning a code (Learn mode ON → tap a control → press remote)
```
learnMode = true ; user taps "Volume Up"
  → action(device,"vol_up") → learn_slot
  → with_lock(rm4.id):
        Device:enter_learning (0x6a/0x03)                                     [3.4]
        loop ~15×:  sleep 1s ; Device:check_learned (0x6a/0x04)               [3.5]
                    first non-empty → code_store.save(device,"vol_up",hex)
  → "LEARN OK: 'vol_up' (N bytes)"   (no send, no optimistic event)
```

### 5.4 Session recovery (RM4 rebooted mid-use, or send rejected)
```
send_slot → Device:send_ir → fails: 3 timeouts ("no reply") OR reply errcode≠0
  → drop cached handle ; Device:auth (0x65) again                            [3.2]
       (auth resets key→INITIAL, iv→fixed, id→0 first, so re-login is clean)
  → on success: retry Device:send_ir once                                     [3.3]
  → still failing → set_health(offline) ; "send failed for <slot>"
```

### 5.5 Scheduled IP refresh (DHCP drift) — every 10 min
```
call_on_schedule(600):
  for each parent with an ip:
     discovery.scan (unicast/broadcast) → match by MAC                        [3.1]
     if reply IP != stored IP: set_field("ip", newip) ; drop cached handle
```

---

## 6. What's encrypted, what isn't, and why it matters

| Exchange | Encrypted? | Key |
|---|---|---|
| Discovery hello/reply | ❌ plaintext | — |
| Login `0x65` request + reply body | ✅ | INITIAL key/IV |
| Send / learn / check (`0x6a`) request + reply body | ✅ | **session** key + fixed IV |

Consequences that show up in behavior:
- **Discovery can succeed even if AES is broken** (it's plaintext) — the first place a crypto
  bug bites is **login**.
- A successful **`login OK`** validates our **framing, both checksums, MAC order, and
  AES-with-the-INITIAL-key** — but *not* the session key or the `0x6a` payload format. The
  INITIAL key is a fixed public constant, so the login request always decrypts on the device
  regardless of how we handle the session. The **first** thing that exercises the session key
  and the `0x6a` payload shape is the **first send** — which is exactly why a wrong send format
  shows up as "login OK, every send rejected `-5`" (the `rmminib` framing bug, now fixed).
- A `0x6a` reply with **`errcode=0`** confirms the RM4 **received and emitted** — never that the
  appliance reacted (IR is one-way); that's why SmartThings state is optimistic. A **non-zero**
  errcode means the RM4 received the packet but **refused to emit** (e.g. `-5` for the wrong
  payload framing) — `send_ir` treats that as a failure.

---

## 7. Reliability mechanisms (in the protocol path)

- **Retries:** `send_packet` re-sends the *same* frame up to 3× on no-reply (UDP is lossy),
  keeping the packet counter stable across retries.
- **Per-RM4 lock:** `with_lock(rm4.id, …)` serializes all `0x6a`/`0x65` traffic for one blaster
  so two children can't interleave frames (overlapping IR would corrupt both).
- **One-shot re-login:** a failed send drops the session and re-runs `auth` once before giving
  up (§5.4).
- **Health:** send success → `online`; final failure or cloud-locked login → `offline` for the
  RM4 and its children.
