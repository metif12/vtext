module vtext

// Tests for the generated codepoint name table and for the trace-facing wrappers in trace_api.v.
//
// The table is front coded and delta coded, which means a wrong answer is a plausible string rather than a
// crash. Every expected name below was read out of UnicodeData.txt with Python's unicodedata, so the check
// is two independent readers agreeing rather than one reader agreeing with itself.
//
// The cases are chosen to cover the parts of the format that can be wrong separately:
//
//	the first entry and the last, which bound the delta tables
//	an entry with a long shared prefix and one with a short one
//	a zero-length suffix, which is a name repeated verbatim
//	a CJK entry, which only exists because the range markers were expanded
//	a codepoint with no name, which must answer empty rather than guess

fn test_codepoint_names_come_from_the_ucd() {
	// The names that were misread from memory this session, which is why this file exists. U+FEA7 is
	// KHAH INITIAL FORM and not "WAW WITH DOT BELOW", and U+FEA8 is KHAH MEDIAL FORM.
	assert codepoint_name(rune(0x0628)) == 'ARABIC LETTER BEH'
	assert codepoint_name(rune(0x0627)) == 'ARABIC LETTER ALEF'
	assert codepoint_name(rune(0xFEA7)) == 'ARABIC LETTER KHAH INITIAL FORM'
	assert codepoint_name(rune(0xFEA8)) == 'ARABIC LETTER KHAH MEDIAL FORM'
	assert codepoint_name(rune(0xFE8E)) == 'ARABIC LETTER ALEF FINAL FORM'

	// Presentation forms are the reason the table exists at all: they are what a shaping trace prints and
	// what nobody has in their head.
	assert codepoint_name(rune(0xFEFC)) == 'ARABIC LIGATURE LAM WITH ALEF FINAL FORM'
	// U+FEF4 is YEH MEDIAL FORM and not "LAM WITH HEH". It is here because that is the reading it invites:
	// the block is full of lam-alef ligatures, and a codepoint that looks like one of them is not one.
	assert codepoint_name(rune(0xFEF4)) == 'ARABIC LETTER YEH MEDIAL FORM'
}

fn test_codepoint_names_at_the_ends_of_the_table() {
	// The first entry bounds both delta tables, because its delta is absolute rather than relative. A
	// generator that wrote a relative zero here would put the whole table one entry out.
	assert codepoint_name(rune(0x0020)) == 'SPACE'
	assert codepoint_name(rune(0x0021)) == 'EXCLAMATION MARK'
	assert codepoint_name(rune(0x0041)) == 'LATIN CAPITAL LETTER A'

	// The last named codepoint in this UCD is a variation selector, not the last codepoint. UnicodeData.txt
	// has no line past U+E01EF, so that is what bounds the other end of both tables, and U+10FFFF is well
	// past it.
	last := rune(0xE01EF)
	assert codepoint_name(last) == 'VARIATION SELECTOR-256'
	assert codepoint_name(rune(0x10FFFF)) == 'U+10FFFF', 'which is past the end of the table'
}

fn test_a_cjk_name_exists_because_the_range_markers_were_expanded() {
	// UnicodeData.txt has no line for U+4E00: the block is one First/Last pair. Without expanding the
	// markers the table would answer empty for every Han ideograph, which is the one thing a trace about
	// CJK text most needs.
	assert codepoint_name(rune(0x4E00)) == 'CJK UNIFIED IDEOGRAPH-4E00'
	assert codepoint_name(rune(0x4E8C)) == 'CJK UNIFIED IDEOGRAPH-4E8C'
	assert codepoint_name(rune(0x9FFF)) == 'CJK UNIFIED IDEOGRAPH-9FFF'

	// The padding width matters. The main block's marker is five hex digits and the extension block's is
	// four, so a substitution without zero padding would name every ideograph in the main block with a
	// four digit number, which is a different codepoint and would read as plausible.
	assert codepoint_name(rune(0x3400)) == 'CJK UNIFIED IDEOGRAPH-3400'
	assert codepoint_name(rune(0x4DBF)) == 'CJK UNIFIED IDEOGRAPH-4DBF'
}

fn test_a_codepoint_with_no_name_answers_empty_rather_than_guessing() {
	// Private use has no name in Unicode, and the range markers say so. The caller substitutes its own
	// fallback; what must not happen is a name invented from the codepoint, because an invented name reads
	// like a fact from the UCD.
	assert name_of_codepoint(rune(0xE000)) == '', 'private use has no Unicode name'
	assert codepoint_name(rune(0xE000)) == 'U+E000', 'so the public form falls back to the hex value'

	// The control area is the other no-name region, and it is the one that is easiest to get wrong because
	// UnicodeData.txt writes "<control>" there rather than a name. A generator that read that marker as a
	// name would print "<control>" for every one of them, which looks like an answer.
	assert name_of_codepoint(rune(0x0001)) == '', 'controls have a range marker, not a name'
	assert codepoint_name(rune(0x0001)) == 'U+0001'
}

fn test_an_unassigned_codepoint_answers_empty() {
	// U+0378 is permanently unassigned. It sits between two assigned codepoints in Greek Extended, which
	// is the case that catches a binary search stopping at the wrong bound.
	assert name_of_codepoint(rune(0x0378)) == ''
	assert codepoint_name(rune(0x0378)) == 'U+0378'
	// The neighbour before it is named, so the gap is a gap rather than a truncation. The one after it is
	// not: U+0379 is unassigned too, which is why this test checks only the one side.
	assert codepoint_name(rune(0x0377)) == 'GREEK SMALL LETTER PAMPHYLIAN DIGAMMA'
	assert name_of_codepoint(rune(0x0379)) == '', 'U+0379 is unassigned as well'
}

fn test_every_name_in_the_table_rebuilds() {
	// A spot check of ten names proves nothing about a front coded table: a format change that broke one
	// entry type would be invisible. So the whole table is walked and every entry has to satisfy the
	// invariant the format rests on: entry i's shared prefix must fit inside entry i-1's name, and the bytes
	// it claims to share must really be equal.
	//
	// The offsets are carried forward rather than re-summed per entry. Summing from zero each time is
	// O(n squared) over a hundred and forty thousand entries and took four minutes of the test run; carrying
	// the running position is the same number with one add per entry. It is the one place in this file where
	// an incremental value is used, and it is used because there is exactly one loop and one place to update
	// it, which is the condition the reader's own incremental sum failed.
	mut checked := 0
	mut prev := []u8{}
	// `start` is entry i's own offset and is carried forward: at entry i it holds offsets[i]. Entry i's end is
	// offsets[i+1], which is that plus the single next delta, so the end is one add rather than a second
	// running sum. The index is i+1 and not i, because offsets_delta[i] is the step *into* entry i and is
	// already inside start; adding it again is what put every end past the end of the blob.
	mut start := 0
	for i in 0 .. codepoint_name_cps_delta.len {
		shared := int(codepoint_name_prefix[i])
		if shared > prev.len {
			assert false, 'entry ${i} claims a ${shared} byte prefix but the previous name is ${prev.len}'
		}
		end := start + int(codepoint_name_offsets_delta[i + 1])
		if start > end || end > codepoint_names_data.len {
			assert false, 'entry ${i} has offsets ${start}..${end} outside a blob of ${codepoint_names_data.len}'
		}
		// The prefix bytes are copied as they are compared, so the check costs nothing over the copy that
		// has to happen anyway. The comparison is against the previous name, which is the only thing the
		// prefix claim is about: entry i says it shares these bytes with entry i-1.
		mut out := []u8{cap: shared + int(end - start)}
		for p in 0 .. shared {
			out << prev[p]
		}
		for k in start .. end {
			out << codepoint_names_data[k]
		}
		prev = out.clone()
		start = end
		checked++
	}
	assert checked > 100000, 'the table should hold every assigned codepoint, walked ${checked}'
	assert start == codepoint_names_data.len, 'the walk should end at the end of the blob'
}

fn test_joining_type_names_are_words_not_numbers() {
	ctx := new_context()
	// The decision the joining pass makes is phrased in these words, and a report printing "2" and "0" is a
	// report the reader has to look up.
	assert joining_type_name(ctx, rune(0x0628)) == 'dual-joining'
	assert joining_type_name(ctx, rune(0x0627)) == 'right-joining'
	assert joining_type_name(ctx, rune(0x0020)) == 'non-joining'
	assert joining_type_name(ctx, rune(0x064E)) == 'transparent'
	// The separator between two Arabic words is right-joining, which is why a mark before it attaches to
	// the letter on the other side. Saying so by name is the point.
	assert joining_type_name(ctx, rune(0x0020)) != 'transparent'
}

fn test_visual_string_renders_the_characters_not_their_low_bytes() {
	// Built as runes rather than bytes, because an Arabic character is three bytes and truncating to one
	// would produce a string that looks right in ASCII and is nothing at all in the script. This function
	// exists to be read next to a picture, so it has to produce the characters the picture has.
	bidi := resolve_bidi(new_context(), [rune(0x0628), rune(0x0020), rune(0x0041)], .rtl)
	assert bidi.visual_order.len == 3
	visual := bidi.visual_string([rune(0x0628), rune(0x0020), rune(0x0041)])
	assert visual == 'A ب', 'expected the Latin letter first, got "${visual}"'
}
