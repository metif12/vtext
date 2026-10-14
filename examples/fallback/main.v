// fallback shows one paragraph drawn from two fonts, with every glyph marked by the font it came from.
//
// A FontSet is an ordered list of fonts and a character is drawn from the first one that covers it. That
// is the whole mechanism, and this example is the only way to see it, because a line drawn correctly
// looks exactly like a line drawn from one font. So every glyph here is underlined in the colour of the
// font it came from, and the underline is drawn from the glyph list rather than from the text: the engine
// has already decided, and this only reports it.
//
// The two fonts are chosen to force the choice rather than to avoid it. Consolas is a monospaced font for
// code and covers Latin, Greek and Cyrillic but no Arabic at all. Traditional Arabic covers Arabic and
// nothing much else. Neither font covers Hebrew, so the last row is the case where the chain runs out and
// there is nothing to draw, which is a report rather than a crash.
//
// What to read off the picture:
//
//   - The Latin letters come from Consolas and are monospaced, and the Arabic comes from Traditional
//     Arabic. One line, two fonts, and the change is where the script changes rather than at a word
//     boundary, because the decision is per character and not per run.
//   - A glyph from the second font has its own advance and its own baseline treatment, so the two fonts
//     in one line do not share a rhythm. That is what fallback costs and it is why an application that
//     cares picks its fonts rather than accepting whatever falls out.
//   - A character no font covers is drawn as .notdef, which is a hollow box, and is counted in the
//     report rather than dropped: a dropped character changes the text, and a box at least shows where
//     something was lost.
module main

import vtext
import corpus
import paint

// A font that covers Latin, Greek and Cyrillic and no Arabic, and a font that covers Arabic.

// Three lines: one that stays in the first font, one that crosses into the second, and one that runs off
// the end of the chain. The Hebrew is there on purpose: no font here covers it.
const lines = [
	'Consolas renders this line in one font.',
	'Then متن عربی takes the second font.',
	'And this: אבג goes nowhere at all.',
]

const em_px = 34.0
const margin = 30
const line_gap = 30.0
const underline_h = 5

// The two colours the underlines are drawn in, and the colour for a glyph that came from nowhere.
const first_level = u8(120)
const second_level = u8(230)
const missing_level = u8(70)

fn main() {
	ctx := vtext.new_context()
	first := vtext.load_font_file(corpus.font('consola.ttf', 'Amiri-Regular.ttf')) or { panic('cannot open ${err}') }
	second := vtext.load_font_file(corpus.font('trado.ttf', 'Amiri-Regular.ttf')) or { panic('cannot open ${err}') }
	// Order is preference: a character both fonts cover comes from the first, and one only the second
	// covers comes from the second.
	fs := vtext.new_font_set_of(first, second)

	// What each font covers is printed, because the picture only means something next to it. A reader who
	// does not know that Consolas has no Arabic cannot tell a working fallback from a coincidence.
	println('first font:  ')
	println('  covers Latin A   ${first.has_glyph('A'.runes()[0])}')
	println('  covers Arabic mim ${first.has_glyph(0x0645)}')
	println('second font: ')
	println('  covers Latin A   ${second.has_glyph('A'.runes()[0])}')
	println('  covers Arabic mim ${second.has_glyph(0x0645)}')
	println('  covers Hebrew alef ${second.has_glyph(0x05D0)}')
	println('')

	mut widest := 0.0
	mut ascent := 0.0
	mut descent := 0.0
	mut drawn := []vtext.Line{cap: lines.len}
	for text in lines {
		line := vtext.layout_paragraph(ctx, text.runes(), .auto, fs, em_px)
		drawn << line
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
	canvas_h := int((ascent + descent + line_gap) * f64(lines.len)) + 2 * margin + underline_h
	mut canvas := paint.new_canvas(canvas_w, canvas_h, 0xff)

	mut baseline := f64(margin) + ascent
	for i, text in lines {
		line := drawn[i]
		mut from_first := 0
		mut from_second := 0
		mut missing := 0
		for g in line.draw_order() {
			// A glyph of zero is the .notdef box, and it is the answer for a character no font in the
			// chain covers. It is not a missing font: the engine still names the font it asked, because
			// that is the font whose .notdef is being drawn, and a glyph drawn by hand would have no font
			// at all. So the test is the glyph index rather than the font.
			mut level := missing_level
			if g.gid != 0 {
				f := g.font or {
					missing++
					continue
				}
				canvas.draw_glyph_at(f, g, baseline, em_px, f64(margin))
				if f.path() == first.path() {
					from_first++
					level = first_level
				} else {
					from_second++
					level = second_level
				}
			} else {
				missing++
				// The box is still drawn, from the font that was asked. Dropping it would move every glyph
				// after it along, which changes the text rather than showing that something was lost.
				f := g.font or { first }
				canvas.draw_glyph_at(f, g, baseline, em_px, f64(margin))
			}
			// The underline is under the glyph's own advance, so it shows how much room that font gave
			// the glyph rather than a box around the ink.
			underline_glyph(canvas, g, baseline, level)
		}
		println('"${text}"')
		println('  ${from_first} from the first font, ${from_second} from the second, ${missing} from neither')
		baseline += ascent + descent + line_gap
	}

	canvas.write_png('fallback.png')
}

// underline_glyph draws a bar under one glyph in a given grey, which is how the font each glyph came from
// is shown. The bar spans the advance rather than the ink, so two glyphs from different fonts can be told
// apart by their widths as well as by their colour.
//
// The x is the glyph's own place within its line plus the margin, because the glyph is drawn at the margin
// rather than at zero. That is the same offset the glyph itself was drawn at, and using a different one
// here would put every underline somewhere other than under its glyph.
fn underline_glyph(c &paint.Canvas, g vtext.Glyph, baseline f64, level u8) {
	y := int(baseline) + underline_h
	x0 := int(g.x) + margin
	w := int(g.advance)
	if w <= 0 {
		// A mark has no advance of its own, so a bar under it would sit under nothing. It is drawn at the
		// pen of its base instead, one pixel wide, which says "this glyph was placed here" without
		// pretending it took room.
		c.blend(x0, y, level)
		return
	}
	for x in x0 .. (x0 + w) {
		c.blend(x, y, level)
	}
}
