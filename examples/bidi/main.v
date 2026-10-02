// bidi shows what the bidirectional algorithm does to a paragraph, which is the case in this engine that
// is hardest to reason about and easiest to get wrong.
//
// Each line is drawn as it will be read, and under it is printed: the input in logical order, the
// resolved embedding level of every character, and the visual order the algorithm produced. Those three
// together are the whole of the case. The drawing is the result and the two lines of numbers are the
// reasoning, and where they disagree with each other the disagreement is the bug.
//
// Four lines, each one a different thing the algorithm has to decide:
//
//   - "The word سلام means peace." is mostly Latin with one Arabic word in it. Nothing moves; the Arabic
//     runs right to left inside a left-to-right paragraph. This is the easy one, and it is here so the
//     other three have something to be different from.
//   - "سلام The world" starts right to left, so the Latin moves to the *left* of the Arabic and the
//     paragraph level is odd. A line like this drawn as if it were the first one has the order of its
//     halves swapped.
//   - "abc سلام 123 def" has a number between the two scripts. Numbers are weak, so they take the
//     direction of what surrounds them, and they come out *before* the Arabic rather than after it, which
//     is the part that surprises people reading the source left to right.
//   - "۱۲۳ فارسی abc ۴۵۶" has two separate runs of Persian digits. Each one takes the direction of its
//     own neighbours, so the line reads as two right-to-left islands whose digits each keep their own
//     left-to-right order. The visual order printed under the line is the only honest way to read it.
module main

import math
import vtext
import paint

const latin_font = 'C:/Windows/Fonts/segoeui.ttf'
const arabic_font = 'C:/Windows/Fonts/trado.ttf'

const paragraphs = [
	'The word سلام means peace.',
	'سلام The world',
	'abc سلام 123 def',
	'۱۲۳ فارسی abc ۴۵۶',
]

const em_px = 40.0
const margin = 30
const line_gap = 26.0

// The printed block under each paragraph: how many lines of text, and how tall each one is.
const print_lines = 3
const print_line_h = 22
const print_gap = 14.0

fn main() {
	ctx := vtext.new_context()
	latin := vtext.load_font_file(latin_font) or { panic('cannot open ${latin_font}: ${err}') }
	arabic := vtext.load_font_file(arabic_font) or { panic('cannot open ${arabic_font}: ${err}') }
	fs := vtext.new_script_font_set(arabic, latin)

	// Resolve every paragraph first, because both the drawing and the printing need the answer and the
	// two must not be two separate runs of the algorithm.
	mut results := []vtext.BidiResult{cap: paragraphs.len}
	mut lines := []vtext.Line{cap: paragraphs.len}
	mut widest := 0.0
	mut ascent := 0.0
	mut descent := 0.0
	for text in paragraphs {
		res := vtext.resolve_paragraph(ctx.properties, text.runes(), .auto)
		line := vtext.layout_paragraph(ctx, text.runes(), .auto, fs, em_px)
		results << res
		lines << line
		if line.width > widest {
			widest = line.width
		}
		if line.ascent > ascent {
			ascent = line.ascent
		}
		if line.descent > descent {
			descent = line.descent
		}
		print_result(text, res, line)
		println('')
	}

	// The canvas has to hold the paragraphs and, under each one, the printed block. The block is drawn by
	// rendering the printed lines with the Latin font, which is why the canvas needs its height as well
	// as its width.
	row_h := ascent + descent + line_gap + print_gap + print_line_h * print_lines
	canvas_w := int(widest) + 2 * margin
	canvas_h := int(row_h * f64(paragraphs.len)) + 2 * margin

	mut canvas := paint.new_canvas(canvas_w, canvas_h, 0xff)
	mut top := f64(margin) + ascent
	for i, text in paragraphs {
		draw_paragraph(mut canvas, fs, lines[i], top)
		top += row_h
	}

	canvas.write_png('bidi.png')
}

// print_result reports one paragraph: what was typed, what level each character ended up at, and what
// order the characters came out in.
//
// The visual order is printed as the characters in the order they will be drawn, which is the only way to
// read a line that mixes directions without seeing it. A reader comparing that with the logical order
// above it can see exactly which characters moved and which did not.
fn print_result(text string, res vtext.BidiResult, line vtext.Line) {
	println('"${text}"')
	println('  paragraph level ${res.paragraph_level}, ${res.isolating_sequences} isolating sequence(s)')

	// The levels, one per input character, which is the algorithm's output before anything is reordered.
	mut level_line := '  levels      '
	for lv in res.levels {
		level_line += '${lv} '
	}
	println(level_line)

	// The visual order as the characters will be drawn, which for a right-to-left paragraph is the
	// reverse of the order they were typed. An invisible character prints as a middle dot, because a
	// formatting control has no glyph and its presence is the point of rule X9.
	//
	// visual_order maps a visual index to a logical index, so walking it left to right gives the
	// characters as the pen meets them, which is not the order a reader of this output reads them: a
	// right-to-left run is drawn from its left edge, and the characters within it are laid out so the
	// reader travels right to left. The drawn line below is the readable version.
	mut visual := '  visual      '
	for logical in res.visual_order {
		if !res.visible[logical] {
			visual += '·'
		} else {
			visual += text.runes()[logical].str()
		}
	}
	println(visual)

	// And what the drawn line says, from the glyphs themselves, which is the check that matters: if the
	// layout and the algorithm disagree, the layout is what the reader sees.
	//
	// The glyphs are in visual order, left to right, so the line reads correctly here — but the characters
	// of a right-to-left run appear in the reverse of the order they were typed. For السلام the glyphs
	// read م ا ل س ل ا, which is the same word as the input ا ل س ل ا م read the other way, and that is
	// the whole of what a direction is. Comparing this with visual_order, which lists logical indices,
	// shows that both name the same characters in the same order.
	mut drawn := '  drawn       '
	for g in line.draw_order() {
		drawn += text.runes()[g.cluster].str()
	}
	println(drawn)
}

// draw_paragraph paints one laid out line and rules the paragraph's edges, so a right-to-left line is
// visibly anchored to the right rather than merely happening to end there.
fn draw_paragraph(mut canvas paint.Canvas, fs &vtext.FontSet, line vtext.Line, baseline f64) {
	for g in line.draw_order() {
		if f := g.font {
			canvas.draw_glyph_at(f, g, baseline, em_px, f64(margin))
		}
	}
	// A rule at the start of the line and one at the end, which for a right-to-left paragraph is the
	// right-hand one: the pen starts where the reading starts.
	baseline_i := int(baseline)
	top := baseline_i - int(em_px * 0.4)
	canvas.vline(margin, top, top + 8, rule_level)
	canvas.vline(int(math.floor(line.width)) + margin, top, top + 8, rule_level)
}

// rule_level is faint enough to read the letters through.
const rule_level = u8(210)
