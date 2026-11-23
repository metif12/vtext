// hello is the smallest program that proves the whole harfara pipeline: text in, positioned glyphs in a
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

import harfara
import paint
import corpus
import harfara.shape

// The two corpus fonts, by role. FiraCode-Variable covers Latin, Cyrillic and Greek and no
// Arabic at all; Amiri-Regular covers Arabic including the Persian additions (peh, cheh, gaf,
// jeh, yeh, keheh) and the Urdu letters (bari-ye, heh-doachashmee), plus basic Latin. Both
// ship in testdata/fonts, so this example opens the same files on every platform.

// Four lines, so one command shows four things at once.
//
// Persian rather than Arabic because it has more to get right in one line. It has letters Arabic does
// not, a yeh and a keheh of its own, a half space that stops two letters joining, and digits that are
// not the ones a Latin keyboard produces. The middle line is a single Persian word; the third is mostly
// Persian with one English word inside it, which is where bidirectional reordering has to do something.
//
// The second line puts Latin, Cyrillic, Greek and Arabic side by side to show the script routing:
// every script in it comes from a different part of the font set. The fourth line adds the Persian
// gaf/cheh/peh/jeh cluster and the Urdu bari-ye and heh-doachashmee, which are the codepoints a
// Latin-plus-Arabic font pair is most likely to be missing.
//
// The half space in the first line is written as U+200C rather than typed as one, and that is worth
// being deliberate about. It has no width and nothing to see, so a ZWNJ in a string literal looks
// exactly like the same word without one, and the one word here that depends on it would otherwise be
// unreviewable: delete the character and the line still reads correctly, but it means something else.
const lines = [
	'شکل‌دهی متن: نیم‌فاصله، چهار شکل، و خط پایه.',
	'Hello Привет Γειά سلام',
	'این یک جملهٔ فارسی است که در آن کلمهٔ hello هم آمده است.',
	'سلام دنیا گچپژ اردو ےھ',
]

// The margin and the gap between lines, in pixels. The canvas size is not written down: it is measured
// from the lines the engine lays out, so changing the text or the size cannot silently crop the last
// line, which is exactly what a fixed height does.
const margin = 40
const line_gap = 26.0
const em_px = 28.0

fn main() {
	ctx := shape.new_context()
	latin := shape.load_font_file(corpus.font('FiraCode-Variable.ttf')) or {
		panic('cannot open a Latin font: ${err}')
	}
	arabic := shape.load_font_file(corpus.font('Amiri-Regular.ttf')) or {
		panic('cannot open an Arabic font: ${err}')
	}
	// One set with both fonts in it, so a character the Latin font has no glyph for is found in the
	// Arabic one rather than drawn as a box. Order is preference: the first font that covers a
	// character wins.
	//
	// Except that a flat order is not enough here, because both fonts cover Latin. A chain of
	// (latin, arabic) would still work for Arabic, but a chain of (arabic, latin) draws the English,
	// Cyrillic and Greek words in a naskh face. The set is given per script instead: Arabic goes to
	// the Arabic font and everything else to FiraCode, which is what handing over two fonts and one
	// mixed line was supposed to mean.
	fs := shape.new_script_font_set(arabic, latin)

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
