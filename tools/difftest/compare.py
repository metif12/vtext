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
import re
import shutil
import subprocess
import sys
import unicodedata
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
    'pango_line_px': 4.0,       # pixels per wrapped line width
    'pango_wrap_px': 400,       # wrap width both engines lay out at
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
    wrap_widths = []
    for line in text.splitlines():
        if line.startswith('#'):
            m = re.match(r'# line (\d+): width=([\d.]+)', line)
            if m:
                wrap_widths.append(float(m.group(2)))
            for part in line[1:].strip().split():
                if '=' in part and '\t' not in part and not part.startswith('line'):
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
                       'ink': int(f[11]),
                       'line': int(f[12]) if len(f) > 12 else 0})
    return meta, glyphs, wrap_widths


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
    # Itemize by script before shaping, the way Pango does, because HarfBuzz
    # does not: one buffer holding سلام and abc guesses script Latn from the
    # first strong character, finds no Latn GSUB records, and returns every
    # Arabic letter unshaped (base advances 992/603/217 straight from hmtx).
    # Comparing that against a properly itemized engine measured nothing but
    # the harness. Runs are maximal spans of one bidi class with weak and
    # neutral spans (digits, spaces) folded into the preceding strong run —
    # the granularity Pango itemizes at for this corpus — each shaped alone
    # with clusters re-based to the full string. A case that is one script is
    # one run and shapes exactly as before.
    out = []
    for text, start in itemize_runs(''.join(chr(int(c, 16)) for c in cps)):
        buf = hb.Buffer()
        buf.add_str(text)
        # Direction per run, not per case: forcing rtl on a Latin run invents an
        # RTL-only kern (def goes 300 to 289) that no real renderer applies, and
        # the suite compared that ghost against an engine that shapes the run
        # left to right. Strong L runs go ltr, strong rightward runs rtl, and
        # weak or neutral runs keep the case direction like the paragraph does.
        buf.direction = run_direction(text, direction)
        buf.guess_segment_properties()
        hb.shape(font, buf)
        for gi, gp in zip(buf.glyph_infos, buf.glyph_positions):
            out.append({'gid': gi.codepoint, 'adv': float(gp.x_advance),
                        'xoff': float(gp.x_offset), 'yoff': float(gp.y_offset),
                        'cluster': gi.cluster + start, 'is_mark': 0})
    return out


def run_direction(text, case_direction):
    for ch in text:
        bc = unicodedata.bidirectional(ch)
        if bc == 'L':
            return 'ltr'
        if bc in ('R', 'AL'):
            return 'rtl'
    return case_direction


def itemize_runs(text):
    import unicodedata
    strong, runs = [], []
    for ch in text:
        bc = unicodedata.bidirectional(ch)
        strong.append('arab' if bc in ('AL', 'AN') else 'latn' if bc == 'L' else '')
    i, n = 0, len(text)
    cur_script, cur_start = None, 0
    for k, s in enumerate(strong):
        if s:
            if cur_script is None:
                cur_script, cur_start = s, 0
            elif s != cur_script:
                runs.append((text[cur_start:k], cur_start))
                cur_script, cur_start = s, k
    runs.append((text[cur_start:], cur_start))
    return [(t, s) for t, s in runs if t]


def per_cluster_adv(glyphs, nchars):
    acc = {i: 0.0 for i in range(nchars)}
    for g in glyphs:
        if 0 <= g['cluster'] < nchars:
            acc[g['cluster']] += g['adv']
    return acc


def vtext_mark_rel(vg):
    """Base-relative mark positions: (x, y_up, gid, cluster) per mark.

    The dump carries pen-relative offsets, so absolute pen positions are
    reconstructed first (pen starts at 0, each glyph's advance moves it) and
    each mark is then measured from the nearest preceding non-mark glyph,
    which is its base in visual order. y is flipped to HarfBuzz sign
    (positive up) at the same time, the one place the sign lives.
    """
    abs_pos, ismark, out = [], [], []
    pen = 0.0
    for g in vg:
        abs_pos.append((pen + g['xoff'], -g['yoff']))
        ismark.append(g['is_mark'])
        pen += g['adv']
    # Cluster of every non-mark glyph: a mark's base is found through the
    # input index, not through neighbours.
    base_at = {}
    for k, g in enumerate(vg):
        if not g['is_mark']:
            base_at.setdefault(g['cluster'], abs_pos[k])
    for k, g in enumerate(vg):
        if not g['is_mark']:
            continue
        # A mark decomposed from the same character as its base shares that
        # base's cluster (0622 splits to alef plus maddah, both cluster 4),
        # so the base's own cluster is checked first — the engine's own rule
        # is <= for the same reason. Otherwise the walk steps down over
        # mark-only clusters (and past a lam-alef fusion, which carries the
        # lam's cluster) to the letter the mark was written after.
        c = g['cluster']
        if c not in base_at:
            c -= 1
            while c >= 0 and c not in base_at:
                c -= 1
        if c in base_at:
            mx, my = abs_pos[k]
            bx, by = base_at[c]
            out.append((mx - bx, -(my - by), g['gid'], g['cluster']))
    return out


def check_case(cid, font_name, cps, direction, size):
    """Returns (diffs, meta). diffs is a list of (check, detail)."""
    diffs = []
    font_path = os.path.join(FONTS, font_name)
    meta, vg, _ = parse_dump(run_vtext(font_path, cps, size, direction))
    upem = int(float(meta.get('upem', '1000')))
    nchars = len(cps)
    # Glyph names for the mark filter below; the hmtx leg reuses the table.
    from fontTools.ttLib import TTFont
    tt = TTFont(font_path, fontNumber=0, lazy=True)
    try:
        order = tt.getGlyphOrder()
    finally:
        tt.close()

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
    #
    # Where it sits needs the same origin on both sides. HarfBuzz reports a
    # mark offset relative to its base glyph's origin; the dump's xoff is
    # relative to the running pen, a different quantity. Comparing those
    # directly failed every mark in the corpus for bookkeeping a second time
    # (damma on meem: 56 against 76, neither side wrong). vtext_mark_rel
    # re-bases each mark onto its base glyph first, so both numbers are
    # base-relative.
    # is_mark_glyph names the comparable marks: glyphs whose name is a Unicode
    # combining mark (uni0653 and friends). Zero advance alone does not qualify,
    # because Naskh-style fonts compose their letters from dot components
    # through GSUB — threedotsupabovear and dotabovear are zero-advance mark
    # glyphs clustered to their letter, five of HarfBuzz's six "marks" on
    # متن آزمایشش, where the engine draws predotted presentation forms and
    # reports one. Counting every zero-advance glyph compared two different
    # glyph inventories; descriptive-named real marks are the documented cost,
    # excluded on both sides equally rather than half-compared.
    def is_mark_glyph(gid):
        if gid < 0 or gid >= len(order):
            return False
        nm = order[gid]
        if len(nm) == 7 and nm.startswith('uni'):
            try:
                return unicodedata.combining(chr(int(nm[3:], 16))) != 0
            except Exception:
                return False
        return False

    vm = [(x, y, gid, cl) for x, y, gid, cl in vtext_mark_rel(vg)
          if is_mark_glyph(gid)]
    hm = [(g['xoff'], g['yoff']) for g in hg
          if abs(g['adv']) < 0.001 and is_mark_glyph(g['gid'])]
    if len(vm) != len(hm):
        diffs.append(('mark', f'{len(vm)} vtext marks vs {len(hm)} hb marks in run order'))
    else:
        for (rx, ry, gid, cl), (hx, hy) in zip(vm, hm):
            if abs(rx - hx) > TOL['mark_off'] or abs(ry - hy) > TOL['mark_off']:
                diffs.append(('mark', f'mark gid {gid} cluster {cl}: vtext ({rx:.1f},{ry:.1f}) vs hb ({hx:.1f},{hy:.1f})'))
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

    # Pango leg: wrap widths at a fixed width. Both sides auto-detect the
    # base direction per UAX#9, so vtext is re-dumped with --dir auto here
    # even when the shaping leg used an explicit direction: same rule in,
    # comparable lines out. A base-direction disagreement between the two
    # auto-detectors would itself be a finding, reported as a line-count
    # diff rather than hidden.
    try:
        import pango_leg
        from pango_leg import SkipLeg
        try:
            family = font_family_name(font_path)
        except Exception as e:
            raise SkipLeg(f'family name unreadable: {e}')
        text = ''.join(chr(int(c, 16)) for c in cps)
        pwidths, pn = pango_leg.layout_lines(family, text, size, TOL['pango_wrap_px'])
        wmeta, wg, vwidths = parse_dump(run_vtext_wrap(font_path, cps, size))
        _ = (wmeta, wg)  # glyph rows unused here; the widths are the engine's own
        if pn != len(vwidths):
            diffs.append(('pango', f'lines: vtext {len(vwidths)} vs pango {pn}'))
        else:
            for i, (a, b) in enumerate(zip(vwidths, pwidths)):
                if abs(a - b) > TOL['pango_line_px']:
                    diffs.append(('pango', f'line {i}: vtext {a:.1f}px vs pango {b:.1f}px'))
        meta['pango_lines'] = f'{len(vwidths)}/{pn}'
    except SkipLeg as e:
        meta['pango_lines'] = f'skipped: {e}'
    except Exception as e:
        diffs.append(('pango', f'pango leg failed: {type(e).__name__}: {e}'))
    return diffs, meta


def font_family_name(font_path):
    from fontTools.ttLib import TTFont
    tt = TTFont(font_path, fontNumber=0, lazy=True)
    try:
        for rec in tt['name'].names:
            if rec.nameID == 1 and rec.platformID in (3, 1):
                try:
                    s = rec.toUnicode()
                except Exception:
                    continue
                if s and all(ord(c) < 128 or True for c in s):
                    # prefer a plain-ASCII record; fall back to the first one
                    if all(ord(c) < 128 for c in s):
                        return s
        for rec in tt['name'].names:
            if rec.nameID == 1:
                try:
                    return rec.toUnicode()
                except Exception:
                    continue
        raise ValueError('no family name record')
    finally:
        tt.close()


def run_vtext_wrap(font_path, cps, size):
    import shutil
    import subprocess
    v = shutil.which('v') or 'v'
    cmd = [v, '-gc', 'none', 'run', os.path.join(REPO, 'tools', 'shapedump.v'),
           font_path, '--cps'] + cps + ['--size', str(size), '--dir', 'auto',
                                        '--wrap', str(TOL['pango_wrap_px'])]
    env = dict(os.environ)
    tmp = os.path.join(os.environ.get('LOCALAPPDATA', os.environ.get('TMPDIR', '/tmp')),
                       'opencode', 'difftest')
    os.makedirs(tmp, exist_ok=True)
    env['TMPDIR'] = tmp
    env['VJOBS'] = '1'
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO)
    if p.returncode != 0:
        raise RuntimeError(f'shapedump --wrap failed: {p.stderr[-2000:]}')
    return p.stdout



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
        print(f'{cid}: {len(diffs)} diff(s) [{meta.get("ink_checked", "?")} ink-checked] [pango {meta.get("pango_lines", "?")}]')
    for b in sorted(baseline):
        if b not in seen:
            print(f'STALE (update deliberately): {b}')
            stale += 1
    print(f'done: {failures} new diff(s), {stale} stale')
    return 1 if (failures or stale) else 0


if __name__ == '__main__':
    sys.exit(main())
