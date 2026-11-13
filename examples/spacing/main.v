// spacing shows what the caller's spacing options do to one line, and what measure says
// before anything is drawn.
//
// One Persian line is laid out five ways: plain, letter-spaced, letter-tightened, word-spaced,
// and with a caller line height. The five rows are drawn stacked with a rule on each baseline,
// so the eye compares the widths; the numbers printed prove the spacing went into the advances
// the engine measured rather than onto the drawing, and that measure_paragraph_with agrees
// with layout_paragraph_with, because a measurement taken with different options is a
// measurement of a different line and a caller that sizes a box from it sizes the wrong box.
//
// What to read off the picture, row by row:
//
//   - Letter spacing opens every letter by the same amount, so the row is longer by the
//     spacing times the letter count, and the marks do not move apart from their bases:
//     a mark shares its base's advance and spacing it too would charge one character twice.
//   - A negative letter spacing tightens the same way, and the row is shorter.
//   - Word spacing opens only the spaces, so a row with four spaces grows by four spacings
//     and the letters inside each word do not move.
//   - A caller line height changes the distance between baselines and nothing else: the
//     last row's bracket is twice as tall while its ink is the same size as the first row's.
//     Asking for less than the glyphs are tall reports the smaller box without shrinking the
//     ink, which is why the bracket is the claim and the ink overflowing it would be correct.
module main

import math
import vtext
import corpus
import paint

// Row is one rendering of the line and the options that produced it.
struct Row {
	about          string
	letter_spacing f64
	word_spacing   f64
	line_height    f64
}

// One line with spaces in it, so word spacing has something to open, and a ZWNJ pair, so a
// reader can check the spacing did not break the join.
const text = 'این یک جملهٔ فارسی است'

const rows = [
	Row{
		about:          'plain: no options'
		letter_spacing: 0.0
		word_spacing:   0.0
		line_height:    0.0
	}
	Row{
		about:          'letter spacing 2: every letter opened by two pixels'
		letter_spacing: 2.0
		word_spacing:   0.0
		line_height:    0.0
	}
	Row{
		about:          'letter spacing -0.75: the same line tightened'
		letter_spacing: -0.75
		word_spacing:   0.0
		line_height:    0.0
	}
	Row{
		about:          'word spacing 8: only the four spaces opened'
		letter_spacing: 0.0
		word_spacing:   8.0
		line_height:    0.0
	}
	Row{
		about:          'line height 64: same ink, baselines twice as far apart'
		letter_spacing: 0.0
		word_spacing:   0.0
		line_height:    64.0
	},
]

const em_px = 32.0
const margin = 30
const bracket_gap = 14.0

// The bracket and the baseline rule, faint enough to read the letters through.
const rule_level = u8(205)

fn main() {
	ctx := vtext.new_context()
	arabic := vtext.load_font_file(corpus.font('trado.ttf', 'Amiri-Regular.ttf')) or { panic('cannot open ${err}') }
	latin := vtext.load_font_file(corpus.font('segoeui.ttf', 'Amiri-Regular.ttf')) or { panic('cannot open ${err}') }
	fs := vtext.new_script_font_set(arabic, latin)

	// Every row is laid out and measured with the same options, so the printed measure and
	// the drawn line cannot disagree about the width of the text.
	mut lines := []vtext.Line{cap: rows.len}
	mut measures := []vtext.TextMetrics{cap: rows.len}
	for r in rows {
		mut opts := vtext.LayoutOptions{}
		opts.letter_spacing = r.letter_spacing
		opts.word_spacing = r.word_spacing
		opts.line_height = r.line_height
		lines << vtext.layout_paragraph_with(ctx, text.runes(), .auto, fs, em_px, &opts)
		measures << vtext.measure_paragraph_with(ctx, text.runes(), .auto, fs, em_px, &opts)
	}

	for i, r in rows {
		line := lines[i]
		m := measures[i]
		println('${r.about}')
		println('  laid out  width ${line.width:7.2f}  line height ${line.line_height:5.2f}')
		println('  measured  min ${m.min_content_width:7.2f}  max ${m.max_content_width:7.2f}  line height ${m.line_height:5.2f}')
		if math.abs(m.max_content_width - line.width) > 0.01 {
			println('  MEASURE AND LAYOUT DISAGREE: same options must size the same line')
		}
	}
	println('')

	// The canvas is sized from the laid out rows: the widest row sets the width, and the
	// line heights stack the baselines, so a taller line height moves the rows below it.
	mut widest := 0.0
	mut total := 0.0
	for line in lines {
		if line.width > widest {
			widest = line.width
		}
		total += line.line_height
	}
	canvas_w := int(widest) + 2 * margin + int(bracket_gap) + 20
	canvas_h := int(total) + 2 * margin
	mut canvas := paint.new_canvas(canvas_w, canvas_h, 0xff)

	mut baseline := f64(margin) + lines[0].ascent
	for i, line in lines {
		for g in line.draw_order() {
			if f := g.font {
				canvas.draw_glyph_at(f, g, baseline, em_px, f64(margin))
			}
		}
		// The baseline rule, so the rows can be compared against the same horizontal.
		for x in margin .. canvas_w - margin {
			canvas.blend(x, int(baseline), rule_level)
		}
		// The bracket on the left spans this row's line height: the next baseline sits one
		// line height below this one, so the bracket is the distance between two rules. It
		// stops two pixels short at each end, so the brackets read as one per row rather
		// than one line for the whole picture.
		top := int(baseline - lines[i].ascent)
		bottom := int(baseline + lines[i].line_height - lines[i].ascent)
		canvas.vline(margin - int(bracket_gap), top + 2, bottom - 2, rule_level)
		baseline += line.line_height
	}

	canvas.write_png('spacing.png')
}
