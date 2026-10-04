module vtext

import os

// Cursive attachment under GPOS lookup type 3: a rule says where each covered glyph's stroke enters and
// leaves, and consecutive glyphs are joined by placing one entry anchor on the previous exit anchor.
//
// The hand-built tables below exist because the ambiguity is only visible in bytes. Reading a cursive
// record array from the wrong offset turns a rule into something that looks like a single positioning and
// then refuses it, so a font carrying a real one is the only thing that catches a reader which is
// confidently wrong in both directions at once.
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
// Both cursive formats write the same six-word header of posFormat, coverageOffset and entryExitCount, so
// the records start six bytes in and the count is read rather than counted from the coverage. The anchor
// offset is 16 rather than the 10 the coverage starts at because the anchor follows the coverage.
fn cursive_format1_bytes() []u8 {
	return bytes_of([
		1,
		10, // posFormat, coverage offset
		1,
		16, // entryExitCount, entry anchor offset
		0, // exit anchor offset
		1,
		1,
		3, // coverage format 1, one glyph, glyph 3
		1,
		0,
		23, // anchor format 1, x, y
	])
}

// cursive_format2_bytes builds a CursivePos format 2 subtable covering one glyph whose exit anchor is at
// (95, 77) and which has no entry anchor. The two formats are laid out identically; format 2 only lets the
// count fall short of the coverage, which is what its own test covers.
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
		14, // posFormat, coverage offset
		2, // entryExitCount
		24, // glyph 10: entry anchor
		0, // and no exit anchor
		0, // glyph 11: no entry anchor
		30, // and an exit one
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
	rule := parse_single_position(r, ResolvedSubtable{
		kind: gpos_lookup_single_position
		at:   0
	}) or { panic('a single positioning is not a cursive rule') }
	assert rule.ranges.len == 1, 'and it covers the one glyph'
	got := rule.offset_for(3) or { panic('no value for the glyph') }
	assert got.x == -120, 'and it moves it by the font number'
}

// A cursive rule is one record per named glyph, and its offsets point past the records to anchors that
// declare themselves anchors.
fn test_gpos_cursive_reader_reads_format_one() {
	r := new_reader(cursive_format1_bytes())
	rule := parse_cursive(r, 0) or { panic('a cursive rule with an anchor was refused') }
	assert rule.format == 1, 'and it says which format it is'
	got := rule.offset_for(3) or { panic('no anchors for the covered glyph') }
	assert got.entry.exists, 'the entry anchor is there'
	assert got.entry.y == 23, 'at the height the bytes say'
	assert !got.exit.exists, 'and an absent exit anchor stays absent rather than becoming a zero'
}

// Format 2 is laid out exactly like format 1, and what it adds is that the count may fall short of the
// coverage so that trailing covered glyphs take no part in the joining.
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

// Dubai reaches its cursive rule through an extension, and it is the font that made the rule worth
// testing: fontTools reads the extension as a mark attachment whose base and mark offsets happen to land
// on something shaped like an anchor, which is how a cursive table came to be dismissed as a mark
// attachment twice. Reading the record array from the six-byte header rather than four makes every one of
// its anchors declare itself an anchor, and the lookup resolves to a cursive rule.
fn test_gpos_dubai_curs_feature_reaches_a_cursive_rule() {
	f := load_font_file('C:\\Windows\\Fonts\\DUBAI-REGULAR.TTF') or { panic(err) }
	gpos := f.face.gpos or { panic('no GPOS') }
	mut cursive := 0
	mut covered := 0
	for script in ['arab', 'latn'] {
		for li in gpos.lookups_for(script, 'curs') {
			if int(li) < gpos.lookups.len {
				cursive += gpos.lookups[li].cursives.len
				for rule in gpos.lookups[li].cursives {
					covered += rule.marks.len
				}
			}
		}
	}
	assert cursive > 0, 'the curs feature names a rule with anchors in it'
	assert covered > 0, 'and it covers glyphs rather than only naming a lookup'
}

// Amiri and Noto Nastaliq Urdu both carry a real cursive attachment, and both were read as having none
// until the record array was read from six bytes into the subtable rather than four. They are the
// regression guard for that, because a hand-built table cannot catch a reader that is wrong about where
// the records start: a fixture written to match the reader passes on any offset it agrees with.
//
// Amiri declares the rule directly and Noto Nastaliq through an extension, so both paths are covered.
fn test_gpos_cursive_is_read_from_real_fonts() {
	mut found := map[string]int{}
	for name in ['Amiri-Regular.ttf', 'NotoNaskhArabic-Regular.ttf', 'NotoNastaliqUrdu-Regular.ttf'] {
		f := load_font_file(os.join_path('testdata', 'fonts', name)) or {
			panic('cannot load ${name}: ${err}')
		}
		gpos := f.face.gpos or { panic('${name} has no GPOS') }
		mut rules := 0
		mut entry_anchors := 0
		mut exit_anchors := 0
		for l in gpos.lookups {
			for rule in l.cursives {
				rules++
				for m in rule.marks {
					if m.entry.exists {
						entry_anchors++
					}
					if m.exit.exists {
						exit_anchors++
					}
				}
			}
		}
		found[name] = rules
		if rules > 0 {
			// A rule with no entry anchor has nothing to join onto, and one with no exit anchor has
			// nothing to join from. A font that has both counted hundreds of times over a rule read
			// from the wrong offset, so both have to be substantial for the read to mean anything.
			assert entry_anchors > 10, '${name}: ${entry_anchors} entry anchors is too few to be a cursive rule'
			assert exit_anchors > 10, '${name}: ${exit_anchors} exit anchors is too few to be a cursive rule'
		}
	}
	assert found['Amiri-Regular.ttf'] > 0, 'Amiri declares its cursive rule directly, got ${found['Amiri-Regular.ttf']}'
	assert found['NotoNastaliqUrdu-Regular.ttf'] > 0, 'Noto Nastaliq reaches its rule through an extension, got ${found['NotoNastaliqUrdu-Regular.ttf']}'
	// The negative control. Noto Naskh joins with substitutions alone and has no cursive rule, so a
	// reader that accepts every type 3 subtable would fail here rather than pass quietly.
	assert found['NotoNaskhArabic-Regular.ttf'] == 0, 'Noto Naskh has no cursive rule, got ${found['NotoNaskhArabic-Regular.ttf']}'
}

// The anchors have to be in the font's own coordinates, which for these faces means well inside a
// thousand-unit em. A record array read from the wrong offset produces anchors that are plainly not
// points, so this is the check that separates a rule from a plausible-looking mistake.
fn test_gpos_cursive_anchors_are_points_in_font_units() {
	f := load_font_file(os.join_path('testdata', 'fonts', 'Amiri-Regular.ttf')) or { panic(err) }
	gpos := f.face.gpos or { panic('no GPOS') }
	mut checked := 0
	for l in gpos.lookups {
		for rule in l.cursives {
			for m in rule.marks {
				for a in [m.entry, m.exit] {
					if !a.exists {
						continue
					}
					assert a.x > -2000 && a.x < 2000, 'entry or exit x out of range: ${a.x}'
					assert a.y > -2000 && a.y < 2000, 'entry or exit y out of range: ${a.y}'
					checked++
				}
			}
		}
	}
	assert checked > 50, 'only ${checked} anchors were checked, which is too few to be meaningful'
}
