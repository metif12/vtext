// mark_stack shows what mark attachment does, and what a mark looks like when nothing places it.
//
// Each row is drawn twice: once as the engine placed it, and once with every offset thrown away, so the
// two behaviours sit next to each other instead of one being asserted. The second copy is drawn by this
// program rather than by the engine, because no engine option turns attachment off, and comparing against
// a font that lacks the feature would compare two fonts rather than two behaviours.
//
// A mark has no advance and shares its base's x, so a mark drawn with its offset discarded lands exactly
// where the pen is: on the letter's left edge, at the baseline. That is the position a mark occupies when
// the font has a glyph for it and no rule to place it, and it is why Arabic drawn without mark attachment
// has its marks sitting in the corner of every letter. The horizontal rule under each column is the
// baseline, and the comparison is whether a mark sits on it.
//
// What to read off the picture, row by row:
//
//   - A fatha over a beh sits high and to the right, and a kasra under the same letter sits low. Both come
//     from the font's own anchors, and the numbers the engine prints are the design units between the
//     base's anchor and the mark's.
//   - A shadda on a kasra is a mark on a mark, which is a different table from the one that put the kasra
//     on the beh. Getting that wrong stacks the shadda over the letter instead of over the kasra, and it
//     still looks plausible, which is what makes it worth looking at.
//   - Fatha and shadda together become a single glyph by ligature substitution, so that row has no mark on
//     a mark in it at all. It is here because it looks like the row above it and is not: one glyph means
//     the ligature fired, and a y that differs from zero means a mark was placed. Conflating those two is
//     the easiest way to believe mark-to-mark works when it never ran.
//   - The marks on a lam-alef use mark-to-ligature, because the lam-alef is two characters fused into one
//     glyph and the font says which part of it each mark belongs to.
//   - The last row uses a mark the font has a glyph for and no rule anywhere. The engine finds the glyph
//     and places nothing, which is the correct answer to a font that has said nothing.
module main

import vtext
import paint

const latin_font = 'C:/Windows/Fonts/segoeui.ttf'
const arabic_font = 'C:/Windows/Fonts/tahoma.ttf'

// Row is one line of the picture: some text and what it is there to show.
struct Row {
	text  string
	about string
}

// The text is written with the marks as their own codepoints after the letter, so the engine decides where
// each one goes and this program has no say in it.
const rows = [
	Row{
		text:  'بَ'
		about: 'fatha on a letter: mark to base, one table'
	}
	Row{
		text:  'بِّ'
		about: 'shadda on the kasra: mark to mark, a different table'
	}
	Row{
		text:  'بَِّ'
		about: 'all three at once: two stacked above the letter, one below it'
	}
	Row{
		text:  'بّ'
		about: 'shadda alone: still mark to base, not a stack'
	}
	Row{
		text:  'لَّ'
		about: 'on a lam-alef: mark to ligature, and the mark belongs to one part of the pair'
	}
	Row{
		text:  'بَّ'
		about: 'fatha and shadda together: one glyph by ligature, so no mark on a mark at all'
	}
	Row{
		text:  'ب́'
		about: 'a mark no rule places: the glyph is found and positioned nowhere'
	},
]

const em_px = 56.0
const margin = 30
const row_gap = 30.0

// How far right the second copy of each row starts. The column is the widest row plus this gap, measured
// from the rows rather than written down, because the widest row depends on the font.
const column_gap = 40.0

// The rule the marks are measured against, drawn under each column. The whole comparison is "is this mark
// on the baseline or not", and a comparison nobody can measure by eye is an assertion.
const baseline_level = u8(205)

fn main() {
	ctx := vtext.new_context()
	latin := vtext.load_font_file(latin_font) or { panic('cannot open ${latin_font}: ${err}') }
	arabic := vtext.load_font_file(arabic_font) or { panic('cannot open ${arabic_font}: ${err}') }
	fs := vtext.new_font_set_of(latin, arabic)

	// What the font says it can do. Every row below depends on these three answers, and printing them
	// means a reader does not have to take the picture's word for which rules were used.
	println(arabic_font)
	println('  places marks on a base      ${arabic.has_mark_attachment()}')
	println('  stacks one mark on another  ${arabic.stacks_marks()}')
	println('  puts a mark on a ligature   ${arabic.places_marks_on_ligatures()}')

	// Lay every row out once to learn how wide it is, so the two columns can be placed and the canvas
	// sized from the text rather than from a guess.
	mut widest := 0.0
	for row in rows {
		line := vtext.layout_paragraph(ctx, row.text.runes(), .auto, fs, em_px)
		if line.width > widest {
			widest = line.width
		}
	}
	// Enough room above and below for a mark that reaches well off the letter.
	ascent := em_px * 1.15
	descent := em_px * 0.95
	column := widest + column_gap
	canvas_w := int(column * 2.0) + 2 * margin
	canvas_h := int((ascent + descent + row_gap) * f64(rows.len)) + 2 * margin

	mut canvas := paint.new_canvas(canvas_w, canvas_h, 0xff)
	mut baseline := f64(margin) + ascent
	for row in rows {
		line := vtext.layout_paragraph(ctx, row.text.runes(), .auto, fs, em_px)
		draw_row(mut canvas, line, baseline, column)
		println('')
		println('${row.about}')
		for g in line.glyphs {
			kind := if g.is_mark { 'mark' } else { 'base' }
			// A y of zero is what "not placed" looks like, so it is printed rather than assumed.
			placed := if g.y == 0.0 { 'at the pen' } else { 'placed' }
			println('    ${kind} gid=${g.gid:5} x=${g.x:7.1f} y=${g.y:8.1f} ${placed} cluster=${g.cluster}')
		}
		baseline += ascent + descent + row_gap
	}

	canvas.write_png('mark_stack.png')
}

// draw_row paints one row twice: as the engine placed it, and with the offsets discarded, with the
// baseline rule under each so the difference can be seen rather than believed.
fn draw_row(mut canvas paint.Canvas, line vtext.Line, baseline f64, column f64) {
	// The rules go down first so the ink of a letter or a mark is drawn over them rather than under them.
	canvas.rect(margin, int(baseline), int(f64(margin) + column) - column_gap_px(), int(baseline),
		baseline_level)
	canvas.rect(int(f64(margin) + column), int(baseline), canvas.w - margin - 1, int(baseline),
		baseline_level)
	for g in line.glyphs {
		if f := g.font {
			canvas.draw_glyph_at(f, g, baseline, em_px, f64(margin))
		}
	}
	for g in line.glyphs {
		if f := g.font {
			canvas.draw_glyph_at(f, at_pen(g), baseline, em_px, f64(margin) + column)
		}
	}
}

// column_gap_px is the gap as a whole number of pixels, for the rule under the first column to stop where
// the second one begins.
fn column_gap_px() int {
	return int(column_gap)
}

// at_pen returns the glyph with its placement offset discarded, so it draws at the pen.
//
// Clearing y is the whole of it, and it works because the engine stores a mark's anchor result in y: it
// puts the mark at the base's x plus the anchor's x, and at minus the anchor's y scaled to pixels. A
// glyph whose y is zero sits where the pen put it.
fn at_pen(g vtext.Glyph) vtext.Glyph {
	return vtext.Glyph{
		gid:     g.gid
		x:       g.x
		y:       0.0
		advance: g.advance
		cluster: g.cluster
		form:    g.form
		font:    g.font
	}
}
