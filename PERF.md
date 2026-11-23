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

The comparison column is a **signed speedup factor**: positive means HarfAra
is faster, negative means it is slower, and the magnitude is how many times.
`-28.2x` reads "28.2 times slower", `+14.3x` reads "14.3 times faster" — a slow
row is negative, not a positive number that looks like a speedup.

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
| op | what | harfara | rival | speedup |
| --- | --- | --- | --- | --- |
| shape latin-1024 | layout+shape vs hb shape | 955.6 us/paragraph | 25.5 us/paragraph | -37.50x |
| shape arabic-1024 | layout+shape vs hb shape | 1.4 ms/paragraph | 231.6 us/paragraph | -5.93x |
| raster amiri-A-T-32 miss | sustained miss vs Pillow | 6.5 us/op | 117.5 us/op | +18.10x |
| raster amiri-A-32 hit | caller cache vs Pillow | 65.0 ns/op | 117.5 us/op | +1807.62x |
| shape hebrew-1024 | layout+shape vs hb shape | 2.8 ms/paragraph | 91.3 us/paragraph | -30.64x |
| shape cjk-1024 | layout+shape vs hb shape | 796.0 us/paragraph | 21.1 us/paragraph | -37.73x |
| shape thai-1024 | layout+shape vs hb shape | 2.3 ms/paragraph | 94.7 us/paragraph | -24.19x |
| shape lao-1024 | layout+shape vs hb shape | 1.6 ms/paragraph | 49.5 us/paragraph | -32.00x |
| shape khmer-1024 | layout+shape vs hb shape | 6.5 ms/paragraph | 201.6 us/paragraph | -32.20x |
| shape myanmar-1024 | layout+shape vs hb shape | 32.7 ms/paragraph | 274.7 us/paragraph | -118.97x |
| shape syriac-1024 | layout+shape vs hb shape | 8.6 ms/paragraph | 172.9 us/paragraph | -49.89x |
| shape thaana-1024 | layout+shape vs hb shape | 3.0 ms/paragraph | 90.7 us/paragraph | -32.90x |
| shape nko-1024 | layout+shape vs hb shape | 4.0 ms/paragraph | 96.7 us/paragraph | -41.54x |
| shape georgian-1024 | layout+shape vs hb shape | 1.1 ms/paragraph | 58.1 us/paragraph | -19.35x |
| shape armenian-1024 | layout+shape vs hb shape | 961.0 us/paragraph | 46.8 us/paragraph | -20.55x |
| shape ethiopic-1024 | layout+shape vs hb shape | 1.1 ms/paragraph | 54.7 us/paragraph | -19.99x |
| shape devanagari-1024 | layout+shape vs hb shape | 5.9 ms/paragraph | 185.3 us/paragraph | -31.92x |
| shape bengali-1024 | layout+shape vs hb shape | 13.1 ms/paragraph | 580.5 us/paragraph | -22.51x |
| shape nastaliq-1024 | layout+shape vs hb shape | 63.8 ms/paragraph | 2.4 ms/paragraph | -26.55x |
| shape marks-1024 | layout+shape vs hb shape | 3.1 ms/paragraph | 345.2 us/paragraph | -8.99x |
| shape digits-1024 | layout+shape vs hb shape | 1.5 ms/paragraph | 213.0 us/paragraph | -7.14x |
| shape bidi-1024 | layout+shape vs hb shape | 1.5 ms/paragraph | 159.5 us/paragraph | -9.67x |
| layout latin-wrap-1024 | wrap+measure vs Pango layout | 1.7 ms/paragraph | 1.5 ms/paragraph | -1.10x |
| layout arabic-wrap-1024 | wrap+measure vs Pango layout | 2.1 ms/paragraph | 2.6 ms/paragraph | +1.26x |
| layout hebrew-wrap-1024 | wrap+measure vs Pango layout | 3.3 ms/paragraph | 1.4 ms/paragraph | -2.38x |
| layout cjk-wrap-1024 | wrap+measure vs Pango layout | 1.8 ms/paragraph | 1.3 ms/paragraph | -1.32x |
| layout thai-wrap-1024 | wrap+measure vs Pango layout | 2.7 ms/paragraph | 1.4 ms/paragraph | -1.95x |
| layout lao-wrap-1024 | wrap+measure vs Pango layout | 2.0 ms/paragraph | 1.2 ms/paragraph | -1.64x |
| layout khmer-wrap-1024 | wrap+measure vs Pango layout | 7.0 ms/paragraph | 2.0 ms/paragraph | -3.48x |
| layout myanmar-wrap-1024 | wrap+measure vs Pango layout | 32.8 ms/paragraph | 2.2 ms/paragraph | -14.63x |
| layout syriac-wrap-1024 | wrap+measure vs Pango layout | 9.5 ms/paragraph | 1.8 ms/paragraph | -5.30x |
| layout thaana-wrap-1024 | wrap+measure vs Pango layout | 3.4 ms/paragraph | 1.5 ms/paragraph | -2.31x |
| layout nko-wrap-1024 | wrap+measure vs Pango layout | 4.8 ms/paragraph | 1.4 ms/paragraph | -3.53x |
| layout georgian-wrap-1024 | wrap+measure vs Pango layout | 1.6 ms/paragraph | 1.4 ms/paragraph | -1.17x |
| layout armenian-wrap-1024 | wrap+measure vs Pango layout | 1.5 ms/paragraph | 1.3 ms/paragraph | -1.21x |
| layout ethiopic-wrap-1024 | wrap+measure vs Pango layout | 1.7 ms/paragraph | 1.3 ms/paragraph | -1.33x |
| layout devanagari-wrap-1024 | wrap+measure vs Pango layout | 6.5 ms/paragraph | 2.2 ms/paragraph | -2.99x |
| layout bengali-wrap-1024 | wrap+measure vs Pango layout | 13.4 ms/paragraph | 2.4 ms/paragraph | -5.59x |
| layout nastaliq-wrap-1024 | wrap+measure vs Pango layout | 64.9 ms/paragraph | 8.8 ms/paragraph | -7.42x |
| layout marks-wrap-1024 | wrap+measure vs Pango layout | 3.7 ms/paragraph | 2.4 ms/paragraph | -1.55x |
| layout digits-wrap-1024 | wrap+measure vs Pango layout | 2.2 ms/paragraph | 2.6 ms/paragraph | +1.19x |
| layout bidi-wrap-1024 | wrap+measure vs Pango layout | 2.3 ms/paragraph | 2.6 ms/paragraph | +1.16x |
| discovery fontconfig-match | provider match vs fc-match | 3.5 ms/op | 5.0 ms/op | +1.42x |
| inspect fonttools-load | load+parse vs fontTools | 1.9 ms/op | 6.2 ms/op | +3.36x |
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
the baseline out of the markers above. It normalizes the signed factor to the
HarfAra/rival slowdown ratio and gates on that: a row fails when it is more
than 3x slower than the recorded one; a missing row fails too, because a silent
hole is a failure. Getting faster never fails. 3x is generous on purpose — shared
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
- 2026-11-23, ubuntu-24.04 CI (`v -prod -cc gcc`): 27.95x / 4.93x / 0.05x / 0.00x / 25.81x / 38.09x / 20.60x / 29.05x / 28.49x / 103.06x / 41.73x / 26.52x / 39.01x / 16.22x / 18.03x / 16.89x / 25.93x / 18.27x / 19.80x / 7.75x / 5.92x / 8.42x / 1.22x / 0.86x / 2.87x / 1.88x / 2.42x / 2.23x / 3.95x / 15.59x / 5.67x / 2.46x / 3.79x / 1.47x / 1.60x / 1.64x / 3.23x / 5.57x / 6.23x / 1.70x / 0.92x / 0.90x / 0.71x / 0.27x.
  Generated by tools/perf_record.py from one bench run; versions unrecorded.
- 2026-11-23, ubuntu-24.04 CI (`v -prod -cc gcc`): -37.50x / -5.93x / +18.10x / +1807.62x / -30.64x / -37.73x / -24.19x / -32.00x / -32.20x / -118.97x / -49.89x / -32.90x / -41.54x / -19.35x / -20.55x / -19.99x / -31.92x / -22.51x / -26.55x / -8.99x / -7.14x / -9.67x / -1.10x / +1.26x / -2.38x / -1.32x / -1.95x / -1.64x / -3.48x / -14.63x / -5.30x / -2.31x / -3.53x / -1.17x / -1.21x / -1.33x / -2.99x / -5.59x / -7.42x / -1.55x / +1.19x / +1.16x / +1.42x / +3.36x.
  Generated by tools/perf_record.py from one bench run; versions unrecorded.
