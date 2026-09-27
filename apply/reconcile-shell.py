#!/usr/bin/env python3
"""Register the mbp133 Omarchy plugins/widgets without replacing shell.json."""

import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("path", type=Path)
parser.add_argument("--check", action="store_true")
args = parser.parse_args()

original = args.path.read_text()
config = json.loads(original)
plugins = config.setdefault("plugins", [])


def configure_plugin(identifier, values):
    entry = next(
        (item for item in plugins if isinstance(item, dict) and item.get("id") == identifier),
        None,
    )
    if entry is None:
        entry = {"id": identifier}
        plugins.append(entry)
    entry.update(values)


configure_plugin("local.touchbar-idle", {"timeout": 10})
configure_plugin(
    "local.idle-suspend",
    {"timeout": 900, "cooldown": 300, "onBatteryOnly": True, "dryRun": True},
)

right = config.setdefault("bar", {}).setdefault("layout", {}).setdefault("right", [])
if isinstance(right, list):
    wanted = {
        "fan": {
            "id": "fan",
            "type": "command",
            "exec": "~/.config/omarchy/bar/scripts/fan-speed",
            "interval": 60,
        },
        "power-draw": {
            "id": "power-draw",
            "type": "command",
            "exec": "~/.config/omarchy/bar/scripts/power-draw",
            "interval": 10,
            "tooltip": "Current battery power",
        },
    }
    for identifier, value in wanted.items():
        current = next(
            (item for item in right if isinstance(item, dict) and item.get("id") == identifier),
            None,
        )
        if current is None:
            index = next(
                (
                    i
                    for i, item in enumerate(right)
                    if isinstance(item, dict) and item.get("id") == "omarchy.power"
                ),
                len(right),
            )
            right.insert(index, value)
        else:
            current.update(value)

rendered = json.dumps(config, indent=2) + "\n"
changed = rendered != original
if changed and not args.check:
    args.path.write_text(rendered)
print("CHANGED" if changed else "UNCHANGED")
