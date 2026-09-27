#!/usr/bin/env python3
"""Check every BLAKE2b EFI path in the generated Limine configuration."""

import argparse
import hashlib
import re
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("--config", type=Path, default=Path("/boot/limine.conf"))
parser.add_argument("--boot", type=Path, default=Path("/boot"))
args = parser.parse_args()

pattern = re.compile(r"^\s*path:\s+boot\(\):(/[^#\s]+)#([0-9a-fA-F]{128})\s*$")
expected = {}
for line_number, line in enumerate(args.config.read_text().splitlines(), 1):
    match = pattern.match(line)
    if not match:
        continue
    relative, digest = match.groups()
    path = args.boot / relative.lstrip("/")
    expected.setdefault(path, set()).add(digest.lower())

if not expected:
    parser.exit(2, f"No hashed EFI paths found in {args.config}\n")

failures = 0
for path, digests in sorted(expected.items()):
    try:
        with path.open("rb") as stream:
            hasher = hashlib.blake2b()
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                hasher.update(block)
            actual = hasher.hexdigest()
    except OSError as error:
        print(f"MISSING {path}: {error}")
        failures += 1
        continue
    if digests != {actual}:
        print(f"MISMATCH {path}: file={actual} configured={','.join(sorted(digests))}")
        failures += 1
    else:
        print(f"OK {path}")

print(f"Checked {len(expected)} distinct EFI targets; failures={failures}")
raise SystemExit(1 if failures else 0)
