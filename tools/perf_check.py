#!/usr/bin/env python3
"""CI gate for the A/B perf record: bench stdout ratios must stay within
TOLERANCE of the PERF.md -prod baseline.

Ratios, not absolutes: a loaded or slower box moves both engines together,
so absolutes cannot gate across machines. Only upward breaches fail;
getting faster never does. A row the bench stops printing fails too,
because a silent hole is a failure.

Usage: v -prod -cc gcc run tools/rival_bench.v > bench.txt
       python3 tools/perf_check.py PERF.md bench.txt
Exit 0 when every row is within tolerance, 1 otherwise.
"""

import re
import sys

TOLERANCE = 3.0
BASELINE_START = '<!-- perf-baseline:prod:start -->'
BASELINE_END = '<!-- perf-baseline:prod:end -->'


def norm(op):
    return re.sub(r'\s+', ' ', op.strip().lower())


def read_text(path):
    """Read bench or baseline output, whatever encoding the shell used:
    utf-8, utf-8-sig, or the utf-16 PowerShell redirections produce."""
    raw = open(path, 'rb').read()
    for enc in ('utf-8-sig', 'utf-16', 'utf-8'):
        try:
            return raw.decode(enc)
        except (UnicodeDecodeError, ValueError):
            continue
    return raw.decode('utf-8', errors='replace')


def parse_baseline(path):
    """Read {op: ratio} out of the marked table in PERF.md."""
    text = read_text(path)
    try:
        seg = text.split(BASELINE_START)[1].split(BASELINE_END)[0]
    except IndexError:
        print(f'perf-check REFUSED: baseline markers missing in {path}')
        return None
    out = {}
    for line in seg.splitlines():
        line = line.strip()
        if not line.startswith('|'):
            continue
        cells = [c.strip() for c in line.strip('|').split('|')]
        if len(cells) < 5 or cells[0] == 'op' or cells[0].startswith('---'):
            continue
        m = re.search(r'([\d.]+)x\s*$', cells[4])
        if not m:
            print(f'perf-check REFUSED: unparseable ratio in {line!r}')
            return None
        out[norm(cells[0])] = float(m.group(1))
    if not out:
        print(f'perf-check REFUSED: no baseline rows in {path}')
        return None
    return out


def parse_bench(path):
    """Read {op: ratio} out of the bench's printed A/B table."""
    if path == '-':
        text = sys.stdin.read()
    else:
        text = read_text(path)
    out = {}
    for line in text.splitlines():
        if '|' not in line:
            continue
        cells = [c.strip() for c in line.split('|')]
        if len(cells) < 4:
            continue
        m = re.search(r'([\d.]+)x\s*$', cells[-1])
        if not m:
            continue
        out[norm(cells[0])] = float(m.group(1))
    return out


def main():
    if len(sys.argv) != 3:
        print('usage: python3 tools/perf_check.py PERF.md bench.txt')
        return 1
    base = parse_baseline(sys.argv[1])
    if base is None:
        return 1
    bench = parse_bench(sys.argv[2])
    bad = 0
    for op, want in sorted(base.items()):
        if op not in bench:
            print(f'perf-check MISSING: {op!r} not in bench output')
            bad += 1
            continue
        got = bench[op]
        bound = want * TOLERANCE
        flag = '' if got <= bound else '  BREACH'
        if flag:
            bad += 1
        print(f'perf-check {op}: {got:.2f}x vs baseline {want:.2f}x '
              f'(bound {bound:.2f}x){flag}')
    if bad:
        print(f'perf-check: {bad} row(s) breached or missing')
        return 1
    print('perf-check: all rows within tolerance')
    return 0


if __name__ == '__main__':
    sys.exit(main())
