#!/usr/bin/env python3
"""Positive control for hintref.py: bytecode hinting must move points.

This is the break-fix guard for the TrueType interpreter's reference leg. If
the tool ever stops invoking FreeType's native interpreter -- a wrong load
flag, a version drift, a stubbed point dump -- the hinted and unhinted point
arrays become identical and this check fails. It does not test the engine;
it proves the reference used to pin the engine is actually measuring the
thing it claims to measure.

Usage: python3 tools/hintref_check.py HINTED.json UNHINTED.json
"""
import json
import sys


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    hinted = json.load(open(sys.argv[1], encoding="utf-8"))
    plain = json.load(open(sys.argv[2], encoding="utf-8"))
    hp, up = hinted["points"], plain["points"]
    if len(hp) != len(up):
        print("hinted and unhinted point counts differ")
        return 1
    delta = max((abs(a[0] - b[0]) + abs(a[1] - b[1]) for a, b in zip(hp, up)), default=0)
    advance = abs(hinted["advance"] - plain["advance"])
    print(f"hintref control: max point delta {delta}/64 px, advance delta {advance}/64 px")
    if delta < 32:
        print("bytecode hinting did not move the points: the reference leg is not live")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
