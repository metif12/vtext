// kerning shows the same word in a font that kerns and in one that does not, with each glyph's advance
// drawn so the gap between two letters can be measured rather than asserted.
//
// The comparison is only honest because both fonts are real and the difference is a font's own decision.
// Segoe UI carries 8146 Latin kern pairs and Tahoma carries none at all for Latin, so the two lines below
// differ by what the fonts say rather than by what the engine did. Tahoma is not missing the table by
// accident: it has Arabic kerning and no Latin kerning, which is a choice a font can make and this
// engine has to respect.
//
// What to read off the picture:
//
//   - The letters are the same and the spacing is not. Segoe UI closes AV, AT and Yo, and Tahoma leaves
//     them at their own advances. Both are correct for their font.
//   - The rule under each glyph is its advance. Two rules the same width apart with no kern are the whole
//     of the difference: a kern is a change to an advance, so a gap that closes is one advance that grew
//     shorter.
//   - The numbers printed say which pairs the font has an opinion about and what it says, in the font's
//     own design units, so the picture can be checked against the font rather than believed.
//
// The word is chosen for pairs the font actually kerns hard. A font's kerning lives in its diagonals:
// A over V, T over o, Y over o, F over A. Kerning a word with no diagonal in it shows nothing.
module main

import math
import vtext
import paint

// Two fonts that both cover Latin, and differ in how hard they kern.
//
// Segoe UI carries 8146 Latin kern pairs and Tahoma carries none at all for Latin, which is a choice a
// font can make: Tahoma has Arabic kerning and no Latin kerning, and this engine has to respect that.
// The sizes differ too, and that is the second thing to read off the picture: two fonts of the same point
// size are not the same size, so a line that looks bigger in one of them is the font's doing.
const kerning_font = 'C:/Windows/Fonts/segoeui.ttf'
const plain_font = 'C:/Windows/Fonts/tahoma.ttf'

// Every letter here has a diagonal pair next to it somewhere in the word, which is where a font's
// kerning lives. Kerning a word with no diagonal in it shows nothing.
const word = 'AVAST To Yo WAY'

// The pairs to report. These are the numbers fontTools reads out of these files, and the test file
// gpos_kern1_test.v fixes the same values, so the printing and the tests cannot drift apart.
const pairs = [
	Pair{
		left:  'A'
		right: 'V'
	}
	Pair{
		left:  'T'
		right: 'o'
	}
	Pair{
		left:  'Y'
		right: 'o'
	}
	Pair{
		left:  'W'
		right: 'A'
	}
	Pair{
		left:  'V'
		right: 'A'
	},
]

// Pair is one pair of letters and where the font has an opinion about it.
struct Pair {
	left  string
	right string
}

const em_px = 90.0
const margin = 30
const row_gap = 60.0

// The advance rules and the box around them are drawn faintly enough to read the letter through.
const rule_level = u8(205)

fn main() {
	ctx := vtext.new_context()
	kerned := vtext.load_font_file(kerning_font) or { panic('cannot open ${kerning_font}: ${err}') }
	plain := vtext.load_font_file(plain_font) or { panic('cannot open ${plain_font}: ${err}') }

	// What the two fonts say about themselves, printed because the picture only means something next to
	// it: a difference in the spacing is a difference in the font, not in the engine.
	println('${word}')
	println('')
	println('${kerning_font}: kerns latin = ${kerned.kerns('latn')}')
	println('${plain_font}: kerns latin = ${plain.kerns('latn')}')
	println('')
	for p in pairs {
		l := p.left.runes()[0]
		r := p.right.runes()[0]
		k := kerned.kern_offset(kerned.glyph_index(l), kerned.glyph_index(r), 'latn')
		u := plain.kern_offset(plain.glyph_index(l), plain.glyph_index(r), 'latn')
		// The value as a plain number, because an Option printed across four lines is not something a
		// reader can compare down a column.
		mut ks := 'none'
		if k != none {
			got := k
			ks = '${got.x}'
		}
		mut us := 'none'
		if u != none {
			got := u
			us = '${got.x}'
		}
		println('  ${p.left}${p.right}: segoe ${ks:>7}   tahoma ${us:>7}')
	}

	// Lay the word out once in each font to learn how wide it is and how tall it needs to be.
	mut widest := 0.0
	mut ascent := 0.0
	mut descent := 0.0
	for f in [kerned, plain] {
		line := vtext.layout_paragraph(ctx, word.runes(), .ltr, vtext.new_font_set_of(f), em_px)
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
	canvas_w := int(widest) + 2 * margin
	canvas_h := int((ascent + descent + row_gap) * 2.0) + 2 * margin + 24

	mut canvas := paint.new_canvas(canvas_w, canvas_h, 0xff)
	mut baseline := f64(margin) + ascent
	for f in [kerned, plain] {
		line := vtext.layout_paragraph(ctx, word.runes(), .ltr, vtext.new_font_set_of(f), em_px)
		draw_row(mut canvas, f, line, baseline, ascent, descent)
		baseline += ascent + descent + row_gap
	}

	canvas.write_png('kerning.png')
}

// draw_row paints one line of the word with each glyph's advance ruled.
//
// The rules are the point. A kern changes an advance, so a pair that is kerned has a rule shorter than
// the letters either side of it, and that is the only way to see a kern rather than assert one: the ink
// of two adjacent letters looks the same either way and only the pen moves.
//
// The pen is marked with a full-height line and the advance with a short one at the foot, so the three
// things a reader needs to tell apart are three different marks: where the pen was, where it went, and
// how far it moved.
fn draw_row(mut canvas paint.Canvas, f &vtext.Font, line vtext.Line, baseline f64, ascent f64,
	descent f64) {
	for g in line.glyphs {
		canvas.draw_glyph_at(f, g, baseline, em_px, f64(margin))
	}
	baseline_i := int(baseline)
	pen_top := baseline_i - int(ascent)
	pen_bottom := baseline_i + int(descent)
	// The foot rule where the advances are measured from.
	foot := baseline_i + int(descent) + 14
	for g in line.glyphs {
		x := int(math.floor(g.x)) + margin
		w := int(math.round(g.advance))
		// The advance, as a short rule at the foot, one per glyph.
		canvas.rect(x, foot, x + w, foot + 3, rule_level)
	}
	// The pen at each glyph's own origin, and at the end of the line, so a rule has both of its ends.
	mut seen := map[int]bool{}
	for g in line.glyphs {
		x := int(math.floor(g.x)) + margin
		if !seen[x] {
			seen[x] = true
			canvas.vline(x, pen_top, pen_bottom, rule_level)
		}
	}
	canvas.vline(int(math.floor(line.width)) + margin, pen_top, pen_bottom, rule_level)
	// The word's two ends, so the line's own extent is drawn rather than inferred.
	canvas.vline(margin, pen_top, pen_bottom, rule_level)
}
