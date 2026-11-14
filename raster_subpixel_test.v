module main

import os
import vtext
import vtext.shape

// Rasterization at quarter-pixel offsets.
//
// These are not tests of this repository's own logic so much as a question asked of the
// binding underneath it: does a glyph rasterize at *every* quarter-pixel offset, or only
// at some of them?
//
// The question was asked because vweb's text layer loses glyphs. A page renders with
// holes in it -- "Block layout and pai" -- and the measurement was that ten `i` glyphs
// in a row at 16 pixels produced six empty bitmaps, while the body text of an ordinary
// page lost 70 of its 125. Nothing above this layer can see why: `rasterize` returns a
// bitmap with no area and the caller has nothing to work with.
//
// An empty bitmap is legitimate for a glyph with no outline, which is what a space is.
// So the assertions here are about a glyph that certainly has one.

// face_path returns a font file from the first search directory that has it, so the test
// does not depend on which fonts this machine has beyond the one it needs.
fn face_path(base string) string {
	for dir in [os.getenv('WINDIR'), '/usr/share/fonts', '/System/Library/Fonts'] {
		if dir == '' {
			continue
		}
		p := dir + '/Fonts/' + base
		if os.exists(p) {
			return p
		}
		p2 := dir + '/' + base
		if os.exists(p2) {
			return p2
		}
	}
	return ''
}

fn load_any() !&shape.Font {
	for base in ['segoeui.ttf', 'arial.ttf', 'DejaVuSans.ttf', 'Helvetica.ttc'] {
		p := face_path(base)
		if p == '' {
			continue
		}
		if f := shape.load_font_file(p) {
			return f
		}
	}
	return error('no usable font found')
}

fn test_a_narrow_glyph_rasterizes_at_every_quarter_pixel() {
	// The narrow one first, because it is the one that fails. `i` is a stem: at 16 pixels
	// its ink is about one pixel wide, so a quarter-pixel shift is a large fraction of its
	// width and the box it is measured in has the least room to survive rounding.
	f := load_any() or { return }
	gid := f.glyph_index(`i`)
	assert gid != 0
	for sub in [0, 1, 2, 3] {
		bm := f.rasterize(u16(gid), 16.0, sub, 0)
		assert bm.width > 0 && bm.height > 0
	}
}

fn test_a_wide_glyph_rasterizes_at_every_quarter_pixel() {
	// The contrast case. If `m` is fine at every offset and `i` is not, the difference is
	// the width of the ink and not the size, the weight, or the offset handling.
	f := load_any() or { return }
	gid := f.glyph_index(`m`)
	assert gid != 0
	for sub in [0, 1, 2, 3] {
		bm := f.rasterize(u16(gid), 16.0, sub, 0)
		assert bm.width > 0 && bm.height > 0
	}
}

fn test_a_space_has_no_bitmap_and_that_is_correct() {
	// The control. If this one starts failing, the loop above has stopped testing what it
	// was written to test.
	f := load_any() or { return }
	gid := f.glyph_index(` `)
	bm := f.rasterize(u16(gid), 16.0, 0, 0)
	assert bm.width <= 0 || bm.height <= 0
}

fn test_a_narrow_glyph_rasterizes_at_several_sizes() {
	f := load_any() or { return }
	gid := f.glyph_index(`i`)
	for px in [12.0, 16.0, 24.0, 32.0] {
		for sub in [0, 1, 2, 3] {
			bm := f.rasterize(u16(gid), px, sub, 0)
			assert bm.width > 0 && bm.height > 0
		}
	}
}

fn test_a_narrow_glyph_rasterizes_on_the_y_axis_too() {
	// Only x was measured. The same rounding applies to y and nobody has looked.
	f := load_any() or { return }
	gid := f.glyph_index(`i`)
	for sub in [0, 1, 2, 3] {
		bm := f.rasterize(u16(gid), 16.0, 0, sub)
		assert bm.width > 0 && bm.height > 0
	}
}
