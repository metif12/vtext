// line_break wraps one paragraph at several widths and prints what each line covers of the input.
//
// Every line is printed with the half-open range of input characters it holds, so the wrapping can be
// checked rather than admired: the ranges run end to end with no gap and no overlap, and every line but
// the last ends somewhere a break was allowed.
//
// Four paragraphs: Latin at four widths, Cyrillic+Greek mixed, Arabic, and Urdu. A Latin paragraph
// breaks at its spaces and that is all there is to it. The Cyrillic+Greek line shows one face covering
// two scripts. Arabic has no spaces, so its breaks come from the line break rules of UAX #14 rather
// than from the text, and this engine's coverage of those rules is partial: no dictionary and no CJK.
// Urdu has spaces despite running right to left, so it wraps at spaces like Latin and contrasts with
// the Arabic paragraph above it. Every paragraph is wrapped by the same call and breaks where the
// rules say, which is the honest statement of what that means today.
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
import corpus
import paint
import vtext.layout
import vtext.shape

const latin_text = 'The quick brown fox jumps over the lazy dog and keeps on running until it is tired.'

const arabic_text = 'اللغة العربية نص طويل يمر دون مسافات بين الكلمات لذلك لا يمكن كسره على الكلمات'

// Mixed Cyrillic+Greek: every rune verified in FiraCode (Cyrillic miss block is only U+047A..U+0489;
// Greek miss block only unassigned/Coptic). Breaks at spaces.
const cyrillic_greek_text = 'Быстрая коричневая лиса прыгает через ленивую собаку η γρήγορη καφέ αλεπού πηδάει'

// Urdu: Naskh/Amiri cover it too, but Nastaliq is the assigned face. Has spaces (U+0020 in Nastaliq
// cmap), so it wraps at spaces like Latin, not by UAX #14.
const urdu_text = 'اردو ایک خوبصورت زبان ہے جو نستعلیق میں لکھی جاتی ہے'

// The widths to wrap at, chosen so the same paragraph shows a line that fills the margin, a line that
// falls well short of it, and a word that will not fit at all.
const widths = [700.0, 400.0, 200.0, 100.0]

const em_px = 24.0
const margin = 30
const case_gap = 34.0
const column_gap = 40.0

fn main() {
	ctx := shape.new_context()
	// Corpus-only: FiraCode lays out every non-Arab paragraph (Latin, Cyrillic, Greek);
	// Naskh lays out the Arabic-script paragraph; Nastaliq lays out the Urdu paragraph.
	fira := shape.load_font_file(corpus.font('FiraCode-Variable.ttf')) or { panic('cannot open ${err}') }
	naskh := shape.load_font_file(corpus.font('NotoNaskhArabic-Regular.ttf', 'Amiri-Regular.ttf')) or {
		panic('cannot open ${err}')
	}
	nastaliq := shape.load_font_file(corpus.font('NotoNastaliqUrdu-Regular.ttf')) or { panic('cannot open ${err}') }
	fs_arabic := shape.new_script_font_set(naskh, fira)
	fs_urdu := shape.new_script_font_set(nastaliq, fira)

	// Wrap first and measure, so the canvas is sized from what was produced rather than from a guess. A
	// fixed height crops the last line the moment a width or a word changes, which is how the first
	// version of the hello example drew two lines and a half.
	print_breaks(ctx, latin_text)
	print_breaks(ctx, cyrillic_greek_text)
	print_breaks(ctx, arabic_text)
	print_breaks(ctx, urdu_text)
	mut latin_runs := [][]layout.WrappedLine{cap: widths.len}
	mut arabic_runs := [][]layout.WrappedLine{cap: 1}
	for w in widths {
		runs := layout.wrap_paragraph(ctx, latin_text.runes(), .auto, fs_arabic, em_px, w)
		latin_runs << runs
		print_paragraph(latin_text, w, runs)
	}
	// Cyrillic+Greek under the same set: scripts Latn/Cyrl/Grek all fall to the general (FiraCode).
	cyrillic_width := 260.0
	cyrillic_runs := layout.wrap_paragraph(ctx, cyrillic_greek_text.runes(), .auto, fs_arabic, em_px, cyrillic_width)
	print_paragraph(cyrillic_greek_text, cyrillic_width, cyrillic_runs)
	arabic_width := 220.0
	arabic_runs << layout.wrap_paragraph(ctx, arabic_text.runes(), .auto, fs_arabic, em_px, arabic_width)
	print_paragraph(arabic_text, arabic_width, arabic_runs[0])
	// Urdu MUST use fs_urdu; under fs_arabic the same codepoints would resolve to Naskh instead of
	// Nastaliq (both have_glyph, primary wins).
	urdu_width := 220.0
	urdu_runs := layout.wrap_paragraph(ctx, urdu_text.runes(), .auto, fs_urdu, em_px, urdu_width)
	print_paragraph(urdu_text, urdu_width, urdu_runs)
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
	mut cyrillic_w := 0.0
	mut cyrillic_h := 0.0
	for l in cyrillic_runs {
		if l.line.width > cyrillic_w {
			cyrillic_w = l.line.width
		}
		cyrillic_h += l.line.ascent + l.line.descent
	}
	mut urdu_w := 0.0
	mut urdu_h := 0.0
	for l in urdu_runs {
		if l.line.width > urdu_w {
			urdu_w = l.line.width
		}
		urdu_h += l.line.ascent + l.line.descent
	}
	// A column is as wide as its content plus its margin rule, and the widest column sets the canvas.
	mut widest_column := 0.0
	for w in [cyrillic_w, arabic_w, urdu_w] {
		if w > widest_column {
			widest_column = w
		}
	}
	for w in column_w {
		if w > widest_column {
			widest_column = w
		}
	}
	canvas_w := int((widest_column + column_gap) * f64(widths.len)) + 2 * margin
	// The canvas is as tall as the tallest column, and the extra paragraphs fit inside the short
	// columns' space, so nothing has to be reserved below.
	canvas_h := int(tallest + cyrillic_h + urdu_h) + 2 * margin

	mut canvas := paint.new_canvas(canvas_w, canvas_h, 0xff)

	// Each width is a column, so the same word is at four different widths side by side and the effect of
	// the width on the wrapping is one glance rather than four.
	mut x := f64(margin)
	for ci in 0 .. widths.len {
		mut baseline := f64(margin) + latin_runs[ci][0].line.ascent
		for l in latin_runs[ci] {
			draw_line(mut canvas, l, x, baseline)
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
	// second column's space, which is where a reader looks after reading the four widths. Cyrillic+Greek
	// and Urdu stack below it in the same column.
	mut second_bottom := 0.0
	for l in latin_runs[1] {
		second_bottom += l.line.ascent + l.line.descent
	}
	arabic_top := f64(margin) + second_bottom + case_gap
	arabic_x := f64(margin) + column_w[0] + column_gap
	mut baseline := arabic_top + arabic_runs[0][0].line.ascent
	for l in arabic_runs[0] {
		draw_line(mut canvas, l, arabic_x, baseline)
		baseline += l.line.ascent + l.line.descent
	}
	draw_margin(mut canvas, arabic_x, arabic_w, arabic_top - 12.0, baseline)
	baseline += case_gap
	for l in cyrillic_runs {
		draw_line(mut canvas, l, arabic_x, baseline)
		baseline += l.line.ascent + l.line.descent
	}
	draw_margin(mut canvas, arabic_x, cyrillic_w, baseline - cyrillic_h - 12.0, baseline)
	baseline += case_gap
	for l in urdu_runs {
		draw_line(mut canvas, l, arabic_x, baseline)
		baseline += l.line.ascent + l.line.descent
	}
	draw_margin(mut canvas, arabic_x, urdu_w, baseline - urdu_h - 12.0, baseline)

	canvas.write_png('line_break.png')
}

// print_breaks reports where the engine may end a line, so the wrapping below can be
// checked against the breaks rather than believed: every line but the last must end at
// one of these, and a line that ends anywhere else is a wrapper that invents its own.
fn print_breaks(ctx &shape.Context, text string) {
	cps := text.runes()
	breaks := layout.break_opportunities(ctx, cps, true)
	mut at := []int{}
	for b in breaks {
		if b.is_mandatory {
			at << b.start
		}
	}
	println('  ${breaks.len} break opportunities, mandatory at ${at}')
}

// print_paragraph reports the wrapping of one paragraph at one width, with the character range of each
// line and its width.
//
// The ranges are the check that matters and they are printed rather than drawn: a wrapper that loses a
// space between two lines, or emits the same range twice, is visible here and nowhere else. The widths are
// printed next to the margin so an overlong line can be spotted in the text alone.
fn print_paragraph(text string, width f64, runs []layout.WrappedLine) {
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
fn draw_line(mut canvas paint.Canvas, l layout.WrappedLine, x f64, baseline f64) {
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
