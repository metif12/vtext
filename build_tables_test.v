module harfara

import os
import harfara.font
import harfara.shape

// Writer tests for `font/build_tables.v` (slice 14.2b): scalar params in,
// spec-layout bytes out, verified by rebuilding through `Builder.build` and
// re-reading with the engine's own `Face` readers.
//
// This file is self-contained like `builder_test.v`: every helper it needs
// is defined here with a btables_ prefix, so `v test build_tables_test.v`
// compiles this file alone. The field readers below deliberately duplicate
// the engine's big-endian arithmetic rather than calling it: the pins prove
// the bytes the writers emit, not the helpers they share.
//
// The Amiri pins come from a fontTools dump of the committed corpus font
// (`testdata/fonts/Amiri-Regular.ttf`, fontTools 4.66.1), the required
// second source: unitsPerEm 1000, bbox -438 -900 11467 1815,
// indexToLocFormat 1, numGlyphs 6710, hhea 1124 -634 0 with 6687 metrics.
// The dump's raw bytes put each value at the offset the writers below write:
// head `00010000 000100c5 ... 5f0f3cf5 0003 03e8 ... fe4a fc7c 2ccb 0717
// 0000 0006 0002 0001 0000`, hhea `00010000 0464 fd86 0000 ... 1a1f`,
// maxp `00010000 1a36 ...`.

// btables_be16 reads a big-endian u16 at off.
fn btables_be16(data []u8, off int) int {
	return int(data[off]) * 256 + int(data[off + 1])
}

// btables_be32 reads a big-endian u32 at off.
fn btables_be32(data []u8, off int) u32 {
	return (u32(data[off]) << 24) | (u32(data[off + 1]) << 16) | (u32(data[off + 2]) << 8) | u32(data[off + 3])
}

// btables_i16 reads a big-endian i16 at off.
fn btables_i16(data []u8, off int) int {
	v := btables_be16(data, off)
	return if v >= 0x8000 { v - 0x10000 } else { v }
}

// btables_zero asserts data[start..end] is all zero bytes.
fn btables_zero(data []u8, start int, end int) {
	for i in start .. end {
		assert data[i] == 0, 'byte ${i} is ${data[i]}, want 0'
	}
}

// btables_head builds the Amiri-shaped head: upem 1000, the Amiri bbox, long loca.
fn btables_head() []u8 {
	return font.build_head(1000, [-438, -900, 11467, 1815]!, true) or {
		panic('head writer refused Amiri params: ${err}')
	}
}

// btables_maxp builds the Amiri-shaped maxp: 6710 glyphs.
fn btables_maxp() []u8 {
	return font.build_maxp(6710) or { panic('maxp writer refused 6710: ${err}') }
}

// btables_hhea builds the Amiri-shaped hhea: 1124 -634 0 with 6687 metrics.
fn btables_hhea() []u8 {
	return font.build_hhea(1124, -634, 0, 6687) or {
		panic('hhea writer refused Amiri params: ${err}')
	}
}

// btables_corpus reads a committed corpus font; Amiri ships in testdata.
fn btables_corpus(name string) []u8 {
	return os.read_bytes(os.join_path('testdata', 'fonts', name)) or {
		panic('${name} is not readable: ${err}')
	}
}

fn test_btables_layout_pins() {
	head := btables_head()
	assert head.len == 54, 'head is ${head.len} bytes, want 54'
	assert btables_be16(head, 0) == 1, 'head major version pins the 1.0 the readers assume'
	assert btables_be16(head, 2) == 0, 'head minor version pins the 1.0 the readers assume'
	assert btables_be32(head, 4) == 0, 'head fontRevision is 0: a synthetic font claims no revision'
	assert btables_be32(head, 8) == 0, 'head checkSumAdjustment is zeroed for the builder to patch'
	assert btables_be32(head, 12) == u32(0x5f0f3cf5), 'head magic moved from +12'
	assert btables_be16(head, 16) == 0, 'head flags are 0'
	assert btables_be16(head, 18) == 1000, 'head unitsPerEm moved from +18'
	btables_zero(head, 20, 36)
	assert btables_i16(head, 36) == -438, 'head xMin moved from +36'
	assert btables_i16(head, 38) == -900, 'head yMin moved from +38'
	assert btables_i16(head, 40) == 11467, 'head xMax moved from +40'
	assert btables_i16(head, 42) == 1815, 'head yMax moved from +42'
	assert btables_be16(head, 44) == 0, 'head macStyle is 0'
	assert btables_be16(head, 46) == 3, 'head lowestRecPPEM is 3'
	assert btables_i16(head, 48) == 2, 'head fontDirectionHint is 2'
	assert btables_i16(head, 50) == 1, 'head indexToLocFormat does not say long'
	assert btables_i16(head, 52) == 0, 'head glyphDataFormat is 0'

	maxp := btables_maxp()
	assert maxp.len == 32, 'maxp is ${maxp.len} bytes, want 32'
	assert btables_be32(maxp, 0) == u32(0x00010000), 'maxp version is not 1.0'
	assert btables_be16(maxp, 4) == 6710, 'maxp numGlyphs moved from +4'
	btables_zero(maxp, 6, 32)

	maxp05 := font.build_maxp_05(6710) or { panic('maxp_05 writer refused 6710: ${err}') }
	assert maxp05.len == 6, 'maxp_05 is ${maxp05.len} bytes, want 6'
	assert maxp05 == [u8(0), 0, 0x50, 0, 0x1a, 0x36], 'maxp_05 is not version 0.5 with 6710 glyphs'

	hhea := btables_hhea()
	assert hhea.len == 36, 'hhea is ${hhea.len} bytes, want 36'
	assert btables_be16(hhea, 0) == 1, 'hhea major version pins the 1.0 the readers assume'
	assert btables_be16(hhea, 2) == 0, 'hhea minor version pins the 1.0 the readers assume'
	assert btables_i16(hhea, 4) == 1124, 'hhea ascender moved from +4'
	assert btables_i16(hhea, 6) == -634, 'hhea descender moved from +6'
	assert btables_i16(hhea, 8) == 0, 'hhea lineGap moved from +8'
	btables_zero(hhea, 10, 34)
	assert btables_be16(hhea, 34) == 6687, 'hhea numOfLongHorMetrics moved from +34'
}

fn test_btables_offsets_match_corpus() {
	// The second source: the real Amiri font carries the same values at the
	// same offsets the writers emit, so the offsets are spec, not consensus
	// between this file and the writers.
	raw := btables_corpus('Amiri-Regular.ttf')
	sfnt := font.parse_sfnt(raw) or { panic('corpus font would not parse: ${err}') }
	head := sfnt.table_data(font.tag_head)
	assert head.len == 54, 'corpus head is ${head.len} bytes, want 54'
	assert btables_be32(head, 12) == u32(0x5f0f3cf5), 'corpus magic is not at head+12'
	assert btables_be16(head, 18) == 1000, 'corpus upem is not at head+18'
	assert [btables_i16(head, 36), btables_i16(head, 38), btables_i16(head, 40), btables_i16(head, 42)] == [
		-438,
		-900,
		11467,
		1815,
	], 'corpus bbox is not at head+36..42'
	assert btables_i16(head, 50) == 1, 'corpus loca format is not at head+50'
	hhea := sfnt.table_data(font.tag_hhea)
	assert hhea.len == 36, 'corpus hhea is ${hhea.len} bytes, want 36'
	assert btables_i16(hhea, 4) == 1124, 'corpus ascender is not at hhea+4'
	assert btables_i16(hhea, 6) == -634, 'corpus descender is not at hhea+6'
	assert btables_i16(hhea, 8) == 0, 'corpus line gap is not at hhea+8'
	assert btables_be16(hhea, 34) == 6687, 'corpus metric count is not at hhea+34'
	maxp := sfnt.table_data(font.tag_maxp)
	assert maxp.len == 32, 'corpus maxp is ${maxp.len} bytes, want 32'
	assert btables_be16(maxp, 4) == 6710, 'corpus glyph count is not at maxp+4'
}

fn test_btables_face_roundtrip() {
	// A full Builder assembly from writer output plus synthetic glyf+loca
	// empties: the writers produce tables the engine itself reads back.
	mut b := font.new_builder(font.sfnt_version_truetype)
	b.set('head', btables_head()) or { panic('head set refused: ${err}') }
	b.set('maxp', btables_maxp()) or { panic('maxp set refused: ${err}') }
	b.set('hhea', btables_hhea()) or { panic('hhea set refused: ${err}') }
	b.set('glyf', []u8{}) or { panic('glyf set refused: ${err}') }
	b.set('loca', []u8{}) or { panic('loca set refused: ${err}') }
	built := b.build() or { panic('writer assembly would not build: ${err}') }

	parsed := font.parse_sfnt(built) or { panic('built sfnt would not parse: ${err}') }
	assert parsed.tables.len == 5, 'built font lost tables'

	face := font.new_face(built) or { panic('built font would not load: ${err}') }
	assert face.units_per_em == 1000, 'Face read ${face.units_per_em} upem, want 1000'
	assert face.x_min == -438 && face.y_min == -900, 'Face misread the bbox minimum'
	assert face.x_max == 11467 && face.y_max == 1815, 'Face misread the bbox maximum'
	assert face.num_glyphs == 6710, 'Face read ${face.num_glyphs} glyphs, want 6710'
	assert face.ascender == 1124, 'Face read ascender ${face.ascender}, want 1124'
	assert face.descender == -634, 'Face read descender ${face.descender}, want -634'
	assert face.line_gap == 0, 'Face read line gap ${face.line_gap}, want 0'

	// And through the shaping entry point, not just the font module.
	loaded := shape.load_font_bytes(built) or { panic('built font would not load as a shape.Font: ${err}') }
	assert loaded.face.units_per_em == 1000, 'shape.Font read ${loaded.face.units_per_em} upem'
	assert loaded.face.num_glyphs == 6710, 'shape.Font read ${loaded.face.num_glyphs} glyphs'
}

fn test_btables_refusals() {
	if _ := font.build_head(0, [0, 0, 0, 0]!, false) {
		assert false, 'head with unitsPerEm 0 built without error'
	}
	if _ := font.build_head(15, [0, 0, 0, 0]!, false) {
		assert false, 'head with unitsPerEm 15 built without error'
	}
	if _ := font.build_head(0x10000, [0, 0, 0, 0]!, false) {
		assert false, 'head with unitsPerEm past u16 built without error'
	}
	if _ := font.build_head(1000, [0, 0, 0, 0x8000]!, false) {
		assert false, 'head with a bbox past i16 built without error'
	}
	if _ := font.build_maxp(-1) {
		assert false, 'maxp with -1 glyphs built without error'
	}
	if _ := font.build_maxp(0x10000) {
		assert false, 'maxp past u16 built without error'
	}
	if _ := font.build_maxp_05(-1) {
		assert false, 'maxp_05 with -1 glyphs built without error'
	}
	if _ := font.build_hhea(0x8000, 0, 0, 1) {
		assert false, 'hhea with an ascender past i16 built without error'
	}
	if _ := font.build_hhea(0, 0, 0, -1) {
		assert false, 'hhea with -1 metrics built without error'
	}
	if _ := font.build_hhea(0, 0, 0, 0x10000) {
		assert false, 'hhea past u16 metrics built without error'
	}
}

// test_btables_break_fix moves the score twice: a flipped magic rebuilds to
// a font the Face reads as headless, and a loca flag disagreeing with the
// loca bytes loads but fails at the first outline, not at load.
fn test_btables_break_fix() {
	// A bad magic: read_head keeps the defaults, so the face reports no
	// units and falls back to 1000.0 per em for scaling.
	mut bad := btables_head()
	bad[12] = 0
	mut bb := font.new_builder(font.sfnt_version_truetype)
	bb.set('head', bad) or { panic('head set refused: ${err}') }
	bb.set('maxp', btables_maxp()) or { panic('maxp set refused: ${err}') }
	built_bad := bb.build() or { panic('bad-magic font would not build: ${err}') }
	face_bad := font.new_face(built_bad) or {
		panic('bad-magic font would not load: ${err}')
	}
	assert face_bad.units_per_em == 0, 'Face read units through a broken magic'
	assert face_bad.units_per_em_f == 1000.0, 'Face lost its 1000.0 fallback'

	// A long loca flag over short loca bytes: the directory still parses and
	// the face still loads (loca is read lazily), and the first outline is
	// where the disagreement surfaces.
	short_loca := [u8(0), 0]
	mut long := font.new_builder(font.sfnt_version_truetype)
	long.set('head', btables_head()) or { panic('head set refused: ${err}') }
	long.set('maxp', btables_maxp()) or { panic('maxp set refused: ${err}') }
	long.set('hhea', btables_hhea()) or { panic('hhea set refused: ${err}') }
	long.set('glyf', []u8{}) or { panic('glyf set refused: ${err}') }
	long.set('loca', short_loca) or { panic('loca set refused: ${err}') }
	built_long := long.build() or { panic('long-flag font would not build: ${err}') }
	face_long := font.new_face(built_long) or {
		panic('long-flag font would not load: ${err}')
	}
	if _ := face_long.glyph_outline(0) {
		assert false, 'long-flag outline over 2 loca bytes answered without error'
	} else {
		assert err.msg().contains('no entries'), 'long-flag outline failed oddly: ${err}'
	}

	// The control: the same bytes under a short flag answer an empty glyph,
	// because two zero bytes are one empty entry pair.
	short_head := font.build_head(1000, [-438, -900, 11467, 1815]!, false) or {
		panic('short head refused: ${err}')
	}
	mut short := font.new_builder(font.sfnt_version_truetype)
	short.set('head', short_head) or { panic('head set refused: ${err}') }
	short.set('maxp', btables_maxp()) or { panic('maxp set refused: ${err}') }
	short.set('hhea', btables_hhea()) or { panic('hhea set refused: ${err}') }
	short.set('glyf', []u8{}) or { panic('glyf set refused: ${err}') }
	short.set('loca', [u8(0), 0, 0, 0]) or { panic('loca set refused: ${err}') }
	built_short := short.build() or { panic('short-flag font would not build: ${err}') }
	face_short := font.new_face(built_short) or {
		panic('short-flag font would not load: ${err}')
	}
	empty := face_short.glyph_outline(0) or { panic('short-flag empty glyph errored: ${err}') }
	assert empty.n_points() == 0, 'short-flag empty glyph has points'
}
