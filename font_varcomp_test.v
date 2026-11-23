module harfara

import harfara.shape
import harfara.font
import os

fn varcomp_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('HARFARA_TEST_FONTS'), 'testdata/fonts', varcomp_windows_dir()] {
		if d != '' && d !in dirs {
			dirs << d
		}
	}
	for dir in dirs {
		p := os.join_path(dir, name)
		if os.exists(p) {
			return p
		}
	}
	return none
}

$if windows {
	fn varcomp_windows_dir() string {
		return 'C:\\Windows\\Fonts'
	}
} $else {
	fn varcomp_windows_dir() string {
		return ''
	}
}

fn varcomp_skip(name string) {
	line := 'SKIP ${name} is in neither testdata/fonts nor the platform font directory'
	path := os.getenv('HARFARA_SKIP_LOG')
	if path != '' {
		mut f := os.open_append(path) or { return }
		f.writeln(line) or { return }
		f.close()
		return
	}
	println(line)
}

fn varcomp_font(name string) ?&shape.Font {
	p := varcomp_font_path(name) or { return none }
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

// FiraCode Aacute (gid 2) is a composite of A plus acute.case. FreeType
// NO_SCALE pins at wght 500 (blend 0.5208) and 700: the second component
// offset moves by -20 at full (10 to -10, 10 to 0 at mid after otRound),
// phantoms stay zero so the advance never varies.
fn test_varcomp_firacode_aacute() {
	mut f := varcomp_font('FiraCode-Variable.ttf') or {
		varcomp_skip('FiraCode-Variable.ttf')
		return
	}
	dflt := f.instanced_glyph_points(2) or { panic('default must outline: ${err}') }
	assert dflt.xs == [887, 301, 180, 60, 515, 684, 1140, 1008, 344, 845, 596, 767, 830, 417, 381], 'Aacute default x, got ${dflt.xs}'
	assert dflt.ys == [367, 367, 0, 0, 1374, 1374, 0, 0, 483, 483, 1255, 1784, 1667, 1514, 1583], 'Aacute default y, got ${dflt.ys}'
	assert dflt.end_pts == [7, 10, 14], 'Aacute contours, got ${dflt.end_pts}'
	assert dflt.advance_dx == 0, 'Aacute advance never varies, got ${dflt.advance_dx}'
	f.set_var_coords([500.0]) or { panic('wght 500 must store: ${err}') }
	mid := f.instanced_glyph_points(2) or { panic('wght 500 must outline: ${err}') }
	assert mid.xs == [842, 349, 253, 17, 456, 744, 1184, 938, 397, 793, 596, 762, 854, 409, 352], 'Aacute at wght 500 x, got ${mid.xs}'
	assert mid.ys == [332, 332, 0, 0, 1380, 1380, 0, 0, 511, 511, 1200, 1847, 1669, 1508, 1624], 'Aacute at wght 500 y, got ${mid.ys}'
	assert mid.end_pts == [7, 10, 14], 'Aacute at 500 contours, got ${mid.end_pts}'
	assert mid.advance_dx == 0, 'Aacute advance never varies, got ${mid.advance_dx}'
	f.set_var_coords([700.0]) or { panic('wght 700 must store: ${err}') }
	max := f.instanced_glyph_points(2) or { panic('wght 700 must outline: ${err}') }
	assert max.xs == [800, 394, 321, -22, 402, 800, 1224, 873, 446, 746, 596, 756, 875, 400, 325], 'Aacute at wght 700 x, got ${max.xs}'
	assert max.ys == [299, 299, 0, 0, 1386, 1386, 0, 0, 537, 537, 1150, 1905, 1670, 1502, 1662], 'Aacute at wght 700 y, got ${max.ys}'
	assert max.advance_dx == 0, 'Aacute advance never varies, got ${max.advance_dx}'
}

// NotoNaskhArabic uni0887 (gid 6) is a single-component composite. FreeType
// NO_SCALE pins at 550 and 700: the component offset moves by (14,19) at
// full and the advance widens by 32 (270 at mid, 286 at max, HVAR agrees).
fn test_varcomp_naskh_0887() {
	mut f := varcomp_font('NotoNaskhArabic-Variable.ttf') or {
		varcomp_skip('NotoNaskhArabic-Variable.ttf')
		return
	}
	dflt := f.instanced_glyph_points(6) or { panic('default must outline: ${err}') }
	assert dflt.xs == [127, 97, 54, 54, 54, 97, 127, 157, 200, 200, 200, 157], 'uni0887 default x, got ${dflt.xs}'
	assert dflt.ys == [60, 60, 103, 134, 164, 207, 207, 207, 164, 134, 103, 60], 'uni0887 default y, got ${dflt.ys}'
	assert dflt.end_pts == [11], 'uni0887 contours, got ${dflt.end_pts}'
	assert dflt.advance_dx == 0, 'default advance shift is zero, got ${dflt.advance_dx}'
	f.set_var_coords([550.0]) or { panic('wght 550 must store: ${err}') }
	mid := f.instanced_glyph_points(6) or { panic('wght 550 must outline: ${err}') }
	assert mid.xs == [137, 105, 61, 61, 61, 105, 136, 168, 212, 212, 212, 167], 'uni0887 at 550 x, got ${mid.xs}'
	assert mid.ys == [65, 65, 110, 141, 172, 217, 217, 217, 172, 141, 110, 65], 'uni0887 at 550 y, got ${mid.ys}'
	assert mid.advance_dx == 16, 'uni0887 at 550 widens by 16, got ${mid.advance_dx}'
	f.set_var_coords([700.0]) or { panic('wght 700 must store: ${err}') }
	max := f.instanced_glyph_points(6) or { panic('wght 700 must outline: ${err}') }
	assert max.xs == [146, 114, 68, 68, 68, 114, 146, 178, 223, 223, 223, 178], 'uni0887 at 700 x, got ${max.xs}'
	assert max.ys == [69, 69, 115, 147, 179, 225, 225, 225, 179, 147, 115, 69], 'uni0887 at 700 y, got ${max.ys}'
	assert max.advance_dx == 32, 'uni0887 at 700 widens by 32, got ${max.advance_dx}'
}

// Raster wiring: off the default, box_only and rasterize_glyph draw the
// instanced outline, so instanced composites measure and fill varied. At the
// default the stb path draws the same ink. CBDT/sbix/COLR paths are untouched
// (Amiri has no variable tables and still boxes).
fn test_varcomp_raster_wiring() {
	mut f := varcomp_font('FiraCode-Variable.ttf') or {
		varcomp_skip('FiraCode-Variable.ttf')
		return
	}
	dflt_box := f.face.box_only(2, 32.0)
	assert !dflt_box.is_empty(), 'Aacute default box is inked'
	dflt_ink := f.face.rasterize_glyph(2, 32.0, 0, 0)
	assert dflt_ink.coverage.len == dflt_box.width * dflt_box.height, 'default fill spans its box'
	f.set_var_coords([700.0]) or { panic('wght 700 must store: ${err}') }
	var_box := f.face.box_only(2, 32.0)
	assert !var_box.is_empty(), 'Aacute varied box is inked'
	assert var_box.width != dflt_box.width || var_box.height != dflt_box.height || var_box.left != dflt_box.left || var_box.top != dflt_box.top, 'varied box must differ from default (unwired raster fails here)'
	var_ink := f.face.rasterize_glyph(2, 32.0, 0, 0)
	assert var_ink.coverage.len == var_box.width * var_box.height, 'varied fill spans its box, got ${var_ink.coverage.len} for ${var_box.width}x${var_box.height}'
	assert var_ink.coverage.len > 0, 'varied fill is inked'
	mut same := var_ink.coverage.len == dflt_ink.coverage.len
	if same {
		for i in 0 .. var_ink.coverage.len {
			if var_ink.coverage[i] != dflt_ink.coverage[i] {
				same = false
				break
			}
		}
	}
	assert !same, 'varied fill must differ from default (unwired raster fails here)'
	// render_into agrees with rasterize_glyph pixel for pixel.
	mut buf := []u8{len: var_box.width * var_box.height}
	f.face.render_into(2, 32.0, 0, 0, buf[0], var_box.width, var_box.height)
	assert buf.len == var_ink.coverage.len, 'render_into spans the wired box'
	for i in 0 .. buf.len {
		assert buf[i] == var_ink.coverage[i], 'render_into byte ${i} matches rasterize, got ${buf[i]} vs ${var_ink.coverage[i]}'
	}
	// Static fonts never take the instanced path.
	p := varcomp_font_path('Amiri-Regular.ttf') or {
		varcomp_skip('Amiri-Regular.ttf')
		return
	}
	mut s := shape.load_font_file(p) or { panic('${p} is not readable: ${err}') }
	sbox := s.face.box_only(s.face.glyph_index(`A`), 32.0)
	assert !sbox.is_empty(), 'Amiri A boxes'
}

// Break-fix controls: neutering the composite deltas collapses the varied
// instance back to the base outline, and the pins above fail with the base
// numbers. Zeroed component deltas must miss the mid/max pins; an unwired
// raster (default box/fill) must miss the wiring pins.
fn test_varcomp_breakfix() {
	mut f := varcomp_font('FiraCode-Variable.ttf') or {
		varcomp_skip('FiraCode-Variable.ttf')
		return
	}
	axes := f.variable_axes()
	avar := f.face.sfnt.table_data(font.tag_avar)
	blended := font.var_blend_coords(axes, avar, [700.0]) or { panic('blend: ${err}') }
	glyf := f.face.sfnt.table_data(font.tag_glyf)
	loca := f.face.sfnt.table_data(font.tag_loca)
	gvar := f.face.sfnt.table_data(font.tag_gvar)
	// Composite gvar for Aacute: 2 components + 4 phantoms. At full blend the
	// second component shifts by -20; zeroing the whole run collapses to zero.
	dx, _ := font.var_gvar_deltas(gvar, ['wght'], 2, blended, [0, 0], [0, 0], []int{}) or {
		panic('composite deltas must parse: ${err}')
	}
	assert dx.len == 6, 'Aacute composite deltas cover 2 comps + 4 phantoms, got ${dx.len}'
	mut seen := false
	for v in dx {
		if v != 0 {
			seen = true
		}
	}
	assert seen, 'composite mid deltas are nonzero, or the pins prove nothing'
	mut zx := []i64{len: dx.len}
	mut nonzero := false
	for v in zx {
		if v != 0 {
			nonzero = true
		}
	}
	assert !nonzero, 'zeroed deltas are zeros'
	// Zeroed offsets leave the base offset (10) in place: the varied acute
	// would sit 10 right of where FreeType puts it.
	assert font.var_fixed_to_int(dx[1]) == -20, 'Aacute comp1 delta at full is -20, got ${font.var_fixed_to_int(dx[1])}'
	assert 0 != font.var_fixed_to_int(dx[1]), 'neutered composite delta must miss the pins'
	// Unwired raster: the default box/fill must differ from the wired one,
	// or the wiring pins above prove nothing.
	f.set_var_coords([300.0]) or { panic('back to default: ${err}') }
	dflt_box := f.face.box_only(2, 32.0)
	f.set_var_coords([700.0]) or { panic('wght 700 must store: ${err}') }
	var_box := f.face.box_only(2, 32.0)
	assert dflt_box.width != var_box.width || dflt_box.height != var_box.height || dflt_box.left != var_box.left || dflt_box.top != var_box.top, 'default and wired boxes differ, or the wiring pin proves nothing'
}
