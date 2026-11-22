#!/usr/bin/env python3
"""Dump FreeType's hinted 26.6 point coordinates for one glyph.

This is the reference leg for the TrueType bytecode-interpreter gate. The
difftest job pins freetype-py so the numbers below have a version to blame:
the native interpreter (FT_LOAD_TARGET_NORMAL) is the target, with
FT_LOAD_NO_HINTING as the control that isolates what the bytecode changed.
TT_INTERPRETER_VERSION_35 is requested explicitly because version 40 changes
results on the same programs.

Output, one JSON object per line:

    {"gid": 12, "ppem": 16, "mode": "hinted"|"unhinted", "advance": int,
     "points": [[x, y, on_curve], ...], "contours": [end, ...],
     "phantom": [[x, y], ...]}

Coordinates are 26.6 fixed point, y positive up (FreeType's convention),
the same space the engine's autohinter would need to match. Usage:

    python3 tools/hintref.py FONT GID PPEM [hinted|unhinted]
"""
import json
import sys

import freetype


def main():
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    path, gid, ppem = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    mode = sys.argv[4] if len(sys.argv) > 4 else "hinted"
    face = freetype.Face(path)
    face.set_char_size(ppem * 64)
    flags = freetype.FT_LOAD_TARGET_NORMAL
    if mode == "unhinted":
        flags = freetype.FT_LOAD_NO_HINTING
    face.load_glyph(gid, flags)
    slot = face.glyph
    outline = slot.outline
    points = [[int(p[0]), int(p[1]), 0] for p in outline.points]
    # freetype-py 2.13 exposes points as (x, y) tuples and the on-curve bit
    # in a separate tags array; older releases put the flag in the point.
    if hasattr(outline, "tags"):
        for i, tag in enumerate(outline.tags):
            points[i][2] = 1 if int(tag) & 1 else 0
    doc = {
        "gid": gid,
        "ppem": ppem,
        "mode": mode,
        "advance": int(slot.advance.x),
        "points": points,
        "contours": [int(c) for c in outline.contours],
        "phantom": [
            [int(slot.metrics.horiBearingX), int(slot.metrics.horiBearingY)],
            [int(slot.metrics.horiAdvance), 0],
        ],
    }
    print(json.dumps(doc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
