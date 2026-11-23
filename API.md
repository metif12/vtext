# HarfAra API reference

The caller-facing API of HarfAra, in two faces: the V modules (`import harfara.*`)
and the C ABI (`harfara.h`). The module and the C symbols are lowercase `harfara`;
the brand is HarfAra. This file is the reference; `README.md` is the tour and
`USAGE.md` is the C build-and-ownership guide.

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
- [C API](#c-api)

## Module map

| Import | Owns | Replaces |
| --- | --- | --- |
| `harfara.ucd` | Generated Unicode tables, decoded once into `Properties` | — (shared data) |
| `harfara.font` | Font data: sfnt/TTC/WOFF1, cmap, metrics, GSUB/GPOS, variation stores, the raster backend | FreeType load side, fontTools read side |
| `harfara.shape` | `Context`, `Font`/`FontSet`/`Glyph`, normalization, bidi, joining, case mapping, inspection, cache | HarfBuzz core |
| `harfara.layout` | Line breaking, wrapping, measuring, alignment, vertical columns, log attrs, iterators | Pango layout math |
| `harfara.raster` | `GlyphBitmap` and the box-and-fill contract; color, LCD, synth, stroke, grid-fit, packing, quantize | FreeType render side, fontstash/stb coverage |
| `harfara.providers` | Per-OS font lookup (fontconfig / Core Text / DirectWrite) + generic discovery | fontconfig |
| `harfara.subset` | Glyph closure and font rebuild (glyf + CFF) | fontTools subsetter |
| `harfara` (root) | `capi.v` (the C face) and `trace_api.v` (stage-by-stage tracing) | — |

Dependencies run one way: `layout` → `shape` → `font` → `ucd`, with `raster` a
leaf below `font`; the root `capi` imports all. No part imports a tool. The
import-direction ratchet (`modularity_test.v`) enforces this on every run.

## Conventions

- **Fallible calls** return `!T` (an error you handle with `or { … }` or propagate
  with `!`) or `?T` (an optional: a value or `none`). A `?` answer of `none` is a
  result, not a failure — e.g. a font with no kerning rule for a pair.
- **Pixels vs design units.** Anything taking `em_px` works in pixels (the size of
  an em square). The raw OpenType queries `kern_offset`, `mark_offset`,
  `single_adjustment` and the MATH/variable helpers return **design units**: divide
  by `units_per_em()` and multiply by the pixel size to place them.
- **Ownership.** V values are reference-counted by the language; a `Font` loaded
  from a file owns its bytes. In the C ABI, anything returned as a pointer is owned
  by the caller and freed with the matching `*_free`, except where the comment says
  *borrowed*. See [C API](#c-api).
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
reuse it across lines. `load_font_file`/`load_font_bytes` accept sfnt, TTC and
WOFF1; WOFF2 is refused with the reason.

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
CFF2 has a separate inspection reader (`font/cff2.v`): default-instance outlines
only; no raster backend or subset rebuild yet.

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

## C API

`harfara.h` is the single header; `capi.v` implements it; `harfara.def` lists the
50 entry points for import-library generation. `tools/capicheck.v` proves the three
agree in both directions on every CI run.

### Build and link

```sh
v -shared -gc none -cc gcc -o libharfara.so .     # Linux
v -shared -gc none -cc clang -o libharfara.dylib . # macOS
v -shared -gc none -cc gcc -o harfara.dll .        # Windows
```

`-gc none` is load-bearing: with the Boehm collector the library would free objects
the C caller still holds. On Windows, build an import library from the def file:
`dlltool -d harfara.def --dllname harfara.dll -l libharfara.dll.a`. See `USAGE.md`
for the per-platform details and the caller-thread stack requirement.

### Conventions

- **Direction macros:** `HARFARA_LTR` (0), `HARFARA_RTL` (1), `HARFARA_AUTO` (2).
- **Error buffer:** fallible functions take `char *err, int errcap` and write a
  sentence on failure; a null buffer or no room drops the sentence rather than
  writing past the end. They return null / 0 / -1 on failure.
- **Ownership:** anything returned as a pointer is owned by the caller and freed
  with the matching `*_free`, except where noted *borrowed*. Anything taken as a
  pointer is borrowed and must outlive the call.

### Types

Opaque handles: `harfara_context_t`, `harfara_fontset_t`, `harfara_font_t`,
`harfara_line_t`, `harfara_wrap_t`, `harfara_bitmap_t`.

Plain structs:

```c
harfara_options_t   // mirrors LayoutOptions; fields append-only, offsets never move
harfara_glyph_t     // uint16_t gid; double advance, x, y; int cluster, is_mark
harfara_metrics_t   // double min_content_width, max_content_width, ascent, descent, line_height
harfara_breaks_t    // int *starts; int *mandatory; int len
```

`harfara_options_t` fields: `features` (comma-separated, NULL ok), `line_height`,
`letter_spacing`, `word_spacing`, `vertical`, `script`, `language`, `align`
(0 left / 1 center / 2 right / 3 justify), `align_width`, `wrap_mode` (0 word /
1 char / 2 word_char), `tab_stops`, `num_tab_stops`.

### Function reference (50 exports)

**Version / context**
```c
const char *harfara_version(void);
harfara_context_t *harfara_context_new(void);
void harfara_context_free(harfara_context_t *ctx);
```

**Font load / free**
```c
harfara_font_t *harfara_font_load_file(const char *path, char *err, int errcap);
harfara_font_t *harfara_font_load_bytes(const unsigned char *data, int len, char *err, int errcap);
void harfara_font_free(harfara_font_t *font);
```

**Font set** (the set borrows the fonts)
```c
harfara_fontset_t *harfara_fontset_new(void);
harfara_fontset_t *harfara_fontset_new_script(harfara_font_t *primary, harfara_font_t *general, char *err, int errcap);
void harfara_fontset_free(harfara_fontset_t *fs);
int harfara_fontset_add(harfara_fontset_t *fs, harfara_font_t *font, char *err, int errcap);   // 1 ok / 0 err
harfara_font_t *harfara_fontset_add_file(harfara_fontset_t *fs, const char *path, char *err, int errcap);
```

**Font metrics / lookup**
```c
int harfara_font_units_per_em(harfara_font_t *font);
double harfara_font_ascent(harfara_font_t *font, double em_px);
double harfara_font_descent(harfara_font_t *font, double em_px);
double harfara_font_line_height(harfara_font_t *font, double em_px);
int harfara_font_is_monospace(harfara_font_t *font);
uint16_t harfara_font_glyph_index(harfara_font_t *font, uint32_t cp);
int harfara_font_has_glyph(harfara_font_t *font, uint32_t cp);
int harfara_font_set_var_coords(harfara_font_t *font, const double *coords, int ncoords,
    char *err, int errcap);   // design units, one per fvar axis; 1 ok / 0 err
```

**Layout**
```c
harfara_line_t *harfara_layout(harfara_context_t *ctx, const char *text, int len, int dir,
    harfara_fontset_t *fs, double em_px, char *err, int errcap);
harfara_line_t *harfara_layout_with(..., const harfara_options_t *opts, char *err, int errcap);
void harfara_line_free(harfara_line_t *line);
int harfara_line_glyph_count(harfara_line_t *line);
int harfara_line_glyph(harfara_line_t *line, int i, harfara_glyph_t *out);   // 1 fills / 0 out of range
harfara_font_t *harfara_line_glyph_font(harfara_line_t *line, int i);        // borrowed from the set
double harfara_line_width(harfara_line_t *line);
double harfara_line_ascent(harfara_line_t *line);
double harfara_line_descent(harfara_line_t *line);
double harfara_line_height(harfara_line_t *line);
double harfara_line_column_height(harfara_line_t *line);
```

**Wrap**
```c
harfara_wrap_t *harfara_wrap(harfara_context_t *ctx, const char *text, int len, int dir,
    harfara_fontset_t *fs, double em_px, double max_width, char *err, int errcap);
harfara_wrap_t *harfara_wrap_with(..., const harfara_options_t *opts, char *err, int errcap);
void harfara_wrap_free(harfara_wrap_t *w);
int harfara_wrap_line_count(harfara_wrap_t *w);
harfara_line_t *harfara_wrap_line(harfara_wrap_t *w, int i);   // borrowed until wrap_free
int harfara_wrap_line_from(harfara_wrap_t *w, int i);
int harfara_wrap_line_to(harfara_wrap_t *w, int i);
```

**Measure**
```c
int harfara_measure(harfara_context_t *ctx, const char *text, int len, int dir,
    harfara_fontset_t *fs, double em_px, harfara_metrics_t *out, char *err, int errcap);
int harfara_measure_with(..., const harfara_options_t *opts, harfara_metrics_t *out, char *err, int errcap);
```

**Break opportunities**
```c
harfara_breaks_t *harfara_breaks(harfara_context_t *ctx, const char *text, int len,
    int mandatory_first, char *err, int errcap);
void harfara_breaks_free(harfara_breaks_t *b);
```

**Rasterize**
```c
harfara_bitmap_t *harfara_rasterize(harfara_font_t *font, uint16_t gid, double em_px,
    int sub_x, int sub_y, char *err, int errcap);
void harfara_bitmap_free(harfara_bitmap_t *bm);
int harfara_bitmap_width(harfara_bitmap_t *bm);
int harfara_bitmap_height(harfara_bitmap_t *bm);
int harfara_bitmap_left(harfara_bitmap_t *bm);
int harfara_bitmap_top(harfara_bitmap_t *bm);
const unsigned char *harfara_bitmap_data(harfara_bitmap_t *bm);   // borrowed, width*height bytes
```

**Subset**
```c
int harfara_subset(harfara_font_t *font, const unsigned short *seed, int nseed,
    unsigned char **out, char *err, int errcap);   // malloc'd bytes + count, -1 on error
void harfara_subset_free(unsigned char *bytes);
```

The subset bytes load with `harfara_font_load_bytes`; `.notdef` is always kept.

### Minimal C program

```c
#include "harfara.h"
char err[512];
harfara_context_t *ctx = harfara_context_new();
harfara_fontset_t *fs = harfara_fontset_new();
harfara_fontset_add_file(fs, "Amiri-Regular.ttf", err, sizeof(err));
harfara_line_t *line = harfara_layout(ctx, text, len, HARFARA_AUTO, fs, 32.0, err, sizeof(err));
for (int i = 0; i < harfara_line_glyph_count(line); i++) {
    harfara_glyph_t g;
    harfara_line_glyph(line, i, &g);
    harfara_font_t *f = harfara_line_glyph_font(line, i);
    harfara_bitmap_t *bm = harfara_rasterize(f, g.gid, 32.0, 0, 0, err, sizeof(err));
    /* draw bm at g.x, g.y ... */
    harfara_bitmap_free(bm);
}
harfara_line_free(line);
harfara_fontset_free(fs);
harfara_context_free(ctx);
```

`examples/c-api/smoke.c` exercises the whole surface end to end and is the shape of
a real C program using the library; CI builds and runs it on all three platforms.

## Stability

- `harfara_options_t` / `LayoutOptions` fields are **append-only**: new fields go at
  the end so existing offsets never move.
- The C ABI version is the string `harfara_version()` returns; a release tag must
  match it and `v.mod` (the `release-c` workflow gates this).
- The rebrand from `vtext` (2026-11-23) moved import paths and C symbol names; the
  published v0.1.0 release keeps the old `vtext` names.
