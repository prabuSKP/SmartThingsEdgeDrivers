# BroadLink RM4 — Architecture

The whole-driver view: how the pieces fit, who owns what, and how a tap in the SmartThings app
becomes an IR pulse (or a captured code). For the byte-level protocol see
[PROTOCOL_FLOW.md](PROTOCOL_FLOW.md); for the *why* behind the stock-capability model see
[SHIPPING_PLAN-STOCK-CAPS.md](SHIPPING_PLAN-STOCK-CAPS.md).

---

## 1. What it is

A SmartThings **Edge** (hub-local, Lua) driver for the **BroadLink RM4 Mini** Wi-Fi IR blaster.
It controls TVs, ACs, fans and other IR appliances **over the LAN, with no cloud** — the BroadLink
cloud account is not involved. The RM4 protocol is a clean-room port of `python-broadlink`; the
AES-128-CBC it needs is a self-contained pure-Lua implementation (no native crypto on the hub).

- **Package:** `broadlink-rm4` (`config.yml`), permissions `lan` + `discovery`.
- **Scale:** ~1,400 lines of Lua. `init.lua` (~570) is the product layer; `broadlink.lua` (~215)
  + `crypto.lua` + `vendor/aes.lua` (~200) are the protocol/crypto layer; the rest are small.

---

## 2. Device model — one parent, many typed children

```
BroadLink RM4 (LAN parent, profile rm4-hub)         one per physical blaster
   dni = "broadlink-<mac>"
   fields: ip, mac, devtype
   │
   ├── EDGE_CHILD  "Living Room TV"   profile ir-tv       type from key prefix
   ├── EDGE_CHILD  "Bedroom AC"       profile ir-ac
   └── EDGE_CHILD  ...                profile ir-fan / ir-media / ir-generic
        dni = "<parent-dni>:<type>-<name>"
        parent_assigned_child_key = "<type>-<name>"   e.g. "tv-Living Room TV"
        fields: learned codes (code_index, code_<slot>), appliance state (vol_level, ac_*)
```

- The **parent** is the blaster itself: it owns the network identity and the authenticated
  session. It is **not** directly controllable — onboarding creates **only** the parent (no
  auto-child).
- Each **appliance** is an `EDGE_CHILD` of a fixed **type** (`tv` / `ac` / `fan` / `media` /
  `generic`). The type is encoded in `parent_assigned_child_key` (`"<type>-<name>"`) and recovered
  by `appliance_type(device)` — it drives both the profile and the code-slot semantics.
- **Adding an appliance is preference-driven:** on the parent, set a type + name in Settings and
  Save. `info_changed` sees the new `applianceName` and calls `create_child`. (A `momentary` Add
  button was tried first but doesn't render on a LAN parent — see [GAPS.md](GAPS.md) G2.)

Each type maps to a fixed profile of **stock** SmartThings capabilities (no custom capabilities),
so cards render natively:

| Type | Profile | Stock capabilities |
|---|---|---|
| tv | `ir-tv` | switch, audioVolume, audioMute, tvChannel, mediaPlayback, refresh |
| ac | `ir-ac` | switch, thermostatMode, thermostatCoolingSetpoint, airConditionerFanMode, refresh |
| fan | `ir-fan` | switch, fanSpeed, fanOscillationMode, refresh |
| media | `ir-media` | switch, mediaPlayback, mediaTrackControl, tvChannel, refresh |
| generic | `ir-generic` | switch, momentary ×4 (button1..4), refresh |

Every child profile also carries a boolean **`learnMode`** preference; the TV profile adds a
**`powerStyle`** enum (`toggle` default / `discrete`).

---

## 3. Layers — from a tap to a pulse

```
 SmartThings app  (tap a control / Routine / voice)
        │  capability command  e.g. audioVolume.volumeUp
        ▼
 init.lua  capability_handlers[cap][cmd]  →  h_vol_up(...)
        │  resolves a named CODE SLOT, e.g. "vol_up"
        ▼
 action(device, slot, success_thunk)         the fork:
        ├── learnMode ON  → learn_slot()     record into the slot
        └── learnMode OFF → send_slot()  then emit the optimistic event
        ▼
 code_store.get(device, slot)  →  hex        learned first, else codes.lua seed (TV only)
        ▼
 broadlink.lua  get_handle → Device:send_ir → cmd_6a(0x02) → build_packet(0x6a)
        │  rmminib framing, 0x38-byte header + AES payload
        ▼
 crypto.lua / vendor/aes.lua   AES-128-CBC (session key + fixed IV)
        ▼
 cosock UDP  →  RM4 @ <ip>:80  →  reply errcode=0  →  RM4 blasts IR
```

The reverse direction (**reporting state up**) never touches the network: handlers call
`emit_event`, which flows hub → cloud → app. This split is load-bearing — see §7 (seeding).

---

## 4. Module responsibilities

| File | Lines | Responsibility |
|---|---|---|
| `init.lua` | ~570 | **Product layer.** Lifecycle handlers, the capability→slot handler table, the `action`/`send_slot`/`learn_slot` core, child creation, per-type state (`vol_level`, `ac_mode/ac_setpoint/ac_fan`), card **state seeding**, health, scheduled IP refresh. |
| `broadlink.lua` | ~215 | **Protocol.** `Device` object; `build_packet` (0x38 header + checksums + MAC + encrypted payload); `send_packet` (UDP + retries + TX dump + errcode read); `auth` (0x65 login, resets to INITIAL key/iv/id); `cmd_6a` (rmminib framing) → `send_ir`/`enter_learning`/`check_learned`. |
| `discovery.lua` | ~158 | UDP broadcast discovery (limited + subnet-directed), `hello` packet, reply parse (devtype @0x34, MAC @0x3a), and the SmartThings `discovery.handler` that creates one LAN parent per unit. |
| `crypto.lua` | ~41 | Thin byte-array wrapper over the vendored AES; holds BroadLink's fixed `INITIAL_KEY` / `IV`. |
| `vendor/aes.lua` | ~200 | Self-contained pure-Lua AES-128-CBC (verified vs NIST SP 800-38A). |
| `code_store.lua` | ~80 | Per-device code storage as persisted fields (`code_index`, `code_<slot>`); `get()` falls back to `codes.lua`. Guards: `MAX_CODES=40`, `MAX_HEX_LEN=4096`. |
| `codes.lua` | ~56 | Bundled seed codes. **Only `tv`** is populated (a generated Samsung codeset). `ac` is `{}` by design; `fan`/`media` have no table. |
| `utils.lua` | ~57 | Byte-array ↔ string, checksum (seed 0xBEAF), lo/hi, hex helpers. |

---

## 5. Command dispatch — capability → slot → op

Every app control resolves to a **code slot name**, then either sends or learns it. Full table in
[PROTOCOL_FLOW.md §4](PROTOCOL_FLOW.md). The load-bearing patterns:

- **Fixed slots** (TV/fan/media): `vol_up`, `mute`, `channel_up`, `play`, `ff`, `speed_<n>`,
  `oscillate`, … A handler is a one-liner: `action(device, "vol_up", <optimistic event thunk>)`.
- **Power** is special: `power_slot(device, on)` returns the `power` **toggle** slot when the TV's
  `powerStyle` = toggle (default), else `power_on`/`power_off`. Types without the preference
  (media/generic/fan) always use discrete.
- **AC is the whole state.** An AC remote transmits mode+temp+fan on every press, so the slot **is
  the combination**: `ac_key(device, over)` builds `"<mode>_<setpoint>_<fan>"` (e.g.
  `cool_24_auto`) from persisted `ac_mode`/`ac_setpoint`/`ac_fan`, with pending `over`rides.
  `ac_apply` sends that slot and **commits the fields + emits only if the op took effect** (learn,
  or a successful send) — a send with no code commits nothing, so the card snaps back instead of
  stranding the driver on an untaught slot.
- **Generic buttons:** `momentary.push` on `buttonN` → `action(device, "buttonN")`.

`action()` is the single fork point:
```
learnMode ON  → learn_slot(slot)                      (record; no optimistic event)
learnMode OFF → send_slot(slot) and emit(success_thunk)
```

---

## 6. Lifecycle & sessions

- **`discovery.handler`** → creates the LAN parent(s), stashes `{ip,mac,devtype}` in
  `driver.datastore.pending_rm4[dni]`.
- **`device_added(parent)`** → `persist_net`: moves the stashed net fields onto the device. **No
  child is created.**
- **`device_init`** →
  - *parent:* ensure net fields (re-discover if missing), then `get_handle` (login).
  - *child:* `seed_child_state` (§7).
- **`info_changed(parent)`** → on a new `applianceName`, `create_child(type, name)`.
- **Session cache:** `get_handle` authenticates once and caches the `Device` in `handles[rm4.id]`;
  every child of that blaster reuses it. A failed send drops the handle and re-auths once
  (`send_slot`). `auth()` always resets key/iv/id to INITIAL first, so re-login is clean.
- **Scheduled IP refresh:** `call_on_schedule(600, …)` re-discovers each parent by MAC every 10 min
  and updates a changed IP (DHCP drift), dropping the cached handle.

---

## 7. Cross-cutting concerns

- **Per-blaster serialization.** `with_lock(rm4.id, fn)` serializes all `0x6a`/`0x65` traffic for
  one RM4 so two children can't interleave frames (overlapping IR corrupts both). 20 s safety
  timeout, then it proceeds with a warning.
- **Optimistic state.** IR is one-way; the app state is what was *sent*, never confirmed. The
  optimistic event is emitted only on a successful send (never on a learn).
- **Card seeding (display only, never transmits).** Stock attributes start `null` and the app
  renders null as `NaN`/`–`. `seed_child_state` (child `init`) emits sensible defaults **via
  `emit_event` only** — it must never reach `send_ir`. It seeds a scalar only if currently null
  (`get_latest_state`), so restarts don't clobber user state; `supported*` lists are always
  re-emitted (they gate which buttons/pickers the app enables). Values are **placeholders, not
  readings**. *Invariant: a driver restart produces `seeded initial state` lines and zero
  `TX cmd=0x6a` lines.*
- **Health.** A successful send marks the RM4 (and its children) `online`; a final failure or a
  rejected login marks them `offline` with a clear cloud-lock message.
- **Error visibility.** Every packet logs a full `TX` hex dump and the reply `errcode`; a
  non-zero errcode on a send is treated as failure. `LEARN OK` logs the captured blob so a
  mis-timed capture can be decoded (see [EXPECTED_LOGS.md](EXPECTED_LOGS.md) F14).

---

## 8. Key design decisions (and where the rationale lives)

| Decision | Why | Ref |
|---|---|---|
| Stock capabilities + fixed types | Native cards, no custom-capability install; the trade is a fixed type list | [SHIPPING_PLAN-STOCK-CAPS.md](SHIPPING_PLAN-STOCK-CAPS.md) |
| `rmminib` send framing (2-byte length prefix) | devtype `0x520c` is an `rm4mini`; the old RM-Mini format is rejected with `-5` | [GAPS.md](GAPS.md) G6, [PROTOCOL_FLOW.md §3.3](PROTOCOL_FLOW.md) |
| Power **toggle** default for TV | Samsung monitors ignore discrete on/off codes | [USER_GUIDE.md](USER_GUIDE.md) |
| **No AC seed codes** | AC frames are full-state, checksummed, generation-specific, and a wrong one is invisible in the logs (`errcode=0`) | [GAPS.md](GAPS.md), `codes.lua` header |
| Preference-driven add (not a button) | `momentary` doesn't render on a LAN parent | [GAPS.md](GAPS.md) G2 |
| Card seeding on `init` | Kill `NaN`/dashes without ever transmitting | [GAPS.md](GAPS.md) G7 |

---

## 9. Limits (structural, not bugs)

- **One-way IR:** no confirmation, no real readings; cards drift if the physical remote is used.
- **Line-of-sight, one room per blaster.** Two identical devices can't be controlled separately.
- **40 codes/device** — full-range AC (≈180+ combos) can't be *learned*; it needs generated frames.
- **Only TV ships seeds** — everything else is learn-only, so `no code for <type>/<slot>` before
  teaching is expected.
- **Community driver on a reverse-engineered protocol** — a firmware change could alter behavior.
