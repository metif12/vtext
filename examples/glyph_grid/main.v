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
//     lighter. Two characters, one glyph, and the second is invisible.
//   - A glyph no scanned codepoint reaches is drawn faintly. They are not broken: most are reached from
//     the private use area or from above the range scanned here, and some are there for another
//     application entirely. The point of drawing them at all is that they are real ink the engine can
//     draw and ordinary text cannot ask for.
//
// The scan is bounded rather than exhaustive, and the bound is stated rather than hidden: U+0000 to
// U+24FF, which covers Latin, Greek, Cyrillic, Hebrew, Arabic, Syriac and their punctuation. A glyph drawn
// faintly may still be reachable above that. What this answers is not which glyphs are reachable but how
// many are reachable from ordinary text, and the counts are printed because they are the measurement.
module main

import vtext
import corpus
import paint
import vtext.shape

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
	fira := shape.load_font_file(corpus.font('FiraCode-Variable.ttf')) or { panic('cannot open ${err}') }
	amiri := shape.load_font_file(corpus.font('Amiri-Regular.ttf', 'NotoNaskhArabic-Regular.ttf')) or {
		panic('cannot open ${err}')
	}
	// Two faces, same range, per-script counts: FiraCode covers Latin/Cyrillic/Greek, Amiri covers
	// Latin/Arabic-script. A faint cell means unreachable from ordinary text in that face, not absent.
	fonts := [fira, amiri]
	mut total_glyphs := 0
	mut total_rows := 0
	for f in fonts {
		glyphs := f.num_glyphs()
		total_glyphs += glyphs
		total_rows += (glyphs + columns - 1) / columns
		println('${f.path().split('/').last()}')
		println('  ${glyphs} glyphs, ${f.units_per_em()} units per em')
	}

	// The reverse maps, built by asking each font forward for every codepoint in the range.
	mut reached_list := []map[u16][]rune{cap: fonts.len}
	for f in fonts {
		mut reached := map[u16][]rune{}
		for cp in scan_first .. scan_last {
			r := rune(cp)
			if !f.has_glyph(r) {
				continue
			}
			gid := f.glyph_index(r)
			if gid == 0 {
				continue
			}
			reached[gid] << r
		}
		reached_list << reached
	}

	for fi, f in fonts {
		reached := reached_list[fi]
		glyphs := f.num_glyphs()
		mut one := 0
		mut many := 0
		mut unreachable := 0
		for count_index in 0 .. glyphs {
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
		// Per-script reached codepoints (not glyphs): Latin, Greek, Cyrillic, Arabic buckets.
		mut n_latin := 0
		mut n_greek := 0
		mut n_cyrl := 0
		mut n_arab := 0
		for _, cps in reached {
			for cp in cps {
				if (cp >= 0x20 && cp <= 0x7e) || (cp >= 0xa0 && cp <= 0xff)
					|| (cp >= 0x100 && cp <= 0x17f) {
					n_latin++
				} else if cp >= 0x370 && cp <= 0x3ff {
					n_greek++
				} else if cp >= 0x400 && cp <= 0x4ff {
					n_cyrl++
				} else if cp >= 0x600 && cp <= 0x6ff {
					n_arab++
				}
			}
		}
		println('  scanned U+${scan_first:04X}..U+${scan_last - 1:04X}')
		println('  ${one} glyphs reached by one codepoint')
		println('  ${many} reached by more than one, so the others are invisible')
		println('  ${unreachable} reached by nothing in that range')
		println('  codepoints reached: latin ${n_latin} greek ${n_greek} cyrillic ${n_cyrl} arabic ${n_arab}')
		println('  index 0 is .notdef and is in none of those')
	}

	// The grids stacked: one cell per glyph, in glyph order, so a run of faint cells is a run of
	// glyphs nothing reaches rather than a gap in the drawing.
	canvas_w := columns * cell + 2 * margin
	canvas_h := total_rows * cell + 2 * margin
	mut canvas := paint.new_canvas(canvas_w, canvas_h, 0xff)

	mut y0 := margin
	for fi, f in fonts {
		reached := reached_list[fi]
		glyphs := f.num_glyphs()
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
			y := y0 + (g / columns) * cell
			draw_cell(mut canvas, f, gid, x, y, level)
		}
		y0 += ((glyphs + columns - 1) / columns) * cell
	}

	canvas.write_png('glyph_grid.png')
	println('  wrote a ${canvas_w}x${canvas_h} grid of ${total_glyphs} glyphs')
}

// draw_cell paints one glyph into a grid cell, at a grey chosen by how many codepoints reach it.
//
// The glyph is rasterised at a fraction of the cell rather than at the cell itself, so a glyph whose ink
// is as wide as its cell cannot overlap its neighbour: an overlap in a grid like this reads as a glyph in
// the wrong cell, which is exactly the misreading the grid exists to prevent.
fn draw_cell(mut canvas paint.Canvas, f &shape.Font, gid u16, x int, y int, level u8) {
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
