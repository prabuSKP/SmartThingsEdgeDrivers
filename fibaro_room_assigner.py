#!/usr/bin/env python3
"""
Fibaro Room Assignment Script

Reads Fibaro device metadata from SmartThings and assigns devices
to the correct SmartThings rooms based on their Fibaro room assignments.

Uses the SmartThings REST API with a PAT token.

API Reference: https://developer.smartthings.com/docs/api/public
               https://developer.smartthings.com/docs/api/public#tag/Devices/operation/getDevices

Usage:
    python3 fibaro_room_assigner.py                          # Interactive - prompts for PAT token
    python3 fibaro_room_assigner.py YOUR_PAT_TOKEN           # Pass token as argument
    python3 fibaro_room_assigner.py --dry-run YOUR_PAT_TOKEN # Show what would change without making changes

Detection Strategies (in order of reliability):
    1. EDGE_CHILD device whose parentDeviceId matches a Fibaro hub
    2. vendorProvidedLabel starts with "fibaro|" (structured VPL format from Edge Driver)
    3. manufacturer field contains "Fibaro"
    4. Device label matches [RoomName] prefix pattern (Fibaro room prefix)
    5. deviceTypeId contains "fibaro"

Required PAT token scopes:
    r:devices   - Read device list
    w:devices   - Update device room assignment
    r:locations - Read locations
    r:rooms     - Read rooms
    w:rooms     - Create new rooms
"""

import requests
import re
import sys
import json
import getpass
import time
from typing import Optional

SMARTTHINGS_API_BASE = "https://api.smartthings.com/v1"


class SmartThingsClient:
    """Client for SmartThings REST API."""

    def __init__(self, pat_token: str, dry_run: bool = False):
        self.token = pat_token
        self.dry_run = dry_run
        self.headers = {
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        }

    def _request(self, method: str, url: str, **kwargs) -> requests.Response:
        """Make an API request with rate limit handling."""
        for attempt in range(3):
            resp = requests.request(method, url, headers=self.headers, **kwargs)
            if resp.status_code == 429:
                retry_after = int(resp.headers.get("Retry-After", 5))
                print(f"  Rate limited. Waiting {retry_after}s...")
                time.sleep(retry_after)
                continue
            return resp
        return resp

    def get_locations(self) -> list:
        """GET /v1/locations - List all locations."""
        resp = self._request("GET", f"{SMARTTHINGS_API_BASE}/locations")
        resp.raise_for_status()
        return resp.json().get("items", [])

    def get_rooms(self, location_id: str) -> list:
        """GET /v1/locations/{locationId}/rooms - List rooms in location."""
        resp = self._request("GET", f"{SMARTTHINGS_API_BASE}/locations/{location_id}/rooms")
        resp.raise_for_status()
        return resp.json().get("items", [])

    def create_room(self, location_id: str, room_name: str) -> dict:
        """POST /v1/locations/{locationId}/rooms - Create a new room."""
        if self.dry_run:
            print(f"  [DRY RUN] Would create room: {room_name}")
            return {"roomId": f"dry-run-{room_name}", "name": room_name}

        resp = self._request(
            "POST",
            f"{SMARTTHINGS_API_BASE}/locations/{location_id}/rooms",
            json={"name": room_name}
        )
        resp.raise_for_status()
        return resp.json()

    def get_devices(self, location_id: Optional[str] = None) -> list:
        """GET /v1/devices - List all devices, optionally filtered by location."""
        params = {}
        if location_id:
            params["locationId"] = location_id
            params["capabilityStatus"] = "false"

        all_devices = []
        url = f"{SMARTTHINGS_API_BASE}/devices"

        while url:
            resp = self._request("GET", url, params=params)
            resp.raise_for_status()
            data = resp.json()
            all_devices.extend(data.get("items", []))

            # Handle pagination via Links header
            links = resp.headers.get("Links", "")
            next_link = None
            if 'rel="next"' in links:
                for part in links.split(","):
                    if 'rel="next"' in part:
                        match = re.search(r'<([^>]+)>', part)
                        if match:
                            next_link = match.group(1)
                            break

            url = next_link
            params = {}  # Clear params for subsequent requests (URL already has them)

        return all_devices

    def update_device_room(self, device_id: str, room_id: str) -> dict:
        """PUT /v1/devices/{deviceId} - Update device's room assignment."""
        if self.dry_run:
            print(f"  [DRY RUN] Would assign device {device_id} to room {room_id}")
            return {"deviceId": device_id, "roomId": room_id}

        resp = self._request(
            "PUT",
            f"{SMARTTHINGS_API_BASE}/devices/{device_id}",
            json={"roomId": room_id}
        )
        resp.raise_for_status()
        return resp.json()


# ============================================
# Fibaro Device Detection
# ============================================

def get_vendor_provided_label(device: dict) -> str:
    """Get vendorProvidedLabel, handling API spelling variations."""
    return (
        device.get("vendorProvidedLabel")
        or device.get("vendorProdividedLabel")  # Known SmartThings API typo
        or ""
    )


def find_fibaro_hubs(all_devices: list) -> dict:
    """
    Identify Fibaro hub/bridge devices from the device list.

    A Fibaro hub is identified by:
    - Label contains "Fibaro" or "HC3" or "HC2"
    - Type is "LAN" (Edge Driver LAN device)

    Returns dict of {deviceId: device_info} for all found Fibaro hubs.
    """
    fibaro_hubs = {}
    fibaro_keywords = ["fibaro", "hc3", "hc2"]

    for device in all_devices:
        label = (device.get("label") or "").lower()
        device_type = (device.get("type") or "").upper()
        device_id = device.get("deviceId", "")

        # Check if label contains Fibaro keywords
        is_fibaro_hub = False
        matched_keyword = ""
        for kw in fibaro_keywords:
            if kw in label:
                is_fibaro_hub = True
                matched_keyword = kw
                break

        if is_fibaro_hub:
            fibaro_hubs[device_id] = {
                "deviceId": device_id,
                "label": device.get("label", ""),
                "type": device.get("type", ""),
                "matched_keyword": matched_keyword,
            }
            print(f"    ✓ Found Fibaro hub: '{device.get('label')}' (type={device_type}, id={device_id}, matched='{matched_keyword}')")

    return fibaro_hubs


def is_fibaro_device(device: dict, fibaro_hub_ids: set) -> tuple:
    """
    Check if a device was created by the Fibaro Edge Driver.

    Returns (is_fibaro: bool, detection_method: str)

    Detection strategies (in order of reliability):
    1. EDGE_CHILD whose parentDeviceId is a known Fibaro hub
    2. vendorProvidedLabel starts with "fibaro|" (structured VPL)
    3. manufacturer field contains "Fibaro"
    4. Label matches [RoomName] prefix AND is EDGE_CHILD type
    5. deviceTypeId contains "fibaro"
    """
    device_id = device.get("deviceId", "")
    label = device.get("label", "")
    device_type = (device.get("type") or "").upper()
    parent_device_id = device.get("parentDeviceId", "")
    manufacturer = (device.get("manufacturer") or "").strip()
    vpl = get_vendor_provided_label(device)
    device_type_id = (device.get("deviceTypeId") or "").lower()

    # Strategy 1: Direct child of a known Fibaro hub (most reliable)
    if parent_device_id and parent_device_id in fibaro_hub_ids:
        return True, f"parent is Fibaro hub (parentId={parent_device_id})"

    # Strategy 2: vendorProvidedLabel starts with "fibaro|"
    if vpl.startswith("fibaro|"):
        return True, f"VPL starts with 'fibaro|'"

    # Strategy 3: manufacturer field contains "Fibaro"
    if manufacturer.lower() == "fibaro":
        return True, f"manufacturer='Fibaro'"

    # Strategy 4: Label has [RoomName] or [RoomName:roomId] prefix AND is EDGE_CHILD type
    # This catches Fibaro child devices even without VPL or manufacturer info
    if device_type == "EDGE_CHILD" and re.match(r'^\[[^\]]+\]\s+.+$', label):
        return True, f"EDGE_CHILD with [Room] label prefix"

    # Strategy 5: deviceTypeId contains "fibaro"
    if "fibaro" in device_type_id:
        return True, f"deviceTypeId contains 'fibaro'"

    return False, ""


def parse_room_info(device: dict) -> tuple:
    """
    Parse room info from a Fibaro device's metadata.

    Returns (fibaro_room_id, room_name) or (None, None) if not found.

    Strategy (in order of reliability):
    1. Parse structured vendor_provided_label: "fibaro|roomId:221|roomName:Living Room|label:Main Light"
       (NOTE: SmartThings does NOT preserve VPL for EDGE_CHILD devices, so this only
        works for the Fibaro bridge/hub device which is type=LAN)
    2. Parse room name AND room_id from device label: "[RoomName:roomId] Main Light"
       This is the primary method for EDGE_CHILD devices since SmartThings strips VPL.
    3. Parse room name only from device label: "[RoomName] Main Light"
       Fallback for devices created before the label format change.
    """
    # Strategy 1: Parse structured VPL (only works for LAN bridge device)
    vpl = get_vendor_provided_label(device)

    if vpl.startswith("fibaro|"):
        parts = {}
        for segment in vpl.split("|")[1:]:  # Skip "fibaro" prefix
            if ":" in segment:
                key, value = segment.split(":", 1)
                parts[key.strip()] = value.strip()

        room_id = parts.get("roomId")
        room_name = parts.get("roomName")
        if room_name and room_name != "":
            return room_id, room_name

    # Strategy 2: Parse from label "[RoomName:roomId] DeviceLabel"
    # This is the primary method for EDGE_CHILD devices
    label = device.get("label", "")
    match_with_id = re.match(r'^\[([^:\]]+):(\d+)\]\s+(.+)$', label)
    if match_with_id:
        room_name = match_with_id.group(1)
        room_id = match_with_id.group(2)
        return room_id, room_name

    # Strategy 3: Parse from label "[RoomName] DeviceLabel" (legacy format)
    match = re.match(r'^\[([^\]]+)\]\s+(.+)$', label)
    if match:
        room_name = match.group(1)
        return None, room_name

    return None, None


# ============================================
# Main Script
# ============================================

def main():
    print("=" * 60)
    print("  Fibaro Room Assignment Script")
    print("  SmartThings API → Room Assignment for Fibaro Devices")
    print("=" * 60)
    print()

    # Parse arguments
    dry_run = "--dry-run" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--dry-run"]

    if dry_run:
        print("  ** DRY RUN MODE - No changes will be made **")
        print()

    # Step 1: Get PAT token
    if args:
        pat_token = args[0]
    else:
        pat_token = getpass.getpass("Enter SmartThings PAT token: ")

    if not pat_token.strip():
        print("Error: PAT token is required.")
        sys.exit(1)

    client = SmartThingsClient(pat_token.strip(), dry_run=dry_run)

    # Step 2: Get location
    print("\n--- Step 1: Fetching SmartThings locations ---")
    try:
        locations = client.get_locations()
    except Exception as e:
        print(f"Error fetching locations: {e}")
        print("Check your PAT token and network connection.")
        sys.exit(1)

    if not locations:
        print("No SmartThings locations found.")
        sys.exit(1)

    if len(locations) == 1:
        location = locations[0]
        print(f"Using location: {location['name']} (ID: {location['locationId']})")
    else:
        print("Multiple locations found:")
        for i, loc in enumerate(locations):
            print(f"  {i+1}. {loc['name']} (ID: {loc['locationId']})")
        try:
            choice = int(input("Select location: ")) - 1
            location = locations[choice]
        except (ValueError, IndexError):
            print("Invalid selection.")
            sys.exit(1)

    location_id = location["locationId"]

    # Step 3: Get existing rooms
    print(f"\n--- Step 2: Fetching existing rooms in '{location['name']}' ---")
    try:
        existing_rooms = client.get_rooms(location_id)
    except Exception as e:
        print(f"Error fetching rooms: {e}")
        sys.exit(1)

    room_name_to_id = {}
    room_id_to_name = {}
    for room in existing_rooms:
        room_name_to_id[room["name"]] = room["roomId"]
        room_id_to_name[room["roomId"]] = room["name"]

    print(f"Found {len(existing_rooms)} existing SmartThings rooms:")
    for room in existing_rooms:
        print(f"  - {room['name']} (ID: {room['roomId']})")

    # Step 4: Get all devices
    print(f"\n--- Step 3: Fetching devices from SmartThings ---")
    try:
        all_devices = client.get_devices(location_id)
    except Exception as e:
        print(f"Error fetching devices: {e}")
        sys.exit(1)

    print(f"  API returned {len(all_devices)} devices")

    # Step 5: Identify Fibaro hubs first
    print(f"\n--- Step 4: Identifying Fibaro hubs/bridges ---")
    fibaro_hubs = find_fibaro_hubs(all_devices)
    fibaro_hub_ids = set(fibaro_hubs.keys())
    print(f"  Found {len(fibaro_hub_ids)} Fibaro hub(s)")

    # Step 6: Detect Fibaro devices using multi-strategy detection
    print(f"\n--- Step 5: Detecting Fibaro devices ---")
    fibaro_devices = []
    non_fibaro_devices = []

    for device in all_devices:
        device_id = device.get("deviceId", "")
        label = device.get("label", "")
        
        # Skip the hub devices themselves
        if device_id in fibaro_hub_ids:
            print(f"    [HUB]  {label} (skipping hub itself)")
            continue

        is_fibaro, method = is_fibaro_device(device, fibaro_hub_ids)
        if is_fibaro:
            fibaro_devices.append(device)
            print(f"    ✓ {label} → detected via: {method}")
        else:
            non_fibaro_devices.append(device)

    print(f"\n  Detection result: {len(fibaro_devices)} Fibaro devices, {len(non_fibaro_devices)} non-Fibaro devices")

    # Show non-Fibaro devices briefly
    if non_fibaro_devices:
        print(f"\n  Non-Fibaro devices (skipped):")
        for device in non_fibaro_devices:
            label = device.get("label", "")
            device_type = device.get("type", "")
            parent_id = device.get("parentDeviceId", "")
            print(f"    - {label} (type={device_type}, parent={parent_id[:12]}...)" if parent_id else f"    - {label} (type={device_type})")

    if not fibaro_devices:
        print("\nNo Fibaro devices found. Possible reasons:")
        print("  1. The Fibaro Edge Driver hasn't created devices yet")
        print("  2. Fibaro hub label doesn't contain 'Fibaro', 'HC3', or 'HC2'")
        print("  3. Child devices don't have [RoomName] label prefix")
        print("  4. PAT token may not have 'r:devices' scope")
        
        # Export all devices for debugging
        export_path = "fibaro_all_devices_debug.json"
        with open(export_path, "w") as f:
            json.dump(all_devices, f, indent=2)
        print(f"\n  All device data exported to: {export_path}")
        print("  Review this file to identify Fibaro devices and update detection logic.")
        sys.exit(0)

    # Step 7: Parse room info and build assignment map
    print(f"\n--- Step 6: Parsing room information from Fibaro devices ---")
    print(f"  Parsing room info from {len(fibaro_devices)} Fibaro devices...")
    print(f"  Available SmartThings rooms: {json.dumps(room_name_to_id, indent=4)}")
    print(f"  Room ID to name map: {json.dumps(room_id_to_name, indent=4)}")
    
    assignments = []
    needed_rooms = set()
    devices_without_rooms = 0

    for i, device in enumerate(fibaro_devices):
        device_id = device.get("deviceId", "")
        label = device.get("label", "")
        current_room_id = device.get("roomId")
        current_room_name = room_id_to_name.get(current_room_id, "Unknown") if current_room_id else "No Room"
        vpl = get_vendor_provided_label(device)
        
        print(f"\n  Device #{i+1}: {label}")
        print(f"    deviceId:          {device_id}")
        print(f"    label:             {label}")
        print(f"    vendorProvidedLabel: '{vpl}'")
        print(f"    current roomId:    {current_room_id}")
        print(f"    current room name: {current_room_name}")
        print(f"    parentDeviceId:    {device.get('parentDeviceId', '')}")
        print(f"    type:              {device.get('type', '')}")

        fibaro_room_id, room_name = parse_room_info(device)
        
        # Show how room info was determined
        if vpl.startswith("fibaro|"):
            print(f"    Room source:       vendorProvidedLabel (structured VPL)")
            print(f"    → Parsed VPL:      fibaro_room_id={fibaro_room_id}, room_name='{room_name}'")
        elif re.match(r'^\[([^:\]]+):(\d+)\]\s+.+$', label):
            match_with_id = re.match(r'^\[([^:\]]+):(\d+)\]\s+(.+)$', label)
            print(f"    Room source:       Label prefix '[RoomName:roomId]'")
            print(f"    → Extracted room:  '{match_with_id.group(1)}' (id={match_with_id.group(2)})")
            print(f"    → Device name:     '{match_with_id.group(3)}'")
        elif re.match(r'^\[([^\]]+)\]\s+.+$', label):
            match = re.match(r'^\[([^\]]+)\]\s+(.+)$', label)
            print(f"    Room source:       Label prefix '[RoomName]' (legacy, no roomId)")
            print(f"    → Extracted room:  '{match.group(1)}' from label '{label}'")
            print(f"    → Device name:     '{match.group(2)}'")
        else:
            print(f"    Room source:       NONE - no room info found in VPL or label")

        if room_name:
            # Check if this room already exists in SmartThings
            existing_st_room_id = room_name_to_id.get(room_name)
            room_exists = existing_st_room_id is not None
            
            assignments.append({
                "device_id": device_id,
                "device_label": label,
                "room_name": room_name,
                "fibaro_room_id": fibaro_room_id,
                "current_room_id": current_room_id,
                "current_room_name": current_room_name,
                "manufacturer": device.get("manufacturer", ""),
                "model": device.get("model", ""),
                "vpl": vpl,
            })
            if room_name not in room_name_to_id:
                needed_rooms.add(room_name)
            
            if room_exists:
                is_same_room = current_room_id == existing_st_room_id
                print(f"    Fibaro room:       '{room_name}' (fibaro_room_id={fibaro_room_id})")
                print(f"    ST room match:     '{room_name}' exists as roomId={existing_st_room_id}")
                print(f"    Already correct:   {is_same_room} (device roomId={current_room_id} vs target roomId={existing_st_room_id})")
            else:
                print(f"    Fibaro room:       '{room_name}' (fibaro_room_id={fibaro_room_id})")
                print(f"    ST room match:     NOT FOUND - room '{room_name}' needs to be created")
        else:
            devices_without_rooms += 1
            print(f"    Result:            NO ROOM INFO - skipping this device")

    print(f"\n  {len(assignments)} devices have room assignments from Fibaro")
    print(f"  {devices_without_rooms} devices have no room assignment")
    print(f"  {len(needed_rooms)} new rooms need to be created in SmartThings")

    if not assignments:
        print("\nNo devices with room assignments found. Nothing to do.")
        sys.exit(0)

    # Group by room for display
    by_room = {}
    for a in assignments:
        by_room.setdefault(a["room_name"], []).append(a)

    print(f"\n--- Room Assignment Summary ---")
    for room_name in sorted(by_room.keys()):
        devices = by_room[room_name]
        existing = room_name_to_id.get(room_name)
        existing_str = f"ID: {existing}" if existing else "NEW (needs creation)"
        print(f"\n  Fibaro Room: [{room_name}] → SmartThings Room: {existing_str}")
        for d in devices:
            already_correct = d["current_room_id"] and d["current_room_id"] == room_name_to_id.get(room_name)
            status = "✓ already in correct room" if already_correct else "→ needs room assignment"
            print(f"    {status}  {d['device_label']}")

    # Step 8: Create missing rooms
    if needed_rooms:
        print(f"\n--- Step 7: Creating missing SmartThings rooms ---")
        for room_name in sorted(needed_rooms):
            print(f"  + {room_name}")

        if not dry_run:
            confirm = input("\nCreate these rooms? (y/n) [y]: ").strip().lower()
            if confirm not in ("", "y", "yes"):
                print("Room creation skipped. Cannot assign devices without rooms.")
                sys.exit(0)

        for room_name in sorted(needed_rooms):
            try:
                new_room = client.create_room(location_id, room_name)
                room_name_to_id[room_name] = new_room["roomId"]
                room_id_to_name[new_room["roomId"]] = room_name
                print(f"  ✓ Created room: {room_name} (ID: {new_room['roomId']})")
            except Exception as e:
                print(f"  ✗ Failed to create room '{room_name}': {e}")
                room_name_to_id.pop(room_name, None)

    # Step 9: Calculate pending assignments
    pending_assignments = []
    for a in assignments:
        st_room_id = room_name_to_id.get(a["room_name"])
        if st_room_id and a["current_room_id"] != st_room_id:
            pending_assignments.append((a, st_room_id))

    if not pending_assignments:
        print("\n✓ All Fibaro devices are already in the correct rooms. Nothing to do.")
        sys.exit(0)

    # Step 10: Assign devices to rooms
    print(f"\n--- Step 8: Assigning {len(pending_assignments)} devices to rooms ---")
    for a, st_room_id in pending_assignments:
        current_room = a.get("current_room_name", "No Room")
        print(f"  {a['device_label']}  [{current_room}] → [{a['room_name']}] ({st_room_id})")

    if not dry_run:
        confirm = input("\nAssign devices to rooms? (y/n) [y]: ").strip().lower()
        if confirm not in ("", "y", "yes"):
            print("Aborted.")
            sys.exit(0)

    # Execute assignments
    success_count = 0
    fail_count = 0

    for i, (a, st_room_id) in enumerate(pending_assignments):
        # Add small delay to avoid rate limiting
        if i > 0 and not dry_run:
            time.sleep(0.3)

        try:
            client.update_device_room(a["device_id"], st_room_id)
            print(f"  ✓ {a['device_label']} → {a['room_name']}")
            success_count += 1
        except requests.exceptions.HTTPError as e:
            if e.response is not None and e.response.status_code == 429:
                retry_after = int(e.response.headers.get("Retry-After", 10))
                print(f"  ⏳ Rate limited. Waiting {retry_after}s...")
                time.sleep(retry_after)
                try:
                    client.update_device_room(a["device_id"], st_room_id)
                    print(f"  ✓ {a['device_label']} → {a['room_name']} (retry)")
                    success_count += 1
                except Exception as e2:
                    print(f"  ✗ {a['device_label']} → FAILED (retry): {e2}")
                    fail_count += 1
            else:
                print(f"  ✗ {a['device_label']} → FAILED: {e}")
                fail_count += 1
        except Exception as e:
            print(f"  ✗ {a['device_label']} → FAILED: {e}")
            fail_count += 1

    # Summary
    print(f"\n{'=' * 60}")
    print(f"  Done!")
    print(f"  {success_count} devices assigned to rooms")
    if fail_count:
        print(f"  {fail_count} devices failed")
    if dry_run:
        print(f"  (DRY RUN - no actual changes were made)")
    print(f"{'=' * 60}")

    # Export assignment details as JSON for further processing
    export_path = "fibaro_room_assignments.json"
    export_data = {
        "location_id": location_id,
        "location_name": location["name"],
        "fibaro_hubs": list(fibaro_hubs.values()),
        "total_fibaro_devices": len(fibaro_devices),
        "devices_with_rooms": len(assignments),
        "rooms_needed": list(needed_rooms),
        "assignments_made": success_count,
        "assignments_failed": fail_count,
        "devices": [
            {
                "device_id": a["device_id"],
                "label": a["device_label"],
                "fibaro_room_id": a["fibaro_room_id"],
                "fibaro_room_name": a["room_name"],
                "current_room_id": a["current_room_id"],
                "current_room_name": a.get("current_room_name", ""),
                "smartthings_room_id": room_name_to_id.get(a["room_name"]),
                "manufacturer": a["manufacturer"],
                "model": a["model"],
            }
            for a in assignments
        ]
    }

    with open(export_path, "w") as f:
        json.dump(export_data, f, indent=2)
    print(f"\nAssignment details exported to: {export_path}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nInterrupted by user.")
        sys.exit(0)
    except Exception as e:
        print(f"\nUnexpected error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
