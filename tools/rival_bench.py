"""Rival half of the 7.11-B A/B harness: shapes and rasterizes the same
workload tools/rival_bench.v times on the vtext side, and prints one
machine-parseable line per operation.

Only the CI reference stack is imported (uharfbuzz, Pillow, fontTools-free
by design): anything else would make the harness unrunnable where the
difftest itself runs. A missing import fails aloud with its reason instead
of printing a table with holes, the platform-ratchet rule.

The workload is identical to the V half by construction: the same repeat
rule builds the same 1024-character paragraphs from the same two sentences,
and the same Amiri 'A' at 32 px is the raster probe. Best of five batches
of twenty, because a loaded box lies about absolutes and the ratio is the
finding -- the same discipline tools/bench.v states.

Usage: python3 tools/rival_bench.py
Output lines look like:
  rival shape latin-1024: 1234.5 ns/op (n=20)
"""

import sys
import time

try:
    import uharfbuzz as hb
except ImportError as err:
    print(f'rival SKIPPED: no uharfbuzz ({err})')
    sys.exit(2)

try:
    from PIL import ImageFont
except ImportError as err:
    print(f'rival SKIPPED: no Pillow ({err})')
    sys.exit(2)

LATIN_TEXT = 'The quick brown fox jumps over the lazy dog near the river bank at dusk'
ARABIC_TEXT = '\u0633\u0644\u0627\u0645 \u062f\u0646\u06cc\u0627 \u0628\u0631 \u0634\u0645\u0627 \u0627\u06cc \u062f\u0648\u0633\u062a \u0642\u062f\u06cc\u0645\u06cc \u0645\u0646'
AMIRI = 'testdata/fonts/Amiri-Regular.ttf'
FIRACODE = 'testdata/fonts/FiraCode-Variable.ttf'


def repeat_to(text, n):
    out = []
    base = list(text)
    while len(out) < n:
        if out:
            out.append(' ')
        for c in base:
            if len(out) >= n:
                break
            out.append(c)
    return ''.join(out)


def best_of(fn, batches=5, per=20):
    best = None
    for _ in range(batches):
        start = time.perf_counter_ns()
        for _ in range(per):
            fn()
        took = time.perf_counter_ns() - start
        if best is None or took < best:
            best = took
    return best / per


def shape_case(font_path, text):
    blob = hb.Blob.from_file_path(font_path)
    face = hb.Face(blob)
    font = hb.Font(face)
    font.scale = (1000, 1000)

    def once():
        buf = hb.Buffer()
        buf.add_str(text)
        buf.guess_segment_properties()
        hb.shape(font, buf, {})

    return once


def main():
    latin = repeat_to(LATIN_TEXT, 1024)
    arabic = repeat_to(ARABIC_TEXT, 1024)
    assert len(latin) == 1024 and len(arabic) == 1024

    latin_op = shape_case(FIRACODE, latin)
    arabic_op = shape_case(AMIRI, arabic)
    print(f'rival shape latin-1024: {best_of(latin_op):.1f} ns/op (n=20)')
    print(f'rival shape arabic-1024: {best_of(arabic_op):.1f} ns/op (n=20)')

    face = ImageFont.truetype(AMIRI, 32)

    def raster_once():
        face.getmask('A')

    print(f'rival raster amiri-A-32: {best_of(raster_once):.1f} ns/op (n=20)')
    print('rival versions: '
          f'uharfbuzz={hb.__version__} '
          f'pillow={__import__("PIL").__version__}')


if __name__ == '__main__':
    main()
