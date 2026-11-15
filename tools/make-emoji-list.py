#!/usr/bin/env python3
"""Builds Resources/emoji.tsv from Unicode's emoji-test.txt.

Usage: python3 -I tools/make-emoji-list.py path/to/emoji-test.txt > Resources/emoji.tsv
Source: https://unicode.org/Public/emoji/latest/emoji-test.txt (Unicode terms of use)

Output: one line per emoji, "group<TAB>emoji<TAB>name", in CLDR order.
Keeps fully-qualified emoji only and leaves out skin-tone variants and the
Component group, so the picker shows one face per emoji, like Apple's grid.
Drift drops any emoji this Mac's font can't draw when it loads the list.
"""
import re
import sys

SKIN_TONES = {0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF}
line_re = re.compile(r"^([0-9A-F ]+?)\s*;\s*fully-qualified\s*#\s*(\S+)\s+E[\d.]+\s+(.+)$")

group = None
out = []
for raw in open(sys.argv[1], encoding="utf-8"):
    raw = raw.rstrip("\n")
    if raw.startswith("# group:"):
        group = raw.split(":", 1)[1].strip()
        continue
    if group in (None, "Component"):
        continue
    m = line_re.match(raw)
    if not m:
        continue
    points = [int(p, 16) for p in m.group(1).split()]
    if SKIN_TONES & set(points):
        continue
    out.append(f"{group}\t{m.group(2)}\t{m.group(3)}")

sys.stdout.write("\n".join(out) + "\n")
