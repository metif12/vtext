module harfara

import harfara.font

// This file is self-contained: every helper it needs is defined here with a
// builder_ prefix, so `v test builder_test.v` compiles this file alone. The
// checksum helpers deliberately duplicate the builder's arithmetic rather
// than calling it: the pins below prove the file the builder emits, not the
// function it used to get there.

// builder_head returns a 54-byte synthetic head table: version 1.0, a zero
// checkSumAdjustment for the builder to patch, and unitsPerEm 1000. The
// content is arbitrary; the length is what matters (at least 12 bytes, so
// bytes 8..12 exist for the adjustment).
fn builder_head() []u8 {
	mut head := []u8{len: 54}
	head[0] = 0
	head[1] = 1
	head[2] = 0
	head[3] = 0
	head[18] = 3
	head[19] = 232 // unitsPerEm 1000
	head[50] = 0
	head[51] = 0 // indexToLocFormat 0: short loca
	return head
}

// builder_maxp returns a 6-byte synthetic maxp: version 0.5 with 3 glyphs.
fn builder_maxp() []u8 {
	return [u8(0), 0x50, 0, 0, 0, 3]
}

// builder_be16 reads a big-endian u16 at off.
fn builder_be16(data []u8, off int) int {
	return int(data[off]) * 256 + int(data[off + 1])
}

// builder_be32 reads a big-endian u32 at off.
fn builder_be32(data []u8, off int) u32 {
	return (u32(data[off]) << 24) | (u32(data[off + 1]) << 16) | (u32(data[off + 2]) << 8) | u32(data[off + 3])
}

// builder_checksum sums bytes as big-endian words with zero padding, the
// sfnt table checksum rule. A local copy of the builder's arithmetic: the
// pins below verify the emitted directory, not the helper that wrote it.
fn builder_checksum(b []u8) u32 {
	mut sum := u64(0)
	mut i := 0
	for i + 4 <= b.len {
		sum += (u64(b[i]) << 24) | (u64(b[i + 1]) << 16) | (u64(b[i + 2]) << 8) | u64(b[i + 3])
		i += 4
	}
	mut tail := u64(0)
	mut shift := 24
	for i < b.len {
		tail |= u64(b[i]) << u32(shift)
		shift -= 8
		i++
	}
	return u32((sum + tail) & 0xffffffff)
}

// builder_file_sum sums a whole file as big-endian words, the sfnt
// whole-file rule: a self-consistent file sums to 0xB1B0AFBA.
fn builder_file_sum(data []u8) u64 {
	mut sum := u64(0)
	mut i := 0
	for i + 4 <= data.len {
		sum += (u64(data[i]) << 24) | (u64(data[i + 1]) << 16) | (u64(data[i + 2]) << 8) | u64(data[i + 3])
		i += 4
	}
	return sum & 0xffffffff
}

// builder_dir_tags reads the directory tags in directory order.
fn builder_dir_tags(data []u8) []string {
	n := builder_be16(data, 4)
	mut out := []string{cap: n}
	for i in 0 .. n {
		rec := 12 + i * 16
		out << data[rec..rec + 4].bytestr()
	}
	return out
}

// builder_span returns the offset and length the directory records for tag.
fn builder_span(data []u8, tag string) (int, int) {
	n := builder_be16(data, 4)
	for i in 0 .. n {
		rec := 12 + i * 16
		if data[rec..rec + 4].bytestr() == tag {
			return int(builder_be32(data, rec + 8)), int(builder_be32(data, rec + 12))
		}
	}
	panic('no directory entry for ${tag}')
	return -1, -1
}

// builder_dir_checksum returns the stored directory checksum for tag.
fn builder_dir_checksum(data []u8, tag string) u32 {
	n := builder_be16(data, 4)
	for i in 0 .. n {
		rec := 12 + i * 16
		if data[rec..rec + 4].bytestr() == tag {
			return builder_be32(data, rec + 4)
		}
	}
	panic('no directory entry for ${tag}')
	return 0
}

// builder_assemble feeds three tables in unsorted order and builds: TEST
// (7 bytes, pinning the 4-alignment pad), head and maxp.
fn builder_assemble() []u8 {
	mut b := font.new_builder(font.sfnt_version_truetype)
	b.set('maxp', builder_maxp()) or { panic('maxp set refused: ${err}') }
	b.set('TEST', [u8(1), 2, 3, 4, 5, 6, 7]) or { panic('TEST set refused: ${err}') }
	b.set('head', builder_head()) or { panic('head set refused: ${err}') }
	return b.build() or { panic('build refused: ${err}') }
}

fn test_builder_synthetic_assembly() {
	built := builder_assemble()
	// The header: TrueType version, 3 tables, and the search fields for 3.
	assert builder_be32(built, 0) == u32(0x00010000), 'bad sfnt version'
	assert builder_be16(built, 4) == 3, 'bad table count'
	assert builder_be16(built, 6) == 32, 'bad search range for 3 tables'
	assert builder_be16(built, 8) == 1, 'bad entry selector for 3 tables'
	assert builder_be16(built, 10) == 16, 'bad range shift for 3 tables'
	// Tags are sorted whatever order set() saw them in.
	assert builder_dir_tags(built) == ['TEST', 'head', 'maxp'], 'directory is not tag-sorted'
	// Every body starts 4-aligned; the odd-length TEST table pins the pad.
	for tag in ['TEST', 'head', 'maxp'] {
		off, _ := builder_span(built, tag)
		assert off % 4 == 0, '${tag} starts at ${off}, not 4-aligned'
	}
	toff, tlen := builder_span(built, 'TEST')
	assert tlen == 7, 'TEST length is ${tlen}, want 7'
	assert built[toff..toff + 7] == [u8(1), 2, 3, 4, 5, 6, 7], 'TEST body moved'
	assert built[toff + 7] == 0, 'TEST pad byte is not zero'
	hoff, hlen := builder_span(built, 'head')
	assert hlen == 54, 'head length is ${hlen}, want 54'
	assert hoff == toff + 8, 'head does not follow the padded TEST table'
	// Per-table checksums verify, with head summed over a zeroed adjustment.
	for tag in ['TEST', 'head', 'maxp'] {
		off, length := builder_span(built, tag)
		mut body := built[off..off + length].clone()
		if tag == 'head' {
			body[8] = 0
			body[9] = 0
			body[10] = 0
			body[11] = 0
		}
		assert builder_dir_checksum(built, tag) == builder_checksum(body), '${tag} directory checksum is wrong'
	}
	// And the whole file sums to the magic: the adjustment patch landed.
	assert builder_file_sum(built) == u64(0xB1B0AFBA), 'built file fails the whole-file checksum'
	// It is still a font: the directory parses with every table.
	parsed := font.parse_sfnt(built) or { panic('built sfnt would not parse: ${err}') }
	assert parsed.tables.len == 3, 'built font lost tables'
}

fn test_builder_textfont_crosscheck() {
	built := builder_assemble()
	// The builder canonicalises the way the subset rebuilds do; textfont
	// stores a layout. Dumping the built file and loading it back must
	// therefore reproduce the same bytes: the cross-check that the builder
	// emits a file the round-trip accepts.
	text := font.textfont_dump(built) or { panic('built file would not dump: ${err}') }
	rebuilt := font.textfont_load(text) or { panic('built dump would not load: ${err}') }
	assert rebuilt == built, 'textfont round-trip of a built font is not byte-symmetric'
	assert builder_file_sum(rebuilt) == u64(0xB1B0AFBA), 'rebuilt file fails the whole-file checksum'
	// Setting a tag twice replaces it: the second body is what builds.
	mut b := font.new_builder(font.sfnt_version_truetype)
	b.set('head', builder_head()) or { panic('head set refused: ${err}') }
	b.set('maxp', builder_maxp()) or { panic('maxp set refused: ${err}') }
	b.set('TEST', [u8(9), 9, 9]) or { panic('TEST set refused: ${err}') }
	b.set('TEST', [u8(1), 2, 3, 4, 5, 6, 7]) or { panic('TEST re-set refused: ${err}') }
	again := b.build() or { panic('re-set build refused: ${err}') }
	assert again == built, 're-set tag did not replace the first body'
}

fn test_builder_refusals() {
	// No head table: there is nowhere for the adjustment to go.
	mut no_head := font.new_builder(font.sfnt_version_truetype)
	no_head.set('maxp', builder_maxp()) or { panic('maxp set refused: ${err}') }
	if _ := no_head.build() {
		assert false, 'headless build succeeded without error'
	}
	// A head shorter than 12 bytes has no checkSumAdjustment field.
	mut short_head := font.new_builder(font.sfnt_version_truetype)
	short_head.set('head', [u8(0), 1, 0, 0, 0, 0, 0, 0]) or {
		panic('short head set refused: ${err}')
	}
	if _ := short_head.build() {
		assert false, 'short-head build succeeded without error'
	}
	// Tags are 4 bytes, no more and no fewer.
	mut bad_tag := font.new_builder(font.sfnt_version_truetype)
	if _ := bad_tag.set('abc', builder_maxp()) {
		assert false, '3-byte tag set without error'
	}
	if _ := bad_tag.set('abcde', builder_maxp()) {
		assert false, '5-byte tag set without error'
	}
	// A non-text tag byte is refused the way textfont_load refuses one.
	if _ := bad_tag.set('ab\x01d', builder_maxp()) {
		assert false, 'non-text tag set without error'
	}
}

// test_builder_break_fix is the control that moves the score: one flipped
// input byte rebuilds to different bytes, and both builds stay
// self-consistent. If neither changed the output, the test would pass on a
// builder that ignores its input.
fn test_builder_break_fix() {
	first := builder_assemble()
	mut b := font.new_builder(font.sfnt_version_truetype)
	b.set('head', builder_head()) or { panic('head set refused: ${err}') }
	b.set('maxp', builder_maxp()) or { panic('maxp set refused: ${err}') }
	b.set('TEST', [u8(1), 2, 3, 4, 5, 6, 8]) or { panic('TEST set refused: ${err}') }
	second := b.build() or { panic('flipped build refused: ${err}') }
	assert second != first, 'flipped input byte rebuilt to identical bytes'
	// The flip moved the TEST table (and head, through the recomputed
	// adjustment), and nothing else claims otherwise: both files verify.
	assert builder_file_sum(first) == u64(0xB1B0AFBA), 'first build fails the whole-file checksum'
	assert builder_file_sum(second) == u64(0xB1B0AFBA), 'flipped build fails the whole-file checksum'
	foff, _ := builder_span(first, 'TEST')
	soff, _ := builder_span(second, 'TEST')
	assert first[foff..foff + 7] != second[soff..soff + 7], 'TEST body is unchanged after the flip'
	assert builder_dir_checksum(first, 'TEST') != builder_dir_checksum(second, 'TEST'), 'TEST checksum is unchanged after the flip'
}
