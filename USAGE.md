# Usage

Using HarfAra from V and from C: the five-minute path, the build recipes, and
the full API with its ownership rules.

## V in five minutes

HarfAra is a V module. The module lives in this tree; point `VMODULES` at its
parent and import it:

```sh
# PowerShell
$env:VMODULES='C:\Users\MR\Projects'
# sh
export VMODULES=$HOME/Projects
```

```v
import harfara.layout
import harfara.shape

fn main() {
	ctx := shape.new_context()
	fs := shape.new_font_set()
	fs.add(shape.load_font_file('testdata/fonts/Amiri-Regular.ttf') or { panic(err) })

	line := layout.layout_paragraph(ctx, 'Hello سلام'.runes(), .auto, fs, 32.0)
	println('width: ${line.width} glyphs: ${line.glyphs.len}')
	for g in line.glyphs {
		font := g.font or { continue }
		bitmap := font.rasterize(g.gid, 32.0, 0, 0)
		// bitmap.left and bitmap.top place it at g.x and g.y on the baseline
		println('${g.gid} at ${g.x},${g.y} ${bitmap.width}x${bitmap.height}')
	}
}
```

The direction argument (`.ltr`, `.rtl`, `.auto`) drives the bidi algorithm's
P2/P3; `.auto` reads it from the first strong character. `em_px` is the size
of an em square in pixels.

Wrapping, measuring and breaking are separate calls over the same pipeline:

```v
// As many lines as fit 400 px, shaped once and cut out of one layout.
for w in layout.wrap_paragraph(ctx, text.runes(), .auto, fs, 32.0, 400.0) {
	draw(w.line) // glyphs, positioned, ready to draw
	caret_at(w.from, w.to) // the input range this line holds
}

// The two widths a layout engine needs before it draws anything.
m := layout.measure_paragraph(ctx, text.runes(), .auto, fs, 32.0)
// m.min_content_width, m.max_content_width, m.ascent, m.descent, m.line_height

// Break positions, for a caller that decides the width itself.
for b in layout.break_opportunities(ctx, text.runes(), true) {
	// b.start is the input index; b.is_mandatory marks hard breaks
}

// Hyphenation rides the same seam as a policy: UAX #14 alone by default,
// UAX #14 plus Liang points when asked.
for w in layout.wrap_paragraph_with_policy(ctx, text.runes(), .auto, fs, 32.0,
	400.0, &layout.LayoutOptions{}, layout.HyphenBreaks{}) {
	draw(w.line) // overlong words break with an appended hyphen glyph
}
```

Options (discretionary features, line height, letter and word spacing, alignment) have
`_with` forms that take the same `LayoutOptions`. A paragraph wrapped without
the features was shaped without them, so the box and the line are sized with
the same options or they disagree about the width of the same text:

```v
mut opts := layout.LayoutOptions{}
opts.features = ['-calt', '+dlig'] // -tag turns a default-on feature off, +tag names one explicitly
opts.line_height = 28.0
opts.letter_spacing = 0.5
opts.word_spacing = 2.0
opts.align = .center
opts.align_width = 400.0 // the width align resolves against; 0 is the line's own
line := layout.layout_paragraph_with(ctx, text.runes(), .rtl, fs, 32.0, &opts)
```

calt, liga and clig are on by default — the code ligatures and the Persian
pairs — so the list above only names what differs from the default. The C
side takes the same names as one comma-separated string (`"-calt,+dlig"`).

`README.md` documents the pipeline, the font fallback rules, kerning, marks
and every inspection API in full. This file does not repeat it.

## Parts

The library is split into one module per job — `harfara.ucd` first, then `harfara.font`,
`harfara.shape` and `harfara.layout` in dependency order (`layout` → `shape` → `font` → `ucd`) —
so a caller that only needs tables does not pull in shaping, and a caller
that only shapes does not pull in rasterization. `ROADMAP.md` Phase 6 tracks
the order; `GOAL.md` says what each part replaces.

The shape of every split is the one `harfara.ucd` set. The part owns its
sources and its generated data, root code reaches it qualified, and the
split is verified the same way: full suite green, fmt gate green, every
consumer green:

```v
import harfara.shape
import harfara.ucd

// The decoded tables live one per text system, next to the shaper that uses
// them, which is why they are built with the context rather than read off a
// global.
ctx := shape.new_context()
props := ctx.properties // &ucd.Properties, shared between threads and faces
_ = props.line_break_of(`A`)
```

Regenerating a part's tables writes into the part, so a regeneration lands
where the module lives:

```sh
v run tools/gen_tables.v          # writes ucd/ucd_bidi.v, ucd/ucd_linebreak.v, ...
v run tools/gen_arabic.v          # writes ucd/ucd_arabic.v
v run tools/gen_normalization.v   # writes ucd/ucd_normalization.v
v run tools/gen_codepoint_names.v # writes ucd/ucd_names.v
```

(`ucd/UnicodeData.txt` — the generator input — is fetched, not committed:
`v run tools/fetch_ucd.v`. The generated files are committed, so a normal
build never needs the fetch.)
