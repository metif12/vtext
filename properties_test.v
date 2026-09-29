module vtext

import os

// The tables come straight from the UCD, so the tests check the lookup against
// codepoints whose property is not in question, plus one full sweep of the
// generated file against the UCD it was derived from.

fn props() &Properties {
	return new_properties()
}

fn test_bidi_class_of_known_codepoints() {
	p := props()
	assert p.bidi_class_of(`A`) == .l
	assert p.bidi_class_of(`1`) == .en
	assert p.bidi_class_of(`+`) == .es
	assert p.bidi_class_of(rune(0x05D0)) == .r // HEBREW ALEF
	assert p.bidi_class_of(rune(0x0627)) == .al // ARABIC ALEF
	assert p.bidi_class_of(rune(0x0644)) == .al // ARABIC LAM
	assert p.bidi_class_of(rune(0x200F)) == .r // RLM
	assert p.bidi_class_of(rune(0x200E)) == .l // LRM
	assert p.bidi_class_of(rune(0x200C)) == .bn // ZWNJ
	assert p.bidi_class_of(rune(0x0660)) == .an // ARABIC-INDIC DIGIT ZERO
	assert p.bidi_class_of(` `) == .ws
	assert p.bidi_class_of(rune(0x0023)) == .et
}

fn test_bidi_class_str_round_trip() {
	p := props()
	assert BidiClass.al.str() == 'AL'
	assert BidiClass.l.str() == 'L'
	assert p.bidi_class_name(rune(0x0627)) == 'AL'
}

fn test_joining_type_of_known_codepoints() {
	p := props()
	assert p.joining_type_of(rune(0x0628)) == .d // BEH, dual
	assert p.joining_type_of(rune(0x0627)) == .r // ALEF, right
	assert p.joining_type_of(rune(0x0644)) == .d // LAM, dual
	assert p.joining_type_of(rune(0x0640)) == .c // TATWEEL, join causing
	assert p.joining_type_of(rune(0x200D)) == .c // ZWJ, join causing
	assert p.joining_type_of(rune(0x0651)) == .t // SHADDA, transparent
	assert p.joining_type_of(`A`) == .u // not a joining letter
}

fn test_joining_type_predicates() {
	assert JoiningType.d.joins_to_previous()
	assert JoiningType.d.joins_to_next()
	assert JoiningType.r.joins_to_next()
	assert !JoiningType.r.joins_to_previous()
	assert JoiningType.l.joins_to_previous()
	assert !JoiningType.l.joins_to_next()
	assert JoiningType.t.is_transparent()
	assert !JoiningType.d.is_transparent()
}

fn test_joining_group_covers_arabic_letters() {
	// Persian relies on the LAM and ALEF groups for the lam-alef ligature, and
	// every Arabic letter must land in some group so joining can compare them.
	p := props()
	lam := p.joining_group_name(rune(0x0644))
	alef := p.joining_group_name(rune(0x0627))
	assert lam != '', 'LAM has no joining group'
	assert alef != '', 'ALEF has no joining group'
	assert lam != alef, 'LAM and ALEF must be in different groups'
	beh := p.joining_group_name(rune(0x0628))
	assert beh != ''
	assert beh != lam
}

fn test_combining_class_of_known_codepoints() {
	p := props()
	assert p.combining_class_of(`A`) == 0
	assert p.combining_class_of(rune(0x0300)) == 230 // COMBINING GRAVE ACCENT
	assert p.combining_class_of(rune(0x064E)) == 30 // ARABIC FATHA
	assert p.combining_class_of(rune(0x0654)) == 230 // ARABIC HAMZA ABOVE
	// The UCD orders marks by class, so a table read from the wrong column or
	// shifted by one would break this ordering.
	assert p.combining_class_of(rune(0x0300)) > p.combining_class_of(rune(0x0316))
	assert p.combining_class_of(rune(0x0316)) == 220 // COMBINING GRAVE ACCENT BELOW
}

fn test_script_of_known_codepoints() {
	p := props()
	assert p.script_tag_of(`A`) == 'Latn'
	assert p.script_tag_of(rune(0x0628)) == 'Arab'
	assert p.script_tag_of(rune(0x05D0)) == 'Hebr'
	assert p.script_tag_of(rune(0x4E2D)) == 'Hani'
	assert p.script_tag_of(rune(0x0300)) == 'Zinh' // inherited
	assert p.is_arabic_script(rune(0x0628))
	assert !p.is_arabic_script(`A`)
}

fn test_grapheme_class_of_known_codepoints() {
	p := props()
	assert p.grapheme_class_of(`A`) == .other
	assert p.grapheme_class_of(rune(0x200D)) == .zwj
	assert p.grapheme_class_of(rune(0x0300)) == .extend
	assert p.grapheme_class_of(`\r`) == .cr
	assert p.grapheme_class_of(`\n`) == .lf
}

fn test_line_break_of_known_codepoints() {
	p := props()
	assert p.line_break_of(`A`) == .al
	assert p.line_break_of(` `) == .sp
	assert p.line_break_of(`-`) == .hy
	assert p.line_break_of(rune(0x200D)) == .zwj
	assert p.line_break_name(`A`) == 'AL'
}

fn test_lookup_range_handles_edges() {
	ranges := [
		CodeRange{ lo: 0x10, hi: 0x1f, value: 5 }
		CodeRange{ lo: 0x30, hi: 0x3f, value: 7 },
	]
	assert lookup_range(ranges, 0x00, 0) == 0
	assert lookup_range(ranges, 0x0f, 0) == 0
	assert lookup_range(ranges, 0x10, 0) == 5
	assert lookup_range(ranges, 0x1f, 0) == 5
	assert lookup_range(ranges, 0x20, 0) == 0
	assert lookup_range(ranges, 0x30, 0) == 7
	assert lookup_range(ranges, 0x3f, 0) == 7
	assert lookup_range(ranges, 0x40, 0) == 0
	assert lookup_range(ranges, 0x7fffffff, 0) == 0
}

fn test_parse_ranges_round_trip() {
	got := parse_ranges('0041 005a 0\n0061 007a 3\n')
	assert got.len == 2
	assert got[0].lo == 0x41 && got[0].hi == 0x5a && got[0].value == 0
	assert got[1].lo == 0x61 && got[1].hi == 0x7a && got[1].value == 3
	// A trailing record without a newline must still be read.
	assert parse_ranges('0007 0007 1').len == 1
	assert parse_ranges('').len == 0
}

fn test_parse_names() {
	assert parse_names('L\nR\nEN\n') == ['L', 'R', 'EN']
	assert parse_names('').len == 0
	// Blank lines are skipped so a trailing newline is harmless.
	assert parse_names('A\n\nB\n').len == 2
}

// test_tables_are_not_trivially_empty guards against a generator run that wrote
// an empty or truncated file: a silently empty table would make every property
// lookup return the default and Persian would render as isolated forms.
fn test_tables_are_not_trivially_empty() {
	p := props()
	assert p.bidi_ranges.len > 500, 'bidi table looks truncated'
	assert p.joining_ranges.len > 200, 'joining table looks truncated'
	assert p.combining_ranges.len > 200, 'combining table looks truncated'
	assert p.script_ranges.len > 500, 'script table looks truncated'
	assert p.grapheme_ranges.len > 500, 'grapheme table looks truncated'
	assert p.linebreak_ranges.len > 1000, 'line break table looks truncated'
	assert_range_sorted(p.bidi_ranges)
	assert_range_sorted(p.joining_ranges)
	assert_range_sorted(p.script_ranges)
	assert_range_sorted(p.linebreak_ranges)
}

fn assert_range_sorted(ranges []CodeRange) {
	mut prev_hi := u32(0)
	for i, r in ranges {
		if i > 0 {
			assert r.lo > prev_hi, 'range ${i} overlaps or is unsorted'
		}
		assert r.hi >= r.lo, 'range ${i} is inverted'
		prev_hi = r.hi
	}
}

// test_value_tables_match_the_enums keeps the hand written enums in step with
// the generated ordinals. Without this, a stale generated file would silently
// return the wrong class and no other test would notice.
fn test_value_tables_match_the_enums() {
	p := props()
	// The bidi and joining enums are checked name by name, because every one of
	// their values is used by the algorithm.
	assert p.bidi_names[int(BidiClass.l)] == 'L'
	assert p.bidi_names[int(BidiClass.r)] == 'R'
	assert p.bidi_names[int(BidiClass.en)] == 'EN'
	assert p.bidi_names[int(BidiClass.es)] == 'ES'
	assert p.bidi_names[int(BidiClass.et)] == 'ET'
	assert p.bidi_names[int(BidiClass.an)] == 'AN'
	assert p.bidi_names[int(BidiClass.cs)] == 'CS'
	assert p.bidi_names[int(BidiClass.b)] == 'B'
	assert p.bidi_names[int(BidiClass.s)] == 'S'
	assert p.bidi_names[int(BidiClass.ws)] == 'WS'
	assert p.bidi_names[int(BidiClass.on)] == 'ON'
	assert p.bidi_names[int(BidiClass.bn)] == 'BN'
	assert p.bidi_names[int(BidiClass.nsm)] == 'NSM'
	assert p.bidi_names[int(BidiClass.al)] == 'AL'
	assert p.bidi_names[int(BidiClass.lro)] == 'LRO'
	assert p.bidi_names[int(BidiClass.rlo)] == 'RLO'
	assert p.bidi_names[int(BidiClass.lre)] == 'LRE'
	assert p.bidi_names[int(BidiClass.rle)] == 'RLE'
	assert p.bidi_names[int(BidiClass.pdf)] == 'PDF'
	assert p.bidi_names[int(BidiClass.lri)] == 'LRI'
	assert p.bidi_names[int(BidiClass.rli)] == 'RLI'
	assert p.bidi_names[int(BidiClass.fsi)] == 'FSI'
	assert p.bidi_names[int(BidiClass.pdi)] == 'PDI'
	assert p.bidi_names.len == int(BidiClass.pdi) + 1, 'bidi name table has extra entries'

	assert p.joining_names[int(JoiningType.u)] == 'U'
	assert p.joining_names[int(JoiningType.c)] == 'C'
	assert p.joining_names[int(JoiningType.d)] == 'D'
	assert p.joining_names[int(JoiningType.r)] == 'R'
	assert p.joining_names[int(JoiningType.l)] == 'L'
	assert p.joining_names[int(JoiningType.t)] == 'T'
	assert p.joining_names.len == int(JoiningType.t) + 1, 'joining name table has extras'

	// The other enums are only checked for reach, since their values are looked
	// up by name at the call site.
	assert int(GraphemeClass.lvt) < p.grapheme_names.len
	assert p.grapheme_names[int(GraphemeClass.zwj)] == 'ZWJ'
	assert p.grapheme_names[int(GraphemeClass.extend)] == 'Extend'
	assert int(LineBreakClass.em) < p.linebreak_names.len
	assert p.linebreak_names[int(LineBreakClass.al)] == 'AL'
	assert p.linebreak_names[int(LineBreakClass.zwj)] == 'ZWJ'
	assert p.linebreak_names[int(LineBreakClass.b2)] == 'B2'
}

// test_generated_bidi_table_matches_the_ucd re-reads the UCD file and checks
// every range it lists. This is the test that would catch a generator reading the
// wrong column, which is how a bidi table silently becomes all L.
fn test_generated_bidi_table_matches_the_ucd() {
	if !os.exists('ucd') {
		return // the UCD is not vendored here; nothing to compare against
	}
	p := props()
	data := os.read_file('ucd/DerivedBidiClass.txt') or { panic(err) }
	mut checked := 0
	for line in data.split_into_lines() {
		cut := line.index('#') or { line.len }
		s := line[..cut].trim_space()
		if s == '' {
			continue
		}
		fields := s.split(';')
		if fields.len < 2 {
			continue
		}
		codes := fields[0].split('..')
		lo := hex_value(codes[0])
		hi := if codes.len > 1 { hex_value(codes[1]) } else { lo }
		want := fields[1].trim_space()
		assert p.bidi_class_name(rune(lo)) == want, 'bidi class of U+${lo:04X}'
		assert p.bidi_class_name(rune(hi)) == want, 'bidi class of U+${hi:04X}'
		checked++
	}
	assert checked > 100, 'expected many ranges, checked ${checked}'
}

// test_generated_joining_table_matches_the_ucd does the same for Joining_Type,
// which the Arabic joining algorithm depends on.
fn test_generated_joining_table_matches_the_ucd() {
	if !os.exists('ucd') {
		return
	}
	p := props()
	data := os.read_file('ucd/DerivedJoiningType.txt') or { panic(err) }
	mut checked := 0
	for line in data.split_into_lines() {
		cut := line.index('#') or { line.len }
		s := line[..cut].trim_space()
		if s == '' {
			continue
		}
		fields := s.split(';')
		if fields.len < 2 {
			continue
		}
		codes := fields[0].split('..')
		lo := hex_value(codes[0])
		want := fields[1].trim_space()
		assert int(p.joining_type_of(rune(lo))) < p.joining_names.len
		assert p.joining_names[int(p.joining_type_of(rune(lo)))] == want, 'joining type of U+${lo:04X}'
		checked++
	}
	assert checked > 100, 'expected many ranges, checked ${checked}'
}
