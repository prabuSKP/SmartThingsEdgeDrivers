---
name: python-mapping-tools
description: >
  Use Python tools to automate profile YAML generation and capability mappings.
  Covers writing Python scripts to parse vendor device API JSON responses, auto-match
  devices to SmartThings capabilities, and export valid device profile YAML files.
  Use when: (1) scaffolding a large number of device profiles, (2) converting vendor schemas,
  or (3) validating YAML profiles against the SmartThings capability schema.
---

# Python Automation for Device Profile Generation

When building LAN bridge drivers that support dozens of vendor devices (like Fibaro or Home Assistant), manually writing YAML device profiles is tedious and error-prone. This skill covers using Python scripts to parse vendor device schemas and auto-generate SmartThings profile `.yml` files.

---

## 1. Automated Profile Scaffolder (Python)

This script parses a vendor device list JSON payload, identifies the device types, and outputs a corresponding SmartThings device profile YAML file.

### Python Requirements
Install dependencies:
```bash
pip install pyyaml
```

### Script: `scaffold_profiles.py`
```python
import json
import os
import yaml

# Mapping between vendor attributes and SmartThings capabilities
CAPABILITY_MAP = {
    "binarySwitch": ["switch"],
    "multilevelSwitch": ["switch", "switchLevel"],
    "colorController": ["switch", "colorControl", "colorTemperature"],
    "doorSensor": ["contactSensor", "battery"],
    "motionSensor": ["motionSensor", "temperatureMeasurement", "battery"],
    "tempSensor": ["temperatureMeasurement", "battery"]
}

CATEGORY_MAP = {
    "binarySwitch": "Switch",
    "multilevelSwitch": "Light",
    "colorController": "Light",
    "doorSensor": "ContactSensor",
    "motionSensor": "MotionSensor",
    "tempSensor": "TemperatureSensor"
}

def generate_profile(device_id, device_type, label, output_dir):
    capabilities = CAPABILITY_MAP.get(device_type, ["switch"])
    category = CATEGORY_MAP.get(device_type, "Switch")
    
    # Structure matching the SmartThings device profile schema
    profile_data = {
        "name": f"vendor-{device_type.lower()}",
        "components": [
            {
                "id": "main",
                "capabilities": [{"id": cap} for cap in capabilities],
                "categories": [{"name": category}]
            }
        ],
        "metadata": {
            "deviceNetworkId": f"vendor-{device_id}"
        }
    }
    
    # Save as .yml (NOT .yaml)
    filename = os.path.join(output_dir, f"vendor_{device_type.lower()}.yml")
    with open(filename, 'w') as f:
        yaml.dump(profile_data, f, default_flow_style=False, sort_keys=False)
    print(f"Generated profile: {filename}")

# Example Usage
if __name__ == "__main__":
    vendor_payload = """
    [
        {"id": 101, "type": "binarySwitch", "name": "Kitchen Outlet"},
        {"id": 102, "type": "multilevelSwitch", "name": "Living Room Dimmer"},
        {"id": 103, "type": "motionSensor", "name": "Hallway Motion"}
    ]
    """
    
    devices = json.loads(vendor_payload)
    os.makedirs("./profiles", exist_ok=True)
    
    for dev in devices:
        generate_profile(dev["id"], dev["type"], dev["name"], "./profiles")
```

---

## 2. Parsing Vendor Databases for Lua Mappers

In addition to profiles, you can auto-generate the Lua mapping tables used in your `mapper.lua` file.

### Script: `generate_lua_mapper.py`
This script takes the vendor database and generates a static Lua look-up table:

```python
import json

def generate_lua_map(devices):
    lua_code = ["-- Auto-generated Mapper Table\nlocal mapper_table = {"]
    
    for dev in devices:
        dev_type = dev["type"]
        lua_code.append(f'  ["{dev_type}"] = {{')
        lua_code.append(f'    profile = "vendor_{dev_type.lower()}",')
        lua_code.append('    capabilities = {')
        
        if dev_type == "binarySwitch":
            lua_code.append('      { id = "switch", attr = "switch" }')
        elif dev_type == "multilevelSwitch":
            lua_code.append('      { id = "switch", attr = "switch" },')
            lua_code.append('      { id = "switchLevel", attr = "level" }')
            
        lua_code.append('    }')
        lua_code.append('  },')
        
    lua_code.append("}\nreturn mapper_table")
    return "\n".join(lua_code)

devices = [
    {"type": "binarySwitch"},
    {"type": "multilevelSwitch"}
]

print(generate_lua_map(devices))
```

### Generated Lua Output:
```lua
-- Auto-generated Mapper Table
local mapper_table = {
  ["binarySwitch"] = {
    profile = "vendor_binaryswitch",
    capabilities = {
      { id = "switch", attr = "switch" }
    }
  },
  ["multilevelSwitch"] = {
    profile = "vendor_multilevelswitch",
    capabilities = {
      { id = "switch", attr = "switch" },
      { id = "switchLevel", attr = "level" }
    }
  },
}
return mapper_table
```
This output can be directly written to `src/vendor/mapper_table.lua` and imported into the Edge driver.
