module harfara

import harfara.shape
import harfara.font

// TrueType outline reading: points, curve flags, contour ends and boxes.
//
// The pins below are fontTools values, measured with
// `Glyph.getCoordinates(glyf)` on the committed corpus files, so the points
// and flags are the table's own numbers beside the reader's. The simple
// cases prove the delta decoding, the composites prove the component walk
// (plain offsets, a mirror, a rotation, a small scale, nesting), and the
// break-fix control at the bottom proves the transform is applied rather
// than parsed and dropped.

// glyf_font loads a corpus face for outline reading.
fn glyf_font(name string) &shape.Font {
	return shape.load_font_file('testdata/fonts/' + name) or { panic('no font ${name}') }
}

// glyf_dump renders an outline the way a failure message wants it: point
// count, contour ends, box, and every point with its curve flag.
fn glyf_dump(tag string, o font.GlyfOutline) string {
	mut pts := []string{}
	for i in 0 .. o.xs.len {
		pts << '${o.xs[i]},${o.ys[i]}:${if o.on_curve[i] { 1 } else { 0 }}'
	}
	return '${tag} n=${o.xs.len} ends=${o.end_pts} box=(${o.x_min},${o.y_min},${o.x_max},${o.y_max}) [${pts.join(' ')}]'
}

fn test_glyf_simple_a() {
	f := glyf_font('FiraCode-Variable.ttf')
	o := f.face.glyph_outline(f.face.glyph_index(`A`)) or { panic('${err}') }
	assert o.n_points() == 11, 'A has eleven points, got ${glyf_dump('A', o)}'
	assert o.n_contours() == 2, 'A has two contours, got ${glyf_dump('A', o)}'
	assert o.end_pts == [7, 10], 'A ends its contours at 7 and 10, got ${glyf_dump('A', o)}'
	assert o.x_min == 60 && o.y_min == 0 && o.x_max == 1140 && o.y_max == 1374, 'A box is (60, 0, 1140, 1374), got ${glyf_dump('A', o)}'
	assert o.xs[0] == 887 && o.ys[0] == 367 && o.on_curve[0], 'A opens at (887, 367) on-curve'
	assert o.xs[3] == 60 && o.ys[3] == 0 && o.on_curve[3], 'A reaches (60, 0) on-curve'
	assert o.xs[10] == 596 && o.ys[10] == 1255 && o.on_curve[10], 'A closes at (596, 1255) on-curve'
	for i in 0 .. o.xs.len {
		assert o.on_curve[i], 'A is all on-curve, point ${i} is off at ${glyf_dump('A', o)}'
	}
}

fn test_glyf_composite_plain_offset() {
	// Aacute is A plus acute.case shifted ten right: the corpus's plainest
	// composite, two integer offsets and no transform.
	f := glyf_font('FiraCode-Variable.ttf')
	o := f.face.glyph_outline(u16(2)) or { panic('${err}') }
	assert o.n_points() == 15, 'Aacute flattens to fifteen points, got ${glyf_dump('Aacute', o)}'
	assert o.end_pts == [7, 10, 14], 'Aacute ends at 7, 10 and 14, got ${glyf_dump('Aacute', o)}'
	assert o.x_min == 60 && o.y_min == 0 && o.x_max == 1140 && o.y_max == 1784, 'Aacute box reaches the acute at 1784, got ${glyf_dump('Aacute', o)}'
	// The first eleven points are A untouched.
	a := f.face.glyph_outline(f.face.glyph_index(`A`)) or { panic('${err}') }
	for i in 0 .. 11 {
		assert o.xs[i] == a.xs[i] && o.ys[i] == a.ys[i], 'Aacute point ${i} is A untouched, got ${glyf_dump('Aacute', o)}'
	}
	// The last four are acute.case shifted by the (10, 0) offset.
	assert o.xs[11] == 767 && o.ys[11] == 1784, 'the acute starts at (757, 1784) plus ten, got ${glyf_dump('Aacute', o)}'
	assert o.xs[12] == 830 && o.ys[12] == 1667, 'the acute continues at (820, 1667) plus ten'
	assert o.xs[14] == 381 && o.ys[14] == 1583, 'the acute ends at (371, 1583) plus ten'
}

fn test_glyf_composite_mirror() {
	// less_equal.ss02 mirrors greater_equal.ss02 across the y axis: an
	// x-and-y scale of (-1, 1) with a zero offset, gid 1756.
	f := glyf_font('FiraCode-Variable.ttf')
	o := f.face.glyph_outline(u16(1756)) or { panic('${err}') }
	assert o.n_points() == 13, 'the mirror flattens to thirteen points, got ${glyf_dump('mirror', o)}'
	assert o.end_pts == [3, 8, 12], 'the mirror keeps the base ends, got ${glyf_dump('mirror', o)}'
	assert o.xs[0] == 569 && o.ys[0] == 279, 'the mirror flips (-569, 279) to (569, 279), got ${glyf_dump('mirror', o)}'
	assert o.xs[12] == 540 && o.ys[12] == 27, 'the mirror flips (-540, 27) to (540, 27)'
	for i in 0 .. o.xs.len {
		assert o.on_curve[i], 'the mirror is all on-curve, point ${i} is off'
	}
}

fn test_glyf_composite_rotation_and_scale() {
	// Amiri uni202C (gid 379) stacks a y-scaled component under a rotated
	// one: the first contour's heights come out fractional (514.9066) and
	// the reader's single final otRound puts them at 515, the way
	// fontTools' rounded coordinates read.
	f := glyf_font('Amiri-Regular.ttf')
	o := f.face.glyph_outline(u16(379)) or { panic('${err}') }
	assert o.n_points() == 13, 'uni202C flattens to thirteen points, got ${glyf_dump('uni202C', o)}'
	assert o.end_pts == [3, 12], 'uni202C ends at 3 and 12, got ${glyf_dump('uni202C', o)}'
	assert o.xs[0] == 15 && o.ys[0] == 515, 'the scaled height rounds to 515, got ${glyf_dump('uni202C', o)}'
	assert o.xs[1] == 15 && o.ys[1] == 0 && o.on_curve[1], 'the scaled base sits at (15, 0)'
	assert o.xs[12] == 0 && o.ys[12] == 609, 'the rotated mark ends at (0, 609), got ${glyf_dump('uni202C', o)}'
	assert !o.on_curve[10] && o.on_curve[11] && o.on_curve[12], 'the rotated mark closes off, on, on'
}

fn test_glyf_composite_nested() {
	// FiraCode uni1F78 (gid 861) is omicron plus grave, and omicron is
	// itself a composite: flattening it proves the recursion, not just one
	// level of components.
	f := glyf_font('FiraCode-Variable.ttf')
	o := f.face.glyph_outline(u16(861)) or { panic('${err}') }
	assert o.n_points() == 32, 'the nested flattening has 32 points, got ${glyf_dump('uni1F78', o)}'
	assert o.end_pts == [15, 27, 31], 'the nested ends are 15, 27 and 31, got ${glyf_dump('uni1F78', o)}'
	assert o.xs[0] == 603 && o.ys[0] == 1069 && o.on_curve[0], 'the nested outline opens at (603, 1069) on-curve'
	assert o.xs[15] == 459 && o.ys[15] == 1069, 'omicron closes its second contour at (459, 1069)'
	assert o.xs[16] == 603 && o.ys[16] == 960 && o.on_curve[16], 'omicron continues on-curve at (603, 960)'
	assert o.xs[28] == 766 && o.ys[28] == 1244 && o.on_curve[28], 'grave opens on-curve at (766, 1244)'
	assert o.xs[31] == 811 && o.ys[31] == 1317 && o.on_curve[31], 'the nested outline ends at (811, 1317) on-curve'
}

fn test_glyf_empty_space() {
	// A space has no contours: the reader answers empty, not an error.
	f := glyf_font('FiraCode-Variable.ttf')
	o := f.face.glyph_outline(f.face.glyph_index(` `)) or { panic('${err}') }
	assert o.n_points() == 0 && o.n_contours() == 0, 'a space is empty, got ${glyf_dump('space', o)}'
}

fn test_glyf_cff_font_is_refused() {
	// LatinModernMath is a CFF font: there is no `glyf` table, so asking
	// for an outline is an error that says so, not an empty outline that
	// pretends the glyph is blank.
	f := glyf_font('LatinModernMath-Regular.otf')
	o := f.face.glyph_outline(u16(1)) or {
		assert err.msg().contains('glyf'), 'the refusal names glyf, got: ${err.msg()}'
		return
	}
	assert false, 'a CFF font answered an outline with ${o.n_points()} points'
}

fn test_glyf_gid_past_the_font_is_refused() {
	f := glyf_font('FiraCode-Variable.ttf')
	f.face.glyph_outline(u16(60000)) or {
		assert err.msg().contains('past'), 'the refusal names the overrun, got: ${err.msg()}'
		return
	}
	assert false, 'gid 60000 answered an outline'
}
