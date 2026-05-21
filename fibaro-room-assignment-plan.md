# Fibaro Device Room Assignment Plan

## Overview

This plan describes how to embed Fibaro room information into SmartThings devices created by the Fibaro Edge Driver, and then use a separate Python script with the SmartThings REST API to move those devices into the correct SmartThings rooms.

**Why two parts?** The SmartThings Edge Driver SDK does NOT provide an API to set room assignments for devices. Room assignment can only be done via the SmartThings REST API (`PUT /devices/{deviceId}` with `roomId`). Therefore:
- **Part 1 (Edge Driver)**: Embeds room metadata into devices so it's queryable later
- **Part 2 (Python Script)**: Reads device metadata via SmartThings API and assigns rooms

---

## Part 1: Edge Driver Changes

### 1.1 Add Room Fields to `fields.lua`

Add two new persisted fields to store Fibaro room info on each child device:

```lua
-- In src/fields.lua, add:
HC2_ROOM_ID = "hc2_room_id",
HC2_ROOM_NAME = "hc2_room_name",
```

These fields will be persisted on the SmartThings device and can be retrieved later via the SmartThings API.

### 1.2 Update `cache_child_metadata()` in `sync.lua`

When a child device is about to be created, cache the room info alongside other metadata:

```lua
-- In sync.lua, modify cache_child_metadata:
local function cache_child_metadata(driver, bridge, mapped)
  driver.datastore.pending_child_data = driver.datastore.pending_child_data or {}
  driver.datastore.pending_child_data[bridge.device_network_id .. "|" .. mapped.key] = {
    bridge_dni = bridge.device_network_id,
    hc2_device_id = mapped.id,
    hc2_device_type = mapped.type,
    hc2_device_kind = mapped.kind,
    hc2_room_id = mapped.room_id,          -- NEW
    hc2_room_name = mapped.room_name or "", -- NEW
  }
end
```

### 1.3 Update `apply_pending_child_metadata()` in `sync.lua`

When a child device is created, persist room fields on the device:

```lua
-- In sync.lua, modify apply_pending_child_metadata:
function sync.apply_pending_child_metadata(driver, device)
  if utils.is_bridge(device) then return end

  driver.datastore.pending_child_data = driver.datastore.pending_child_data or {}
  local bridge = utils.find_parent_bridge(driver, device)
  local bridge_dni = bridge and bridge.device_network_id or device:get_field(fields.PARENT_BRIDGE_DNI)
  local child_key = device.parent_assigned_child_key
  if not bridge_dni or not child_key then return end

  local cache_key = bridge_dni .. "|" .. child_key
  local pending = driver.datastore.pending_child_data[cache_key]
  if pending == nil then return end

  device:set_field(fields.PARENT_BRIDGE_DNI, pending.bridge_dni, { persist = true })
  device:set_field(fields.HC2_DEVICE_ID, pending.hc2_device_id, { persist = true })
  device:set_field(fields.HC2_DEVICE_TYPE, pending.hc2_device_type, { persist = true })
  device:set_field(fields.HC2_DEVICE_KIND, pending.hc2_device_kind, { persist = true })
  device:set_field(fields.HC2_ROOM_ID, pending.hc2_room_id, { persist = true })       -- NEW
  device:set_field(fields.HC2_ROOM_NAME, pending.hc2_room_name, { persist = true })   -- NEW
  driver.datastore.pending_child_data[cache_key] = nil
end
```

### 1.4 Update `mapper.lua` to Include `room_name` in Mapped Output

The mapper already prefixes the label with `[RoomName]`. Now also pass `room_name` in the mapped result:

```lua
-- In mapper.lua, each return block should include room_name:
return {
  id = device.id,
  key = utils.child_key_for_id(device.id),
  kind = "switch",
  profile = "fibaro-switch",
  label = label,             -- "[Living Room] Main Light"
  type = device_type,
  parent_id = parent_id,
  room_id = room_id,         -- numeric Fibaro room ID (e.g., 221)
  room_name = room_name,     -- string Fibaro room name (e.g., "Living Room")
  raw = device,
}
```

This needs to be added to **all** return blocks in mapper.lua (switch, dimmer, motion, contact, etc.).

### 1.5 Update `vendor_provided_label` in `sync.lua`

The `vendor_provided_label` field in the device creation metadata is queryable via the SmartThings API. Use a structured format that the script can reliably parse:

```lua
-- In sync.lua, modify ensure_child_device:
local function ensure_child_device(driver, bridge, mapped, existing_child)
  if existing_child then
    emit_child_state(existing_child, mapped.raw, mapped.kind)
    return existing_child
  end

  cache_child_metadata(driver, bridge, mapped)
  
  -- Structured vendor_provided_label for script parsing:
  -- Format: "fibaro|roomId:<id>|roomName:<name>|label:<raw_label>"
  local structured_vpl = string.format(
    "fibaro|roomId:%s|roomName:%s|label:%s",
    tostring(mapped.room_id or 0),
    tostring(mapped.room_name or ""),
    tostring(mapped.raw and mapped.raw.label or mapped.label)
  )
  
  local metadata = {
    type = "EDGE_CHILD",
    label = mapped.label,                                          -- "[Living Room] Main Light"
    profile = mapped.profile,
    manufacturer = "Fibaro",
    model = mapped.type ~= "" and mapped.type or "fibaro-hc2-device",
    vendor_provided_label = structured_vpl,                        -- Parseable format
    parent_device_id = bridge.id,
    parent_assigned_child_key = mapped.key,
  }

  local success, err = driver:try_create_device(metadata)
  if not success then
    log.error_with({hub_logs = true}, string.format("[Fibaro] Failed to create child %s: %s", mapped.key, tostring(err)))
  end

  return nil
end
```

### 1.6 Summary of Edge Driver File Changes

| # | File | Change | Purpose |
|---|------|--------|---------|
| 1 | `src/fields.lua` | Add `HC2_ROOM_ID`, `HC2_ROOM_NAME` fields | Persist room info on device |
| 2 | `src/fibaro/mapper.lua` | Add `room_name` to all mapped return objects | Pass room name through pipeline |
| 3 | `src/fibaro/sync.lua` | Update `cache_child_metadata()` | Cache room info during device creation |
| 4 | `src/fibaro/sync.lua` | Update `apply_pending_child_metadata()` | Persist room fields on new device |
| 5 | `src/fibaro/sync.lua` | Update `ensure_child_device()` | Set structured `vendor_provided_label` |

### 1.7 How Room Info Flows Through the Edge Driver

```
Fibaro HC3 API
    │
    ├── GET /api/rooms → [{id:221, name:"Living Room"}, ...]
    │                     ↓
    │              rooms lookup table: {221: "Living Room"}
    │
    ├── GET /api/devices → [{id:50, name:"Main Light", roomID:221, ...}]
    │                         ↓
    │              adapter.normalize_device() → {id:50, label:"Main Light", room_id:221, ...}
    │                         ↓
    │              mapper.map_device(device, rooms)
    │                ├── room_name = rooms[221] = "Living Room"
    │                ├── label = "[Living Room] Main Light"
    │                └── returns: {id:50, label:"[Living Room] Main Light",
    │                             room_id:221, room_name:"Living Room", kind:"switch", ...}
    │                         ↓
    │              ensure_child_device()
    │                ├── vendor_provided_label = "fibaro|roomId:221|roomName:Living Room|label:Main Light"
    │                ├── device label = "[Living Room] Main Light"
    │                └── device fields: HC2_ROOM_ID=221, HC2_ROOM_NAME="Living Room"
    │                         ↓
    │              SmartThings Device Created ✓
    │
```

### 1.8 What the SmartThings API Returns for Each Device

After the Edge Driver creates a device, the SmartThings REST API `GET /devices` will return:

```json
{
  "deviceId": "abc123-def456-...",
  "label": "[Living Room] Main Light",
  "deviceTypeId": "edge:driver-id:profile-id",
  "manufacturer": "Fibaro",
  "model": "com.fibaro.binarySwitch",
  "vendorProdividedLabel": "fibaro|roomId:221|roomName:Living Room|label:Main Light",
  "roomId": null,
  "locationId": "loc-123",
  "components": [...]
}
```

The script will parse `vendorProdividedLabel` (note: SmartThings API may use this spelling variant) or `label` to extract room info.

---

## Part 2: Python Script for Room Assignment

### 2.1 SmartThings API Endpoints Used

Based on the SmartThings API documentation at:
https://developer.smartthings.com/docs/api/public

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v1/locations` | GET | List all locations (to get locationId) |
| `/v1/locations/{locationId}/rooms` | GET | List all rooms in a location |
| `/v1/locations/{locationId}/rooms` | POST | Create a new room |
| `/v1/devices` | GET | List all devices (to find Fibaro devices) |
| `/v1/devices/{deviceId}` | PUT | Update device (to set roomId) |

### 2.2 Script Architecture

```
fibaro_room_assigner.py
│
├── Step 1: Authenticate with SmartThings PAT token
├── Step 2: Get location ID
├── Step 3: Get all existing SmartThings rooms
├── Step 4: Get all devices, filter for Fibaro devices
├── Step 5: Parse room info from device metadata
├── Step 6: Create missing SmartThings rooms
├── Step 7: Assign each device to its room
└── Step 8: Report results
```

### 2.3 Detailed Script Logic

```python
#!/usr/bin/env python3
"""
Fibaro Room Assignment Script

Reads Fibaro device metadata from SmartThings and assigns devices
to the correct SmartThings rooms based on their Fibaro room assignments.

Uses the SmartThings REST API with a PAT token.

API Reference: https://developer.smartthings.com/docs/api/public
"""

import requests
import re
import sys
import os
import json
import getpass
from typing import Optional

SMARTTHINGS_API_BASE = "https://api.smartthings.com/v1"

class SmartThingsClient:
    """Client for SmartThings REST API."""
    
    def __init__(self, pat_token: str):
        self.token = pat_token
        self.headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
        }
    
    def get_locations(self):
        """GET /v1/locations - List all locations."""
        resp = requests.get(f"{SMARTTHINGS_API_BASE}/locations", headers=self.headers)
        resp.raise_for_status()
        return resp.json().get("items", [])
    
    def get_rooms(self, location_id: str):
        """GET /v1/locations/{locationId}/rooms - List rooms in location."""
        resp = requests.get(
            f"{SMARTTHINGS_API_BASE}/locations/{location_id}/rooms",
            headers=self.headers
        )
        resp.raise_for_status()
        return resp.json().get("items", [])
    
    def create_room(self, location_id: str, room_name: str):
        """POST /v1/locations/{locationId}/rooms - Create a new room."""
        resp = requests.post(
            f"{SMARTTHINGS_API_BASE}/locations/{location_id}/rooms",
            headers=self.headers,
            json={"name": room_name}
        )
        resp.raise_for_status()
        return resp.json()
    
    def get_devices(self, location_id: Optional[str] = None):
        """GET /v1/devices - List all devices, optionally filtered by location."""
        url = f"{SMARTTHINGS_API_BASE}/devices"
        params = {}
        if location_id:
            params["locationId"] = location_id
        
        all_devices = []
        while url:
            resp = requests.get(url, headers=self.headers, params=params)
            resp.raise_for_status()
            data = resp.json()
            all_devices.extend(data.get("items", []))
            # Handle pagination
            url = None  # SmartThings API may use cursor-based pagination
            params = {}  # Clear params for subsequent requests
        
        return all_devices
    
    def update_device_room(self, device_id: str, room_id: str):
        """PUT /v1/devices/{deviceId} - Update device's room assignment."""
        resp = requests.put(
            f"{SMARTTHINGS_API_BASE}/devices/{device_id}",
            headers=self.headers,
            json={"roomId": room_id}
        )
        resp.raise_for_status()
        return resp.json()


def is_fibaro_device(device: dict) -> bool:
    """Check if a device was created by the Fibaro Edge Driver."""
    manufacturer = (device.get("manufacturer") or "").lower()
    vpl = (device.get("vendorProvidedLabel") or 
           device.get("vendorProdividedLabel") or "")
    
    # Match by manufacturer or structured VPL prefix
    return manufacturer == "fibaro" or vpl.startswith("fibaro|")


def parse_room_info(device: dict) -> tuple[Optional[str], Optional[str]]:
    """
    Parse room info from a Fibaro device's metadata.
    
    Returns (room_id, room_name) or (None, None) if not found.
    
    Strategy (in order of reliability):
    1. Parse structured vendor_provided_label: "fibaro|roomId:221|roomName:Living Room|label:Main Light"
    2. Parse room name from device label: "[Living Room] Main Light"
    """
    # Strategy 1: Parse structured VPL
    vpl = (device.get("vendorProvidedLabel") or 
           device.get("vendorProdividedLabel") or "")
    
    if vpl.startswith("fibaro|"):
        parts = {}
        for segment in vpl.split("|")[1:]:  # Skip "fibaro" prefix
            if ":" in segment:
                key, value = segment.split(":", 1)
                parts[key] = value
        
        room_id = parts.get("roomId")
        room_name = parts.get("roomName")
        if room_name and room_name != "":
            return room_id, room_name
    
    # Strategy 2: Parse from label "[RoomName] DeviceLabel"
    label = device.get("label", "")
    match = re.match(r'^\[([^\]]+)\]\s+(.+)$', label)
    if match:
        room_name = match.group(1)
        return None, room_name
    
    return None, None


def main():
    print("=== Fibaro Room Assignment Script ===\n")
    
    # Step 1: Get PAT token
    if len(sys.argv) > 1:
        pat_token = sys.argv[1]
    else:
        pat_token = getpass.getpass("Enter SmartThings PAT token: ")
    
    client = SmartThingsClient(pat_token)
    
    # Step 2: Get location
    locations = client.get_locations()
    if not locations:
        print("No SmartThings locations found.")
        sys.exit(1)
    
    if len(locations) == 1:
        location = locations[0]
        print(f"Using location: {location['name']} ({location['locationId']})")
    else:
        print("Multiple locations found:")
        for i, loc in enumerate(locations):
            print(f"  {i+1}. {loc['name']} ({loc['locationId']})")
        choice = int(input("Select location: ")) - 1
        location = locations[choice]
    
    location_id = location["locationId"]
    
    # Step 3: Get existing rooms
    existing_rooms = client.get_rooms(location_id)
    room_name_to_id = {}
    for room in existing_rooms:
        room_name_to_id[room["name"]] = room["roomId"]
    
    print(f"\nFound {len(existing_rooms)} existing SmartThings rooms:")
    for room in existing_rooms:
        print(f"  - {room['name']} (ID: {room['roomId']})")
    
    # Step 4: Get all Fibaro devices
    all_devices = client.get_devices(location_id)
    fibaro_devices = [d for d in all_devices if is_fibaro_device(d)]
    
    print(f"\nFound {len(fibaro_devices)} Fibaro devices out of {len(all_devices)} total")
    
    # Step 5: Parse room info and build assignment map
    assignments = []  # [(device_id, device_label, room_name, room_id)]
    needed_rooms = set()
    
    for device in fibaro_devices:
        fibaro_room_id, room_name = parse_room_info(device)
        if room_name:
            assignments.append({
                "device_id": device["deviceId"],
                "device_label": device.get("label", ""),
                "room_name": room_name,
                "fibaro_room_id": fibaro_room_id,
                "current_room_id": device.get("roomId"),
            })
            if room_name not in room_name_to_id:
                needed_rooms.add(room_name)
    
    print(f"\n{len(assignments)} devices have room assignments:")
    
    # Group by room for display
    by_room = {}
    for a in assignments:
        by_room.setdefault(a["room_name"], []).append(a)
    
    for room_name, devices in sorted(by_room.items()):
        existing = room_name_to_id.get(room_name, "NEW")
        print(f"\n  [{room_name}] → SmartThings Room ID: {existing}")
        for d in devices:
            already = "✓" if d["current_room_id"] == room_name_to_id.get(room_name) else "→"
            print(f"    {already} {d['device_label']}")
    
    # Step 6: Create missing rooms
    if needed_rooms:
        print(f"\n{len(needed_rooms)} rooms need to be created in SmartThings:")
        for room_name in sorted(needed_rooms):
            print(f"  + {room_name}")
        
        confirm = input("\nCreate missing rooms? (y/n) [y]: ").strip().lower()
        if confirm in ("", "y", "yes"):
            for room_name in sorted(needed_rooms):
                new_room = client.create_room(location_id, room_name)
                room_name_to_id[room_name] = new_room["roomId"]
                print(f"  Created room: {room_name} (ID: {new_room['roomId']})")
    
    # Step 7: Assign devices to rooms
    pending_assignments = []
    for a in assignments:
        st_room_id = room_name_to_id.get(a["room_name"])
        if st_room_id and a["current_room_id"] != st_room_id:
            pending_assignments.append((a, st_room_id))
    
    if not pending_assignments:
        print("\nAll devices are already in the correct rooms. Nothing to do.")
        sys.exit(0)
    
    print(f"\n{len(pending_assignments)} devices need room assignment:")
    for a, st_room_id in pending_assignments:
        print(f"  {a['device_label']} → {a['room_name']} ({st_room_id})")
    
    confirm = input("\nAssign devices to rooms? (y/n) [y]: ").strip().lower()
    if confirm not in ("", "y", "yes"):
        print("Aborted.")
        sys.exit(0)
    
    # Step 8: Execute assignments
    success_count = 0
    fail_count = 0
    for a, st_room_id in pending_assignments:
        try:
            client.update_device_room(a["device_id"], st_room_id)
            print(f"  ✓ {a['device_label']} → {a['room_name']}")
            success_count += 1
        except Exception as e:
            print(f"  ✗ {a['device_label']} → FAILED: {e}")
            fail_count += 1
    
    print(f"\nDone! {success_count} devices assigned, {fail_count} failed.")


if __name__ == "__main__":
    main()
```

### 2.4 Script Features

| Feature | Description |
|---------|-------------|
| **PAT Token Auth** | Uses Bearer token for SmartThings API authentication |
| **Multi-location support** | Handles locations with multiple SmartThings locations |
| **Room auto-creation** | Creates SmartThings rooms that don't exist yet |
| **Idempotent** | Safe to run multiple times; skips devices already in correct room |
| **Dual parsing strategy** | Parses structured `vendor_provided_label` first, falls back to label prefix |
| **Dry-run display** | Shows planned assignments before executing |
| **Progress reporting** | Reports success/failure for each device |

### 2.5 SmartThings API Details

#### GET /v1/devices Response (relevant fields)

```json
{
  "items": [
    {
      "deviceId": "string",
      "label": "[Living Room] Main Light",
      "manufacturer": "Fibaro",
      "model": "com.fibaro.binarySwitch",
      "vendorProvidedLabel": "fibaro|roomId:221|roomName:Living Room|label:Main Light",
      "roomId": null,
      "locationId": "string",
      "deviceTypeId": "string",
      "components": [...]
    }
  ]
}
```

#### POST /v1/locations/{locationId}/rooms - Create Room

Request:
```json
{
  "name": "Living Room"
}
```

Response:
```json
{
  "roomId": "abc-def-123",
  "name": "Living Room",
  "locationId": "loc-123"
}
```

#### PUT /v1/devices/{deviceId} - Update Device Room

Request:
```json
{
  "roomId": "abc-def-123"
}
```

Response:
```json
{
  "deviceId": "device-123",
  "roomId": "abc-def-123",
  ...
}
```

---

## Part 3: End-to-End Workflow

### 3.1 Initial Setup (One-time)

1. Deploy updated Fibaro Edge Driver to SmartThings hub
2. Delete existing Fibaro child devices (so they get recreated with room metadata)
3. Let the driver rediscover and recreate devices with room info embedded

### 3.2 Running the Room Assignment Script

```bash
# Install dependencies
pip install requests

# Run with token as argument
python3 fibaro_room_assigner.py "YOUR_PAT_TOKEN"

# Or run interactively (will prompt for token)
python3 fibaro_room_assigner.py
```

### 3.3 PAT Token Requirements

The PAT token needs the following scopes:
- `r:devices` - Read device list
- `w:devices` - Update device room assignment
- `r:locations` - Read locations
- `r:rooms` - Read rooms
- `w:rooms` - Create new rooms

### 3.4 Running After Device Changes

When devices are added/removed in Fibaro:
1. The Edge Driver will automatically sync and create new devices with room metadata
2. Run the room assignment script to move new devices to their rooms
3. Optionally set up a cron job to run the script periodically

```bash
# Cron example: Run every 30 minutes
*/30 * * * * /usr/bin/python3 /path/to/fibaro_room_assigner.py "PAT_TOKEN" >> /var/log/fibaro_rooms.log 2>&1
```

---

## Part 4: Implementation Order

| Step | Component | File | Description |
|------|-----------|------|-------------|
| **1** | Edge Driver | `src/fields.lua` | Add `HC2_ROOM_ID`, `HC2_ROOM_NAME` fields |
| **2** | Edge Driver | `src/fibaro/mapper.lua` | Add `room_name` to all mapped return objects |
| **3** | Edge Driver | `src/fibaro/sync.lua` | Update `cache_child_metadata()` to include room info |
| **4** | Edge Driver | `src/fibaro/sync.lua` | Update `apply_pending_child_metadata()` to persist room fields |
| **5** | Edge Driver | `src/fibaro/sync.lua` | Update `ensure_child_device()` to set structured `vendor_provided_label` |
| **6** | Script | `fibaro_room_assigner.py` | Create the Python room assignment script |
| **7** | Test | — | Deploy driver, delete old devices, let rediscovery happen |
| **8** | Test | — | Run script, verify room assignments in SmartThings app |

---

## Part 5: Risk & Considerations

### 5.1 Edge Driver Limitations
- **No real-time room assignment**: Room assignment happens via external script, not in real-time
- **Devices appear unassigned initially**: New devices will show in "No Room" until the script runs
- **Label prefix is informational only**: The `[RoomName]` prefix in the device label helps identify rooms but doesn't actually assign the SmartThings room

### 5.2 Script Considerations
- **PAT Token security**: Store token securely; don't hardcode in scripts
- **Rate limiting**: SmartThings API has rate limits; add delays if assigning many devices
- **Idempotency**: Script is safe to re-run; it skips devices already in the correct room
- **Error handling**: If a device assignment fails, the script continues with remaining devices
- **Room name matching**: Fibaro room names must match SmartThings room names exactly (case-sensitive)

### 5.3 Edge Cases
- **Device with no Fibaro room**: Devices without a `roomID` in Fibaro will have `room_id=0` and no room prefix; script skips them
- **Room renamed in Fibaro**: If a room is renamed in Fibaro, the next driver sync will update the label, but the script must be re-run to update SmartThings room assignment
- **Duplicate room names**: If SmartThings has duplicate room names, the script uses the first match
- **Special characters in room names**: The `|` character in room names could break VPL parsing; consider using a different delimiter or escaping

### 5.4 Future Improvements
- **Automation**: Schedule the script to run periodically via cron/systemd timer
- **Integration with Home Assistant**: If using HA, the room assignment could be triggered via HA automation
- **WebSocket/real-time updates**: If SmartThings adds a device room assignment API to the Edge SDK, the script would no longer be needed
- **Conflict resolution**: Add logic to handle devices that have been manually moved to a different room in SmartThings
