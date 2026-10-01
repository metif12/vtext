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

`ROADMAP.md` says what is left in the engine, and lists the examples and the tools that come after
it.

## Supported

- TrueType and CFF outlines, and font collections (TTC).
- cmap subtable formats 0, 4, 6 and 12.
- Arabic joining forms, and the isolated, initial, medial and final shapes.
- GSUB single, multiple, alternate, ligature and contextual substitutions.
- GPOS mark-to-base, mark-to-ligature and mark-to-mark attachment.
- GPOS pair adjustment (kerning), in both the per-pair and per-class forms.
- GPOS chaining-context positioning (lookup type 8, format 3).
- Right-to-left lines, mixed-direction paragraphs, and bidi mirroring.
- Line breaking per UAX #14, and wrapping to a width.
- Glyph rasterization through a bundled stb_truetype.

## Not supported

Named here so that a caller is not surprised by them.

- **The legacy `kern` table.** Kerning is read from GPOS only, which is where every font worth using
  puts it. A font that has only a `kern` table is drawn unkerned.
- **The parts of UAX #14 that need a dictionary or a resolved level.** Segmentation inside a word
  (LB16b, LB17b) and the strict level rules are not implemented. Neither affects Arabic or Persian.
- **CJK line breaking.** The ideographic rules are not implemented, so a Han or Kana run breaks at
  every character rather than at the word boundaries a reader expects.
- **Contextual positioning formats 1 and 2.** Format 3 is read, which is what the Arabic fonts use.
  Formats 1 and 2 need a class for every glyph in a pattern and then a jump through a rule set.
- **Cursive attachment (GPOS type 1).** Three Windows Arabic fonts carry it — Traditional Arabic
  with 7 lookups, Simplified Arabic with 57, Majalla with 54 — and it is what makes a cursive script
  look cursive rather than merely joined. This engine joins by picking one of four shapes instead.
- **Device and variation tables.** A hint that a pair is tighter at one size than another is skipped,
  so a kern is the same at every size.
- **Justification and kashida.**
- **Non-Arabic scripts beyond the basics.** Latin, Greek and Cyrillic resolve their glyphs, shapes,
  kern and draw correctly, but a font's script-specific positioning tables go unused.
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

### Wrapping

A paragraph laid out to fit a width, with the input range each line came from. The whole paragraph
is shaped once and the lines are cut out of it, so trying a narrower width costs no extra shaping.

```v
for w in vtext.wrap_paragraph(ctx, text.runes(), .rtl, fs, 32.0, 400.0) {
	draw(w.line)         // the glyphs, positioned, ready to draw
	caret_at(w.from, w.to)  // the range of the caller's text this line holds
}
```

Three rules are handled rather than left to the caller: a space never ends a line, a word wider than
the margin goes on a line of its own rather than being split, and a newline ends the paragraph
whatever the width is.

`break_opportunities` is the lower half of this, for a caller that wants to decide the width itself
or to draw the opportunities.

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
if font.contextually_positions('arab') {
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
if off := font.kern_offset(left_gid, right_gid, 'arab') {
	// off is in design units; divide by units_per_em and multiply by the pixel size
}

if font.kerns('arab') {
	// the font has pair rules for this script
}
```

Ask about the glyphs the pipeline produced rather than the letters in the text. Two letters that join
are shaped into a different glyph, and a lam-alef is one glyph that no pair rule can name.

`kern_pair_in` is the form to use when the two glyphs are known to be adjacent in a run, because a font
can kern the same two letters differently depending on what is around them. A run of three in Arabic can
need three answers that a pair table cannot give.

```v
// gids is the shaped run in logical order; left and right are indices into it.
if off := font.kern_pair_in(gids, 0, 1, 'arab') {
	// this pair is kerned differently here than it would be two letters into the word
}
```

The rules behind it are counted by `kerns`, so a font whose only kerning is context-sensitive still
reports true.

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

**A value format is not a field name.** A GPOS `ValueRecord` is variable length, and the bits of the
format say which of four fields are there: `0x0001` is xPlacement, `0x0002` yPlacement, `0x0004`
xAdvance and `0x0008` yAdvance. Kerning is `0x0004`, so reading an xPlacement where an xAdvance
belongs produces the right number in the wrong place: the letter moves out from under its neighbour
and the gap between them stays the same.

**The two pair formats diverge at the sixth field.** Format 1 has a count of `PairSet` tables where
format 2 has two class definitions, and both begin with the same coverage and the same two value
formats. Reading one as the other takes a class definition's offset as a count, which is a small
number that looks fine, and then walks offsets out of something that is not an array of them.

**Class 0 is a real class.** It is what a glyph gets when no definition names it, and a font that
kerns a class of letters against everything else writes into the class 0 row. What decides a pair is
the coverage, not the class value.

**A positioning record is a pair of indices and nothing else.** There is no count of them and no value
format on the contextual side, even though the substitution side has fields that look as though they
belong there. Reading one takes a word that belongs to the first record, which shifts every record by
one and turns a lookup index of 62 into a value format of 62.

**A record under the kern feature usually names a single positioning, not a pair.** Andalus's first
kerning rule is "if one of glyphs 160 through 167 comes before glyph 3, apply lookup 21", and lookup 21
moves one glyph rather than closing a gap between two. Assuming a pair finds no rule and answers nothing
on a font whose rules are working perfectly.

## Known compiler problems

Two shapes of code fail to compile with this compiler, both producing C that does not build rather than
a V-level error. Both were found the slow way here, so they are written down.

**A function that takes a slice of a struct as a mutable parameter.** `fn f(mut xs []PairValue)` reaches
`src.c: expected expression before ')' token` with an `__arr_val_N` undeclared behind it, and so does a
mutable reference to one. Returning such a slice fails the same way. Building the array locally and
appending to it works; passing it in does not. `read_single_exceptions` in the context work was stuck on
this for a while before it was recognised as the compiler and not the code.

**An empty array literal of a struct with no capacity.** `[]PairValue{}` fails the same way. Writing it
as `[]PairValue{cap: n, len: 0}` compiles.

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
