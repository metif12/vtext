// features shows what a discretionary OpenType feature does to the text rather than to the code.
//
// Every word here is laid out twice: once with the feature explicitly off (`-tag`, which turns back
// on one of the defaults calt/liga/clig or names nothing for the rest), and once with it asked for
// by name. Both widths and both gid lists are printed and both rows are drawn, so the change is
// something the reader can see and check rather than a claim. Every number below was read off
// HarfBuzz before it was written here; where this engine and HarfBuzz disagree the case is a null,
// not a pin.
//
// A feature does three kinds of thing, and the cases are one of each:
//
//   - `liga` fuses Latin `fi` in Amiri from two glyphs to one. That is a count change, and the easy
//     one to notice.
//   - `dlig` fuses الله in Naskh from four glyphs to two: the Allah fusion is discretionary in this
//     face (off by default) and absent from the others' tables in this form, which is why the same
//     word is a null under `liga` in Nastaliq.
//   - `calt` swaps FiraCode's `=>` for its two-piece arrow with the same count and the same width
//     (a monospace face): a substitution only the printed gid list can see, which is why the list is
//     printed.
module main

import math
import harfara
import paint
import corpus
import harfara.layout
import harfara.shape

// Two Arabic-capable fonts that cover Persian as well, so one shape.FontSet serves every row.

// Case is one word and the feature that changes it.
struct Case {
	text    string
	feature string
	about   string
	font    string
}

const cases = [
	Case{
		text:    'fi'
		feature: 'liga'
		about:   'two glyphs become one: the Latin liga in Amiri, HarfBuzz agrees'
		font:    corpus.font('Amiri-Regular.ttf')
	}
	Case{
		text:    'الله'
		feature: 'dlig'
		about:   'four become two in Naskh: the Allah fusion is discretionary here, off by default'
		font:    corpus.font('NotoNaskhArabic-Regular.ttf')
	}
	Case{
		text:    'فارسی'
		feature: 'liga'
		about:   'five stay five: the Persian joins come from the joining features, liga changes nothing and HarfBuzz agrees'
		font:    corpus.font('Amiri-Regular.ttf')
	}
	Case{
		text:    'الله'
		feature: 'liga'
		about:   'Urdu Nastaliq has no liga (GSUB lacks it): off==on, fusion is rlig always-on'
		font:    corpus.font('NotoNastaliqUrdu-Regular.ttf')
	}
	Case{
		text:    '=>'
		feature: 'calt'
		about:   'two stay two, alternates 1730/1736; calt present, liga absent'
		font:    corpus.font('FiraCode-Variable.ttf')
	}
	Case{
		text:    'АВ Αα'
		feature: 'calt'
		about:   'Cyrillic/Greek pass through calt unchanged; FiraCode covers latn/cyrl/grek'
		font:    corpus.font('FiraCode-Variable.ttf')
	},
]

const em_px = 64.0
const margin = 30
const row_gap = 30.0
const label_gap = 26.0

fn main() {
	ctx := shape.new_context()

	// Every case is laid out twice, once with the required features alone and once with the
	// discretionary one, and both are kept so the numbers printed and the rows drawn come from the same
	// layout rather than from two passes that could disagree.
	mut lines := []layout.Line{cap: cases.len * 2}
	for ci, c in cases {
		f := shape.load_font_file(c.font) or { panic('cannot open ${c.font}: ${err}') }
		fs := shape.new_font_set_of(f)
		// The feature is on by default (calt, liga, clig), so the "without" side names the
		// off-switch explicitly: `-tag` turns one default back off, and the "with" side is the
		// default itself. Before the defaults landed, the bare line was the off side; now it
		// would be the on side twice, and every pair would read as no change.
		mut off_opts := layout.LayoutOptions{}
		off_opts.features = ['-' + c.feature]
		off := layout.layout_paragraph_with(ctx, c.text.runes(), .auto, fs, em_px, &off_opts)
		mut opts := layout.LayoutOptions{}
		opts.features = [c.feature]
		on := layout.layout_paragraph_with(ctx, c.text.runes(), .auto, fs, em_px, &opts)
		lines << off
		lines << on

		println('${c.text}   ${c.font.split('/').last()}   ${c.about}')
		println('  without ${c.feature}: ${off.glyphs.len} glyphs, width ${off.width:.2f} ${gids_of(off)}')
		println('  with    ${c.feature}: ${on.glyphs.len} glyphs, width ${on.width:.2f} ${gids_of(on)}')
		println('  change: ${on.glyphs.len - off.glyphs.len} glyphs, ${on.width - off.width:+.2f} px')
	}

	// The canvas is sized from what was laid out above. The loop walks the cases rather than the
	// flattened list, because a list of layouts built by appending is what the loop above fills and
	// walking it twice would mean keeping two things in step for no reason.
	mut widest := 0.0
	mut ascent := 0.0
	mut descent := 0.0
	for i in 0 .. cases.len {
		for line in [lines[i * 2], lines[i * 2 + 1]] {
			if line.width > widest {
				widest = line.width
			}
			if line.ascent > ascent {
				ascent = line.ascent
			}
			if line.descent > descent {
				descent = line.descent
			}
		}
	}
	// Each case is two rows plus the space between cases.
	row_h := ascent + descent + row_gap
	canvas_w := int(widest) + 2 * margin + label_gap
	canvas_h := int(row_h * f64(cases.len * 2)) + 2 * margin + label_gap

	mut canvas := paint.new_canvas(int(canvas_w), int(canvas_h), 0xff)
	mut baseline := f64(margin + label_gap) + ascent
	for ci, c in cases {
		f := shape.load_font_file(c.font) or { continue }
		draw(mut canvas, f, lines[ci * 2], baseline)
		draw(mut canvas, f, lines[ci * 2 + 1], baseline + row_h)
		// The baseline under each row of the pair, so a reader can see which two go together.
		canvas.vline(margin - 6, int(baseline + row_h * 0.5), int(baseline + row_h * 1.5),
			label_level)
		baseline += row_h * 2.0
	}

	canvas.write_png('features.png')
}

// gids_of lists a line's glyph ids, so a substitution that keeps the count and the width (a
// monospace calt swap, an unfolded-then-equal advance) still reads as a change rather than as nothing.
fn gids_of(line layout.Line) string {
	mut out := '['
	for i, g in line.glyphs {
		if i > 0 {
			out += ' '
		}
		out += '${g.gid}'
	}
	out += ']'
	return out
}

// label_level is faint enough to read the letters through.
const label_level = u8(210)

// draw paints one laid out line and rules the pen at each glyph, so a substitution is visible as a
// different number of rules and a change of width as a different distance between the last two.
fn draw(mut canvas paint.Canvas, f &shape.Font, line layout.Line, baseline f64) {
	for g in line.glyphs {
		canvas.draw_glyph_at(f, g, baseline, em_px, f64(margin))
	}
	mut seen := map[int]bool{}
	for g in line.glyphs {
		x := int(math.floor(g.x)) + margin
		if !seen[x] {
			seen[x] = true
			canvas.vline(x, int(baseline) - int(em_px * 0.35), int(baseline) + int(em_px * 0.35),
				label_level)
		}
	}
}
