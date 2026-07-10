# BroadLink RM4 Mini — SmartThings Edge Driver

Local, hub-native control of a BroadLink RM4 Mini Wi-Fi IR blaster — TVs, ACs, fans and other
IR devices, over the LAN, no cloud. Protocol ported from `python-broadlink`; AES is pure Lua.

**Docs:** [User Guide](broadlink-rm4-USER_GUIDE.md) · [Testing](broadlink-rm4-TESTING.md) ·
[Expected logs](broadlink-rm4-EXPECTED_LOGS.md) · [Protocol flow](broadlink-rm4-PROTOCOL_FLOW.md) ·
Shipping plans: [stock-caps (implemented)](broadlink-rm4-SHIPPING_PLAN-STOCK-CAPS.md) ·
[custom-caps (alternative)](broadlink-rm4-SHIPPING_PLAN.md)

## Status

| Layer | State |
|---|---|
| AES-128-CBC (`vendor/aes.lua`) | ✅ Verified vs. NIST SP 800-38A vector (Lua 5.3.6) |
| Framing + `auth` (`broadlink.lua`) | ✅ Verified offline (mock) **and on real hardware** |
| Discovery + **login** | ✅ **Passed on a real RM4** (devtype `0x520c`, `login OK`) — see hub-agent log |
| Product layer (this driver) | ✅ Implemented per the **stock-capabilities** plan |
| Distribution (channel/invite), code database, full CI test suite | ⏳ Remaining (plan Phase 5 / add-ons) |

The MAC byte-order and reply-offset questions are **settled** — the real RM4 accepted the
straight-copied MAC and logged in, so no reversal is needed.

## What it does (stock-capabilities model)

- The **RM4 blaster** is a LAN **parent** device. Each appliance is an **EDGE_CHILD** of a
  known **type** — `tv`, `ac`, `fan`, `media`, or `generic` — each mapped to a fixed profile of
  **stock** SmartThings capabilities (no custom capabilities). Cards render natively.
- **Add an appliance** from the app: on the RM4 tile, pick a type + name (Settings) and tap the
  Add button.
- **Learn codes in the app** via a **Learn-mode** preference: turn it on, tap a control, point
  your remote at the RM4 and press — the code is captured to that control's slot. Turn it off
  to go back to sending. Codes are stored **per device** (`code_store.lua`) and survive
  reboots/updates; `codes.lua` is only an optional developer seed.
- **Hardening:** online/offline health, scheduled IP re-discovery (DHCP drift), and cloud-lock
  detection with a clear message.

See the [User Guide](broadlink-rm4-USER_GUIDE.md) for the full walkthrough.

## Layout

```
broadlink-rm4/
├── config.yml
├── profiles/  rm4-hub · ir-tv · ir-ac · ir-fan · ir-media · ir-generic
└── src/
    ├── init.lua        driver: typed children, stock-cap handlers, Learn mode, add/remove,
    │                   health, IP refresh, cloud-lock
    ├── discovery.lua   UDP broadcast (+ directed + unicast fallback) discovery
    ├── broadlink.lua   protocol: framing, login (0x65), send (0x6a), learn
    ├── crypto.lua      byte-array wrapper over the vendored AES
    ├── code_store.lua  per-device code storage (+ codes.lua fallback)
    ├── utils.lua       byte/checksum/hex helpers
    ├── codes.lua       optional dev seed codes
    ├── vendor/aes.lua  self-contained pure-Lua AES-128-CBC
    └── test/           offline_crypto_test · offline_code_store_test
```

## Offline checks (no hub)

```powershell
$lua = "C:\Users\s.chatakonda\Edge\edge-test-env\lua\lua.exe"
cd drivers\Unofficial\broadlink-rm4
& $lua src\test\offline_crypto_test.lua       # AES vs. NIST vector
& $lua src\test\offline_code_store_test.lua   # code storage
```

## Deploy

```
smartthings edge:drivers:package . --install -C <channelId> -H <hubId>
```
Then in the app: **Add device → Scan nearby**. See [Testing](broadlink-rm4-TESTING.md).
