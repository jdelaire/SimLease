#!/usr/bin/python3
import json
import os
import sys
from pathlib import Path

root = Path(os.environ["SIMLEASE_FAKE_ROOT"])
state_path = root / "simulators.json"
runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
device_type = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"


def initial_state():
    return {
        "next": 1,
        "devices": [{
            "udid": "FOREIGN",
            "name": "Foreign Simulator",
            "state": "Shutdown",
            "runtimeIdentifier": runtime,
            "deviceTypeIdentifier": device_type,
            "dataPath": str(root / "Devices" / "FOREIGN"),
        }],
    }


def load():
    if not state_path.exists():
        state = initial_state()
        save(state)
        return state
    return json.loads(state_path.read_text())


def save(state):
    temporary = state_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(state))
    temporary.replace(state_path)


args = sys.argv[1:]
state = load()

if args == ["simctl", "list", "runtimes", "-j"]:
    print(json.dumps({"runtimes": [{
        "identifier": runtime,
        "name": "iOS 27.0",
        "version": "27.0",
        "isAvailable": True,
    }]}))
elif args == ["simctl", "list", "devicetypes", "-j"]:
    print(json.dumps({"devicetypes": [{
        "identifier": device_type,
        "name": "iPhone 17 Pro",
    }]}))
elif args == ["simctl", "list", "devices", "-j"]:
    print(json.dumps({"devices": {
        runtime: [{key: value for key, value in device.items()
                   if key != "runtimeIdentifier"}
                  for device in state["devices"]]
    }}))
elif len(args) == 5 and args[:2] == ["simctl", "create"]:
    udid = f"MANAGED-{state['next']}"
    state["next"] += 1
    state["devices"].append({
        "udid": udid,
        "name": args[2],
        "state": "Booted",
        "runtimeIdentifier": args[4],
        "deviceTypeIdentifier": args[3],
        "dataPath": str(root / "Devices" / udid),
    })
    save(state)
    print(udid)
elif len(args) == 3 and args[:2] == ["simctl", "shutdown"]:
    for device in state["devices"]:
        if device["udid"] == args[2]:
            device["state"] = "Shutdown"
            save(state)
            sys.exit(0)
    sys.exit(148)
elif len(args) == 3 and args[:2] == ["simctl", "boot"]:
    for device in state["devices"]:
        if device["udid"] == args[2]:
            device["state"] = "Booted"
            save(state)
            sys.exit(0)
    sys.exit(148)
elif len(args) == 3 and args[:2] == ["simctl", "delete"]:
    udid = args[2]
    with (root / "delete.log").open("a") as log:
        log.write(f"delete {udid}\n")
    if udid == "FOREIGN":
        sys.exit(99)
    before = len(state["devices"])
    state["devices"] = [device for device in state["devices"]
                        if device["udid"] != udid]
    if len(state["devices"]) == before:
        sys.exit(148)
    save(state)
else:
    print(f"unexpected xcrun command: {' '.join(args)}", file=sys.stderr)
    sys.exit(97)
