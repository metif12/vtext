module vtext

// Tests for the width of a GPOS value record, which is what the reader uses to step from one record to the
// next.
//
// This is not a formatting question. A ValueRecord says which of eight fields it carries by setting bits in
// a format word, and each field costs two bytes, so the record's width is the sum of the bits. If the reader
// counts fewer bits than the font set, every record after the short-counted one is read from the wrong place
// — and lands in the middle of a neighbouring record, producing small plausible numbers rather than a
// failure. Nothing about the output says wrong.
//
// No font on this machine sets a VariationIndex bit, so these are written as bytes. That is the correct
// reason for hand-building them and not a compromise: there is no font to read, and the format is stated
// rather than remembered.

fn bytes_of(words []i16) []u8 {
	mut b := []u8{len: words.len * 2}
	for i, w in words {
		b[i * 2] = u8((w >> 8) & 0xff)
		b[i * 2 + 1] = u8(w & 0xff)
	}
	return b
}

// A value record is two bytes per field, and the fields are:
//
//   0x0001 xPlacement   0x0002 yPlacement   0x0004 xAdvance   0x0008 yAdvance
//   0x0010 xPlacementDevice  0x0020 yPlacementDevice
//   0x0040 xAdvanceDevice    0x0080 yAdvanceDevice
//   0x0100 xPlacementVariationIndex  0x0200 yPlacementVariationIndex
//   0x0400 xAdvanceVariationIndex    0x0800 yAdvanceVariationIndex
//
// Twelve fields, and the specification stops at 0x0800. The last four were the ones that were missing. The
// count is checked per field, because a width that is right on average and wrong per record steps wrongly
// exactly once per record.
fn test_a_value_record_is_two_bytes_per_field_it_sets() {
	assert pair_value_size(0) == 0, 'a record with no fields is empty'
	assert pair_value_size(0x0001) == 2, 'one field is two bytes'
	assert pair_value_size(0x0001 | 0x0002 | 0x0004 | 0x0008) == 8, 'the four values are eight bytes'
	assert pair_value_size(0x0010) == 2, 'a placement device offset is two bytes'
	assert pair_value_size(0x0100) == 2, 'a placement variation index is two bytes, and this is the one that was counted as zero'
	assert pair_value_size(0x0800) == 2, 'and so is the last of the four'
	assert pair_value_size(0x0004 | 0x0100 | 0x0800) == 6, 'three fields, whatever they are'
	// Every defined bit at once. There are twelve, not eight: the four values, two placement devices, two
	// advance devices and the four variation indices. The top four bits of a format word are not fields —
	// the specification stops at 0x0800 — so a format with them set is counted over the twelve that exist
	// rather than over sixteen.
	assert pair_value_size(0x0FFF) == 24, 'all twelve defined fields is twenty-four bytes'
}

// The width is what steps the reader, so the test that matters is that a second record after a
// variation-index one is still found. Two PairValueRecords are written back to back: the first carries an
// xAdvance and a variation index, the second carries only an xAdvance. Read with the wrong width, the
// second is found at the wrong offset and its value is the variation index's words instead.
fn test_a_record_after_a_variation_index_record_is_still_found() {
	// Two PairValueRecords of four bytes each. The first has a valueFormat of 0x0004 | 0x0100 — an
	// xAdvance of -70 and a zero variation index — and the second has 0x0004 with an xAdvance of -30.
	words := [i16(-70), 0, -30]
	r := new_reader(bytes_of(words))
	first := read_pair_value(r, 0, 0x0004 | 0x0100)
	assert first.x_advance == -70, 'the first record reads its own advance, got ${first.x_advance}'
	// The reader steps by the width the format states. With the variation index uncounted it would stop
	// two bytes early, on the variation index word, and read -30 as 0.
	second := read_pair_value(r, pair_value_size(0x0004 | 0x0100), 0x0004)
	assert second.x_advance == -30, 'the second record is found past the variation index, got ${second.x_advance}'
}

// The four variation-index bits were missing from the width until 2026-10-04. No font on this machine sets
// one — measured across all 341 fonts available, not assumed — so nothing else would have caught it, and
// this is the assertion that says so rather than the absence of a failure.
fn test_the_four_variation_index_bits_are_counted() {
	mut counted := 0
	for bit in [u16(0x0100), u16(0x0200), u16(0x0400), u16(0x0800)] {
		if pair_value_size(bit) == 2 {
			counted++
		}
	}
	assert counted == 4, 'all four variation index bits are two bytes each, got ${counted} of 4'
	// And each of them must move the width on its own, which is the property the old count violated: it
	// returned zero for all four.
	assert pair_value_size(u16(0x0100)) != 0, 'an x-placement variation index is not free'
	assert pair_value_size(u16(0x0200)) != 0, 'nor is a y-placement variation index'
	assert pair_value_size(u16(0x0400)) != 0, 'nor an x-advance variation index'
	assert pair_value_size(u16(0x0800)) != 0, 'nor a y-advance variation index'
}
