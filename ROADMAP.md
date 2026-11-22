# Roadmap

Where this library is, what is left in the engine, and what comes after it.
Status first, evidence with every claim, history only where it binds future
work. Dated entries use the landing date; anything undated is open.

## How to read this

**Status words** (load-bearing — a slice is one of these):

- **landed** — committed, full suite green, difftest 0 new / 0 stale, pushed.
- **in progress** — an agent or owner is working it in a worktree right now.
- **open** — scoped, unassigned.
- **triggered** — lands when a font needs it, not before; the trigger is stated.
- **refused** — will not land; the reason is stated.

**Evidence rules** (every landed slice was held to these):

- Pins are measured (HarfBuzz via uharfbuzz, fontTools, FreeType), never invented.
- Every slice carries a break-fix control: neuter the mechanism, watch the test fail, restore.
- The gate is the full suite plus `tools/difftest/compare.py` at 0 new / 0 stale.
- One commit per slice, verified before commit, pushed after.
- Examples are corpus-only: committed OFL faces, no installed system fonts, no
  Windows-only faces, rendered PNGs gitignored.
- Every committed font ships its licence text beside it (OFL almost everywhere;
  Latin Modern Math is GFL — the one exception, documented where it lands).
- Generated UCD tables are committed with their inputs; the licence travels
  with them via `.gitignore` exceptions, the way `LineBreakTest.txt` was first.

## Where this is

The engine is done for Arabic, Persian and Urdu, for Latin/Cyrillic/Greek,
and for the layout math around them. Hebrew, Syriac, Thaana and NKo are
HarfBuzz-pinned; Thai, Lao, Khmer and Myanmar carry corpus pins, Khmer's
coeng fusions shaping HB-exact with the pref reorder and pres-group landed
alongside; CJK line breaking is conformance-pinned.

| Part | State | Evidence |
| --- | --- | --- |
| sfnt/TTC containers, table directory, cmap (incl. 13, 14) | landed | `font_test`, CFF/CFF2 detection |
| WOFF1 (WOFF2 refused: no brotli decoder) | landed 7.9/8.1 | `woff_test` |
| Metrics, boxes, unhinted raster | landed | `stbtt_test`, Pillow legs |
| Normalization (UAX #15) | landed | `normalize_test` + `NormalizationTest.txt` |
| Bidi (UAX #9) | landed | bidi suite, NFD-drift fix |
| Arabic joining + GSUB/GPOS application | landed | joining/GSUB/GPOS suites |
| SinglePos, pair kern, chaining-1, class-contextual | landed | `singlepos_apply_test`, context suites |
| Script/language override | landed 7.2 | `script_lang_test` |
| Common-base marks | landed 7.3 | `commonbase_test` |
| Grapheme clusters; word/sentence tables | landed 8.2 (engines in `layout/`) | 1944/1944 + 512/512 + 853/853 floors |
| Case mapping (incl. tr/az) | landed 8.3 | SpecialCasing conformance |
| Line breaking (UAX #14) | landed, 19,346/19,346 | conformance floor |
| Wrap: align/justify/kashida/hyphen-policy/modes/ellipsize/tabs | landed 7.4, 7.5, 8.4 | `align_test`, `hyphen_wrap_test`, `ellipsize_wrap_test` |
| Vertical single column | landed | `vertical_test`, columns cut and pinned |
| CFF reader + subset rebuild (CFF2/CID refused) | landed 7.9 | `cff_test`, `subset_cff_test` |
| MATH reader + Face wiring | landed 8.7 | `math_test` |
| Variable instancing | landed 7.10 | `varinstance_test` + 142,848 sweep |
| Reference cache helper (caller-owned) | landed 7.11-1H | `cache_test` |
| fontconfig match/sort/coverage | landed 8.8 | `match_test` (CI-owned leg) |
| Subsetter (glyf + CFF rebuilds; CFF2/CID refused) | landed | `subset_test` |
| C API + usage guide | landed | `capi.v`, `vtext.h`, `USAGE.md`, smoke test |
| Inspection API (on `shape.Font`) | landed | `inspect_test`, `fontdump`/`fontcheck`/`shapetrace` |
| Examples (12, multilingual, corpus-only) | landed | `examples/` |
| Indic machine, SE-Asian engine, color/hinting, stroking, synth/LCD, CoreText/DW providers, rival A/B | landed | Phase 7–9 below |

Suite: 82 test files, all passing (2026-11-18). Differential baseline:
151 entries, exact-string matching, 0 new / 0 stale (Pango legs skip aloud
on Windows without a Pango stack; CI verifies them).

## Conformance floors

Floors asserted on every run — a drop fails the suite, not a review.

| Floor | Score | Run by |
| --- | --- | --- |
| UAX #14 `LineBreakTest.txt` (18.0.0) | 19,346/19,346 | `linebreak_conformance_test` |
| UAX #29 `WordBreakTest.txt` | 1944/1944 | `wordbreak_test` |
| UAX #29 `SentenceBreakTest.txt` | 512/512 | `wordbreak_test` |
| `SpecialCasing.txt` expectations | 120 cases, 0 failed | `case_test` |
| Case table rows | 1601/1508/1578/16 | `case_test` (dropping U+0061 fails at 1600) |
| Hyphenation word list | 8 words + injection/edge rows | `hyphen_test` |
| CJK ID-class / CJK-subset | 0 fail on 1,753 / 0 on 5,333 | `cjkbreak_test` |
| `script`/`language` overrides | locl positions, gid swaps | `script_lang_test` |
| Device deltas / VariationIndex reads | byte-pinned | `gpos_device_test`, `gpos_valuesize_test` |
| Chaining-format-1 ratchet | fires on nothing in corpus | corpus test (deliberate fail on gain) |

## Phase 1: the engine's remaining gaps — closed

Everything here was a correctness question, not a feature. What survives is
the decisions, because they bind later work:

- **NFD index drift in visual ordering** — fixed 2026-10-16.
- **Line breaking to the file's own end** — 19,346/19,346. LB28a's fourth arm
  (`(AK|◌|AS) × (AK|◌|AS) VF`) was an unwritten lookahead, not missing data;
  the three `Pf|ID` span cases fell to a counter threaded through the walk;
  LB19a's exception reads off the pair with the base read through marks. The
  file contradicts itself in 130 places; every remaining disagreement is
  named, none is coded around.
- **Numeric breaking, aksara-vs-mark, chaining-context positioning,
  context-sensitive kerning, SinglePos format 2, GSUB joining, cmap 13/14,
  vertical-extent double-count, tools/metrics** — done (struck sections kept
  in history).
- **Cursive attachment** — read and verified glyph-for-glyph against
  fontTools, never wired: the one corpus rule that reaches its own glyphs is
  vestigial (Noto Nastaliq, four one-sided anchors, no adjacent exit+entry
  pair; HarfBuzz reports zero x-offsets on سلام). The test fails the day a
  shaped line grows a pair.
- **A glyph cache in this library** — settled against: the cache is the
  caller's (see the performance section and 7.11). No atlas was ever real.
- **Performance** — `layout_paragraph` was quadratic (72 ms at 1024 chars);
  linear now (4 ms). Cause was ligature matching copying O(n) per position,
  fixed by a once-computed bound; rasterization was never the cost (3.9 us
  per glyph). Consequence: nothing else on this roadmap is a performance
  item, and optimizations land with before/after on the same harness or not
  at all. 2026-11-17: chaining evaluation hoisted from per-pair/per-mark to
  once per font per line (`kern_chain_offsets`, chain memo); same-box -prod
  arabic-1024 went 51 ms back to 8.1 ms with identical shaping, and the A/B
  table reads 20.67x against the 57x baseline.
- **Device and variation offsets** — zero Device tables in 2,450,058 value
  records over 379 faces; 9,432 VariationIndex, all in two variable fonts,
  resolving to zero at the default instance. Readers pinned; no plumbing.
- **CFF subsetting** — deferred by measurement (0 CFF faces in the 379-face
  scan): a reader verified only against matching tables is the
  fixture-matches-reader failure, so the subsetter refused until 7.9 brought
  a real font.

## Phase 2: reach — done

Language and platform coverage, the public API, documentation — all landed.

- The shaping engine covers Arabic/Persian plus the Latin that comes with
  them; the script map in Phase 9 tracks everything after.
- The C API is `vtext.h` with opaque handles over contexts, font sets, fonts,
  lines, wraps, breaks and bitmaps (`capi.v`, `@[export]` wrappers, errors in
  a caller-owned buffer, explicit `i32` at the boundary because V `int` is
  64-bit here). Verified by `examples/c-api/smoke.c` through both link routes
  (tcc direct, gcc via `vtext.def`). No versioned C release exists (only
  GitHub Release `v0.1.0`, 2026-10-16) — the C library ships as per-run CI
  artifacts, not releases.
- Hard-won C-export facts, kept because they bite again: the wrappers needed
  the compiler's export fix (the tcc `-export-all-symbols` belt stays until
  that lands); the module initializer needed 1 MB of stack until the big
  `ucd_names` tables became parsed strings like every other generated table
  (the smoke test links a default 1 MB stack and proves it); glyph backings
  cross to C only behind unmanaged headers (`c_array` rule, valgrind-clean),
  because a managed V array's backing must not meet C free (glibc aborted
  while the Windows heap tolerated it); the MinGW import-library step runs
  before the smoke build because V links the DLL under the internal object
  name `out` (same root cause as the macOS install name); the MinGW runtime
  DLLs travel beside the outputs because a loader failure prints nothing.
- `USAGE.md` is the quickstart plus the full reference with ownership rules;
  `GOAL.md` is the one paragraph that settles scope arguments.

## Phase 3: examples — done

Twelve examples, all corpus-only, all multilingual by requirement — every
example draws Arabic-script, Latin and CJK text, and the set covers the
terminal/geek faces (FiraCode, JetBrainsMono, Cascadia Code, the Nerd patch
with PUA icons) with no size limit (NotoSansSC rides along at 17 MB).
`hello`, `rtl_line`, `mark_stack` (NotoNaskhArabic — Amiri anchors sit at
y=0, Naskh gives nonzero placement, both HarfBuzz-verified), `kerning`
(Amiri closes Latin AV by 62; AV at 550 vs 612 end to end), `fallback`,
`bidi`, `features` (Amiri `fi`/liga nulls beside HarfBuzz — HB fuses
neither; real pins are Amiri `fi`→6630, Naskh Allah/dlig, `=>` gid swaps on
FiraCode/JetBrainsMono/Cascadia/nerd, icon F09B), `line_break`, `glyph_grid`,
`spacing`, `corpus`, `c-api`. No Windows-only faces anywhere; rendered PNGs
are gitignored, never committed.

## Phase 4: tools — done

`fontdump`, `shapetrace`, `fontcheck`, `metrics` (found the doubled vertical
extent), `glyphdump`, `subset` (glyf and CFF rebuilds landed; CFF2/CID
refused with the reason),
`capicheck` (the full C export list, both directions, CI-gated before the
library builds). Deliberately not taken: deduplicating the 31 copies of a
font-path helper across test files — each test stays self-contained so any
single file runs alone.

## Differential shaping: four references, one baseline

`tools/shapedump.v` dumps any case as tab-separated columns (glyph, advance,
offsets, cluster, mark flag, source font, box, coverage sum, wrap line);
`tools/difftest/compare.py` lays four engines beside it — uharfbuzz for
shaping, fontTools for outline identity and advances, Pillow for box and
coverage, Pango for line counts and widths. Baseline matching is
exact-string: 151 entries, 0 new / 0 stale.

Rules that cost real debugging, kept:

- Shape multi-script cases per script span (maximal bidi-class spans, digits
  folded into the neighbouring strong run) — one buffer lets HarfBuzz guess
  Latin from the first strong character and return Arabic unshaped.
- The lam-alef fusion is not a bug: the shaper fuses what it recognises as
  one shape (advance-neutral, 691 vs 245+446). The cluster-split entries stay
  with this reason.
- Same form, different drawings is font-internal metric divergence, not a
  defect: Amiri's presentation noon/yeh vs its GSUB initials (the deliberate
  cmap route's measured price). Baseline entries stay with this reason.
- stb-vs-FreeType edge pixels are a third party's convention (Pillow box
  10x13 vs stb 12x14 on one dal gid, outlines agreeing) — the one ink entry
  with its reason. Pango's full-line Cairo renders of folded code ligatures
  rasterize past the pixel bound (maxdiff 224–255): recorded, not tuned.
- Pango full-line pixel renders drift with the runner's Pango/Cairo stack,
  not with this engine: 2026-11-17 the arabic-marks pixel entry moved
  30.6/2815 → 30.1/2797 at the same maxdiff 255 with the same 34 shaping
  diffs, measured identically on consecutive runs, so the baseline follows
  the measured renderer rather than the code.

## Phase 5: every script — done, holes moved to Phase 9

- **Chaining format 1** — `chain_glyphs`: reader, matcher, both apply loops,
  every kind gate. No corpus font writes one (352 Windows faces scanned;
  only Leela* Malayalam), so lookup 13 of LeelawUI is the real-font fixture
  (46 backtrack/covered/lookahead rules through lookup 69) and the corpus
  test fails deliberately if any font gains a rule.
- **Class-based contextual (GSUB 5/2, 5/3, 6/1, 6/2)** — `context_classes`,
  `chain_glyphs`, `chain_classes`. The "no font writes them" premise was
  stale: Amiri carries all four (lookups 55/27/28/66), so fixtures are real
  tables beside built bytes (1591→4031, 1817→3378, 1632→3396, 5439→5440).
  Two misreads caught on the way: plain format-3 counts sit before coverage
  offsets (Amiri lookup 27 is the control), and class-only lookups needed the
  format-1 coverage miss to stop returning early.
- **Script-following mark collection** — `mark_offset_in`: arab stays the
  parse-time default, the run's script selects the lookups. Arabic unchanged
  by construction; a Latin acute on q lands at its HarfBuzz anchor (825, −328).
- **Line breaking to 19,346** — the width table (UAX#11) for LB30, LB9's
  post-break mark exception, `.ex`/`.hy` leaving the prohibited-end list,
  LB28a/LB30b/LB26/LB20a/LB21a as pairs with mark read-through.
- **UCD carve-out** — `tables.v`, `properties.v` and the 13 generated
  `ucd_*.v` in `ucd/` as `module ucd`; moved free functions are `pub`.
  `parse_names` preserves the interned empty group name (lam reported Meem
  before the fix). Conformance inputs committed with licence-travels
  comments; `emoji-data.txt`'s tree copy is 16.0.0 while the word-break work
  needed 18.0.0, so `emoji-data-18.0.0.txt` is versioned beside it (U+2701
  answers WB3c wrong on the old file — 2 committee cases).
- **Vertical text** — single-column placement behind `LayoutOptions.vertical`
  with HarfBuzz-TTB-pinned geometry, reachable from C. Columns cut and
  pinned since (`slice_for_column`, `vertical_test`).

## Phase 6: the modular replacement — done

One library, separate parts, dependencies one way
(`layout` → `shape` → `font` → `ucd`, `raster` a leaf below `font`,
`capi` over all, no part imports a tool): `vtext.ucd`, `vtext.font`
(containers, cmap, reader, Face with metrics + GSUB/GPOS parsing +
application, stb primitives), `vtext.shape` (joining, normalization, bidi,
`Context`, `Font`/`FontSet`/`Glyph`, `inspect.v`), `vtext.layout`
(`linebreak.v`, `layout.v`), `vtext.raster` (`GlyphBitmap`; `box_only` /
`render_into` stay methods on `font.Face` because methods live in the type's
own module, so `font` imports the leaf), `vtext.subset`
(`subset_font(font, seed)` + CLI), `vtext.capi` (last, wraps all;
`vtext.h` stays the single header).

Seams, each an explicit interface: `FontSource` (file, bytes, provider),
`RasterBackend` (box-for-gid plus fill-this-buffer), `BreakPolicy` (UAX #14
default, dictionaries behind it), the caller-owned glyph cache (font id,
gid, size, subpixel offset — the only honest key), per-part options structs
on the `LayoutOptions` pattern. Not goals, unchanged throughout: no HarfBuzz
bindings, no ports, no font authoring; boxes/cascade/painting are the
caller's (`../vweb` builds on this line).

## Phase 7: the full replacement, on every platform

Per-part replacement with its own baseline, green on all three CI runners
(Windows/Linux/macOS, both arches CI provides) or it does not land. The byte
reader is endian-clean by construction; WASM is a spike, not a commitment.

**7.1 GPOS positioning in layout — landed 2026-11-15.** SinglePos folds into
advances and placements after substitution, under the pair-kern feature's
single half (`kern` horizontal, `vkrn` vertical) plus the applied
discretionary features — same off-switch semantics as substitution, each
lookup consulted once. Marks keep the anchor pass's answer (no double
shift); single-pos applies to non-marks only. Pinned by
`singlepos_apply_test.v` (first-match and accumulation hand lookups,
U+06E5/U+06E6 at (−170, +230) beside HarfBuzz, Amiri's thirty dead singles
staying dead). Cursive stays unwired — vestigial, see Phase 1. No corpus
line moves; difftest 0/0.

**7.2 Script and language override — landed 2026-11-15 (both halves).**
`LayoutOptions.script` / `.language`, threaded from run detection through
substitution, kern, single-pos, marks and the C boundary. Empty is the
default path byte-for-byte. Naming a script forces every run under it (`=>`
unfolds under `arab` on FiraCode, whose calt lives under latn); naming a
language asks the tagged system with default fallback (Amiri UR U+06F4
gid 260→1463, Naskh FAR U+066B gid 160→162, Naskh SND U+0645 gid 72→73).
`locl` runs after `ccmp` and before joining forms (written against base
glyphs). Direction stays the `base_dir` argument; `vert`/`vkrn` stay
mode-driven. First half also turned programming ligatures on by default
(`calt`/`liga`/`clig` after `rlig`; `-tag` off-switch, `+tag` explicit).
Pinned by `script_lang_test.v` and `calt_liga_test.v`, each with break-fix
controls, plus the C-struct arrival in `vertical_test.v`.

**7.3 Common-base marks — landed 2026-11-15.** Zyyy/Zinh resolves to the
neighbouring strong script in logical order (preceding first, arab last
resort), mode-independent. Pinned by `commonbase_test.v` on MS Gothic
(dakuten/handakuten on the dotted circle land on the latn anchor, hiragana
keeps kana, neighbourless tatweel keeps arab).

**7.4 Align, justify, kashida — landed 2026-11-16.** Opt-in `align` /
`align_width` (single line) with wrap width for wrapped lines. Center/right
shift; justify widens spaces, or inserts U+0640 tatweels for uniform Arabic
lines where slack buys whole advances (no corpus `just` feature; all three
Arabic faces carry the glyph). Kashida re-lays the line's own text —
neighbours keep join states, one tatweel per gap (stacked tatweels fuse into
dedicated ligatures per HarfBuzz), lam-alef gap skipped, remainder to
spaces; mixed lines stretch spaces, last wrapped line stays flush, vertical
ignores align. C struct mirrors both fields. Pinned by `align_test.v`
(HB-grown 82.432 مدرسة, 60.672 سلام at 32 px).

**7.5 Hyphenation as a `BreakPolicy` — landed 2026-11-15 (both halves).**
Liang over embedded US-English patterns (`layout/hyphen.v`,
`ucd/ucd_hyphen.v` — hand-authored MIT rows; TeX ushyph evaluated and
rejected, CTAN's licence text unusable, source and rationale recorded with
the table). Every further language is data, not code. The wiring half is
`wrap_paragraph_with_policy`: `Uax14Breaks` answers the plain call
line-for-line; `HyphenBreaks` merges ASCII-word points in order; overlong
words break with an appended hyphen glyph (undersized targets fall back to
plain breaks, then whole-word overflow); digits and vertical never
hyphenate. C callers keep UAX #14. Pinned by `hyphen_test.v` (word list,
edge minima 2/3) and `hyphen_wrap_test.v` (equivalence + hyphen pins).

**7.6 Indic and Khmer — first cut landed 2026-11-16.** UCD Indic tables
generated like the rest (`tools/gen_indic.v` → `ucd/ucd_indic.v`: 37
syllabic values, 16 positional; inputs committed with licence-travels
exceptions); committed OFL NotoSansDevanagari-Variable (1117 glyphs,
`akhn rphf blwf cjct` under `deva`+`dev2`); the syllable machine as
`shape/indic.v` (segmentation, Left-matra reorder, conjunct finder —
imports only `vtext.ucd`, nothing existing touched). Pinned by
`indic_test.v` beside HarfBuzz: segmentation == HB clusters, reorder ==
HB visual order, akhn smoke (KSSA → gid 90), राम exact agreement, with
mutation break-fix (neutered reorder, dropped Virama row). Engine gaps
documented in-test: logical-order spacing matras, dropped ccc-0 matras, no
fusion by default. Follow-up: feeding reordered runs into GSUB (the
joining hook), repha, split matras, pres/half/blwf/rphf, GPOS marks.

**7.7 Color + hinting landed 2026-11-17.** COLR/CPAL (layered outline color
with v1-prefix detection), CBDT/EBDT (formats 1/2/6/7), sbix strikes and
SVG refusal (documents refused with reason; PNG-wrapped pixels refused, no
decoder in tree) behind `box_only`/`render_into` (`font/color.v` readers +
`raster/color.v` straight-alpha source-over composite), monochrome fallback
so colorless faces render exactly as before; grid-fit autohinter
(`font/hint.v` + `raster/hint.v`, Amiri dal pin within 1px/few-percent of
FreeType's autohinter). Pinned by `raster_color_test.v` (corpus sweep,
synthetic fixtures, twin-Python composite pins, break-fix) and
`raster_hint_test.v` (passthrough-identity break-fix). A full bytecode
interpreter lands only if a corpus font needs it — measured first, not
assumed.

**7.8 Providers: Core Text + DirectWrite landed 2026-11-17.** Each pinned on its own
OS, none elsewhere — the fontconfig pattern exactly. `providers/coretext.v`
resolves a family through CoreText to file path plus matched family;
`providers/directwrite.v` walks the real DirectWrite path on Windows
(factory via the `DWriteCreateFactory` DLL export — `CoCreateInstance`
answers `REGDB_E_CLASSNOTREG`, measured — through collection, family,
first-matching font and the local-file-loader key to a path, matched family
read beside it). Anything unusable answers none with reason, never a wrong
font. Pinned by `providers_os_test.v` (off-OS none plus skip-aloud, macOS
try-real-or-skip, Windows real asserts) and `providers_dw_test.v` (Arial
resolves to an existing path with named family).

**7.9 CFF/CFF2 with a real font — reader landed 2026-11-15.** OFL Source
Sans 3 OTF (non-CID Type 2, 2,478 glyphs); `font/cff.v` reads header,
INDEXes, Top DICT, CharStrings, charset, Private, both subr sets through
the existing curve path. Pinned by `cff_test.v` against fontTools with a
corrupt-byte break-fix. CFF2 still refuses (no committed face carries it).
**Subsetting landed 2026-11-17:** `subset/cff.v` rebuilds CharStrings
(verbatim keep, endchar drop), format-0 charset with original SIDs, Top DICT
offsets, Private/subrs carried, ids preserved; CFF2/CID refused with reason.
Pinned by `subset_cff_test.v` (reload + outline equality, tampered-mask
break-fix, CFF2 refusal).

**7.10 Variable instancing — landed 2026-11-15.** fvar/gvar at
caller-chosen coordinates (`font/var.v`: normalize, avar warp, tuple
tents, packed runs, IUP, `FT_MulFix` op-for-op — including the exact-.5 IUP
fix found by measuring against the FT 2.13.2 source), behind additive
`set_var_coords` / `instanced_glyph_points` on Face and Font. Pinned by
`varinstance_test.v` beside FreeType and fontTools, plus a dev-time sweep
of every simple glyph × four coords at 142,848/142,848 exact across four
variable faces. HVAR/MVAR/cvar readers landed 2026-11-17 (`font/hvar.v`,
pure lookups over caller blend coords, otRound half-up, pinned by
`font_hvar_test.v` with neutered-delta break-fix). Composites + raster
wiring landed 2026-11-17 (recursive component instancing with phantom-honored
offsets, HVAR-preferred advances, instanced backend behind
`box_only`/`render_into` only at non-default coords; pinned by
`font_varcomp_test.v` with neutered-delta/unwired-raster break-fix).

**7.11 Cache and the rival number — landed 2026-11-15/16.** `shape/cache.v`:
`CacheKey` (font id, gid, size bits, subpixel x/y) with `==` and canonical
`str` (V maps take no struct keys; every field is in the encoding, two
tests fail if size or subpixel drops out), caller-owned `Cache` with
`get_or_rasterize`, `clear`, `len`, hit/miss counts. Font id is the caller's
assignment (nothing on `Font` is stable across calls); one id names one
(file, face). No eviction — the caller clears. Miss 19.1 us, hit 1.2 us
(Amiri `A`, 32 px, first-touch method). Pinned by `cache_test.v` with
break-fix over all four key dimensions. **Second half (rival A/B harness)
landed 2026-11-16**: `tools/rival_bench.v` drives the V half and parses the
`tools/rival_bench.py` rival half (uharfbuzz shaping, Pillow rasterization,
Pango layout, fc-match discovery, fontTools loading — the CI reference
stack, nothing more) into one table with per-op ratios and
a hit-beats-miss refusal as its liveness control. PERF.md carries the
measured table with box, flags, versions and date, re-measured by the
manual `perf-record` workflow (which commits with `[skip ci]`), and the
`perf` CI job gates the ratios on every commit. The matrix covers every
script the corpus carries plus marks, digits and mixed-bidi char types.
The harness degrades the ratchet way: no interpreter or rival import prints
the vtext half with the reason. Recorded on Win11 x64 with `v -cc gcc`:
shape latin-1024 1672x (layout+shape vs hb shape), arabic-1024 552x, raster
miss 0.69x, raster hit 0.03x. Recorded 2026-11-17 with `v -prod -cc gcc`:
shape latin-1024 399x, arabic-1024 57x, raster miss 0.27x, raster hit
0.00x — the tree is -prod-clean as of that run (UCD IN is a real
`LineBreakClass` member now, one subset loop dropped an unused value).
The full -prod test suite additionally needs `-fno-lto` on this gcc,
whose LTO rejects V's heap exports at link time.

**Platform ratchet.** No host-skips on any runner: every OS leg is covered
on its own OS and answers none elsewhere. A skip that prints why stays a
skip; a silent gap is a failure.

## Phase 8: the rival parity sweep

Every other library in the stack, measured against this tree. Landed slices
are done; the rest name their trigger or their assignee.

| Library | Carries | Covered | Not covered |
| --- | --- | --- | --- |
| HarfBuzz core | GSUB/GPOS, features, variations | yes (7.1, 7.2, 7.10) | MATH → 8.7 ✓ |
| hb-subset | subsetting | glyf yes | CFF → 7.9 (refused, see 7.9) |
| FreeType load | sfnt/TTC | yes | WOFF → 8.1 ✓ (WOFF2 triggered) |
| FreeType raster | unhinted/hinted/auto/LCD | unhinted yes; hint → 7.7 | LCD → 8.5 ✓ (bitmap-level; FIR follow-up) |
| FreeType API | embolden/oblique, stroker | bitmap-level 8.5 ✓ (outline-level follow-up) | 8.6 ✓ (landed) |
| FreeType color | COLR/CBDT/sbix/SVG | → 7.7 | — |
| FreeType var | instancing | 7.10 ✓ | — |
| Pango layout | wrap modes, align, ellipsize, tabs | 7.4, 8.4 ✓ | — |
| Pango log attrs | cursor/word/sentence runs | landed 8.2 (`layout/logattr.v`) | — |
| Pango markup | attribute markup | out (app-level, like CSS) | — |
| fontconfig | match/sort/coverage | match + 8.8 ✓ | — |
| ICU text | bidi/normalize/breaks/case | bidi, NFD, graphemes, 8.2 tables + log attrs, 8.3 ✓ | — |
| ICU rest | collation, numbers, dates | out (not the text layer) | — |
| FriBidi | bidi + N0 brackets | yes, incl. bracket table | — |
| Raqm | bidi+shaping glue | yes, own pipeline | — |
| DirectWrite/CoreText | OS shape+layout+raster | providers → 7.8 | engine runs on their fonts ✓ |
| AAT morx, Graphite | Apple/SIL shaping | no corpus font | triggered |
| WOFF2/brotli | web fonts | no | triggered (no decoder in tree) |

**8.1 WOFF1 — landed 2026-11-15.** `font/woff.v` unwraps one container to
plain sfnt (per-table inflate, rebuilt directory, recomputed checksums and
head adjustment); `load_font_bytes` takes it transparently. Pinned against
fontTools on in-tree-converted Amiri: 15 tables, 6710 glyphs, bytes
identical except checkSumAdjustment and `modified`, whole file summing to
0xB1B0AFBA. WOFF2 refused with its reason.

**8.2 Words, sentences, graphemes, log attrs — landed 2026-11-15/16.**
UAX #29 tables as generated data (`tools/gen_wordbreak.v` →
`ucd_wordbreak.v`, `ucd_sentence.v`); committee floors 1944/1944 + 512/512
with break-fix controls that move the score (no WB4: 858; no RI ranges:
1937; no SB8a: 498). UCD 18.0.0 inputs committed with licence-travels
exceptions. The engines then moved to production (`layout/textbreaks.v` —
the floors pin the same functions the library calls) and the slice closed
with the grapheme engine plus the log-attr pass: `layout/graphemes.v`
implements GB1–GB13 including GB9c (InCB Linker Extend* × Consonant, read
off the InCB rows of the committed 1.16 MB DerivedCoreProperties.txt —
there is no InCB file of its own) and GB10/GB11 (emoji tables extended in
the same generator: EBG derived as Emoji minus Presentation, plus
E_Modifier and E_Base); `GraphemeBreakTest.txt` committed with exception
and run as an 853/853 floor with a GB9-neutered break-fix. `layout/logattr.v`
answers PangoLogAttr per boundary (line/mandatory/char/cursor/white/word
start/word end/sentence/deletion span) from those engines plus
`white_space_ranges` (PropList.txt White_Space via `tools/gen_whitespace.v`,
committed with exception); `logattr_test.v` pins word runs, cluster
deletion, whitespace flags, wrap-engine agreement and the double-space
control (naive every-break-starts-a-word fails it).

**8.3 Case mapping — landed 2026-11-15.** Upper/lower/title through
generated tables plus `SpecialCasing.txt` (unconditional over simple, 16
conditional rows verbatim; 1601/1508/1578/16). `shape/case.v` with
`tr`/`az` locale rows (BCP47 primary, `-`/`_` equivalent); Final_Sigma by
neighbouring cased letters; Lithuanian rows carried but not applied.
`case_test.v` round-trips every row plus context triggers.

**8.4 Wrap modes, ellipsize, tabs — landed 2026-11-15.** `WrapMode`
word/char/word_char through both wrap entry points (word is all prior
behavior; char holds marks and CR/LF; word_char splits overlong words);
`ellipsize_line` end/start/middle with a caller-owned U+2026 (no glyph:
line comes back whole; vertical: whole); additive `tab_stops` expanding
after placing, horizontal only. Hyphenation is word-mode only by decision.
Pinned by `ellipsize_wrap_test.v` with fontTools-measured pins and two
break-fix controls (char arm, ellipsis append). C-side spelling landed
2026-11-16: `wrap_mode` (0 word, 1 char, 2 word_char, else word) and
`tab_stops` (pointer plus count, copied) appended to `COptions` after
`align_width` in `capi.v` and to `vtext_options_t` in `vtext.h` — existing
offsets never move, so old callers keep reading their own fields. Pinned
by `coptions_test.v` (mapping, copy semantics, null/empty/negative stops,
engine equivalence for tabs and wrap modes) with a swapped-arm break-fix.
`examples/c-api/smoke.c` pins the same two fields through the real C
boundary the way the vertical flag does: char mode splits "Hello" at 20px
while word mode lets it overflow whole, and a 40/80 stop array puts b at
40.0 — a drifted trailing field would wrap as word mode or ignore the
stops. The pre-existing smoke run (zeroed struct) still passes unchanged,
which is the no-ABI-break half of the proof.

**8.5 Synthetic styles and LCD — landed 2026-11-15 at bitmap level.**
`raster/synth.v`: embolden (max-filter dilation, FT `em/24` default) then
oblique (baseline shear, slant 0.2126 from outline regression), zero-value
identity; `raster/lcd.v`: triple-width `LcdBitmap`, G-center ±⅓ resample,
opt-in `RenderOptions` (default off = byte-identical output). Pinned by
`synth_test.v` against freetype-py: embolden boxes match FT exactly in
height and exactly/+1 in width; oblique heights exact, widths within +2,
sums within 1%. Honest divergence, pinned not hidden: bitmap dilation
roughly doubles the ink (2.0–2.4×) where outline-level FT lifts 1.55–1.75×,
and LCD lacks FT's one-column FIR spill. Follow-ups: outline-level
embolden, true FIR LCD (needs ⅓-px shifts; the API quantizes to quarters).

**8.6 Stroking — landed 2026-11-17 (8.6a outline reader + stroker).**
`Face.glyph_outline` answers every glyph's points, curve flags, contour
ends and header box with composites flattened and transforms applied,
fontTools-pinned (FiraCode A/Aacute/mirror/nested, Amiri rotation+scale,
empty space, CFF and out-of-range refusals). The stroker —
`raster/stroke.v`, `FT_Stroker` parity for joins, caps and miter limits
flattened through the curve path — is pinned by `raster_stroke_test.v`
(miter/bevel/round pins, limit fallbacks, caps, flatten tolerance) with
neutered-join/limit break-fix. Effects are the caller's;
geometry is the library's.

**8.7 MATH — reader landed 2026-11-15.** Opt-in `shape/math.v` pass
(variants, px scaling, disabled-pass answers base/zero) over `font/math.v`
(constants, italics, top accents, extended shapes, variants, assemblies),
pinned against HarfBuzz on STIX Two Math (OFL) and Latin Modern Math (GFL —
its OFL backup carries no MATH table and was rejected). Two spec traps
caught by measuring: 52 records not 54, inline construction records.
Wiring landed 2026-11-16: `Font.has_math` / `Font.math_pass` build the pass
over the font's own table and upm (none when the font carries no usable
MATH); `MathPass.top_accent_with_fallback` answers the HarfBuzz value —
table entry when covered, else half the horizontal advance in design units
(MathTopAccentAttachment's get_value in hb-ot-math-table.hh synthesizes
h_advance / 2 for anything uncovered, which corrects the old "glyph
extents" comment; integer division truncates the way the reference does).
The subset closure keeps every variant and part glyph the kept bases'
constructions name (`close_over_math`, counted as from_math; ids are
preserved so the verbatim-copied table stays valid, and the kept outlines
are what the closure protects). Pinned by math_test.v beside HarfBuzz
(fallback 178/468 STIX, 194/528 LM; covered arms ignore the advance;
disabled is zero; subset keeps 1301/1312/4862/4861 with MATH whole and
variant ink identical) with two runtime break-fix controls (neutered
fallback, neutered closure loop — both fail).

**8.8 Matching, sorting, coverage, instances — landed 2026-11-15.**
`system_fonts_sorted` answers the ranked `FcFontSort` list (path + matched
family per rank); `system_font_covers_char` / `_covers_lang` ask the
pattern's own charset/lang (`FcLangSetHasLang` coverage is `!= 2`; BCP 47
codes are not OT tags). Off Linux all three answer none/false with the
reason. The sorted reader takes no struct-typed access to `FcFontSet` — two
revisions segfaulted on CI inside `FcPatternGetString` through it while
every address idiom probed fine locally, so nfont reads as u32 at offset 0
and the pointer vector at offset 8; CI is green on the offset revision.
fvar instances read beside fontTools on NotoNaskhArabic-Variable (4 named
instances, name-ID join pinned; `is_variable` tells empty apart).

## Phase 9: the remaining scripts

Levels are load-bearing: **full** = suite plus difftest cases, **pinned** =
HarfBuzz-measured test without a difftest case, **smoke** =
loads-shapes-rasterises, **untested** = mechanism should answer but no test
proves it, **absent** = the mechanism does not exist.

| Family | Level | Evidence |
| --- | --- | --- |
| Latin, Cyrillic, Greek | full | kern/calt suites, `latin-*` cases, wave-2 fold pins |
| Arabic, Persian, Urdu | full | joining/GSUB/GPOS suites, `arabic-*`/`persian-*`/`nastaliq-*`, locl pins |
| Hebrew | pinned | `extra_fonts_test`: coverage, niqqud zero-advance, smoke. Placement not HB-pinned, no difftest case |
| CJK Han | smoke + breaks pinned | `extra_fonts_test` (2-glyph line, rasterise); 9.1 pins |
| Thai, Lao, Khmer, Myanmar | pinned (corpus; fusions, reorders, kinzi/blws, pres-group landed) | `seasian_test.v`, HB-measured (Thai 6E/86/2D/6E/0C/5E, Lao, Khmer coeng fusions blwf 0xcc / pstf 0xba, pres-group, Myanmar kinzi order + blws stacks) |
| Syriac, Thaana, NKo | pinned | `longtail_test.v`: Syriac init/medi/rlig + lone-SHIN joining acceptance |
| Hangul (precomposed) | pinned | conjoining-Jamo composition + vertical CJK punctuation (`hangul_test.v`, NotoSansKR) |
| Kana | partial | vertical rules in `vertical_test`; horizontal unpinned |
| Tibetan | absent | stacking needs its own machine |
| Indic (Devanagari, Bengali) | syllable machine, two-script pinned | tables + two faces + machine (wired: hook, assembly, GPOS), HB-pinned both |
| Mongolian/Phags-pa vertical | absent | vertical columns cut and pinned (`vertical_test`); no Mongolian face pinned |
| Simple alphabets (Georgian, Armenian, Ethiopic) | pinned | corpus + HB-exact cmap smoke (`simple_test.v`) |
| Emoji | surveyed (mono) | no color tables in corpus; FiraCode smiley cmap-pinned; color engines → 7.7 |

**9.1 CJK line breaking — landed 2026-11-15 as pins.** ID/CJ/NS/OP/CL were
already complete in the 19,346 tail: 0 fail on 1,753 ID cases and 0 on
5,333 CJK-subset cases in `cjkbreak_test.v`, HB wrap pins on NotoSansSC, a
520-case break-fix control. Hangul conjoining-Jamo composition landed
2026-11-17 (`shape/hangul.v` arithmetic fold L+V(+T) with origin-map carry,
7-line hook after `nfd_mapped`, committed OFL NotoSansKR-Variable, pinned by
`hangul_test.v` beside HarfBuzz with neutered-composition break-fix) and
vertical CJK punctuation landed beside it (column geometry pins).

**9.2 Southeast Asian clusters — corpus landed 2026-11-15, Khmer coeng
fusions and pref reorder landed 2026-11-16/17, Myanmar kinzi landed
2026-11-17.** Wave 3
(NotoSansThai/Lao/Khmer/Myanmar variable faces, HB pins in
`seasian_test.v`). The ccc=0 spacing marks attach (Thai/Lao/Khmer
HB-exact); the Khmer pres-group (`pres/abvs/blws/psts/abvf`, landed
2026-11-17 in spec order pref<blwf<pstf<pres<abvs<blws<psts<abvf behind
`seasian_remainder_test.v` with neutered-group break-fix), Myanmar blws
landed, and Myanmar blwf stays caller-asked (proven: enabling it by default
would fuse KA+DOT and fail the pin). GPOS marks beyond anchors compose
through `apply_mark_chain` (Thai dist chain at U). Tibetan stacks arrive as
their own slice with a stacking font, or the slice says why they cannot. A
dangling Myanmar virama's dotted circle belongs there too.

**9.3 The Indic machine — Bengali generality landed 2026-11-16 (joining hook,
conjunct defaults and assembly + GPOS land in 9.3b–9.3d below).** The Devanagari acceptance above stands; this slice proves the
machine is script-agnostic: committed OFL NotoSansBengali-Variable (730
glyphs, `akhn blwf cjct half pres pstf rphf vatu` under `bng2`), pinned by
`bengali_test.v` beside HarfBuzz with a neutered-reorder break-fix. No new
tables were needed — the same 813 syllabic and 651 positional ranges answer
Bengali, which is the proof. Segmentation, Left-matra reorder and conjunct
spans behave per-script identically (karma/hindi/stra shapes recur with
Bengali codepoints); shaping agrees exactly where no reordering or assembly
is owed (raam gids 0x33/0x3b/0x31, advances 596/266/612; kssa fuses to 0x87
at exactly 859 through the bng2 akhn rule). Slices left: UCD tables (done),
Devanagari (done), Bengali (done); the joining hook landed 2026-11-16
(9.3b), the conjunct defaults landed 2026-11-16 (9.3c); assembly + GPOS marks landed 2026-11-17 (defaults nukt,akhn,rphf,half,blwf,pstf,vatu,cjct,pres,abvs,blws,psts in blwf,pstf,vatu,cjct order; SingleSubst coverage-first fix; mark-filtered chain matching; cluster-ordered stacking; pinned by extended bengali_test.v), with Arabic staying green.

**9.3b The joining hook — landed 2026-11-16.** `layout/layout.v` feeds the
machine into shaping: `indic_visual` reorders each run with
`reorder_indic_mapped` before `shape_arabic`, recomposes the `sub_idx`
cluster map through the permutation (through a copy — in-place would reuse
overwritten slots), and merges each reordered syllable's clusters onto its
base, because the placing pass groups by cluster along bidi visual order
and honest per-character clusters would un-draw the reorder. Both glyphs on
cluster 0 matches HarfBuzz. Pinned by updated `indic_test.v`/`bengali_test.v`
(ki draws matra-first on cluster 0 both scripts; Devanagari pres swaps the
matra for gid 0x221 = HarfBuzz's 545; Bengali ste merges four glyphs onto
cluster 2) with a hook-level neutered break-fix (identity reorder fails the
new pins with the exact pre-hook signature) and machine-level mapped pins
(map [1, 0] for ki, identity elsewhere).

**9.3c Conjunct defaults, tag fallback, dist — landed 2026-11-16.** Three
fixes behind one behaviour change: the engine applies the in-place Indic
features by default (nukt, akhn, half, pres, abvs, blws, psts, cjct — named
asking repeats them by construction, since double application is not
idempotent). Devanagari agrees with HarfBuzz where no reordering is owed
(kssa fuses to 90, ki draws the 545 pres variant, hindi's NDA fuses to 0xf5
with the dist kern folding to exactly 309, STA fuses to 256) and Bengali
kssa fuses to 0x87 at exactly 859. What the slice found on the way: (1) a
coverage-index bug in parse_ligature_subst compared the set index against
the range count, keeping 8 of lookup 114's 42 sets and silently dropping
every range-covered ligature past the eighth range — every script's
fusions, not just Indic; (2) the script resolver lowercased UCD names, so
Bengali runs never resolved a GSUB script (bng2-only face): v1/v2 sibling
tags now fall back in both resolvers, deva-first where deva exists;
(3) Indic pair adjustments live under GPOS dist, which the kern path now
reads beside kern (only six corpus faces carry dist; every other script
reads what it always did). Open: reph movement (rphf/pref), pstf/blwf/vatu,
the Bengali blwf/pstf/cjct assembly chain with mark positioning, GPOS
marks, post-base cluster convention (UU on 5 vs HarfBuzz 4).

**9.3d Repha movement — landed 2026-11-16.** The machine moves a
syllable-initial RA+halant to the syllable end (after matras), merges the
touched syllable onto its base, and the default rphf lookup fuses it there:
karma draws [KA, MA, reph] in both scripts, rki draws [matra, KA, reph] in
Devanagari (0x311) and [matra, reph, KA, ZWSP] in Bengali, rkma draws [KA,
AA, reph] in Devanagari — every gid, advance, cluster and offset HarfBuzz
reports. The one divergence is Bengali rkma with a post-base matra:
HarfBuzz puts the reph before the AA ([KA, reph, AA]) while this engine
appends it after, pinned as-is. Pref, pstf/blwf/vatu, the Bengali
conjunct assembly chain and GPOS marks land in the assembly + GPOS slice below.

**9.3e Zero-class marks attach — landed 2026-11-16 (first cut).** The
`attach_marks` skip for invisible format controls gated on a zero combining
class, which ate every transparent zero-class Indic mark: the Bengali ku
matra U+09C1 vanished, Devanagari candrabindu/anusvara vanished, namaste
lost its E matra, and Thai/Lao/Khmer lost their vowels. The gate is now the
Format general category (new `ucd/ucd_format.v`, generated by
`tools/gen_format.v` from UnicodeData.txt): Cf controls are still dropped,
zero-class Mn/Me marks now attach and draw. Bengali ku is HB-exact in gids,
advances and the -393 anchor, Devanagari candrabindu/anusvara including
offsets, namaste five HB gids with HB advances, Thai in gids, advances and
offsets — all under honest per-input mark clusters where HarfBuzz merges
onto the base (the recorded post-base convention: UU, namaste tail, Thai,
Lao, Khmer, Amiri SUKUN). Three sub-fixes fell out on the way: (1) GPOS lookups
gated by USE_MARK_FILTERING_SET are skipped unless the mark is in the
GDEF set (the flag was ignored, stacking Thai SARA II onto MAI HAN AKAT);
the GDEF sets were already parsed, only the lookup flags and the gate were
missing. (2) A mark stacks only on a mark of its own syllable — same
nearest letter base — which is what makes (1) unnecessary for Thai and
keeps the Arabic shadda+fatha stack. (3) The Lao/NKo/Yi OT tags pad with a
space ('lao '), which the resolver never produced, so Lao runs drew
unshaped; the tags map now and Lao SARA II lands HB-exact at -582. The one
casualty is U+1E94B, a spacing mark riding as a mark with no advance,
recorded in-code. The arabic-marks difftest entry for the Amiri SUKUN
improves from (674, 201) to (116, 0) vs HB (68, 0): the cross-syllable
stack is gone; the residual anchor/chain gap is GPOS open work. Still open
after the first cut: pref, pstf/blwf/vatu, the Bengali conjunct assembly
chain, ke's pres-variant divergence ([0x42] vs HB [0x18e]), Khmer coeng
fusion with its cluster merge and the chaining override on SRA II (+615
first-match vs HB -32), GPOS marks beyond anchors.

**9.3e Conjunct assembly — landed 2026-11-16 (second cut).** Three engine
fixes compose the Bengali conjunct chain. (1) A nested chaining record
reads the run from its own position onward, not a single glyph: `one_at`
starved every multi-glyph nested match, so cjct's ligature rules never
fired and kta/nta/sta drew unfused. The tail is spec-correct for singles
too (they only read their own glyph), and the half lookups ride the same
path. (2) cjct runs before the matra-positioning group, not after it as
the specification lists: Noto's pres rules split cjct products (kta 0xbe
to [0xbe, 0x14a] through lookup 66), and HarfBuzz produces the split, so
the engine follows the font. (3) A run-initial pre-base matra takes the
initial joining form: the font files ke's E allograph under `init`
(lookup 57) and HarfBuzz applies it there and nowhere else (nomoste's
run-medial E draws the cmap glyph). Only the run-initial matra changes;
every other form assignment is untouched, so Arabic/Syriac/NKo masking is
exactly as it was.
kta, nta, sta, ndda, ke, hindi and nomoste are now HB-exact in gids,
advances, offsets and clusters.

**9.3e Rakar, dist kern and the v2 tag — landed 2026-11-16 (third cut).**
kri assembles through blwf (now defaulted between cjct and pres, feeding
pres the same way cjct products do) and widens its base through dist:
kta-style chaining gave [0x9a, 0x15a, 0x140, 0x40] at hmtx advances while
HarfBuzz reports 862 for the base. Three engine fixes close the 200-unit
gap. (1) The sibling script order is v2-first: Noto files dist lookups 0
and 1 under `beng` but the chaining contextual kern only under `bng2`,
so a v1-first order never saw it — HarfBuzz resolves the v2 model. (2)
SinglePos format 2 with valueCount equal to the coverage size reads
per-glyph values in coverage order (Noto writes the dist singles that
way); valueCount 1 keeps the single value plus the old exception path,
anything else stays refused. (3) A chaining single that carries only an
advance adjusts the pen without moving the glyph: the record application
reads those advances beside placements, the way the single-position
reader already did. A base on at least one side of a kerned pair now
takes part (two marks still have nowhere to go). stra fuses fully too
(0xfd, 0x108, 0x149, 0x11a). kri and stra are now HB-exact in gids,
advances and offsets; their tails keep honest per-input clusters where
HarfBuzz merges onto the base. Open: pref, pstf/vatu, the mark-cluster
merge, the Khmer pres/abvs/blws/psts/abvf group, GPOS marks beyond anchors.

**9.3e Fallout repairs — landed 2026-11-16 (fourth cut).** The slice's own
fallout, each pinned. (1) The advance-only chaining single over-applied:
Andalus carries placement *and* advance in one single (-120/-120), and the
context kern answered the sum. The fallback now skips the rule that placed,
so Andalus keeps the -120 the pin holds while kri's advance-only record
still widens the base. (2) Segoe UI's lookup 18 — an extension-wrapped
SinglePos format 2 with fifteen YPlacement values for fifteen glyphs —
reads now, so the inspect count moves 44→45 singles with no trailing 9.
The unread-extension branch keeps a synthetic-bytes witness (no corpus font
exercises it anymore), and the per-glyph format-2 shape gains one too.
Difftest unmoved, 0 new and 0 stale.

**9.2-engine Khmer coeng fusions — landed 2026-11-16.** Two engine fixes
draw the hello word the way HarfBuzz does. (1) Khmer runs `blwf` and
`pstf` by default under their own script gate: both are HarfBuzz
default-on (toggling either off unfolds its consonants) and both are
disjoint plain ligatures, so no order is owed between them. COENG+TA
fuses to the 0xcc subscript and COENG+KHO to the 0xba post-base form.
(2) A fusion is a new glyph, so the font classifies it: `ligatables`
used to inherit the inputs' mark flag, which kept every coeng fusion a
mark with no advance, but the pstf and pref products are GDEF bases
with a real advance (0xba at 294 units, 0xdc at 287) that HarfBuzz
advances as bases. Only the ligature path changes; singles, multiples
and alternates keep the old rule, so Arabic ccmp compositions are
untouched. The hello word is now HB-exact in gids, advances and
offsets (fused mark at +14/-26, SRA II at -32/-29); the pstf word is
HB-exact with honest per-input clusters where HarfBuzz merges.

**9.2-engine Khmer pref reorder — landed 2026-11-17.** Two halves draw
SA + COENG + RO the way HarfBuzz does. (1) The reorder machine preposes
each adjacent COENG+RO pair to its syllable front, the way a reph moves
for the Indic scripts: HarfBuzz reorders with or without the fusion
(`-pref` unfolds the pair but leaves it ahead of the base), so the move
is the shaper's work, not the font's. The codepoints gate the rule —
no Devanagari or Bengali syllable contains U+17D2 or U+179A — and the
layout pass merges the reordered syllable onto the base the way it does
for a moved matra. (2) `pref` joins the Khmer defaults ahead of `blwf`,
claiming the preposed pair through lookup 12 before the chains see it.
The pair, the pair-plus-vowel, the two-pair cluster and the
syllable-tail words are all HB-exact in gids, order, advances, offsets
and clusters. Open: the Khmer pres/abvs/blws/psts/abvf group, the
mark-cluster merge, GPOS marks beyond anchors.

**9.2-engine Myanmar kinzi — landed 2026-11-17.** Two halves draw
mingala the way HarfBuzz does. (1) The reorder machine preposes the
consonant after a [C, ASAT, VIRAMA] trio ahead of it — C is NGA or RA
(KA with the same tail draws in place, and a vowel after the virama
draws after it) — the way the Khmer pair preposes, and the layout pass
merges the reordered syllable onto the base. HarfBuzz reorders with
GSUB off, so the move is the shaper's work. (2) `abvs` joins the
Myanmar defaults under its own gate with the `mym2` sibling the v2
fonts file under (v2-first, the Bengali precedent), fusing the reordered
trio into the kinzi mark through lookup 52. There is no stack
ligature: LA's cmap glyph was the stack all along. Mingala is HB-exact
in gids, order, advances and offsets with honest per-input clusters
where HarfBuzz merges AA. Open: blwf caller-asked until a medial-dot
word proves its order, the dangling-virama dotted circle, the
mark-cluster merge, GPOS marks beyond anchors.

**9.2-engine Myanmar blws stacks — landed 2026-11-17.** The second
half of the Myanmar defaults: `blws` subjoins a VIRAMA-led stack
behind its base (DA/VIRAMA/DHA to DA plus dha.sub), proven default-on
the same way — `-blws` unfolds it while -abvs, -blwf and -ccmp change
nothing. It runs after `abvs` because HarfBuzz orders it there: with
abvs off, blws subjoins the surviving virama, and with abvs on the
kinzi consumes it first — swapping the two breaks mingala, which is
the order's break-fix. The stack word is HB-exact in gids, order,
advance and offsets with honest per-input clusters. blwf stays
caller-asked: its medial-dot rules fire on no corpus word.

**9.4 The long tail — corpus landed 2026-11-15.** Wave 4 (Syriac, Thaana,
NKo; `longtail_test.v`, break-fix on the SHIN pin). Two wave gaps closed in
9.3e: Thaana fili attach beside HarfBuzz (gids, advances, GPOS offsets
exact), and the `ot_script_tag` space-pad fold (`nko `/`lao `/`yi `) lands
NKo joining beside HarfBuzz by default. Simple alphabets landed 2026-11-16:
Georgian, Armenian and Ethiopic variable faces (554/436/925 glyphs, upm
1000, well under the wave ceiling) with hello-word smoke beside HarfBuzz
(`simple_test.v`: gamarjoba/barev/selam exact gid and advance agreement,
rasterize smoke, off-by-one break-fix). These scripts need no machinery —
cmap glyph plus hmtx advance, in order — and the pins prove it. The emoji
survey closes 9.4 with them: no committed face carries a colour table
(COLR/CPAL/CBDT/CBLC/sbix/SVG scanned on all four survey faces, not
assumed), and the monochrome smiley U+263A FiraCode covers shapes from its
cmap beside HarfBuzz (gid 0x625, advance 600) and rasterizes. Colour
engines stay 7.7.

Wave rule for the whole phase: every new script arrives as a committed OFL
font plus HarfBuzz-measured pins. A shaping-affecting script also extends
the difftest corpus, pango legs verified on CI.

## Phase 10: standalone vlib replacement gaps

vtext stays standalone: no `vlib` types, no `gg`/`canvas`/`sfons`/`os.font`/`x/ttf`
imports, no FONS/C types. vtext provides the generic gaps vlib needs to
replace fontstash / stb_truetype / freetype behind its own split flags;
the adaptation (`-d use_vtext_gg`, `-d use_vtext_canvas`, `vlib/vtext/...`)
lives in `vlib`, not here.

The atlas boundary does not move: Phase 1 settled against a hidden atlas
and for a caller-owned cache (`shape/cache.v`, `shape/CacheKey`), and that
holds here. The caller keeps owning its atlas texture, dirty-rect upload
and strike budgets; vtext answers box-for-gid plus fill-this-buffer
(`box_only` / `render_into` on `font.Face`, `raster.GlyphBitmap`) plus the
generic helpers below. No new thirdparty.

**10.1 generic measure / iterate — landed 2026-11-17.** `layout/iterator.v`:
`advance_quads` (visual-order quads from advances with atlas uv and
top/bottom origin) plus `line_ink_box` (the generic line-bounds/vert-metrics
answer). No FONS types, no state stack, no atlas. Pinned by
`layout_iterator_test.v` (empty line, order/origin, ink box).

**10.2 generic rect packing — landed 2026-11-17.** `raster/pack.v`: skyline
`PackAtlas` with bottom-left `insert`/`reset`/`rect_fits`, no hidden
allocation beyond nodes, no stb/fontstash/freetype dependency. This is the
packing half of the atlas vlib keeps owning. Pinned by
`raster_pack_test.v` (side-by-side, full-refuses, reset-reuses).

**10.3 generic coverage helpers — landed 2026-11-17.** `raster/quantize.v`:
`quantize_mono/gray2/gray4`, `gamma_lut`/`apply_lut`, `blur_bitmap`
(3x3 box, radius 0 identity). Generic form of the fontstash blur and the
canvas mono/gray2/4 + gamma/contrast preblend, with no backend types.
Pinned by `raster_quantize_test.v` (threshold, gray4 top, identity LUT/blur,
single-pixel spread) with a threshold-neutered break-fix.

**10.4 canvas CPU helpers — landed 2026-11-17 as generic coverage only.**
Mono/gray2/4 quantize, gamma/contrast LUT and blur land here (10.3);
hinting rides 7.7, LCD FIR rides the 8.5 follow-up, stroking rides 8.6,
color rides 7.7. No `Typeface`/`ScalerRec`/`Strike` types in vtext; those
stay in `vlib` behind its own flag.

**10.5 generic discovery — landed 2026-11-17.** `providers/discovery.v`:
pure `discovery_order`/`pick_first`, `variant_path` bold/italic/mono
heuristics, `is_power_of_two`. No ENV reads, no filesystem walks, no
`fc-match` exec, no Android XML in this library; the caller injects
candidates and readability. Legacy `kern` stays refused by design (GPOS
only). Core Text / DirectWrite full providers remain 7.8 per-OS work.
Pinned by `providers_discovery_test.v` (order, skip-unreadable, variants,
power-of-two).

Each 10.x slice carries its own baseline (new `*_test.v` plus full suite
green), one commit per slice, break-fix that moves the score, and no
change to existing behavior. Triggered items from Phase 7–9 (bytecode
interpreter, CFF2, WOFF2/brotli, AAT `morx`, Graphite, Tibetan stacking)
stay triggered; 10.x never pulls them in early. The `vlib` adaptation
(flags, `FT`, `ScalerRec`, `Strike`, `os.font` order, `sfons`, `x/ttf`
callers) stays in `vlib`, not here.

## Phase 11: modular, extendable, fast — landed 2026-11-18.

The engine is done; this phase is about the shape of the tree: adding a
script must not mean editing three files, and the slowest family must have
numbers before anyone tunes it. Slices land in M1 → E1 → E2 → F1 → F2 → F3
order, with M2/M3 wherever the tree is quiet. Every slice keeps the suite,
difftest 0/0 and the perf gate green; perf slices additionally carry
same-harness before/after numbers. C-API rule from 8.4 holds throughout
(append-only; offsets never move).

**Modular.** M1 is an import-direction ratchet test: allowed imports per
module (`layout` may use `shape`/`font`, `shape` never `layout`, nothing
imports `tools/`), a deliberate violation fails. M1 landed 2026-11-17 as
`modularity_test.v`, pinning the exact vtext-internal set per module
(stdlib stays free; test files and the tools/ and examples/ programs are
out of scope), with a neutered-table break-fix proving it discriminates.
M2/M3 split the monoliths
by lookup kind and pass (`font/gpos.v`, `font/gsub.v`, `layout/layout.v`,
`shape/font.v`), no behavior change, every resulting file under 60 KB. M2
landed 2026-11-18 splitting the font monoliths by lookup kind
(`gpos_pair`/`gpos_single`/`gpos_mark`/`gpos_cursive`/`gpos_context`,
`gsub_single`/`gsub_ligature`/`gsub_context`); M3 landed the same day
splitting the layout monolith by pass (`layout/kern.v`, `layout/marks.v`,
`layout/place.v` beside the slimmed `layout.v`). No
public API renames: pure file moves, `vtext.h` untouched.

**Extendable.** E1 is a `ScriptShaper` interface with a registry (Khmer,
Myanmar, Indic migrated one commit per script): feature order, reorder and
split become registry calls and the `is_khmer`/`is_myanmar` branches
delete. E1 landed 2026-11-17 as `shape/shaper.v`: the interface plus a
registry resolving scripts to shapers and content to the claiming
shaper, with Khmer moved across (defaults, COENG+RO prepose, split
vowels) and its `is_khmer` branches deleted. Myanmar followed one
commit later with the same three moves plus a fourth the interface grew
for it: asked `blwf` runs before `ccmp` through `pre_ccmp_features`, and
the old `myanmar_pre_blwf` carve-out, the defaults and the gate deleted
with it. Reorder and split dispatch on content because
both run before the run script resolves; substitution dispatches on the
script, which it has.
E2 makes feature order data, including the before-`ccmp` slot the Myanmar
carve-out needs: E2 landed 2026-11-18 as the `FeaturePlan` value
(`pre_ccmp` beside the defaults in one value, fetched once per run
through `feature_plan_for`), with `feature_order_test.v` pinning the
slot. Indic migrated to the registry the same day, closing the E1
plan: the Indic defaults, reorder tail and run split move across and
the old per-script branches delete with them. E3 writes the
script-onboarding checklist down (OFL face +
licence, HB pins, difftest cases, order proof): E3 landed 2026-11-18
as `SCRIPT_ONBOARDING.md`, the seven-item list every future script
follows, each item naming the Khmer/Myanmar/Indic precedent that
proves it. No plugin DLLs or FFI:
registration is compile-time, `-prod`+LTO builds intact.

**Fast.** F1 is an opt-in per-stage shaping profiler (segment, reorder,
GSUB, GPOS, place) on the Thai/Khmer/Myanmar bench rows, silent by default.
F2 fixes what F1 finds; the candidate is a run-level shaping memo whose key
must include features, script override and variation coords, with a
break-fix over an omitted input. F3 removes per-glyph heap churn on the hot
path (reused buffers in the run loops). F1 landed 2026-11-18 as the opt-in
per-stage profiler above (`layout/profiler.v`, `layout_paragraph_profiled`,
`profiler_test.v` pinning profiled==plain); F2 and its tails landed the
same day hoisting what it found (Indic table decodes out of per-syllable
paths, O(1) format-4 reverse lookup by segment kind, stacked cluster
search out of the per-mark loop). No SIMD (endian-clean, every
platform), no hidden atlas or global cache (Phase 1 settled: the cache is
the caller's), ratios vs HarfBuzz are not a target — absolute paragraph
times are, measured on a quiet box (foreign V builds tripled suite time on
2026-11-17, which is recorded, not tuned around).

**Fast F3 — landed 2026-11-18.** GPOS lookup-list hoisting: `kern_offset_in`
and `vkern_offset_in` answer from an explicit lookup list, `Gpos.single_lookups`
resolves the singles list the one-glyph `single_adjustment` always resolved,
and the layout pass resolves each list once per font per run instead of per
pair, per glyph and per mark. Two memos because the keys differ: a
`GposPairLookupsMemo` for kern, vertical kern and mark attachments keyed on
font, script and language, and a `GposSinglesLookupsMemo` for singles keyed
additionally on the asked extras and direction. `shaped_mark_offset` takes
the resolved marks list; the public one-shot forms (`kern_offset`,
`single_adjustment`, `mark_offset_in`) delegate and keep working. No
behavior change by construction: the resolution code moved, it was not
rewritten, and every consumer reads the list the per-call path resolved.

## Phase 12: rival parity — open, planned 2026-11-19.

The perf table compares vtext's full pipeline against rivals that do less
per row (layout+shape vs HarfBuzz shape-only), and the ratios show it:
hundreds to one on the shape rows. This phase closes that gap slice by
slice, each with same-harness before/after numbers attributed by the F1
stage profiler, and the suite, difftest 0/0 and the perf gate green on
every commit. Ratios, not absolutes, are the finding — a loaded box lies
about absolutes — and getting faster never fails the gate.

**Phase 12 G1 — landed 2026-11-19.** GSUB lookup pre-filter
(`font/gsub_prefilter.v`): `substitute_forms` builds the run's glyph set
once per lookup and skips lookups whose first-position coverage names
nothing in it. Sound because every apply path coverage-gates position
zero first and the set is rebuilt from the current run for every lookup.
Latin GSUB 9.97ms to 0.49ms, arabic 4.99ms to 0.91ms.

**Phase 12 G2 — landed 2026-11-19.** The mark pass is skipped outright on
markless lines, and the F2c stacked-cluster precompute binary-searches a
once-sorted base-cluster array instead of walking the map per glyph. Same
maximum over an unchanged set. Latin GPOS 1.18ms to 0.18ms.

**Phase 12 G3 — landed 2026-11-19.** ASCII fast path for NFD mapping:
a single pre-scan of plain comparisons takes ASCII text straight to the
identity mapping, replacing two Unicode table lookups per character.
Sound because ASCII characters are starters with no decomposition.

**Phase 12 G4 — landed 2026-11-19.** The decoded Indic syllabic and
positional tables live in `shape.Context` beside the other caller-owned
tables, decoded once at construction; the reorder path resolves each run
against them instead of re-parsing the generator text per run per
sequence. Same tables, same code, caller-decoded.

**Phase 12 G5 — landed 2026-11-19.** ASCII fast path for bidi resolution
(`shape/bidi.v`): a non-RTL paragraph over printable ASCII plus tab skips the
UAX9 walk. L stays at level 0, W7 folds every EN into L at sos (ASCII names no
R or AL), N0/N1/N2 over all-even surroundings leave every neutral at level 0,
so L2 and X10 are both the identity and X9 removes nothing. An RTL base or any
non-ASCII codepoint keeps the slow path. `resolve_paragraph` on 4096 ASCII
characters went 3.2–3.9 ms to 0.17–0.27 ms (14–19x, `tools/bench_bidi.v`,
interleaved best-of); neutering the gate collapses the ratio to 1.04x. Pinned
by `bidi_test.v` (the fast path equals the slow path on a class-identical
sequence, including the `sequences` fields the conformance file never checks,
plus the `.auto`/`.rtl` split), with the 94k-line UAX9 file green, difftest
0 new / 0 stale and the full suite green (one parallel-run tcc `dwrite.h`
header fallback passed on serial repro).

**Phase 12 G6 — landed 2026-11-19.** Dense arrays in `place_glyphs`
(`layout/place.v`): the two hash maps keyed by cluster and origin become
indexable arrays when every key is a small non-negative int, the normal case
since both index the caller's text. Negative or far-out keys keep the map
walk; merged clusters and repeated origins behave the same. `place_glyphs` on
1024 glyphs went 1.66 ms to 0.87 ms (1.7–2.2x, `tools/bench_place.v`,
interleaved best-of with the map path forced by one negative cluster). Pinned
by `layout_test.v` (dense equals the map walk across plain, merged, RTL and
invisible-character inputs) with a neutered-dense break-fix; full suite and
difftest 0/0 green on CI, where the pinned runners do not carry the 39–44
foreign V builds that made the local compiler run out of memory.

**Phase 12 G7 — landed 2026-11-20.** Per-line measurement memo
(`layout/place.v`): `measure_line` read each font's metrics and called
`box_only` on every glyph, although a line is measured at one size and a
paragraph draws a few dozen distinct gids. A memo local to the call keys boxes
and metrics by (font, gid), so 1024 glyphs make about 47 box reads; the glyph's
own `y` is still applied per glyph and nothing is cached across lines, so a
caller changing size or variation coordinates cannot read a stale box. The
memo keeps only the three integer fields it needs rather than a
`raster.GlyphBitmap`, because the module boundary forbids a `layout` -> `raster`
import. `measure_line` on 1024 glyphs went 2.94 ms to 0.27 ms (10.7x,
`tools/bench_measure.v`, interleaved best-of). Pinned by `layout_test.v` against
an unmemoized walk over repeated gids with varied mark offsets, with a
collapsed-key break-fix; full suite and difftest 0/0 green on CI.

**Phase 12 G8 — landed 2026-11-20.** ASCII fast path for joining
(`shape/joining.v`): `shape_arabic` ran a two-pass join computation and several
UCD lookups per character even when the run was all printable ASCII or tab,
where no codepoint takes a shape, names a presentation form, is a mark or is a
joining control. The fast path emits one isolated, unmarked ShapedGlyph per
character, with script Latn for letters and Zyyy for everything else; a single
non-ASCII codepoint keeps the full walk. `shape_arabic` on 1024 ASCII characters
went 1.4 ms to 0.26 ms (4.7–5.7x, `tools/bench_join.v`, interleaved best-of with
the slow walk forced by U+00E9). Pinned by `joining_test.v` (fast path equals the
full walk across all 95 printable ASCII characters, with a corrupted-form
break-fix); gate-neuter collapses the ratio to 0.98x. Full suite and difftest
0/0 green on CI.

**Phase 12 G9 — landed 2026-11-20.** Per-lookup coverage hit set in GSUB
(`font/gsub.v`, `font/gsub_prefilter.v`): `substitute_forms` already built a
set of run gids per lookup to decide whether the lookup could match at all,
but the walk still entered `apply_at` at every position and tried every rule.
A second set marks the run gids that this lookup's first-position coverage can
name, so a position that cannot start any rule is stepped over without the
dispatch. It is rebuilt after each edit, since a substitution can introduce a
gid the original run did not hold. FiraCode's `calt` carries 103 chain lookups
(~500 rules), which is where this shows. A same-session toggle on
`tools/bench_gsub.v` measured 16.8 ms with the filter disabled against
7.3–8.8 ms enabled (~1.9–2.3x on the GSUB call). GSUB, class, calt/liga and
joining suites green locally; full suite and difftest 0/0 green on CI.

**Phase 12 G10 — landed 2026-11-20.** Read the precomputed mark base cluster
(`layout/marks.v`): F2c built `cand_base` once per glyph for the stacked-candidate
question, but each mark still walked the whole `bases` hash map to find its own
base — about 300 marks times 700 clusters on a long marked line. `cand_base[i]`
is the same answer from the same keys with the same `<=` predicate, and the loop
never writes a cluster, so the snapshot stays valid. An interleaved
single-process A/B (`tools/bench_markbase.v`) measured 836 us to 16 us on the
search itself (53x, with per-mark equality asserted); layout, gpos_mkm and
commonbase suites green locally, full suite and difftest 0/0 green on CI.

**Phase 12 G11 — landed 2026-11-20.** Query each first-coverage gid once
(`font/gsub_prefilter.v`): `first_coverage_hits` recorded only positive hits, so
an uncovered gid's negative answer was re-tested on every occurrence — about 75
uncovered ASCII gids times ~11 repeats per lookup, across ~80 active `calt`
lookups. A companion `tested` set now asks `gid_in_first_coverage` once per
distinct gid, and `coverage_has` uses the binary-search `coverage_index` that the
apply paths already rely on (ranges are sorted and disjoint by the format).
Both arms compute the same `hits` set from a pure function, so no position is
skipped or reordered. A true interleaved single-process A/B (old and new arms in
one binary, alternating, warmup + best-of, so host load cancels) measured
9.4 ms to 6.7 ms on the 1024-glyph Latin FiraCode GSUB call — 1.40x, reproduced
at 1.42x on a second run. gsub, gsub_class, calt_liga, joining_gsub and
feature_order suites green locally; full suite and difftest 0/0 green on CI.

**Phase 12 G12 — landed 2026-11-20.** Per-layout `shaped_glyphs` memo
(`layout/glyph_memo.v`, `layout/layout.v`): `FontSet.shaped_glyphs` is a pure
cmap/UCD read, and a line repeats the same letters and forms many times. One
memo per layout call (so it cannot outlive the FontSet, em size or Context that
gave it) caches the common single-codepoint, selector-free shaped glyph in 64
direct-mapped slots keyed by form cp, base cp, form, mark flag and script —
everything the function reads. Multi-codepoint forms, lam-alef and variation
selectors fall through uncached. A hit returns the stored slice directly: the
only caller iterates by value, sets `.cluster` on the copy and appends that
copy, so the backing array is never written. The first attempt used a linear
key scan with a clone per hit and measured 1.00x — the scan and allocation cost
more than the lookups saved. Direct-mapping fixed that: an interleaved
single-process A/B on a 768-glyph Arabic line measured 942 us to 826 us (1.14x)
and 968 us to 919 us (1.05x) on the `.segment` stage, with the full `Line`
(gid, advance, x, y, cluster, is_mark, form, base_gid, width) asserted identical
before any numbers were taken. joining, commonbase, gpos_mkm, indic, layout and
profiler suites green locally; full suite and difftest 0/0 green on CI.

**Rejected 2026-11-20:** folding the per-lookup `lookup_touches_run` gate into
`first_coverage_hits`. The idea was to have the coverage walk also return
`any_hit`, dropping the 8 KB memset, the mark loop and the gate check per
lookup. An interleaved single-process A/B (identical substituted runs asserted
before timing) showed 1.02–1.10x on a hit-heavy Latin `calt` run but **0.27–0.36x
on a miss-heavy run** — the new path was 2.8–3.7x slower. The cause is real: on
a miss, `first_coverage_hits` does one binary search per distinct gid, while
`lookup_touches_run.touches` answers the same question with a handful of bitset
span checks. The change was reverted; do not retry it without fixing that
asymmetry first.

**Phase 12 G13 — landed 2026-11-20.** Dense per-run `JoiningType` table
(`shape/joining.v`): `shape_arabic` asked `joining_type_of` roughly four times
per character, each a binary search over the UCD range table. It now asks once
per character and threads a dense `[]ucd.JoiningType` through `compute_joins`,
`connect`, `next_letter` and `attach_marks`, so the remaining questions are
array reads. The value is a pure lookup, so the answers are exact — a full
`ShapedRun` equality gate ran before either arm was timed. An isolated
microbench of the lookup mechanism alone measured 118x, but the one-time
precompute and the rest of `shape_arabic` absorb most of it: the interleaved
single-process A/B on a 768-glyph Arabic line measured 1.31 ms to 1.25 ms
(1.05x) and 1.25 ms to 1.13 ms (1.11x) on `shape_arabic` itself. The four
helpers now take the dense table as a parameter (all callers are in-file).
joining, joining_gsub, bengali, indic, seasian and layout suites green locally;
full suite and difftest 0/0 green on CI.

**Phase 12 G14 — landed 2026-11-20.** Drop the dead second pass in
`glyph_index_for` (`font/cmap.v`): the function scanned every cmap subtable
twice. Pass 1 returned the first non-zero opinion; if it found none, pass 2
returned the first non-none opinion, which can only be an explicit zero
(.notdef) — exactly what the trailing `return 0` already gives. `lookup_glyph`
is a pure read of immutable tables, so the two passes cannot disagree; this is
dead-code elimination, not a heuristic. An interleaved single-process A/B
(two-pass vs one-pass in one binary, all 2048 mixed hit/miss cps asserted equal
across both fonts before timing) measured 1.67–1.78x on Amiri and 1.90–1.91x on
FiraCode for the lookup itself. cmap, cmap_reverse, cmap_vs, font and glyph
suites green locally; full suite and difftest 0/0 green on CI.

**Phase 12 G15 — landed 2026-11-20.** Dense arrays for vertical placement
(`layout/place.v`): `place_glyphs_vertical` still used two hash maps
(`by_cluster`, `drawn`) and asked `glyph_advance` twice per glyph, while the
horizontal path had moved to dense arrays in G6. It now has the same guarded
dense path — the same `max_idx` bound and map fallback for negative or far-out
clusters — with one advance per glyph reused for centering. Merged clusters
still hold a list and a repeated origin is still drawn once. An interleaved
single-process A/B on a 1024-glyph vertical CJK line (full `Line` equality
asserted across every field before timing) measured 151 us to 73 us (2.09x) and
151 us to 77 us (1.95x) on the `.place` stage. layout, vertical, bidi, indic
and cjkbreak suites green locally; full suite and difftest 0/0 green on CI.

**Rejected 2026-11-20:** indexing `ChainMemo.apps` by `at` so
`mark_chain_offset` need not scan every application per mark. The interleaved
A/B (full `Line` equality asserted first) measured 1.00x on Thai and Khmer
after several runs on a quiet host — the earlier 1.02–1.28x readings were host
noise, and the single-sequence Latin control swung 0.72x to 1.17x. The map and
the extra per-mark lookup bought nothing measurable; reverted.

**Phase 12 G16 — landed 2026-11-20.** Build the bracket table once per
paragraph (`shape/bidi.v`, `shape/bidi_rules.v`): `resolve_paragraph` calls
`apply_n0` once per isolating run sequence, and `apply_n0` rebuilt the ~150-entry
table each time via `split_into_lines` / `split(' ')` / `hex_value` — roughly 600
small string allocations per sequence. The decoded table is immutable, so it is
now built once before the sequence loop and passed down. An interleaved
single-process A/B (full `BidiResult` equality asserted before timing) on a
three-sequence mixed RTL/LTR/digits paragraph measured 2.55–2.68x on
`resolve_paragraph`; a single-sequence control measured 0.96–0.99x, confirming
no regression where there is nothing to hoist. bidi, layout, linebreak,
script_lang and profiler suites green locally; full suite and difftest 0/0
green on CI.

**Phase 12 G17 — landed 2026-11-20.** ASCII fast path for grapheme clustering
(`layout/graphemes.v`): `grapheme_breaks` spent about four UCD binary searches
per character on all-ASCII input, and none of GB9/GB9a/GB9b/GB9c/GB10/GB11/GB12
can fire there — ASCII has no Extend, ZWJ, SpacingMark, Hangul or Regional
Indicator. A strict `cp <= 0x7f` gate now answers true at every boundary except
CRLF (GB3, the only no-break pair), and `skip_gb9` is inert. Non-ASCII falls
through to the unchanged full walk. An interleaved single-process A/B on 4147
ASCII codepoints with real CRLFs (full output equality asserted for both
`GraphemeOpts` values and for a non-ASCII fallback case) measured 26.4x, 29.0x
and 27.8x on the function itself. grapheme, logattr, wordbreak, linebreak and
layout suites green locally; full suite and difftest 0/0 green on CI.

**Phase 12 G18 — landed 2026-11-20.** Separable max filter for
`embolden_bitmap` (`raster/synth.v`). The dilation window is the asymmetric
rectangle `[x-2r, x] x [y-2r, y]`, and max is associative and idempotent, so a
horizontal max over each source row followed by a vertical max over each column
is byte-identical at `2(2r+1)` neighbour visits instead of `(2r+1)^2`;
out-of-range neighbours stay skipped. An interleaved single-process A/B over 15
real glyph bitmaps x 5 strengths (every coverage byte and box field asserted
equal before timing, plus empty and coverageless edge cases) measured 3.17x,
3.05x and 2.52x on the embolden pass. synth, raster_color and stbtt suites green
locally; full suite and difftest 0/0 green on CI.

**Phase 12 G19 — landed 2026-11-20.** Direct hmtx metric writes (`font/face.v`).
`read_hmtx` filled a third `Face.glyphs` array and copied each advance and lsb
out of it; nothing outside that function ever read the array. The two live
arrays are now written straight from the table, leaving `glyphs` declared but
empty for source compatibility. Truncation, tail-advance reuse and LSB defaults
are unchanged. An interleaved single-process A/B over five corpus fonts
(advances, lsbs, glyph count and units_per_em asserted equal before timing)
measured 1.03x, 1.08x and 1.08x on whole-face load. font, cmap, glyph and
font_varcomp suites green locally; full suite and difftest 0/0 green on CI.

**Phase 12 G20 — landed 2026-11-21.** Dense raw line-break class table
(`layout/linebreak.v`). The UAX#14 pass asked `props.line_break_of(cps[i])` once
in LB1 (`effective_class`) and again in LB8a and LB17 (`break_kind`) — roughly
two binary searches over the 2,946-record table per character. `break_opportunities`
now reads the raw class once per character into a dense slice and threads it
through all three rules; those rules deliberately want the raw, not the resolved,
class, so passing the effective class would be wrong. An interleaved
single-process A/B at elevated process priority over five 1024-codepoint inputs
(Latin, ZWJ, em-dash, Arabic, CJK) x both mandatory modes (full
`BreakOpportunity` equality asserted for every case before timing) measured
1.14x, 1.07x, 1.04x and 1.09x on `break_opportunities`. linebreak, cjkbreak,
linebreak conformance, layout, logattr and inspect suites green locally; full
suite and difftest 0/0 green on CI.

**Phase 12 G21 — landed 2026-11-21.** Fold the oblique ink-box scan into the
shear write (`raster/synth.v`). `oblique_bitmap` made a third full `w2 x height`
pass over the freshly written canvas just to find the min/max of nonzero pixels;
the shear loop writes every canvas byte exactly once, so tracking the box from
the value just stored sees the same accumulators. All-zero canvases still return
the empty sentinel, and slant sign, bounds and `left`/`top` are unchanged. An
interleaved single-process A/B over nine real glyph bitmaps x five slants plus
five edge cases (every coverage byte and box field asserted equal before timing)
measured 1.16x, 1.23x and 1.13x on the oblique pass. synth, raster_color and
stbtt suites green locally; full suite and difftest 0/0 green on CI.

A fourth scout wave covered rasterization, cold font loading and the
segmentation utilities; all three of its candidates (G17–G19) are now landed.
A fifth wave added the linebreak raw-class table (G20) and the oblique ink-box
fold (G21). Two of its runner-ups were measured and rejected: the `to_lcd`
row-index hoist was consistently 0.85–0.87x the original despite removing a
multiply and a load per pixel, and the shaped-glyph backing arena swung between
0.77x and 1.46x across interleaved A/B runs (0.85–1.13x even on a quieter host),
so neither has a trustworthy gain and the original code stands. Skipping WOFF
checksum passes was rejected earlier as behavior-changing.
A sixth scout wave looked at separable blur, the UCD lookup primitive and cmap
glyph lookup. The separable `blur_bitmap` reimplementation is byte-identical in
principle but the function is test-only — the engine never calls it — so it
would move no shipped number and was not landed. A dense Latin-1 glyph index on
`Face` was built and measured: the microbenchmark was 79–95x (one array load
instead of a cmap binary search), but across thirteen interleaved whole-paragraph
runs the layout ratio had a median near 1.02x with several 0.87–0.96x results —
the extra branch on the predominantly non-Latin workload erased the saving — so
it was rejected. The UCD `lookup_range` structure-of-arrays key table was also
built and measured: a dense `[]u32` of `lo` keys was threaded through the seven
`Properties` accessors so the binary search reads 4-byte strides instead of
`CodeRange`'s 12-byte stride. Full equality was pinned over 24,384 codepoints
(every boundary of the two largest tables plus a dense sweep, all seven
properties) and over four whole paragraphs before timing, but eight
interleaved A/B runs on a quiet host measured 0.84–0.96x — the final `hi`/`value`
read from the second array costs more than the single cache-friendly array with
hardware prefetching, so it was rejected too. A seventh scout wave covered GPOS
positioning, bidi reorder / the C API, and FontSet resolution. Its clearest
candidate — dropping a provably redundant `tos(...).clone()` in `capi.v:c_text`
(`string.runes()` always decodes into a fresh array, and an alias test confirmed
the result does not borrow the caller's bytes) — was built and measured with
full equality pinned: twelve interleaved A/B runs, including a `-prod`/gcc build,
clustered around 1.0x (0.91–1.09x). The memcpy is below the noise floor, so with
no trustworthy gain it was rejected under the same rule. The GPOS stack-candidate
bucketing (`layout/marks.v`) and the FontSet double-cmap fusion (`shape/glyphs.v`)
remain scoped but unmeasured. AAT `morx`, Graphite, WOFF2, the full TrueType
interpreter, CFF2 and Tibetan stacking remain gated on a carrier font or a CI
reference engine, not on performance.

## Corpus register

Every face below ships its licence text as `OFL-<Name>.txt` (or
`GFL-LatinModernMath.txt` — the one exception) beside the font. Fetched
from google/fonts raw URLs (wave pattern) except the pre-existing Amiri,
Naskh, Nastaliq and SC faces.

| Face | Bytes | Scripts | Licence |
| --- | --- | --- | --- |
| `Amiri-Regular.ttf` (+ `.woff`) | 437,780 | Arabic-script | OFL |
| `NotoNaskhArabic-Regular/Variable.ttf` | 291,980 / 253,880 | Arabic-script | OFL |
| `NotoNastaliqUrdu-Regular.ttf` | 176,600 | Urdu | OFL |
| `FiraCode-Variable.ttf` | 260,364 | Latin/Cyrillic/Greek + code | OFL |
| `JetBrainsMono-Variable.ttf` | 187,208 | Latin + code | OFL |
| `JetBrainsMonoNerdFont-Regular.ttf` | 2,571,596 | Latin + PUA icons | OFL |
| `CascadiaCode-Variable.ttf` | 727,940 | Latin + code | OFL |
| `NotoSansHebrew-Variable.ttf` | 112,640 | Hebrew | OFL |
| `NotoSansSC-Variable.ttf` | 17,772,300 | CJK Han | OFL |
| `NotoSansThai/Lao/Khmer/Myanmar-Variable.ttf` | 218,652 / 176,620 / 359,788 / 784,832 | Thai / Lao / Khmer / Myanmar | OFL |
| `NotoSansSyriac-Variable.ttf` | 171,996 | Syriac | OFL |
| `NotoSansThaana-Variable.ttf` | 114,724 | Thaana | OFL |
| `NotoSansNKo-Regular.ttf` | 79,696 | NKo | OFL |
| `NotoSansGeorgian-Variable.ttf` | 231,988 | Georgian | OFL |
| `NotoSansArmenian-Variable.ttf` | 221,936 | Armenian | OFL |
| `NotoSansEthiopic-Variable.ttf` | 1,143,168 | Ethiopic | OFL |
| `NotoSansBengali-Variable.ttf` | 463,668 | Bengali | OFL |
| `DoulosSIL-Regular.ttf` | 887,828 | Latin (survey-only: no `morx`/Graphite) | OFL |
| `AwamiNastaliq-Regular.ttf` | 644,356 | Urdu Nastaliq + Graphite trigger (`Silf`/`Glat`/`Gloc`) | OFL |
| `SourceSans3-Regular.otf` (CFF) | 334,924 | Latin | OFL |
| `STIXTwoMath-Regular.ttf` | 1,517,976 | Math | OFL |
| `LatinModernMath-Regular.otf` (CFF) | 733,736 | Math | GFL (LPPL instance; OFL backup carries no MATH table — rejected) |

## Open work

Everything not landed, in one place. Text above owns the detail; this table
owns the queue.

| Slice | Item | State |
| --- | --- | --- |
| 7.6 / 9.3 | Indic machine + Devanagari + Bengali + hook + conjunct defaults + repha + zero-class marks + assembly + GPOS | landed (HB-default incl. reph; rkma reph order stays the recorded divergence) |
| 8.5 | Synthetic styles + LCD | landed (bitmap-level) |
| 7.7 | Color + hinting engines | landed (grid-fit autohinter, color readers + composite; bytecode triggered) |
| 7.8 | Core Text + DirectWrite providers | landed (per-OS real, none elsewhere) |
| 7.11-2H | Rival A/B harness | landed (README table, re-measured per release) |
| 8.2 | Log-attr/caret pass over laid-out lines | landed (grapheme engine + floor included) |
| 8.4 | C-side spelling for `wrap_mode`/`tab_stops` | landed (append-only, offsets stable) |
| 8.6 | Stroking | landed (8.6a outline reader + stroker; design-unit pins at 1e-9 since 2026-11-17 — miter/bevel joints divide, and C contraction moves 1-2 ulps between clang and gcc) |
| 8.7 | Face/subset MATH wiring; top-accent fallback | landed (half-advance fallback, MATH closure) |
| 7.9 | CFF subsetting | landed (verbatim keep, CFF2/CID refused) |
| 7.10 | Composite instancing; raster wiring | landed (HVAR/MVAR/cvar readers, composites, wiring) |
| 9.1 | Hangul jamo composition; vertical CJK punctuation | landed (KR face, HB pins, break-fix) |
| 9.2-engine | ccc=0 marks attach; coeng fusions, pref reorder, kinzi, blws, Khmer pres-group landed; Myanmar blwf order closed 2026-11-17 (asked runs pre-ccmp, HB-exact; default stays unfused); `nko ` tag fold landed; Khmer subscript-U residual closed 2026-11-17 (HB-exact, pinned; U rides the stack); Khmer abvm stack pinned 2026-11-17 (anchor-side HB-exact, chains fire on no corpus word); 17CE-over-SRAII-ligature closed 2026-11-17 (mark-lig ComponentRecord stride + last-anchored-component, Tahoma HB-exact); Khmer split vowels closed 2026-11-17 (SRA E inserted pre-base, HB-exact incl. coeng cluster); chaining singles compose through apply_mark_chain (Thai dist chain, Khmer abvm/blwm) | landed (clusters stay honest per input where HarfBuzz merges onto the base — convention, recorded) |
| 9.4-rest | More simple alphabets; emoji survey | landed (Georgian/Armenian/Ethiopic + mono survey; color → 7.7) |
| 9.3 | Bengali generality proof (after Devanagari) | landed (assembly + GPOS marks; joining hook included) |
| 10.1 | generic measure / iterate (`layout/iterator.v`) | landed (standalone, no FONS) |
| 10.2 | generic rect packing (`raster/pack.v`) | landed (standalone, caller-owned atlas) |
| 10.3 | generic coverage helpers (`raster/quantize.v`) | landed (mono/gray2/4, gamma, blur) |
| 10.4 | canvas CPU helpers as generic coverage only | landed (10.3; hint/LCD/stroke/color stay 7.7/8.5/8.6/7.7) |
| 10.5 | generic discovery (`providers/discovery.v`) | landed (order/variant/pow2; 7.8 stays per-OS) |
| 11.1 | Modularity: import ratchet (M1), split gpos/gsub/layout/shape-font (M2/M3) | landed (M1 ratchet + deliberate-violation break-fix; M2/M3 pure moves, no API renames, all files under 60 KB) |
| 11.2 | Extendability: ScriptShaper registry (E1), feature order as data (E2), onboarding checklist (E3) | landed (E1 registry + Khmer/Myanmar/Indic migrations; E2 FeaturePlan with pre-ccmp slot; E3 SCRIPT_ONBOARDING.md) |
| 11.3 | Fast: shaping profiler (F1), fix what it finds (F2), allocation pass (F3) | F1 landed (opt-in per-stage profiler); F2/F2b/F2c landed (Indic table hoist, format-4 reverse, stacked cluster search); F3 landed (GPOS lookup-list hoisting, no behavior change) |
| 12.1 | Rival parity: GSUB pre-filter (G1), mark-pass skip (G2) | landed (first-coverage run-set filter; markless early return + binary-searched cand_base) |
| 12.2 | Rival parity: NFD ASCII path (G3), Context-decoded Indic tables (G4) | landed (identity mapping pre-scan; tables decode once per Context) |
| 12.3 | Rival parity: ASCII bidi fast path (G5) | landed (14–19x on `resolve_paragraph`; gate-neuter control 1.04x) |
| 12.4 | Rival parity: dense placement arrays (G6) | landed (1.7–2.2x on `place_glyphs`; dense==map pinned across plain/merged/RTL inputs) |
| 12.5 | Rival parity: per-line measurement memo (G7) | landed (10.7x on `measure_line`; memo==per-glyph pinned across repeated gids and mark offsets) |
| 12.6 | Rival parity: ASCII joining fast path (G8) | landed (4.7–5.7x on `shape_arabic`; fast==full walk pinned across printable ASCII) |
| 12.7 | Rival parity: per-lookup GSUB hit set (G9) | landed (1.9–2.3x on `substitute_glyphs`; filter toggle pinned, calt has 103 lookups) |
| 12.8 | Rival parity: precomputed mark base cluster (G10) | landed (53x on the mark base search; cand_base==map walk asserted per mark) |
| 12.9 | Rival parity: query each first-coverage gid once (G11) | landed (1.40–1.42x on GSUB, interleaved single-process A/B; binary coverage_has) |
| 12.10 | Rival parity: per-layout shaped_glyphs memo (G12) | landed (1.05–1.14x on `.segment`; direct-mapped, full Line equality asserted) |
| 12.11 | Rival parity: dense per-run JoiningType (G13) | landed (1.05–1.11x on `shape_arabic`; full ShapedRun equality asserted) |
| 12.12 | Rival parity: drop dead cmap second pass (G14) | landed (1.67–1.91x on `glyph_index_for`; 2048 cps equality asserted) |
| 12.13 | Rival parity: dense vertical placement (G15) | landed (1.95–2.09x on `.place`; full Line equality asserted) |
| 12.14 | Rival parity: bracket table once per paragraph (G16) | landed (2.55–2.68x on `resolve_paragraph`; single-sequence control ~1.00x) |
| 12.15 | Rival parity: ASCII grapheme fast path (G17) | landed (26–29x on `grapheme_breaks`; full equality pinned for both opts + fallback) |
| 12.16 | Rival parity: separable embolden max filter (G18) | landed (2.52–3.17x on the embolden pass; byte-for-byte coverage equality) |
| 12.17 | Rival parity: direct hmtx metric writes (G19) | landed (1.03–1.08x on whole-face load; metrics equality pinned across 5 fonts) |
| 12.18 | Rival parity: dense raw line-break class table (G20) | landed (1.04–1.14x on `break_opportunities`; full opportunity equality pinned) |
| 12.19 | Rival parity: oblique ink-box fold (G21) | landed (1.13–1.23x on the oblique pass; byte-for-byte coverage equality) |

**Triggered, not scheduled** (a slice lands when a font needs it): AAT
`morx` (no committable carrier class exists — Apple faces are
unredistributable, no OFL `morx` carrier is known; a generated font would be
the fixture-matches-reader failure, so there is nothing to fetch), Graphite
(font gate pulled 2026-11-17: `AwamiNastaliq-Regular.ttf` committed with
`Silf`/`Glat`/`Gloc`/`Feat`/`Sill`; Doulos SIL 7.000 surveyed 2026-11-17 and
carries none — 18 tables, no `morx`/`mort`/Graphite, `Silt` is an opaque gzip
blob; corpus 26-face scan 0 hits, full AAT-family scan on both SIL faces 0
hits; reference gate still closed — HarfBuzz cannot shape Graphite, so a
grengine-class reference must be proven in CI first; engine unscoped),
WOFF2/brotli, the full TrueType bytecode interpreter,
CFF2, Tibetan stacking (arrives with its own slice and stacking font, or
says why it cannot).

## Explicitly not planned

Worth writing down so these do not come back as questions.

- A text editor, or any interactive application. The library is a library.
- A layout engine for boxes, flex, or CSS beyond the text layer. Line
  breaking, wrapping, alignment, hyphenation, wrap modes, ellipsize and tabs
  are in; boxes, the cascade and painting stay the caller's.
- HarfBuzz bindings, or a port of anything. The engine is written from the
  specifications.
- Font authoring. vtext reads fonts, subsets them, and reports on them; it
  does not build them.

The last boundary has a caller: a from-scratch HTML/CSS engine (`../vweb`)
uses this library as its only text layer. Boxes, the cascade and painting
are the caller's; this library ends at a positioned glyph with a coverage
bitmap. Glyph reuse is the one place the boundary was awkward, and it is
settled: the caller rasterizes into its own buffer, so it needs a cache and
not an atlas — **the cache is the caller's**.

## Process

How slices land, kept here so it is not re-derived each session:

- One commit per slice on its own branch, merged with `--no-ff` (fast-forward
  only for purely additive corpus/table slices).
- Before commit: `v fmt -w` every touched V file, `v fmt -l` clean, full diff
  read (fmt must be whitespace-only), targeted tests plus the full suite
  (`VJOBS` sized to free RAM, private `TMPDIR`) plus difftest 0/0, plus a
  break-fix control that moves the score.
- At merge: review the diff, re-run the suite and difftest on the merge,
  then push. Worktrees and branches are pruned after landing.
- Parallel slices share nothing: disjoint file sets, new files where
  possible, exclusive ownership where shared files are unavoidable. Agents
  never touch `ROADMAP.md`, docs, or another slice's files; docs and wiring
  land with the owner.
- V resolves `vtext.*` imports by ancestor walk, so a worktree named
  `vtext-NN` tests the sibling checkout named `vtext` instead of itself.
  Verify worktree-local through a `VMODULES` junction (`<tmpmod>\vtext` →
  the worktree) plus `v -path <tmpmod>|@vlib|@vmodules`; merge-time runs
  happen in a `vtext`-named root.
