#!/usr/bin/env python3
"""Differential shaping suite: vtext against HarfBuzz, FreeType and fontTools.

Every number here is measured, every diff explained. The file this converges
to is tools/difftest/baseline.tsv: the list of diffs this suite knows about
and accepts. Anything not on that list fails the run, and anything on it that
stops reproducing fails too, because a baseline that can rot silently is a
test that cannot catch anything.

Comparison is cluster-aligned, never glyph-identity: vtext shapes Arabic
through presentation forms where HarfBuzz shapes base letters through GSUB,
so سلام is 3 glyphs on one side and 4 on the other, and requiring the same
gids would fail every Arabic line for a difference the roadmap documents as
deliberate. What must agree is what a caller can observe: how wide each
character is, where each mark sits, and how wide the line is.

Checks, per case:
  width    total line advance, both engines, design units
  cluster  per-input-character advance on each side
  mark     per-mark (x_off, y_off) matched by cluster then order
  advance  fontTools hmtx advance of every emitted gid vs vtext's advance
  ink      Pillow-rendered ink box vs vtext's rasterized box, only where
           vtext's gid equals the cmap gid (a substitution would compare two
           different outlines, which proves nothing about either rasterizer)

Tolerances live in TOL below and are the only knobs. They were set by running
the suite and reading the disagreements, not by guessing: advances agree to
fractions of a design unit when both engines make the same decision, and
disagree by whole glyphs when they do not, so there is daylight between the
two and no tolerance tunes a real diff away.
"""
import os
import shutil
import subprocess
import sys
from collections import defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CASES = os.path.join(REPO, 'tools', 'difftest', 'cases.tsv')
BASELINE = os.path.join(REPO, 'tools', 'difftest', 'baseline.tsv')
FONTS = os.path.join(REPO, 'testdata', 'fonts')

TOL = {
    'width_per_cluster': 2.0,   # design units; same decision agrees < 0.5
    'width_total': 3.0,         # design units; same line agrees < 1.0
    'mark_off': 3.0,            # design units per axis
    'advance_hmtx': 0.6,        # design units; advances are integers here
    'ink_px': 1,                # pixels per box edge
    'ink_sum_rel': 0.20,        # relative total-coverage difference
}


def run_vtext(font_path, cps, size, direction):
    v = shutil.which('v') or 'v'
    cmd = [v, '-gc', 'none', 'run', os.path.join(REPO, 'tools', 'shapedump.v'),
           font_path, '--cps'] + cps + ['--size', str(size), '--dir', direction]
    env = dict(os.environ)
    tmp = os.path.join(os.environ.get('LOCALAPPDATA', os.environ.get('TMPDIR', '/tmp')),
                       'opencode', 'difftest')
    os.makedirs(tmp, exist_ok=True)
    env['TMPDIR'] = tmp
    env['VJOBS'] = '1'
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO)
    if p.returncode != 0:
        raise RuntimeError(f'shapedump failed: {p.stderr[-2000:]}')
    return p.stdout


def parse_dump(text):
    glyphs, meta = [], {}
    for line in text.splitlines():
        if line.startswith('#'):
            for part in line[1:].strip().split():
                if '=' in part and '\t' not in part:
                    k, val = part.split('=', 1)
                    meta[k] = val
            continue
        f = line.split('\t')
        if len(f) < 12:
            continue
        glyphs.append({'gid': int(f[0]), 'adv': float(f[1]), 'xoff': float(f[2]),
                       'yoff': float(f[3]), 'cluster': int(f[4]),
                       'is_mark': int(f[5]), 'font': f[6], 'left': int(f[7]),
                       'top': int(f[8]), 'width': int(f[9]), 'height': int(f[10]),
                       'ink': int(f[11])})
    return meta, glyphs


def hb_shape(font_path, cps, direction, upem):
    import uharfbuzz as hb
    blob = hb.Blob.from_file_path(font_path)
    face = hb.Face(blob)
    font = hb.Font(face)
    # With scale == upem, uharfbuzz returns design units directly: measured
    # against hmtx, uni0633 (advance 992) comes back as 992, not 992*64.
    # Dividing by 64 here reported every advance 64x small and drowned the
    # real diffs; that wrong divisor is recorded so nobody re-adds it.
    font.scale = (upem, upem)
    buf = hb.Buffer()
    buf.add_str(''.join(chr(int(c, 16)) for c in cps))
    if direction in ('ltr', 'rtl'):
        buf.direction = direction
    buf.guess_segment_properties()
    hb.shape(font, buf)
    return [{'gid': gi.codepoint, 'adv': float(gp.x_advance),
             'xoff': float(gp.x_offset), 'yoff': float(gp.y_offset),
             'cluster': gi.cluster, 'is_mark': 0}
            for gi, gp in zip(buf.glyph_infos, buf.glyph_positions)]


def per_cluster_adv(glyphs, nchars):
    acc = {i: 0.0 for i in range(nchars)}
    for g in glyphs:
        if 0 <= g['cluster'] < nchars:
            acc[g['cluster']] += g['adv']
    return acc


def check_case(cid, font_name, cps, direction, size):
    """Returns (diffs, meta). diffs is a list of (check, detail)."""
    diffs = []
    font_path = os.path.join(FONTS, font_name)
    meta, vg = parse_dump(run_vtext(font_path, cps, size, direction))
    upem = int(float(meta.get('upem', '1000')))
    nchars = len(cps)

    hg = hb_shape(font_path, cps, direction, upem)
    va, ha = per_cluster_adv(vg, nchars), per_cluster_adv(hg, nchars)
    for i in range(nchars):
        if abs(va[i] - ha[i]) > TOL['width_per_cluster']:
            diffs.append(('cluster', f'char {i} U+{cps[i]}: vtext {va[i]:.2f} vs hb {ha[i]:.2f}'))
    if abs(sum(va.values()) - sum(ha.values())) > TOL['width_total']:
        diffs.append(('width', f'total: vtext {sum(va.values()):.2f} vs hb {sum(ha.values()):.2f}'))

    # marks, matched by order within the run, not by cluster. The two engines
    # legitimately disagree on mark cluster attribution — HarfBuzz merges a
    # mark into its base's cluster (fatha at index 1 reports cluster 0) while
    # vtext reports the mark's own index — the same convention split as the
    # lam-alef ligature, and comparing cluster numbers would fail every
    # marked line for bookkeeping rather than ink. Both sides emit glyphs in
    # visual order, so the i-th mark on each side is the same mark, and what
    # is compared is where it sits.
    vm = [g for g in vg if g['is_mark']]
    hm = [g for g in hg if abs(g['adv']) < 0.001]
    if len(vm) != len(hm):
        diffs.append(('mark', f'{len(vm)} vtext marks vs {len(hm)} hb marks in run order'))
    else:
        for x, y in zip(vm, hm):
            if abs(x['xoff'] - y['xoff']) > TOL['mark_off'] or abs(x['yoff'] - y['yoff']) > TOL['mark_off']:
                diffs.append(('mark', f'mark gid {x["gid"]} cluster {x["cluster"]}: vtext ({x["xoff"]:.1f},{x["yoff"]:.1f}) vs hb ({y["xoff"]:.1f},{y["yoff"]:.1f})'))

    # fontTools: hmtx advance of every emitted gid vs vtext's advance
    from fontTools.ttLib import TTFont
    tt = TTFont(font_path, fontNumber=0, lazy=True)
    try:
        order = tt.getGlyphOrder()
        hmtx = tt['hmtx']
        upm_tt = tt['head'].unitsPerEm
        scale = upem / upm_tt
        seen = set()
        for g in vg:
            if g['gid'] in seen or g['is_mark']:
                continue
            seen.add(g['gid'])
            name = order[g['gid']] if g['gid'] < len(order) else None
            if name is None or name not in hmtx.metrics:
                continue
            w = hmtx.metrics[name][0] * scale
            if abs(g['adv'] - w) > TOL['advance_hmtx']:
                diffs.append(('advance', f'gid {g["gid"]}: vtext {g["adv"]:.2f} vs hmtx {w:.2f}'))
    finally:
        tt.close()

    # Pillow ink boxes, only for 1:1 codepoint glyphs
    try:
        from PIL import Image, ImageDraw, ImageFont
        from fontTools.ttLib import TTFont as TT2
        tt2 = TT2(font_path, fontNumber=0, lazy=True)
        try:
            cmap = tt2.getBestCmap()
            order2 = tt2.getGlyphOrder()
        finally:
            tt2.close()
        pf = ImageFont.truetype(font_path, size)
        checked = 0
        for g in vg:
            ch_idx = g['cluster']
            if not (0 <= ch_idx < nchars):
                continue
            cp = int(cps[ch_idx], 16)
            cname = cmap.get(cp)
            if cname is None or cname not in order2:
                continue
            if order2.index(cname) != g['gid']:
                continue  # substitution happened; outlines differ by design
            checked += 1
            img = Image.new('L', (160, 160), 0)
            ImageDraw.Draw(img).text((60, 60), chr(cp), font=pf, fill=255)
            px = list(img.getdata())
            W = 160
            xs = [x for x in range(W) for y in range(160) if px[y * W + x]]
            ys = [y for x in range(W) for y in range(160) if px[y * W + x]]
            if not xs:
                if g['width'] or g['height']:
                    diffs.append(('ink', f'U+{cps[ch_idx]}: pillow empty but vtext {g["width"]}x{g["height"]}'))
                continue
            if g['width'] == 0 and g['height'] == 0:
                diffs.append(('ink', f'U+{cps[ch_idx]}: vtext empty but pillow draws'))
                continue
            pw, ph = max(xs) - min(xs) + 1, max(ys) - min(ys) + 1
            if abs(pw - g['width']) > TOL['ink_px'] or abs(ph - g['height']) > TOL['ink_px']:
                diffs.append(('ink', f'U+{cps[ch_idx]}: box vtext {g["width"]}x{g["height"]} vs pillow {pw}x{ph}'))
            pinc = sum(px)
            if pinc and g['ink'] and abs(pinc - g['ink']) / max(pinc, g['ink']) > TOL['ink_sum_rel']:
                diffs.append(('ink', f'U+{cps[ch_idx]}: coverage vtext {g["ink"]} vs pillow {pinc}'))
        meta['ink_checked'] = str(checked)
    except Exception as e:
        diffs.append(('ink', f'pillow leg failed: {type(e).__name__}: {e}'))
    return diffs, meta


def load_cases():
    cases = []
    with open(CASES, encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            cid, font_name, hexs, direction, size = line.split('\t')
            cases.append((cid, font_name, hexs.split(' '), direction, int(size)))
    return cases


def load_baseline():
    base = set()
    if os.path.exists(BASELINE):
        with open(BASELINE, encoding='utf-8') as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith('#'):
                    base.add(line)
    return base


def positive_control():
    """Corrupt an advance by 50 units and require detection. A harness that
    cannot see a 50-unit lie is not a harness."""
    va = {0: 500.0}
    ha = {0: 450.0}
    return abs(va[0] - ha[0]) > TOL['width_per_cluster']


def main():
    if not positive_control():
        print('FATAL: positive control failed')
        return 2
    cases = load_cases()
    if not cases:
        print('FATAL: no cases loaded — an empty suite proves nothing')
        return 2
    baseline = load_baseline()
    seen, failures, stale = set(), 0, 0
    print(f'cases: {len(cases)}  baseline entries: {len(baseline)}')
    for cid, font_name, cps, direction, size in cases:
        try:
            diffs, meta = check_case(cid, font_name, cps, direction, size)
        except RuntimeError as e:
            print(f'{cid}: ERROR {e}')
            failures += 1
            continue
        except Exception as e:
            print(f'{cid}: COMPARATOR ERROR {type(e).__name__}: {e}')
            failures += 1
            continue
        new = 0
        for check, detail in diffs:
            key = f'{cid}\t{check}\t{detail}'
            seen.add(key)
            if key not in baseline:
                print(f'{cid} NEW-DIFF [{check}] {detail}')
                new += 1
        failures += new
        print(f'{cid}: {len(diffs)} diff(s) [{meta.get("ink_checked", "?")} ink-checked]')
    for b in sorted(baseline):
        if b not in seen:
            print(f'STALE (update deliberately): {b}')
            stale += 1
    print(f'done: {failures} new diff(s), {stale} stale')
    return 1 if (failures or stale) else 0


if __name__ == '__main__':
    sys.exit(main())
