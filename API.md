# HarfAra API reference

The caller-facing API of HarfAra: the V modules (`import harfara.*`). The
module is lowercase `harfara`; the brand is HarfAra. This file is the
reference; `README.md` is the tour and `USAGE.md` is the build-and-use guide.

Every signature here is taken from the tree, not invented. Where a part has a
conformance baseline, `ROADMAP.md` names it. Lower-level parsers and lookup
helpers are public too (the inspection tools are written against them); this
reference leads with the calls a caller reaches for and notes the deeper layer.

## Contents

- [Module map](#module-map)
- [Conventions](#conventions)
- [V API — shape](#v-api--shape)
- [V API — layout](#v-api--layout)
- [V API — raster](#v-api--raster)
- [V API — font, providers, subset, ucd](#v-api--font-providers-subset-ucd)

## Module map

| Import | Owns | Replaces |
| --- | --- | --- |
| `harfara.ucd` | Generated Unicode tables, decoded once into `Properties` | — (shared data) |
| `harfara.font` | Font data: sfnt/TTC/WOFF1/WOFF2 read (WOFF2 write refused, no encoder), cmap, metrics, GSUB/GPOS, variation stores, the raster backend, text round-trip | FreeType load side, fontTools read side |
| `harfara.brotli` | Pure-V decoder-only brotli subset vendored in-tree; WOFF2 inflates through it | brotli's decoder |
| `harfara.shape` | `Context`, `Font`/`FontSet`/`Glyph`, normalization, bidi, joining, case mapping, inspection, cache | HarfBuzz core |
| `harfara.layout` | Line breaking, wrapping, measuring, alignment, vertical columns, log attrs, iterators | Pango layout math |
| `harfara.raster` | `GlyphBitmap` and the box-and-fill contract; color, LCD, synth, stroke, grid-fit, packing, quantize | FreeType render side, fontstash/stb coverage |
| `harfara.providers` | Per-OS font lookup (fontconfig / Core Text / DirectWrite) + generic discovery | fontconfig |
| `harfara.subset` | Glyph closure and font rebuild (glyf + CFF) | fontTools subsetter |
| `harfara` (root) | `trace_api.v` (stage-by-stage tracing) | — |

Dependencies run one way: `layout` → `shape` → `font` → `ucd`, with `raster` a
leaf below `font`. No part imports a tool. The import-direction ratchet
(`modularity_test.v`) enforces this on every run.

## Conventions

- **Fallible calls** return `!T` (an error you handle with `or { … }` or propagate
  with `!`) or `?T` (an optional: a value or `none`). A `?` answer of `none` is a
  result, not a failure — e.g. a font with no kerning rule for a pair.
- **Pixels vs design units.** Anything taking `em_px` works in pixels (the size of
  an em square). The raw OpenType queries `kern_offset`, `mark_offset`,
  `single_adjustment` and the MATH/variable helpers return **design units**: divide
  by `units_per_em()` and multiply by the pixel size to place them.
- **Ownership.** V values are reference-counted by the language; a `Font` loaded
  from a file owns its bytes.
- **The engine ends at a positioned glyph with a coverage bitmap.** Boxes, the
  cascade, painting and the glyph cache belong to the caller.

## V API — shape

`import harfara.shape`

### Context and fonts

```v
ctx := shape.new_context()                       // &Context — shared shaping state
font := shape.load_font_file('Amiri-Regular.ttf') or { panic(err) }  // !&Font
font := shape.load_font_bytes(data) or { panic(err) }                // !&Font
```

`Context` holds the decoded UCD `Properties` and the normalizer; create one and
reuse it across lines. `load_font_file`/`load_font_bytes` accept sfnt, TTC, WOFF1,
and WOFF2 (read; WOFF2 write is refused, no encoder lives in this tree).

### FontSet — the fallback chain

```v
fs := shape.new_font_set()                 // empty ordered chain
fs := shape.new_font_set_of(a, b, c)       // variadic convenience
fs.add(font)                               // append; first coverage wins
fs := shape.new_script_font_set(arabic, latin)  // route by script, not coverage
```

| Call | Answer |
| --- | --- |
| `fs.pick(cp rune) ?&Font` | first font covering `cp` (flat coverage order) |
| `fs.pick_in(ctx, cp) ?&Font` | script-aware pick (a script set routes by what the text is) |
| `fs.pick_script(ctx, cp, script) ?&Font` | pick under an explicit script |
| `fs.covers(cp) bool` | any font in the set has the glyph |
| `fs.len() int` | number of fonts |
| `fs.glyph(cp, em_px) Glyph` / `fs.glyph_in(ctx, cp, em_px) Glyph` | a positioned-ready `Glyph` for `cp` |

A per-script set with no primary/general is exactly a flat set, so `pick` and
`pick_in` agree in that case. The script test is the same generated table the
joining pass uses.

### Font — metrics, lookup, rasterization

`shape.Font` wraps a loaded face. The common calls:

```v
font.units_per_em() int
font.num_glyphs() int
font.is_monospaced() bool
font.ascent(em_px) f64
font.descent(em_px) f64
font.line_height(em_px) f64
font.glyph_index(cp rune) u16          // 0 is .notdef
font.codepoint_for(gid) ?rune          // reverse map; lowest codepoint, none for gid 0
font.has_glyph(cp) bool
font.glyph_advance(gid, em_px) f64     // pixels
font.rasterize(gid, em_px, sub_x, sub_y) raster.GlyphBitmap
```

Variation sequences (emoji vs text presentation):

```v
font.glyph_index_variation(cp rune, selectors []rune) u16  // no selector == glyph_index
font.has_variation_sequence(cp, selector) bool             // does this font know the pair
```

Variable fonts:

```v
font.set_var_coords(coords []f64) !     // instance at caller-chosen axis coordinates
font.var_coords() []f64
font.instanced_glyph_points(gid) !font.InstancedOutline
```

### Font — shaping queries (design units)

These ask what the font's OpenType rules do; they are reports and engine actions,
kept apart from the pipeline that applies them.

```v
font.kerns(script, lang) bool
font.kern_offset(left_gid, right_gid, script, lang) ?font.Offset2
font.vkern_offset(left_gid, right_gid, script, lang) ?font.Offset2   // vertical
font.context_placement(gids []u16, left, right, script, lang) ?font.Offset2
font.contextually_positions(script, lang) bool
font.mark_offset(mark_gid, base_gid, base_is_mark) ?font.Offset2
font.mark_offset_in(mark_gid, base_gid, base_is_mark, script, lang) ?font.Offset2
font.cursive_anchors(gid, script, lang) ?font.CursiveAnchors   // read, not applied
font.single_adjustment(gid, script, lang, extra, vertical) ?font.PairValue
font.shaped_glyph_index(gid, form, script, lang) u16
font.substitute_glyphs(glyphs, script, lang, em_px, …)         // what a run can reach
```

Ask about the glyphs the pipeline produced, not the letters in the text: two
letters that join shape into a different glyph, and a lam-alef is one glyph no
pair rule can name.

### Font — inspection

```v
font.tables() []TableInfo
font.has_table(tag) bool
font.outlines() string                  // 'glyf', 'CFF ', 'CFF2', or ''
font.num_lookups(table) int
font.features(table) []string           // the FeatureList, sorted
font.scripts(table) []string
font.cmap_counts() []int
font.glyph_class_counts() [5]int
font.is_variable() bool
font.variable_axes() []font.VariableAxis
font.variable_instances() []NamedInstance
font.variable_instance_names() []string
font.has_math() bool
font.math_pass(enabled) ?MathPass
```

`features` reads the FeatureList, not the features a run can reach — those differ
(a tag may be enabled only under a tagged language). What a *run* reaches is asked
through `substitute_glyphs`.

### Case mapping

```v
shape.to_upper(cps []rune, locale string) []rune
shape.to_lower(cps []rune, locale string) []rune
shape.to_title(cps []rune, locale string) []rune
```

Full UCD mappings including the 1-to-N rows (`ß`→`SS`) and the Turkish/Azeri
dotted-I rows. `locale` of `tr`/`az` selects the conditional rows; anything else
the unconditional ones.

### Cache — caller-owned glyph memo

```v
mut cache := shape.new_cache()
bm := cache.get_or_rasterize(font_id, font, gid, em_px, sub_x, sub_y)
cache.len() int
cache.clear()
```

`Font.rasterize` is pure in (font, gid, size, subpixel offset), so the caller
rasterizes each glyph once and reuses the bitmap. `font_id` is the caller's own
stable id for the font (nothing on `Font` is stable across calls). The cache is
unbounded; `clear()` evicts. Bitmaps share the cached coverage — treat them as
read-only. The engine never sees the cache.

## V API — layout

`import harfara.layout`

### Lay out, wrap, measure

```v
line := layout.layout_paragraph(ctx, cps, base_dir, fs, em_px)                 // Line
line := layout.layout_paragraph_with(ctx, cps, base_dir, fs, em_px, &opts)     // Line

lines := layout.wrap_paragraph(ctx, cps, base_dir, fs, em_px, max_width)       // []WrappedLine
lines := layout.wrap_paragraph_with(ctx, cps, base_dir, fs, em_px, max_width, &opts)
lines := layout.wrap_paragraph_with_policy(ctx, cps, base_dir, fs, em_px, max_width, &opts, policy)

m := layout.measure_paragraph(ctx, cps, base_dir, fs, em_px)                   // TextMetrics
m := layout.measure_paragraph_with(ctx, cps, base_dir, fs, em_px, &opts)

ops := layout.break_opportunities(ctx, cps, mandatory_first)                   // []BreakOpportunity
line := layout.ellipsize_line(ctx, cps, base_dir, fs, em_px, max_width, &opts, mode)
```

- `cps []rune` is the caller's text; `base_dir` is `shape.Direction` (`.ltr`,
  `.rtl`, `.auto` reads the first strong character). Direction is an argument, not
  an option — one source for one decision.
- The whole paragraph is shaped once and lines are cut out of it, so trying a
  narrower width costs no extra shaping.
- `measure_paragraph` reports `min_content_width` (widest unbreakable unit,
  **excluding trailing spaces**) and `max_content_width` (no break taken; equals
  `layout_paragraph`'s `line.width`). Use the `_with` form when the box and the line
  must be sized with the same features/spacing.
- Wrapping handles three rules rather than leaving them to the caller: a space
  never ends a line, an over-wide word goes on a line of its own, and a newline
  ends the paragraph whatever the width.

### LayoutOptions

`layout.LayoutOptions` (all fields `pub mut`; the zero value is the defended
default — `calt`/`liga`/`clig` on, everything else off):

| Field | Type | Meaning |
| --- | --- | --- |
| `features` | `[]string` | discretionary features; `-tag` turns a default off, `+tag` names one |
| `script` | `string` | force every run under one OpenType script tag (empty = detect) |
| `language` | `string` | tagged language system (`'URD'`, not BCP 47 `ur`; empty = default) |
| `line_height` | `f64` | baseline-to-baseline px; 0 takes the font's own |
| `letter_spacing` | `f64` | added to each letter's advance (marks get none) |
| `word_spacing` | `f64` | added to each space's advance |
| `vertical` | `bool` | one column of vertical text |
| `align` | `Align` | `.left` `.center` `.right` `.justify` |
| `align_width` | `f64` | target width for a single line (wrapped lines use the wrap width) |
| `wrap_mode` | `WrapMode` | `.word` `.char` `.word_char` |
| `tab_stops` | `[]f64` | visual x positions a tab advances to (empty disables) |

Justify stretches spaces, except on a uniform Arabic line where it inserts U+0640
tatweels at joining gaps and re-lays the text. The last wrapped line stays flush.

### Result types

```v
pub struct Line {
    glyphs []shape.Glyph   // visual order, ready to draw
    width f64              // total advance (column width in vertical mode)
    height f64             // column length (0 in horizontal mode)
    ascent, descent f64    // ink extent, marks included
    paragraph_level u8     // even = LTR, odd = RTL
    line_height f64        // resolved baseline-to-baseline distance
}

pub struct WrappedLine { line Line; from int; to int }   // half-open input range
pub struct TextMetrics { min_content_width, max_content_width, ascent, descent, line_height f64 }
pub struct BreakOpportunity { start int; is_mandatory bool; hyphen bool }

pub struct Glyph {
    gid u16; advance f64; x f64; y f64
    cluster int      // index of the input character this glyph came from
    is_mark bool     // shares its base's position, no advance
}
```

`g.cluster` maps a glyph back to the text / a caret position; a ligature reports
the first character it covers. To split a line you already have, filter glyphs on
`cluster`, not on a glyph index.

### Text segmentation and iterators

```v
layout.log_attrs(ctx, cps) []LogAttr                 // per-char caret/word/sentence flags
layout.grapheme_breaks(ctx, cps, opt) []bool
layout.word_breaks(cps, layout.word_tables(), opt) []bool
layout.sentence_breaks(cps, layout.sentence_tables(), opt) []bool
layout.advance_quads(line, atlas_w, atlas_h, origin) []GlyphQuad   // visual-order quads
layout.line_ink_box(line) (f64, f64, f64, f64)
```

## V API — raster

`import harfara.raster`

The contract is **box-and-fill**: `box_only` reports the ink box, `render_into`
fills a caller buffer. `Font.rasterize` returns a `GlyphBitmap`:

```v
pub struct GlyphBitmap {
    coverage []u8   // row-major, width*height bytes; 0 empty, 255 solid
    width, height int
    left int        // ink reach left of the pen
    top int         // ink reach above the baseline, positive up
}
bm.is_empty() bool
bm.ink(x, y) u8
```

Caller-owned generics (no FONS types, no hidden atlas):

| Area | Calls |
| --- | --- |
| Packing | `new_pack_atlas(w, h)`, `atlas.insert(w, h) ?(int, int)`, `atlas.reset(w, h)` |
| Quantize | `quantize_mono/gray2/gray4(src)`, `gamma_lut(contrast, gamma)`, `apply_lut(src, table)`, `blur_bitmap(src, radius)` |
| Synth | `apply_synth(src, opt)`, `embolden_bitmap(src, strength_px)`, `oblique_bitmap(src, slant)` |
| LCD | `to_lcd(src)`, `render_with_options(src, opt)` |
| Color | `tint_bitmap(src, rgba)`, `composite_layers(layers)`, `flatten_alpha(src)` |
| Grid-fit | `grid_fit_bitmap(src)`, `grid_fit_bitmap_opt(src, opt)`, `fit_bitmap_to_box(src, box)` |
| Stroke | `stroke_outline(xs, ys, on_curve, end_pts, opt)`, `stroke_open_polyline(xs, ys, opt)` |

## V API — font, providers, subset, ucd

### font (the data layer)

`import harfara.font` — mostly reached through `shape.Font`, but public for tools:
`parse_sfnt(data) !Sfnt`, `woff_to_sfnt(data) ![]u8`, `new_reader(data) Reader`
(bounds-checked big-endian reads), the GSUB/GPOS engines (`new_gsub`, `Gpos`
methods), variable instancing (`var_instance_glyph`, `var_blend_coords`), and the
stb_truetype backend (`Face.box_only`, `Face.render_into`, `Face.rasterize_glyph`).
CFF2 has a full pipeline now (inspection reader in `font/cff2.v`, raster backend
in `font/cff2raster.v`, non-default instancing over the shared VarStore reader,
subset rebuild in `subset/cff2.v`). Text round-trip
(`font/textfont.v`): `textfont_dump(data) !string` renders the sfnt container
as canonical text (version, size, search fields, then one `table` line per
table with file offset and raw hex), and `textfont_load(text) ![]u8` rebuilds
byte-identical bytes — directory order, offsets, zero padding, recomputed
checksums and head adjustment. TTC and WOFF containers are refused with the
reason (unwrap first). Parsed overlays (`font/textfont_parsed.v`, 14.1b wave
1): head, hhea, maxp, hmtx, OS/2, post, name and cmap additionally travel as
`begin TAG ... end TAG` blocks grouped after the table lines, in directory
order — kebab-case decimal fields, 16.16 Fixed as exact decimals, codepoints
as `0x` hex, byte runs as lowercase hex. Load rebuilds each block and refuses
any disagreement with the raw line; unknown blocks error, missing blocks fall
back to raw. Glyf, CFF, GSUB, GPOS and the rest stay raw.

### providers (optional, never linked by default)

`import harfara.providers`

```v
providers.discovery_order(inp DiscoveryInput) []string   // generic search order
providers.pick_first(cands, is_readable) string
providers.variant_path(font_path, kind) string
// Per-OS, each pinned on its own OS and answering none elsewhere:
providers.system_font(family) ?SystemFont                 // fontconfig / Core Text / DirectWrite
providers.system_fonts_sorted(family, limit) ?[]SystemFont // Linux ranked sort
```

### subset

`import harfara.subset`

```v
subset.subset_font(font, seed []u16) !Subset   // rebuild around the seed glyphs
subset.subset_cff_font(font, seed) !Subset     // CFF rebuild
subset.spans_of(font) map[string]Span
```

glyf and CFF rebuilds land; CFF2/CID are refused with the reason. `.notdef` is
always kept. The result loads back through `load_font_bytes`; the tool verifies by
reloading.

### ucd

`import harfara.ucd`

```v
props := ucd.new_properties()                 // decode the generated tables once
props.bidi_class_of(cp) BidiClass
props.joining_type_of(cp) JoiningType
props.script_tag_of(cp) string
props.line_break_of(cp) LineBreakClass
props.combining_class_of(cp) int
props.is_arabic_script(cp) bool
props.is_mark(cp) bool
```

No other part reads the UCD directly; they go through `Properties`.

## Stability

- `LayoutOptions` fields are **append-only**: new fields go at the end so
  existing offsets never move.
- The rebrand from `vtext` (2026-11-23) moved import paths and symbol names; the
  published v0.1.0 release keeps the old `vtext` names.
