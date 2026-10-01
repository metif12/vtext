module vtext

// The two tables under GPOS lookup type 1: a single positioning, which moves one glyph on its own, and
// a cursive attachment, which says where a glyph's stroke enters and leaves. They share a number, both
// declare format 1, and both write a coverage at the same place, so a reader has to tell them apart
// from the bytes or it will read one as the other.
//
// No font on this machine has a cursive attachment, so these build the two tables by hand. That is the
// point: the ambiguity is only visible in bytes, and a font that happens to have one is not available
// to test the refusal with.
//
// Every field in all of these is sixteen bits, so each table is written as the words a hex dump would
// show and converted once. Writing them this way keeps the layout next to the offsets that depend on it.

// bytes_of turns a list of sixteen bit words into the bytes a font stores.
fn bytes_of(words []i16) []u8 {
	mut b := []u8{len: words.len * 2}
	for i, w in words {
		b[i * 2] = u8((w >> 8) & 0xff)
		b[i * 2 + 1] = u8(w & 0xff)
	}
	return b
}

// single_pos_bytes builds a SinglePos format 1 subtable covering one glyph, in the shape Andalus's
// lookup 21 has: a valueFormat of 3 at the word a cursive reader takes for its first anchor offset, and
// something else small at the word it takes for its second, so one of the two lands on a valid anchor
// format and the other points backwards. That is enough to be mistaken for a cursive rule.
//
// The values come first, at +6, and the coverage is stored after them at +10. A coverage at +6 would be
// read as the values, which is worth knowing because the two tables share a layout that only looks
// shared until the offsets are counted.
fn single_pos_bytes() []u8 {
	return bytes_of([
		1,
		10, // posFormat, coverage offset
		3, // valueFormat: xPlacement and xAdvance
		-120,
		-120, // the values, at +6 and +8
		1,
		1,
		3, // coverage format 1, one glyph, glyph 3, at +10
	])
}

// cursive_format1_bytes builds a CursivePos format 1 subtable covering one glyph whose entry anchor is
// at (0, 23) and which has no exit anchor at all.
//
// Format 1 writes one record per covered glyph with no count, so the records sit directly after the
// header and the coverage follows them, which is why the anchor offset is 14 rather than the 8 the
// coverage starts at.
fn cursive_format1_bytes() []u8 {
	return bytes_of([
		1,
		8, // posFormat, coverage offset
		14,
		0, // entry anchor, no exit anchor
		1,
		1,
		3, // coverage format 1, one glyph, glyph 3
		1,
		0,
		23, // anchor format 1, x, y
	])
}

// cursive_format2_bytes builds a CursivePos format 2 subtable covering one glyph whose exit anchor is at
// (95, 77) and which has no entry anchor. Format 2 writes a count first, so its records start two bytes
// later than format 1's.
fn cursive_format2_bytes() []u8 {
	return bytes_of([
		2,
		10, // posFormat, coverage offset
		1, // entryExitCount
		0,
		16, // no entry anchor, exit anchor
		1,
		1,
		3, // coverage format 1, one glyph, glyph 3
		1,
		95,
		77, // anchor format 1, x, y
	])
}

// cursive_range_bytes builds a CursivePos format 1 subtable whose coverage is written as one range from
// glyph 10 to glyph 11, so it covers two glyphs and has two records: the first has an entry anchor, the
// second an exit anchor.
//
// The range is written start, end, index. Tahoma's own mark coverage confirms the order with three
// words that only make sense that way: 753, 760, 0 is the range uni064B to uni0652 starting at coverage
// index 0, where reading the index first would put a range from 760 back to 0.
fn cursive_range_bytes() []u8 {
	return bytes_of([
		1,
		16, // posFormat, coverage offset
		26,
		0, // glyph 10: entry anchor, no exit
		0,
		32, // glyph 11: no entry, exit anchor
		0,
		0,
		// The coverage sits between the records and the anchors here, which is legal and is why the
		// anchor offsets are not simply the record's own position plus four.
		2,
		1,
		10,
		11,
		0, // coverage format 2, one range, glyphs 10 to 11, from index 0
		1,
		0,
		40, // anchor format 1, x, y
		1,
		0,
		-5,
	])
}

// The first guard has to hold: a value record read as an anchor offset has to be refused, or every
// single positioning in a font is read as a cursive rule and the kerning rules built on them vanish.
//
// It is a real failure and not a theoretical one. Reading anchors first and falling back to values when
// there are none took Andalus's lookup 21 out of the font and failed the kerning tests, because its
// valueFormat of 3 is a valid anchor format and the offset it makes lands inside the subtable.
fn test_gpos_cursive_reader_refuses_a_single_position() {
	r := new_reader(single_pos_bytes())
	assert parse_cursive(r, 0) == none, 'a value format is not an anchor offset'
	// The same bytes still have to read as the positioning rule they are.
	rule := parse_single_position(r, 0) or { panic('a single positioning is not a cursive rule') }
	assert rule.ranges.len == 1, 'and it covers the one glyph'
	got := rule.offset_for(3) or { panic('no value for the glyph') }
	assert got.x == -120, 'and it moves it by the font number'
}

// A cursive rule is one record per covered glyph with no count, and its offsets point past the records
// to anchors that declare themselves anchors.
fn test_gpos_cursive_reader_reads_format_one() {
	r := new_reader(cursive_format1_bytes())
	rule := parse_cursive(r, 0) or { panic('a cursive rule with an anchor was refused') }
	assert rule.format == 1, 'and it says which format it is'
	got := rule.offset_for(3) or { panic('no anchors for the covered glyph') }
	assert got.entry.exists, 'the entry anchor is there'
	assert got.entry.y == 23, 'at the height the bytes say'
	assert !got.exit.exists, 'and an absent exit anchor stays absent rather than becoming a zero'
}

// Format 2 writes the count first, so its records start two bytes later.
fn test_gpos_cursive_reader_reads_format_two() {
	r := new_reader(cursive_format2_bytes())
	rule := parse_cursive(r, 0) or { panic('a cursive rule with an exit anchor was refused') }
	assert rule.format == 2, 'and it says which format it is'
	got := rule.offset_for(3) or { panic('no anchors for the covered glyph') }
	assert got.exit.exists, 'the exit anchor is there'
	assert got.exit.x == 95 && got.exit.y == 77, 'at the point the bytes say'
	assert !got.entry.exists, 'and an absent entry anchor stays absent'
}

// A coverage can be written as ranges, and a glyph per range is still a glyph with a record. Reading the
// number of ranges as the number of records leaves most of the coverage unanchored.
fn test_gpos_cursive_reader_counts_the_coverage_in_glyphs() {
	r := new_reader(cursive_range_bytes())
	rule := parse_cursive(r, 0) or { panic('a rule covering a range was refused') }
	assert rule.marks.len == 2, 'a range of two glyphs has two records'
	first := rule.offset_for(10) or { panic('the first glyph of the range has no anchors') }
	assert first.entry.exists && first.entry.y == 40, 'the first glyph has the entry anchor'
	second := rule.offset_for(11) or { panic('the second glyph of the range has no anchors') }
	assert second.exit.exists && second.exit.y == -5, 'and the second has the exit one'
	assert !second.entry.exists, 'a record only says what it says'
}

// Dubai is the one font here with a curs feature, and it is worth knowing what that feature really is,
// because fontTools calls the subtable a CursivePos and the bytes say otherwise. The extension header
// names type 3, so it places marks on a base glyph. Read by shape alone, its mark array and base array
// offsets happen to land on something shaped like an anchor, which is how a mark attachment table comes
// to look like a cursive one.
fn test_gpos_dubai_curs_feature_places_marks_rather_than_joining_strokes() {
	f := load_font_file('C:\\Windows\\Fonts\\DUBAI-REGULAR.TTF') or { panic(err) }
	gpos := f.face.gpos or { panic('no GPOS') }
	mut cursive := 0
	for script in ['arab', 'latn'] {
		for li in gpos.lookups_for(script, 'curs') {
			if int(li) < gpos.lookups.len && gpos.lookups[li].cursives.len > 0 {
				cursive++
			}
		}
	}
	assert cursive == 0, 'the lookup the curs feature names is a mark attachment, not a cursive rule'
	assert gpos.has_mark_attachment(), 'and the marks are placed, which is what that lookup is for'
}
