# Goal

One library that does the whole text job — load, shape, lay out, rasterize,
inspect, subset — where each job is a separate part with its own API, its own
conformance baseline, and its own reason to exist. A caller uses one part or
all of them; nothing is pulled in by accident. It replaces HarfBuzz,
FreeType, Pango, fontconfig, fontstash and stb_truetype per part, on Windows, Linux and macOS, with
answers as good and throughput measured better — or the claim is not made.

That sentence is the architecture. "Replacement" is claimed per part, against
the incumbent for that part, and measured the way this repository already
measures everything else: shaping against HarfBuzz, line breaking against the
Unicode committee's own test, rasterization against FreeType and Pillow, with
every remaining difference recorded with its reason. A part with no baseline
is a part with no claim.

## The parts and what each one replaces

| Part | Replaces | Objective |
| --- | --- | --- |
| `harfara.ucd` | — (shared data) | Generated UCD tables, decoded once into `Properties`. No other part reads the UCD directly. Case mapping (8.3) and word/sentence tables (8.2) landed the same way, each with its committee conformance floor. |
| `harfara.font` | FreeType's loading side, fontTools' reading side | sfnt/TTC containers, WOFF1 (WOFF2 refused: no brotli decoder in tree), cmap, metrics, variation-store reading. The `Font`/`FontSet`/`Glyph` wrappers and layout live in `shape/` and `layout/`; `font/` owns data, parsers, and every method on font types. |
| `harfara.shape` | HarfBuzz core | Normalization, bidi, joining, `Context`, `Font`/`FontSet`/`Glyph`, `inspect.v`, case mapping. GSUB/GPOS application runs on font types in `font/`; orchestration taking font types as arguments lives here. |
| `harfara.layout` | Pango's layout math | Line breaking, wrapping, measuring, vertical columns. Align/justify landed opt-in in 7.4 (kashida tatweels for uniform Arabic, spaces elsewhere); hyphenation (7.5), wrap modes/ellipsize/tabs (8.4) and log attrs (8.2) landed. |
| `harfara.raster` | FreeType's rendering side, fontstash/stb_truetype coverage | `GlyphBitmap` behind the box-and-fill contract `box_only`/`render_into` define; hinted engine, color, synth/LCD and stroking landed (7.7/8.5/8.6). Packing, quantize/gamma/blur and quads live in `raster/pack.v`, `raster/quantize.v`, `layout/iterator.v` as caller-owned generics with no FONS types. The box and fill calls stay methods on `font.Face` because methods live in the type's own module, so `font` imports the leaf `raster` for the data they trade in. |
| `harfara.inspect` | fontTools introspection (read side) | The inspection API on `shape.Font` in `shape/inspect.v`, not a separate part: eighteen `Font` methods, and a thin `inspect/` of free functions would cycle `shape` → `inspect` → `shape` through the return type. |
| `harfara.subset` | fontTools subsetter | `subset/` behind `subset_font(font, seed)` with `tools/subset.v` as the CLI; glyf and CFF rebuilds landed (verbatim keep, CFF2/CID refused with the reason). The separate CFF2 reader (`font/cff2.v`) reads outlines but cannot be subset yet. `Font.data()` returns the parsed bytes; the closure rebuilds and the tool verifies by reloading. |
| `harfara.capi` | — (the C face of all of the above) | Opaque handles over every part; `harfara.h` stays the single header. The header mirror is proven, not claimed: `tools/capicheck.v` reads `capi.v`, `harfara.h` and `harfara.def` as text and fails either direction (50 exports). |
| providers | fontconfig / Core Text / DirectWrite | Per-OS font lookup, optional, never linked by default. Linux (fontconfig) resolves a family and reports the matched family beside the path, plus ranked sort with charset/language coverage (8.8); Core Text and DirectWrite are Phase 7.8, each pinned on its own OS and answering none elsewhere. |

Dependencies run one way: `layout` → `shape` → `font` → `ucd`, with `raster` a leaf below `font`; `capi` → all;
nothing depends upward. A part never imports a tool, and no tool is imported.

The seams that keep the parts combinable, each an explicit interface rather
than an argument about taste, are `FontSource` (where fonts come from),
`RasterBackend` (box-for-gid plus fill-this-buffer), `BreakPolicy` (UAX #14
plus hyphenation dictionaries behind one call), the caller-owned glyph cache (keyed on
font id, gid, size, subpixel), and per-part options structs on the proven
`LayoutOptions` pattern.

## Explicitly not goals

Worth writing down so that scope arguments end by quoting this file.

- A text editor, or any interactive application. The library is a library.
- A layout engine for boxes, flex, or CSS beyond the text layer: line breaking,
  alignment, justification and hyphenation are in (7.4 and 7.5 landed).
  Boxes, the cascade and painting stay the caller's, which is what `../vweb` builds on.
- HarfBuzz bindings, or a port of anything. Every part is written from the
  specifications.
- Font authoring. HarfAra reads fonts, subsets them, and reports on them; it
  does not build them (`otLib`-side tooling stays out).

The platform scope is all three CI runners — Windows, Linux, macOS, both
arches CI provides — with every OS-specific leg covered on its own OS (Phase
7 platform ratchet). WASM is a spike, not a commitment, until a slice is
measured on it.

The last four of the old list changed status on purpose: kashida,
justification, hyphenation and wrap modes are `harfara.layout` features now
(7.4, 7.5, 8.4), system font discovery is a provider rather than a refusal,
and variable instancing landed (7.10).
What did not change: the engine ends at a positioned glyph with a coverage bitmap, and the cache stays with the caller.
