module harfara

import harfara.font
import harfara.shape

// First-font tests for the 14.2d writers: cmap format 4 and the minimal name
// table. This file is self-contained like `build_tables_test.v` and
// `build_metrics_test.v`: every helper it needs is defined here with a bscr_
// prefix, so `v test build_scratch_test.v` compiles this file alone. The field
// readers duplicate the big-endian arithmetic on purpose — the pins prove the
// bytes the writers emit, not the helpers that read them.
//
// The scratch font is assembled entirely from parameters through Builder:
// head/maxp/hhea/hmtx/empty glyf+loca/cmap/name. No corpus font is read. What
// is proved is that the result loads through shape.load_font_bytes, maps code
// points through the engine's own cmap reader, reports the family name from the
// name table, and survives a textfont dump/load byte-symmetrically.

const bscr_family = 'Scratch Test'
const bscr_style = 'Regular'
const bscr_upem = 1000
const bscr_glyphs = 8

// bscr_maps is the mixed mapping set: two delta-only runs separated by a gap,
// then a run whose glyph ids are not consecutive and so needs glyphIdArray.
// Sorted by codepoint: A=0x41, B=0x42, Z=0x5A, a=0x61, b=0x62.
fn bscr_maps() []font.CmapMapping {
	return [
		font.CmapMapping{ cp: 0x41, gid: 1 },
		font.CmapMapping{ cp: 0x42, gid: 2 },
		font.CmapMapping{ cp: 0x5a, gid: 3 },
		font.CmapMapping{ cp: 0x61, gid: 4 },
		font.CmapMapping{ cp: 0x62, gid: 7 },
	]
}

// bscr_be16 reads a big-endian u16 at off.
fn bscr_be16(data []u8, off int) int {
	return int(data[off]) * 256 + int(data[off + 1])
}

// bscr_be32 reads a big-endian u32 at off.
fn bscr_be32(data []u8, off int) u32 {
	return (u32(data[off]) << 24) | (u32(data[off + 1]) << 16) | (u32(data[off + 2]) << 8) | u32(data[off + 3])
}

// bscr_i16 reads a big-endian i16 at off.
fn bscr_i16(data []u8, off int) int {
	v := bscr_be16(data, off)
	return if v >= 0x8000 { v - 0x10000 } else { v }
}

// bscr_file_sum sums the whole file as big-endian words: a self-consistent
// file sums to 0xB1B0AFBA.
fn bscr_file_sum(data []u8) u64 {
	mut sum := u64(0)
	mut i := 0
	for i + 4 <= data.len {
		sum += (u64(data[i]) << 24) | (u64(data[i + 1]) << 16) | (u64(data[i + 2]) << 8) | u64(data[i + 3])
		i += 4
	}
	return sum & 0xffffffff
}

// bscr_assemble builds a complete loadable font from writer output. Every gid
// the cmap names is inside num_glyphs, and the hmtx advances differ per gid so
// a read-back proves which glyph a codepoint reached.
fn bscr_assemble(mappings []font.CmapMapping, family string, style string) []u8 {
	advances := [u16(500), 600, 700, 800, 900, 1000, 1100, 1200]
	lsbs := [i16(0), 0, 0, 0, 0, 0, 0, 0]
	head := font.build_head(bscr_upem, [0, 0, 0, 0]!, false) or {
		panic('head writer refused: ${err}')
	}
	maxp := font.build_maxp(bscr_glyphs) or { panic('maxp writer refused: ${err}') }
	hhea := font.build_hhea(800, -200, 0, bscr_glyphs) or {
		panic('hhea writer refused: ${err}')
	}
	hmtx := font.build_hmtx(advances, lsbs, bscr_glyphs) or {
		panic('hmtx writer refused: ${err}')
	}
	glyf, loca := font.build_empty_glyf_loca(bscr_glyphs, false) or {
		panic('empty glyf/loca writer refused: ${err}')
	}
	cmap := font.build_cmap4(mappings) or { panic('cmap4 writer refused: ${err}') }
	name := font.build_name_minimal(family, style) or { panic('name writer refused: ${err}') }
	mut b := font.new_builder(font.sfnt_version_truetype)
	b.set('head', head) or { panic('head set refused: ${err}') }
	b.set('maxp', maxp) or { panic('maxp set refused: ${err}') }
	b.set('hhea', hhea) or { panic('hhea set refused: ${err}') }
	b.set('hmtx', hmtx) or { panic('hmtx set refused: ${err}') }
	b.set('glyf', glyf) or { panic('glyf set refused: ${err}') }
	b.set('loca', loca) or { panic('loca set refused: ${err}') }
	b.set('cmap', cmap) or { panic('cmap set refused: ${err}') }
	b.set('name', name) or { panic('name set refused: ${err}') }
	return b.build() or { panic('scratch assembly would not build: ${err}') }
}

// bscr_table returns one table body from a built file.
fn bscr_table(data []u8, tag string) []u8 {
	parsed := font.parse_sfnt(data) or { panic('scratch sfnt would not parse: ${err}') }
	return parsed.table_data(tag)
}

// bscr_name_string resolves a Windows Unicode name ID the way an inspection
// caller does: scan the records, take the best (platform, encoding, language)
// match, and decode its UTF-16BE payload. A surrogate pair is joined; a lone
// half answers U+FFFD rather than a wrong rune.
fn bscr_name_string(data []u8, want_id int) string {
	if data.len < 6 {
		return ''
	}
	count := bscr_be16(data, 2)
	storage := bscr_be16(data, 4)
	mut best := ''
	mut best_score := -1
	for i in 0 .. count {
		at := 6 + i * 12
		if at + 12 > data.len {
			break
		}
		platform := bscr_be16(data, at)
		encoding := bscr_be16(data, at + 2)
		lang := bscr_be16(data, at + 4)
		id := bscr_be16(data, at + 6)
		length := bscr_be16(data, at + 8)
		off := bscr_be16(data, at + 10)
		if id != want_id || length <= 0 {
			continue
		}
		score := if platform == 3 && encoding == 1 {
			if lang == 0x0409 { 4 } else { 3 }
		} else if platform == 3 && encoding == 0 {
			2
		} else if platform == 0 {
			1
		} else {
			-1
		}
		if score < 0 || score <= best_score {
			continue
		}
		if storage + off < 0 || storage + off + length > data.len {
			continue
		}
		mut runes_out := []rune{}
		mut p := storage + off
		end := p + length
		for p + 1 < end {
			hi := u16(bscr_be16(data, p))
			p += 2
			if hi >= 0xd800 && hi <= 0xdbff {
				if p + 1 < end {
					lo := u16(bscr_be16(data, p))
					if lo >= 0xdc00 && lo <= 0xdfff {
						runes_out << rune(u32(0x10000) + (u32(hi - 0xd800) << 10) + u32(lo - 0xdc00))
						p += 2
						continue
					}
				}
				runes_out << rune(0xfffd)
			} else if hi >= 0xdc00 && hi <= 0xdfff {
				runes_out << rune(0xfffd)
			} else {
				runes_out << rune(hi)
			}
		}
		best = runes_out.string()
		best_score = score
		if best_score == 4 {
			break
		}
	}
	return best
}

fn test_bscr_cmap4_single_and_empty_pins() {
	// One mapping: the mapped segment plus the 0xFFFF terminator, no glyph
	// array, and the two encoding records sharing the one subtable.
	one := font.build_cmap4([font.CmapMapping{ cp: 0x41, gid: 1 }]) or {
		panic('single cmap4 refused: ${err}')
	}
	assert one.len == 52, 'single cmap is ${one.len} bytes, want 52'
	assert bscr_be16(one, 0) == 0, 'cmap version moved from 0'
	assert bscr_be16(one, 2) == 2, 'cmap has ${bscr_be16(one, 2)} encoding records, want 2'
	assert [bscr_be16(one, 4), bscr_be16(one, 6), int(bscr_be32(one, 8))] == [3, 1, 20], 'Windows BMP record moved'
	assert [bscr_be16(one, 12), bscr_be16(one, 14), int(bscr_be32(one, 16))] == [0, 3, 20], 'Unicode BMP record moved'
	sub := 20
	assert bscr_be16(one, sub) == 4, 'subtable format is not 4'
	assert bscr_be16(one, sub + 2) == 32, 'subtable length ${bscr_be16(one, sub + 2)} want 32'
	assert bscr_be16(one, sub + 4) == 0, 'subtable language is not 0'
	assert bscr_be16(one, sub + 6) == 4, 'segCountX2 is not 4'
	assert bscr_be16(one, sub + 8) == 4, 'searchRange is not 4 for 2 segments'
	assert bscr_be16(one, sub + 10) == 1, 'entrySelector is not 1 for 2 segments'
	assert bscr_be16(one, sub + 12) == 0, 'rangeShift is not 0 for 2 segments'
	// Arrays: endCode, reservedPad, startCode, idDelta, idRangeOffset.
	assert [u16(bscr_be16(one, sub + 14)), u16(bscr_be16(one, sub + 16))] == [
		u16(0x41),
		u16(0xffff),
	], 'endCode array moved'
	assert bscr_be16(one, sub + 18) == 0, 'reservedPad is not 0'
	assert [u16(bscr_be16(one, sub + 20)), u16(bscr_be16(one, sub + 22))] == [
		u16(0x41),
		u16(0xffff),
	], 'startCode array moved'
	assert [i16(bscr_i16(one, sub + 24)), i16(bscr_i16(one, sub + 26))] == [i16(-64), i16(1)], 'idDelta array moved'
	assert bscr_be16(one, sub + 28) == 0 && bscr_be16(one, sub + 30) == 0, 'idRangeOffset is not all zero'

	// No mappings: the terminator alone is still a valid one-segment cmap.
	empty_cmap := font.build_cmap4([]font.CmapMapping{}) or {
		panic('empty cmap4 refused: ${err}')
	}
	assert empty_cmap.len == 44, 'empty cmap is ${empty_cmap.len} bytes, want 44'
	assert bscr_be16(empty_cmap, sub + 6) == 2, 'empty cmap has more than its terminator segment'
	assert bscr_be16(empty_cmap, sub + 8) == 2 && bscr_be16(empty_cmap, sub + 10) == 0, 'empty cmap search fields are not for one segment'
	assert u16(bscr_be16(empty_cmap, sub + 14)) == u16(0xffff), 'empty cmap lost its terminator'
	assert i16(bscr_i16(empty_cmap, sub + 14 + 2 + 2 + 2)) == i16(1), 'terminator idDelta is not 1'
}

fn test_bscr_cmap4_multi_segment_pins() {
	cmap := font.build_cmap4(bscr_maps()) or { panic('mixed cmap4 refused: ${err}') }
	sub := 20
	// Four segments: A..B (delta), Z (delta), a..b (glyph array), terminator.
	assert bscr_be16(cmap, sub + 6) == 8, 'segCountX2 is not 8 for 4 segments'
	assert [bscr_be16(cmap, sub + 8), bscr_be16(cmap, sub + 10), bscr_be16(cmap, sub + 12)] == [
		8,
		2,
		0,
	], 'format 4 search fields moved'
	assert bscr_be16(cmap, sub + 2) == 16 + 8 * 4 + 4, 'subtable length does not count the two glyph ids'
	ends := [u16(bscr_be16(cmap, sub + 14)), u16(bscr_be16(cmap, sub + 16)),
		u16(bscr_be16(cmap, sub + 18)), u16(bscr_be16(cmap, sub + 20))]
	assert ends == [u16(0x42), u16(0x5a), u16(0x62), u16(0xffff)], 'endCode array moved'
	starts_at := sub + 14 + 8 + 2
	starts := [u16(bscr_be16(cmap, starts_at)), u16(bscr_be16(cmap, starts_at + 2)),
		u16(bscr_be16(cmap, starts_at + 4)), u16(bscr_be16(cmap, starts_at + 6))]
	assert starts == [u16(0x41), u16(0x5a), u16(0x61), u16(0xffff)], 'startCode array moved'
	deltas_at := starts_at + 8
	deltas := [i16(bscr_i16(cmap, deltas_at)), i16(bscr_i16(cmap, deltas_at + 2)),
		i16(bscr_i16(cmap, deltas_at + 4)), i16(bscr_i16(cmap, deltas_at + 6))]
	assert deltas == [i16(-64), i16(-87), i16(0), i16(1)], 'idDelta array moved'
	ranges_at := deltas_at + 8
	assert [bscr_be16(cmap, ranges_at), bscr_be16(cmap, ranges_at + 2), bscr_be16(cmap, ranges_at + 4),
		bscr_be16(cmap, ranges_at + 6)] == [
		0,
		0,
		4,
		0,
	], 'idRangeOffset of the glyph-array segment moved'
	assert [u16(bscr_be16(cmap, ranges_at + 8)), u16(bscr_be16(cmap, ranges_at + 10))] == [
		u16(4),
		u16(7),
	], 'glyphIdArray moved'

	// The engine reads both records back to the same mappings.
	cmaps := font.parse_cmap(cmap)
	assert cmaps.len == 2, 'parse_cmap read ${cmaps.len} subtables, want both records'
	for c in cmaps {
		assert c.format == 4, 'subtable is format ${c.format}, want 4'
	}
	for case in [font.CmapMapping{ cp: 0x41, gid: 1 }, font.CmapMapping{ cp: 0x42, gid: 2 },
		font.CmapMapping{ cp: 0x5a, gid: 3 }, font.CmapMapping{ cp: 0x61, gid: 4 },
		font.CmapMapping{ cp: 0x62, gid: 7 }] {
		assert font.glyph_index_for(cmaps, case.cp) == case.gid, 'gid for U+${case.cp:x} is ${font.glyph_index_for(cmaps, case.cp)}, want ${case.gid}'
	}
	assert font.glyph_index_for(cmaps, 0x43) == 0, 'a gap inside a segment answered a glyph'
}

fn test_bscr_name_layout_pins() {
	name := font.build_name_minimal(bscr_family, bscr_style) or {
		panic('name writer refused: ${err}')
	}
	assert bscr_be16(name, 0) == 0, 'name format is not 0'
	assert bscr_be16(name, 2) == 4, 'name has ${bscr_be16(name, 2)} records, want 4'
	assert bscr_be16(name, 4) == 54, 'stringOffset ${bscr_be16(name, 4)} want 54'
	ids := [1, 2, 4, 6]
	want_lengths := [24, 14, 40, 38] // UTF-16BE byte counts, not rune counts
	want_offsets := [0, 24, 38, 78]
	for i, id in ids {
		rec := 6 + i * 12
		assert [bscr_be16(name, rec), bscr_be16(name, rec + 2), bscr_be16(name, rec + 4)] == [
			3,
			1,
			0x0409,
		], 'record ${i} is not Windows Unicode English US'
		assert bscr_be16(name, rec + 6) == id, 'record ${i} has name ID ${bscr_be16(name, rec + 6)}, want ${id}'
		assert bscr_be16(name, rec + 8) == want_lengths[i], 'record ${i} length moved'
		assert bscr_be16(name, rec + 10) == want_offsets[i], 'record ${i} string offset moved'
	}
	assert name.len == 54 + 116, 'name table is ${name.len} bytes, want 170'
	assert [u8(0x00), 0x53, 0x00, 0x63, 0x00, 0x72] == name[54..60], 'family payload is not UTF-16BE'
	assert bscr_name_string(name, 1) == bscr_family, 'family did not decode back'
	assert bscr_name_string(name, 2) == bscr_style, 'style did not decode back'
	assert bscr_name_string(name, 4) == 'Scratch Test Regular', 'full name moved'
	assert bscr_name_string(name, 6) == 'ScratchTest-Regular', 'postscript name moved'

	// A non-ASCII family goes through a surrogate-free UTF-16BE pair per rune.
	wide := font.build_name_minimal('Café', bscr_style) or {
		panic('non-ASCII name writer refused: ${err}')
	}
	assert [u8(0x00), 0xe9] == wide[54 + 6..54 + 8], 'U+00E9 is not 0x00E9 in the payload'
	assert bscr_name_string(wide, 1) == 'Café', 'non-ASCII family did not decode back'
}

fn test_bscr_scratch_font_readback() {
	built := bscr_assemble(bscr_maps(), bscr_family, bscr_style)
	loaded := shape.load_font_bytes(built) or {
		panic('scratch font would not load as a shape.Font: ${err}')
	}
	assert loaded.num_glyphs() == bscr_glyphs, 'shape.Font read ${loaded.num_glyphs()} glyphs'
	for case in [font.CmapMapping{ cp: 0x41, gid: 1 }, font.CmapMapping{ cp: 0x42, gid: 2 },
		font.CmapMapping{ cp: 0x5a, gid: 3 }, font.CmapMapping{ cp: 0x61, gid: 4 },
		font.CmapMapping{ cp: 0x62, gid: 7 }] {
		got := loaded.glyph_index(rune(case.cp))
		assert got == case.gid, 'glyph_index(U+${case.cp:x}) is ${got}, want ${case.gid}'
		assert loaded.has_glyph(rune(case.cp)), 'has_glyph(U+${case.cp:x}) is false'
	}
	assert loaded.glyph_index(rune(0x7a)) == 0, 'unmapped codepoint did not answer .notdef'
	assert !loaded.has_glyph(rune(0x7a)), 'unmapped codepoint claims a glyph'
	// The advances come from hmtx and are per-gid, so they identify the gid the
	// cmap reached rather than repeating the mapping assertion.
	assert loaded.face.glyph_advance_units(1) == 600, 'gid 1 advance moved'
	assert loaded.face.glyph_advance_units(7) == 1200, 'gid 7 advance moved'
	assert loaded.glyph_advance(7, 1000.0) == 1200.0, 'shape.Font scaled gid 7 wrongly'
	assert loaded.glyph_advance(1, 500.0) == 300.0, 'shape.Font scaled gid 1 wrongly'

	// Family name from the built name table, through the inspection reader's
	// record walk and through the textfont dump's parsed name block.
	name := bscr_table(built, font.tag_name)
	assert bscr_name_string(name, 1) == bscr_family, 'built font reports family ${bscr_name_string(name, 1)}'
	assert bscr_name_string(name, 2) == bscr_style, 'built font reports the wrong style'
	text := font.textfont_dump(built) or { panic('scratch font would not dump: ${err}') }
	assert text.contains('begin name'), 'dump has no parsed name block'
	assert text.contains('begin cmap'), 'dump has no parsed cmap block'
	assert text.contains('005300630072006100740063006800200054006500730074'), 'dump does not show the family payload'

	// The builder's checksum patch and the text round-trip both close on the
	// same bytes.
	assert bscr_file_sum(built) == u64(0xB1B0AFBA), 'scratch font fails the whole-file checksum'
	rebuilt := font.textfont_load(text) or { panic('scratch dump would not load: ${err}') }
	assert rebuilt == built, 'scratch textfont round-trip is not byte-symmetric'
	assert bscr_file_sum(rebuilt) == u64(0xB1B0AFBA), 'rebuilt scratch font fails the checksum'
}

fn test_bscr_refusals() {
	// Strictly increasing input: no reordering, no silent overwrite.
	if _ := font.build_cmap4([
		font.CmapMapping{ cp: 0x42, gid: 1 },
		font.CmapMapping{ cp: 0x41, gid: 2 },
	]) {
		assert false, 'unsorted mappings built without error'
	}
	if _ := font.build_cmap4([
		font.CmapMapping{ cp: 0x41, gid: 1 },
		font.CmapMapping{ cp: 0x41, gid: 2 },
	]) {
		assert false, 'overlapping mappings built without error'
	}
	if _ := font.build_cmap4([font.CmapMapping{ cp: 0x10000, gid: 1 }]) {
		assert false, 'non-BMP mapping built without error'
	}
	if _ := font.build_cmap4([font.CmapMapping{ cp: 0xffff, gid: 1 }]) {
		assert false, 'mapping onto the 0xFFFF terminator built without error'
	}
	if _ := font.build_name_minimal('', bscr_style) {
		assert false, 'empty family built a name table'
	}
}

// test_bscr_break_fix moves the score: changing one mapping's gid moves that
// codepoint's glyph (and its advance) in a rebuilt font, while the other
// mappings stay put. Changing the family moves the name table, not the cmap.
fn test_bscr_break_fix() {
	base_maps := bscr_maps()
	first := bscr_assemble(base_maps, bscr_family, bscr_style)
	mut moved_maps := base_maps.clone()
	moved_maps[0] = font.CmapMapping{ cp: 0x41, gid: 7 }
	second := bscr_assemble(moved_maps, bscr_family, bscr_style)
	assert first != second, 'changing a gid rebuilt identical bytes'
	old_font := shape.load_font_bytes(first) or { panic('baseline font would not load: ${err}') }
	new_font := shape.load_font_bytes(second) or { panic('moved font would not load: ${err}') }
	assert old_font.glyph_index(rune(0x41)) == 1, 'baseline A moved'
	assert new_font.glyph_index(rune(0x41)) == 7, 'A did not follow its changed gid'
	assert new_font.glyph_index(rune(0x42)) == 2, 'the gid change leaked into B'
	assert old_font.glyph_advance(1, 1000.0) == 600.0, 'baseline advance moved'
	assert new_font.glyph_advance(7, 1000.0) == 1200.0, 'A did not reach the changed gid advance'
	assert bscr_table(first, font.tag_cmap) != bscr_table(second, font.tag_cmap), 'cmap bytes did not move'
	assert bscr_table(first, font.tag_name) == bscr_table(second, font.tag_name), 'a gid change moved the name table'

	third := bscr_assemble(base_maps, 'Other Family', bscr_style)
	assert bscr_name_string(bscr_table(third, font.tag_name), 1) == 'Other Family', 'renamed family did not reach the name table'
	assert bscr_table(third, font.tag_cmap) == bscr_table(first, font.tag_cmap), 'a family change moved the cmap'
	assert bscr_table(third, font.tag_name) != bscr_table(first, font.tag_name), 'renamed family left identical name bytes'
	renamed := shape.load_font_bytes(third) or { panic('renamed font would not load: ${err}') }
	assert renamed.glyph_index(rune(0x41)) == 1, 'renaming changed glyph coverage'
}
