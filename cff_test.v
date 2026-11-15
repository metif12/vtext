module vtext

import os
import vtext.font
import vtext.shape
import vtext.subset

// Tests for the CFF reader (font/cff.v) against a real CFF font.
//
// The font is Source Sans 3 Regular, an OFL Adobe release committed as
// testdata/fonts/SourceSans3-Regular.otf with its licence beside it. Every
// number below was read off fontTools before it was written here —
// agreement with a second reader is the evidence, the way the glyf pins
// agree with HarfBuzz. A reader verified only against tables built to match
// it would prove nothing, which is why this file exists on the committed
// font rather than on a fixture.
//
// Measured on the committed bytes (fontTools 4.66.1):
// sfntVersion OTTO, 2478 glyphs, 1000 upm, tables include CFF, no glyf/loca
// CharStrings INDEX at CFF+39533 with 2478 entries, charset at CFF+38860
// Private size 64 at CFF+150157, Local Subrs at Private+64 with 648 entries
// Global Subrs 738 entries, both biases 107, nominalWidthX 518
// gid 0 .notdef (90 raw bytes), 1 space (3), 2 A (3: 247 96 29), 3 B (3),
// 28 a (27); outline ops A 2/10/2/2, a 2/6/10/2, space none,
// .notdef 5/17/0/5, B 3/7/8/3 (moves/lines/curves/closes)

fn cff_font_path() ?string {
	mut dirs := []string{}
	for d in [os.getenv('VTEXT_TEST_FONTS'), 'testdata/fonts'] {
		if d != '' && d !in dirs {
			dirs << d
		}
	}
	for dir in dirs {
		p := os.join_path(dir, 'SourceSans3-Regular.otf')
		if os.exists(p) {
			return p
		}
	}
	return none
}

fn cff_font_bytes() ?[]u8 {
	p := cff_font_path() or { return none }
	return os.read_bytes(p) or { panic('${p} is not readable: ${err}') }
}

fn cff_skip() bool {
	line := 'SKIP SourceSans3-Regular.otf is in neither testdata/fonts nor VTEXT_TEST_FONTS'
	path := os.getenv('VTEXT_SKIP_LOG')
	if path != '' {
		mut f := os.open_append(path) or { return true }
		f.writeln(line) or { return true }
		f.close()
		return true
	}
	println(line)
	return true
}

fn cff_test_font() ?&shape.Font {
	p := cff_font_path() or {
		cff_skip()
		return none
	}
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

fn cff_test_cff() ?font.Cff {
	data := cff_font_bytes() or {
		cff_skip()
		return none
	}
	sfnt := font.parse_sfnt(data) or { panic('the CFF font does not parse: ${err}') }
	return font.parse_cff_from_sfnt(&sfnt) or { panic('the CFF table does not parse: ${err}') }
}

// The table directory and the CFF header pins: a real CFF face, not a
// fixture with the right tags.
fn test_cff_font_is_cff() {
	f := cff_test_font() or { return }
	assert f.is_cff_outlined(), 'Source Sans 3 must report CFF outlines'
	assert f.outlines() == 'CFF ', "outlines() must say 'CFF ', got '${f.outlines()}'"
	assert f.num_glyphs() == 2478, 'glyph count ${f.num_glyphs()}, not 2478'
	assert f.units_per_em() == 1000, 'upm ${f.units_per_em()}, not 1000'
	assert f.glyph_index(`A`) == 2, "'A' must be gid 2"
	assert f.glyph_index(`a`) == 28, "'a' must be gid 28"
	assert f.glyph_index(` `) == 1, 'space must be gid 1'
	data := cff_font_bytes() or { return }
	sfnt := font.parse_sfnt(data) or { panic(err) }
	assert sfnt.is_cff(), 'sfnt must report CFF'
	assert sfnt.has(font.tag_cff), 'sfnt must carry a CFF table'
	assert !sfnt.has(font.tag_cff2), 'this face must not carry CFF2'
	assert !sfnt.has_glyf_outlines(), 'a CFF face has no glyf outlines'
}

// Charstring counts and subroutine biases beside fontTools: 2478
// charstrings, 738 global and 648 local subrs, both biases 107.
fn test_cff_parse_pins() {
	cff := cff_test_cff() or { return }
	assert cff.num_charstrings == 2478, 'charstrings ${cff.num_charstrings}, not 2478'
	assert cff.num_global_subrs == 738, 'global subrs ${cff.num_global_subrs}, not 738'
	assert cff.num_local_subrs == 648, 'local subrs ${cff.num_local_subrs}, not 648'
	assert cff.global_bias == 107, 'global bias ${cff.global_bias}, not 107'
	assert cff.local_bias == 107, 'local bias ${cff.local_bias}, not 107'
	assert cff.charstrings_at == 39533, 'CharStrings at ${cff.charstrings_at}, not 39533'
	assert cff.charset_at == 38860, 'charset at ${cff.charset_at}, not 38860'
	assert cff.private_off == 150157, 'Private at ${cff.private_off}, not 150157'
	assert cff.private_len == 64, 'Private size ${cff.private_len}, not 64'
	assert cff.nominal_width == 518.0, 'nominalWidthX ${cff.nominal_width}, not 518'
	// The raw lengths: .notdef carries a box (90), A and space are one
	// subroutine call and a width respectively (3 each).
	assert (cff.charstring_raw(0) or { panic(err) }).len == 90, '.notdef raw length'
	assert (cff.charstring_raw(1) or { panic(err) }).len == 3, 'space raw length'
	assert (cff.charstring_raw(2) or { panic(err) }).len == 3, "'A' raw length"
	assert (cff.charstring_raw(28) or { panic(err) }).len == 27, "'a' raw length"
	a_raw := cff.charstring_raw(2) or { panic(err) }
	assert a_raw == [u8(247), 96, 29], "'A' is 204 callgsubr"
}

// The bias function on its boundaries, not just on this font's counts.
fn test_cff_subr_bias_pins() {
	assert font.cff_subr_bias(0) == 107
	assert font.cff_subr_bias(738) == 107
	assert font.cff_subr_bias(1239) == 107
	assert font.cff_subr_bias(1240) == 1131
	assert font.cff_subr_bias(33899) == 1131
	assert font.cff_subr_bias(33900) == 32768
}

// Outline counts beside the fontTools decompiler: moves/lines/curves/closes
// per glyph, the first moveTo, and the width the charstring declared — which
// for this release equals the hmtx advance on all five.
fn test_cff_outline_counts_match_decompiler() {
	cff := cff_test_cff() or { return }
	a := cff.outline(2) or { panic("'A' does not outline: ${err}") }
	assert a.ops.len == 16, "'A' has ${a.ops.len} ops, not 16"
	assert a.count_kind(font.CffOpKind.move_to) == 2, "'A' moves"
	assert a.count_kind(font.CffOpKind.line_to) == 10, "'A' lines"
	assert a.count_kind(font.CffOpKind.curve_to) == 2, "'A' curves"
	assert a.count_kind(font.CffOpKind.close_path) == 2, "'A' closes"
	assert a.ops[0].pts == [203.0, 367.0], "'A' first move ${a.ops[0].pts}"
	assert a.has_width && a.width == 544.0, "'A' width ${a.width}"
	// 'A' is nothing but a global-subr call, so these counts also prove the
	// callgsubr path recurses with the bias added: without it the outline
	// would be empty and the width missing.
	low := cff.outline(28) or { panic("'a' does not outline: ${err}") }
	assert low.ops.len == 20, "'a' has ${low.ops.len} ops, not 20"
	assert low.count_kind(font.CffOpKind.move_to) == 2
	assert low.count_kind(font.CffOpKind.line_to) == 6
	assert low.count_kind(font.CffOpKind.curve_to) == 10
	assert low.count_kind(font.CffOpKind.close_path) == 2
	assert low.ops[0].pts == [194.0, -12.0], "'a' first move ${low.ops[0].pts}"
	assert low.has_width && low.width == 504.0, "'a' width ${low.width}"
	space := cff.outline(1) or { panic('space does not outline: ${err}') }
	assert space.ops.len == 0, 'space draws nothing'
	assert space.has_width && space.width == 200.0, 'space width ${space.width}'
	notdef := cff.outline(0) or { panic('.notdef does not outline: ${err}') }
	assert notdef.ops.len == 27, '.notdef has ${notdef.ops.len} ops, not 27'
	assert notdef.count_kind(font.CffOpKind.move_to) == 5
	assert notdef.count_kind(font.CffOpKind.line_to) == 17
	assert notdef.count_kind(font.CffOpKind.curve_to) == 0
	assert notdef.count_kind(font.CffOpKind.close_path) == 5
	assert notdef.has_width && notdef.width == 653.0, '.notdef width ${notdef.width}'
	b := cff.outline(3) or { panic("'B' does not outline: ${err}") }
	assert b.ops.len == 21, "'B' has ${b.ops.len} ops, not 21"
	assert b.count_kind(font.CffOpKind.move_to) == 3
	assert b.count_kind(font.CffOpKind.line_to) == 7
	assert b.count_kind(font.CffOpKind.curve_to) == 8
	assert b.count_kind(font.CffOpKind.close_path) == 3
	assert b.has_width && b.width == 588.0, "'B' width ${b.width}"
}

// Outlining the same glyph twice answers the same bytes: the interpreter
// carries no state between calls that could drift.
fn test_cff_outline_is_deterministic() {
	cff := cff_test_cff() or { return }
	first := cff.outline(2) or { panic(err) }
	second := cff.outline(2) or { panic(err) }
	assert first.ops.len == second.ops.len
	for i, op in first.ops {
		assert op.kind == second.ops[i].kind, 'op ${i} kind drifted'
		assert op.pts == second.ops[i].pts, 'op ${i} points drifted'
	}
}

// Rasterization goes through stb_truetype — the existing curve path, which
// reads CFF itself — so a CFF 'A' inks, its box agrees with its ink the way
// the glyf sweep demands, a space is empty and .notdef is drawn.
fn test_cff_rasterize_smoke() {
	f := cff_test_font() or { return }
	a := f.rasterize(2, 32.0, 0, 0)
	assert !a.is_empty(), "'A' rasterizes to nothing at 32px"
	assert a.coverage.len == a.width * a.height
	box := f.face.box_only(2, 32.0)
	assert box.width == a.width && box.height == a.height, 'box and ink disagree on size'
	assert box.left == a.left && box.top == a.top, 'box and ink disagree on placement'
	assert box.coverage.len == 0, 'the box carries no pixels'
	space := f.rasterize(1, 32.0, 0, 0)
	assert space.is_empty(), 'a space must have no ink'
	notdef := f.rasterize(0, 32.0, 0, 0)
	assert !notdef.is_empty(), '.notdef must draw something'
}

// The CFF outline and a glyf outline flow through the same rasterizer: both
// faces ink an 'A' at 32px, both boxes agree with their ink, and neither
// path draws the other's glyph. This is parity of the engine, not of the
// pixels — the designs differ, so equal coverage would be the failure.
fn test_cff_outline_parity_with_glyf_path() {
	cff_font := cff_test_font() or { return }
	amiri_path := if os.exists('testdata/fonts/Amiri-Regular.ttf') {
		'testdata/fonts/Amiri-Regular.ttf'
	} else {
		cff_skip()
		return
	}
	glyf_font := shape.load_font_file(amiri_path) or { panic(err) }
	assert !glyf_font.is_cff_outlined(), 'Amiri must stay the glyf side of this comparison'
	cff_a := cff_font.glyph_index(`A`)
	glyf_a := glyf_font.glyph_index(`A`)
	assert cff_a != 0 && glyf_a != 0, 'both fonts must cover A'
	cff_bmp := cff_font.rasterize(cff_a, 32.0, 0, 0)
	glyf_bmp := glyf_font.rasterize(glyf_a, 32.0, 0, 0)
	assert !cff_bmp.is_empty() && !glyf_bmp.is_empty(), 'both As must ink'
	cff_box := cff_font.face.box_only(cff_a, 32.0)
	assert cff_box.width == cff_bmp.width && cff_box.height == cff_bmp.height
	glyf_box := glyf_font.face.box_only(glyf_a, 32.0)
	assert glyf_box.width == glyf_bmp.width && glyf_box.height == glyf_bmp.height
	assert cff_font.glyph_advance(cff_a, 32.0) > 0
	assert glyf_font.glyph_advance(glyf_a, 32.0) > 0
}

// Break-fix, part one: flipping 'A's first byte to 0x00 — a reserved
// operator — must refuse with the byte named, not draw garbage. 'A' is one
// call away from proving the point: its whole outline lives in a global
// subr, so a corrupt call byte cannot limp along on partial ink.
fn test_cff_corrupt_charstring_refuses() {
	cff := cff_test_cff() or { return }
	start, _ := cff.charstring_range(2) or { panic(err) }
	mut bad := cff.table.clone()
	bad[start] = u8(0)
	corrupt := font.parse_cff(bad) or { panic('the INDEX structure is intact, so parsing must still succeed: ${err}') }
	if _ := corrupt.outline(2) {
		assert false, 'a charstring starting with reserved operator 0 drew an outline'
	} else {
		assert err.msg().contains('reserved charstring operator 0'), 'unexpected refusal: ${err.msg()}'
	}
	// A gid past the end is a refusal before any byte is read.
	if _ := cff.outline(9999) {
		assert false, 'gid 9999 outlined'
	} else {
		assert err.msg().contains('outside'), 'unexpected refusal: ${err.msg()}'
	}
}

// Break-fix, part two: a table that ends mid-INDEX is truncated, not short.
// Cutting the CFF table to 100 bytes leaves every header field present and
// every INDEX hanging, which is exactly the shape a short read has.
fn test_cff_truncated_table_refuses() {
	cff := cff_test_cff() or { return }
	if _ := font.parse_cff(cff.table[..100]) {
		assert false, 'a 100-byte CFF table parsed'
	} else {
		assert err.msg().len > 0, 'a truncation must say why'
	}
	if _ := font.parse_cff([]u8{}) {
		assert false, 'an empty CFF table parsed'
	}
	// A CFF2-only face refuses with the format's name: CFF2 is a different
	// bytecode the reader does not implement, not a corrupt CFF table.
	fake := cff_fake_sfnt(['CFF2'])
	only2 := shape.load_font_bytes(fake) or { panic('the CFF2-only sfnt did not load: ${err}') }
	assert only2.outlines() == 'CFF2'
	data := only2.data()
	sfnt := font.parse_sfnt(data) or { panic(err) }
	if _ := font.parse_cff_from_sfnt(&sfnt) {
		assert false, 'a CFF2-only face parsed as CFF'
	} else {
		assert err.msg().contains('CFF2'), 'unexpected refusal: ${err.msg()}'
	}
}

// The subsetter still refuses CFF: font/cff.v reads charstrings, it does not
// rebuild them, so build_font errors on the missing glyf pair and the tool's
// branch keeps refusing with its reason. CFF2 refuses the same way.
fn test_cff_subsetter_still_refuses() {
	f := cff_test_font() or { return }
	assert f.outlines() == 'CFF '
	if _ := subset.subset_font(f, [u16(2)]) {
		assert false, 'a CFF font subsetted without a glyf table'
	} else {
		assert err.msg().contains('no glyf table'), 'unexpected refusal: ${err.msg()}'
	}
}

// cff_fake_sfnt builds a minimal sfnt holding the named tables with four
// zero bytes each — the shape inspect_test proves the loader accepts — for
// the CFF2-only refusal above, where no committed font can stand in: the
// corpus carries no CFF2 face.
fn cff_fake_sfnt(tags []string) []u8 {
	mut out := []u8{cap: 12 + tags.len * 20}
	out << 'OTTO'.bytes()
	out << u8(tags.len >> 8)
	out << u8(tags.len & 0xff)
	out << [u8(0), 0, 0, 0, 0, 0]
	mut body_at := 12 + tags.len * 16
	for t in tags {
		assert t.len == 4
		out << t.bytes()
		out << [u8(0), 0, 0, 0]
		out << u8(body_at >> 24)
		out << u8((body_at >> 16) & 0xff)
		out << u8((body_at >> 8) & 0xff)
		out << u8(body_at & 0xff)
		out << u8(0)
		out << u8(0)
		out << u8(0)
		out << u8(4)
		body_at += 4
	}
	for _ in 0 .. tags.len * 4 {
		out << u8(0)
	}
	return out
}
