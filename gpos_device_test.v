module vtext

import vtext.font
// Tests for the Device table reader: the size-dependent pixel adjustment a GPOS value may carry.
//
// No font measured carries one — zero Device tables across 2,450,058 value records on 379 faces —
// so these are written as bytes, the way the value-size tests are and for the same reason. The
// specification's own example pins the packing order: four 4-bit deltas {1, 2, 3, -1} are the
// single word 0x123F, most-significant first, which is what distinguishes this from an LSB-first
// reader that would answer something else for the same bytes.

fn device_of(words []i16) []u8 {
	mut b := []u8{len: words.len * 2}
	for i, w in words {
		b[i * 2] = u8((w >> 8) & 0xff)
		b[i * 2 + 1] = u8(w & 0xff)
	}
	return b
}

// The specification's example, verbatim: four 4-bit values {1, 2, 3, -1} in one word 0x123F.
fn test_device_reads_the_specification_example() {
	r := font.new_reader(device_of([i16(12), 15, 2, 0x123F]))
	d := read_device(r, 0, r.len()) or { panic('a whole table reads') }
	assert d.start == 12 && d.end == 15 && d.format == 2
	assert d.delta_at(12) == 1, 'first delta, got ${d.delta_at(12)}'
	assert d.delta_at(13) == 2, 'second delta, got ${d.delta_at(13)}'
	assert d.delta_at(14) == 3, 'third delta, got ${d.delta_at(14)}'
	assert d.delta_at(15) == -1, 'fourth delta is negative, got ${d.delta_at(15)}'
	assert d.delta_at(11) == 0, 'below the range is uncorrected'
	assert d.delta_at(16) == 0, 'past the range is uncorrected'
}

// Two-bit deltas pack eight per word, and the negatives pin the sign extension: 0b10 is -2 and
// 0b11 is -1, not 2 and 3. Without the extension {-2, -1, 0, 1} would read {2, 3, 0, 1}, which is
// the break this test re-fails.
fn test_device_reads_two_bit_deltas_with_sign() {
	// start 10, end 13, format 1, then 10 11 00 01 followed by zeros: 0xB100.
	r := font.new_reader(device_of([i16(10), 13, 1, i16(0xB100)]))
	d := read_device(r, 0, r.len()) or { panic('a whole table reads') }
	assert d.delta_at(10) == -2, 'got ${d.delta_at(10)}'
	assert d.delta_at(11) == -1, 'got ${d.delta_at(11)}'
	assert d.delta_at(12) == 0, 'got ${d.delta_at(12)}'
	assert d.delta_at(13) == 1, 'got ${d.delta_at(13)}'
}

// Eight-bit deltas pack two per word: -128 and 127 are 0x80 and 0x7F.
fn test_device_reads_eight_bit_deltas() {
	r := font.new_reader(device_of([i16(9), 10, 3, i16(0x807F)]))
	d := read_device(r, 0, r.len()) or { panic('a whole table reads') }
	assert d.delta_at(9) == -128, 'got ${d.delta_at(9)}'
	assert d.delta_at(10) == 127, 'got ${d.delta_at(10)}'
}

// A table that overruns its bound is read as far as it goes: eleven sizes stated, room for two
// 8-bit deltas, so the third size reads zero rather than refusing the table.
fn test_device_clamps_an_overrunning_table_to_its_bytes() {
	r := font.new_reader(device_of([i16(10), 20, 3, i16(0x0102)]))
	d := read_device(r, 0, r.len()) or { panic('a truncated table still reads') }
	assert d.deltas.len == 2, 'two deltas fit, got ${d.deltas.len}'
	assert d.delta_at(10) == 1 && d.delta_at(11) == 2, 'the bytes present still answer'
	assert d.delta_at(12) == 0, 'past the bytes is uncorrected, not the next table'
}

// What is not a Device table reads as none: a truncated header, an unknown format, a VariationIndex
// (0x8000, which names a delta-set index rather than carrying deltas), and an empty range.
fn test_device_refuses_what_is_not_a_device_table() {
	if _ := read_device(font.new_reader(device_of([i16(10), 12])), 0, 4) {
		assert false, 'four bytes are not a table'
	}
	if _ := read_device(font.new_reader(device_of([i16(10), 12, 0, 0])), 0, 8) {
		assert false, 'format 0 is not a table'
	}
	if _ := read_device(font.new_reader(device_of([i16(10), 12, 4, 0])), 0, 8) {
		assert false, 'format 4 is not a table'
	}
	if _ := read_device(font.new_reader(device_of([i16(0), 0, i16(-32768)])), 0, 6) {
		assert false, 'a VariationIndex is not a Device table'
	}
	if _ := read_device(font.new_reader(device_of([i16(20), 10, 2, 0])), 0, 8) {
		assert false, 'an end before the start is not a table'
	}
}

// The bound is the caller's, not the buffer's: an extension wrapper ends the table where the
// wrapper says, even with bytes after it. Nine sizes stated, room for two, same answer as above.
fn test_device_respects_the_wrapper_bound() {
	words := [i16(10), 20, 3, 0x0102, 0x0304]
	r := font.new_reader(device_of(words))
	d := read_device(r, 0, 8) or { panic('a bounded table reads') }
	assert d.deltas.len == 2, 'the wrapper bound wins over the buffer, got ${d.deltas.len}'
	assert d.delta_at(11) == 2, 'got ${d.delta_at(11)}'
}
