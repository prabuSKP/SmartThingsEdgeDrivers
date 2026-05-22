#!/usr/bin/env python3
"""
Fibaro Room Diagnostic Script

Analyzes current device-to-room assignments and identifies:
1. Fibaro devices in wrong rooms
2. Duplicate rooms (case-insensitive)
3. Devices that need label cleanup

Uses the SmartThings REST API with a PAT token.

Usage:
    python3 fibaro_room_diagnostic.py YOUR_PAT_TOKEN
    python3 fibaro_room_diagnostic.py --export YOUR_PAT_TOKEN  # Also exports detailed JSON
"""

import requests
import re
import sys
import json
import getpass
from typing import Optional, Dict, List, Tuple

SMARTTHINGS_API_BASE = "https://api.smartthings.com/v1"


def normalize_room_name(room_name: str) -> str:
    """Normalize room name for case-insensitive comparison."""
    return room_name.strip().lower()


def extract_room_from_label(label: str) -> Tuple[Optional[str], Optional[str], str]:
    """
    Extract room info from device label.
    
    Returns (room_name, room_id, clean_name):
    - room_name: Extracted room name (e.g., "GBR")
    - room_id: Extracted room ID (e.g., "219")
    - clean_name: Device name without prefix
    """
    # Pattern: [RoomName:roomId] DeviceName
    match = re.match(r'^\[([^:\]]+):(\d+)\]\s*(.+)$', label)
    if match:
        return match.group(1), match.group(2), match.group(3).strip()
    
    # Pattern: [RoomName] DeviceName (legacy)
    match = re.match(r'^\[([^\]]+)\]\s*(.+)$', label)
    if match:
        return match.group(1), None, match.group(2).strip()
    
    return None, None, label


class SmartThingsClient:
    """Client for SmartThings REST API."""

    def __init__(self, pat_token: str):
        self.token = pat_token
        self.headers = {
            "Authorization": f"Bearer {pat_token}",
            "Accept": "application/json",
        }

    def _request(self, method: str, url: str, **kwargs) -> requests.Response:
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
        resp = self._request("GET", f"{SMARTTHINGS_API_BASE}/locations")
        resp.raise_for_status()
        return resp.json().get("items", [])

    def get_rooms(self, location_id: str) -> list:
        resp = self._request("GET", f"{SMARTTHINGS_API_BASE}/locations/{location_id}/rooms")
        resp.raise_for_status()
        return resp.json().get("items", [])

    def get_devices(self, location_id: Optional[str] = None) -> list:
        params = {"locationId": location_id, "capabilityStatus": "false"} if location_id else {}
        all_devices = []
        url = f"{SMARTTHINGS_API_BASE}/devices"

        while url:
            resp = self._request("GET", url, params=params)
            resp.raise_for_status()
            data = resp.json()
            all_devices.extend(data.get("items", []))

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
            params = {}

        return all_devices


def find_fibaro_hubs(all_devices: list) -> set:
    """Find Fibaro hub device IDs."""
    fibaro_hubs = set()
    keywords = ["fibaro", "hc3", "hc2"]
    
    for device in all_devices:
        label = (device.get("label") or "").lower()
        device_type = (device.get("type") or "").upper()
        
        if device_type == "LAN" and any(kw in label for kw in keywords):
            fibaro_hubs.add(device.get("deviceId", ""))
    
    return fibaro_hubs


def is_fibaro_device(device: dict, fibaro_hub_ids: set) -> bool:
    """Check if device is a Fibaro device."""
    parent_id = device.get("parentDeviceId", "")
    label = device.get("label", "")
    device_type = (device.get("type") or "").upper()
    
    # Child of Fibaro hub
    if parent_id and parent_id in fibaro_hub_ids:
        return True
    
    # Has [RoomName] prefix
    if device_type == "EDGE_CHILD" and re.match(r'^\[[^\]]+\]\s+.+$', label):
        return True
    
    return False


def main():
    print("=" * 70)
    print("  Fibaro Room Diagnostic Script")
    print("  Analyzing device-to-room assignments...")
    print("=" * 70)
    print()

    # Get PAT token
    args = sys.argv[1:]
    export_mode = "--export" in args
    args = [a for a in args if a != "--export"]
    
    if args:
        pat_token = args[0]
    else:
        pat_token = getpass.getpass("Enter SmartThings PAT token: ")

    if not pat_token.strip():
        print("Error: PAT token is required.")
        sys.exit(1)

    client = SmartThingsClient(pat_token.strip())

    # Get location
    print("--- Fetching locations ---")
    locations = client.get_locations()
    if not locations:
        print("No locations found.")
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
            if choice < 0 or choice >= len(locations):
                print("Invalid selection.")
                sys.exit(1)
            location = locations[choice]
        except (ValueError, IndexError):
            print("Invalid selection.")
            sys.exit(1)
    
    location_id = location["locationId"]

    # Get rooms
    print("\n--- Fetching rooms ---")
    rooms = client.get_rooms(location_id)
    room_name_to_id = {r["name"]: r["roomId"] for r in rooms}
    room_id_to_name = {r["roomId"]: r["name"] for r in rooms}
    
    print(f"Found {len(rooms)} rooms:")
    for room in rooms:
        print(f"  - {room['name']} (ID: {room['roomId']})")

    # Detect duplicate rooms (case-insensitive)
    print("\n--- Checking for Duplicate Rooms ---")
    normalized_rooms = {}
    duplicate_rooms = []
    
    for room_name, room_id in room_name_to_id.items():
        normalized = normalize_room_name(room_name)
        if normalized in normalized_rooms:
            duplicate_rooms.append((normalized_rooms[normalized], room_name))
            print(f"  ⚠️  DUPLICATE: '{normalized_rooms[normalized]}' vs '{room_name}'")
        else:
            normalized_rooms[normalized] = room_name
    
    if not duplicate_rooms:
        print("  ✓ No duplicate rooms found")

    # Get devices
    print("\n--- Fetching devices ---")
    all_devices = client.get_devices(location_id)
    print(f"Found {len(all_devices)} devices")

    # Find Fibaro hubs
    fibaro_hub_ids = find_fibaro_hubs(all_devices)
    print(f"Found {len(fibaro_hub_ids)} Fibaro hub(s)")

    # Analyze Fibaro devices
    print("\n--- Analyzing Fibaro Devices ---")
    
    def check_is_fibaro(device):
        """Local function to check if device is Fibaro."""
        return is_fibaro_device(device, fibaro_hub_ids)
    
    fibaro_devices = [d for d in all_devices if check_is_fibaro(d) 
                      and d.get("deviceId") not in fibaro_hub_ids]
    
    print(f"Found {len(fibaro_devices)} Fibaro devices")

    # Group ALL devices by CURRENT room (actual room assignment from SmartThings)
    all_devices_by_room = {}
    fibaro_devices_by_room = {}
    misplaced_devices = []
    devices_needing_label_cleanup = []

    for device in all_devices:
        device_id = device.get("deviceId", "")
        label = device.get("label", "")
        current_room_id = device.get("roomId")
        
        # Get current room name from the room_id_to_name dict
        if current_room_id and current_room_id in room_id_to_name:
            current_room_name = room_id_to_name[current_room_id]
        else:
            current_room_name = "No Room"
        
        # Group ALL devices by room
        if current_room_name not in all_devices_by_room:
            all_devices_by_room[current_room_name] = []
        all_devices_by_room[current_room_name].append(device)
        
        # Also track Fibaro devices separately
        if is_fibaro_device(device, fibaro_hub_ids) and device.get("deviceId") not in fibaro_hub_ids:
            if current_room_name not in fibaro_devices_by_room:
                fibaro_devices_by_room[current_room_name] = []
            fibaro_devices_by_room[current_room_name].append(device)
            
            # Extract expected room from label
            expected_room, expected_room_id, clean_name = extract_room_from_label(label)
            
            # Check if misplaced
            if expected_room:
                target_room_id = room_name_to_id.get(expected_room)
                if not target_room_id:
                    for rn, rid in room_name_to_id.items():
                        if normalize_room_name(rn) == normalize_room_name(expected_room):
                            target_room_id = rid
                            break
                
                if target_room_id and current_room_id != target_room_id:
                    misplaced_devices.append({
                        "device_id": device_id,
                        "label": label,
                        "clean_name": clean_name,
                        "current_room": current_room_name,
                        "current_room_id": current_room_id,
                        "expected_room": expected_room,
                        "expected_room_id": expected_room_id,
                        "target_room_id": target_room_id,
                    })
            
            # Check if label needs cleanup
            if label.startswith("["):
                devices_needing_label_cleanup.append({
                    "device_id": device_id,
                    "current_label": label,
                    "clean_label": clean_name,
                })
        

    # Report by room - show ALL devices grouped by their CURRENT room assignment
    print("\n--- Devices by Current Room (ALL DEVICES LISTED) ---")
    for room_name in sorted(all_devices_by_room.keys()):
        all_room_devices = all_devices_by_room[room_name]
        fibaro_room_devices = fibaro_devices_by_room.get(room_name, [])
        total_count = len(all_room_devices)
        fibaro_count = len(fibaro_room_devices)
        
        # Get the room ID for this room name
        if room_name == "No Room":
            room_id_display = "Not Assigned"
        else:
            room_id = room_name_to_id.get(room_name)
            room_id_display = room_id if room_id else "Unknown ID"
        
        print(f"\n  {room_name} (ID: {room_id_display}): {total_count} devices ({fibaro_count} Fibaro)")
        print(f"  {'-' * 60}")
        
        # Show ALL devices (no truncation)
        for idx, d in enumerate(all_room_devices, 1):
            label = d.get("label", "")
            device_id = d.get("deviceId", "")
            device_type = d.get("type", "")
            current_room_id = d.get("roomId")
            is_fibaro = d in fibaro_room_devices
            expected_room, expected_room_id, clean_name = extract_room_from_label(label)
            
            # Show Fibaro indicator
            fibaro_marker = "🔹" if is_fibaro else "  "
            
            # Check if this device belongs in a different room
            if expected_room:
                target_room_id = room_name_to_id.get(expected_room)
                if not target_room_id:
                    for rn, rid in room_name_to_id.items():
                        if normalize_room_name(rn) == normalize_room_name(expected_room):
                            target_room_id = rid
                            break
                
                if target_room_id and current_room_id != target_room_id:
                    print(f"    {idx}. {fibaro_marker} ⚠️  MISPLACED: '{label}'")
                    print(f"           Device ID: {device_id}, Type: {device_type}")
                    print(f"           Current: {room_name} → Should be: {expected_room}")
                else:
                    print(f"    {idx}. {fibaro_marker} ✓  '{label}'")
            else:
                print(f"    {idx}. {fibaro_marker}   '{label}'")

    # Report misplaced devices
    print("\n--- Misplaced Devices ---")
    if misplaced_devices:
        print(f"Found {len(misplaced_devices)} Fibaro devices in wrong rooms:")
        for m in misplaced_devices[:20]:
            print(f"  ⚠️  '{m['label']}'")
            print(f"      Current: {m['current_room']} → Should be: {m['expected_room']}")
        if len(misplaced_devices) > 20:
            print(f"  ... and {len(misplaced_devices) - 20} more")
    else:
        print("  ✓ All Fibaro devices are in correct rooms")

    # Report label cleanup
    print("\n--- Devices Needing Label Cleanup ---")
    if devices_needing_label_cleanup:
        print(f"Found {len(devices_needing_label_cleanup)} devices with [RoomName:roomId] prefix:")
        for d in devices_needing_label_cleanup[:10]:
            print(f"  '{d['current_label']}' → '{d['clean_label']}'")
        if len(devices_needing_label_cleanup) > 10:
            print(f"  ... and {len(devices_needing_label_cleanup) - 10} more")
    else:
        print("  ✓ No devices need label cleanup")

    # Export detailed report
    if export_mode:
        export_data = {
            "location_id": location_id,
            "location_name": location["name"],
            "total_rooms": len(rooms),
            "duplicate_rooms": duplicate_rooms,
            "total_devices": len(all_devices),
            "fibaro_devices": len(fibaro_devices),
            "misplaced_devices": misplaced_devices,
            "devices_needing_label_cleanup": devices_needing_label_cleanup,
            "all_devices_by_room": {
                room: [
                    {
                        "deviceId": d.get("deviceId"),
                        "label": d.get("label"),
                        "type": d.get("type"),
                    }
                    for d in devices
                ]
                for room, devices in all_devices_by_room.items()
            },
            "fibaro_devices_by_room": {
                room: [
                    {
                        "deviceId": d.get("deviceId"),
                        "label": d.get("label"),
                        "type": d.get("type"),
                    }
                    for d in devices
                ]
                for room, devices in fibaro_devices_by_room.items()
            },
        }
        
        export_path = "fibaro_room_diagnostic.json"
        with open(export_path, "w") as f:
            json.dump(export_data, f, indent=2)
        print(f"\nDetailed report exported to: {export_path}")

    # Summary
    print("\n" + "=" * 70)
    print("  SUMMARY")
    print("=" * 70)
    print(f"  Total rooms: {len(rooms)}")
    print(f"  Duplicate room pairs: {len(duplicate_rooms)}")
    print(f"  Fibaro devices: {len(fibaro_devices)}")
    print(f"  Misplaced devices: {len(misplaced_devices)}")
    print(f"  Devices needing label cleanup: {len(devices_needing_label_cleanup)}")
    
    if misplaced_devices or duplicate_rooms:
        print("\n  Recommended action: Run fibaro_room_assigner.py to fix assignments")
    print("=" * 70)

    # Optional: View devices in a specific room
    print("\n--- View Devices in Specific Room ---")
    print("  Enter room number to view ALL devices in that room, or press Enter to skip")
    for i, room in enumerate(rooms, 1):
        all_count = len(all_devices_by_room.get(room["name"], []))
        fibaro_count = len(fibaro_devices_by_room.get(room["name"], []))
        print(f"  {i}. {room['name']} (ID: {room['roomId']}) - {all_count} devices ({fibaro_count} Fibaro)")
    
    try:
        choice = input("\n  Select room number: ").strip()
        if choice and choice.isdigit():
            choice_idx = int(choice) - 1
            if 0 <= choice_idx < len(rooms):
                selected_room = rooms[choice_idx]
                selected_room_name = selected_room["name"]
                selected_room_id = selected_room["roomId"]
                all_room_devices = all_devices_by_room.get(selected_room_name, [])
                
                print(f"\n{'=' * 70}")
                print(f"  ALL Devices in '{selected_room_name}' (ID: {selected_room_id})")
                print(f"  Total: {len(all_room_devices)} devices")
                print(f"{'=' * 70}")
                
                if all_room_devices:
                    for idx, d in enumerate(all_room_devices, 1):
                        label = d.get("label", "")
                        device_id = d.get("deviceId", "")
                        device_type = d.get("type", "")
                        is_fibaro_dev = d in fibaro_devices_by_room.get(selected_room_name, [])
                        fibaro_marker = "[Fibaro] " if is_fibaro_dev else ""
                        
                        print(f"\n  {idx}. {fibaro_marker}Device: '{label}'")
                        print(f"      Device ID:   {device_id}")
                        print(f"      Type:        {device_type}")
                else:
                    print("  No devices in this room.")
                print(f"{'=' * 70}")
    except (ValueError, IndexError, EOFError):
        pass  # Skip if invalid input or interrupted


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
