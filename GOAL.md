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
| `vtext.font` | FreeType's loading side, fontTools' reading side | sfnt/TTC containers, cmap, metrics, variation-store reading, instancing. |
| `vtext.shape` | HarfBuzz core | Normalization, bidi, joining, GSUB/GPOS incl. contextual formats, instancing consumers. |
| `vtext.layout` | Pango's layout math | Line breaking, wrapping, measuring, fallback chains, vertical text, kashida/justification, hyphenation. |
| `vtext.raster` | FreeType's rendering side | Unhinted stb today; hinting (TT interpreter + auto-hinter fallback) and color (COLR/CPAL, CBDT/sbix) as engines behind one box-and-fill contract. |
| `vtext.inspect` | fontTools introspection (read side) | Already the tool surface (`fontdump`, `fontcheck`, `shapetrace`); promoted to a library part. |
| `vtext.subset` | fontTools subsetter | `tools/subset.v` promoted to a library; glyf today, CFF/CFF2 after the charstring reader exists. |
| `vtext.capi` | — (the C face of all of the above) | Opaque handles over every part; `vtext.h` stays the single header. |
| providers | fontconfig / Core Text / DirectWrite | Per-OS `FontSource` implementations, optional, never linked by default. |

Dependencies run one way: `layout` → `shape` → `font` → `ucd`; `capi` → all;
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
