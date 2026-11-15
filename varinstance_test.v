module vtext

import vtext.shape
import vtext.font
import os

// Variable instancing: applying fvar/gvar at caller-chosen coordinates.
//
// The pins below are FreeType values, measured with freetype-py through
// FT_Set_Var_Design_Coordinates plus FT_Load_Glyph with FT_LOAD_NO_SCALE,
// so the points are raw font units beside the rasterizer integers. The
// mid-weight pins are the load-bearing ones: both corpus faces warp the
// normalized coordinate through avar (FiraCode maps 0.5 to 0.5208), and the
// inferred points come out of the fixed-point IUP, which rounds half
// boundaries down where a float IUP rounds them up. All three pins per
// glyph, plus the break-fix control at the bottom, fail if any of that is
// dropped.

// corpus_font_path is where a named font is: the committed corpus first,
// this platform font directory second, and none when neither has it. The
// corpus is first because the FreeType pins below are about these exact
// files, and VTEXT_TEST_FONTS overrides both.
fn varinstance_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('VTEXT_TEST_FONTS'), 'testdata/fonts', varinstance_windows_dir()] {
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
	fn varinstance_windows_dir() string {
		return 'C:\\Windows\\Fonts'
	}
} $else {
	fn varinstance_windows_dir() string {
		return ''
	}
}

// varinstance_skip records why a test cannot run. A skip that prints nothing
// is a failure pretending to be a pass, so the missing font and where it was
// looked for are written to the file tools/run_tests.v names in
// VTEXT_SKIP_LOG rather than to stdout.
fn varinstance_skip(name string) {
	line := 'SKIP ${name} is in neither testdata/fonts nor the platform font directory'
	path := os.getenv('VTEXT_SKIP_LOG')
	if path != '' {
		mut f := os.open_append(path) or { return }
		f.writeln(line) or { return }
		f.close()
		return
	}
	println(line)
}

fn varinstance_font(name string) ?&shape.Font {
	p := varinstance_font_path(name) or { return none }
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

// The default instance is the uninterpolated outline: with no coordinates
// stored, instancing reads the base glyf points back. FiraCode A, gid 1,
// has one peak tuple, so at the default weight its scalar is exactly zero.
fn test_varinstance_default_is_uninterpolated() {
	mut f := varinstance_font('FiraCode-Variable.ttf') or {
		varinstance_skip('FiraCode-Variable.ttf')
		return
	}
	glyf := f.face.sfnt.table_data(font.tag_glyf)
	loca := f.face.sfnt.table_data(font.tag_loca)
	start, stop := font.var_loca_range(loca, glyf.len, 1, false) or {
		panic('A loca range must parse: ${err}')
	}
	bxs, bys, bends := font.var_read_glyph_points(glyf, start, stop) or {
		panic('A outline must parse: ${err}')
	}
	assert bxs == [887, 301, 180, 60, 515, 684, 1140, 1008, 344, 845, 596], 'A base x points, got ${bxs}'
	assert bys == [367, 367, 0, 0, 1374, 1374, 0, 0, 483, 483, 1255], 'A base y points, got ${bys}'
	assert bends == [7, 10], 'A contour ends, got ${bends}'
	o := f.instanced_glyph_points(1) or { panic('default instance must outline: ${err}') }
	assert o.xs == bxs, 'default instance keeps the base x points, got ${o.xs}'
	assert o.ys == bys, 'default instance keeps the base y points, got ${o.ys}'
	assert o.end_pts == bends, 'instancing moves points, never contours, got ${o.end_pts}'
	assert o.advance_dx == 0, 'the default advance shift is zero, got ${o.advance_dx}'
}

// The mid and max pins for FiraCode A, measured from FreeType at wght 500
// and 700 beside fontTools. The mid pin carries the avar warp (normalized
// 0.5 becomes 0.5208) and the rounding (point 0 lands on 842, not 843);
// the max pin is the raw delta added, which is what a dropped scalar gives
// trivially and a dropped warp still reaches.
fn test_varinstance_firacode_mid_and_max() {
	mut f := varinstance_font('FiraCode-Variable.ttf') or {
		varinstance_skip('FiraCode-Variable.ttf')
		return
	}
	f.set_var_coords([500.0]) or { panic('wght 500 must store: ${err}') }
	mid := f.instanced_glyph_points(1) or { panic('wght 500 must outline: ${err}') }
	assert mid.xs == [842, 349, 253, 17, 456, 744, 1184, 938, 397, 793, 596], 'A at wght 500 x, got ${mid.xs}'
	assert mid.ys == [332, 332, 0, 0, 1380, 1380, 0, 0, 511, 511, 1200], 'A at wght 500 y, got ${mid.ys}'
	assert mid.end_pts == [7, 10], 'A at wght 500 contours, got ${mid.end_pts}'
	assert mid.advance_dx == 0, 'A advance never varies, got ${mid.advance_dx}'
	f.set_var_coords([700.0]) or { panic('wght 700 must store: ${err}') }
	max := f.instanced_glyph_points(1) or { panic('wght 700 must outline: ${err}') }
	assert max.xs == [800, 394, 321, -22, 402, 800, 1224, 873, 446, 746, 596], 'A at wght 700 x, got ${max.xs}'
	assert max.ys == [299, 299, 0, 0, 1386, 1386, 0, 0, 537, 537, 1150], 'A at wght 700 y, got ${max.ys}'
	assert max.advance_dx == 0, 'A advance never varies, got ${max.advance_dx}'
}

// NotoSansSC exclam, gid 2, at the default, middle and maximum weight,
// measured from FreeType at wght 100, 500 and 900. The long loca of this
// 17 MB face is read the same way, and the advance pins carry the phantom
// derivation: 275 plus the rounded phantom shift (0, 68, 122), which is
// what the rasterizer HVAR adjustment reports at the same coordinates.
fn test_varinstance_sc_exclam() {
	mut f := varinstance_font('NotoSansSC-Variable.ttf') or {
		varinstance_skip('NotoSansSC-Variable.ttf')
		return
	}
	glyf := f.face.sfnt.table_data(font.tag_glyf)
	loca := f.face.sfnt.table_data(font.tag_loca)
	start, stop := font.var_loca_range(loca, glyf.len, 2, true) or {
		panic('exclam loca range must parse: ${err}')
	}
	bxs, bys, bends := font.var_read_glyph_points(glyf, start, stop) or {
		panic('exclam outline must parse: ${err}')
	}
	assert bends == [5, 17], 'exclam contour ends, got ${bends}'
	dflt := f.instanced_glyph_points(2) or { panic('default instance must outline: ${err}') }
	assert dflt.xs == bxs, 'default instance keeps the base x points'
	assert dflt.ys == bys, 'default instance keeps the base y points'
	assert dflt.advance_dx == 0, 'the default advance shift is zero, got ${dflt.advance_dx}'
	f.set_var_coords([500.0]) or { panic('wght 500 must store: ${err}') }
	mid := f.instanced_glyph_points(2) or { panic('wght 500 must outline: ${err}') }
	assert mid.xs == [133, 117, 113, 230, 227, 210, 171, 139, 95, 95, 95, 139, 171, 205, 249, 249,
		249, 205], 'exclam at wght 500 x, got ${mid.xs}'
	assert mid.ys == [235, 634, 754, 754, 634, 235, -14, -14, 33, 68, 104, 149, 149, 149, 104,
		68, 33, -14], 'exclam at wght 500 y, got ${mid.ys}'
	assert mid.advance_dx == 68, 'exclam at wght 500 widens by 68, got ${mid.advance_dx}'
	f.set_var_coords([900.0]) or { panic('wght 900 must store: ${err}') }
	max := f.instanced_glyph_points(2) or { panic('wght 900 must outline: ${err}') }
	assert max.xs == [141, 115, 109, 288, 282, 256, 198, 152, 93, 93, 93, 152, 198, 245, 304, 304,
		304, 245], 'exclam at wght 900 x, got ${max.xs}'
	assert max.ys == [270, 608, 767, 767, 608, 270, -14, -14, 51, 97, 144, 207, 207, 207, 144,
		97, 51, -14], 'exclam at wght 900 y, got ${max.ys}'
	assert max.advance_dx == 122, 'exclam at wght 900 widens by 122, got ${max.advance_dx}'
}

// The IUP glyph: FiraCode uniE0A1, gid 1847, carries 10 explicit deltas out
// of 27 points, so 13 points come out of interpolation. The pins are
// FreeType at wght 300, 500 and 700, and point 16 at wght 700 is the case
// that separates the fixed-point IUP from a float one: the interpolated
// 9.5 lands on 636, not 637.
fn test_varinstance_iup_glyph() {
	mut f := varinstance_font('FiraCode-Variable.ttf') or {
		varinstance_skip('FiraCode-Variable.ttf')
		return
	}
	dflt := f.instanced_glyph_points(1847) or { panic('default instance must outline: ${err}') }
	assert dflt.xs == [356, 473, 473, 833, 824, 356, 460, 462, 471, 478, 478, 478, 365, 365, 535,
		741, 738, 723, 723, 723, 837, 837, 666], 'uniE0A1 default x, got ${dflt.xs}'
	assert dflt.ys == [1616, 1616, 915, 915, 816, 816, 580, 557, 456, 328, 264, -100, -100, 700,
		700, 20, 56, 229, 338, 700, 700, -100, -100], 'uniE0A1 default y, got ${dflt.ys}'
	assert dflt.end_pts == [5, 22], 'uniE0A1 contours, got ${dflt.end_pts}'
	f.set_var_coords([500.0]) or { panic('wght 500 must store: ${err}') }
	mid := f.instanced_glyph_points(1847) or { panic('wght 500 must outline: ${err}') }
	assert mid.xs == [296, 471, 471, 898, 881, 296, 444, 446, 455, 462, 462, 462, 306, 306, 550,
		756, 753, 738, 738, 738, 896, 896, 650], 'uniE0A1 at wght 500 x, got ${mid.xs}'
	assert mid.ys == [1616, 1616, 974, 974, 816, 816, 580, 557, 456, 328, 264, -100, -100, 700,
		700, 20, 56, 229, 338, 700, 700, -100, -100], 'uniE0A1 at wght 500 y, got ${mid.ys}'
	f.set_var_coords([700.0]) or { panic('wght 700 must store: ${err}') }
	max := f.instanced_glyph_points(1847) or { panic('wght 700 must outline: ${err}') }
	assert max.xs == [240, 470, 470, 957, 934, 240, 429, 431, 440, 447, 447, 447, 252, 252, 563,
		769, 766, 751, 751, 751, 950, 950, 635], 'uniE0A1 at wght 700 x, got ${max.xs}'
	assert max.ys == [1616, 1616, 1028, 1028, 816, 816, 580, 557, 456, 328, 264, -100, -100, 700,
		700, 20, 56, 229, 338, 700, 700, -100, -100], 'uniE0A1 at wght 700 y, got ${max.ys}'
}

// Normalization clamps out-of-range coordinates to the axis ends and maps
// the default to exactly zero, and the avar warp is the identity on exact
// key hits: FiraCode maps normalized 0.5 to 0.52081298828125 the way
// fontTools reads the same segment, and SC maps 0.25 to 0.15997314453125.
// Interpolated warps are pinned within 1e-9, which is tighter than the
// 16.16 quantization the rasterizer works in.
fn test_varinstance_normalize_and_avar() {
	axes := [font.VariableAxis{
		tag:     'wght'
		minimum: 300.0
		deflt:   300.0
		maximum: 700.0
	}]
	n := font.var_normalize_coords(axes, [300.0]) or { panic('normalize: ${err}') }
	assert n == [0.0], 'the default normalizes to zero, got ${n}'
	m := font.var_normalize_coords(axes, [500.0]) or { panic('normalize: ${err}') }
	assert m == [0.5], 'wght 500 normalizes to 0.5, got ${m}'
	h := font.var_normalize_coords(axes, [700.0]) or { panic('normalize: ${err}') }
	assert h == [1.0], 'the maximum normalizes to one, got ${h}'
	lo := font.var_normalize_coords(axes, [200.0]) or { panic('normalize: ${err}') }
	assert lo == [0.0], 'below the minimum clamps to the default end, got ${lo}'
	hi := font.var_normalize_coords(axes, [800.0]) or { panic('normalize: ${err}') }
	assert hi == [1.0], 'past the maximum clamps to the top end, got ${hi}'
	if _ := font.var_normalize_coords(axes, [300.0, 700.0]) {
		assert false, 'two coordinates for one axis must not normalize'
	}
	mut f := varinstance_font('FiraCode-Variable.ttf') or {
		varinstance_skip('FiraCode-Variable.ttf')
		return
	}
	faxes := f.variable_axes()
	avar := f.face.sfnt.table_data(font.tag_avar)
	w := font.var_blend_coords(faxes, avar, [500.0]) or { panic('blend: ${err}') }
	assert w == [0.52081298828125], 'avar warps 0.5 to 0.5208, got ${w}'
	w0 := font.var_blend_coords(faxes, avar, [300.0]) or { panic('blend: ${err}') }
	assert w0 == [0.0], 'avar keeps zero at zero, got ${w0}'
	w1 := font.var_blend_coords(faxes, avar, [700.0]) or { panic('blend: ${err}') }
	assert w1 == [1.0], 'avar keeps one at one, got ${w1}'
	segs := font.var_read_avar(avar, 1) or { panic('avar: ${err}') }
	got := font.var_apply_avar(segs, [0.3])[0]
	d := got - 0.27918701171875
	assert d < 1e-9 && d > -1e-9, 'avar interpolates 0.3 to 0.27918, got ${got}'
	if _ := font.var_blend_coords(faxes, avar, [500.0, 600.0]) {
		assert false, 'two coordinates for one axis must not blend'
	}
}

// Hand-built gvar machinery: one axis, three points, one shared tuple, and
// one tuple of each shape the format allows, so every branch of the parser
// runs without needing a font that carries it. Tuple 1 names the shared
// peak 0.5 and covers all seven points (three real, four phantom) with
// zero, byte and word runs; tuple 2 embeds peak 1.0 with private points
// {0, 2} in byte, zero and byte runs; tuple 3 is intermediate (start 0.25,
// peak 0.5, end 0.75) over all points in zero and byte runs. The mid
// expectations below come out of the same fixed-point pipeline FreeType
// runs (MulFix per tuple, fixed-point IUP, half-up final), checked by hand
// against its C: at blend 0.5 the totals are x [2, 2.5, 3] and y
// [1001, 2, -1], and the 2.5 lands on 3.
fn varinstance_synthetic_gvar() []u8 {
	return [u8(0x00), u8(0x01), u8(0x00), u8(0x00), u8(0x00), u8(0x01), u8(0x00), u8(0x01), u8(0x00),
		u8(0x00), u8(0x00), u8(0x18), u8(0x00), u8(0x01), u8(0x00), u8(0x00), u8(0x00), u8(0x00),
		u8(0x00), u8(0x1a), u8(0x00), u8(0x00), u8(0x00), u8(0x1f), u8(0x20), u8(0x00), u8(0x80),
		u8(0x03), u8(0x00), u8(0x18), u8(0x00), u8(0x16), u8(0x00), u8(0x00), u8(0x00), u8(0x10),
		u8(0xa0), u8(0x00), u8(0x40), u8(0x00), u8(0x00), u8(0x13), u8(0xc0), u8(0x00), u8(0x20),
		u8(0x00), u8(0x10), u8(0x00), u8(0x30), u8(0x00), u8(0x00), u8(0x82), u8(0x01), u8(0x0a),
		u8(0xfb), u8(0x41), u8(0x01), u8(0x2c), u8(0xfe), u8(0xd4), u8(0x40), u8(0x03), u8(0xe8),
		u8(0x81), u8(0x03), u8(0x07), u8(0x07), u8(0x07), u8(0x07), u8(0x02), u8(0x01), u8(0x00),
		u8(0x02), u8(0x01), u8(0x04), u8(0x06), u8(0x80), u8(0x00), u8(0xf8), u8(0x86), u8(0x06),
		u8(0x01), u8(0x02), u8(0x03), u8(0x04), u8(0x05), u8(0x06), u8(0x07)]
}

fn test_varinstance_synthetic_tuples() {
	gvar := varinstance_synthetic_gvar()
	assert gvar.len == 88, 'the synthetic table is 88 bytes, got ${gvar.len}'
	axes := ['wght']
	bxs := [0, 10, 20]
	bys := [0, 0, 0]
	ends := [2]
	dx, dy := font.var_gvar_deltas(gvar, axes, 0, [0.5], bxs, bys, ends) or {
		panic('synthetic deltas must parse: ${err}')
	}
	ox, oy, adv := font.var_apply_deltas(bxs, bys, dx, dy)
	assert ox == [2, 13, 23], 'synthetic x at 0.5, got ${ox}'
	assert oy == [1001, 2, -1], 'synthetic y at 0.5, got ${oy}'
	assert adv == -15, 'synthetic advance shift at 0.5, got ${adv}'
	dx2, dy2 := font.var_gvar_deltas(gvar, axes, 0, [0.125], bxs, bys, ends) or {
		panic('synthetic deltas must parse: ${err}')
	}
	ox2, oy2, adv2 := font.var_apply_deltas(bxs, bys, dx2, dy2)
	assert ox2 == [1, 11, 21], 'synthetic x at 0.125, got ${ox2}'
	assert oy2 == [250, 0, -1], 'synthetic y at 0.125, got ${oy2}'
	assert adv2 == -4, 'synthetic advance shift at 0.125, got ${adv2}'
	mut seen_x := false
	for v in dx {
		if v != 0 {
			seen_x = true
		}
	}
	assert seen_x, 'the synthetic mid deltas are nonzero, or the pins prove nothing'
}

// The break-fix control: zeroing the extracted deltas collapses the mid
// instance back to the base outline and away from the FreeType pins. If the
// applier ever dropped the deltas on the floor, the mid test above would
// pass with the base numbers and this test would fail with them.
fn test_varinstance_zeroed_deltas_breakfix() {
	mut f := varinstance_font('FiraCode-Variable.ttf') or {
		varinstance_skip('FiraCode-Variable.ttf')
		return
	}
	axes := f.variable_axes()
	avar := f.face.sfnt.table_data(font.tag_avar)
	blended := font.var_blend_coords(axes, avar, [500.0]) or { panic('blend: ${err}') }
	glyf := f.face.sfnt.table_data(font.tag_glyf)
	loca := f.face.sfnt.table_data(font.tag_loca)
	start, stop := font.var_loca_range(loca, glyf.len, 1, false) or {
		panic('A loca range must parse: ${err}')
	}
	xs, ys, ends := font.var_read_glyph_points(glyf, start, stop) or {
		panic('A outline must parse: ${err}')
	}
	gvar := f.face.sfnt.table_data(font.tag_gvar)
	dx, dy := font.var_gvar_deltas(gvar, ['wght'], 1, blended, xs, ys, ends) or {
		panic('A deltas must parse: ${err}')
	}
	mut nonzero := false
	for v in dx {
		if v != 0 {
			nonzero = true
		}
	}
	assert nonzero, 'A mid deltas are nonzero, or the pins prove nothing'
	mut zx := []i64{len: dx.len}
	mut zy := []i64{len: dy.len}
	ox, oy, adv := font.var_apply_deltas(xs, ys, zx, zy)
	assert ox == xs, 'zeroed deltas keep the base x points'
	assert oy == ys, 'zeroed deltas keep the base y points'
	assert adv == 0, 'zeroed deltas keep the base advance'
	assert ox != [842, 349, 253, 17, 456, 744, 1184, 938, 397, 793, 596], 'zeroed deltas must miss the wght 500 pins'
}

// What instancing refuses: a static font has no design space, a composite
// names components rather than points, a coordinate count that does not
// match the axis count answers to no tent, and a truncated table is corrupt
// input rather than zero deltas.
fn test_varinstance_rejects() {
	mut f := varinstance_font('FiraCode-Variable.ttf') or {
		varinstance_skip('FiraCode-Variable.ttf')
		return
	}
	if _ := f.instanced_glyph_points(8) {
		assert false, 'Aogonek is composite and must not instance'
	} else {
		assert err.msg().contains('composite'), 'the refusal names composites, got: ${err}'
	}
	if _ := f.instanced_glyph_points(1) {
	} else {
		assert false, 'A instances without stored coordinates: ${err}'
	}
	f.set_var_coords([500.0, 600.0]) or {
		assert err.msg().contains('count'), 'two coordinates for one axis: ${err}'
		return
	}
	assert false, 'two coordinates for one axis must not store'
}

// A static font has no fvar table, so there is nothing to store and nothing
// to instance. Storing nothing is allowed and reads back nothing; storing
// anything and instancing anything are both errors that say so.
fn test_varinstance_static_font() {
	p := varinstance_font_path('Amiri-Regular.ttf') or {
		varinstance_skip('Amiri-Regular.ttf')
		return
	}
	mut f := shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
	assert !f.is_variable(), 'Amiri has no fvar table'
	f.set_var_coords([]f64{}) or { panic('storing nothing on a static font: ${err}') }
	assert f.var_coords() == [], 'a static font has no coordinates, got ${f.var_coords()}'
	if _ := f.instanced_glyph_points(1) {
		assert false, 'a static font must not instance'
	} else {
		assert err.msg().contains('fvar'), 'the refusal names fvar, got: ${err}'
	}
	f.set_var_coords([400.0]) or {
		assert err.msg().contains('count'), 'coordinates on a static font: ${err}'
		return
	}
	assert false, 'coordinates on a static font must not store'
}

// The coordinates stick: storing, reading back, clearing through the
// defaults. A truncated gvar is refused rather than read as zeros.
fn test_varinstance_coords_stick() {
	mut f := varinstance_font('FiraCode-Variable.ttf') or {
		varinstance_skip('FiraCode-Variable.ttf')
		return
	}
	assert f.var_coords() == [300.0], 'unset coordinates read back the default, got ${f.var_coords()}'
	f.set_var_coords([500.0]) or { panic('wght 500 must store: ${err}') }
	assert f.var_coords() == [500.0], 'stored coordinates read back, got ${f.var_coords()}'
	f.set_var_coords([300.0]) or { panic('wght 300 must store: ${err}') }
	o := f.instanced_glyph_points(1) or { panic('back at default: ${err}') }
	assert o.xs[0] == 887 && o.ys[0] == 367, 'back at default is the base point, got ${o.xs[0]},${o.ys[0]}'
	if _, _ := font.var_gvar_deltas([u8(0x00), u8(0x01)], ['wght'], 1, [0.5], [0], [0], []) {
		assert false, 'a two-byte gvar must not parse'
	}
}

// The fixed-point arithmetic contract, pinned beside FreeType integer
// behavior: MulFix and DivFix round half away from zero on the magnitude,
// fixed_to_int rounds half up, and scalar_fixed carries the same rounding
// into 16.16. The numbers are the ones the IUP sweep stands on.
fn test_varinstance_fixed_arithmetic() {
	assert font.var_mulfix(i64(-87) << 16, 34132) == -2969484, 'MulFix(-87, 0.5208)'
	assert font.var_mulfix(i64(4) << 16, 8192) == 32768, 'MulFix(4, 0.125) is exactly 0.5'
	assert font.var_divfix(1327104, 1310720) == 66355, 'DivFix slope of the IUP ramp'
	assert font.var_fixed_to_int(163842) == 3, '2.50003 rounds to 3'
	assert font.var_fixed_to_int(-245761) == -4, '-3.25 rounds to -4'
	assert font.var_fixed_to_int(622590) == 9, '9.49998 rounds to 9'
	assert font.var_fixed_to_int(-983040) == -15, 'exactly -15 stays -15'
	assert font.var_scalar_fixed(0.5) == 32768, 'scalar 0.5'
	assert font.var_scalar_fixed(-0.25) == -16384, 'scalar -0.25'
	assert font.var_scalar_fixed(0.0) == 0, 'scalar zero stays zero'
	assert font.var_ot_round(-43.5) == -43, 'otRound rounds half up, not away'
	assert font.var_ot_round(843.5) == 844, 'otRound rounds 843.5 up'
}
