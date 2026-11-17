"""Rival half of the 7.11-B A/B harness: shapes, lays out, looks up and loads
the same workload tools/rival_bench.v times on the vtext side, and prints one
machine-parseable line per operation.

Only the CI reference stack is imported (uharfbuzz, Pillow, fontTools, the
pango trio; fc-match comes from fontconfig): anything else would make the
harness unrunnable where the difftest itself runs. A missing import skips
only its own rows with its reason instead of failing the whole half —
exit 2 stays reserved for the core stack (uharfbuzz, Pillow) without which
no table is worth printing.

The workload is identical to the V half by construction: the same repeat
rule builds the same 1024-character paragraphs (latin, arabic, every script
plus marks/digits/bidi from the same pinned suite words), the same wrap at
400 px, and the same Amiri 'A' at 32 px raster probe. Best of five batches
of twenty, because a loaded box lies about absolutes and the ratio is the
finding -- the same discipline tools/bench.v states.

Usage: python3 tools/rival_bench.py
Output lines look like:
  rival shape latin-1024: 1234.5 ns/op (n=20)
"""

import os
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
FONTS_DIR = 'testdata/fonts'

# Per-script cases mirroring tools/rival_bench.v perf_cases(): (id, pango
# family, file, codepoints). Samples are short real words pinned by the
# suites, repeated to 1024 by the same repeat rule on both sides.
PERF_CASES = [
    ('hebrew', 'Noto Sans Hebrew', 'NotoSansHebrew-Variable.ttf',
     [0x05E9, 0x05B8, 0x05C1, 0x05DC, 0x05D5, 0x05B9, 0x05DD]),
    ('cjk', 'Noto Sans SC', 'NotoSansSC-Variable.ttf',
     [0x4E2D, 0x6587]),
    ('thai', 'Noto Sans Thai', 'NotoSansThai-Variable.ttf',
     [0x0E2A, 0x0E27, 0x0E31, 0x0E2A, 0x0E14, 0x0E35]),
    ('lao', 'Noto Sans Lao', 'NotoSansLao-Variable.ttf',
     [0x0EAA, 0x0EB0, 0x0E9A, 0x0EB2, 0x0E8D, 0x0E94, 0x0EB5]),
    ('khmer', 'Noto Sans Khmer', 'NotoSansKhmer-Variable.ttf',
     [0x179F, 0x17BD, 0x179F, 0x17D2, 0x178F, 0x17B8]),
    ('myanmar', 'Noto Sans Myanmar', 'NotoSansMyanmar-Variable.ttf',
     [0x1019, 0x1004, 0x103A, 0x1039, 0x1002, 0x101C, 0x102C]),
    ('syriac', 'Noto Sans Syriac', 'NotoSansSyriac-Variable.ttf',
     [0x072B, 0x0720, 0x0721, 0x0710]),
    ('thaana', 'Noto Sans Thaana', 'NotoSansThaana-Variable.ttf',
     [0x078B, 0x07A8, 0x0788, 0x07AC, 0x0780, 0x07A8]),
    ('nko', 'Noto Sans NKo', 'NotoSansNKo-Regular.ttf',
     [0x07D2, 0x07DE, 0x07CF]),
    ('georgian', 'Noto Sans Georgian', 'NotoSansGeorgian-Variable.ttf',
     [0x10D2, 0x10D0, 0x10DB, 0x10D0, 0x10E0, 0x10EF, 0x10DD, 0x10D1, 0x10D0]),
    ('armenian', 'Noto Sans Armenian', 'NotoSansArmenian-Variable.ttf',
     [0x0562, 0x0561, 0x0580, 0x0565, 0x0582]),
    ('ethiopic', 'Noto Sans Ethiopic', 'NotoSansEthiopic-Variable.ttf',
     [0x1230, 0x120B, 0x121D]),
    ('devanagari', 'Noto Sans Devanagari', 'NotoSansDevanagari-Variable.ttf',
     [0x0928, 0x092E, 0x0938, 0x094D, 0x0924, 0x0947]),
    ('bengali', 'Noto Sans Bengali', 'NotoSansBengali-Variable.ttf',
     [0x09A8, 0x09AE, 0x09B8, 0x09CD, 0x09A4, 0x09C7]),
    ('nastaliq', 'Noto Nastaliq Urdu', 'NotoNastaliqUrdu-Regular.ttf',
     [0x0633, 0x0644, 0x0627, 0x0645, 0x0020, 0x062F, 0x0646, 0x06CC, 0x0627]),
    ('marks', 'Amiri', 'Amiri-Regular.ttf',
     [0x0628, 0x0650, 0x0633, 0x0652, 0x0645, 0x0650, 0x0020, 0x0627, 0x0644,
      0x0644, 0x064E, 0x0647, 0x0020, 0x0627, 0x0644, 0x0631, 0x0651, 0x062D,
      0x0652, 0x0645, 0x0670, 0x0646, 0x0020, 0x0627, 0x0644, 0x0631, 0x0651,
      0x062D, 0x0650, 0x062C, 0x0645, 0x0650]),
    ('digits', 'Amiri', 'Amiri-Regular.ttf',
     [0x06F1, 0x06F2, 0x06F3, 0x0020, 0x0641, 0x0627, 0x0631, 0x0633, 0x06CC,
      0x0020, 0x0061, 0x0062, 0x0063, 0x0020, 0x06F4, 0x06F5, 0x06F6]),
    ('bidi', 'Amiri', 'Amiri-Regular.ttf',
     [0x0061, 0x0062, 0x0063, 0x0020, 0x0633, 0x0644, 0x0627, 0x0645, 0x0020,
      0x0031, 0x0032, 0x0033, 0x0020, 0x0064, 0x0065, 0x0066]),
]


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


def _ver(modname):
    try:
        mod = __import__(modname)
        return getattr(mod, '__version__', 'unknown')
    except Exception:
        return 'missing'


def rival_wrap(cases):
    """Pango layout wrap at the same 400 px the V half wraps at.

    Fresh layout objects per op, the way tools/difftest/pango_leg.py uses
    them — setup cost is Pango's real usage cost, not a cached fast path.
    `cases` is a list of (op_name, family, text) triples.
    """
    try:
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'difftest'))
        import pango_leg
    except Exception as e:
        print(f'rival SKIPPED layout wrap (pango leg unavailable: {e})')
        return
    for op_name, family, text in cases:
        try:
            op = lambda: pango_leg.layout_lines(family, text, 16, 400)  # noqa: E731
            print(f'rival layout {op_name}: {best_of(op):.1f} ns/op (n=20)')
        except Exception as e:
            print(f'rival SKIPPED layout {op_name} ({e})')


def rival_discovery(family):
    """fc-match, the incumbent path os.font shells out to."""
    import shutil
    import subprocess
    if shutil.which('fc-match') is None:
        print('rival SKIPPED discovery fc-match (no fc-match binary)')
        return

    def once():
        subprocess.run(['fc-match', '--format=%{file}\n', family],
                       check=True, capture_output=True)

    try:
        print(f'rival discovery fontconfig-match: {best_of(once):.1f} ns/op (n=20)')
    except Exception as e:
        print(f'rival SKIPPED discovery fc-match ({e})')


def rival_inspect():
    """fontTools load: the reading-side incumbent behind inspect/subset."""
    try:
        from fontTools.ttLib import TTFont
    except Exception as e:
        print(f'rival SKIPPED inspect fonttools ({e})')
        return

    def once():
        f = TTFont(AMIRI)
        _ = f['cmap']
        _ = f['maxp'].numGlyphs

    try:
        print(f'rival inspect fonttools-load: {best_of(once):.1f} ns/op (n=20)')
    except Exception as e:
        print(f'rival SKIPPED inspect fonttools ({e})')


def main():
    latin = repeat_to(LATIN_TEXT, 1024)
    arabic = repeat_to(ARABIC_TEXT, 1024)
    assert len(latin) == 1024 and len(arabic) == 1024

    latin_op = shape_case(FIRACODE, latin)
    arabic_op = shape_case(AMIRI, arabic)
    print(f'rival shape latin-1024: {best_of(latin_op):.1f} ns/op (n=20)')
    print(f'rival shape arabic-1024: {best_of(arabic_op):.1f} ns/op (n=20)')

    for cid, _family, fname, cps in PERF_CASES:
        text = repeat_to(''.join(chr(c) for c in cps), 1024)
        op = shape_case(os.path.join(FONTS_DIR, fname), text)
        print(f'rival shape {cid}-1024: {best_of(op):.1f} ns/op (n=20)')

    face = ImageFont.truetype(AMIRI, 32)

    def raster_once():
        face.getmask('A')

    print(f'rival raster amiri-A-32: {best_of(raster_once):.1f} ns/op (n=20)')

    wrap_cases = [('latin-wrap-1024', 'Amiri', latin), ('arabic-wrap-1024', 'Amiri', arabic)]
    for cid, family, _fname, cps in PERF_CASES:
        wrap_cases.append((f'{cid}-wrap-1024', family, repeat_to(''.join(chr(c) for c in cps), 1024)))
    rival_wrap(wrap_cases)
    rival_discovery('Amiri')
    rival_inspect()

    print('rival versions: '
          f'uharfbuzz={hb.__version__} '
          f'pillow={__import__("PIL").__version__} '
          f'pangocffi={_ver("pangocffi")} '
          f'fonttools={_ver("fontTools")}')


if __name__ == '__main__':
    main()
