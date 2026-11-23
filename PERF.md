# Performance record

Throughput measured better — or the claim is not made (GOAL.md). This file
is the canonical A/B record: the same workload timed on HarfAra and on the
stack it replaces, on the same box, in one table.

## Method

`tools/rival_bench.v` with `tools/rival_bench.py` is the harness. The V half
times line layout and wrapping at 16 px for 1024-character paragraphs in
every script the corpus covers plus three char-type paragraphs
(marks-heavy, digits, mixed bidi), Amiri 'A' rasterized at 32 px cold
(sustained miss over A–T) and through the caller-owned cache, one
fontconfig family match, and one font load. The Python half times uharfbuzz
shaping, a Pango wrap at the same 400 px width, an fc-match lookup, and a
fontTools load of the same inputs, built by the same repeat rule. Best of
five batches of twenty on both sides, because a loaded box lies about
absolutes and the ratio is the finding.

What each side does differs and the table says so: HarfAra lays the line out
(bidi, joining, substitution, positioning and measurement) where HarfBuzz
only shapes; Pango lays out and wraps where HarfAra wraps; fc-match spawns a
process where the provider calls the library; fontTools parses into Python
objects where HarfAra parses into its own tables; Pillow renders with its own
bundled FreeType at default flags where HarfAra fills hinted. Throughput is
the comparison; correctness is proven elsewhere, per part.

The optimizing C compiler matters: a tcc build measures the compiler's
checks, not the engine. The primary table is `-prod`; the `-cc gcc` table
stays as the pre-clean baseline.

## Current numbers

<!-- perf-baseline:prod:start -->
| op | what | HarfAra | rival | HarfAra/rival |
| --- | --- | --- | --- | --- |
| shape latin-1024 | layout+shape vs hb shape | 536.4 us/paragraph | 19.0 us/paragraph | 28.18x |
| shape arabic-1024 | layout+shape vs hb shape | 915.7 us/paragraph | 175.9 us/paragraph | 5.21x |
| raster amiri-A-T-32 miss | sustained miss vs Pillow | 5.6 us/op | 80.3 us/op | 0.07x |
| raster amiri-A-32 hit | caller cache vs Pillow | 51.0 ns/op | 80.3 us/op | 0.00x |
| shape hebrew-1024 | layout+shape vs hb shape | 1.9 ms/paragraph | 68.8 us/paragraph | 27.71x |
| shape cjk-1024 | layout+shape vs hb shape | 557.5 us/paragraph | 15.0 us/paragraph | 37.17x |
| shape thai-1024 | layout+shape vs hb shape | 1.6 ms/paragraph | 72.2 us/paragraph | 21.60x |
| shape lao-1024 | layout+shape vs hb shape | 1.1 ms/paragraph | 37.7 us/paragraph | 29.46x |
| shape khmer-1024 | layout+shape vs hb shape | 4.3 ms/paragraph | 151.3 us/paragraph | 28.44x |
| shape myanmar-1024 | layout+shape vs hb shape | 22.2 ms/paragraph | 196.0 us/paragraph | 113.44x |
| shape syriac-1024 | layout+shape vs hb shape | 5.1 ms/paragraph | 121.1 us/paragraph | 42.31x |
| shape thaana-1024 | layout+shape vs hb shape | 2.0 ms/paragraph | 66.8 us/paragraph | 30.55x |
| shape nko-1024 | layout+shape vs hb shape | 2.4 ms/paragraph | 63.7 us/paragraph | 38.04x |
| shape georgian-1024 | layout+shape vs hb shape | 811.3 us/paragraph | 42.2 us/paragraph | 19.21x |
| shape armenian-1024 | layout+shape vs hb shape | 698.0 us/paragraph | 33.4 us/paragraph | 20.90x |
| shape ethiopic-1024 | layout+shape vs hb shape | 660.8 us/paragraph | 38.6 us/paragraph | 17.11x |
| shape devanagari-1024 | layout+shape vs hb shape | 4.0 ms/paragraph | 146.6 us/paragraph | 27.40x |
| shape bengali-1024 | layout+shape vs hb shape | 8.5 ms/paragraph | 435.2 us/paragraph | 19.57x |
| shape nastaliq-1024 | layout+shape vs hb shape | 41.9 ms/paragraph | 1.7 ms/paragraph | 24.95x |
| shape marks-1024 | layout+shape vs hb shape | 2.0 ms/paragraph | 261.1 us/paragraph | 7.74x |
| shape digits-1024 | layout+shape vs hb shape | 947.5 us/paragraph | 158.2 us/paragraph | 5.99x |
| shape bidi-1024 | layout+shape vs hb shape | 998.6 us/paragraph | 118.7 us/paragraph | 8.41x |
| layout latin-wrap-1024 | wrap+measure vs Pango layout | 972.7 us/paragraph | 1.2 ms/paragraph | 0.83x |
| layout arabic-wrap-1024 | wrap+measure vs Pango layout | 1.3 ms/paragraph | 2.0 ms/paragraph | 0.67x |
| layout hebrew-wrap-1024 | wrap+measure vs Pango layout | 2.3 ms/paragraph | 1.1 ms/paragraph | 2.11x |
| layout cjk-wrap-1024 | wrap+measure vs Pango layout | 1.2 ms/paragraph | 1.0 ms/paragraph | 1.19x |
| layout thai-wrap-1024 | wrap+measure vs Pango layout | 1.9 ms/paragraph | 1.1 ms/paragraph | 1.72x |
| layout lao-wrap-1024 | wrap+measure vs Pango layout | 1.4 ms/paragraph | 983.2 us/paragraph | 1.44x |
| layout khmer-wrap-1024 | wrap+measure vs Pango layout | 4.6 ms/paragraph | 1.5 ms/paragraph | 3.06x |
| layout myanmar-wrap-1024 | wrap+measure vs Pango layout | 22.4 ms/paragraph | 1.7 ms/paragraph | 13.40x |
| layout syriac-wrap-1024 | wrap+measure vs Pango layout | 5.6 ms/paragraph | 1.3 ms/paragraph | 4.17x |
| layout thaana-wrap-1024 | wrap+measure vs Pango layout | 2.4 ms/paragraph | 1.2 ms/paragraph | 2.04x |
| layout nko-wrap-1024 | wrap+measure vs Pango layout | 3.1 ms/paragraph | 1.1 ms/paragraph | 2.88x |
| layout georgian-wrap-1024 | wrap+measure vs Pango layout | 1.1 ms/paragraph | 1.1 ms/paragraph | 1.07x |
| layout armenian-wrap-1024 | wrap+measure vs Pango layout | 1.1 ms/paragraph | 985.5 us/paragraph | 1.12x |
| layout ethiopic-wrap-1024 | wrap+measure vs Pango layout | 1.2 ms/paragraph | 1.0 ms/paragraph | 1.15x |
| layout devanagari-wrap-1024 | wrap+measure vs Pango layout | 4.4 ms/paragraph | 1.6 ms/paragraph | 2.74x |
| layout bengali-wrap-1024 | wrap+measure vs Pango layout | 8.8 ms/paragraph | 1.8 ms/paragraph | 4.97x |
| layout nastaliq-wrap-1024 | wrap+measure vs Pango layout | 42.2 ms/paragraph | 5.9 ms/paragraph | 7.20x |
| layout marks-wrap-1024 | wrap+measure vs Pango layout | 2.4 ms/paragraph | 1.8 ms/paragraph | 1.30x |
| layout digits-wrap-1024 | wrap+measure vs Pango layout | 1.4 ms/paragraph | 1.8 ms/paragraph | 0.78x |
| layout bidi-wrap-1024 | wrap+measure vs Pango layout | 1.4 ms/paragraph | 1.8 ms/paragraph | 0.78x |
| discovery fontconfig-match | provider match vs fc-match | 2.6 ms/op | 3.6 ms/op | 0.71x |
| inspect fonttools-load | load+parse vs fontTools | 1.1 ms/op | 4.1 ms/op | 0.27x |
<!-- perf-baseline:prod:end -->

Measured 2026-11-23 on ubuntu-24.04 CI with `v -prod -cc gcc`, uharfbuzz
0.56.2, Pillow 12.3.0 and fontTools 4.66.1 (the pinned stack in
`.github/workflows/perf-record.yml`). Earlier Win11 x64 measurements are
kept in the history below. The raster side is ahead; the shape side is the
finding, not a failure to hide, and the harness is what an optimization
lands against. The miss number supersedes the old 19.1 us first-touch
figure with a sustained method; the hit still answers from the caller's
cache.

Pre-clean baseline, measured 2026-11-16 on the same box with `v -cc gcc`
(no optimization), same rivals:

| op | what | harfara | rival | harfara/rival |
| --- | --- | --- | --- | --- |
| shape latin-1024 | layout+shape vs hb shape | 44.8 ms/paragraph | 26.8 us/paragraph | 1672x |
| shape arabic-1024 | layout+shape vs hb shape | 141.4 ms/paragraph | 256.4 us/paragraph | 552x |
| raster amiri-A-T-32 miss | sustained miss vs Pillow | 17.0 us/op | 24.8 us/op | 0.69x |
| raster amiri-A-32 hit | caller cache vs Pillow | 625 ns/op | 24.8 us/op | 0.03x |

## CI gate

The `perf` CI job runs the harness with `-prod` on every push and pull
request (ubuntu-24.04, pinned rivals: uharfbuzz, Pillow, fontTools, the
pangocffi trio, fc-match — the same pinned-runner rationale as the difftest
job) and gates on the ratios, not the absolutes: a loaded or slower box
moves both engines together.

`tools/perf_check.py` parses the bench's A/B table out of its stdout and
the baseline out of the markers above. A row fails when its ratio exceeds
3x the recorded one; a missing row fails too, because a silent hole is a
failure. Getting faster never fails. 3x is generous on purpose — shared
runners are noisy and hardware shifts ratios — and still catches what the
gate is for: an algorithmic blowup, an accidental unoptimized build, or a
broken caller cache (the harness itself already refuses when a hit does
not beat a miss).

## History

Numbers are generated by the `perf-record` workflow (manual dispatch,
same pinned stack, `[skip ci]` on its commit so no run can commit-loop);
CI gates regressions but never writes this file. The recorder appends new
rows here, newest last, when it re-measures. Hand edits to the table above
are refused by review: the file is the output, not the input.

- 2026-11-16, Win11 x64, `v -cc gcc`: 1672x / 552x / 0.69x / 0.03x.
  First published table; tree not yet -prod-clean.
- 2026-11-17, Win11 x64, `v -prod -cc gcc`: 399x / 57x / 0.27x / 0.00x.
  Tree -prod-clean (UCD IN is a real `LineBreakClass` member; one subset
  loop dropped an unused value).
- 2026-11-17, ubuntu-24.04 CI (`v -prod -cc gcc`): 427.97x / 31.27x / 0.07x / 0.00x / 626.45x / 155.64x / 1324.45x / 2569.33x / 717.41x / 332.46x / 81.50x / 747.14x / 35.17x / 59.91x / 72.03x / 86.85x / 329.16x / 105.04x / 27.10x / 132.15x / 37.32x / 185.58x / 7.65x / 3.14x / 40.49x / 2.84x / 86.76x / 98.46x / 72.42x / 39.60x / 7.75x / 43.11x / 2.44x / 2.67x / 2.88x / 3.73x / 30.38x / 26.02x / 7.82x / 19.10x / 3.57x / 12.51x / 0.72x / 0.30x.
  Generated by tools/perf_record.py from one bench run; versions unrecorded.
- 2026-11-23, ubuntu-24.04 CI (`v -prod -cc gcc`): 28.18x / 5.21x / 0.07x / 0.00x / 27.71x / 37.17x / 21.60x / 29.46x / 28.44x / 113.44x / 42.31x / 30.55x / 38.04x / 19.21x / 20.90x / 17.11x / 27.40x / 19.57x / 24.95x / 7.74x / 5.99x / 8.41x / 0.83x / 0.67x / 2.11x / 1.19x / 1.72x / 1.44x / 3.06x / 13.40x / 4.17x / 2.04x / 2.88x / 1.07x / 1.12x / 1.15x / 2.74x / 4.97x / 7.20x / 1.30x / 0.78x / 0.78x / 0.71x / 0.27x.
  Generated by tools/perf_record.py from one bench run; versions unrecorded.
