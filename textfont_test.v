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
	// Dropping a table line drops the table. The last table line is found by
	// prefix, not by position: parsed blocks group after all table lines, so
	// the dump's tail is blocks, not tables.
	mut last_table := -1
	for i, line in lines {
		if line.starts_with('table ') {
			last_table = i
		}
	}
	assert last_table > 3, 'no table line to drop'
	mut dropped := []string{}
	for i, line in lines {
		if line == '' {
			continue
		}
		if i == last_table {
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

// ---------- 14.1b wave 1: parsed table overlays ----------
//
// The design under test: dumps carry raw table lines plus `begin TAG ... end
// TAG` blocks for head, hhea, maxp, hmtx, OS/2, post, name and cmap; load
// rebuilds each block and refuses any disagreement with the raw line. Two
// deviations from the scoping pass are pinned here rather than silently
// carried: (1) cmap is segment/group-level, not a flat codepoint map, because
// byte-equality forces it — a flat map cannot reproduce subtable choice,
// idRangeOffset sharing or format 14's per-record tables (NotoSansKR's format
// 14 has 12 records pointing at 19 distinct shared tables); (2) OS/2 vendor-id
// travels as lowercase hex and panose as ten decimals, because both spell the
// same bytes and the choice is arbitrary. The name table has no Face accessor
// (family_name/style_name are never populated), so its pin asserts table bytes
// rather than a Face field.

// textfont_join rejoins split dump lines, restoring the trailing newline the
// dump ends with.
fn textfont_join(tlines []string) string {
	return tlines.join('\n') + '\n'
}

// textfont_block_span returns the [begin, end] line indices of a parsed block,
// both markers inclusive.
fn textfont_block_span(tlines []string, tag string) (int, int) {
	mut bi := -1
	mut ei := -1
	for i, line in tlines {
		if line == 'begin ${tag}' {
			bi = i
		}
		if line == 'end ${tag}' {
			ei = i
		}
	}
	assert bi >= 0 && ei > bi, 'missing block ${tag}'
	return bi, ei
}

// textfont_has_block reports whether the dump carries a parsed block for tag.
fn textfont_has_block(text string, tag string) bool {
	for line in text.split_into_lines() {
		if line == 'begin ${tag}' {
			return true
		}
	}
	return false
}

// textfont_field_val returns the value part of a field line inside a block.
fn textfont_field_val(text string, tag string, word string) string {
	tlines := text.split_into_lines()
	bi, ei := textfont_block_span(tlines, tag)
	for i in bi + 1 .. ei {
		if tlines[i] == word || tlines[i].starts_with(word + ' ') {
			return tlines[i][word.len + 1..]
		}
	}
	panic('missing field ${word} in ${tag}')
	return ''
}

// textfont_set_field replaces the value part of a field line inside a block.
fn textfont_set_field(text string, tag string, word string, newval string) string {
	tlines := text.split_into_lines()
	bi, ei := textfont_block_span(tlines, tag)
	mut out := tlines.clone()
	mut done := false
	for i in bi + 1 .. ei {
		if tlines[i] == word || tlines[i].starts_with(word + ' ') {
			out[i] = '${word} ${newval}'
			done = true
		}
	}
	assert done, 'missing field ${word} in ${tag}'
	return textfont_join(out)
}

// textfont_table_hex returns the hex payload of a raw table line.
fn textfont_table_hex(text string, tag string) string {
	for line in text.split_into_lines() {
		if line.starts_with('table ') && line.len >= 10 && line[6..10] == tag {
			at := textfont_hex_at(line)
			return line[at + 1..]
		}
	}
	panic('missing table line ${tag}')
	return ''
}

// textfont_patch_hex splices newhex over the table bytes at byte off.
fn textfont_patch_hex(text string, tag string, off int, newhex string) string {
	tlines := text.split_into_lines()
	mut out := tlines.clone()
	mut done := false
	for i, line in tlines {
		if line.starts_with('table ') && line.len >= 10 && line[6..10] == tag {
			at := textfont_hex_at(line)
			hex := line[at + 1..]
			assert hex.len >= (off + newhex.len / 2) * 2, 'patch runs past ${tag}'
			out[i] = line[..at + 1] + hex[..off * 2] + newhex +
				hex[off * 2 + newhex.len..]
			done = true
		}
	}
	assert done, 'missing table line ${tag}'
	return textfont_join(out)
}

// textfont_coherent_u16 edits a u16 field and its raw bytes together: the one
// edit the loader must accept, proving the parsed side drives the output.
fn textfont_coherent_u16(text string, tag string, field string, off int, new_val int) string {
	assert new_val >= 0 && new_val <= 65535
	patched := textfont_patch_hex(text, tag, off, '${u16(new_val):04x}')
	return textfont_set_field(patched, tag, field, '${new_val}')
}

// textfont_strip_blocks drops every parsed block, leaving a 14.1a-style dump.
fn textfont_strip_blocks(text string) string {
	mut out := []string{}
	for line in text.split_into_lines() {
		if line.starts_with('begin ') {
			break
		}
		out << line
	}
	return textfont_join(out)
}

// textfont_replace_counting replaces needle, asserting it occurs want times
// (shared cmap subtables are stored once, so a group window occurs once; the
// helper keeps the count explicit at the call site).
fn textfont_replace_counting(s string, needle string, new_ string, want int) string {
	assert s.count(needle) == want, 'want ${want} occurrence(s)'
	return s.replace(needle, new_)
}

// textfont_changed_tables lists the tags whose bytes differ between two
// fonts, sorted. Directory checksums and head.checkSumAdjustment live outside
// table bodies (adjustment inside head), so a one-table edit changes at most
// the target plus head.
fn textfont_changed_tables(a []u8, b []u8) []string {
	fa := font.parse_sfnt(a) or { panic('a would not parse: ${err}') }
	fb := font.parse_sfnt(b) or { panic('b would not parse: ${err}') }
	mut changed := []string{}
	for tag, rec in fa.tables {
		r2 := fb.record(tag) or {
			changed << tag
			continue
		}
		if a[rec.offset..rec.offset + rec.length] != b[r2.offset..r2.offset + r2.length] {
			changed << tag
		}
	}
	for tag in fb.tables.keys() {
		if tag !in fa.tables {
			changed << tag
		}
	}
	changed.sort()
	return changed
}

// textfont_same_except_adjustment reports whether two dumps differ only in
// head.checkSumAdjustment: the `check-sum-adjustment` field line and bytes
// 8..12 of the raw head hex. A coherent edit changes file bytes, so the
// recomputed adjustment must differ; everything else must be identical.
fn textfont_same_except_adjustment(a string, b string) bool {
	la := a.split_into_lines()
	lb := b.split_into_lines()
	if la.len != lb.len {
		return false
	}
	for i in 0 .. la.len {
		if la[i] == lb[i] {
			continue
		}
		if la[i].starts_with('check-sum-adjustment ') && lb[i].starts_with('check-sum-adjustment ') {
			continue
		}
		if la[i].starts_with('table head ') && lb[i].starts_with('table head ') {
			ha := la[i][la[i].last_index(' ') or { -1 } + 1..]
			hb := lb[i][lb[i].last_index(' ') or { -1 } + 1..]
			if ha.len != hb.len || ha.len < 48 {
				return false
			}
			if ha[..16] == hb[..16] && ha[24..] == hb[24..] {
				continue
			}
		}
		return false
	}
	return true
}

// textfont_cp_val parses a `0x` codepoint back to a number.
fn textfont_cp_val(s string) u32 {
	assert s.starts_with('0x')
	mut v := u32(0)
	for b in s[2..].bytes() {
		v = (v << 4) | if b >= `a` { u32(b - `a` + 10) } else { u32(b - `0`) }
	}
	return v
}

// textfont_synth_sum sums bytes as big-endian words, the sfnt checksum rule.
// A local copy of the loader's arithmetic: the synth font must be
// self-consistent (stored checksums matching bytes) for rebuilt == original
// to hold, the way every corpus font is.
fn textfont_synth_sum(b []u8) u64 {
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
	sum += tail
	return sum & 0xffffffff
}

// textfont_synth builds a minimal self-consistent container from directory
// order and bodies: packed tables, standard search fields, real directory
// checksums and a real head.checkSumAdjustment, so load rebuilds it exactly.
fn textfont_synth(tags []string, bodies [][]u8) []u8 {
	assert tags.len == bodies.len && tags.len > 0
	n := tags.len
	mut es := 0
	for (1 << (es + 1)) * 16 <= n * 16 {
		es++
	}
	sr := 16 * (1 << es)
	rs := 16 * n - sr
	mut size := 12 + 16 * n
	for b in bodies {
		size += b.len
	}
	mut out := []u8{len: size}
	out[0] = 0
	out[1] = 1
	out[2] = 0
	out[3] = 0
	out[4] = u8((n >> 8) & 0xff)
	out[5] = u8(n & 0xff)
	out[6] = u8((sr >> 8) & 0xff)
	out[7] = u8(sr & 0xff)
	out[8] = u8((es >> 8) & 0xff)
	out[9] = u8(es & 0xff)
	out[10] = u8((rs >> 8) & 0xff)
	out[11] = u8(rs & 0xff)
	mut at := 12 + 16 * n
	for i in 0 .. n {
		rec := 12 + i * 16
		tb := tags[i].bytes()
		for k in 0 .. 4 {
			out[rec + k] = tb[k]
		}
		out[rec + 8] = u8((at >> 24) & 0xff)
		out[rec + 9] = u8((at >> 16) & 0xff)
		out[rec + 10] = u8((at >> 8) & 0xff)
		out[rec + 11] = u8(at & 0xff)
		out[rec + 12] = u8((bodies[i].len >> 24) & 0xff)
		out[rec + 13] = u8((bodies[i].len >> 16) & 0xff)
		out[rec + 14] = u8((bodies[i].len >> 8) & 0xff)
		out[rec + 15] = u8(bodies[i].len & 0xff)
		for k, byte_val in bodies[i] {
			out[at + k] = byte_val
		}
		at += bodies[i].len
	}
	// Self-consistent checksums: directory entries sum their table bodies
	// (head with its adjustment zeroed, the way the loader checksums it),
	// then head.checkSumAdjustment makes the whole file sum to the magic.
	for i in 0 .. n {
		rec := 12 + i * 16
		off := (int(out[rec + 8]) << 24) | (int(out[rec + 9]) << 16) | (int(out[rec + 10]) << 8) | int(out[rec + 11])
		length := (int(out[rec + 12]) << 24) | (int(out[rec + 13]) << 16) | (int(out[rec + 14]) << 8) | int(out[rec + 15])
		mut body := out[off..off + length].clone()
		if tags[i] == 'head' && body.len >= 12 {
			body[8] = 0
			body[9] = 0
			body[10] = 0
			body[11] = 0
		}
		sum := textfont_synth_sum(body)
		out[rec + 4] = u8((sum >> 24) & 0xff)
		out[rec + 5] = u8((sum >> 16) & 0xff)
		out[rec + 6] = u8((sum >> 8) & 0xff)
		out[rec + 7] = u8(sum & 0xff)
	}
	mut whole := u64(0)
	mut i := 0
	// The loader sums the laid-out file with the adjustment field zeroed, so
	// the synth zeroes it before summing too; the patch below restores it.
	mut head_off := -1
	for j, tag in tags {
		if tag == 'head' {
			rec := 12 + j * 16
			head_off = (int(out[rec + 8]) << 24) | (int(out[rec + 9]) << 16) | (int(out[rec + 10]) << 8) | int(out[rec + 11])
		}
	}
	if head_off >= 0 && head_off + 12 <= out.len {
		out[head_off + 8] = 0
		out[head_off + 9] = 0
		out[head_off + 10] = 0
		out[head_off + 11] = 0
	}
	for i + 4 <= out.len {
		whole += (u64(out[i]) << 24) | (u64(out[i + 1]) << 16) | (u64(out[i + 2]) << 8) | u64(out[i + 3])
		i += 4
	}
	whole = whole & 0xffffffff
	adjust := (u64(0xB1B0AFBA) + 0x100000000 - whole) % 0x100000000
	if head_off >= 0 && head_off + 12 <= out.len {
		out[head_off + 8] = u8((adjust >> 24) & 0xff)
		out[head_off + 9] = u8((adjust >> 16) & 0xff)
		out[head_off + 10] = u8((adjust >> 8) & 0xff)
		out[head_off + 11] = u8(adjust & 0xff)
	}
	return out
}

fn test_textfont_parsed_corpus_coverage() {
	fonts := textfont_corpus_fonts()
	assert fonts.len >= 25
	wave1 := ['head', 'hhea', 'maxp', 'hmtx', 'OS/2', 'post', 'name', 'cmap']
	for path in fonts {
		raw := os.read_bytes(path) or { panic('${path} is not readable: ${err}') }
		sfnt := font.parse_sfnt(raw) or { panic('${path} would not parse: ${err}') }
		text := font.textfont_dump(raw) or { panic('${path} refused: ${err}') }
		// Every wave 1 table present gets a parsed block: no silent raw-only
		// on the corpus.
		for tag in wave1 {
			if tag in sfnt.tables {
				assert textfont_has_block(text, tag), '${path} has no ${tag} block'
			}
		}
		rebuilt := font.textfont_load(text) or { panic('${path} would not load: ${err}') }
		assert rebuilt == raw, '${path} parsed round-trip is not byte-symmetric'
		// The blocks sit after all table lines, in directory order.
		tlines := text.split_into_lines()
		mut first_begin := -1
		mut last_table := -1
		for i, line in tlines {
			if line.starts_with('table ') {
				last_table = i
			}
			if line.starts_with('begin ') && first_begin < 0 {
				first_begin = i
			}
		}
		assert first_begin > last_table, '${path} blocks are not grouped after tables'
		// And the rebuild is still a font.
		face := font.new_face(rebuilt) or { panic('${path} rebuilt face would not load: ${err}') }
		assert face.num_glyphs > 0, '${path} rebuilt face has no glyphs'
	}
}

fn test_textfont_parsed_fallback() {
	raw := os.read_bytes('testdata/fonts/Amiri-Regular.ttf') or {
		panic('Amiri-Regular.ttf is not readable: ${err}')
	}
	text := font.textfont_dump(raw) or { panic('Amiri would not dump: ${err}') }
	assert textfont_has_block(text, 'head'), 'Amiri dump has no head block'
	stripped := textfont_strip_blocks(text)
	for tag in ['head', 'hhea', 'maxp', 'hmtx', 'OS/2', 'post', 'name', 'cmap'] {
		assert !textfont_has_block(stripped, tag), 'strip left a ${tag} block'
	}
	// Missing blocks fall back to raw-only: the 14.1a text still loads to the
	// same bytes.
	plain := font.textfont_load(stripped) or { panic('stripped dump would not load: ${err}') }
	assert plain == raw, 'stripped dump is not byte-symmetric'
}

fn test_textfont_parsed_bad_shapes() {
	raw := os.read_bytes('testdata/fonts/Amiri-Regular.ttf') or {
		panic('Amiri-Regular.ttf is not readable: ${err}')
	}
	text := font.textfont_dump(raw) or { panic('Amiri would not dump: ${err}') }
	// An unknown begin tag errors, even with a matching end.
	if _ := font.textfont_load(text + 'begin FOO\nend FOO\n') {
		assert false, 'unknown parsed table loaded without error'
	}
	// A mismatched end errors.
	if _ := font.textfont_load(text.replace('end head', 'end hhea')) {
		assert false, 'mismatched end loaded without error'
	}
	// An unclosed block errors.
	if _ := font.textfont_load(text.replace('end head\n', '')) {
		assert false, 'unclosed block loaded without error'
	}
	// A duplicated block errors.
	tlines := text.split_into_lines()
	bi, ei := textfont_block_span(tlines, 'head')
	mut dup := tlines.clone()
	for i in bi .. ei + 1 {
		dup << tlines[i]
	}
	if _ := font.textfont_load(textfont_join(dup)) {
		assert false, 'duplicated block loaded without error'
	}
	// A block for a table with no raw line errors.
	mut no_post := []string{}
	for line in tlines {
		if line.starts_with('table post ') {
			continue
		}
		no_post << line
	}
	assert no_post.len == tlines.len - 1, 'no post table line found'
	if _ := font.textfont_load(textfont_join(no_post)) {
		assert false, 'block without a table line loaded without error'
	}
	// A table line after the blocks begin errors.
	mut moved := []string{}
	for line in tlines {
		if !line.starts_with('table head ') {
			moved << line
		}
	}
	mut with_moved := []string{}
	for line in moved {
		with_moved << line
		if line.starts_with('begin ') {
			break
		}
	}
	assert with_moved.len < moved.len, 'no block found to move after'
	for line in tlines {
		if line.starts_with('table head ') {
			with_moved << line
			break
		}
	}
	if _ := font.textfont_load(textfont_join(with_moved)) {
		assert false, 'table line after blocks loaded without error'
	}
	// A stray field line between blocks errors, as does an unknown prefix.
	_, ei2 := textfont_block_span(tlines, 'head')
	mut stray := tlines.clone()
	stray.insert(ei2 + 1, 'units-per-em 1000')
	if _ := font.textfont_load(textfont_join(stray)) {
		assert false, 'stray field line loaded without error'
	}
	mut bogus := tlines.clone()
	bogus.insert(ei2 + 1, 'frobnicate 1')
	if _ := font.textfont_load(textfont_join(bogus)) {
		assert false, 'unknown prefix loaded without error'
	}
}

fn test_textfont_parsed_head() {
	raw := os.read_bytes('testdata/fonts/Amiri-Regular.ttf') or {
		panic('Amiri-Regular.ttf is not readable: ${err}')
	}
	text := font.textfont_dump(raw) or { panic('Amiri would not dump: ${err}') }
	cur := textfont_field_val(text, 'head', 'units-per-em').int()
	new_upem := if cur == 1000 { 2000 } else { 1000 }
	// Parsed-only flip disagrees with the raw line: refuse.
	flipped := textfont_set_field(text, 'head', 'units-per-em', '${new_upem}')
	if _ := font.textfont_load(flipped) {
		assert false, 'disagreeing head block loaded without error'
	}
	// The coherent edit moves exactly the head table's bytes, and the Face
	// re-read shows the new value.
	coherent := textfont_coherent_u16(text, 'head', 'units-per-em', 18, new_upem)
	moved := font.textfont_load(coherent) or { panic('coherent head edit would not load: ${err}') }
	assert moved != raw, 'coherent head edit changed nothing'
	assert textfont_changed_tables(raw, moved) == ['head'], 'head edit moved other tables'
	face := font.new_face(moved) or { panic('edited face would not load: ${err}') }
	assert face.units_per_em == new_upem, 'Face kept units-per-em ${face.units_per_em}'
	redump1 := font.textfont_dump(moved) or { panic('re-dump failed: ${err}') }
	assert textfont_same_except_adjustment(redump1, coherent), 'head edit is not idempotent'
	assert font.textfont_load(redump1) or { panic('re-dump would not load: ${err}') } == moved, 'fixed point failed'
	// Garbage refuses.
	bad := textfont_set_field(text, 'head', 'units-per-em', 'abc')
	if _ := font.textfont_load(bad) {
		assert false, 'non-numeric head field loaded without error'
	}
	bad2 := textfont_set_field(text, 'head', 'units-per-em', '999999')
	if _ := font.textfont_load(bad2) {
		assert false, 'out-of-range head field loaded without error'
	}
}

fn test_textfont_parsed_hhea() {
	raw := os.read_bytes('testdata/fonts/Amiri-Regular.ttf') or {
		panic('Amiri-Regular.ttf is not readable: ${err}')
	}
	text := font.textfont_dump(raw) or { panic('Amiri would not dump: ${err}') }
	cur := textfont_field_val(text, 'hhea', 'ascender').int()
	new_asc := cur + 10
	flipped := textfont_set_field(text, 'hhea', 'ascender', '${new_asc}')
	if _ := font.textfont_load(flipped) {
		assert false, 'disagreeing hhea block loaded without error'
	}
	// Ascender is a positive i16 here, so the raw patch shares the u16 path.
	coherent := textfont_coherent_u16(text, 'hhea', 'ascender', 4, new_asc)
	moved := font.textfont_load(coherent) or { panic('coherent hhea edit would not load: ${err}') }
	assert textfont_changed_tables(raw, moved) == ['head', 'hhea'], 'hhea edit moved other tables'
	face := font.new_face(moved) or { panic('edited face would not load: ${err}') }
	assert face.ascender == f64(new_asc), 'Face kept ascender ${face.ascender}'
	redump2 := font.textfont_dump(moved) or { panic('re-dump failed: ${err}') }
	assert textfont_same_except_adjustment(redump2, coherent), 'hhea edit is not idempotent'
	assert font.textfont_load(redump2) or { panic('re-dump would not load: ${err}') } == moved, 'fixed point failed'
	bad := textfont_set_field(text, 'hhea', 'ascender', '999999')
	if _ := font.textfont_load(bad) {
		assert false, 'out-of-range hhea field loaded without error'
	}
}

fn test_textfont_parsed_maxp() {
	raw := os.read_bytes('testdata/fonts/Amiri-Regular.ttf') or {
		panic('Amiri-Regular.ttf is not readable: ${err}')
	}
	text := font.textfont_dump(raw) or { panic('Amiri would not dump: ${err}') }
	cur := textfont_field_val(text, 'maxp', 'num-glyphs').int()
	new_ng := cur - 10
	assert new_ng > 0
	flipped := textfont_set_field(text, 'maxp', 'num-glyphs', '${new_ng}')
	if _ := font.textfont_load(flipped) {
		assert false, 'disagreeing maxp block loaded without error'
	}
	// Fewer glyphs: hmtx keeps its bytes (the edit is byte-scoped, not
	// cross-checked), and the Face re-read shows the new count.
	coherent := textfont_coherent_u16(text, 'maxp', 'num-glyphs', 4, new_ng)
	moved := font.textfont_load(coherent) or { panic('coherent maxp edit would not load: ${err}') }
	assert textfont_changed_tables(raw, moved) == ['head', 'maxp'], 'maxp edit moved other tables'
	face := font.new_face(moved) or { panic('edited face would not load: ${err}') }
	assert face.num_glyphs == new_ng, 'Face kept num-glyphs ${face.num_glyphs}'
	redump3 := font.textfont_dump(moved) or { panic('re-dump failed: ${err}') }
	assert textfont_same_except_adjustment(redump3, coherent), 'maxp edit is not idempotent'
	assert font.textfont_load(redump3) or { panic('re-dump would not load: ${err}') } == moved, 'fixed point failed'
	bad := textfont_set_field(text, 'maxp', 'num-glyphs', 'xyz')
	if _ := font.textfont_load(bad) {
		assert false, 'non-numeric maxp field loaded without error'
	}
}

fn test_textfont_parsed_hmtx() {
	raw := os.read_bytes('testdata/fonts/DoulosSIL-Regular.ttf') or {
		panic('DoulosSIL-Regular.ttf is not readable: ${err}')
	}
	text := font.textfont_dump(raw) or { panic('DoulosSIL would not dump: ${err}') }
	// First long metric: advance + 1.
	tlines := text.split_into_lines()
	bi, _ := textfont_block_span(tlines, 'hmtx')
	metric_line := tlines[bi + 3]
	mbits := metric_line.split(' ')
	assert mbits[0] == 'metric' && mbits.len == 3, 'first hmtx line is not a metric'
	adv := mbits[1].int()
	lsb := mbits[2].int()
	assert adv >= 0 && adv < 65535 && lsb >= 0, 'unflippable first metric'
	new_adv := adv + 1
	// A parsed-only metric flip disagrees: refuse. Patch the metric line
	// directly (two values, so set_field cannot spell it).
	mut only_parsed := tlines.clone()
	only_parsed[bi + 3] = 'metric ${new_adv} ${lsb}'
	if _ := font.textfont_load(textfont_join(only_parsed)) {
		assert false, 'disagreeing hmtx block loaded without error'
	}
	lsb_hex := '${u16(lsb):04x}'
	coherent_text := textfont_patch_hex(text, 'hmtx', 0, '${u16(new_adv):04x}' + lsb_hex)
	mut coherent_lines := coherent_text.split_into_lines()
	cbi, _ := textfont_block_span(coherent_lines, 'hmtx')
	coherent_lines[cbi + 3] = 'metric ${new_adv} ${lsb}'
	coherent := textfont_join(coherent_lines)
	moved := font.textfont_load(coherent) or { panic('coherent hmtx edit would not load: ${err}') }
	assert textfont_changed_tables(raw, moved) == ['head', 'hmtx'], 'hmtx metric edit moved other tables'
	face := font.new_face(moved) or { panic('edited face would not load: ${err}') }
	assert face.advances[0] == u16(new_adv), 'Face kept advance ${face.advances[0]}'
	redump4 := font.textfont_dump(moved) or { panic('re-dump failed: ${err}') }
	assert textfont_same_except_adjustment(redump4, coherent), 'hmtx edit is not idempotent'
	assert font.textfont_load(redump4) or { panic('re-dump would not load: ${err}') } == moved, 'fixed point failed'
	// Monospaced tail: the last bearing + 1. DoulosSIL carries a 7-entry tail.
	tail_val := textfont_field_val(text, 'hmtx', 'lsb-tail')
	tbits := tail_val.split(' ')
	assert tbits.len == 7, 'DoulosSIL tail is ${tbits.len}, want 7'
	last_lsb := tbits[tbits.len - 1].int()
	assert last_lsb >= 0 && last_lsb < 32767, 'unflippable tail bearing'
	hmtx_hex := textfont_table_hex(text, 'hmtx')
	tail_off := hmtx_hex.len / 2 - 2
	mut tail_lines := textfont_patch_hex(text, 'hmtx', tail_off, '${u16(last_lsb + 1):04x}').split_into_lines()
	tbi, _ := textfont_block_span(tail_lines, 'hmtx')
	mut new_tail := ''
	for i, v in tbits {
		if i > 0 {
			new_tail += ' '
		}
		new_tail += if i == tbits.len - 1 { '${last_lsb + 1}' } else { v }
	}
	// The lsb-tail line is the one right after the last metric: find it.
	mut tail_idx := -1
	for i in tbi + 1 .. tail_lines.len {
		if tail_lines[i].starts_with('lsb-tail') {
			tail_idx = i
			break
		}
	}
	assert tail_idx > 0, 'no lsb-tail line found'
	tail_lines[tail_idx] = 'lsb-tail ${new_tail}'
	tail_edit := textfont_join(tail_lines)
	moved_tail := font.textfont_load(tail_edit) or { panic('coherent tail edit would not load: ${err}') }
	assert textfont_changed_tables(raw, moved_tail) == ['head', 'hmtx'], 'hmtx tail edit moved other tables'
	face2 := font.new_face(moved_tail) or { panic('edited face would not load: ${err}') }
	assert face2.lsbs[face2.lsbs.len - 1] == i16(last_lsb + 1), 'Face kept tail bearing'
	redump_tail := font.textfont_dump(moved_tail) or { panic('re-dump failed: ${err}') }
	assert textfont_same_except_adjustment(redump_tail, tail_edit), 'hmtx tail edit is not idempotent'
	assert font.textfont_load(redump_tail) or { panic('re-dump would not load: ${err}') } == moved_tail, 'fixed point failed'
	// A short tail refuses.
	bad := textfont_set_field(text, 'hmtx', 'lsb-tail', '1 2')
	if _ := font.textfont_load(bad) {
		assert false, 'short hmtx tail loaded without error'
	}
}

fn test_textfont_parsed_os2() {
	raw := os.read_bytes('testdata/fonts/Amiri-Regular.ttf') or {
		panic('Amiri-Regular.ttf is not readable: ${err}')
	}
	text := font.textfont_dump(raw) or { panic('Amiri would not dump: ${err}') }
	cur := textfont_field_val(text, 'OS/2', 'weight-class').int()
	new_w := if cur == 500 { 400 } else { 500 }
	flipped := textfont_set_field(text, 'OS/2', 'weight-class', '${new_w}')
	if _ := font.textfont_load(flipped) {
		assert false, 'disagreeing OS/2 block loaded without error'
	}
	coherent := textfont_coherent_u16(text, 'OS/2', 'weight-class', 4, new_w)
	moved := font.textfont_load(coherent) or { panic('coherent OS/2 edit would not load: ${err}') }
	assert textfont_changed_tables(raw, moved) == ['OS/2', 'head'], 'OS/2 edit moved other tables'
	face := font.new_face(moved) or { panic('edited face would not load: ${err}') }
	assert face.weight == new_w, 'Face kept weight ${face.weight}'
	redump5 := font.textfont_dump(moved) or { panic('re-dump failed: ${err}') }
	assert textfont_same_except_adjustment(redump5, coherent), 'OS/2 edit is not idempotent'
	assert font.textfont_load(redump5) or { panic('re-dump would not load: ${err}') } == moved, 'fixed point failed'
	bad := textfont_set_field(text, 'OS/2', 'panose', '1 2 3')
	if _ := font.textfont_load(bad) {
		assert false, 'short OS/2 panose loaded without error'
	}
}

fn test_textfont_parsed_post() {
	// Version 3.0: bare 32 bytes (Amiri).
	raw := os.read_bytes('testdata/fonts/Amiri-Regular.ttf') or {
		panic('Amiri-Regular.ttf is not readable: ${err}')
	}
	text := font.textfont_dump(raw) or { panic('Amiri would not dump: ${err}') }
	flipped := textfont_set_field(text, 'post', 'italic-angle', '1')
	if _ := font.textfont_load(flipped) {
		assert false, 'disagreeing post block loaded without error'
	}
	coherent := textfont_join(textfont_set_field(textfont_patch_hex(text, 'post', 4, '00010000'),
		'post', 'italic-angle', '1').split_into_lines())
	moved := font.textfont_load(coherent) or { panic('coherent post edit would not load: ${err}') }
	assert textfont_changed_tables(raw, moved) == ['head', 'post'], 'post edit moved other tables'
	face := font.new_face(moved) or { panic('edited face would not load: ${err}') }
	assert face.italic_angle == 1.0, 'Face kept italic angle ${face.italic_angle}'
	redump6 := font.textfont_dump(moved) or { panic('re-dump failed: ${err}') }
	assert textfont_same_except_adjustment(redump6, coherent), 'post edit is not idempotent'
	assert font.textfont_load(redump6) or { panic('re-dump would not load: ${err}') } == moved, 'fixed point failed'
	// Version 2.0 with names (NotoSansNKo, the smallest post-2.0 carrier):
	// negative angle exercises the signed Fixed path.
	raw2 := os.read_bytes('testdata/fonts/NotoSansNKo-Regular.ttf') or {
		panic('NotoSansNKo-Regular.ttf is not readable: ${err}')
	}
	text2 := font.textfont_dump(raw2) or { panic('NotoSansNKo would not dump: ${err}') }
	coherent2 := textfont_join(textfont_set_field(textfont_patch_hex(text2, 'post', 4,
		'ffff0000'), 'post', 'italic-angle', '-1').split_into_lines())
	moved2 := font.textfont_load(coherent2) or { panic('coherent post 2.0 edit would not load: ${err}') }
	assert textfont_changed_tables(raw2, moved2) == ['head', 'post'], 'post 2.0 edit moved other tables'
	face2 := font.new_face(moved2) or { panic('edited face would not load: ${err}') }
	assert face2.italic_angle == -1.0, 'Face kept italic angle ${face2.italic_angle}'
	redump7 := font.textfont_dump(moved2) or { panic('re-dump failed: ${err}') }
	assert textfont_same_except_adjustment(redump7, coherent2), 'post 2.0 edit is not idempotent'
	assert font.textfont_load(redump7) or { panic('re-dump would not load: ${err}') } == moved2, 'fixed point failed'
	// A names-blob flip without its raw twin refuses.
	names_hex := textfont_field_val(text2, 'post', 'names')
	assert names_hex.len >= 4, 'post names blob too short to flip'
	flip_digit := if names_hex[0] == `a` { 'b' } else { 'a' }
	bad_names := textfont_set_field(text2, 'post', 'names', flip_digit + names_hex[1..])
	if _ := font.textfont_load(bad_names) {
		assert false, 'disagreeing post names loaded without error'
	}
	bad := textfont_set_field(text2, 'post', 'names', 'xyz')
	if _ := font.textfont_load(bad) {
		assert false, 'non-hex post names loaded without error'
	}
}

fn test_textfont_parsed_name() {
	raw := os.read_bytes('testdata/fonts/Amiri-Regular.ttf') or {
		panic('Amiri-Regular.ttf is not readable: ${err}')
	}
	text := font.textfont_dump(raw) or { panic('Amiri would not dump: ${err}') }
	// Flip the first hex digit of the longest payload, in both spellings.
	// (Face has no name accessor — family_name/style_name are never populated
	// — so this pin asserts table bytes and directory scope instead.)
	tlines := text.split_into_lines()
	bi, ei := textfont_block_span(tlines, 'name')
	mut best := -1
	mut best_len := 0
	for i in bi + 1 .. ei {
		parts := tlines[i].split(' ')
		if parts.len == 7 && parts[0] == 'record' && parts[6].len > best_len {
			best = i
			best_len = parts[6].len
		}
	}
	assert best > 0 && best_len >= 4, 'no flippable name record'
	payload := tlines[best].split(' ')[6]
	flip_digit := if payload[0] == `a` { 'b' } else { 'a' }
	new_payload := flip_digit + payload[1..]
	mut only_parsed_lines := tlines.clone()
	only_parsed_lines[best] = only_parsed_lines[best].replace(payload, new_payload)
	if _ := font.textfont_load(textfont_join(only_parsed_lines)) {
		assert false, 'disagreeing name block loaded without error'
	}
	// The payload is verbatim subtable bytes, so its hex is a substring of
	// the raw line: widen the window until it is unique, then patch both.
	mut window := payload[..16]
	raw_hex := textfont_table_hex(text, 'name')
	mut wlen := 16
	for raw_hex.count(window) != 1 {
		wlen += 4
		assert wlen <= payload.len, 'name window never unique'
		window = payload[..wlen]
	}
	new_window := flip_digit + window[1..]
	patched_hex := textfont_replace_counting(raw_hex, window, new_window, 1)
	mut both := tlines.clone()
	for i, line in both {
		if line.starts_with('table name ') {
			at := textfont_hex_at(line)
			both[i] = line[..at + 1] + patched_hex
		}
	}
	both[best] = both[best].replace(payload, new_payload)
	coherent := textfont_join(both)
	moved := font.textfont_load(coherent) or { panic('coherent name edit would not load: ${err}') }
	assert textfont_changed_tables(raw, moved) == ['head', 'name'], 'name edit moved other tables'
	moved_sfnt := font.parse_sfnt(moved) or { panic('edited font would not parse: ${err}') }
	moved_name := moved_sfnt.table_data('name')
	assert moved_name.hex().contains(new_payload), 'edited name payload missing from rebuild'
	redump8 := font.textfont_dump(moved) or { panic('re-dump failed: ${err}') }
	assert textfont_same_except_adjustment(redump8, coherent), 'name edit is not idempotent'
	assert font.textfont_load(redump8) or { panic('re-dump would not load: ${err}') } == moved, 'fixed point failed'
	// A short record refuses.
	bad := textfont_set_field(text, 'name', 'count', '999')
	if _ := font.textfont_load(bad) {
		assert false, 'lying name count loaded without error'
	}
}

fn test_textfont_parsed_cmap() {
	raw := os.read_bytes('testdata/fonts/Amiri-Regular.ttf') or {
		panic('Amiri-Regular.ttf is not readable: ${err}')
	}
	text := font.textfont_dump(raw) or { panic('Amiri would not dump: ${err}') }
	// The (3,10) format 12 subtable is the best-scored mapping: flip its first
	// nonzero group. Group bytes are verbatim subtable bytes, so the 12-char
	// window patches the raw line at exactly the right place.
	tlines := text.split_into_lines()
	mut sub_at := -1
	for i, line in tlines {
		if line == 'subtable 1 12' {
			sub_at = i
			break
		}
	}
	assert sub_at > 0, 'no (3,10) format 12 subtable found'
	mut group_idx := -1
	mut start_cp := u32(0)
	mut group_gid := 0
	mut in_groups := false
	for i in sub_at + 1 .. tlines.len {
		parts := tlines[i].split(' ')
		if parts.len == 4 && parts[0] == 'group' {
			in_groups = true
			gid := parts[3].int()
			if gid != 0 {
				group_idx = i
				start_cp = textfont_cp_val(parts[1])
				group_gid = gid
				break
			}
			continue
		}
		if in_groups {
			break
		}
	}
	assert group_idx > 0, 'no nonzero f12 group found'
	new_gid := group_gid + 1
	assert new_gid <= 65535
	start_hex := tlines[group_idx].split(' ')[1][2..]
	end_hex := tlines[group_idx].split(' ')[2][2..]
	mut sp := start_hex
	for sp.len < 8 {
		sp = '0' + sp
	}
	mut ep := end_hex
	for ep.len < 8 {
		ep = '0' + ep
	}
	window := sp + ep + '${u32(group_gid):08x}'
	raw_hex := textfont_table_hex(text, 'cmap')
	assert raw_hex.count(window) >= 1, 'group window missing from raw cmap'
	// The two f12 subtables are byte-identical and stored once (shared), so
	// one window occurrence is the norm; two would mean duplication.
	patched_hex := textfont_replace_counting(raw_hex, window, sp + ep + '${u32(new_gid):08x}',
		raw_hex.count(window))
	mut both := tlines.clone()
	for i, line in both {
		if line.starts_with('table cmap ') {
			at := textfont_hex_at(line)
			both[i] = line[..at + 1] + patched_hex
		}
	}
	gbits := both[group_idx].split(' ')
	both[group_idx] = 'group ${gbits[1]} ${gbits[2]} ${new_gid}'
	coherent := textfont_join(both)
	moved := font.textfont_load(coherent) or { panic('coherent cmap edit would not load: ${err}') }
	assert textfont_changed_tables(raw, moved) == ['cmap', 'head'], 'cmap edit moved other tables'
	face := font.new_face(moved) or { panic('edited face would not load: ${err}') }
	assert face.glyph_index(rune(start_cp)) == u16(new_gid), 'Face kept cmap mapping'
	redump9 := font.textfont_dump(moved) or { panic('re-dump failed: ${err}') }
	assert textfont_same_except_adjustment(redump9, coherent), 'cmap edit is not idempotent'
	assert font.textfont_load(redump9) or { panic('re-dump would not load: ${err}') } == moved, 'fixed point failed'
	// A parsed-only group flip disagrees: refuse.
	mut only_parsed := tlines.clone()
	obits := only_parsed[group_idx].split(' ')
	only_parsed[group_idx] = 'group ${obits[1]} ${obits[2]} ${new_gid}'
	if _ := font.textfont_load(textfont_join(only_parsed)) {
		assert false, 'disagreeing cmap block loaded without error'
	}
	// A malformed group refuses.
	mut bad := tlines.clone()
	bad[group_idx] = 'group 0x20 0x7e'
	if _ := font.textfont_load(textfont_join(bad)) {
		assert false, 'short cmap group loaded without error'
	}
}

fn textfont_parsed_refusal(tags []string, bodies [][]u8, absent string) {
	f := textfont_synth(tags, bodies)
	text := font.textfont_dump(f) or { panic('synth dump refused: ${err}') }
	assert !textfont_has_block(text, absent), 'refused layout still got a ${absent} block'
	rebuilt := font.textfont_load(text) or { panic('synth raw-only load refused: ${err}') }
	assert rebuilt == f, 'synth raw-only round-trip is not byte-symmetric'
}

fn test_textfont_parsed_refusals() {
	// Each probe feeds one layout the encoder does not represent: the dump
	// must succeed raw-only, and the raw-only text must round-trip.
	head60 := []u8{len: 60}
	maxp10 := [u8(0), u8(1), u8(0), u8(0), u8(0), u8(2), u8(0), u8(0), u8(0), u8(0)]
	name0 := [u8(0), u8(0), u8(0), u8(0), u8(0), u8(6)]
	textfont_parsed_refusal(['head', 'maxp', 'name'], [head60, maxp10, name0], 'head')
	textfont_parsed_refusal(['head', 'maxp', 'name'], [[]u8{len: 54}, [u8(0), u8(0)], name0], 'maxp')
	hhea40 := []u8{len: 40}
	textfont_parsed_refusal(['hhea', 'maxp', 'hmtx'], [hhea40, maxp10, []u8{len: 4}],
		'hhea')
	textfont_parsed_refusal(['hhea', 'maxp', 'hmtx'], [[]u8{len: 36}, maxp10, []u8{len: 5}],
		'hmtx')
	os2_80 := []u8{len: 80}
	textfont_parsed_refusal(['OS/2', 'maxp'], [os2_80, maxp10], 'OS/2')
	mut post25 := [u8(0), u8(2), u8(0x50), u8(0)]
	post25 << []u8{len: 36}
	textfont_parsed_refusal(['post', 'maxp'], [post25, maxp10], 'post')
	name1 := [u8(0), u8(1), u8(0), u8(0), u8(0), u8(6)]
	textfont_parsed_refusal(['name', 'maxp'], [name1, maxp10], 'name')
	// Format 13 stays raw: the whole cmap keeps its raw line only.
	f13 := [u8(0), u8(13), u8(0), u8(0), u8(0), u8(0), u8(0), u8(16), u8(0), u8(0), u8(0), u8(0),
		u8(0), u8(0), u8(0), u8(0)]
	mut cmap13 := [u8(0), u8(0), u8(0), u8(1), u8(0), u8(3), u8(0), u8(1), u8(0), u8(0), u8(0),
		u8(12)]
	cmap13 << f13
	textfont_parsed_refusal(['cmap', 'maxp'], [cmap13, maxp10], 'cmap')
}

fn test_textfont_parsed_f0() {
	// Format 0 has no corpus carrier, so a synthetic cmap covers it: the
	// block is emitted and round-trips byte-identically.
	mut glyphs := []u8{cap: 512}
	for i in 0 .. 256 {
		glyphs << u8((i >> 8) & 0xff)
		glyphs << u8(i & 0xff)
	}
	mut sub := [u8(0), u8(0), u8(2), u8(6), u8(0), u8(0)]
	sub << glyphs
	mut cmap := [u8(0), u8(0), u8(0), u8(1), u8(0), u8(0), u8(0), u8(0), u8(0), u8(0), u8(0), u8(12)]
	cmap << sub
	f := textfont_synth(['cmap', 'maxp'], [cmap, [u8(0), u8(1), u8(0), u8(0), u8(0), u8(2), u8(0),
		u8(0), u8(0), u8(0)]])
	text := font.textfont_dump(f) or { panic('synth f0 dump refused: ${err}') }
	assert textfont_has_block(text, 'cmap'), 'synth f0 got no cmap block'
	rebuilt := font.textfont_load(text) or { panic('synth f0 load refused: ${err}') }
	assert rebuilt == f, 'synth f0 round-trip is not byte-symmetric'
	// And a parsed-only flip refuses, proving the block is load-bearing.
	bad := textfont_set_field(text, 'cmap', 'language', '7')
	if _ := font.textfont_load(bad) {
		assert false, 'disagreeing synth cmap loaded without error'
	}
}
