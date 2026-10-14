// glyph_grid draws every glyph a font has, in a grid, and marks each one by whether any codepoint
// reaches it.
//
// This is the example to reach for when a shaping result looks wrong, because it turns "the font has no
// glyph for this character" from a guess into a fact. A character's absence is usually diagnosed by the
// empty box it draws, and the question that follows is always the same: is the box because the cmap does
// not name the character, or because the font has no glyph for it at all? Those are different faults with
// different fixes, and only one of them can be fixed by falling back to another font.
//
// How the two are told apart here:
//
//   - A glyph some codepoint reaches is drawn at full ink. A glyph more than one codepoint reaches is drawn
//     lighter. Consolas has 40 such glyphs: U+0000 and U+0008 both land on gid 1, and U+0020 and U+00A0
//     both land on gid 3. Two characters, one glyph, and the second is invisible.
//   - A glyph no scanned codepoint reaches is drawn faintly. Consolas has 1650 of its 3031 glyphs like
//     that. They are not broken: most are reached from the private use area or from above the range
//     scanned here, and some are there for another application entirely. The point of drawing them at all
//     is that they are real ink the engine can draw and ordinary text cannot ask for.
//
// The scan is bounded rather than exhaustive, and the bound is stated rather than hidden: U+0000 to
// U+24FF, which covers Latin, Greek, Cyrillic, Hebrew, Arabic, Syriac and their punctuation. A glyph drawn
// faintly may still be reachable above that. What this answers is not which glyphs are reachable but how
// many are reachable from ordinary text, and the counts are printed because they are the measurement.
module main

import vtext
import corpus
import paint

// The codepoint range scanned. Everything above this is not scanned.
const scan_first = 0
const scan_last = 0x2500

const cell = 34
const columns = 26
const margin = 24

// Three greys: reached by one codepoint, reached by more than one, reached by none.
const one_level = u8(40)
const many_level = u8(150)
const none_level = u8(225)

fn main() {
	f := vtext.load_font_file(corpus.font('consola.ttf', 'Amiri-Regular.ttf')) or { panic('cannot open ${err}') }
	glyphs := f.num_glyphs()
	println(corpus.font('consola.ttf', 'Amiri-Regular.ttf'))
	println('  ${glyphs} glyphs, ${f.units_per_em()} units per em')

	// The reverse map, built by asking the font forward for every codepoint in the range. There is no
	// reverse lookup in the API and there does not need to be: the font is the authority on which
	// character is which glyph, and walking the other way is harder to get wrong than reading the cmap
	// tables a second time.
	mut reached := map[u16][]rune{}
	mut scanned := 0
	for cp in scan_first .. scan_last {
		scanned++
		r := rune(cp)
		if !f.has_glyph(r) {
			continue
		}
		gid := f.glyph_index(r)
		if gid == 0 {
			// A character the font names .notdef for is absent, not present as a box. Counting it would
			// put a codepoint against the wrong glyph.
			continue
		}
		reached[gid] << r
	}

	mut one := 0
	mut many := 0
	mut unreachable := 0
	for count_index in 0 .. glyphs {
		// The lookup is not `m[k] or []rune{}`. That form compiles fine on a map whose values are
		// strings and fails on one whose values are slices of a struct or of a rune, and the failure is
		// reported as an unexpected end of file at the end of the function rather than at the line, so
		// the message points nowhere near the expression that caused it.
		//
		// Asking whether the key is there first is the form that compiles, and it reads no worse.
		mut lst := []rune{}
		if count_index in reached {
			lst = reached[u16(count_index)]
		}
		if lst.len == 1 {
			one++
		} else if lst.len > 1 {
			many++
		} else {
			unreachable++
		}
	}
	println('  scanned ${scanned} codepoints, U+${scan_first:04X}..U+${scan_last - 1:04X}')
	println('  ${one} glyphs reached by one codepoint')
	println('  ${many} reached by more than one, so the others are invisible')
	println('  ${unreachable} reached by nothing in that range')
	println('  index 0 is .notdef and is in none of those')

	// The grid: one cell per glyph, in glyph order, so a run of faint cells is a run of glyphs nothing
	// reaches rather than a gap in the drawing.
	rows := (glyphs + columns - 1) / columns
	canvas_w := columns * cell + 2 * margin
	canvas_h := rows * cell + 2 * margin
	mut canvas := paint.new_canvas(canvas_w, canvas_h, 0xff)

	for g in 1 .. glyphs {
		gid := u16(g)
		mut lst := []rune{}
		if g in reached {
			lst = reached[gid]
		}
		mut level := none_level
		if lst.len > 1 {
			level = many_level
		} else if lst.len == 1 {
			level = one_level
		}
		x := margin + (g % columns) * cell
		y := margin + (g / columns) * cell
		draw_cell(mut canvas, f, gid, x, y, level)
	}

	canvas.write_png('glyph_grid.png')
	println('  wrote a ${canvas_w}x${canvas_h} grid of ${glyphs} glyphs')
}

// draw_cell paints one glyph into a grid cell, at a grey chosen by how many codepoints reach it.
//
// The glyph is rasterised at a fraction of the cell rather than at the cell itself, so a glyph whose ink
// is as wide as its cell cannot overlap its neighbour: an overlap in a grid like this reads as a glyph in
// the wrong cell, which is exactly the misreading the grid exists to prevent.
fn draw_cell(mut canvas paint.Canvas, f &vtext.Font, gid u16, x int, y int, level u8) {
	bitmap := f.rasterize(gid, f64(cell) * 0.8, 0, 0)
	if bitmap.is_empty() {
		return
	}
	// Centred in the cell, so a glyph's position depends on its index and not on how wide it happens to be.
	ox := x + (cell - bitmap.width) / 2
	oy := y + (cell - bitmap.height) / 2
	for by in 0 .. bitmap.height {
		for bx in 0 .. bitmap.width {
			cov := bitmap.ink(bx, by)
			if cov == 0 {
				continue
			}
			// The glyph's own coverage multiplied into the level, so a glyph drawn faintly is still
			// shaped like itself rather than a flat block of grey.
			mixed := u8((int(level) * int(cov)) / 255)
			canvas.blend(ox + bx, oy + by, mixed)
		}
	}
}
