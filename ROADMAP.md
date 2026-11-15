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
HarfBuzz-pinned; Thai, Lao, Khmer and Myanmar carry corpus pins with two
documented engine gaps; CJK line breaking is conformance-pinned.

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
| Grapheme clusters; word/sentence tables | tables landed 8.2 | 1944/1944 + 512/512 floors |
| Case mapping (incl. tr/az) | landed 8.3 | SpecialCasing conformance |
| Line breaking (UAX #14) | landed, 19,346/19,346 | conformance floor |
| Wrap: align/justify/kashida/hyphen-policy/modes/ellipsize/tabs | landed 7.4, 7.5, 8.4 | `align_test`, `hyphen_wrap_test`, `ellipsize_wrap_test` |
| Vertical single column | landed | `vertical_test` (columns open) |
| CFF reader (CFF2/subset refused) | reader landed 7.9 | `cff_test` |
| MATH reader (Face wiring open) | reader landed 8.7 | `math_test` |
| Variable instancing | landed 7.10 | `varinstance_test` + 142,848 sweep |
| Reference cache helper (caller-owned) | landed 7.11-1H | `cache_test` |
| fontconfig match/sort/coverage | landed 8.8 | `match_test` (CI-owned leg) |
| Subsetter (glyf; CFF refused) | landed | `subset_test` |
| C API + usage guide | landed | `capi.v`, `vtext.h`, `USAGE.md`, smoke test |
| Inspection API (on `shape.Font`) | landed | `inspect_test`, `fontdump`/`fontcheck`/`shapetrace` |
| Examples (12, multilingual, corpus-only) | landed | `examples/` |
| Indic machine, SE-Asian engine, color/hinting, stroking, synth/LCD, CoreText/DW providers, rival A/B | open / in progress | Phase 7–9 below |

Suite: 57 test files, all passing (2026-11-15). Differential baseline:
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
  at all.
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
extent), `glyphdump`, `subset` (glyf; CFF refused with the reason),
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
  with HarfBuzz-TTB-pinned geometry, reachable from C. Columns stay open.

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

**7.7 Color and hinting — open.** COLR/CPAL, CBDT/EBDT, sbix behind
`box_only`/`render_into`; SVG refuses with its reason. Grid-fit
autohinting verified against FreeType's own autohinter per glyph. A full
bytecode interpreter lands only if a corpus font needs one — measured
first, not assumed.

**7.8 Providers: Core Text and DirectWrite — open.** Each pinned on its own
OS, none elsewhere — the fontconfig pattern exactly.

**7.9 CFF/CFF2 with a real font — reader landed 2026-11-15.** OFL Source
Sans 3 OTF (non-CID Type 2, 2,478 glyphs); `font/cff.v` reads header,
INDEXes, Top DICT, CharStrings, charset, Private, both subr sets through
the existing curve path. Pinned by `cff_test.v` against fontTools with a
corrupt-byte break-fix. CFF2 still refuses (no committed face carries it);
subsetting still refuses CFF (a read is not a rebuild).

**7.10 Variable instancing — landed 2026-11-15.** fvar/gvar at
caller-chosen coordinates (`font/var.v`: normalize, avar warp, tuple
tents, packed runs, IUP, `FT_MulFix` op-for-op — including the exact-.5 IUP
fix found by measuring against the FT 2.13.2 source), behind additive
`set_var_coords` / `instanced_glyph_points` on Face and Font. Pinned by
`varinstance_test.v` beside FreeType and fontTools, plus a dev-time sweep
of every simple glyph × four coords at 142,848/142,848 exact across four
variable faces. Follow-ups: composites, HVAR/MVAR/cvar, raster wiring.

**7.11 Cache and the rival number — cache landed 2026-11-15.** `shape/cache.v`:
`CacheKey` (font id, gid, size bits, subpixel x/y) with `==` and canonical
`str` (V maps take no struct keys; every field is in the encoding, two
tests fail if size or subpixel drops out), caller-owned `Cache` with
`get_or_rasterize`, `clear`, `len`, hit/miss counts. Font id is the caller's
assignment (nothing on `Font` is stable across calls); one id names one
(file, face). No eviction — the caller clears. Miss 19.1 us, hit 1.2 us
(Amiri `A`, 32 px). Pinned by `cache_test.v` with break-fix over all four
key dimensions. **Second half (rival A/B harness) open**: README numbers
become vtext-vs-rival on the same box, re-measured per release.

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
| FreeType API | embolden/oblique, stroker | bitmap-level 8.5 ✓ (outline-level follow-up) | 8.6 open |
| FreeType color | COLR/CBDT/sbix/SVG | → 7.7 | — |
| FreeType var | instancing | 7.10 ✓ | — |
| Pango layout | wrap modes, align, ellipsize, tabs | 7.4, 8.4 ✓ | — |
| Pango log attrs | cursor/word/sentence runs | tables 8.2 ✓ | log-attr pass open |
| Pango markup | attribute markup | out (app-level, like CSS) | — |
| fontconfig | match/sort/coverage | match + 8.8 ✓ | — |
| ICU text | bidi/normalize/breaks/case | bidi, NFD, graphemes, 8.2 tables, 8.3 ✓ | log-attr pass open |
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

**8.2 Words, sentences — tables landed 2026-11-15.** UAX #29 tables as
generated data (`tools/gen_wordbreak.v` → `ucd_wordbreak.v`,
`ucd_sentence.v`); committee floors 1944/1944 + 512/512 with break-fix
controls that move the score (no WB4: 858; no RI ranges: 1937; no SB8a:
498). UCD 18.0.0 inputs committed with licence-travels exceptions. **Open:
the log-attr/caret pass** over laid-out lines (cursor offsets, word
boundaries, deletion spans) — engines live test-local in the meantime.

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
break-fix controls (char arm, ellipsis append). Follow-up:
C-side spelling for the two new fields (`COptions` untouched, no ABI break).

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

**8.6 Stroking — open.** `FT_Stroker` parity (joins, caps, miter limits)
flattened through the curve path, pixel-compared. Effects are the caller's;
geometry is the library's.

**8.7 MATH — reader landed 2026-11-15.** Opt-in `shape/math.v` pass
(variants, px scaling, disabled-pass answers base/zero) over `font/math.v`
(constants, italics, top accents, extended shapes, variants, assemblies),
pinned against HarfBuzz on STIX Two Math (OFL) and Latin Modern Math (GFL —
its OFL backup carries no MATH table and was rejected). Two spec traps
caught by measuring: 52 records not 54, inline construction records.
Follow-ups: Face/subset wiring; extent-derived top-accent fallback.

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
| Thai, Lao, Khmer, Myanmar | pinned (corpus; engine gaps open) | `seasian_test.v`, HB-measured (Thai 6E/86/2D/6E/0C/5E, Lao, Khmer coeng mark, Myanmar kinzi order) |
| Syriac, Thaana, NKo | pinned | `longtail_test.v`: Syriac init/medi/rlig + lone-SHIN joining acceptance |
| Hangul (precomposed) | untested | cmap suffices, no face, no test |
| Kana | partial | vertical rules in `vertical_test`; horizontal unpinned |
| Tibetan | absent | stacking needs its own machine |
| Indic (Devanagari et al.) | syllable machine first cut | tables + Devanagari face + machine (unwired), HB-pinned |
| Mongolian/Phags-pa vertical | absent | no vertical-columns path |
| Simple alphabets (Georgian, Armenian, Ethiopic, …) | untested | cmap should answer; nothing proves it |
| Emoji | unassessed | `emoji-data.txt` ships; color formats + ZWJ unsurveyed |

**9.1 CJK line breaking — landed 2026-11-15 as pins.** ID/CJ/NS/OP/CL were
already complete in the 19,346 tail: 0 fail on 1,753 ID cases and 0 on
5,333 CJK-subset cases in `cjkbreak_test.v`, HB wrap pins on NotoSansSC, a
520-case break-fix control. Follow-ups, each needing its own pin: Hangul
conjoining-Jamo composition (needs a Korean face), vertical CJK
punctuation.

**9.2 Southeast Asian clusters — corpus landed 2026-11-15.** Wave 3
(NotoSansThai/Lao/Khmer/Myanmar variable faces, HB pins in
`seasian_test.v`). Engine gaps documented in-file: ccc=0 spacing marks draw
nothing; no Khmer coeng fusion or Myanmar kinzi/stacks. Tibetan stacks
arrive as their own slice with a stacking font, or the slice says why they
cannot.

**9.3 The Indic machine — open (7.6 is its acceptance).** Slices: UCD Indic
tables generated like the rest; a committed Devanagari face; the syllable
machine with matra reordering; conjunct features
(`rphf`/`pref`/`blwf`/`pstf`/`vatu`/`cjct`); HarfBuzz pins; then Bengali to
prove generality. Each slice carries break-fix; Arabic stays green — the
ratchet, not a wish.

**9.4 The long tail — corpus landed 2026-11-15.** Wave 4 (Syriac, Thaana,
NKo; `longtail_test.v`, break-fix on the SHIN pin). Gaps documented
in-test: ccc=0 marks (Thaana fili, same gap as wave 3), `ot_script_tag`
missing space-padded tags (`nko ` vs `Nkoo` — forms prove right under
override, only the fold is wrong). Remaining: one smoke line each for the
other simple alphabets; the emoji survey (cmap monochrome ships, color
formats refuse with the reason).

Wave rule for the whole phase: every new script arrives as a committed OFL
font plus HarfBuzz-measured pins. A shaping-affecting script also extends
the difftest corpus, pango legs verified on CI.

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
| `SourceSans3-Regular.otf` (CFF) | 334,924 | Latin | OFL |
| `STIXTwoMath-Regular.ttf` | 1,517,976 | Math | OFL |
| `LatinModernMath-Regular.otf` (CFF) | 733,736 | Math | GFL (LPPL instance; OFL backup carries no MATH table — rejected) |

## Open work

Everything not landed, in one place. Text above owns the detail; this table
owns the queue.

| Slice | Item | State |
| --- | --- | --- |
| 7.6 / 9.3 | Indic machine + Devanagari acceptance | first cut landed (unwired); joining hook + Bengali open |
| 8.5 | Synthetic styles + LCD | landed (bitmap-level) |
| 7.7 | Color + hinting engines | open |
| 7.8 | Core Text + DirectWrite providers | open (OS-gated) |
| 7.11-2H | Rival A/B harness | open |
| 8.2 | Log-attr/caret pass over laid-out lines | open (engines test-local) |
| 8.4 | C-side spelling for `wrap_mode`/`tab_stops` | open (no ABI break) |
| 8.6 | Stroking | open |
| 8.7 | Face/subset MATH wiring; top-accent fallback | open |
| 7.9 | CFF subsetting (a read is not a rebuild) | open until a slice needs it |
| 7.10 | Composite instancing; HVAR/MVAR/cvar; raster wiring | open |
| 9.1 | Hangul jamo composition; vertical CJK punctuation | open (each needs its pin) |
| 9.2-engine | ccc=0 mark drawing; Khmer coeng; Myanmar kinzi/stacks; `nko ` tag fold | open |
| 9.4-rest | More simple alphabets; emoji survey | open |
| 9.3 | Bengali generality proof (after Devanagari) | open |

**Triggered, not scheduled** (a slice lands when a font needs it): AAT
`morx`, Graphite, WOFF2/brotli, the full TrueType bytecode interpreter,
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
