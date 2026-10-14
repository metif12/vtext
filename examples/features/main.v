// features shows what a discretionary OpenType feature does to the text rather than to the code.
//
// Every word here is laid out twice: once with the required features alone, which is what the engine
// always applies, and once with one discretionary feature asked for by name. Both widths are printed and
// both rows are drawn, so the change is something the reader can see and check rather than a claim.
//
// Two words, because a feature does two different kinds of thing:
//
//   - "الله" goes from four glyphs to two with `liga` in every Arabic font on this machine. That is a
//     count change: two of the letters have a shape that only exists as a pair, and the font says so.
//     Every Arabic font here agrees, which is what makes it a good first thing to look at.
//   - "فارسی" changes glyphs but not their number under `liga` in Segoe UI, and the line gets ten pixels
//     narrower. That is a substitution that keeps the count: the same five letters, drawn differently,
//     taking less room.
//
// The second is the one worth understanding. A feature that changes the count is easy to notice and a
// feature that changes only the width is easy to miss, and the second is the more common.
module main

import math
import vtext
import paint
import corpus

// Two Arabic-capable fonts that cover Persian as well, so one FontSet serves every row.

// Case is one word and the feature that changes it.
struct Case {
	text    string
	feature string
	about   string
	font    string
}

const cases = [
	Case{
		text:    'الله'
		feature: 'liga'
		about:   'four glyphs become two: a shape that exists only as a pair'
		font:    corpus.font('segoeui.ttf', 'Amiri-Regular.ttf')
	}
	Case{
		text:    'الله'
		feature: 'liga'
		about:   'the same in a second font, which agrees'
		font:    corpus.font('tahoma.ttf', 'Amiri-Regular.ttf')
	}
	Case{
		text:    'فارسی'
		feature: 'liga'
		about:   'five glyphs stay five and the line gets narrower'
		font:    corpus.font('segoeui.ttf', 'Amiri-Regular.ttf')
	},
]

const em_px = 64.0
const margin = 30
const row_gap = 30.0
const label_gap = 26.0

fn main() {
	ctx := vtext.new_context()

	// Every case is laid out twice, once with the required features alone and once with the
	// discretionary one, and both are kept so the numbers printed and the rows drawn come from the same
	// layout rather than from two passes that could disagree.
	mut lines := []vtext.Line{cap: cases.len * 2}
	for ci, c in cases {
		f := vtext.load_font_file(c.font) or { panic('cannot open ${c.font}: ${err}') }
		fs := vtext.new_font_set_of(f)
		off := vtext.layout_paragraph(ctx, c.text.runes(), .auto, fs, em_px)
		mut opts := vtext.LayoutOptions{}
		opts.features = [c.feature]
		on := vtext.layout_paragraph_with(ctx, c.text.runes(), .auto, fs, em_px, &opts)
		lines << off
		lines << on

		println('${c.text}   ${c.font.split('/').last()}   ${c.about}')
		println('  without ${c.feature}: ${off.glyphs.len} glyphs, width ${off.width:.2f}')
		println('  with    ${c.feature}: ${on.glyphs.len} glyphs, width ${on.width:.2f}')
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
		f := vtext.load_font_file(c.font) or { continue }
		draw(mut canvas, f, lines[ci * 2], baseline)
		draw(mut canvas, f, lines[ci * 2 + 1], baseline + row_h)
		// The baseline under each row of the pair, so a reader can see which two go together.
		canvas.vline(margin - 6, int(baseline + row_h * 0.5), int(baseline + row_h * 1.5),
			label_level)
		baseline += row_h * 2.0
	}

	canvas.write_png('features.png')
}

// label_level is faint enough to read the letters through.
const label_level = u8(210)

// draw paints one laid out line and rules the pen at each glyph, so a substitution is visible as a
// different number of rules and a change of width as a different distance between the last two.
fn draw(mut canvas paint.Canvas, f &vtext.Font, line vtext.Line, baseline f64) {
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
