#!/usr/bin/env python3
"""Regenerate the PERF.md A/B baseline table from one bench run.

CI-generated, manual dispatch only: .github/workflows/perf-record.yml runs
the bench with -prod, runs this script, gates with perf_check.py, and
commits PERF.md with [skip ci]. Nothing here runs on push, so no run can
commit-loop. Numbers are never hand-edited: an unknown bench op, a missing
op, or an unparseable row fails loud instead of writing a partial table.

Usage: python3 tools/perf_record.py PERF.md bench.txt
Exit 0 after rewriting PERF.md in place, 1 on any refusal.
"""

import datetime
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from perf_check import (
    BASELINE_END,
    BASELINE_START,
    norm,
    parse_baseline,
    read_text,
)

WHAT = {
    'shape latin-1024': 'layout+shape vs hb shape',
    'shape arabic-1024': 'layout+shape vs hb shape',
    'raster amiri-A-T-32 miss': 'sustained miss vs Pillow',
    'raster amiri-A-32 hit': 'caller cache vs Pillow',
    'layout latin-wrap-1024': 'wrap+measure vs Pango layout',
    'layout arabic-wrap-1024': 'wrap+measure vs Pango layout',
    'discovery fontconfig-match': 'provider match vs fc-match',
    'inspect fonttools-load': 'load+parse vs fontTools',
}

# Deterministic table order: the four original rows first, then shape per
# script in perf_cases() order, then wrap per script in the same order,
# then discovery and inspect. New counterparts extend this list and WHAT
# together, or the recorder refuses.
SCRIPT_IDS = [
    'hebrew', 'cjk', 'thai', 'lao', 'khmer', 'myanmar', 'syriac',
    'thaana', 'nko', 'georgian', 'armenian', 'ethiopic', 'devanagari',
    'bengali', 'nastaliq', 'marks', 'digits', 'bidi',
]

ORDER = (
    ['shape latin-1024', 'shape arabic-1024',
     'raster amiri-A-T-32 miss', 'raster amiri-A-32 hit']
    + [f'shape {s}-1024' for s in SCRIPT_IDS]
    + ['layout latin-wrap-1024', 'layout arabic-wrap-1024']
    + [f'layout {s}-wrap-1024' for s in SCRIPT_IDS]
    + ['discovery fontconfig-match', 'inspect fonttools-load']
)

# Every script row shapes (then lays out) on the V side against the same
# rival as the latin/arabic pair it extends: HarfBuzz for shape, Pango for
# wrap. Filling WHAT here keeps the table's `what` column descriptive and
# keeps ORDER and WHAT in one place — a new script extends SCRIPT_IDS and
# both follow, or the recorder refuses above.
for _s in SCRIPT_IDS:
    WHAT.setdefault(f'shape {_s}-1024', 'layout+shape vs hb shape')
    WHAT.setdefault(f'layout {_s}-wrap-1024', 'wrap+measure vs Pango layout')


def parse_bench_full(path):
    """Read {op: (vtext_cell, rival_cell, ratio_str)} out of the bench table."""
    text = read_text(path)
    out = {}
    for line in text.splitlines():
        if '|' not in line:
            continue
        cells = [c.strip() for c in line.split('|')]
        cells = [c for c in cells if c != '']
        # Bench table rows have four data cells (op, vtext, rival, ratio);
        # anything else (headers, separators, skip notes) is not a row.
        if len(cells) != 4:
            continue
        op = norm(cells[0])
        if op == 'op' or set(op) == {'-'}:
            continue
        m = re.search(r'([\d.]+)x\s*$', cells[-1])
        if not m:
            continue
        out[op] = (cells[1], cells[2], m.group(1))
    return out


def units_of(cell):
    m = re.search(r'([\d.]+)\s*ns/(\w+)$', cell.strip())
    if not m:
        return None
    return float(m.group(1)), m.group(2)


def fmt_cell(ns, unit):
    if ns >= 1_000_000:
        return f'{ns / 1e6:.1f} ms/{unit}'
    if ns >= 1000:
        return f'{ns / 1e3:.1f} us/{unit}'
    return f'{ns:.1f} ns/{unit}'


def versions_of(text):
    for line in text.splitlines():
        if 'rival versions:' in line:
            return line.split('rival versions:', 1)[1].strip()
    return 'versions unrecorded'


def main():
    if len(sys.argv) != 3:
        print('usage: python3 tools/perf_record.py PERF.md bench.txt')
        return 1
    perf_path, bench_path = sys.argv[1], sys.argv[2]
    base = parse_baseline(perf_path)
    if base is None:
        return 1
    bench_text = read_text(bench_path)
    bench = parse_bench_full(bench_path)
    if not bench:
        print('perf-record REFUSED: no table rows in the bench output')
        return 1
    unknown = sorted(set(bench) - set(ORDER) - set(base))
    if unknown:
        print(f'perf-record REFUSED: bench op(s) with no WHAT entry or baseline row: {unknown}')
        return 1
    missing = [op for op in ORDER if norm(op) not in bench]
    if missing:
        print(f'perf-record REFUSED: bench is missing baseline op(s): {missing}')
        return 1
    rows = []
    for op in ORDER:
        key = norm(op)
        vtext_cell, rival_cell, ratio = bench[key]
        vu = units_of(vtext_cell)
        ru = units_of(rival_cell)
        if vu is None or ru is None:
            print(f'perf-record REFUSED: unparseable bench cells for {op!r}: {vtext_cell!r} / {rival_cell!r}')
            return 1
        what = WHAT.get(op, op)
        rows.append(
            f'| {op} | {what} | {fmt_cell(*vu)} | {fmt_cell(*ru)} | {ratio}x |')
    header = ['| op | what | vtext | rival | vtext/rival |',
              '| --- | --- | --- | --- | --- |']
    segment = '\n'.join(header + rows)
    doc = read_text(perf_path)
    try:
        before, rest = doc.split(BASELINE_START, 1)
        _old, after = rest.split(BASELINE_END, 1)
    except ValueError:
        print('perf-record REFUSED: baseline markers missing')
        return 1
    doc = before + BASELINE_START + '\n' + segment + '\n' + BASELINE_END + after
    today = datetime.date.today().isoformat()
    ratios = ' / '.join(f'{bench[norm(op)][2]}x' for op in ORDER)
    doc = doc.rstrip('\n') + (
        f'\n- {today}, ubuntu-24.04 CI (`v -prod -cc gcc`): {ratios}.\n'
        f'  Generated by tools/perf_record.py from one bench run; {versions_of(bench_text)}.\n')
    with open(perf_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(doc)
    print(f'perf-record: rewrote {len(rows)} baseline rows; history appended')
    return 0


if __name__ == '__main__':
    sys.exit(main())
