"""Verify every byte of the core grain tile using Python's standard SHA-256.
The spec runner compares its dimensions and prefix; this checks its full hash.
No runtime browser dependency or network access.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

fixture = json.loads(Path(sys.argv[2]).read_text())
case = next(c for c in fixture["cases"] if c["name"] == "grain tile")
expected = case["expected"]["sha256_rgba"]
with tempfile.TemporaryDirectory(prefix="birch-grain.") as scratch:
    tile = Path(scratch) / "grain.rgba"
    subprocess.run([sys.argv[1], "--grain", str(tile)], check=True)
    actual = hashlib.sha256(tile.read_bytes()).hexdigest()
print(f"theme: grain SHA-256 expected={expected} got={actual}")
sys.exit(0 if actual == expected else 1)
