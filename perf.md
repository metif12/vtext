# Performance record

Throughput measured better — or the claim is not made (GOAL.md). This file
is the canonical A/B record: the same workload timed on vtext and on the
stack it replaces, on the same box, in one table.

## Method

`tools/rival_bench.v` with `tools/rival_bench.py` is the harness. The V half
times line layout at 16 px for 1024-character Latin and Arabic paragraphs
plus Amiri 'A' rasterized at 32 px cold (sustained miss over A–T) and through
the caller-owned cache; the Python half times uharfbuzz shaping and Pillow
rasterization of the same inputs, built by the same repeat rule. Best of five
batches of twenty on both sides, because a loaded box lies about absolutes
and the ratio is the finding.

What each side does differs and the table says so: vtext lays the line out
(bidi, joining, substitution, positioning and measurement) where HarfBuzz
only shapes, and Pillow renders with its own bundled FreeType at default
flags where vtext fills unhinted. Throughput is the comparison; correctness
is proven elsewhere, per part.

The optimizing C compiler matters: a tcc build measures the compiler's
checks, not the engine. The primary table is `-prod`; the `-cc gcc` table
stays as the pre-clean baseline.

## Current numbers

<!-- perf-baseline:prod:start -->
| op | what | vtext | rival | vtext/rival |
| --- | --- | --- | --- | --- |
| shape latin-1024 | layout+shape vs hb shape | 10.5 ms/paragraph | 26.2 us/paragraph | 399x |
| shape arabic-1024 | layout+shape vs hb shape | 14.3 ms/paragraph | 250.1 us/paragraph | 57x |
| raster amiri-A-T-32 miss | sustained miss vs Pillow | 6.4 us/op | 23.6 us/op | 0.27x |
| raster amiri-A-32 hit | caller cache vs Pillow | 80 ns/op | 23.6 us/op | 0.00x |
<!-- perf-baseline:prod:end -->

Measured 2026-11-17 on Win11 x64 (16 CPU) with `v -prod -cc gcc`,
uharfbuzz 0.56.2, Pillow 12.3.0. The raster side is ahead; the shape side
is the finding, not a failure to hide, and the harness is what an
optimization lands against. The miss number supersedes the old 19.1 us
first-touch figure with a sustained method; the hit still answers from
the caller's cache.

Pre-clean baseline, measured 2026-11-16 on the same box with `v -cc gcc`
(no optimization), same rivals:

| op | what | vtext | rival | vtext/rival |
| --- | --- | --- | --- | --- |
| shape latin-1024 | layout+shape vs hb shape | 44.8 ms/paragraph | 26.8 us/paragraph | 1672x |
| shape arabic-1024 | layout+shape vs hb shape | 141.4 ms/paragraph | 256.4 us/paragraph | 552x |
| raster amiri-A-T-32 miss | sustained miss vs Pillow | 17.0 us/op | 24.8 us/op | 0.69x |
| raster amiri-A-32 hit | caller cache vs Pillow | 625 ns/op | 24.8 us/op | 0.03x |

## CI gate

The `perf` CI job runs the harness with `-prod` on every push and pull
request (ubuntu-24.04, pinned rivals: uharfbuzz 0.56.2, Pillow 12.3.0 —
the same pinned-runner rationale as the difftest job) and gates on the
ratios, not the absolutes: a loaded or slower box moves both engines
together.

`tools/perf_check.py` parses the bench's A/B table out of its stdout and
the baseline out of the markers above. A row fails when its ratio exceeds
3x the recorded one; a missing row fails too, because a silent hole is a
failure. Getting faster never fails. 3x is generous on purpose — shared
runners are noisy and hardware shifts ratios — and still catches what the
gate is for: an algorithmic blowup, an accidental unoptimized build, or a
broken caller cache (the harness itself already refuses when a hit does
not beat a miss).

## History

Numbers are recorded by hand per release; CI gates regressions but never
writes this file, so no run can commit-loop. Append new rows here, newest
last, when the method or the engine changes the ratios.

- 2026-11-16, Win11 x64, `v -cc gcc`: 1672x / 552x / 0.69x / 0.03x.
  First published table; tree not yet -prod-clean.
- 2026-11-17, Win11 x64, `v -prod -cc gcc`: 399x / 57x / 0.27x / 0.00x.
  Tree -prod-clean (UCD IN is a real `LineBreakClass` member; one subset
  loop dropped an unused value).
