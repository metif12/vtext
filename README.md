# HarfAra

**HarfAra (حرف‌آرا)** is a Persian compound meaning *one who adorns and arranges letters*.

- **harf (حرف):** Letter or character.
- **ārā (آرا):** An element meaning adorning, embellishing, or arranging, derived from **ārāstan (آراستن)**, the Persian verb meaning *to adorn, decorate, or put in order*.

Pronounced *harf-ārā* (/hæɾf.ɒːˈɾɒː/).

The name reflects the art of giving letters their proper form, position, and visual expression. In typography, beautiful text is not simply written; it is shaped, arranged, and brought to life.

A complete font and text package in V: load, shape, lay out, rasterize,
inspect and subset — one library where each job is a separate part with its
own API and its own conformance baseline. It replaces FreeType, HarfBuzz,
Pango, fontconfig, fontstash and stb_truetype per part, on Windows, Linux
and macOS, with answers as good and throughput measured better — or the
claim is not made.

A caller uses one part or all of them; nothing is pulled in by accident. Each
part is measured against the incumbent for that part: shaping against
HarfBuzz, line breaking against the Unicode committee's own test,
rasterization against FreeType and Pillow. A part with no baseline is a part
with no claim, and every remaining difference is recorded with its reason.
See `GOAL.md` for the one paragraph that decides scope arguments, and
`ROADMAP.md` for where each part stands.

> HarfAra was named **vtext** until 2026-11-23. The module is lowercase
> `harfara`; the v0.1.0 release predates the rename and keeps the old names.
> See `API.md` for the full V reference.

```v
import harfara.layout
import harfara.shape

fn main() {
	ctx := shape.new_context()
	fs := shape.new_font_set()
	fs.add(shape.load_font_file('testdata/fonts/Amiri-Regular.ttf') or { panic(err) })

	line := layout.layout_paragraph(ctx, 'بِه'.runes(), .rtl, fs, 32.0)
	font := fs.pick(`ب`) or { panic('no font') }
	for g in line.glyphs {
		bitmap := font.rasterize(g.gid, 32.0, 0, 0)
		println('${g.gid} at ${g.x},${g.y} ${bitmap.width}x${bitmap.height}')
	}
	println('width: ${line.width}')
}
```

## What it replaces

| Part | Replaces | Status |
| --- | --- | --- |
| `harfara.ucd` | — (shared data) | Generated UCD tables, decoded once into `Properties`; case mapping included |
| `harfara.font` | FreeType's loading side, fontTools' reading side | sfnt/TTC containers, WOFF1 and WOFF2 read, cmap, metrics, variation-store reading |
| `harfara.brotli` | brotli's decoder | Decoder-only pure-V subset vendored in-tree (no encoder); WOFF2 inflates through it |
| `harfara.shape` | HarfBuzz core | Normalization, bidi, joining, GSUB/GPOS application, case mapping |
| `harfara.layout` | Pango's layout math | Line breaking, wrapping, measuring, vertical lines and columns |
| `harfara.raster` | FreeType's rendering side | Hinted box-and-fill, color, synth/LCD, stroker behind the same contract |
| `harfara.inspect` | fontTools' reading side | Reports on tables, features, scripts, coverage, variable axes and instances |
| `harfara.subset` | fontTools' subsetter | Glyf closure and rebuild; CFF rebuild landed, CFF2 refused with its reason |
| generic helpers (`raster/pack`, `raster/quantize`, `layout/iterator`, `providers/discovery`) | fontstash + stb_truetype | Atlas packing, coverage quantize/gamma/blur, visual-order quads, search order — caller-owned atlas, no FONS types |
| providers | fontconfig / Core Text / DirectWrite | All three landed; none elsewhere |

Dependencies run one way — `layout` → `shape` → `font` → `ucd` — and no part
imports a tool.

## What it does

The pipeline is the one UAX #9 and the OpenType specification describe, in order.

| Stage | Spec | File |
| --- | --- | --- |
| Decompose and order combining marks | UAX #15 | `shape/normalize.v` |
| Resolve paragraph direction and runs | UAX #9 | `shape/bidi.v`, `shape/bidi_rules.v` |
| Pick the Arabic joining form | UAX #53 | `shape/joining.v` |
| Choose and order fonts | | `shape/glyphs.v` |
| Substitute glyphs | OpenType GSUB | `font/gsub.v` |
| Place combining marks | OpenType GPOS | `font/gpos.v` |
| Order glyphs for drawing | UAX #9 | `layout/layout.v` |
| Rasterize | | `font/stbtt.c.v` (glyf/CFF1), `font/cff2raster.v` (CFF2) |

Character data is generated from the UCD into `ucd/ucd_*.v` (module `harfara.ucd`),
so there are no runtime tables to load and no network access is needed to build.

## Supported

- sfnt and TTC containers, WOFF1, and font collections. CFF1 is read,
  rasterized and subsetted; CFF2 is read, rasterized at any instance,
  and subsetted (CID-keyed CFF is refused).
- cmap subtable formats 0, 4, 6, 12, 13 and 14, including variation sequences.
- Arabic joining forms, and the isolated, initial, medial and final shapes.
- GSUB single, multiple, alternate, ligature and contextual substitutions.
- GPOS mark-to-base, mark-to-ligature and mark-to-mark attachment.
- GPOS pair adjustment (kerning), in both the per-pair and the per-class forms.
- GPOS single positioning, in both the per-glyph and the shared-value-plus-exceptions forms.
- GPOS chaining-context positioning (lookup type 8, formats 1, 2 and 3).
- Right-to-left lines, mixed-direction paragraphs, and bidi mirroring.
- Line breaking per UAX #14 — 19,346 of 19,346 committee cases (100%) —
  wrapping to a width, and vertical lines cut into columns.
- Measuring a paragraph: min-content and max-content width, vertical extent, resolved line height.
- Line height, letter spacing and word spacing as caller options.
- Per-run script and language override for feature resolution.
- Alignment: left, center, right, and justification — with kashida
  tatweel insertion for uniform Arabic lines, space stretching
  everywhere else.
- Full upper, lower and title case mapping, including the Turkish/Azeri rows.
- Hyphenation by Liang's algorithm over generated US-English patterns,
  through any `BreakPolicy` — UAX #14 alone by default.
- A variable font's axes and named instances, read off fvar and the name table.
- A glyph's box and its coverage bitmap.

### Emoji and variation sequences

A variation selector changes which glyph the character in front of it draws as: a heart with U+FE0F
after it is an emoji and without it is text, and those are different glyphs with different outlines.
The selector is not looked up as a character — U+FE0F has no glyph of its own in any font — so the
lookup that answers the question takes a pair rather than a codepoint.

```v
// Both forms exist. With no selector this is exactly glyph_index.
gid := font.glyph_index_variation(0x2764, [rune(0xFE0F)])

// A font can cover a base and still have no opinion about the sequence, which is a result
// rather than a miss, and this is how a fallback chain tells them apart.
if font.has_variation_sequence(0x2764, 0xFE0F) {
	// this font knows the pair
}
```

The layout pass does this for you: text containing a selector draws the emoji, and the selector never
becomes a glyph of its own or takes width. A selector with no character in front of it draws nothing,
because a request about nothing is not a character.

**A variation sequence is not a character**, which is the one rule everything else follows from. The
base on its own still draws as text; only the pair draws as emoji.

## Not yet

Each item names the slice that owns it in `ROADMAP.md`.

- Cursive attachment: read from real fonts, not applied — the one corpus rule
  that reaches its own glyphs is vestigial (four one-sided anchors, no adjacent
  exit-plus-entry pair), and it rewires the day a shaped line grows a pair.
- Everything else this section used to list is landed: the Indic machine with
  Devanagari and Bengali, Khmer/Myanmar shaping, hinting and color, synthetic
  styles and LCD, stroking, MATH wiring, variable instancing, Core Text and
  DirectWrite providers, CFF subsetting, word/sentence breaks with log attrs,
  wrap modes/ellipsize/tabs, the Phase 9 scripts, the CFF2 reader, raster
  backend, instancing and subset rebuild, and Tibetan stacking. What remains
  besides cursive is the triggered set in `ROADMAP.md` (AAT `morx`, Graphite,
  the full TrueType bytecode interpreter), which lands when a
  font needs it.

## Refused by design

Named here so that a caller is not surprised by them.

- **The legacy `kern` table.** Kerning is read from GPOS only, which is where every font worth using
  puts it. A font that has only a `kern` table is drawn unkerned.
- **WOFF2 write.** Reading is landed (14.0, pure-V vendored brotli decoder); writing needs an
encoder and none lives in this tree, so the write path is refused with the reason.
- **AAT `morx` and Graphite.** No corpus font carries either; the day one does, it gets a slice.
- **HarfBuzz bindings, or a port of anything.** Every part is written from the specifications.
- **Font authoring.** HarfAra reads fonts, subsets them, and reports on them; it does not build them.
- **GPU atlases and hidden caches.** `Font.rasterize` is pure in (font, gid,
  size, subpixel offset); the caller rasterizes into its own buffer and keeps
  its own cache. `shape.Cache` is that memo with the only honest key already in
  it, and the engine never sees it.
- **Boxes, the cascade, painting.** The engine ends at a positioned glyph with a
  coverage bitmap; what stacks the lines owns the rest.

Line breaking is measured against the Unicode committee's own test for this version, not described.
It passes **19,346 of 19,346 cases (100%)**, and `linebreak_conformance_test.v` asserts that as a
floor on every run, so the number cannot be quietly lowered.

## Test fonts

The suite reads the fonts in `testdata/fonts/`, so it does not depend on what is installed.
All are under the SIL Open Font License except Latin Modern Math, which ships under the GUST
Font License (an LPPL instance); the licence text sits beside each font.

| Font | Why it is here |
| --- | --- |
| `Amiri-Regular.ttf` | A naskh face with a real cursive attachment, plus the joining, mark and kern reference. |
| `Amiri-Regular.woff` | The same face as WOFF1: the WOFF1 container pin. |
| `Amiri-Regular.woff2` | The same face as WOFF2: the brotli inflate + transform-rebuild pin. |
| `NotoSansNKo-Regular.woff2` | A small WOFF2 with hint programs in the transform: the instructions-path pin. |
| `FiraCode-Variable.ttf` | Programming ligatures and a variable weight axis: the `calt`/`liga` pin. |
| `NotoNaskhArabic-Regular.ttf` | Joins with substitutions alone, so it has **no** cursive rule. It is the negative control: a reader that accepted every type 3 subtable would fail here. |
| `NotoNaskhArabic-Variable.ttf` | A variable naskh face: the fvar axes and named-instances pin. |
| `NotoNastaliqUrdu-Regular.ttf` | Nastaliq, whose positioning reaches its rule through an extension. |
| `JetBrainsMono-Variable.ttf` | A second code face: `=>` folds under `latn` `calt` beside FiraCode. |
| `CascadiaCode-Variable.ttf` | A third code face that also covers Arabic and Hebrew: the multilingual-mono pin. |
| `NotoSansHebrew-Variable.ttf` | Hebrew with niqqud: bidi plus mark attachment outside the Arabic script. |
| `NotoSansSC-Variable.ttf` | Simplified Chinese: CJK coverage, shaping smoke, and pinned ID/CJ/NS/OP/CL breaks (9.1). |
| `JetBrainsMonoNerdFont-Regular.ttf` | The same code face patched with PUA icons: terminal/geek glyphs beside text. |
| `STIXTwoMath-Regular.ttf` | A math face: MATH constants, variants and assemblies beside HarfBuzz. |
| `NotoSansBengali-Variable.ttf` | Bengali: the Indic generality proof beside HarfBuzz (9.3). |
| `NotoSansThai-Variable.ttf` | Thai: SE Asian engine pins beside HarfBuzz (9.2). |
| `NotoSansLao-Variable.ttf` | Lao: same engine, anchored marks (9.2). |
| `NotoSansKhmer-Variable.ttf` | Khmer: coeng fusions, pref reorder, pres-group, abvm stack (9.2). |
| `NotoSansMyanmar-Variable.ttf` | Myanmar: kinzi, blws stacks, caller-asked blwf (9.2). |
| `NotoSansSyriac-Variable.ttf` | Syriac: long-tail shaping smoke (9.4). |
| `NotoSansThaana-Variable.ttf` | Thaana: fili attach beside HarfBuzz (9.4). |
| `NotoSansNKo-Regular.ttf` | NKo: joining beside HarfBuzz, space-pad tag fold (9.4). |
| `NotoSansGeorgian-Variable.ttf` | Georgian: hello-word pin beside HarfBuzz (9.4). |
| `NotoSansArmenian-Variable.ttf` | Armenian: same pin (9.4). |
| `NotoSansEthiopic-Variable.ttf` | Ethiopic: same pin (9.4). |
| `DoulosSIL-Regular.ttf` | Survey face: carries neither `morx` nor Graphite. |
| `AwamiNastaliq-Regular.ttf` | Graphite trigger face (`Silf`/`Glat`/`Gloc`); shaped here through OpenType. |
| `SourceSans3-Regular.otf` | CFF outlines through the same reader and rasterizer pins. |
| `LatinModernMath-Regular.otf` | A second math face (CFF outlines, GUST licence): same pins, different tables. |

## Differential testing

Shaping is measured against four independent engines, not described. `tools/shapedump.v`
dumps any case as tab-separated glyphs (advance, offsets, cluster, source font, box,
coverage), and `tools/difftest/compare.py` lays HarfBuzz, fontTools, Pillow and Pango
beside it over seventeen cases, from `سلام` to mixed bidi with digits. Every difference
found is recorded in `tools/difftest/baseline.tsv` — currently one hundred and fifty-one entries, each
with its reason in `ROADMAP.md` — and CI fails on any new difference or any fixed one
left unrecorded, in both directions. The Pango leg compares wrap widths at a fixed
width and a full-line Cairo render against a HarfAra-composed image, pixel by pixel;
it runs where libpango exists and elsewhere skips aloud, in which case its
baseline entries are reported as unverifiable rather than stale.

## Using it

### Laying out a line

```v
ctx := shape.new_context()
fs := shape.new_font_set()
fs.add(shape.load_font_file('tahoma.ttf') or { panic(err) })
fs.add(shape.load_font_file('segoeui.ttf') or { panic(err) })

// The third argument is the paragraph direction; .auto reads it from the text.
line := layout.layout_paragraph(ctx, text.runes(), .auto, fs, 32.0)
```

`em_px` is the size of an em square in pixels, so 32.0 gives roughly a 32-pixel line.

### Fonts

`FontSet` is an ordered fallback chain. A codepoint is drawn with the first font that has a glyph for it.

```v
fs := shape.new_font_set()
fs.add(arabic_font)  // first choice
fs.add(latin_font)   // used for codepoints the first has no glyph for
```

A flat order cannot express what a mixed-script line usually wants, and the reason is worth stating
because it is not obvious until you count the glyphs. A flat chain answers by coverage order —
the first font that has the codepoint wins — so Latin lands in whichever of Amiri and FiraCode
stands first, whatever the line is "in". Only the script set routes by what the text is.

```v
// Arabic goes to the Arabic font, everything else to the Latin one.
fs := shape.new_script_font_set(arabic_font, latin_font)
fs.pick_in(ctx, rune(0x0628))  // -> arabic_font
fs.pick_in(ctx, rune(0x41))    // -> latin_font
```

Measured on the corpus pair: `examples/fallback` lays three lines through a flat
(FiraCode, Amiri) chain and prints the counts per line — 53/0/0, then 29/7/0 with the 7
changing at the script boundary rather than at a word boundary, then 31/0/3 for the three
Hebrew letters neither font covers.

A per-script set with no primary and no general is exactly a flat set, so the two are interchangeable and
`pick_in` and `pick` agree in that case. The script test is the same generated table the joining pass
uses, so the set cannot disagree with the shaper about which characters are Arabic.

`glyph_index` maps a character to a glyph, and `codepoint_for` maps it back:

```v
gid := font.glyph_index('س')   // u16, zero for .notdef
cp := font.codepoint_for(gid)  // ?rune
```

The reverse direction is a search rather than a table, because a font may map several characters to one
glyph and the forward table does not record which came first. The lowest is returned, so a glyph is named
the same way everywhere in this library. Glyph 0 has no answer at all: it is `.notdef`, and naming it
would answer "what character draws nothing" with the lowest control character the font happens to
reference.

Arabic fonts rely on this being many-to-one. Noto Naskh Arabic draws U+0633 ARABIC LETTER SEEN and
U+FEB3 ARABIC LETTER SEEN INITIAL FORM as one glyph, so `codepoint_for` on that glyph answers U+0633.

### Tools

`tools/glyphdump.v` writes a font out as images, and lays a string out so the shaping result can be looked
at rather than inferred.

```sh
v run tools/glyphdump.v testdata/fonts/Amiri-Regular.ttf --size 32 --count 256 --boxes
v run tools/glyphdump.v testdata/fonts/Amiri-Regular.ttf --each out/glyphs --count 64
v run tools/glyphdump.v testdata/fonts/NotoNaskhArabic-Regular.ttf --text 'سلام'
```

`--sheet` draws a grid of glyphs on one page, on a shared baseline, which is how you see what a font
contains and eyeball a rasteriser across a whole font at once. `--each` writes one image per glyph sized
to that glyph's own ink box, which is the form to diff against another rasteriser: the box is the font's
answer. `--text` draws the run a string shapes into and tabulates it, and that table is the point —
`سلام` reports four characters becoming three glyphs, each one naming the character it came from and
saying which substitution replaced it, which is otherwise only answerable by printing glyph ids and
counting them by hand.

`tools/rival_bench.v` with `tools/rival_bench.py` is the rival A/B harness: the same workload timed
on HarfAra and on the stack it replaces, on the same box, in one table. The V half times line layout
and wrapping at 16 px for 1024-character paragraphs in every script the corpus covers, plus three
char-type paragraphs (marks-heavy, digits, mixed bidi), Amiri 'A' rasterized at 32 px cold
(sustained miss over A–T) and through the caller-owned cache, one fontconfig family match, and
one font load. The Python half times uharfbuzz shaping, a Pango wrap at the same 400 px width,
an fc-match lookup, and a fontTools load of the same inputs, built by the same repeat rule.
Best of five batches of twenty on both sides.

```sh
v -prod -cc gcc run tools/rival_bench.v
```

The measured table lives in [PERF.md](PERF.md) — method, boxes, flags, both rivals, and the
history — re-measured per release. The last column is a signed speedup factor: positive =
HarfAra faster, negative = HarfAra slower (`-28.2x` = 28.2 times slower, `+14.3x` = 14.3 times
faster). The `perf` CI job runs the harness on every commit and gates the ratios with
`tools/perf_check.py` (3x headroom over the recorded baselines; getting faster never fails). What each side does differs and the table says so: HarfAra lays the line out (bidi,
joining, GSUB/GPOS, measurement) where HarfBuzz only shapes, and Pillow renders with its own
bundled FreeType at default flags where HarfAra fills unhinted. Throughput is the comparison;
correctness is proven elsewhere, per part.

### Features

Every line gets `ccmp`, the four Arabic joining features, `rlig`, `calt`,
`liga` and `clig`, in that order, because a line missing its mark
composition, its letter shapes or its ligatures is not the text that was
asked for. Anything else is a presentation choice and stays with the caller.

Single positioning (GPOS type 1) folds the kerning feature's per-glyph
adjustments into advances and placements after substitution; mark features
stay with the anchor pass, which owns marks, so a mark is never shifted
twice. Cursive attachment is read and not applied: no available font both
carries a rule and shapes letters the way it describes, and HarfBuzz agrees
with the unwired answer on the one font that reaches its own rule.

The joining features are `isol`, `init`, `medi` and `fina`, and each is applied to the letters in its own
shape — the ones that join forward, the ones that join both ways, and so on. That masking is not an
optimisation. Each rule is written against the *base* letters, so applying `init` to a whole run would turn
every letter initial, and `medi` would then look up an initial form in a coverage of base letters, find
nothing, and leave the letter stuck initial.

**Combining marks take part in every shape**, because in Arabic these features are also mark composition: a
dot sits below the letter in one joining shape and above it in another, so a font composes its marks
differently per shape, through the very feature that names the shape. Noto Naskh Arabic's lookup 4 turns a
dot-centred mark into a dot-below one and is named by `init`, `medi` and `fina` alike. Holding marks out of
the mask leaves every dot in the composition meant for a different shape, and the text reads wrong.

This matters for fonts that keep their Arabic shapes in GSUB rather than in the cmap, which is most modern
ones. A font that maps the Unicode presentation forms is answered from the cmap. Noto Nastaliq Urdu is one
that does not, and it draws letters whose joining rules replace a single glyph with two or three:
`سلام دنیا` is 18 glyphs from 9 characters. A glyph at a time cannot express that, which is why the features
run over the run.

```v
// calt, liga and clig are already on: the code arrow and the fi ligature
// below draw the way every other shaper draws them. A `-tag` entry turns
// one back off.
mut opts := layout.LayoutOptions{}
opts.features = ['-calt'] // => stays two plain glyphs

line := layout.layout_paragraph_with(ctx, text.runes(), .rtl, fs, 32.0, &opts)
```

### Line options

`LayoutOptions` is where the choices that are the caller's rather than the engine's live. Three of
them change measurements, so anything that sizes a box has to use the same options the line is drawn
with.

```v
mut opts := layout.LayoutOptions{}
opts.features = ['liga']
opts.line_height = 28.0       // 0 takes the font's own
opts.letter_spacing = 0.5
opts.word_spacing = 2.0
opts.align = .justify         // left is the default; needs align_width below
opts.align_width = 400.0      // 0 takes the line's own width (align off)

line := layout.layout_paragraph_with(ctx, text.runes(), .rtl, fs, 32.0, &opts)
next_baseline := baseline + line.line_height
```

`line.line_height` is resolved for you: the value you asked for, or the largest natural line height
among the fonts that contributed a glyph, so a paragraph that fell back mid-line is spaced for the
tallest face in it.

Spacing is added to each letter's advance, not between letters, and a **combining mark is not
spaced**. A mark shares its base's position and has no advance of its own, so spacing one as well
would apply the same letter spacing twice to one character.

`line_height` does not shrink `ascent` and `descent`. Those are how far the ink reaches, and they
stay that way: a value below the glyphs' own height reports a smaller box and leaves the clipping to
you, because this engine will not report an extent it did not measure. `line.ascent` is larger than
the font's own ascent whenever a mark reaches above it, and that is deliberate — it is what stops a
caller clipping a fatha.

**Direction is not here.** It is the `base_dir` argument, and putting it in both places would leave
two sources for one decision with no stated precedence.

**Script and language steer feature resolution.** `script` forces every run under one OpenType
script tag, `language` names the tagged language system inside it — each empty for the default
(detection per run, default language system). A BCP 47 code is not a tag (`ur` is not `URD`):
name the tag the font spells.

**Alignment is visual.** `align` puts the line in the target width — `align_width` for a
single line, the wrap width for `wrap_paragraph_with` — left, centered, right, or justified.
Justify stretches spaces by widening advances, except on a uniform Arabic line, where it
inserts U+0640 tatweels at joining gaps (one per gap, lam-alef skipped) and re-lays the text
out. The last wrapped line stays flush, and a target narrower than the line changes nothing.

### Measuring

The two widths a layout engine needs before it draws anything, from one shaping pass.

```v
m := layout.measure_paragraph(ctx, text.runes(), .rtl, fs, 32.0)
m.min_content_width   // narrowest: the widest unbreakable unit
m.max_content_width   // widest: no break taken at all
m.ascent, m.descent, m.line_height
```

`min_content_width` is the narrowest the text can be without a glyph breaking out of it. **It excludes
trailing spaces**, which is the one thing to know about it: a break falls *after* a space, so the
space ends the line before the break, and a width taken from a wrapped line includes one space per
line. At 32 pixels that is 8.77 pixels, about a twentieth of a line at a readable size. Deriving the
number from `wrap_paragraph` gives a minimum width one space too wide on every word.

`max_content_width` is the same number `layout_paragraph` reports as `line.width`, and it is required
to agree with it: both come out of one shaping, and the total of the advances is the furthest the pen
reached because `x` is accumulated as a running sum.

Use `measure_paragraph_with` when the box and the line have to be sized with the same features and the
same spacing. A measurement taken with different options is a measurement of a different line.

### Glyphs

`line.glyphs` is in visual order, left to right, ready to draw back to front.

```v
for g in line.glyphs {
	font := fs.pick(`ب`) or { continue }
	bitmap := font.rasterize(g.gid, 32.0, 0, 0)
	// bitmap.left and bitmap.top position it at g.x and g.y on the baseline
}
```

`g.cluster` is the index of the input character the glyph came from, so a caller can map any glyph
back to the text or to a caret position. A ligature reports the first character it covers. A mark
and its base are both in the list and share an `x`, because a mark is drawn on top of its base rather
than after it.

### Caching glyphs

`Font.rasterize` is pure in (font, gid, size, subpixel offset), so a caller drawing a page
rasterizes each glyph once and reuses the bitmap. `shape.Cache` is that memo with the only
honest key already in it — the caller owns the value, the engine never sees it:

```v
mut cache := shape.new_cache()
for g in line.glyphs {
	font := fs.pick(`ب`) or { continue }
	bitmap := cache.get_or_rasterize(0, font, g.gid, 32.0, 0, 0)
}
```

The `0` is the caller's own id for the font — an index into its own font list does — because
nothing on `Font` is stable across calls. One id must name one font; the cache is unbounded
and `cache.clear()` evicts, with `cache.hits`/`cache.misses` saying when to. Bitmaps share
the cached coverage, so treat them as read-only.

### Wrapping

A paragraph laid out to fit a width, with the input range each line came from. The whole paragraph
is shaped once and the lines are cut out of it, so trying a narrower width costs no extra shaping.

```v
for w in layout.wrap_paragraph(ctx, text.runes(), .rtl, fs, 32.0, 400.0) {
	draw(w.line)         // the glyphs, positioned, ready to draw
	caret_at(w.from, w.to)  // the range of the caller's text this line holds
}
```

Three rules are handled rather than left to the caller: a space never ends a line, a word wider than
the margin goes on a line of its own rather than being split, and a newline ends the paragraph
whatever the width is.

The plain form applies no discretionary features. `wrap_paragraph_with` takes the same `LayoutOptions` as
`layout_paragraph_with`, and it has to: a paragraph wrapped without the features you asked for was
shaped without them while the same text laid out with them was shaped with them, and the two
disagreed about the width of the same text.

`break_opportunities` is the lower half of this, for a caller that wants to decide the width itself
or to draw the opportunities.

`BreakOpportunity` carries one position and one flag, both in your own text. To split a line you
already have, filter its glyphs on the cluster rather than on a glyph index:

```v
for g in line.glyphs {
	if g.cluster >= op.start {
		draw(g)
	}
}
```

`g.cluster` is the index of the input character the glyph came from, so this works in both
directions.

### Case mapping

Full upper, lower and title mappings from the UCD, including the 1-to-N rows
(`ß` to `SS`, `İ` to `i` plus dot) and the Turkish/Azeri dotted-I rows that
make a hand table wrong.

```v
import harfara.shape

upper := shape.to_upper('ß'.runes(), '')          // SS
lower := shape.to_lower('İ'.runes(), '')          // i + dot
lower_tr := shape.to_lower('I'.runes(), 'tr')     // dotless ı
upper_tr := shape.to_upper('i'.runes(), 'tr')     // dotted İ
title := shape.to_title('hello world'.runes(), '') // Hello World
```

The second argument is the locale: `tr`/`az` select the conditional rows,
everything else the unconditional ones. Title is the first cased letter of
each word through the title table and the rest through lower, where a word is
a maximal run of cased letters and a combining mark rides on its base.

### Contextual positioning

A font that moves a glyph based on what is around it. A `true` here means the font has such rules for
a script, not that this engine reaches them.

Two things make this worth reading. Tahoma carries 229 of these and none fire, because its patterns
name glyphs its own GSUB cannot produce: the lookup that would make them is named by no feature, so
they cannot exist however the text is shaped. That is a font bug, and no engine reaches them. The rules
under the `mark` feature are the interesting case, and on the Arabic fonts this engine reads they are
mostly unreachable for the same reason.

Calibri carries 69 chaining lookups and has none of them under any feature of any script. A `true`
answer here can mean a rule that nothing can reach.

```v
if font.contextually_positions('arab', '') {
	// the font has chaining-context rules for this script
}
```

`Gpos.apply_contextual` returns what each matched rule asks for, resolved to a glyph index and a
lookup, so a caller can run the lookups itself and decide the order. The order matters: a later rule is
meant to override an earlier one, and that decision belongs to whoever owns the pipeline.

### Kerning

A font's pair adjustments, which move one glyph when a particular glyph follows it. The two glyphs
are named in the order the text reads them, so a right-to-left pair is the rightmost first, and
`script` names the script because a font may kern one script differently from another.

```v
if off := font.kern_offset(left_gid, right_gid, 'arab', '') {
	// off is in design units; divide by units_per_em and multiply by the pixel size
}

if font.kerns('arab', '') {
	// the font has pair rules for this script
}
```

Ask about the glyphs the pipeline produced rather than the letters in the text. Two letters that join
are shaped into a different glyph, and a lam-alef is one glyph that no pair rule can name.

`context_placement` is the form to use when the two glyphs are known to be adjacent in a run, because a
font can place the same two letters differently depending on what precedes them. A run of three in Arabic
can need three answers that a pair table cannot give.

```v
// gids is the shaped run in logical order; left and right are indices into it.
if off := font.context_placement(gids, 0, 1, 'arab', '') {
	// this pair is placed differently here than it would be two letters into the word
}
```

The rules behind it are counted by `kerns`, so a font whose only kerning is context-sensitive still
reports true. The answer is a placement rather than an advance, because a rule under kern usually is
one.

### Marks

Three tables place a mark, and the API asks which one is meant, because a font may use any of them
for a given pair.

```v
offset := font.mark_offset(mark_gid, base_gid, false)  // over a letter
offset := font.mark_offset(mark_gid, base_gid, true)   // over another mark
```

The offsets are in design units with y upwards, as the font's own coordinates run. A font that has
no rule for the pair returns `none`, and the caller leaves the mark at the pen. The script the
rules are read under is the base letter's; a base with no script of its own — the dotted
circle a dakuten sits on — resolves to the neighbouring strong script, with arab as the last
resort when no strong character is on either side.

### Asking a font what it has

Some questions are about the font rather than about the string. `Font.kerns` asks whether a font kerns;
`Font.kern_offset` asks what it does to a pair. The first is a report and the second is the engine
acting, and they are kept apart. Everything in this section is the first kind.

```v
for t in font.tables() {
    println('${t.tag} at ${t.offset}, ${t.length} bytes')
}
font.has_table('COLR')            // the font has one this engine draws nothing with
font.outlines()                   // 'glyf', 'CFF ', 'CFF2', or ''
font.num_lookups('GPOS')          // the count in the table's own LookupList
font.features('GSUB')             // the FeatureList, sorted
font.scripts('GPOS')              // the ScriptList, sorted
font.cmap_counts()                // mapped codepoints per subtable
font.glyph_class_counts()         // in the order of glyph_class_names
font.is_variable()                // has an fvar table, which is not the same as reading one
font.variable_axes()                // one entry per fvar axis: tag, range, default
font.variable_instances()           // the named instances: UI name, name ID, coords per axis
font.variable_instance_names()      // the names alone, in fvar order
```

`variable_axes` reports the design space; `variable_instances` reports the
named points in it. The records carry only numeric IDs, so the names come from
joining them against the font's `name` table.

`features` reads the FeatureList rather than the features the scripts enable, and those are different
sets. Segoe UI declares 25 tags in GSUB; only 23 are reachable from any default language system,
because `isol` and `locl` are enabled only under a tagged language. A count of 23 would say the font
cannot isolate a letter, which is false. What a *run of text* can reach is asked through
`substitute_glyphs`, and that is a separate question on purpose.

`glyph_class_counts` puts every glyph in `unclassified` when there is no GDEF, so the counts add up to
the glyph count either way.

These are what `tools/fontdump`, `tools/fontcheck` and `tools/shapetrace` are written against, and they
are public because a library that cannot be inspected from outside cannot be diagnosed from outside.

## Building and testing

The build needs V. The scripts are V programs rather than PowerShell ones: the same language means
one set of quoting rules, one idea of a path separator and one idea of an exit code, and a bug in
the runner is then not a bug in anything it was checking.

```sh
v run tools/env.v              # prints the build environment and checks the compiler is there
v run tools/run_tests.v        # runs every _test.v file
v run tools/run_tests.v gpos   # one area, matched as a substring of the file name
v run tools/fmt_check.v        # formatting
```

`run_tests.v` builds one file at a time and gives the compiler a `TMPDIR` of its own: the
compiler's own temporary build directory is shared with every other V build on the machine, so
parallel builds collide in it. Heavy runs set `VJOBS` explicitly (4 here) and never overlap.

The tests read fonts in this order: `$HARFARA_TEST_FONTS`, then the committed corpus under
`testdata/fonts`, then `C:\Windows\Fonts` last and only on Windows. The examples resolve
theirs the same way through `examples/corpus`: `$HARFARA_EXAMPLE_FONTS`, then the corpus,
then the platform directory. On Linux and macOS the corpus is what answers. A font no
directory carries is a skip that says which font and where it looked, never a silent pass.

```sh
v run tools/run.v tools/fontdump.v -- testdata/fonts/Amiri-Regular.ttf
```

`run.v` builds one program and runs it. Everything after a bare `--` goes to the program.

```sh
v run tools/fetch_ucd.v         # the UCD source files; the generated tables are
                                # committed, so a normal build never fetches
```

### Looking at the output in a window

`tools/viewpng.v` opens any of the pictures a tool or an example wrote, with the mouse wheel
scaling about the cursor and the left drag panning:

```sh
v run tools/viewpng.v examples/mark_stack/mark_stack.png
```

There is no window *inside* an example, and that is a toolchain limit rather than a choice. A
program importing both `gg` and `harfara` does not build: each includes `stb_truetype.h` with
`STB_TRUETYPE_IMPLEMENTATION` into V's single generated C translation unit, and C forbids two
definitions of one identifier in one unit regardless of linkage. The viewer is therefore a
separate program that knows nothing about text.

## Notes on the code

Decisions in here worth knowing before changing anything, because each one caused a bug that
looked like something else.

**Decomposition reorders, and the mapping has to travel with it.** NFD moves a mark that was written
after another mark to before it, because a lower combining class sorts first. An index into the
decomposed text is therefore not an index into the caller's text, and `nfd_mapped` returns the
mapping that `layout.v` goes through.

**A lookup table is not the number of things it covers.** A `Coverage` table's count is the number of
ranges, not the number of glyphs, and a `LigatureArray` is indexed through offsets that point at
variable-length structures. Sizes are checked before they are used to allocate.

**A value format is not a field name.** A GPOS `ValueRecord` is variable length, and the bits of the
format say which of four fields are there: `0x0001` is xPlacement, `0x0002` yPlacement, `0x0004`
xAdvance and `0x0008` yAdvance.

**The two pair formats diverge at the sixth field.** Format 1 has a count of `PairSet` tables where
format 2 has two class definitions, and both begin with the same coverage and the same two value
formats.

**Class 0 is a real class.** It is what a glyph gets when no definition names it, and a font that
kerns a class of letters against everything else writes into the class 0 row.

**A positioning record is a pair of indices and nothing else.** There is no count of them and no value
format on the contextual side. Reading one takes a word that belongs to the first record, which shifts
every record by one.

**A record under the kern feature usually names a single positioning, not a pair.** Across the Arabic
fonts here, of the records a kern feature reaches, 186 name a single positioning and 12 name a pair.
Assuming a pair finds no rule and answers nothing on a font whose rules are working perfectly.

**A SinglePos format 1 value comes straight after the format that says how wide it is.** There is no
count of the values, because the coverage already says how many there are.

**A SinglePos format 2 exception is a coverage index, not a glyph id.** The exception list runs to the
end of the subtable; the scan is bounded by the extension's length where there is one, and always by
the coverage. A count equal to the coverage size is the other shape: per-glyph values in coverage
order with no exceptions at all, the way Noto writes its dist singles and Segoe UI its extension-wrapped
ones. Anything else is refused rather than guessed at.

**A rule with a backtrack is about one glyph with a condition.** Its pattern names the glyph being
placed and reaches back to what makes it different. A reader that insists the pattern covers both
discards every rule shaped like this one, and most rules under kern are shaped like it.

**A ligature matcher reads a bounded prefix.** `match_ligature` only ever looks as far as the longest
rule's components, and that bound (`Lookup.longest_ligature`, computed when the lookup is parsed) is
what keeps laying out a paragraph linear rather than quadratic.

## Working with this compiler

Three things this codebase ran into, written down because each one costs an hour to find again and none
of them says where the problem is.

**`m[k] or []T{}` fails on a map whose values are slices.** Asking `if k in m` first compiles and reads
no worse.

**`none` is not available as a name.** It reads as the option's empty value, so a counter called `none`
gives "non-name `none` on left side of `:=`" rather than anything mentioning the name being taken.

**A slice assigned into a struct inside a loop needs `clone()`.** The array is still live at the end of
the iteration, so the struct gets a copy.

## Layout

```
shape/context.v   the text system: decoded tables, shaper and normalizer handles
shape/font.v      the loaded font: metrics, glyph lookup and rasterisation
shape/shaper.v    ScriptShaper registry: per-script defaults, reorder, split
shape/glyphs.v    fallback chain, joining forms, glyph metrics
shape/inspect.v   reporting what a font contains: tables, features, scripts, coverage
shape/joining.v   UAX #53
shape/normalize.v UAX #15
shape/bidi.v      UAX #9
shape/case.v      UCD case mapping with Turkish/Azeri rows
shape/cache.v     caller-owned glyph cache behind the only honest key
font/reader.v     bounds-checked big-endian byte reading
font/sfnt.v       the font file: tables, collections, offsets
font/woff.v       WOFF1 containers, unwrapped to sfnt before parsing
font/woff2.v      WOFF2 containers (brotli inflate + transform rebuild), unwrapped to sfnt
font/textfont.v   text round-trip: sfnt container as canonical text and back, byte-identical
font/textfont_parsed.v   14.1b wave 1 parsed overlays: head/hhea/maxp/hmtx/OS/2/post/name/cmap as begin/end blocks
font/builder.v      14.2a in-memory builder core: set(tag, bytes) per table, build() lays out tag-sorted, 4-aligned, checksummed sfnt with the head adjustment patch
font/build_tables.v   14.2b fixed-size writers: build_head/build_maxp(_05)/build_hhea emit spec-layout bytes for Builder.set
brotli/           module harfara.brotli: pure-V decoder-only subset vendored in-tree,
                  no encoder; WOFF2 inflates through it
font/cmap.v       codepoint to glyph
font/face.v       loads GDEF, GSUB and GPOS for a font
font/gsub.v       OpenType substitution engine; single, ligature and contextual
                  lookups live in gsub_single.v, gsub_ligature.v, gsub_context.v
font/gpos.v       OpenType positioning engine with GDEF; pair, single, mark,
                  cursive and contextual lookups live in gpos_pair.v,
                  gpos_single.v, gpos_mark.v, gpos_cursive.v, gpos_context.v
font/stbtt.c.v    the stb_truetype rasteriser, vendored and public domain
layout/layout.v   the pipeline
layout/kern.v     pair kern, vertical kern, single positioning
layout/marks.v    mark placement: anchors plus chaining singles
layout/place.v    spacing, placing, measuring
layout/profiler.v opt-in per-stage shaping profiler
layout/linebreak.v UAX #14, wrapping, and measuring a paragraph's two widths

trace_api.v     the pipeline's stages, reached one at a time for shapetrace

ucd/            module harfara.ucd: tables.v (decode once into Properties),
                properties.v (hand-written enums and lookups), and the
                ucd_*.v files generated from the UCD by the tools in tools/,
                committed so a build needs no fetch
ucd/ucd_names.v codepoint names, front coded: the suffixes and the shared prefix lengths
```

The tools are in `tools/`, the examples in `examples/`, and `ucd/` holds the Unicode Character Database
files that are redistributed here. See `LICENSE` for which licence covers what.

`providers/` holds the per-OS font lookup (fontconfig on Linux); nothing links
it by default.

## Licence

Two licences, because the tree holds two kinds of thing.

The source is MIT. The Unicode Character Database files under `ucd/` are Unicode, Inc.'s and are
redistributed unchanged under UNICODE LICENSE V3, whose text is in `ucd/LICENSE-UNICODE.txt`. That licence
grants redistribution only on the condition that the notice travels with the files, which is why the licence
is committed rather than downloaded: `tools/fetch_ucd.v` does not fetch it.

The generated tables in `ucd/ucd_*.v` are derived from those files and are covered by the MIT licence above. A
derivative of the data would have to carry the data's terms for the same reason, so those tables are kept
out of the MIT grant rather than quietly inside it; the notice travels with the sources they came from, in
the same directory tree and in the same commit.

`ucd/ucd_*.v` are generated character data and are not edited by hand.
