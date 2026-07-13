# CLAUDE.md — BroadLink RM4 driver

Working notes for this directory. Read this first; deep detail is in `../../../docs/broadlink-rm4/`.

## What this is
SmartThings **Edge** (hub-local, Lua) driver for the **BroadLink RM4 Mini** Wi-Fi IR blaster.
Controls TVs / ACs / fans / media / generic IR appliances over the **LAN, no cloud**. RM4 protocol
is a port of `python-broadlink`; AES-128-CBC is pure Lua (`src/vendor/aes.lua`). Package key
`broadlink-rm4`; permissions `lan` + `discovery` (`config.yml`).

## Mental model (see docs/broadlink-rm4/ARCHITECTURE.md for the full picture)
- **One LAN parent per blaster** (`profile rm4-hub`, dni `broadlink-<mac>`, fields `ip/mac/devtype`)
  + **typed `EDGE_CHILD` appliances** (`tv/ac/fan/media/generic`), each a fixed profile of **stock**
  capabilities. Onboarding creates **only the parent**; appliances are added by setting a
  type+name in the parent's Settings and Saving (`info_changed` → `create_child`).
  Note: all five types work in code, but the add-menu (`applianceType` enum in `rm4-hub.yml`)
  currently exposes only **tv / ac / generic** — `fan`/`media` are retained but hidden.
- Type is encoded in `parent_assigned_child_key = "<type>-<name>"` and read by `appliance_type()`.
- A tap → `capability_handlers[cap][cmd]` → resolves a **code slot** → `action(device, slot, thunk)`:
  `learnMode` ON = record the slot, OFF = send it then emit the optimistic event.
- `code_store.get()` returns the **learned** code first, else the `codes.lua` seed. `send_ir` →
  `cmd_6a(0x02)` → UDP to `<ip>:80`. Reporting state up uses `emit_event` and **never** hits the net.

## File map
```
src/init.lua        product layer: lifecycle, capability→slot handlers, action/send/learn,
                    child mgmt, per-type state, seed_child_state, health, IP refresh (~570 lines)
src/broadlink.lua   protocol: Device, build_packet, send_packet, auth (0x65), cmd_6a/send_ir/learn
src/discovery.lua   UDP broadcast discovery + LAN-parent creation
src/crypto.lua      byte-array wrapper over AES; BroadLink INITIAL_KEY/IV constants
src/vendor/aes.lua  pure-Lua AES-128-CBC (NIST-verified)
src/code_store.lua  per-device code storage (code_index, code_<slot>); MAX_CODES=40
src/codes.lua       bundled seeds — ONLY `tv` (Samsung); `ac={}`, no fan/media table
src/utils.lua       byte/checksum(0xBEAF)/hex helpers
profiles/*.yml      rm4-hub, ir-tv, ir-ac, ir-fan, ir-media, ir-generic
```

## Invariants — do not break these
1. **Seeding never transmits.** `seed_child_state` (child `init`) emits display-only defaults via
   `emit_event`. It must never reach `send_ir`/`cmd_6a`. **Check:** a driver restart shows
   `seeded initial state …` lines and **zero** `TX cmd=0x6a` lines.
2. **RM4 send framing is `rmminib`** (2-byte LE length + 4-byte LE sub-cmd + data, pad 16), built
   by `cmd_6a`. The older RM-Mini format (`{0x02,0x00,0x00,0x00}+ir`, no length prefix) is rejected
   by the RM4 with `errcode=65531` (`-5`). This was THE bug that made every send silently fail.
3. **`errcode=0` is the send pass signal**, logged on the reply line. A reply alone is not success;
   `send_ir` fails on any non-zero errcode.
4. **AC slot = full state.** `ac_apply` builds `<mode>_<setpoint>_<fan>` from proposed values and
   **commits fields + emits only on a successful op** (learn, or send with a code). Never persist
   an AC selection before the send — that caused a setpoint-desync bug.
5. **`auth()` resets key/iv/id to INITIAL first** — re-login on a live handle otherwise replies
   `-7` "control key expired".
6. **Only `tv` ships codes.** `no code for ac/… | fan/… | generic/…` before learning is **expected**.
7. **Optimistic state only** — IR is one-way; never claim a reading. `LEARN OK` proves *a* capture,
   not the *right* one (logs the hex so it can be decoded — EXPECTED_LOGS F14).

## Local verification (no hub) — this is how everything here is tested
Lua 5.3.6 + the Edge `lua_libs` are on this Windows box (see the `local-lua-test-env` memory):
```
LUA=C:/Users/s.chatakonda/Edge/edge-test-env/lua/lua.exe
LL=C:/Users/s.chatakonda/Edge/edge-test-env/lua_libs   # package.path: LL/?.lua;LL/?/init.lua
```
- **Parse check:** `"$LUA" -e "assert(loadfile('src/init.lua'))"` (loadfile compiles without running requires).
- **Probe a capability constructor** before emitting it: `require "st.capabilities"` then call it;
  note some enums are NOT validated at construction (`airConditionerFanMode.fanMode` is a free
  string), so introspect `.schema` when unsure.
- **Drive real handlers** by stubbing `st.driver` to capture `opts`, then call
  `opts.capability_handlers[cap.ID][cmd.NAME](driver, mockDevice, {args=…})` with a mock device
  (`get_field/set_field/get_latest_state/emit_event/get_parent_device`) and a mock `broadlink` that
  counts `send_ir`. This is how seeding / ac-desync / learn-logging were verified offline.
- `src/test/offline_crypto_test.lua` and `offline_code_store_test.lua` are the committed suites.
- The `emit()` helper wraps `emit_event` in `pcall`, so a bad attribute constructor is **silent** —
  always verify names against `lua_libs`, don't trust "no crash".

## Deploy (needs a hub) — see the `smartthings-cli-package-install` memory
```
smartthings edge:drivers:package . --install -C <channelId> -H <hubId>
```
One command = build+upload+install. Watch `smartthings edge:drivers:logcat --hub-address <ip>`;
all lines are tagged `[BroadLink]`, logged with `hub_logs=true`.

## Git / push (see the `git-push-environment` memory)
This working dir is **not a git repo**. To push: sparse-clone the fork
(`snehith-kumar/SmartThingsEdgeDrivers`, no upstream write access → 403), copy files in, commit,
push to a new branch, PR upstream. Corp proxy `HTTPS_PROXY=http://10.112.1.184:8080` (git in the
Bash tool has it; PowerShell doesn't). `.gitignore` ignores `docs/` → `git add -f`. Full clones hit
the Windows 260-char path limit → use `--sparse`.

## Docs (docs/broadlink-rm4/)
- **ARCHITECTURE.md** — whole-driver structure (start here)
- **PROTOCOL_FLOW.md** — byte-level: packet anatomy, 0x65/0x6a, capability→slot map
- **USER_GUIDE.md** — end-user: adding appliances, Learn mode, AC teaching, power style
- **TESTING.md** — install + on-hardware test procedure & pass criteria
- **EXPECTED_LOGS.md** — happy-path log samples + failure signatures (F1–F14)
- **GAPS.md** — findings from real-device testing (G1–G7), dated; records the -5 and NaN fixes
- **SHIPPING_PLAN-STOCK-CAPS.md** — the implemented design + rationale
- **SHIPPING_PLAN.md**, **END_USER_EXPERIENCE.md** — the *alternative* custom-caps design (NOT built)

## Conventions
- All logs: `log.*_with({ hub_logs = true }, "[BroadLink] …")`.
- Bytes are 1-indexed Lua arrays; convert to/from strings only at the socket (`utils`).
- `handles[rm4.id]` = cached authed session; `locks[rm4.id]` = per-blaster send lock.
- When you change behavior, update the matching doc in the same pass — the docs are kept in lockstep.
