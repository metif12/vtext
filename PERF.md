# Performance record

Throughput measured better — or the claim is not made (GOAL.md). This file
is the canonical A/B record: the same workload timed on vtext and on the
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

What each side does differs and the table says so: vtext lays the line out
(bidi, joining, substitution, positioning and measurement) where HarfBuzz
only shapes; Pango lays out and wraps where vtext wraps; fc-match spawns a
process where the provider calls the library; fontTools parses into Python
objects where vtext parses into its own tables; Pillow renders with its own
bundled FreeType at default flags where vtext fills hinted. Throughput is
the comparison; correctness is proven elsewhere, per part.

The optimizing C compiler matters: a tcc build measures the compiler's
checks, not the engine. The primary table is `-prod`; the `-cc gcc` table
stays as the pre-clean baseline.

## Current numbers

<!-- perf-baseline:prod:start -->
| op | what | vtext | rival | vtext/rival |
| --- | --- | --- | --- | --- |
| shape latin-1024 | layout+shape vs hb shape | 8.1 ms/paragraph | 19.0 us/paragraph | 427.97x |
| shape arabic-1024 | layout+shape vs hb shape | 5.5 ms/paragraph | 175.0 us/paragraph | 31.27x |
| raster amiri-A-T-32 miss | sustained miss vs Pillow | 5.5 us/op | 80.8 us/op | 0.07x |
| raster amiri-A-32 hit | caller cache vs Pillow | 47.0 ns/op | 80.8 us/op | 0.00x |
| shape hebrew-1024 | layout+shape vs hb shape | 43.0 ms/paragraph | 68.7 us/paragraph | 626.45x |
| shape cjk-1024 | layout+shape vs hb shape | 2.3 ms/paragraph | 15.0 us/paragraph | 155.64x |
| shape thai-1024 | layout+shape vs hb shape | 95.5 ms/paragraph | 72.1 us/paragraph | 1324.45x |
| shape lao-1024 | layout+shape vs hb shape | 96.6 ms/paragraph | 37.6 us/paragraph | 2569.33x |
| shape khmer-1024 | layout+shape vs hb shape | 109.4 ms/paragraph | 152.5 us/paragraph | 717.41x |
| shape myanmar-1024 | layout+shape vs hb shape | 65.8 ms/paragraph | 198.0 us/paragraph | 332.46x |
| shape syriac-1024 | layout+shape vs hb shape | 9.9 ms/paragraph | 122.1 us/paragraph | 81.50x |
| shape thaana-1024 | layout+shape vs hb shape | 49.9 ms/paragraph | 66.8 us/paragraph | 747.14x |
| shape nko-1024 | layout+shape vs hb shape | 2.2 ms/paragraph | 62.8 us/paragraph | 35.17x |
| shape georgian-1024 | layout+shape vs hb shape | 2.5 ms/paragraph | 42.0 us/paragraph | 59.91x |
| shape armenian-1024 | layout+shape vs hb shape | 2.5 ms/paragraph | 34.4 us/paragraph | 72.03x |
| shape ethiopic-1024 | layout+shape vs hb shape | 3.3 ms/paragraph | 38.2 us/paragraph | 86.85x |
| shape devanagari-1024 | layout+shape vs hb shape | 48.2 ms/paragraph | 146.5 us/paragraph | 329.16x |
| shape bengali-1024 | layout+shape vs hb shape | 45.9 ms/paragraph | 437.1 us/paragraph | 105.04x |
| shape nastaliq-1024 | layout+shape vs hb shape | 45.3 ms/paragraph | 1.7 ms/paragraph | 27.10x |
| shape marks-1024 | layout+shape vs hb shape | 34.5 ms/paragraph | 260.9 us/paragraph | 132.15x |
| shape digits-1024 | layout+shape vs hb shape | 5.9 ms/paragraph | 157.7 us/paragraph | 37.32x |
| shape bidi-1024 | layout+shape vs hb shape | 22.0 ms/paragraph | 118.3 us/paragraph | 185.58x |
| layout latin-wrap-1024 | wrap+measure vs Pango layout | 9.0 ms/paragraph | 1.2 ms/paragraph | 7.65x |
| layout arabic-wrap-1024 | wrap+measure vs Pango layout | 6.2 ms/paragraph | 2.0 ms/paragraph | 3.14x |
| layout hebrew-wrap-1024 | wrap+measure vs Pango layout | 43.4 ms/paragraph | 1.1 ms/paragraph | 40.49x |
| layout cjk-wrap-1024 | wrap+measure vs Pango layout | 2.9 ms/paragraph | 1.0 ms/paragraph | 2.84x |
| layout thai-wrap-1024 | wrap+measure vs Pango layout | 96.0 ms/paragraph | 1.1 ms/paragraph | 86.76x |
| layout lao-wrap-1024 | wrap+measure vs Pango layout | 97.7 ms/paragraph | 992.0 us/paragraph | 98.46x |
| layout khmer-wrap-1024 | wrap+measure vs Pango layout | 109.8 ms/paragraph | 1.5 ms/paragraph | 72.42x |
| layout myanmar-wrap-1024 | wrap+measure vs Pango layout | 66.3 ms/paragraph | 1.7 ms/paragraph | 39.60x |
| layout syriac-wrap-1024 | wrap+measure vs Pango layout | 10.4 ms/paragraph | 1.3 ms/paragraph | 7.75x |
| layout thaana-wrap-1024 | wrap+measure vs Pango layout | 50.4 ms/paragraph | 1.2 ms/paragraph | 43.11x |
| layout nko-wrap-1024 | wrap+measure vs Pango layout | 2.6 ms/paragraph | 1.1 ms/paragraph | 2.44x |
| layout georgian-wrap-1024 | wrap+measure vs Pango layout | 2.9 ms/paragraph | 1.1 ms/paragraph | 2.67x |
| layout armenian-wrap-1024 | wrap+measure vs Pango layout | 2.9 ms/paragraph | 989.7 us/paragraph | 2.88x |
| layout ethiopic-wrap-1024 | wrap+measure vs Pango layout | 3.8 ms/paragraph | 1.0 ms/paragraph | 3.73x |
| layout devanagari-wrap-1024 | wrap+measure vs Pango layout | 48.6 ms/paragraph | 1.6 ms/paragraph | 30.38x |
| layout bengali-wrap-1024 | wrap+measure vs Pango layout | 46.4 ms/paragraph | 1.8 ms/paragraph | 26.02x |
| layout nastaliq-wrap-1024 | wrap+measure vs Pango layout | 45.9 ms/paragraph | 5.9 ms/paragraph | 7.82x |
| layout marks-wrap-1024 | wrap+measure vs Pango layout | 34.7 ms/paragraph | 1.8 ms/paragraph | 19.10x |
| layout digits-wrap-1024 | wrap+measure vs Pango layout | 6.4 ms/paragraph | 1.8 ms/paragraph | 3.57x |
| layout bidi-wrap-1024 | wrap+measure vs Pango layout | 22.5 ms/paragraph | 1.8 ms/paragraph | 12.51x |
| discovery fontconfig-match | provider match vs fc-match | 2.6 ms/op | 3.6 ms/op | 0.72x |
| inspect fonttools-load | load+parse vs fontTools | 1.2 ms/op | 4.1 ms/op | 0.30x |
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
