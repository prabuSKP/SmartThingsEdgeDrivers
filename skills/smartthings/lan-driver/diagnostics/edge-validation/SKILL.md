---
name: edge-validation
description: >
  Mandatory pre-handover validation gate for generated SmartThings Edge LAN/bridge drivers.
  Run this BEFORE telling the user a driver is ready: Lua syntax check (luac -p), banned-pattern
  grep (non-Edge libs, hardcoded IPs, nonexistent SDK calls), profile/mapper parity, scope check,
  and the mock-server / hub install functional test. Use whenever a driver has been generated or
  edited, or when the user asks to "package", "validate", or "ship" a driver.
---

# Edge Driver Validation Gate

A generated driver is **not done** until it passes this gate. The recurring failure mode (a new
bug per generation: empty `scheme` → `localhost`, datastore queue never persisted, unclosed
`log.info_with(`, full catalog when one device was asked for) is exactly what these checks catch.
Run all five stages from the driver root and **report each result to the user**. Do not declare a
driver ready while any stage fails.

## Quick start — one command (`run-gate.sh`)

Run the whole scriptable gate (Stages 1, 1b, 1c, 1c(2), 2, 2b, 3, 6) with a single pass/fail:

```bash
<skills>/smartthings/lan-driver/diagnostics/edge-validation/scripts/run-gate.sh <driver-dir>
# exit 0 = all scriptable stages passed   (Stage 5 hub install still required for full sign-off)
# exit 1 = one or more stages failed → driver is NOT production-grade; do not hand off
# exit 2 = usage/path error → NOTHING was validated; treat as failure
```

This is the artifact an **enforcement hook** should call after generation — block handover unless
exit is 0. `run-gate.sh` is fail-closed: a bad path or an empty `src/` exits **2**, never a false
"OK". It is verified to **fail** a known-broken driver (the v40 `driver.open(...)` /
`windowShadeLevel.setLevel` / hardcoded-IP build) and **pass** the production reference driver
(`drivers/Unofficial/fibaro-hc2`).

> **Invocation contract (important).** Every `check-*.js` script accepts **either a directory
> (walked for `.lua`) or explicit file paths**, and **fails (exit ≥1) when zero files are
> scanned** — so handing a script a directory can never silently pass. (Earlier versions
> `continue`d past a directory arg and printed "OK", or crashed with `EISDIR`; both are fixed.)
> If the compile stage prints `WARN: no luac/lua on PATH`, install a Lua to enable it — the JS
> nil-linter covers the most common load failures but is not a full compiler.

The stages below document each check individually (what it catches and how to read its output);
`run-gate.sh` simply runs them in order with the correct arguments.

## Stage 1 — Lua syntax (`luac -p`)

Every `.lua` file must compile. A single unclosed paren or forward-reference fails the package.

```bash
fail=0
while IFS= read -r f; do
  luac -p "$f" 2>&1 || { echo "SYNTAX FAIL: $f"; fail=1; }
done < <(find src -name '*.lua')
[ "$fail" -eq 0 ] && echo "Stage 1 OK: all Lua compiles" || echo "Stage 1 FAILED"
```

If `luac` is unavailable, use any Lua: `lua -e "assert(loadfile('src/file.lua'))"`.

**No Lua toolchain installed?** Use a pure-JS Lua VM under Node (no system privileges needed).
`fengari` is Lua 5.3; this parses+compiles each file without executing it (the `luac -p` equivalent):

```bash
npm install fengari   # once, in a scratch dir
node -e '
const fs=require("fs"),{lua,lauxlib,to_luastring}=require("fengari");
let bad=0;
for(const f of process.argv.slice(1)){
  const L=lauxlib.luaL_newstate();
  const st=lauxlib.luaL_loadstring(L,to_luastring(fs.readFileSync(f,"utf8")));
  if(st!==lua.LUA_OK){console.log("SYNTAX FAIL "+f+": "+lua.lua_tojsstring(L,-1));bad++;}
}
console.log(bad?(bad+" FAILED"):"all Lua compiles");process.exit(bad?1:0);
' $(find src -name '*.lua')
```

Caveat: this is a **syntax/compile** check (like `luac -p`) — it does not resolve `st.*` requires or
validate runtime behavior. Lua 5.3 vs the hub's 5.4 differ only in rarely-used syntax; for driver
code the result matches `luac`. Stage 5 is what proves runtime correctness.

## Stage 1b — Runtime-nil lint (CATCHES WHAT luac -p MISSES)

The most common runtime-only failures are **valid syntax** (so Stage 1 / `luac -p` passes them), and
the crash is swallowed by the `pcall` around sync/poll — so the **bridge comes online but no child
devices are ever created**. The shipped linter `scripts/check-lua-nils.js` (pure Node, no deps)
catches all three classes. It has been verified to flag the real generator bugs below while producing
**zero false positives** on the working reference driver.

```bash
node "$(dirname "$0")/scripts/check-lua-nils.js" $(find src -name '*.lua')
# or with an explicit path to this skill's script:
node <skills>/smartthings/lan-driver/diagnostics/edge-validation/scripts/check-lua-nils.js $(find src -name '*.lua')
```

The three classes it flags (each one ⇒ `attempt to call/index a nil/boolean value` at runtime):

1. **FORWARD-REF** — a `local function A` calls a `local function B` defined **later** in the same
   file. A `local` is only visible after its declaration, so the earlier call resolves to a nil
   global. (Seen in v30: `enqueue_child_create`; v31: `emit_child_state`.) Fix: move B above A.
   Enforces the ordering rule in `templates` (#12) and `hub-event-sync` (§0).
2. **UNDEFINED-CALL** — a bare `name(...)` where `name` is **defined nowhere in the file** and isn't a
   Lua builtin (i.e. a helper that lives in another module but was called unqualified). (Seen in v33:
   `has_action(...)` in `sync.lua`, where `has_action` is only a local in `mapper.lua`.) Fix: define
   the helper in this file, or call it qualified (`mapper.has_action` / `utils.has_action`).
3. **PCALL-MISUSE** — the **first** variable of `local A, … = pcall(…)` is later indexed/called as a
   table (`A.x`, `A:m()`, `A[…]`). `pcall`'s first return is always the OK **boolean**; the real value
   is the *second* return. (Seen in v33: `local bootstrap = pcall(bootstrap_bridge,…)` then
   `bootstrap.adapter`.) Fix: `local ok, bootstrap, err = pcall(...)` and guard on `ok`.

A header comment claiming "all locals defined before use" / "ordered correctly" is **not** proof —
this lint is the proof. Re-run until it prints `clean`.

## Stage 1c — Driver construction / SDK-API check (CATCHES FABRICATED APIs)

`init.lua` must build the driver with the **real** SmartThings Edge constructor. A hallucinated
Driver API is **valid syntax** (Stage 1 passes) but throws at **module load on the hub** — the driver
never starts, so **discovery never runs and the hub is never discoverable** (no bridge to add). The
shipped check `scripts/check-driver-api.js` (pure Node) enforces the supported shape.

```bash
node <skills>/smartthings/lan-driver/diagnostics/edge-validation/scripts/check-driver-api.js src/init.lua
```

The ONLY supported construction (what v312 and the reference use):

```lua
local Driver = require "st.driver"
local my_driver = Driver("my-driver-name", {     -- the require'd value, CALLED with (name, opts)
  discovery = discovery.discover,                -- a FUNCTION (driver, opts, should_continue)
  lifecycle_handlers = { added=…, init=…, removed=…, infoChanged=… },
  capability_handlers = commands.capability_handlers,
  supported_capabilities = { capabilities.switch, … },
})
my_driver:run()                                  -- Stage 2 asserts this (see below)
```

What the check flags (all seen in v34, which crashed at load → hub undiscoverable):

1. **`<driver>.open(…)` / `.new(…)` / `.init(…)` / `.create(…)`** on the `require "st.driver"` value —
   `st.driver` has **no such methods**; it is the constructor itself. (v34: `driver.open({…})` → `nil`.)
2. **No `Driver("<name>", { … })` constructor call** — the driver is never built the supported way.
3. **`discovery = { … }`** — `discovery` must be a **function**, not a table. As a table it is never
   invoked, so discovery never fires. (v34 wrapped it as `discovery = { poll=…, handler=… }`.)
4. **Fabricated option keys** at the top level — `driver_init`, `device_lifecycle`, `on_install`,
   `preference_change_handler`, `disconnected_handler`, `init_handler`, `poll`, `handler`. The real
   opts are `discovery`, `lifecycle_handlers`, `capability_handlers`, `supported_capabilities`,
   `sub_drivers`. (Same family as the banned `driver:get_device_by_dni()` — invented SDK surface.)

Re-run until it prints `Driver construction OK`.

### Stage 1c (part 2) — Capability command names

Same failure family, different surface: a `capability_handlers` table that references a **command that
does not exist on the capability** crashes at **module load** (it's a key in a table literal evaluated
when the handler module is `require`d → the whole driver fails to load → discovery never runs → hub
undiscoverable). Valid syntax, so Stage 1 passes it. The shipped check enforces real command names:

```bash
node <skills>/smartthings/lan-driver/diagnostics/edge-validation/scripts/check-capability-commands.js $(find src -name '*.lua')
```

The classic miss is **`windowShadeLevel`**: its command is **`setShadeLevel`**, NOT `setLevel`
(seen in v34 *and* v35 — `capabilities.windowShadeLevel.commands.setLevel.NAME` → `nil.NAME` →
`attempt to index a nil value (field 'setLevel')` at load). Correct command names for the common
actuator capabilities:

| Capability | Command(s) |
|---|---|
| `switch` | `on`, `off` |
| `switchLevel` | `setLevel` |
| `windowShade` | `open`, `close`, `pause` |
| **`windowShadeLevel`** | **`setShadeLevel`** ← not `setLevel` |
| `colorControl` | `setColor`, `setHue`, `setSaturation` |
| `colorTemperature` | `setColorTemperature` |
| `lock` | `lock`, `unlock` |
| `refresh` | `refresh` |

Re-run until it prints `capability commands OK`.

## Stage 2 — Banned-pattern grep

These patterns are defects in an Edge LAN driver. Each must return **no matches** in `src/`.

```bash
# Non-Edge / blocking libraries — not available or unsafe on the hub runtime
grep -rn 'require *["'\'']socket.http["'\'']\|require *["'\'']ltn12["'\'']' src/

# Cloud discovery + hardcoded addresses (must be preference-driven, never baked in)
grep -rnE 'find\.fibaro\.com|([0-9]{1,3}\.){3}[0-9]{1,3}' src/

# Nonexistent SDK method — Driver has NO get_device_by_dni (iterate get_devices() instead)
grep -rn 'get_device_by_dni' src/

# Nonexistent cosock member — there is NO `cosock.sleep`. sleep lives on cosock.socket.
# `cosock.sleep(n)` → nil → crash at startup (BACKOFF, bridge never loads). Use socket.sleep(n).
grep -rn 'cosock\.sleep' src/

# Hand-rolled periodic loop in init.lua — use driver:/device.thread:call_on_schedule instead
grep -rn 'cosock\.spawn' src/init.lua

# Constructor wrapped in pcall (driver/api .new must not be pcall-wrapped at module load)
grep -rnE 'pcall\([a-zA-Z_.]+\.new' src/

# init.lua MUST start the event loop with <driver>:run() — POSITIVE assertion (most robust).
# Without it the driver loads but never runs: discovery + lifecycle handlers never fire, so the
# BRIDGE DEVICE IS NEVER CREATED ("bridge never appears" / "discovery does nothing"). This is valid
# syntax, so luac -p / Stage 1 passes it. The usual culprit is `return <driver>` instead of `:run()`.
grep -q ':run()' src/init.lua || echo "FAIL: src/init.lua never calls <driver>:run() — driver will load but never start"
grep -rniE 'return +[a-z_]*driver\b' src/init.lua   # case-INSENSITIVE: catches `return fibaroDriver`, `return my_driver`, etc.

# Empty-string scheme trap (": or ''" → "" is truthy in Lua)
grep -rn 'scheme or "http"\|scheme or "https"' src/

# C/JS-style line comments — Lua comments are `--`, NOT `//`. `//` is integer floor-division, so a
# line-leading `//` is a SYNTAX ERROR. If it lands in init.lua the driver never loads and NO device
# card appears during the scan (v42). luac -p catches it, but this grep catches it WITHOUT a Lua
# toolchain. Scan stripped source so a legitimate `://` inside a URL string never false-positives.
for f in $(find src -name '*.lua'); do
  node <skills>/.../scripts/lua-strip.js "$f" | grep -nE '^[[:space:]]*//' && echo "FAIL: $f has // comments (use --)"
done
```

Any hit → fix before shipping. (Illustrative IPs inside comments/docs are fine in skills, **never**
in generated `src/`.) `run-gate.sh` runs all of the above, including the `//`-comment guard.

## Stage 3 — Profile / mapper / capability parity

Every profile must have a mapper rule, every rule must point at a profile that exists, and every
emitted capability must be declared. No orphans either direction.

```bash
# Profiles declared on disk
ls profiles/*.yml | xargs -n1 basename | sed 's/\.yml$//' | sort > /tmp/profiles.txt
# Profiles referenced by the mapper
grep -rhoE 'fibaro-[a-z-]+' src/fibaro/mapper.lua | sort -u > /tmp/mapper_refs.txt

echo "--- profiles with NO mapper rule (orphan profile) ---"
comm -23 /tmp/profiles.txt /tmp/mapper_refs.txt
echo "--- mapper rules pointing at a MISSING profile ---"
comm -13 /tmp/profiles.txt /tmp/mapper_refs.txt
```

Both lists must be empty (allowing for the bridge profile and `-metered` variants). A rule pointing
at a missing profile is a 422 at package time; an orphan profile is over-generation.

## Stage 4 — Scope check

Match the output to what the user asked for.

- If the user named **specific device types** ("a light", "blinds"): `profiles/` and the mapper must
  contain **only** those kinds (plus the bridge). There must be **no `*-default` catch-all** and the
  mapper must `return nil` for out-of-scope devices.
- Only when the user asked for **"all devices" / a full integration** may the full catalog + the
  `-default` catch-all appear.
- **Red flag:** the generated `src/` is byte-for-byte identical to the reference driver. That means
  the catalog was cloned, not scoped — re-scope `mapper.lua`, `profiles/`, `supported_capabilities`,
  and `config.yml` to the request. (Quick check: `diff -rq src <reference>/src`.)

## Stage 5 — Functional install test

Syntax-clean is not the same as working. Package and install to a hub (or the mock server) and
confirm a child device is actually created — the "maps but doesn't create" class of bug only shows
here.

```bash
# Package + assign + install in one shot (see cli-control for hub/channel selection)
smartthings edge:drivers:package . --channel <channel-id> --hub <hub-id>
smartthings edge:drivers:installed --hub <hub-id> --json   # confirm the driver is present
# then in the app / via logcat, confirm: bridge appears once, child devices are created
smartthings edge:drivers:logcat --all --hub-address <hub-ip> --log-level info
```

Pass criteria: bridge appears **exactly once**, the requested child device(s) are created, commands
and refresh work. See `cli-control` for the full packaging/selection flow and `edge-log-analysis`
for reading the logcat output.

## Stage 6 — Golden-reference structural diff (CATCHES CROSS-FILE CONTRACT DRIFT)

Single-file checks (Stages 1b/1c) cannot see a mismatch **between** two modules — e.g. a
`utils.labeled_socket_builder` whose arity/return-shape no longer matches how `lunchbox/rest.lua`
calls it (v41: builder was `function(sock)` → `client.socket` became the host *string* →
`rest.lua:52 attempt to call a nil value (method 'send')`, so the bridge never talked to the hub),
or a missing `fibaro_finder.lua` (v40). Both files compile and lint clean individually; the defect
is only visible when wired together — historically only at Stage 5 on real hardware.

`scripts/check-golden-structure.js` compares the generated driver's **infrastructure** against the
proven reference driver and flags drift **before** the hub:

```bash
node <skills>/.../scripts/check-golden-structure.js <golden-reference-dir> <generated-dir>
# default golden reference: skills/vendors/fibaro/reference-driver
```

It is deliberately **scope-aware** so it never fights the "generate only requested device kinds"
rule:

- Compares only `src/**/*.lua` (infrastructure modules, identical across every scoped driver) —
  **never** `profiles/`, the mapper RULE table, or which children exist.
- Compares each module's **exported function surface** (`T.name(...)` / `T.name = function(...)` /
  `T:name(...)`), not local helpers — a benign internal refactor does not trip it.
- One-directional superset: every reference src file must be present, and every reference export
  must exist with **matching arity**; extra files/exports in the generated driver are allowed.

Verified: **passes** the reference and a legitimately scoped copy (profiles removed); **fails** v41
(`utils.lua export 'labeled_socket_builder' arity 2 != reference 3`) and a driver missing
`fibaro_finder.lua`. `run-gate.sh` runs this automatically for Fibaro drivers (config/profiles
detect the vendor); for other vendors, pass a matching `--golden` reference or it is skipped.

## Handover checklist (report this back)

```text
[ ] run-gate.sh <driver-dir> exits 0   (runs Stages 1, 1b, 1c, 1c², 2, 2b, 3 in one pass)
[ ] Stage 1   luac -p / fengari compile clean
[ ] Stage 1b  runtime-nil lint clean (forward-ref / undefined-call / pcall-misuse) — check-lua-nils.js
[ ] Stage 1c  Driver construction OK (real ctor, no fabricated API) — check-driver-api.js
[ ] Stage 1c² capability commands OK (real command names, e.g. windowShadeLevel→setShadeLevel) — check-capability-commands.js
[ ] Stage 2   no banned patterns
[ ] Stage 3   profile/mapper parity (no orphans)
[ ] Stage 4   scope matches request (not a full-catalog clone)
[ ] Stage 5   installs; bridge once; child(ren) created; commands/refresh work
[ ] Stage 6   golden structure OK (infra surface matches reference) — check-golden-structure.js
```

`run-gate.sh` covers everything except Stage 4 (scope — needs the original request) and Stage 5
(needs a hub). Only when `run-gate.sh` exits 0 **and** Stages 4–5 pass is the driver ready to hand
over.
