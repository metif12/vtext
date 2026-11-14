# Goal

One library that does the whole text job — load, shape, lay out, rasterize,
inspect, subset — where each job is a separate part with its own API, its own
conformance baseline, and its own reason to exist. A caller uses one part or
all of them; nothing is pulled in by accident.

That sentence is the architecture. "Replacement" is claimed per part, against
the incumbent for that part, and measured the way this repository already
measures everything else: shaping against HarfBuzz, line breaking against the
Unicode committee's own test, rasterization against FreeType and Pillow, with
every remaining difference recorded with its reason. A part with no baseline
is a part with no claim.

## The parts and what each one replaces

| Part | Replaces | Objective |
| --- | --- | --- |
| `vtext.ucd` | — (shared data) | Generated UCD tables, decoded once into `Properties`. No other part reads the UCD directly. Done 2026-11-13. |
| `vtext.font` | FreeType's loading side, fontTools' reading side | sfnt/TTC containers, cmap, metrics, variation-store reading, instancing. Slice 1 landed 2026-11-14: sfnt, cmap and the reader live in `font/` as `module font`, green across the suite, both difftest hosts and the 1 MB smoke. Slice 2 landed the same day: Face, GSUB/GPOS/GDEF, stb bindings, GlyphBitmap, JoiningForm; verified the same full way. Slices 4+5 (same day, one commit — slice 4 alone does not compile) moved the last `vtext`-side pieces out around it: the `Font`/`FontSet`/`Glyph` wrappers, `Context` and `inspect.v` to `shape/`, line breaking and layout to `layout/`; `font/` itself unchanged. |
| `vtext.shape` | HarfBuzz core | Normalization, bidi, joining, GSUB/GPOS incl. contextual formats, instancing consumers. Slice 1 landed 2026-11-14: joining, normalize, bidi, bidi_rules, brackets in `shape/`, verified the full way. Slice 2 landed the same day: `Context` with `new_context`/`normalize_nfd`/`shape_for_trace`, `Font` with the load delegates, `Glyph`/`FontSet`, and `inspect.v` in `shape/` as `module shape`; the `Font`/`Context`/`Glyph`/`FontSet` knot dissolved into `shape/` (the HarfBuzz-core home) after proving a layout/-only move cycles through `capi.v`. |
| `vtext.layout` | Pango's layout math | Slices 4+5 landed 2026-11-14: `linebreak.v` and `layout.v` live in `layout/` as `module layout`; dependencies run `layout` → `shape` → `font` → `ucd` with `capi` over all, and the root module is tests plus `capi.v`/`trace_api.v`. Vertical text, kashida/justification as opt-in, and hyphenation dictionaries as a `BreakPolicy` remain. |
| `vtext.raster` | FreeType's rendering side | Unhinted stb today; hinting (TT interpreter + auto-hinter fallback) and color (COLR/CPAL, CBDT/sbix) as engines behind one box-and-fill contract. Slice 1 landed 2026-11-14: `GlyphBitmap` with `is_empty`/`ink` lives in `raster/` as `module raster`; the `box_only`/`render_into` calls stay methods on `font.Face` because methods live in the type's own module, so `font` imports the leaf `raster` for the data they trade in. |
| `vtext.inspect` | fontTools introspection (read side) | Already the tool surface (`fontdump`, `fontcheck`, `shapetrace`); promoted to a library part. |
| `vtext.subset` | fontTools subsetter | `tools/subset.v` promoted to a library; glyf today, CFF/CFF2 after the charstring reader exists. First of the three named API gaps closed 2026-11-14: `Font.data()` returns the bytes the face was parsed from, and the tool subsets a memory font the same way it subsets a path. |
| `vtext.capi` | — (the C face of all of the above) | Opaque handles over every part; `vtext.h` stays the single header. |
| providers | fontconfig / Core Text / DirectWrite | Per-OS `FontSource` implementations, optional, never linked by default. |

Dependencies run one way: `layout` → `shape` → `font` → `ucd`, with `raster` a leaf below `font`; `capi` → all;
nothing depends upward. A part never imports a tool, and no tool is imported.

The seams that keep the parts combinable, each an explicit interface rather
than an argument about taste, are `FontSource` (where fonts come from),
`RasterBackend` (box-for-gid plus fill-this-buffer), `BreakPolicy` (UAX #14
default today, dictionaries tomorrow), the caller-owned glyph cache (keyed on
font id, gid, size, subpixel), and per-part options structs on the proven
`LayoutOptions` pattern.

## Explicitly not goals

Worth writing down so that scope arguments end by quoting this file.

- A text editor, or any interactive application. The library is a library.
- A layout engine for boxes, flex, or CSS. Line breaking is the most the text
  layer needs and no further.
- HarfBuzz bindings, or a port of anything. Every part is written from the
  specifications.
- Font authoring. vtext reads fonts, subsets them, and reports on them; it
  does not build them (`otLib`-side tooling stays out).
- Variable font instancing (generating instances). Reading the variation
  store belongs to `vtext.font` because the hints depend on it; generating
  new instances has no caller here.

The last three of the old list changed status on purpose: kashida and
justification are `vtext.layout` features now, hyphenation dictionaries are
a `BreakPolicy` with generated tables, and system font discovery is a
provider rather than a refusal. What did not change: the engine ends at a
positioned glyph with a coverage bitmap, and the cache stays with the caller.
