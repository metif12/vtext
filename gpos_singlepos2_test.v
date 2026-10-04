module vtext

// GPOS SinglePos format 2: one value for a whole coverage and a run of exceptions.
//
// Format 1 has one value per covered glyph and format 2 has one value for all of them plus a list of
// glyphs that want something else, named by *coverage index* rather than by glyph id. That last part is
// why the two cannot be read as each other, and it is the failure the roadmap predicted: reading format
// 2 as format 1 takes its valueCount as the number of per-glyph values and then reads the exception
// list's indices as records.
//
// No font on this machine uses format 2, so the subtables here are built as bytes. That is not a
// shortcut, it is the only way to test a format nothing here has: the alternative is a parser that is
// correct on the specification and never executed.

import os

// bytes_of builds a big-endian byte array from 16-bit words, which is how every table in this file is
// written: a font is a sequence of 16-bit values with the occasional 8-bit count in the middle of one,
// and spelling them as words keeps the offsets in the comments checkable by eye.
fn bytes_of(words []i16) []u8 {
	mut b := []u8{len: words.len * 2}
	for i, w in words {
		b[i * 2] = u8((w >> 8) & 0xff)
		b[i * 2 + 1] = u8(w & 0xff)
	}
	return b
}

fn sp2_font() &Font {
	path := os.join_path('C:\\Windows\\Fonts', 'segoeui.ttf')
	return load_font_file(path) or { panic(err) }
}

// single_pos_format2_bytes builds a format 2 subtable over three glyphs.
//
//	valueFormat is 1, which is xPlacement only, so every value is one 16-bit number.
//
//	 0  posFormat = 2
//	 2  coverageOffset = 16
//	 4  valueFormat = 1
//	 6  valueCount = 1
//	 8  value1 = 100          the value every covered glyph gets
//	10  glyphCount = 1
//	12  glyphs[0] = 3         coverage index 3, which is glyph 13
//	14  value = -40           and glyph 13 gets this instead
//	16  the coverage, format 2: one range, glyphs 10 to 13, from coverage index 0
//
// The coverage is format 2 over glyphs 10 to 13, so coverage index 2 is glyph 12 and index 3 is glyph
// 13. That distinction is the whole point: naming glyph 12 here would put the exception on a glyph that
// has none, and a reader that treated the numbers as glyph ids would put it on the right one by
// accident, which is why this file asserts both directions.
fn single_pos_format2_bytes() []u8 {
	return bytes_of([
		2,
		16, // posFormat, coverage offset
		1, // valueFormat: xPlacement
		1, // valueCount
		100, // the shared value
		1,
		3, // one exception, naming coverage index 3
		-40, // and its own value
		2,
		1,
		10,
		13,
		0, // coverage format 2: glyphs 10 to 13, from coverage index 0
	])
}

// The shared value applies to every covered glyph that no exception names.
fn test_single_pos_format_2_gives_every_glyph_the_same_value() {
	r := new_reader(single_pos_format2_bytes())
	rule := parse_single_position(r, ResolvedSubtable{
		kind: gpos_lookup_single_position
		at:   0
	}) or { panic('a format 2 single positioning did not parse') }

	assert rule.ranges.len > 0, 'the coverage should have been read'
	for gid in [u16(10), 11, 12] {
		off := rule.offset_for(gid) or { panic('glyph ${gid} should take the shared value') }
		assert off.x == 100, 'glyph ${gid} should move by 100, got ${off.x}'
		assert off.y == 0, 'and only horizontally'
	}
}

// An exception overrides the shared value, and it is keyed by coverage index rather than by glyph id.
fn test_single_pos_format_2_an_exception_overrides_the_shared_value() {
	r := new_reader(single_pos_format2_bytes())
	rule := parse_single_position(r, ResolvedSubtable{
		kind: gpos_lookup_single_position
		at:   0
	}) or { panic('a format 2 single positioning did not parse') }

	// Coverage index 3 of glyphs 10..13 is glyph 13, and that is the one the exception names.
	off := rule.offset_for(13) or { panic('glyph 13 should have the exception value') }
	assert off.x == -40, 'the exception should win over the shared 100, got ${off.x}'

	// And glyph 12, which is coverage index 2, must be untouched. This is the assertion that would
	// fail if the exception's number were read as a glyph id rather than an index: 2 is not a glyph in
	// this coverage at all, so treating it as one puts the exception nowhere or on glyph 2.
	other := rule.offset_for(12) or { panic('glyph 12 should still take the shared value') }
	assert other.x == 100, 'glyph 12 is not the exception, it should still be 100, got ${other.x}'
}

// A glyph outside the coverage is not covered by the shared value either. The value belongs to the
// coverage, not to the lookup.
fn test_single_pos_format_2_leaves_an_uncovered_glyph_alone() {
	r := new_reader(single_pos_format2_bytes())
	rule := parse_single_position(r, ResolvedSubtable{
		kind: gpos_lookup_single_position
		at:   0
	}) or { panic('a format 2 single positioning did not parse') }
	assert rule.offset_for(9) == none, 'glyph 9 is not covered'
	assert rule.offset_for(14) == none, 'and neither is glyph 14'
}

// valueCount must be 1. Anything else means the reader does not know where the exceptions begin, and
// guessing is what this format is famous for.
fn test_single_pos_format_2_refuses_a_value_count_it_does_not_know() {
	// The same table with valueCount of 2, which the specification does not allow.
	bad := bytes_of([
		2,
		16, // posFormat, coverage offset
		1, // valueFormat
		2, // valueCount, which must be 1
		100,
		0, // a second value the reader has no rule for
		1,
		3,
		-40,
		2,
		1,
		10,
		13,
		0, // the coverage, format 2
	])
	r := new_reader(bad)
	assert parse_single_position(r, ResolvedSubtable{
		kind: gpos_lookup_single_position
		at:   0
	}) == none, 'a valueCount of 2 should be refused rather than guessed at'
}

// The exception list runs to the end of the subtable, and a subtable reached directly has no length to
// run to. What stops the scan instead is that an exception names coverage indices, so it cannot name
// more glyphs than the coverage covers. Without that bound the scan walks into whatever follows and
// reads it as exceptions.
//
// The record below names four indices into a **two** glyph coverage, and every one of them is a valid
// index — 0, 1, 0, 1. That is deliberate: it makes the count the only thing wrong with the record, so
// this test pins the count check and not the index check beside it. A record with an out-of-range
// index would be refused by either, and a test using one would pass with the count check removed.
fn test_single_pos_format_2_stops_at_a_record_larger_than_the_coverage() {
	words := [
		i16(2),
		i16(24), // posFormat, coverage offset, which is twelve words in
		i16(1), // valueFormat
		i16(1), // valueCount
		i16(100), // the shared value
		i16(4), // glyphCount, which cannot fit a two glyph coverage
		i16(0),
		i16(1),
		i16(0),
		i16(1), // four indices, every one of them valid
		i16(-40),
		i16(-41), // and values that must not be read
		i16(2),
		i16(1),
		i16(7),
		i16(8),
		i16(0), // coverage format 2: glyphs 7 and 8
	]
	r := new_reader(bytes_of(words))
	rule := parse_single_position(r, ResolvedSubtable{
		kind: gpos_lookup_single_position
		at:   0
	}) or { panic('the table up to the bad record should still parse') }

	assert rule.overrides.len == 0, 'the oversized record should not have been read, got ${rule.overrides.len} exceptions'
	// And the glyphs the coverage does name still get the shared value, because what is refused is the
	// record rather than the table.
	for gid in [u16(7), 8] {
		off := rule.offset_for(gid) or { panic('glyph ${gid} should take the shared value') }
		assert off.x == 100, 'glyph ${gid} got ${off.x}'
	}
}

// Format 1 and format 2 answer the same question and neither may be read as the other. This is the
// whole reason the parser branches on the format before reading anything else.
fn test_single_pos_format_1_still_reads_as_format_1() {
	// A coverage of one glyph and one value, in format 1's shape: no count of values at all.
	r := new_reader(bytes_of([
		i16(1),
		i16(10), // posFormat, coverage offset
		i16(1), // valueFormat
		i16(-120), // the value, straight after the format that says how wide it is
		i16(2),
		i16(1),
		i16(1),
		i16(7), // coverage format 1, glyph 7
	]))
	rule := parse_single_position(r, ResolvedSubtable{
		kind: gpos_lookup_single_position
		at:   0
	}) or { panic('a format 1 single positioning did not parse') }
	off := rule.offset_for(7) or { panic('no value for glyph 7') }
	assert off.x == -120, 'got ${off.x}'
	// A format 1 rule has no shared value, and saying so is what tells offset_for which of the two
	// lookups to make.
	assert rule.base == none, 'format 1 has no single value for the coverage'
	assert rule.values.len == 1, 'it has one value per covered glyph, got ${rule.values.len}'
}

// A real font, to confirm the extension length plumbed through ResolvedSubtable did not change how any
// of the fonts on this machine read. Every positioning rule here is format 1, and every one of them is
// reached through an extension, so this is the regression guard on the length being carried at all.
fn test_real_fonts_still_read_their_single_positionings() {
	f := sp2_font()
	gpos := f.face.gpos or { panic('segoeui has no GPOS') }
	assert gpos.lookups.len > 0, 'there should be lookups'
	mut singles := 0
	for l in gpos.lookups {
		singles += l.singles.len
	}
	assert singles > 0, 'segoeui has single positioning rules, found ${singles}'
}
