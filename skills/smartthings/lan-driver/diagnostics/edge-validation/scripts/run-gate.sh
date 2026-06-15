#!/usr/bin/env bash
# Single entry point for the SmartThings Edge driver validation gate.
#
#   run-gate.sh <driver-dir>
#
# Runs every *scriptable* stage of the edge-validation gate (compile, runtime-nil lint,
# Driver-API check, capability-command check, banned patterns, :run() assertion, profile/mapper
# parity, and a golden-reference structural diff) and returns a SINGLE pass/fail:
#   exit 0  -> all scriptable stages passed (Stage 5 functional install on a real hub is
#              still required for full production sign-off)
#   exit 1  -> one or more stages failed; the driver is NOT production-grade, do not hand off
#   exit 2  -> usage / could-not-run error (treat as failure: nothing was actually validated)
#
# This is the artifact an enforcement hook should call. It never "passes" by scanning zero
# files: a bad path or empty src/ exits 2.
set -uo pipefail

DRIVER="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$DRIVER" ] || [ ! -d "$DRIVER" ]; then
  echo "usage: run-gate.sh <driver-dir> [golden-reference-dir]"; exit 2
fi
# Golden reference for the structural diff (Stage 6): 2nd arg > $GOLDEN_REF env > bundled fibaro ref.
GOLDEN="${2:-${GOLDEN_REF:-$SCRIPT_DIR/../../../../../vendors/fibaro/reference-driver}}"
SRC="$DRIVER/src"
if [ ! -d "$SRC" ]; then echo "GATE ERROR: no src/ directory under $DRIVER"; exit 2; fi

mapfile -t LUA < <(find "$SRC" -name '*.lua')
if [ "${#LUA[@]}" -eq 0 ]; then echo "GATE ERROR: no .lua files under $SRC"; exit 2; fi

fails=0
section(){ printf '\n==================== %s ====================\n' "$1"; }
pass(){ echo "  PASS: $1"; }
fail(){ echo "  FAIL: $1"; fails=$((fails+1)); }

# ---- Stage 1: Lua compile -----------------------------------------------------------------
section "Stage 1: Lua compile"
if command -v luac >/dev/null 2>&1; then
  c=0; for f in "${LUA[@]}"; do luac -p "$f" 2>&1 | sed 's/^/    /' || c=1; done
  [ "$c" -eq 0 ] && pass "all Lua compiles (luac -p)" || fail "Lua compile error(s)"
elif command -v lua >/dev/null 2>&1; then
  c=0; for f in "${LUA[@]}"; do lua -e "assert(loadfile([[$f]]))" 2>&1 | sed 's/^/    /' || c=1; done
  [ "$c" -eq 0 ] && pass "all Lua loads (lua loadfile)" || fail "Lua load error(s)"
else
  echo "  WARN: no luac/lua on PATH — compile stage SKIPPED (install lua to enable)."
  echo "        The JS nil-linter (Stage 1b) covers the most common load failures, but a"
  echo "        real compiler is recommended in the enforcement environment."
fi

# ---- Stage 1b: runtime-nil lint -----------------------------------------------------------
section "Stage 1b: runtime-nil lint (forward-ref / undefined-call / pcall-misuse)"
node "$SCRIPT_DIR/check-lua-nils.js" "$SRC" && pass "no nil-runtime issues" || fail "nil-runtime issue(s)"

# ---- Stage 1c: Driver construction / SDK API ----------------------------------------------
section "Stage 1c: Driver construction / SDK API"
node "$SCRIPT_DIR/check-driver-api.js" "$SRC" && pass "Driver construction OK" || fail "Driver-API issue(s)"

# ---- Stage 1c(2): capability command names ------------------------------------------------
section "Stage 1c(2): capability command names"
node "$SCRIPT_DIR/check-capability-commands.js" "$SRC" && pass "capability commands OK" || fail "bad capability command(s)"

# ---- Stage 2: banned patterns -------------------------------------------------------------
# Scan COMMENT/STRING-STRIPPED source (via the shared Lua stripper) so a banned token mentioned
# in a comment (e.g. "-- do not paste 192.168.1.50") is not a false positive — only real code is.
section "Stage 2: banned patterns"
banned=0
ban(){ # <regex> <human label>
  local hit=0
  for f in "${LUA[@]}"; do
    local m
    m="$(node "$SCRIPT_DIR/lua-strip.js" --keep-strings "$f" | grep -nE "$1" || true)"
    if [ -n "$m" ]; then
      [ "$hit" -eq 0 ] && echo "    banned: $2"
      echo "$m" | head -5 | sed "s|^|      $f:|"
      hit=1; banned=1
    fi
  done
}
ban 'require *["'\'']socket\.http["'\'']|require *["'\'']ltn12["'\'']' 'non-Edge HTTP libs (socket.http / ltn12)'
ban 'get_device_by_dni' 'get_device_by_dni — no such Driver method'
ban 'cosock\.sleep' 'cosock.sleep — does not exist (use socket.sleep / call_on_schedule)'
# Hardcoded LAN hub IP (RFC1918). Deliberately NOT a generic IPv4 match, so legitimate
# broadcast/loopback constants (255.255.255.255, 0.0.0.0, 127.0.0.1) do not false-positive.
ban '(^|[^0-9.])(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)[0-9]+\.[0-9]+' 'hardcoded RFC1918 hub IP'
ban 'find\.fibaro\.com' 'hardcoded find.fibaro.com endpoint'
# Invalid C/JS-style line comments. Lua comments are `--`; `//` is integer floor-division, so a
# line-leading `//` is a SYNTAX ERROR — if it lands in init.lua the driver never loads and no
# device card appears (v42). Scanned on COMMENT+STRING-STRIPPED source (default strip blanks
# strings) so a legitimate `://` inside a URL string never false-positives. Caught here without a
# Lua toolchain, so it is reported even when Stage 1 (luac -p) is skipped.
cjs_hit=0
for f in "${LUA[@]}"; do
  m="$(node "$SCRIPT_DIR/lua-strip.js" "$f" | grep -nE '^[[:space:]]*//' || true)"
  if [ -n "$m" ]; then
    [ "$cjs_hit" -eq 0 ] && echo "    banned: C/JS-style '//' comments — Lua comments must be '--' (// is a syntax error)"
    echo "$m" | head -5 | sed "s|^|      $f:|"
    cjs_hit=1; banned=1
  fi
done
[ "$banned" -eq 0 ] && pass "no banned patterns" || fail "banned pattern(s) present"

# ---- Stage 2b: init.lua must start the event loop -----------------------------------------
section "Stage 2b: init.lua calls <driver>:run()"
if grep -q ':run()' "$SRC/init.lua" 2>/dev/null; then
  pass "init.lua calls :run()"
else
  fail "init.lua never calls <driver>:run() — driver loads but never starts"
fi

# ---- Stage 3: profile / mapper parity (best-effort) ---------------------------------------
section "Stage 3: profile / mapper parity"
MAPPER="$(find "$SRC" -name 'mapper.lua' | head -1)"
if [ -n "$MAPPER" ] && [ -d "$DRIVER/profiles" ]; then
  missing=0
  while read -r p; do
    [ -z "$p" ] && continue
    if [ ! -f "$DRIVER/profiles/$p.yml" ]; then
      echo "    mapper references profile with no profiles/$p.yml"; missing=1
    fi
  done < <(grep -rhoE '[a-z][a-z0-9]+-[a-z-]+' "$MAPPER" | grep -E '^(fibaro|hc2)-' | sort -u)
  [ "$missing" -eq 0 ] && pass "every mapper profile reference has a profiles/*.yml" || fail "mapper references missing profile(s)"
else
  echo "  (skipped: no mapper.lua or profiles/ — parity check is bridge-specific)"
fi

# ---- Stage 6: golden-reference structural diff (Fibaro infra-scoped) -----------------------
# Catches cross-file/contract drift that single-file checks cannot see (e.g. a
# labeled_socket_builder whose arity no longer matches its rest.lua caller, or a missing
# fibaro_finder.lua). Compares ONLY src/ infrastructure surface, never profiles/scope, so it
# does not punish "generate only requested device kinds". Runs only for Fibaro-style drivers.
section "Stage 6: golden-reference structural diff"
is_fibaro=0
grep -qi 'fibaro' "$DRIVER/config.yml" 2>/dev/null && is_fibaro=1
ls "$DRIVER"/profiles/fibaro-*.yml >/dev/null 2>&1 && is_fibaro=1
[ -d "$SRC/fibaro" ] && is_fibaro=1
if [ "$is_fibaro" -ne 1 ]; then
  echo "  (skipped: not a Fibaro driver — golden reference is Fibaro-specific)"
elif [ ! -d "$GOLDEN/src" ]; then
  echo "  WARN: golden reference not found at $GOLDEN — structural diff SKIPPED."
  echo "        Pass it explicitly: run-gate.sh <driver-dir> <golden-reference-dir>"
else
  node "$SCRIPT_DIR/check-golden-structure.js" "$GOLDEN" "$DRIVER" \
    && pass "infrastructure matches golden reference" || fail "structural drift vs golden reference"
fi

# ---- Result -------------------------------------------------------------------------------
section "RESULT"
if [ "$fails" -eq 0 ]; then
  echo "GATE PASSED — all scriptable stages clean."
  echo "NOTE: Stage 5 (functional install on a real hub via the SmartThings CLI) is still"
  echo "      required for full production sign-off."
  exit 0
else
  echo "GATE FAILED — $fails stage(s) failed. Driver is NOT production-grade; do not hand off."
  exit 1
fi
