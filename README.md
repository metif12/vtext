# vtext

A text shaping and rendering library in V, written for Arabic and Persian but not limited to them.

It takes a string and a set of fonts, and returns positioned glyphs: decomposed, reordered,
substituted, and with every combining mark placed on the letter it belongs to.

```v
import vtext

fn main() {
	ctx := vtext.new_context()
	fs := vtext.new_font_set()
	fs.add(vtext.load_font_file('C:\\Windows\\Fonts\\tahoma.ttf') or { panic(err) })

	line := vtext.layout_paragraph(ctx, 'بِه'.runes(), .rtl, fs, 32.0)
	font := fs.pick(`ب`) or { panic('no font') }
	for g in line.glyphs {
		bitmap := font.rasterize(g.gid, 32.0, 0, 0)
		println('${g.gid} at ${g.x},${g.y} ${bitmap.width}x${bitmap.height}')
	}
	println('width: ${line.width}')
}
```

## What it does

The pipeline is the one UAX #9 and the OpenType specification describe, in order.

| Stage | Spec | File |
| --- | --- | --- |
| Decompose and order combining marks | UAX #15 | `normalize.v` |
| Resolve paragraph direction and runs | UAX #9 | `bidi.v`, `bidi_rules.v` |
| Pick the Arabic joining form | UAX #53 | `joining.v` |
| Choose and order fonts | | `glyph.v` |
| Substitute glyphs | OpenType GSUB | `gsub.v` |
| Place combining marks | OpenType GPOS | `gpos.v` |
| Order glyphs for drawing | UAX #9 | `layout.v` |
| Rasterize | | `stbtt.c.v` |

Character data is generated from the UCD into `ucd_*.v`, so there are no runtime tables to load and
no network access is needed to build.

## Supported

- TrueType and CFF outlines, and font collections (TTC).
- cmap subtable formats 0, 4, 6 and 12.
- Arabic joining forms, and the isolated, initial, medial and final shapes.
- GSUB single, multiple, alternate, ligature and contextual substitutions.
- GPOS mark-to-base, mark-to-ligature and mark-to-mark attachment.
- Right-to-left lines, mixed-direction paragraphs, and bidi mirroring.
- Glyph rasterization through a bundled stb_truetype.

## Not supported

Named here so that a caller is not surprised by them.

- **Kerning.** GPOS pair-adjustment lookups (type 2) are not parsed, and neither is the `kern`
  table. Latin text is shaped and drawn without letter spacing correction.
- **Line breaking.** The UAX #14 class data is present in `properties.v` but no rule engine uses it
  yet. `layout_paragraph` returns one line and does not wrap.
- **Contextual positioning.** GPOS chaining-context lookups (types 5 and 6) are not parsed.
- **Justification and kashida.**
- **Non-Arabic scripts beyond the basics.** Latin, Greek and Cyrillic resolve their glyphs, shapes
  and draw correctly, but a font's Latin-specific positioning tables go unused.
- **Vertical text.**

## Using it

### Laying out a line

```v
ctx := vtext.new_context()
fs := vtext.new_font_set()
fs.add(vtext.load_font_file('tahoma.ttf') or { panic(err) })
fs.add(vtext.load_font_file('segoeui.ttf') or { panic(err) })

// The third argument is the paragraph direction; .auto reads it from the text.
line := vtext.layout_paragraph(ctx, text.runes(), .auto, fs, 32.0)
```

`em_px` is the size of an em square in pixels, so 32.0 gives roughly a 32-pixel line.

### Fonts

`FontSet` is an ordered fallback chain. A codepoint is drawn with the first font that has a glyph
for it, so a chain of an Arabic font followed by a Latin font covers mixed text.

```v
fs := vtext.new_font_set()
fs.add(arabic_font)  // first choice
fs.add(latin_font)   // used for codepoints the first has no glyph for
```

### Features

Every line gets `ccmp` and `rlig`, in that order, because a line missing its mark composition is not
the text that was asked for. Anything else is a presentation choice and stays with the caller.

```v
// liga is what Persian letter pairs need, and it changes the width of the text, so it is opt-in.
mut opts := vtext.LayoutOptions{}
opts.features = ['liga']

line := vtext.layout_paragraph_with(ctx, text.runes(), .rtl, fs, 32.0, &opts)
```

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

### Marks

Three tables place a mark, and the API asks which one is meant, because a font may use any of them
for a given pair.

```v
offset := font.mark_offset(mark_gid, base_gid, false)  // over a letter
offset := font.mark_offset(mark_gid, base_gid, true)   // over another mark
```

The offsets are in design units with y upwards, as the font's own coordinates run. A font that has
no rule for the pair returns `none`, and the caller leaves the mark at the pen.

## Building and testing

The build needs V built with GCC, because the rasterizer is C.

```powershell
.\env.ps1          # sets VEXE, CC and VMODULES
.\test.ps1         # runs every _test.v file
.\test.ps1 -Filter gpos   # one area
v fmt -verify .    # formatting
```

The tests read real fonts from `C:\Windows\Fonts`, so they only run on a machine with Tahoma, Segoe
UI and Dubai installed.

## Notes on the code

Two decisions in here are worth knowing before changing anything, because both caused a bug that
looked like something else.

**Decomposition reorders, and the mapping has to travel with it.** NFD moves a mark that was written
after another mark to before it, because a lower combining class sorts first. An index into the
decomposed text is therefore not an index into the caller's text, and a mark that took its cluster
from the decomposed text would report a neighbouring mark's character and then be placed against
the wrong letter. `nfd_mapped` returns the mapping and `layout.v` goes through it.

**A lookup table is not the number of things it covers.** A `Coverage` table's count is the number of
ranges, not the number of glyphs, and a `LigatureArray` is indexed through offsets that point at
variable-length structures. Sizes are checked before they are used to allocate.

## Layout

```
reader.v     bounds-checked big-endian byte reading
sfnt.v       the font file: tables, collections, offsets
tables.v     shared table directory handling
cmap.v       codepoint to glyph
face.v       loads GDEF, GSUB and GPOS for a font
glyph.v      fallback chain, joining forms, glyph metrics
normalize.v  UAX #15
bidi.v       UAX #9
joining.v    UAX #53
gsub.v       OpenType substitution
gpos.v       OpenType positioning
layout.v     the pipeline, and mark placement
properties.v the UCD lookup tables
```

`ucd_*.v` are generated character data and are not edited by hand.
