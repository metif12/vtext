// rtl_line is the example to look at first when something is placed wrong.
//
// It draws a right-to-left line large, then draws a box around every glyph and numbers the boxes with
// each glyph's cluster index. A box that overlaps its neighbour without sharing a cluster is the first
// sign of a positioning bug; a cluster index that runs backwards through the line is the first sign of
// an ordering bug; a box with no letter in it and no cluster is a mark that has been drawn as if it
// were a letter.
//
// The line is chosen to exercise all three at once: a mark on every letter so attachment is visible, a
// lam-alef in the middle so a ligature becomes one glyph carrying two characters' clusters, and
// letters that join to all four shapes from first to last.
//
// `v run .` writes rtl_line.png, and `v run . -debug` writes the same line with the boxes.
module main

import os
import vtext
import paint

// Two fonts, because the Latin line at the top of the picture is drawn with the same call as the Arabic
// below it and neither font covers the other's script.
const latin_font = 'C:/Windows/Fonts/segoeui.ttf'
const arabic_font = 'C:/Windows/Fonts/trado.ttf'

// The Arabic line. The lam-alef is written as one character pair on purpose: it is the one ligature
// Arabic forms out of the letters themselves, and it becomes a single glyph whose cluster is the first
// of the two characters it covers.
const arabic_text = 'مَرْحَبًا بِالْعَالَمِ'

// A Latin line above it, so the picture shows both directions from the same FontSet and the same call.
const latin_text = 'Ligature: ffi. Kerning: AV. Mark: a with a grave.'

const em_px = 44.0
const margin = 40
const line_gap = 40.0

// The box is drawn generously on both sides of the baseline, so a glyph whose ink goes further than
// expected is still inside its own box rather than breaking out of it and hiding the mistake.
const box_top = 0.95 * em_px

// The box colour, which has to be faint enough to read the letter through and dark enough to see.
const box_level = u8(150)
const caret_level = u8(110)

fn main() {
	debug := os.args.len > 1 && os.args[1] == '-debug'

	ctx := vtext.new_context()
	latin := vtext.load_font_file(latin_font) or { panic('cannot open ${latin_font}: ${err}') }
	arabic := vtext.load_font_file(arabic_font) or { panic('cannot open ${arabic_font}: ${err}') }
	fs := vtext.new_font_set_of(latin, arabic)

	mut width := 0
	mut ascent := 0.0
	mut descent := 0.0
	for text in [latin_text, arabic_text] {
		w, a, d := paint.measure(fs, ctx, text, em_px)
		if w > width {
			width = w
		}
		if a > ascent {
			ascent = a
		}
		if d > descent {
			descent = d
		}
	}
	// The debug view needs room below the line for the boxes, and room at the right for the last one.
	extra := if debug { 30 } else { 0 }
	canvas_w := width + 2 * margin + extra
	canvas_h := int((ascent + descent + line_gap) * 2.0) + 2 * margin + extra

	mut canvas := paint.new_canvas(canvas_w, canvas_h, 0xff)
	mut baseline := f64(margin) + ascent
	for text in [latin_text, arabic_text] {
		draw(mut canvas, fs, ctx, text, baseline, debug)
		baseline += ascent + descent + line_gap
	}

	name := if debug { 'rtl_line_debug.png' } else { 'rtl_line.png' }
	canvas.write_png(name)
}

// draw paints one line, and its boxes when debug is set.
//
// The boxes are drawn from the same glyph list the letters are drawn from, so a box that does not
// enclose its letter means the two disagree about where the glyph is, which is worth being able to see.
fn draw(mut canvas &paint.Canvas, fs &vtext.FontSet, ctx &vtext.Context, text string, baseline f64,
	debug bool) {
	line := vtext.layout_paragraph(ctx, text.runes(), .auto, fs, em_px)
	for g in line.glyphs {
		if f := g.font {
			canvas.draw_glyph(f, g, baseline, em_px)
		}
	}
	if !debug {
		return
	}
	// A caret under each distinct cluster, then a box around each glyph. The two are different questions:
	// the caret says which input character a glyph came from, and the box says how much room it takes.
	mut seen := map[int]bool{}
	baseline_i := int(baseline)
	// Everything below the baseline: the carets and the cluster numbers. They go under the line rather
	// than over it so they cannot cover a letter.
	below := baseline_i + int(box_depth) + 2
	for g in line.glyphs {
		if !seen[g.cluster] {
			seen[g.cluster] = true
			canvas.vline(int(g.x), below + 6, below + 14, caret_level)
		}
		// A mark has no advance and shares the letter's x, so a box for it would sit exactly on top of
		// the letter's. Only the box of a letter that moves the pen is drawn, which is what makes the
		// overlap visible instead of doubled up.
		if g.advance <= 0.0 {
			continue
		}
		canvas.rect(int(g.x), baseline_i - int(box_top), int(g.x + g.advance), baseline_i +
			int(box_depth), box_level)
		print_cluster(canvas, g.cluster, int(g.x + g.advance / 2.0), below + 22)
	}
}

// box_depth is how far below the baseline a glyph's box reaches, which has to be generous because the
// descenders in Arabic go a long way down.
const box_depth = 0.55 * em_px

// print_cluster writes a small number into the picture.
//
// The digits always read left to right, because a number reads left to right in every script: a
// right-to-left line draws its cluster indexes descending from the right, and each index is still
// written forwards. Drawing the digits themselves backwards prints 12 as 21, which looks like a layout
// bug and is not one.
fn print_cluster(c &paint.Canvas, cluster int, center int, y int) {
	digits := digits_of(cluster)
	// Four pixels per digit, so the whole number's width is known before the first digit is placed and
	// it can be centred on the glyph rather than starting at it.
	step := 9
	mut dx := center - (step * digits.len) / 2
	for ch in digits {
		draw_digit(c, int(ch) - '0'.int(), dx, y)
		dx += step
	}
}

// The seven segments a digit lights up, named rather than indexed, because an index has to be counted
// against a picture in the source and a name says what it is.
const segment_top = 0
const segment_upper_left = 1
const segment_upper_right = 2
const segment_middle = 3
const segment_lower_left = 4
const segment_lower_right = 5
const segment_bottom = 6

// digits lists the segments each digit uses, in the order above. It is written out rather than computed
// because there are ten of them and a lookup is clearer than the rule that would generate them.
const digit_segments = [
	[1, 1, 1, 1, 1, 1, 1], // 0
	[0, 1, 1, 0, 0, 0, 0], // 1
	[1, 1, 0, 1, 1, 0, 1], // 2
	[1, 1, 1, 1, 0, 0, 1], // 3
	[0, 1, 1, 0, 0, 1, 1], // 4
	[1, 0, 1, 1, 0, 1, 1], // 5
	[1, 0, 1, 1, 1, 1, 1], // 6
	[1, 1, 1, 0, 0, 0, 0], // 7
	[1, 1, 1, 1, 1, 1, 1], // 8
	[1, 1, 1, 1, 0, 1, 1], // 9
]

// draw_digit draws one digit as a grid of pixels, with the segments a seven-segment display would use.
//
// The grid is 7 wide by 13 tall, which fits under a 44 pixel glyph and is still readable. Each segment is
// a filled rectangle rather than a one pixel line, because a one pixel line vanishes at this size in the
// same way a hairline in a letter does.
fn draw_digit(c &paint.Canvas, d int, x int, y int) {
	if d < 0 || d > 9 {
		return
	}
	lit := digit_segments[d]
	if lit[segment_top] == 1 {
		fill(c, x + 2, y, x + 5, y + 1, box_level)
	}
	if lit[segment_upper_left] == 1 {
		fill(c, x, y + 2, x + 1, y + 6, box_level)
	}
	if lit[segment_upper_right] == 1 {
		fill(c, x + 6, y + 2, x + 7, y + 6, box_level)
	}
	if lit[segment_middle] == 1 {
		fill(c, x + 2, y + 6, x + 5, y + 7, box_level)
	}
	if lit[segment_lower_left] == 1 {
		fill(c, x, y + 8, x + 1, y + 12, box_level)
	}
	if lit[segment_lower_right] == 1 {
		fill(c, x + 6, y + 8, x + 7, y + 12, box_level)
	}
	if lit[segment_bottom] == 1 {
		fill(c, x + 2, y + 12, x + 5, y + 13, box_level)
	}
}

// fill paints a rectangle, which is what one segment of a digit is.
fn fill(c &paint.Canvas, x0 int, y0 int, x1 int, y1 int, level u8) {
	for y in y0 .. (y1 + 1) {
		for x in x0 .. (x1 + 1) {
			c.blend(x, y, level)
		}
	}
}

// digits_of turns a small number into its digits. There is no itoa in the module and pulling in strconv for
// two digits would be more code than this. It cannot be called itoa: that name is taken by a
fn digits_of(n int) string {
	if n <= 0 {
		return '0'
	}
	mut out := []u8{}
	mut v := n
	for v > 0 {
		out.prepend(u8(v % 10 + '0'.int()))
		v /= 10
	}
	return out.bytestr()
}
