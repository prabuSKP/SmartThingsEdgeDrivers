#!/usr/bin/env python3
import json
import os
import re

# Paths relative to the root of the repository
raw_path = "logs/may_22/raw_reconstructed.json"
output_dir = "logs/may_22/devices"
complete_path = "logs/may_22/complete_devices.json"

if not os.path.exists(raw_path):
    print(f"Error: {raw_path} not found. Please make sure to run this script from the repository root.")
    exit(1)

if not os.path.exists(output_dir):
    os.makedirs(output_dir)

with open(raw_path, "r", encoding="utf-8") as f:
    content = f.read().strip()

start_idx = content.find("[{")
if start_idx == -1:
    print("Could not find start '[{' of JSON array.")
    exit(1)

json_str = content[start_idx:]

try:
    decoder = json.JSONDecoder()
    devices, end_pos = decoder.raw_decode(json_str)
    print(f"Successfully decoded JSON array! Total devices: {len(devices)}")
    
    # Save individual devices
    for dev in devices:
        dev_id = dev.get("id")
        dev_name = dev.get("name", "unnamed")
        # Sanitize filename
        safe_name = re.sub(r'[^a-zA-Z0-9_\-]', '_', str(dev_name))
        filename = f"device_{dev_id}_{safe_name}.json"
        filepath = os.path.join(output_dir, filename)
        
        with open(filepath, "w", encoding="utf-8") as out_f:
            json.dump(dev, out_f, indent=2)
            
    print(f"Successfully wrote {len(devices)} device JSON files to {output_dir}")
    
    # Also save a complete_devices.json for reference in may_22 log folder
    with open(complete_path, "w", encoding="utf-8") as out_c:
        json.dump(devices, out_c, indent=2)
    print(f"Successfully wrote complete_devices.json to {complete_path}")

except Exception as e:
    print(f"Error parsing or saving devices: {e}")
    # Print the beginning of the string to see what went wrong
    print(f"Start of json_str: {json_str[:200]}")
