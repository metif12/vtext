module harfara

import harfara.font
import harfara.shape

// Writer tests for the 14.2c half of `font/build_tables.v`: the metrics and
// empty-outline writers, scalar and per-glyph params in, spec-layout bytes
// out, verified by rebuilding through `Builder.build` and re-reading with
// the engine's own `Face` readers.
//
// This file is self-contained like `build_tables_test.v`: every helper it
// needs is defined here with a bmet_ prefix, so `v test
// build_metrics_test.v` compiles this file alone. The field readers below
// deliberately duplicate the engine's big-endian arithmetic rather than
// calling it: the pins prove the bytes the writers emit, not the helpers
// they share. The read-back leg goes through `Face.glyph_advance_units`,
// `Face.glyph_lsb` and `Face.glyph_outline`, the accessors callers use.

// bmet_be16 reads a big-endian u16 at off.
fn bmet_be16(data []u8, off int) int {
	return int(data[off]) * 256 + int(data[off + 1])
}

// bmet_i16 reads a big-endian i16 at off.
fn bmet_i16(data []u8, off int) int {
	v := bmet_be16(data, off)
	return if v >= 0x8000 { v - 0x10000 } else { v }
}

// bmet_hmtx builds the three-glyph mixed table the pins below read: long
// records (600, 10) and (700, -20), then the tail bearing 30 whose advance
// replays the last long one (700). The 999 in the third advance slot is
// deliberately wrong: the format has no room for tail advances, so the
// writer must not store it and the reader must answer 700.
fn bmet_hmtx() []u8 {
	return font.build_hmtx([u16(600), 700, 999], [i16(10), -20, 30], 2) or {
		panic('hmtx writer refused the pin params: ${err}')
	}
}

// bmet_assemble builds a whole loadable font from writer output: head (upem
// 1000, zero bbox), maxp sized to the advances, hhea carrying num_h, the
// hmtx under test, and the empty glyf/loca pair. long_loca selects the head
// flag and the loca stride together, so the two never disagree.
fn bmet_assemble(advances []u16, lsbs []i16, num_h int, long_loca bool) []u8 {
	head := font.build_head(1000, [0, 0, 0, 0]!, long_loca) or {
		panic('head writer refused: ${err}')
	}
	maxp := font.build_maxp(advances.len) or { panic('maxp writer refused: ${err}') }
	hhea := font.build_hhea(800, -200, 0, num_h) or {
		panic('hhea writer refused ${num_h} metrics: ${err}')
	}
	hmtx := font.build_hmtx(advances, lsbs, num_h) or {
		panic('hmtx writer refused: ${err}')
	}
	glyf, loca := font.build_empty_glyf_loca(advances.len, long_loca) or {
		panic('empty glyf/loca writer refused: ${err}')
	}
	mut b := font.new_builder(font.sfnt_version_truetype)
	b.set('head', head) or { panic('head set refused: ${err}') }
	b.set('maxp', maxp) or { panic('maxp set refused: ${err}') }
	b.set('hhea', hhea) or { panic('hhea set refused: ${err}') }
	b.set('hmtx', hmtx) or { panic('hmtx set refused: ${err}') }
	b.set('glyf', glyf) or { panic('glyf set refused: ${err}') }
	b.set('loca', loca) or { panic('loca set refused: ${err}') }
	return b.build() or { panic('metrics assembly would not build: ${err}') }
}

fn test_bmet_hmtx_layout_pins() {
	hmtx := bmet_hmtx()
	// Two long records plus one tail bearing: 2*4 + 1*2 bytes, and the
	// third advance (999) is nowhere in them.
	assert hmtx.len == 10, 'hmtx is ${hmtx.len} bytes, want 10'
	assert hmtx == [u8(0x02), 0x58, 0x00, 0x0a, 0x02, 0xbc, 0xff, 0xec, 0x00, 0x1e], 'mixed hmtx bytes moved'
	assert bmet_be16(hmtx, 0) == 600, 'first advance moved from +0'
	assert bmet_i16(hmtx, 2) == 10, 'first bearing moved from +2'
	assert bmet_be16(hmtx, 4) == 700, 'second advance moved from +4'
	assert bmet_i16(hmtx, 6) == -20, 'second bearing moved from +6'
	assert bmet_i16(hmtx, 8) == 30, 'tail bearing moved from +8'

	// All long: every glyph carries its own advance.
	all := font.build_hmtx([u16(700), 650], [i16(-5), 12], 2) or {
		panic('all-long hmtx refused: ${err}')
	}
	assert all.len == 8, 'all-long hmtx is ${all.len} bytes, want 8'
	assert all == [u8(0x02), 0xbc, 0xff, 0xfb, 0x02, 0x8a, 0x00, 0x0c], 'all-long hmtx bytes moved'

	// Monospaced tail: one long record, the rest bearings only.
	mono := font.build_hmtx([u16(600), 600, 600], [i16(5), 6, 7], 1) or {
		panic('mono-tail hmtx refused: ${err}')
	}
	assert mono.len == 8, 'mono-tail hmtx is ${mono.len} bytes, want 8'
	assert mono == [u8(0x02), 0x58, 0x00, 0x05, 0x00, 0x06, 0x00, 0x07], 'mono-tail hmtx bytes moved'

	// No glyphs, no metrics: the empty table.
	empty := font.build_hmtx([]u16{}, []i16{}, 0) or {
		panic('empty hmtx refused: ${err}')
	}
	assert empty.len == 0, 'empty hmtx is ${empty.len} bytes, want 0'
}

fn test_bmet_glyf_loca_pins() {
	// Short loca: one 2-byte entry per glyph plus one, all zeros, so every
	// glyph's range is 0..0 — the dropped-glyph convention from
	// subset.v:rebuild_outlines, and evenly at 0, which the halved short
	// format requires.
	glyf, loca := font.build_empty_glyf_loca(3, false) or {
		panic('empty short glyf/loca refused: ${err}')
	}
	assert glyf.len == 0, 'empty glyf is ${glyf.len} bytes, want 0'
	assert loca.len == 8, 'short loca is ${loca.len} bytes, want 8'
	for i, byte_val in loca {
		assert byte_val == 0, 'short loca byte ${i} is ${byte_val}, want 0'
	}

	// Long loca: the same zeros at a 4-byte stride.
	_, long_loca := font.build_empty_glyf_loca(3, true) or {
		panic('empty long glyf/loca refused: ${err}')
	}
	assert long_loca.len == 16, 'long loca is ${long_loca.len} bytes, want 16'
	for i, byte_val in long_loca {
		assert byte_val == 0, 'long loca byte ${i} is ${byte_val}, want 0'
	}

	// Zero glyphs still carry the single end entry.
	_, zero_loca := font.build_empty_glyf_loca(0, false) or {
		panic('zero-glyph loca refused: ${err}')
	}
	assert zero_loca.len == 2, 'zero-glyph short loca is ${zero_loca.len} bytes, want 2'
}

fn test_bmet_engine_readback() {
	built := bmet_assemble([u16(600), 700, 999], [i16(10), -20, 30], 2, false)
	face := font.new_face(built) or { panic('metrics font would not load: ${err}') }
	assert face.num_glyphs == 3, 'Face read ${face.num_glyphs} glyphs, want 3'
	// The long records come back verbatim.
	assert face.glyph_advance_units(0) == 600, 'gid 0 advance is ${face.glyph_advance_units(0)}, want 600'
	assert face.glyph_advance_units(1) == 700, 'gid 1 advance is ${face.glyph_advance_units(1)}, want 700'
	assert face.glyph_lsb(0) == 10, 'gid 0 lsb is ${face.glyph_lsb(0)}, want 10'
	assert face.glyph_lsb(1) == -20, 'gid 1 lsb is ${face.glyph_lsb(1)}, want -20'
	// The monospaced tail: the advance replays the last long one (700, not
	// the unstorable 999) while the bearing is the tail's own.
	assert face.glyph_advance_units(2) == 700, 'tail advance is ${face.glyph_advance_units(2)}, want the replayed 700'
	assert face.glyph_lsb(2) == 30, 'tail lsb is ${face.glyph_lsb(2)}, want 30'

	// And through the shaping entry point, not just the font module.
	loaded := shape.load_font_bytes(built) or {
		panic('metrics font would not load as a shape.Font: ${err}')
	}
	assert loaded.face.glyph_advance_units(2) == 700, 'shape.Font lost the tail advance'
	assert loaded.face.glyph_lsb(2) == 30, 'shape.Font lost the tail bearing'

	// The long-loca twin reads back the same metrics: the stride change
	// touches only the outline tables.
	long_built := bmet_assemble([u16(600), 700, 999], [i16(10), -20, 30], 2, true)
	long_face := font.new_face(long_built) or {
		panic('long-loca metrics font would not load: ${err}')
	}
	assert long_face.glyph_advance_units(2) == 700, 'long-loca tail advance moved'
	assert long_face.glyph_lsb(2) == 30, 'long-loca tail bearing moved'
}

fn test_bmet_full_assembly_outlines() {
	// Every gid in the assembled font rasterizes empty-but-valid: the
	// .notdef-equivalent the empty loca ranges promise, with no crash.
	for long_loca in [false, true] {
		built := bmet_assemble([u16(600), 700, 999], [i16(10), -20, 30], 2, long_loca)
		loaded := shape.load_font_bytes(built) or {
			panic('metrics font would not load as a shape.Font: ${err}')
		}
		for gid in 0 .. 3 {
			outline := loaded.face.glyph_outline(u16(gid)) or {
				panic('gid ${gid} (long=${long_loca}) errored: ${err}')
			}
			assert outline.n_points() == 0, 'gid ${gid} (long=${long_loca}) has points'
			bm := loaded.rasterize(u16(gid), 32.0, 0, 0)
			assert bm.coverage.len == 0, 'gid ${gid} (long=${long_loca}) rasterized ${bm.coverage.len} bytes of ink'
		}
	}
}

fn test_bmet_refusals() {
	// A bearing per glyph: a short tail is a caller bug, not a short font.
	if _ := font.build_hmtx([u16(600), 700], [i16(10)], 2) {
		assert false, 'hmtx with a short tail built without error'
	}
	if _ := font.build_hmtx([u16(600)], [i16(10), 20], 1) {
		assert false, 'hmtx with a long tail built without error'
	}
	// The metric count must name a split inside the glyphs: 0 would read
	// back as all-long, past the end has no tail to split at.
	if _ := font.build_hmtx([u16(600), 700], [i16(10), 20], 0) {
		assert false, 'hmtx with 0 metrics built without error'
	}
	if _ := font.build_hmtx([u16(600), 700], [i16(10), 20], 3) {
		assert false, 'hmtx with metrics past the glyphs built without error'
	}
	if _ := font.build_hmtx([]u16{}, []i16{}, 1) {
		assert false, 'hmtx with metrics but no glyphs built without error'
	}
	// The loca count is the maxp count's range.
	if _, _ := font.build_empty_glyf_loca(-1, false) {
		assert false, 'empty glyf/loca with -1 glyphs built without error'
	}
	if _, _ := font.build_empty_glyf_loca(0x10000, false) {
		assert false, 'empty glyf/loca past u16 built without error'
	}
}

// test_bmet_break_fix moves the score twice: a flipped advance rebuilds to
// bytes that differ in exactly that glyph's record, and the tail-length
// mismatch the flip must not be confused with is refused at write time.
fn test_bmet_break_fix() {
	first := bmet_hmtx()
	flipped := font.build_hmtx([u16(600), 701, 999], [i16(10), -20, 30], 2) or {
		panic('flipped hmtx refused: ${err}')
	}
	assert flipped.len == first.len, 'flipped hmtx changed length'
	mut diffs := []int{}
	for i in 0 .. first.len {
		if flipped[i] != first[i] {
			diffs << i
		}
	}
	assert diffs == [5], 'advance flip moved bytes ${diffs}, want only the low byte of the gid 1 record'
	// The engine sees the flip in gid 1 and in gid 1 only.
	built := bmet_assemble([u16(600), 701, 999], [i16(10), -20, 30], 2, false)
	face := font.new_face(built) or { panic('flipped font would not load: ${err}') }
	assert face.glyph_advance_units(0) == 600, 'flip leaked into gid 0'
	assert face.glyph_advance_units(1) == 701, 'flip did not reach gid 1'
	assert face.glyph_advance_units(2) == 701, 'tail did not follow the flipped last advance'
	assert face.glyph_lsb(1) == -20, 'flip leaked into the bearings'
}
