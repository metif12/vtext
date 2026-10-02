// hello is the smallest program that proves the whole vtext pipeline: text in, positioned glyphs in a
// picture, quit.
//
// There is no window here on purpose. A window needs a graphics binding, and a binding is a dependency
// that has nothing to do with the text engine, so the part of this example that shows the engine works
// is the part that writes a file. `v run .` prints the path.
//
// Everything between the text and the file is the library: fonts are opened from disk, the paragraph is
// laid out through bidi and Arabic joining, each glyph is rasterised from the font's own outlines, and
// the result is deflated into a PNG. Nothing about the shaping is redone here, and that is the claim
// this example makes.
module main

import vtext
import paint

// The fonts this example asks for by role, rather than by name. Which file fills a role is this
// program's decision; what the engine does with the result is the library's.
const latin_font = 'C:/Windows/Fonts/segoeui.ttf'
const arabic_font = 'C:/Windows/Fonts/trado.ttf'

// Three lines, so one command shows three things at once: left-to-right text with a ligature, an
// Arabic word, and a line that is mostly Latin with one Arabic word in the middle, which is where
// bidirectional reordering has to do something.
const lines = [
	'V shapes text: ffi ligature, kerning AV, and a baseline.',
	'مرحبا بالعالم',
	'The word سلام means peace, inside an English line.',
]

// The margin and the gap between lines, in pixels. The canvas size is not written down: it is measured
// from the lines the engine lays out, so changing the text or the size cannot silently crop the last
// line, which is exactly what a fixed height does.
const margin = 40
const line_gap = 26.0
const em_px = 28.0

fn main() {
	ctx := vtext.new_context()
	latin := vtext.load_font_file(latin_font) or { panic('cannot open ${latin_font}: ${err}') }
	arabic := vtext.load_font_file(arabic_font) or { panic('cannot open ${arabic_font}: ${err}') }
	// One set with both fonts in it, so a character the Latin font has no glyph for is found in the
	// Arabic one rather than drawn as a box. Order is preference: the first font that covers a
	// character wins.
	fs := vtext.new_font_set_of(latin, arabic)

	// The canvas is sized from the text: the widest line sets the width, and the tallest ascent plus
	// the line heights set the height.
	mut width := 0
	mut ascent := 0.0
	mut descent := 0.0
	for text in lines {
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
	canvas_w := width + 2 * margin
	canvas_h := int((ascent + descent + line_gap) * f64(lines.len)) + 2 * margin

	mut canvas := paint.new_canvas(canvas_w, canvas_h, 0xff)
	mut baseline := f64(margin) + ascent
	for text in lines {
		canvas.draw_line(fs, ctx, text, baseline, em_px)
		baseline += ascent + descent + line_gap
	}

	canvas.write_png('hello.png')
	println('shaped ${lines.len} lines at ${em_px:.0f}px')
}
