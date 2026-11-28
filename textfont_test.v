module harfara

import harfara.font
import os

// This file is self-contained: every helper it needs is defined here with a
// textfont_ prefix, so `v test textfont_test.v` compiles this file alone.

// textfont_corpus_fonts lists the committed sfnt corpus: every .ttf and .otf
// under testdata/fonts. WOFF containers, licences and the collection case
// are not here: 14.1a round-trips plain sfnt, and WOFF unwrap is 14.0's
// proven path.
fn textfont_corpus_fonts() []string {
	mut out := []string{}
	for entry in os.ls('testdata/fonts') or { return out } {
		if entry.ends_with('.ttf') || entry.ends_with('.otf') {
			out << os.join_path('testdata/fonts', entry)
		}
	}
	out.sort()
	return out
}

// textfont_file_sum sums bytes as big-endian words, the sfnt whole-file sum.
fn textfont_file_sum(data []u8) u64 {
	mut sum := u64(0)
	mut i := 0
	for i + 4 <= data.len {
		sum += (u64(data[i]) << 24) | (u64(data[i + 1]) << 16) | (u64(data[i + 2]) << 8) | u64(data[i + 3])
		i += 4
	}
	return sum & 0xffffffff
}

// textfont_hex_at returns the hex field of a table line: everything after
// the last space. The hex never contains spaces, but tags like `CFF ` do,
// so splitting on spaces is wrong and the last space is right.
fn textfont_hex_at(line string) int {
	return line.last_index(' ') or { -1 }
}

fn test_textfont_corpus_byte_symmetry() {
	fonts := textfont_corpus_fonts()
	assert fonts.len >= 25, 'corpus too small: ${fonts.len} sfnt files'
	for path in fonts {
		raw := os.read_bytes(path) or { panic('${path} is not readable: ${err}') }
		text := font.textfont_dump(raw) or { panic('${path} refused: ${err}') }
		rebuilt := font.textfont_load(text) or { panic('${path} would not load: ${err}') }
		assert rebuilt == raw, '${path} is not byte-symmetric'
		// Idempotence: a rebuilt file dumps to the same text, so the format
		// has one rendering per font rather than a choice of them.
		text2 := font.textfont_dump(rebuilt) or { panic('${path} re-dump refused: ${err}') }
		assert text2 == text, '${path} dump is not idempotent'
		// The rebuild carries its own proof: a self-consistent file sums
		// to the magic, and every corpus file is self-consistent.
		assert textfont_file_sum(rebuilt) == u64(0xB1B0AFBA), '${path} rebuilt file fails the whole-file checksum'
		// And it is still a font: the directory parses with every table.
		parsed := font.parse_sfnt(rebuilt) or { panic('${path} rebuilt sfnt would not parse: ${err}') }
		orig := font.parse_sfnt(raw) or { panic('${path} original sfnt would not parse: ${err}') }
		assert parsed.tables.len == orig.tables.len, '${path} lost tables: ${parsed.tables.len} vs ${orig.tables.len}'
	}
}

// test_textfont_refusals pins every way a dump or a load can say no. A
// refusal that is not pinned is a crash report waiting for its font.
fn test_textfont_refusals() {
	// Nothing to read.
	if _ := font.textfont_dump([]u8{}) {
		assert false, 'empty file dumped without error'
	}
	if _ := font.textfont_dump('ttcf'.bytes()) {
		assert false, 'short file dumped without error'
	}
	// A collection would silently lose members.
	if _ := font.textfont_dump('ttcf00000000'.bytes()) {
		assert false, 'TTC dumped without error'
	}
	// Containers unwrap elsewhere.
	if _ := font.textfont_dump('wOF1'.bytes()) {
		assert false, 'WOFF1 dumped without error'
	}
	if _ := font.textfont_dump('wOF2'.bytes()) {
		assert false, 'WOFF2 dumped without error'
	}
	// Unknown version.
	if _ := font.textfont_dump('typ100000000'.bytes()) {
		assert false, 'unknown version dumped without error'
	}
	// Truncated directory.
	raw := os.read_bytes('testdata/fonts/Amiri-Regular.ttf') or {
		panic('Amiri-Regular.ttf is not readable: ${err}')
	}
	if _ := font.textfont_dump(raw[0..100]) {
		assert false, 'truncated file dumped without error'
	}
	good := font.textfont_dump(raw) or { panic('Amiri would not dump: ${err}') }
	lines := good.split_into_lines()
	// Bad magic line.
	if _ := font.textfont_load('bad-magic\n' + lines[1..].join('\n') + '\n') {
		assert false, 'bad magic loaded without error'
	}
	// Bad sfnt version.
	mut badver := lines.clone()
	badver[1] = 'sfnt 12345678 428032'
	if _ := font.textfont_load(badver.join('\n') + '\n') {
		assert false, 'bad version loaded without error'
	}
	// Odd hex length.
	at := textfont_hex_at(lines[3])
	mut odd := lines.clone()
	odd[3] = odd[3] + '0'
	if _ := font.textfont_load(odd.join('\n') + '\n') {
		assert false, 'odd hex loaded without error'
	}
	// Non-hex data: 'G' is never a hex digit, wherever it lands.
	mut nonhex := lines.clone()
	nonhex[3] = nonhex[3][0..at + 1] + 'G' + nonhex[3][at + 2..]
	if _ := font.textfont_load(nonhex.join('\n') + '\n') {
		assert false, 'non-hex loaded without error'
	}
	// Uppercase hex is refused: dumps emit lowercase, one rendering per font.
	mut upper := lines.clone()
	upper[3] = upper[3][0..at + 1] + 'AB' + upper[3][at + 3..]
	if _ := font.textfont_load(upper.join('\n') + '\n') {
		assert false, 'uppercase hex loaded without error'
	}
	// A duplicated table line.
	if _ := font.textfont_load(good + lines[3] + '\n') {
		assert false, 'duplicate tag loaded without error'
	}
	// An offset moved over its neighbour: line 4 takes line 3's offset.
	off3_end := lines[3].index_after(' ', 11) or { -1 }
	off4_start := 11
	off4_end := lines[4].index_after(' ', 11) or { -1 }
	assert off3_end > 11 && off4_end > 11, 'cannot find offsets in table lines'
	mut overlap := lines.clone()
	overlap[4] = overlap[4][0..off4_start] + overlap[3][11..off3_end] + overlap[4][off4_end..]
	if _ := font.textfont_load(overlap.join('\n') + '\n') {
		assert false, 'overlapping tables loaded without error'
	}
	// A table past the file end.
	mut past_end := lines.clone()
	past_end[3] = past_end[3][0..off4_start] + '99999999' + past_end[3][off3_end..]
	if _ := font.textfont_load(past_end.join('\n') + '\n') {
		assert false, 'table past the end loaded without error'
	}
	// No tables at all.
	if _ := font.textfont_load('harfara-roundtrip 1\nsfnt 00010000 12\nsearch 16 1 0\n') {
		assert false, 'table-less dump loaded without error'
	}
	// A non-text tag byte.
	mut badtag := lines.clone()
	badtag[3] = 'table \x01BCD 1234 abcdef'
	if _ := font.textfont_load(badtag.join('\n') + '\n') {
		assert false, 'non-text tag loaded without error'
	}
}

// test_textfont_break_fix is the control that moves the score: one flipped
// hex digit rebuilds to different bytes, and one dropped table rebuilds to a
// font missing that table. If neither changed the output, the test would
// pass on a loader that ignores its input.
fn test_textfont_break_fix() {
	raw := os.read_bytes('testdata/fonts/Amiri-Regular.ttf') or {
		panic('Amiri-Regular.ttf is not readable: ${err}')
	}
	text := font.textfont_dump(raw) or { panic('Amiri would not dump: ${err}') }
	lines := text.split_into_lines()
	at := textfont_hex_at(lines[3])
	mut hexb := lines[3][at + 1..].bytes()
	mut first := int(hexb[0])
	if first == 48 {
		first = 49
	} else {
		first = 48
	}
	hexb[0] = u8(first)
	mut flipped := lines.clone()
	flipped[3] = lines[3][0..at + 1] + hexb.bytestr()
	changed := font.textfont_load(flipped.join('\n') + '\n') or {
		panic('flipped dump would not load: ${err}')
	}
	assert changed != raw, 'flipped hex digit rebuilt to identical bytes'
	// The flip is still a font: the loader changed the input, not the format.
	parsed := font.parse_sfnt(changed) or { panic('flipped rebuild would not parse: ${err}') }
	assert 'glyf' in parsed.tables, 'flipped rebuild lost glyf'
	// Dropping a table line drops the table.
	mut dropped := []string{}
	for i, line in lines {
		if line == '' {
			continue
		}
		if i == lines.len - 2 {
			continue
		}
		dropped << line
	}
	shorter := font.textfont_load(dropped.join('\n') + '\n') or {
		panic('dropped-table dump would not load: ${err}')
	}
	assert shorter != raw, 'dropped table rebuilt to identical bytes'
	short_parsed := font.parse_sfnt(shorter) or {
		panic('dropped rebuild would not parse: ${err}')
	}
	orig := font.parse_sfnt(raw) or { panic('original would not parse: ${err}') }
	assert short_parsed.tables.len == orig.tables.len - 1, 'dropped rebuild kept every table'
}
