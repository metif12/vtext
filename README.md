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
- **SinglePos format 2.** Format 1 is read, which is what every font here uses. Format 2 has one value
  for a whole coverage and a second array of exceptions, and reading it as format 1 takes the valueCount
  as a count and then reads coverage indices as records.
- **Cursive attachment (GPOS type 1).** Read, in both formats, but the reader refuses a table whose
  offsets point back into its own records, which is what tells a cursive rule from a single
  positioning. No font on this machine has one, so nothing here exercises the attachment itself: Arabic
  joining in the Windows fonts comes entirely from GSUB substitution, which this engine does do. The
  one `curs` feature here, in Dubai, reaches a mark attachment lookup, and fontTools calls that
  subtable a CursivePos because it reads the shape rather than the extension header that names the
  type.
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

`FontSet` is an ordered fallback chain. A codepoint is drawn with the first font that has a glyph for it.

```v
fs := vtext.new_font_set()
fs.add(arabic_font)  // first choice
fs.add(latin_font)   // used for codepoints the first has no glyph for
```

A flat order cannot express what a mixed-script line usually wants, and the reason is worth stating
because it is not obvious until you count the glyphs. **Both** Segoe UI and Traditional Arabic cover
both Latin and Arabic. So a chain of (latin, arabic) draws every Persian letter in Segoe UI and never
reaches the Arabic font, and a chain of (arabic, latin) draws the English word in a naskh face. Neither
order is wrong as an order; each is wrong as an answer to "draw this Persian line in a naskh face and
that English word in a Latin one".

```v
// Arabic goes to the Arabic font, everything else to the Latin one.
fs := vtext.new_script_font_set(arabic_font, latin_font)
fs.pick_in(ctx, rune(0x0628))  // -> arabic_font
fs.pick_in(ctx, rune(0x41))    // -> latin_font
```

Measured on Segoe UI and Traditional Arabic, `سلام` drawn through a flat latin-first chain produces
**0** glyphs from the Arabic font, and through a per-script chain produces **4**, with `hello سلام`
giving 6 Latin and 4 Arabic.

A per-script set with no primary and no general is exactly a flat set, so the two are interchangeable and
`pick_in` and `pick` agree in that case. The script test is the same generated table the joining pass
uses, so the set cannot disagree with the shaper about which characters are Arabic.

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

`context_placement` is the form to use when the two glyphs are known to be adjacent in a run, because a
font can place the same two letters differently depending on what precedes them. A run of three in Arabic
can need three answers that a pair table cannot give.

```v
// gids is the shaped run in logical order; left and right are indices into it.
if off := font.context_placement(gids, 0, 1, 'arab') {
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
no rule for the pair returns `none`, and the caller leaves the mark at the pen.

### Asking a font what it has

Some questions are about the font rather than about the string. `Font.kerns` asks whether a font kerns;
`Font.kern_offset` asks what it does to a pair. The first is a report and the second is the engine
acting, and they are kept apart. Everything in this section is the first kind.

```v
for t in font.tables() {
    println('${t.tag} at ${t.offset}, ${t.length} bytes')
}
font.has_table('COLR')            // the font has one this engine draws nothing with
font.outlines()                   // 'glyf', 'CFF ', or ''
font.num_lookups('GPOS')          // the count in the table's own LookupList
font.features('GSUB')             // the FeatureList, sorted
font.scripts('GPOS')              // the ScriptList, sorted
font.cmap_counts()                // mapped codepoints per subtable
font.glyph_class_counts()         // in the order of glyph_class_names
font.is_variable()                // has an fvar table, which is not the same as reading one
font.variable_axes()
```

`features` reads the FeatureList rather than the features the scripts enable, and those are different
sets. Segoe UI declares 25 tags in GSUB; only 23 are reachable from any default language system,
because `isol` and `locl` are enabled only under a tagged language. A count of 23 would say the font
cannot isolate a letter, which is false. What a *run of text* can reach is asked through
`substitute_glyphs`, and that is a separate question on purpose.

`glyph_class_counts` puts every glyph in `unclassified` when there is no GDEF, so the counts add up to
the glyph count either way. `BreakOpportunity` is public too: it was not, and `break_opportunities` was,
which left a caller able to count its results and read none of them.

These are what `tools/fontdump`, `tools/fontcheck` and `tools/shapetrace` are written against, and they
are public because a library that cannot be inspected from outside cannot be diagnosed from outside.

## Building and testing

The build needs V built with GCC, because the rasterizer is C.

The scripts are V programs rather than PowerShell ones. A test runner for a V module should be a V program:
the same language means one set of quoting rules, one idea of a path separator and one idea of an exit code,
and a bug in the runner is then not a bug in anything it was checking. Two of these were PowerShell until
2026-10-03 and the rewrite is in the history.

```sh
v run tools/env.v              # prints the build environment and checks the compiler is there
v run tools/run_tests.v        # runs every _test.v file
v run tools/run_tests.v gpos   # one area, matched as a substring of the file name
v fmt -verify .                # formatting
```

`run_tests.v` builds one file at a time and gives the compiler a `TMPDIR` of its own, and both are needed.
`v test a.v b.v c.v` builds concurrently and enough of them collide in the compiler's own temporary build
directory that a run fails with "CreateDirectory returned: The operation completed successfully", which says
the directory already existed rather than that creating it failed. Serial alone is not enough: the compiler
puts its build directory at `<temp>/v_<uid>`, which is shared with every other V build on the machine,
including another session building the compiler itself. It retries a failure that mentions the build
directory and does not retry a real one, and says so when a pass needed a retry.

```sh
v run tools/run.v tools/fontdump.v -- C:/Windows/Fonts/segoeui.ttf
```

`run.v` builds one program and runs it, which is two steps and both of them need their exit code.
Everything after a bare `--` goes to the program, because the program's arguments and this script's options
both start with a dash and guessing which is which is the kind of guess that works until it does not.

```sh
v run tools/fetch_ucd.v         # the UCD files, which are not committed
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
moves one glyph rather than closing a gap between two. Across the Arabic fonts here, of the records a
kern feature reaches, 186 name a single positioning and 12 name a pair. Assuming a pair finds no rule
and answers nothing on a font whose rules are working perfectly.

**A SinglePos format 1 value comes straight after the format that says how wide it is.** There is no
count of the values, because the coverage already says how many there are. Reading the first value as a
count turns a value of -120 into a count of 65416, and the pair tables beside it in the same table do
have a count, which is what makes the two easy to confuse.

**A rule with a backtrack is about one glyph with a condition.** Its pattern names the glyph being
placed and reaches back to what makes it different, so the two glyphs a caller asks about are a glyph
and its context rather than two the pattern both names. A reader that insists the pattern covers both
discards every rule shaped like this one, and most rules under kern are shaped like it.

## Working with this compiler

Three things this codebase ran into, written down because each one costs an hour to find again and none
of them says where the problem is.

**`m[k] or []T{}` fails on a map whose values are slices.** The same form compiles on a map of strings and
on one of structs, and the failure is reported as an unexpected end of file at the end of the function, not
at the expression that caused it. Asking `if k in m` first compiles and reads no worse. The shapes
suspected of this earlier in the project's history — a mutable slice parameter, an empty array literal —
were tested together and all compile; that was recorded as a compiler bug and the recording was wrong,
but a fault is here and it is a different one.

**`none` is not available as a name.** It reads as the option's empty value, so a counter called `none`
gives "non-name `none` on left side of `:=`" rather than anything mentioning the name being taken.

**A slice assigned into a struct inside a loop needs `clone()`.** The array is still live at the end of
the iteration, so the struct gets a copy. `parse_mark_to_ligature` does this for its anchors.

## Layout

```
reader.v        bounds-checked big-endian byte reading
sfnt.v          the font file: tables, collections, offsets
tables.v        shared table directory handling
cmap.v          codepoint to glyph
face.v          loads GDEF, GSUB and GPOS for a font
glyph.v         fallback chain, joining forms, glyph metrics
normalize.v     UAX #15
bidi.v          UAX #9
joining.v       UAX #53
gsub.v          OpenType substitution
gpos.v          OpenType positioning
layout.v        the pipeline, and mark placement
properties.v    the UCD lookup tables
linebreak.v     UAX #14
stbtt.c.v       the stb_truetype rasteriser, vendored and public domain

inspect.v       reporting what a font contains: tables, features, scripts, coverage
trace_api.v     the pipeline's stages, reached one at a time for shapetrace

ucd_*.v         generated from the UCD by the tools in tools/, committed so a build needs no fetch
ucd_names.v     codepoint names, front coded: the suffixes and the shared prefix lengths
```

The tools are in `tools/`, the examples in `examples/`, and `ucd/` holds the Unicode Character Database
files that are redistributed here. See `LICENSE` for which licence covers what.

## Licence

Two licences, because the tree holds two kinds of thing.

The source is MIT. The seven Unicode Character Database files under `ucd/` are Unicode, Inc.'s and are
redistributed unchanged under UNICODE LICENSE V3, whose text is in `ucd/LICENSE-UNICODE.txt`. That licence
grants redistribution only on the condition that the notice travels with the files, which is why the licence
is committed rather than downloaded: `tools/fetch_ucd.v` does not fetch it, and a `ucd/*` ignore without an
exception for it would publish the data with no terms at all.

The generated tables in `ucd_*.v` are derived from those files and are covered by the MIT licence above. A
derivative of the data would have to carry the data's terms for the same reason, so those tables are kept
out of the MIT grant rather than quietly inside it; the notice travels with the sources they came from, in
the same directory tree and in the same commit.

`ucd_*.v` are generated character data and are not edited by hand.
