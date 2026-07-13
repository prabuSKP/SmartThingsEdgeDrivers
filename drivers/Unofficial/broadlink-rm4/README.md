# BroadLink RM4 Mini — SmartThings Edge Driver

Local, hub-native control of a BroadLink RM4 Mini Wi-Fi IR blaster — TVs, ACs, fans and other
IR devices, over the LAN, no cloud. Protocol ported from `python-broadlink`; AES is pure Lua.

**Docs:** [Architecture](../../../docs/broadlink-rm4/ARCHITECTURE.md) · [User Guide](../../../docs/broadlink-rm4/USER_GUIDE.md) · [Testing](../../../docs/broadlink-rm4/TESTING.md) ·
[Expected logs](../../../docs/broadlink-rm4/EXPECTED_LOGS.md) · [Protocol flow](../../../docs/broadlink-rm4/PROTOCOL_FLOW.md) ·
[Known gaps](../../../docs/broadlink-rm4/GAPS.md) ·
Shipping plans: [stock-caps (implemented)](../../../docs/broadlink-rm4/SHIPPING_PLAN-STOCK-CAPS.md) ·
[custom-caps (alternative)](../../../docs/broadlink-rm4/SHIPPING_PLAN.md)

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
- **Add an appliance** from the app: on the RM4 tile → **Settings**, pick a **type** and type a
  **name**, then **Save** — an `info_changed` handler creates the typed child (preference-driven;
  no button — `momentary` doesn't render on the LAN parent, see GAPS G2). Onboarding creates
  **only the RM4** (no default child).
- **Cards populate on init** with sensible starting values (thermostat mode, setpoint, fan
  strength, volume, and the media/mode/fan picker lists) so child cards aren't blank. These are
  optimistic **placeholders, not real readings** — IR is one-way, so the driver never gets
  actual state back and the card can drift if you use the physical remote.
- **Learn codes in the app** via a **Learn-mode** preference: turn it on, tap a control, point
  your remote at the RM4 and press — the code is captured to that control's slot. Turn it off
  to go back to sending. Codes are stored **per device** (`code_store.lua`) and survive
  reboots/updates. Only the **TV** type ships **bundled (Samsung) seed codes**; **AC, Fan,
  Media box and Generic have no seeds and must be taught with Learn mode**. Learned codes
  always override bundled ones.
- **TV power style:** TV appliances default to a power **Toggle** code (one flip code for
  on/off — best for Samsung monitors); switch to **Discrete On/Off** in the tile's **Settings**
  for TVs that use separate on/off codes.
- **Hardening:** online/offline health, scheduled IP re-discovery (DHCP drift), and cloud-lock
  detection with a clear message.

See the [User Guide](../../../docs/broadlink-rm4/USER_GUIDE.md) for the full walkthrough.

## Layout

```
broadlink-rm4/
├── config.yml
├── profiles/  rm4-hub · ir-tv · ir-ac · ir-fan · ir-media · ir-generic
└── src/
    ├── init.lua        driver: typed children, stock-cap handlers, Learn mode, add/remove,
    │                   card state seeding, health, IP refresh, cloud-lock
    ├── discovery.lua   UDP broadcast (+ directed + unicast fallback) discovery
    ├── broadlink.lua   protocol: rmminib framing, login (0x65), send/learn (0x6a), errcode checks
    ├── crypto.lua      byte-array wrapper over the vendored AES
    ├── code_store.lua  per-device code storage (+ codes.lua fallback)
    ├── utils.lua       byte/checksum/hex helpers
    ├── codes.lua       bundled Samsung TV seed codes (fallback; AC/fan/media/generic are learn-only)
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
Then in the app: **Add device → Scan nearby**. See [Testing](../../../docs/broadlink-rm4/TESTING.md).
