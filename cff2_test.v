module harfara

import os
import harfara.font
import harfara.shape

// CFF2 reader pins against fontTools 4.66.1 on the committed OFL face
// SourceSans3VF-Upright.otf. Every number below was read off fontTools
// before it was written here; a reader checked only against fixtures built
// to match it would prove nothing.

fn cff2_path() ?string {
	for d in [os.getenv('HARFARA_TEST_FONTS'), 'testdata/fonts'] {
		if d == '' {
			continue
		}
		p := os.join_path(d, 'SourceSans3VF-Upright.otf')
		if os.exists(p) {
			return p
		}
	}
	return none
}

fn cff2_table() ?[]u8 {
	p := cff2_path() or {
		println('SKIP SourceSans3VF-Upright.otf is in neither testdata/fonts nor HARFARA_TEST_FONTS')
		return none
	}
	data := os.read_bytes(p) or { panic('${p} is not readable: ${err}') }
	sfnt := font.parse_sfnt(data) or { panic('the CFF2 font does not parse: ${err}') }
	assert sfnt.has(font.tag_cff2), 'the face must carry CFF2'
	assert !sfnt.has(font.tag_cff), 'the face must have no CFF1 table'
	return sfnt.table_data(font.tag_cff2)
}

fn test_cff2_parse_pins() {
	table := cff2_table() or { return }
	c := font.parse_cff2(table) or { panic('CFF2 does not parse: ${err}') }
	// fontTools on the committed bytes: 2478 CharStrings, 1 FD, region
	// counts [2, 3, ...] from the VarStore; 738 global subrs.
	assert c.num_charstrings == 2478, 'charstrings ${c.num_charstrings}, not 2478'
	assert c.fds.len == 1, 'FDArray has ${c.fds.len} fonts, not 1'
	assert c.num_global_subrs == 0, 'fontTools sees 0 global subrs on this face'
	assert c.region_counts.len > 0, 'the VarStore has no ItemVariationData'
	assert c.region_counts[0] == 2, 'vsindex 0 must have 2 regions, got ${c.region_counts[0]}'
	for gid in 0 .. c.num_charstrings {
		assert c.fd_for_gid[gid] == 0, 'gid ${gid} must select FD 0'
	}
}

fn test_cff2_outline_counts_match_decompiler() {
	table := cff2_table() or { return }
	c := font.parse_cff2(table) or { panic(err) }
	// fontTools RecordingPen op counts at the default instance:
	// A 2/12/2/2, B 3/10/8/3, C 1/2/8/1, a 2/6/10/2, i 2/4/4/2, m 1/12/8/1
	// (moves/lines/curves/closes).
	cases := [
		TestGid{2, 2, 12, 2, 2},
		TestGid{3, 3, 10, 8, 3},
		TestGid{4, 1, 2, 8, 1},
		TestGid{28, 2, 6, 10, 2},
	]
	for t in cases {
		o := c.outline(t.gid) or { panic('gid ${t.gid} does not outline: ${err}') }
		assert o.count_kind(font.CffOpKind.move_to) == t.m, 'gid ${t.gid} moves: ${o.count_kind(font.CffOpKind.move_to)}, not ${t.m}'
		assert o.count_kind(font.CffOpKind.line_to) == t.l, 'gid ${t.gid} lines: ${o.count_kind(font.CffOpKind.line_to)}, not ${t.l}'
		assert o.count_kind(font.CffOpKind.curve_to) == t.c, 'gid ${t.gid} curves: ${o.count_kind(font.CffOpKind.curve_to)}, not ${t.c}'
		assert o.count_kind(font.CffOpKind.close_path) == t.z, 'gid ${t.gid} closes: ${o.count_kind(font.CffOpKind.close_path)}, not ${t.z}'
	}
}

struct TestGid {
	gid int
	m   int
	l   int
	c   int
	z   int
}

// The first moveTo of 'A' is (10, 0) in fontTools design units, a direct
// check that the blend at the default instance keeps its default operand.
fn test_cff2_first_move_pins() {
	table := cff2_table() or { return }
	c := font.parse_cff2(table) or { panic(err) }
	o := c.outline(2) or { panic(err) }
	assert o.ops[0].kind == font.CffOpKind.move_to, "'A' must start with a move"
	assert o.ops[0].pts == [f64(10), 0], "'A' first move ${o.ops[0].pts}, not [10, 0]"
}

// A truncated header is refused with CFF2 in the message, not misread.
fn test_cff2_truncated_header_refused() {
	c := font.parse_cff2([u8(2), 0, 5, 0]) or {
		assert err.msg().contains('CFF2'), 'refusal must name CFF2: ${err.msg()}'
		return
	}
	panic('a 4-byte CFF2 table must be refused, got ${c.num_charstrings} charstrings')
}

fn cff2_face() !&shape.Font {
	p := cff2_path() or { return error('no CFF2 face on this host') }
	return shape.load_font_file(p)
}

// The raster backend pins against fontTools 4.66.1 BoundsPen boxes on the
// same face at the default instance. Design-unit bounds read off fontTools:
// A (10, 0, 510, 660), B (100, 0, 528, 660), C (56, -12, 522, 672),
// a (60, -12, 404, 490). At 32 px over 1000 units the floor/ceil of those
// gives the boxes below; the flatten tolerance (0.05 px) sits an order of
// magnitude inside every fractional margin, so the pins are stable and not
// boundary-adjacent.
fn test_cff2_raster_box_pins() {
	f := cff2_face() or { return }
	assert f.face.is_cff2(), 'the SourceSans3VF face must take the CFF2 backend'
	cases := [
		TestBox{`A`, 17, 22, 0, 22},
		TestBox{`B`, 14, 22, -3, 22},
		TestBox{`C`, 16, 23, -1, 22},
		TestBox{`a`, 12, 17, -1, 16},
	]
	for t in cases {
		gid := f.glyph_index(t.cp)
		assert gid != 0, '${t.cp} must map to a real glyph'
		bm := f.rasterize(gid, 32.0, 0, 0)
		assert bm.width == t.w, '${t.cp}: width ${bm.width}, not ${t.w}'
		assert bm.height == t.h, '${t.cp}: height ${bm.height}, not ${t.h}'
		assert bm.left == t.l, '${t.cp}: left ${bm.left}, not ${t.l}'
		assert bm.top == t.t, '${t.cp}: top ${bm.top}, not ${t.t}'
		mut ink := u64(0)
		for v in bm.coverage {
			ink += v
		}
		assert ink > 0, '${t.cp} must rasterize with ink'
		// Measuring and drawing agree: box_only reports the same box with
		// no coverage.
		box := f.face.box_only(gid, 32.0)
		assert box.width == t.w && box.height == t.h, '${t.cp}: box_only disagrees'
		assert box.coverage.len == 0, '${t.cp}: box_only must carry no coverage'
		// Deterministic: the same glyph rasterizes to the same bytes.
		again := f.rasterize(gid, 32.0, 0, 0)
		assert again.coverage == bm.coverage, '${t.cp}: raster must be deterministic'
	}
}

struct TestBox {
	cp rune
	w  int
	h  int
	l  int
	t  int
}

// Glyphs outside the CharStrings INDEX rasterize empty rather than failing
// the face; .notdef still draws its box.
fn test_cff2_invalid_gid_rasterizes_empty() {
	f := cff2_face() or { return }
	bm := f.rasterize(60000, 32.0, 0, 0)
	assert bm.is_empty(), 'an out-of-range gid must rasterize empty'
	box := f.face.box_only(60000, 32.0)
	assert box.is_empty(), 'an out-of-range gid must measure empty'
	zero := f.rasterize(0, 32.0, 0, 0)
	assert !zero.is_empty(), '.notdef must keep its ink'
}

// Instancing pins against fontTools getGlyphSet at the same location on the
// same face. Design wght 900 normalizes to blend 1.0 (avar is the identity
// at the extremes); design 500 warps to 0.4860085424338366, so the pins go
// through the face's prepared blend rather than hand-normalized values.
// Boxes derive from the fontTools instanced bounds the same floor/ceil way
// as the default pins: A@900 (-10, 0, 594, 650), a@900 (38, -12, 482, 512),
// A@500 (0.279, 0, 550.502, 655.140).
fn test_cff2_instanced_raster_pins() {
	data := os.read_bytes(cff2_path() or { return }) or { panic(err) }
	mut face := font.new_face(data) or { panic(err) }
	face.set_var_coords([900.0]) or { panic(err) }
	assert face.var_cache_blend == [1.0], 'blend at wght 900 must be exactly 1.0, got ${face.var_cache_blend}'
	bm := face.rasterize_glyph(2, 32.0, 0, 0)
	assert bm.width == 21 && bm.height == 21, 'A@900 box ${bm.width}x${bm.height}, not 21x21'
	assert bm.left == 1 && bm.top == 21, 'A@900 at (${bm.left},${bm.top}), not (1,21)'
	bma := face.rasterize_glyph(28, 32.0, 0, 0)
	assert bma.width == 15 && bma.height == 18, 'a@900 box ${bma.width}x${bma.height}, not 15x18'
	assert bma.left == -1 && bma.top == 17, 'a@900 at (${bma.left},${bma.top}), not (-1,17)'
	// Back at the default the default box returns: instancing is state, not
	// a one-way trip.
	face.set_var_coords([200.0]) or { panic(err) }
	back := face.rasterize_glyph(2, 32.0, 0, 0)
	assert back.width == 17 && back.height == 22, 'back at default must recover the default box'
	face.set_var_coords([500.0]) or { panic(err) }
	mid := face.rasterize_glyph(2, 32.0, 0, 0)
	assert mid.width == 18 && mid.height == 21, 'A@500 box ${mid.width}x${mid.height}, not 18x21'
	assert mid.left == 0 && mid.top == 21, 'A@500 at (${mid.left},${mid.top}), not (0,21)'
}

// The instanced outline's first point pins the blend arithmetic itself, not
// just its box: fontTools draws A@900 starting at (-10, 0) and A@500 at
// (0.27943362046472586, 0), and the interpreter must agree bit for bit.
fn test_cff2_instanced_first_move_pins() {
	data := os.read_bytes(cff2_path() or { return }) or { panic(err) }
	mut face := font.new_face(data) or { panic(err) }
	face.set_var_coords([900.0]) or { panic(err) }
	c := face.cff2 or { panic('the face must carry CFF2') }
	o := c.outline_instanced(2, face.var_cache_blend) or { panic(err) }
	assert o.ops[0].kind == font.CffOpKind.move_to, 'A@900 must start with a move'
	assert o.ops[0].pts == [f64(-10.0), 0], 'A@900 first move ${o.ops[0].pts}, not [-10, 0]'
	face.set_var_coords([500.0]) or { panic(err) }
	o5 := c.outline_instanced(2, face.var_cache_blend) or { panic(err) }
	assert o5.ops[0].pts == [0.27943362046472586, 0], 'A@500 first move ${o5.ops[0].pts}'
}
