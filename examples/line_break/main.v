// line_break wraps one paragraph at several widths and prints what each line covers of the input.
//
// Every line is printed with the half-open range of input characters it holds, so the wrapping can be
// checked rather than admired: the ranges run end to end with no gap and no overlap, and every line but
// the last ends somewhere a break was allowed.
//
// The last paragraph is Arabic, which is the case that makes wrapping a problem rather than an exercise.
// A Latin paragraph breaks at its spaces and that is all there is to it. Arabic has no spaces, so its
// breaks come from the line break rules of UAX #14 rather than from the text, and this engine's coverage
// of those rules is partial: no dictionary and no CJK. The Arabic lines are wrapped by the same call and
// break where the rules say, which is the honest statement of what that means today.
//
// Two things are worth measuring off the picture rather than trusting:
//
//   - The ranges. `[0..35]` then `[35..71]` then `[71..83]` is the paragraph accounted for three times
//     over with nothing lost. A wrapper that drops a space between lines, or reorders two, shows up here.
//   - The overflow. At 100 pixels three lines run past the margin rule, and the printed widths say why:
//     "quick brown" is 137 wide, "jumps over" 124 and "keeps on" 102, against a margin of 100. A line is
//     not broken inside a word, so a word that does not fit is overlong rather than hyphenated. That is a
//     decision a text engine has to make and cannot make on the caller's behalf, and the overlong line is
//     where it shows.
//
// Drawing this needed two things the previous examples did not. A column is as wide as its own widest
// line rather than the whole paragraph's, or every column is as wide as the widest and four drawings
// overlap; and the glyph's x inside its line is already added by draw_glyph_at, so passing the column
// offset plus the glyph position counts it twice and pushes each line further right the further along
// the paragraph it is.
module main

import vtext
import paint

const latin_font = 'C:/Windows/Fonts/segoeui.ttf'
const arabic_font = 'C:/Windows/Fonts/trado.ttf'

const latin_text = 'The quick brown fox jumps over the lazy dog and keeps on running until it is tired.'

const arabic_text = 'اللغة العربية نص طويل يمر دون مسافات بين الكلمات لذلك لا يمكن كسره على الكلمات'

// The widths to wrap at, chosen so the same paragraph shows a line that fills the margin, a line that
// falls well short of it, and a word that will not fit at all.
const widths = [700.0, 400.0, 200.0, 100.0]

const em_px = 24.0
const margin = 30
const case_gap = 34.0
const column_gap = 40.0

fn main() {
	ctx := vtext.new_context()
	latin := vtext.load_font_file(latin_font) or { panic('cannot open ${latin_font}: ${err}') }
	arabic := vtext.load_font_file(arabic_font) or { panic('cannot open ${arabic_font}: ${err}') }
	fs := vtext.new_font_set_of(latin, arabic)

	// Wrap first and measure, so the canvas is sized from what was produced rather than from a guess. A
	// fixed height crops the last line the moment a width or a word changes, which is how the first
	// version of the hello example drew two lines and a half.
	mut latin_runs := [][]vtext.WrappedLine{cap: widths.len}
	mut arabic_runs := [][]vtext.WrappedLine{cap: 1}
	for w in widths {
		runs := vtext.wrap_paragraph(ctx, latin_text.runes(), .auto, fs, em_px, w)
		latin_runs << runs
		print_paragraph(latin_text, w, runs)
	}
	arabic_width := 220.0
	arabic_runs << vtext.wrap_paragraph(ctx, arabic_text.runes(), .auto, fs, em_px, arabic_width)
	print_paragraph(arabic_text, arabic_width, arabic_runs[0])
	println('')

	// Each column is as wide as its own widest line and no wider, so the four of them sit side by side
	// without overlapping and the margin rule of one does not fall inside the next. Measuring the widest
	// line of the whole paragraph instead gives every column that width, which is both a canvas much
	// wider than the content and four overlapping drawings.
	mut column_w := []f64{cap: widths.len}
	mut tallest := 0.0
	for ci in 0 .. widths.len {
		mut w := 0.0
		mut h := 0.0
		for l in latin_runs[ci] {
			if l.line.width > w {
				w = l.line.width
			}
			h += l.line.ascent + l.line.descent
		}
		column_w << w
		if h > tallest {
			tallest = h
		}
	}
	mut arabic_w := 0.0
	for l in arabic_runs[0] {
		if l.line.width > arabic_w {
			arabic_w = l.line.width
		}
	}
	// A column is as wide as its content plus its margin rule, and the widest column sets the canvas.
	mut widest_column := 0.0
	for w in column_w {
		if w > widest_column {
			widest_column = w
		}
	}
	if arabic_w > widest_column {
		widest_column = arabic_w
	}
	canvas_w := int((widest_column + column_gap) * f64(widths.len)) + 2 * margin
	// The canvas is as tall as the tallest column, and the Arabic fits inside the second one's space, so
	// nothing has to be reserved below.
	canvas_h := int(tallest) + 2 * margin

	mut canvas := paint.new_canvas(canvas_w, canvas_h, 0xff)

	// Each width is a column, so the same word is at four different widths side by side and the effect of
	// the width on the wrapping is one glance rather than four.
	mut x := f64(margin)
	for ci in 0 .. widths.len {
		mut baseline := f64(margin) + latin_runs[ci][0].line.ascent
		for l in latin_runs[ci] {
			draw_line(mut canvas, fs, l, x, baseline)
			baseline += l.line.ascent + l.line.descent
		}
		// The margin this column wraps at, drawn as a vertical rule, so an overlong line is visibly
		// overlong rather than merely reported to be. The column is sized to its own content, so a line
		// that runs past the rule runs past the column too and is not clipped by the next one.
		draw_margin(mut canvas, x, column_w[ci], f64(margin), baseline)
		x += column_w[ci] + column_gap
	}

	// The Arabic paragraph goes under the shortest column rather than below all of them. The four columns
	// have two, three, five and ten lines, so a uniform block for each leaves three of them mostly empty
	// and pushing the Arabic below the tallest as well puts it a long way from anything. It fits in the
	// second column's space, which is where a reader looks after reading the four widths.
	mut second_bottom := 0.0
	for l in latin_runs[1] {
		second_bottom += l.line.ascent + l.line.descent
	}
	arabic_top := f64(margin) + second_bottom + case_gap
	arabic_x := f64(margin) + column_w[0] + column_gap
	mut baseline := arabic_top + arabic_runs[0][0].line.ascent
	for l in arabic_runs[0] {
		draw_line(mut canvas, fs, l, arabic_x, baseline)
		baseline += l.line.ascent + l.line.descent
	}
	draw_margin(mut canvas, arabic_x, arabic_w, arabic_top - 12.0, baseline)

	canvas.write_png('line_break.png')
}

// print_paragraph reports the wrapping of one paragraph at one width, with the character range of each
// line and its width.
//
// The ranges are the check that matters and they are printed rather than drawn: a wrapper that loses a
// space between two lines, or emits the same range twice, is visible here and nowhere else. The widths are
// printed next to the margin so an overlong line can be spotted in the text alone.
fn print_paragraph(text string, width f64, runs []vtext.WrappedLine) {
	println('width ${width:.0f}: ${runs.len} lines')
	cps := text.runes()
	for l in runs {
		mut s := ''
		for r in cps[l.from..l.to] {
			s += r.str()
		}
		over := if l.line.width > width { ' OVER' } else { '' }
		println('  [${l.from:3}..${l.to:3}] ${l.line.width:6.1f}${over}  ${s}')
	}
}

// draw_line paints one wrapped line at an x offset.
fn draw_line(mut canvas paint.Canvas, fs &vtext.FontSet, l vtext.WrappedLine, x f64, baseline f64) {
	for g in l.line.draw_order() {
		if f := g.font {
			// The offset is the column's left edge and nothing else. The glyph keeps the x the engine
			// gave it inside its own line, and draw_glyph_at adds the glyph's x to the offset itself, so
			// passing the column plus the glyph here would count that x twice and push each line further
			// right the further along the paragraph it is.
			canvas.draw_glyph_at(f, g, baseline, em_px, x)
		}
	}
}

// draw_margin paints the vertical rule a column wraps at, so a line that runs past it is visible as
// running past it.
fn draw_margin(mut canvas paint.Canvas, x f64, width f64, top f64, bottom f64) {
	rule := int(x + width)
	for y in int(top) .. int(bottom) {
		canvas.blend(rule, y, margin_level)
	}
}

// margin_level is faint enough to read the letters through.
const margin_level = u8(225)
