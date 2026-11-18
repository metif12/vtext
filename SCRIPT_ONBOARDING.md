# Script onboarding checklist

Adding a script's shaping behaviour means implementing the `ScriptShaper`
interface and registering the struct — not editing the pipeline. This is
the E3 checklist; every item below is what the Khmer, Myanmar and Indic
migrations actually did, one commit per script. A slice that skips an
item says which one and why, in its commit message.

## 1. Corpus face

- An OFL-licensed face covering the script goes under `testdata/fonts/`,
  with its licence text as `OFL-<Name>.txt` beside the font (GFL is
  refused where an OFL backup exists — see the LatinModernMath row).
- Register the face in the ROADMAP corpus table (bytes, scripts,
  licence). The suite loads faces from that directory; a missing file
  fails loudly rather than falling back.

## 2. Registry

- Implement the five `ScriptShaper` methods in `shape/shaper.v`:
  `claims` (codepoint range), `default_features` (run order),
  `pre_ccmp_features` (asked features that run before `ccmp`, usually
  none — `ccmp`'s mark compositions have to exist before any feature
  reads them), `reorder_tail`, `split_run`.
- Hook the OpenType script tag into `shaper_for_script` and the range
  into `shaper_for_content`. Reorder and split dispatch on content
  because both run before the run script resolves; substitution
  dispatches on the script.
- No pipeline edits: feature order, reorder and split enter through the
  registry, and the old per-script branches delete in the same commit.

## 3. Feature order proof

- Every default-on feature is proven by toggling it off under
  uharfbuzz: `-pref` unfolds COENG+RO, `-blwf` unfolds COENG+TA, and so
  on. A feature whose off-toggle changes nothing is not a default.
- The order is proven by a neutered-order break-fix: run the group in
  the wrong order and the pin must fail (neutered pres-before-blwf
  leaves the low variant unfolded).
- The `pre_ccmp` slot needs its own proof. The precedent is Myanmar
  `blwf`: enabling it by default fuses KA+DOT, so it stays
  caller-asked and runs pre-`ccmp` only when asked. A default that
  breaks a corpus word the way `blwf` broke KA+DOT stays caller-asked
  with the pin that proves it.

## 4. HarfBuzz pins

- Pin gids, advances and offsets HB-exact in a `_test.v` suite named
  for the script family (`seasian_test.v` + `seasian_remainder_test.v`
  for Khmer/Myanmar, `indic_test.v` + `bengali_test.v` for Indic).
- Clusters stay honest per input where HarfBuzz merges onto the base
  (the kri/stra tails). The convention is recorded in the commit, not
  tuned around.
- Mark placement beyond anchors composes through `apply_mark_chain`
  (`layout/marks.v`): anchors place the mark, chains move it further,
  and HarfBuzz's sum is the pin.

## 5. Difftest

- Add the script's words to `tools/difftest/cases.tsv` (id, font,
  codepoints, dir, size — the header comment owns the format).
- `python tools/difftest/compare.py` must print `0 new diff(s),
  0 stale`: new diffs pin new behaviour, stale entries mean the
  baseline moved without the commit saying so.

## 6. Gates

- Full suite green, `v fmt` clean, difftest 0/0 — every slice, no
  exceptions.
- `modularity_test.v` owns the import rule: new shape code may use
  `vtext/font` and `vtext/ucd`; nothing new imports `layout` or
  `tools/`. A deliberate violation fails; the commit's break-fix
  proves it discriminates.
- A hot-path touch carries same-harness before/after numbers
  (`tools/rival_bench.v -prod -cc gcc`, absolute paragraph times on a
  quiet box) gated by `tools/perf_check.py` against `perf.md`. Ratios
  vs HarfBuzz are not a target.

## 7. Paper trail

- One commit per script, message `Phase 11 <slice>: <what>`, body
  naming the proof (toggle, neuter, pin) and the honest divergences.
- The ROADMAP Open-work row flips in the same commit (the M1
  precedent: ratchet test plus roadmap hunk, one commit).
