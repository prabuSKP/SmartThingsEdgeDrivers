#!/usr/bin/env python3
"""Generate a Phase 2 multi-endpoint energy simulator ZAP.

This composes a new .zap file from existing connectedhomeip examples in the
local checkout:

- evse-app: provides the Electrical Sensor + DEM cluster definitions used by
  the Linux-capable energy app in this branch.
- energy-gateway-app: provides the meter-side cluster definitions.

The generated topology is:
  endpoint 0: Root Node
  endpoint 1: Electrical Sensor (0x0510)
  endpoint 2: Device Energy Management (0x050D)
  endpoint 3: Electrical Meter (0x0514)
  endpoint 4: Electrical Utility Meter (0x0511)
"""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path


PROFILE_ID = 259


DEVICE_TYPE_LIBRARY = {
    "electrical_sensor": {
        "code": 1296,
        "label": "Electrical Sensor",
        "name": "Electrical Sensor",
        "version": 1,
    },
    "device_energy_management": {
        "code": 1293,
        "label": "Device Energy Management",
        "name": "Device Energy Management",
        "version": 2,
    },
    "electrical_meter": {
        "code": 1300,
        "label": "Electrical Meter",
        "name": "Electrical Meter",
        "version": 1,
    },
    "electrical_utility_meter": {
        "code": 1297,
        "label": "Electrical Utility Meter",
        "name": "Electrical Utility Meter",
        "version": 1,
    },
}


ENDPOINT_BLUEPRINTS = [
    {
        "endpoint_type_id": 2,
        "endpoint_id": 1,
        "name": "Phase2 Electrical Sensor",
        "device_type_key": "electrical_sensor",
        "cluster_sources": [
            ("evse", "Identify"),
            ("evse", "Descriptor"),
            ("evse", "Electrical Power Measurement"),
            ("evse", "Electrical Energy Measurement"),
            ("evse", "Power Topology"),
        ],
    },
    {
        "endpoint_type_id": 3,
        "endpoint_id": 2,
        "name": "Phase2 Device Energy Management",
        "device_type_key": "device_energy_management",
        "cluster_sources": [
            ("evse", "Identify"),
            ("evse", "Descriptor"),
            ("evse", "Device Energy Management"),
            ("evse", "Device Energy Management Mode"),
        ],
    },
    {
        "endpoint_type_id": 4,
        "endpoint_id": 3,
        "name": "Phase2 Electrical Meter",
        "device_type_key": "electrical_meter",
        "cluster_sources": [
            ("evse", "Identify"),
            ("evse", "Descriptor"),
            ("evse", "Electrical Power Measurement"),
            ("evse", "Electrical Energy Measurement"),
            ("gateway", "Commodity Metering"),
        ],
    },
    {
        "endpoint_type_id": 5,
        "endpoint_id": 4,
        "name": "Phase2 Electrical Utility Meter",
        "device_type_key": "electrical_utility_meter",
        "cluster_sources": [
            ("gateway", "Identify"),
            ("gateway", "Descriptor"),
            ("gateway", "Meter Identification"),
        ],
    },
]


def parse_args() -> argparse.Namespace:
    repo_root = Path(__file__).resolve().parent.parent
    default_evse = repo_root / "connectedhomeip" / "examples" / "evse-app" / "evse-common" / "evse-app.zap"
    default_gateway = (
        repo_root
        / "connectedhomeip"
        / "examples"
        / "energy-gateway-app"
        / "energy-gateway-common"
        / "energy-gateway-app.zap"
    )
    default_output = (
        repo_root
        / "connectedhomeip"
        / "examples"
        / "evse-app"
        / "evse-common"
        / "phase2-energy-simulator.zap"
    )

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evse-zap", type=Path, default=default_evse)
    parser.add_argument("--gateway-zap", type=Path, default=default_gateway)
    parser.add_argument("--output", type=Path, default=default_output)
    return parser.parse_args()


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as infile:
        return json.load(infile)


def cluster_map(endpoint_type: dict) -> dict[str, dict]:
    return {cluster["name"]: cluster for cluster in endpoint_type["clusters"]}


def build_device_type_spec(device_type_key: str) -> tuple[dict, list[dict], list[int], list[int]]:
    entry = DEVICE_TYPE_LIBRARY[device_type_key]
    device_type_ref = {
        "code": entry["code"],
        "profileId": PROFILE_ID,
        "label": entry["label"],
        "name": entry["name"],
        "deviceTypeOrder": 0,
    }
    return (
        device_type_ref,
        [copy.deepcopy(device_type_ref)],
        [entry["version"]],
        [entry["code"]],
    )


def build_endpoint_type(blueprint: dict, evse_clusters: dict[str, dict], gateway_clusters: dict[str, dict]) -> dict:
    device_type_ref, device_types, device_versions, device_identifiers = build_device_type_spec(
        blueprint["device_type_key"]
    )

    selected_clusters = []
    for source_name, cluster_name in blueprint["cluster_sources"]:
        source_clusters = evse_clusters if source_name == "evse" else gateway_clusters
        if cluster_name not in source_clusters:
            raise KeyError(f"Cluster '{cluster_name}' not found in {source_name} source ZAP")
        selected_clusters.append(copy.deepcopy(source_clusters[cluster_name]))

    return {
        "id": blueprint["endpoint_type_id"],
        "name": blueprint["name"],
        "deviceTypeRef": device_type_ref,
        "deviceTypes": device_types,
        "deviceVersions": device_versions,
        "deviceIdentifiers": device_identifiers,
        "deviceTypeName": device_type_ref["name"],
        "deviceTypeCode": device_type_ref["code"],
        "deviceTypeProfileId": PROFILE_ID,
        "clusters": selected_clusters,
    }


def build_endpoint_record(blueprint: dict, endpoint_type_index: int) -> dict:
    return {
        "endpointTypeName": blueprint["name"],
        "endpointTypeIndex": endpoint_type_index,
        "profileId": PROFILE_ID,
        "endpointId": blueprint["endpoint_id"],
        "networkId": 0,
        "parentEndpointIdentifier": None,
    }


def main() -> int:
    args = parse_args()
    evse_json = load_json(args.evse_zap)
    gateway_json = load_json(args.gateway_zap)

    evse_endpoint_types = evse_json["endpointTypes"]
    gateway_endpoint_types = gateway_json["endpointTypes"]
    if len(evse_endpoint_types) < 2:
        raise ValueError("EVSE ZAP does not contain the expected root + application endpoint types")
    if len(gateway_endpoint_types) < 2:
        raise ValueError("Gateway ZAP does not contain the expected root + application endpoint types")

    root_endpoint_type = copy.deepcopy(evse_endpoint_types[0])
    root_endpoint = copy.deepcopy(evse_json["endpoints"][0])

    evse_clusters = cluster_map(evse_endpoint_types[1])
    gateway_clusters = cluster_map(gateway_endpoint_types[1])

    new_endpoint_types = [root_endpoint_type]
    new_endpoints = [root_endpoint]

    for endpoint_type_index, blueprint in enumerate(ENDPOINT_BLUEPRINTS, start=1):
        new_endpoint_types.append(build_endpoint_type(blueprint, evse_clusters, gateway_clusters))
        new_endpoints.append(build_endpoint_record(blueprint, endpoint_type_index))

    output_json = copy.deepcopy(evse_json)
    output_json["endpointTypes"] = new_endpoint_types
    output_json["endpoints"] = new_endpoints

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as outfile:
        json.dump(output_json, outfile, indent=2)
        outfile.write("\n")

    print(f"Wrote {args.output}")
    print("Endpoints:")
    for blueprint in ENDPOINT_BLUEPRINTS:
        spec = DEVICE_TYPE_LIBRARY[blueprint["device_type_key"]]
        print(f"  - endpoint {blueprint['endpoint_id']}: {spec['name']} (0x{spec['code']:04X})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
