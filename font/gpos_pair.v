module font

// kern_lookups are the lookups of the kern feature, for the script a caller names, which is where
// a font puts its pair adjustments.
//
// They are resolved per script rather than collected once, because a font is free to give a script
// its own kerning: a Persian font kerns Arabic letters with one set of rules and Latin letters with
// another, and a single list would apply the wrong one to both. The Arabic set is collected eagerly
// because that is the script this library shapes.
pub fn (g &Gpos) kerning_for(script string, lang string) []u16 {
	mut out := g.lookups_for_lang(script, lang, 'kern')
	// Indic pair adjustments live under dist rather than kern: the Noto
	// Indic faces kern their half-forms there, and HarfBuzz applies it by
	// default. Only the six corpus faces with a dist table can answer, so
	// every other script reads exactly what it always did.
	for li in g.lookups_for_lang(script, lang, 'dist') {
		if li !in out {
			out << li
		}
	}
	return out
}

// kern_offset returns how far to move left_gid when right_gid follows it, in design units.
//
// The order of the arguments is the order of the pair in the text's own direction, which for a
// right-to-left script means the rightmost glyph comes first. This matches the specification's rule
// that a pair is written in the order the layout direction reads, and getting it backwards is
// silent: a font that kerns "AV" tightly has a rule for A then V, and asking for V then A finds
// nothing and leaves the line a little too wide rather than wrong.
//
// A value of zero is a real answer, and it is different from no answer: it is the font saying the
// pair is already correct. The caller cannot tell the two apart from the number, so this returns
// none only when the font has no rule at all.
//
// Adjustments accumulate across lookups rather than stopping at the first: every lookup that
// matches applies, and the line moves by their sum. A PairPos class-0 row matches any glyph its
// classes do not name, usually for zero, so stopping at the first match would let that zero
// hide a real kern a contextual lookup holds for the same pair — e-f in Amiri reports (0, 0)
// from the class row and -11 from the chain, and HarfBuzz draws the -11.
pub fn (g &Gpos) kern_offset(left_gid u16, right_gid u16, script string, lang string) ?Offset2 {
	mut x := 0
	mut y := 0
	mut found := false
	for li in g.kerning_for(script, lang) {
		if li >= g.lookups.len {
			continue
		}
		for rule in g.lookups[li].pairs {
			if a := rule.offset_for(left_gid, right_gid) {
				x += a.x
				y += a.y
				found = true
				break
			}
		}
	}
	if !found {
		return none
	}
	return Offset2{
		x: x
		y: y
	}
}

// vkerning_for are the lookups of the vkrn feature, for the script a caller names: the vertical
// half of kerning_for. A font is free to kern horizontally and vertically under different rules,
// and Yu Gothic does — its kern and vkrn are different lookups — so one list cannot answer both.
pub fn (g &Gpos) vkerning_for(script string, lang string) []u16 {
	return g.lookups_for_lang(script, lang, 'vkrn')
}

// vkern_offset returns how far to move left_gid down when right_gid follows it in a vertical line,
// in design units: the y advance the pair's rule names, which closes the downward step the way an
// x advance closes the horizontal one. Plain pairs only, the contextual half of vkrn is not read:
// no font on this machine writes one, and a reader verified only against tables built to match it
// is the failure this repository rejects.
//
// The answer is the first glyph's, in the text's own direction, the same convention kern_offset
// keeps. A value of zero is a real answer like it is there, and none means no rule at all.
pub fn (g &Gpos) vkern_offset(left_gid u16, right_gid u16, script string, lang string) ?Offset2 {
	mut y := 0
	mut found := false
	for li in g.vkerning_for(script, lang) {
		if li >= g.lookups.len {
			continue
		}
		for rule in g.lookups[li].pairs {
			if a := rule.offset_for_vertical(left_gid, right_gid) {
				y += a.y
				found = true
				break
			}
		}
	}
	if !found {
		return none
	}
	return Offset2{
		x: 0
		y: y
	}
}

// has_kerning reports whether the font has any pair adjustment for a script, which is what a
// caller needs to know before deciding whether to lay a line out twice to find the answer.
//
// A context counts. A font whose only rules are context-sensitive kerns just as much as one with a
// plain pair table, and reporting false for it would make a caller lay a line out twice to learn there
// was nothing to learn.
pub fn (g &Gpos) has_kerning(script string, lang string) bool {
	for li in g.kerning_for(script, lang) {
		if li >= g.lookups.len {
			continue
		}
		lk := g.lookups[li]
		if lk.pairs.len > 0 || lk.chains.len > 0 || has_chain_classes(lk)
			|| has_chain_glyphs(lk) {
			return true
		}
	}
	return false
}

// offset_for finds the adjustment for one pair of glyphs within a single rule.
//
// The two formats are answered from different tables and it is worth saying which, because the
// answer is the same number either way and only one of them can be checked by looking.
//
// Format 1 names each pair, so it has to find the first glyph in its coverage, then the second
// glyph in that glyph's own set. The second coverage is what says how many records follow, and a
// record is found through it rather than by assuming an order, so a font that writes its records in
// a different order still works.
//
// Format 2 names no pair at all. It says what class each glyph is in and looks the answer up in a
// matrix, so every pair of glyphs in two classes shares one adjustment. A font that uses it has
// usually also written a format 1 rule for the pairs it wants to treat differently, and a lookup
// holds both, so the order of the rules decides which one is reached.
//
// The adjustment returned is the first glyph's, and it is only reported when it is a change of
// advance. A record that only moves a glyph without changing the gap is a placement rule, and
// reporting it as a kern would take a letter out from under its neighbour.
pub fn (rule &PairPos) offset_for(left_gid u16, right_gid u16) ?Anchor {
	return rule.offset_for_advance(left_gid, right_gid, false)
}

// offset_for_vertical finds the vertical adjustment for one pair of glyphs within a single rule.
//
// It walks the same tables as offset_for, and the answer is reported when it changes the vertical
// advance rather than the horizontal one: a vkrn record carries only a y advance, which the
// horizontal gate reads as no kern at all.
pub fn (rule &PairPos) offset_for_vertical(left_gid u16, right_gid u16) ?Anchor {
	return rule.offset_for_advance(left_gid, right_gid, true)
}

fn (rule &PairPos) offset_for_advance(left_gid u16, right_gid u16, vertical bool) ?Anchor {
	// The second glyph is the one that advances, so it is the one a zero value format 2 leaves
	// without a record of its own.
	mut first_side := PairValue{}
	if rule.is_format2 {
		// Class 0 is the class of a glyph the definitions do not name, and a font is free to put a
		// pair there on purpose: a rule that kerns everything next to a punctuation mark writes its
		// adjustments in the class 0 row, because the other glyphs are the ones in no class. So class
		// 0 cannot be skipped.
		//
		// What does decide the pair is the coverage, which lists the first glyphs the rule is about
		// at all. A glyph outside it is not in the rule whatever class the definitions give it, and
		// the class matrix is indexed by class rather than by glyph, so without this check any glyph
		// would match any cell.
		if coverage_index(rule.first_ranges, left_gid) == none {
			return none
		}
		first_class := int(rule.class_def1.class_of(left_gid))
		second_class := int(rule.class_def2.class_of(right_gid))
		if first_class >= rule.class1_records.len {
			return none
		}
		row := rule.class1_records[first_class]
		if second_class >= row.len {
			return none
		}
		first_side = row[second_class]
	} else {
		first_index := coverage_index(rule.first_ranges, left_gid) or { return none }
		if first_index >= rule.pair_sets.len {
			return none
		}
		set := rule.pair_sets[first_index]
		// The second glyphs are named by their own ids, in the order the records are written, so finding
		// one is counting along the array rather than looking it up. The array is short — it is the set
		// of glyphs this one first glyph pairs with — so a scan is the cheaper answer than a map, and it
		// keeps a font with thousands of pair sets from allocating a map per set.
		mut second_index := -1
		for i, g in set.seconds {
			if g == right_gid {
				second_index = i
				break
			}
		}
		if second_index < 0 || second_index >= set.records.len {
			return none
		}
		first_side = set.records[second_index][0]
	}
	if vertical {
		if !first_side.has_y_advance() {
			return none
		}
	} else if !first_side.has_x_advance() {
		return none
	}
	return Anchor{
		x:      int(first_side.x_advance)
		y:      int(first_side.y_advance)
		exists: true
	}
}

// parse_pair_pos reads one PairPos subtable, in whichever of the two formats it declares.
//
// The formats are the same rule with a different indexing scheme, and the format is the first field
// because the two cannot be told apart any other way: both start with a coverage, and both go on
// writing structures whose width depends on the value formats.
//
// Format 1 names every pair. Format 2 says which glyphs share an adjustment by class and writes the
// adjustments in a matrix, which is how a font keeps a kerning table to a size that can be shipped.
// PairValue is one side of a pair adjustment: the four numbers a font can change about a glyph, and
// which of them it wrote.
//
// The four are placement and advance in each direction, and they are not the same adjustment:
// xPlacement moves the glyph where it is drawn without changing how far the pen travels, and
// xAdvance changes the gap after it. Kerning uses xAdvance, because the whole point is the space
// between two letters, and a rule that used xPlacement instead would move the first letter out from
// under the second one and leave the gap the same.
//
// Which fields a record has is decided by the subtable's value format, not by the record itself, so
// this keeps a mask per side. A record with x of zero and no x at all is not a kern of nothing, it
// is a rule that says nothing about the horizontal, and the two cannot be told apart without it.
pub struct PairValue {
pub mut:
	x_placement i16
	y_placement i16
	x_advance   i16
	y_advance   i16
	// format is the value format of the side this record came from, which is what says whether a
	// field is present or merely zero.
	format u16
}

// present_x_advance reports whether this record adjusts the horizontal advance at all, which is
// what kerning is. A rule that adjusts only a placement is not a kern, and applying it as one would
// move a letter without closing the gap.
pub fn (v &PairValue) has_x_advance() bool {
	return v.format & 0x0004 != 0
}

// present_y_advance reports whether this record adjusts the vertical advance at all, which is
// what vertical kerning is. A vkrn record carries only this, so the horizontal gate drops it.
pub fn (v &PairValue) has_y_advance() bool {
	return v.format & 0x0008 != 0
}

// PairSet is every adjustment one first glyph has.
//
// A PairSet has no coverage. It names the second glyphs as an array of glyph ids, in the order the
// records that follow are written, so a record is found by counting along the array rather than by
// looking the glyph up in a coverage. Reading a coverage at the offset where the second glyphs start
// reads the first glyph id as a coverage format, which is not 1 or 2, so the whole set comes back
// empty and the format reports as having no rules at all.
pub struct PairSet {
pub mut:
	// seconds are the second glyphs, in the order the records are written.
	seconds []u16
	// records is indexed the same way as seconds, and holds the two sides of the adjustment in order.
	records [][]PairValue
}

// PairPos is one pair-adjustment rule: for a covered first glyph, how far to move it and the glyph
// that follows it.
//
// The two formats are kept apart in the fields rather than resolved at parse time, because they
// share a header and diverge immediately after it: format 1 has a pairSetCount where format 2 has
// two class definitions, so reading one as the other produces a plausible count and rows of numbers
// that are not adjustments of anything.
pub struct PairPos {
pub mut:
	// first_ranges is the coverage of the first glyph of a pair, which is the glyph that moves.
	first_ranges []CoverageRange
	// value_format1 and value_format2 are the field masks of the first and second sides. They are
	// kept because they say how wide a record is, which is what steps the reader onto the next pair.
	value_format1 u16
	value_format2 u16
	// pair_sets is the set of rules of format 1, indexed by the first glyph's coverage index.
	pair_sets []PairSet
	// class_def1 and class_def2 are the class definitions of format 2. A glyph's class says which
	// column or row of the matrix its adjustment is in, which is how a font writes one rule for a
	// group of glyphs rather than one rule for each pair.
	class_def1 ClassDef
	class_def2 ClassDef
	// class1_records is indexed by the second glyph's class, and each entry is that row of the
	// matrix: one value for every class the first glyph might be in.
	class1_records [][]PairValue
	// class2_records is the last column, which is what a glyph with a valueFormat2 of zero gets.
	class2_records []PairValue
	// is_format2 says which format the subtable declared, and is what the lookup does with it.
	is_format2 bool
}

// parse_pair_pos reads one PairPos subtable, in whichever of the two formats it declares.
//
// The format is read first because the two cannot be told apart any other way: both begin with a
// coverage of the first glyph, both declare the same two value formats, and both go on to write
// structures whose width depends on those formats, so a record cannot even be stepped over before
// the format is known.
//
// They diverge at the sixth field. Format 1 has a count of PairSet tables there, and format 2 has two
// class definitions. Reading a format 2 subtable as format 1 takes the first class definition's
// offset as a count of sets, which is a small number that looks fine, and then walks offsets out of
// a class definition that is not an array of them. The result is thousands of pair records with
// numbers in them that are not kerning.
pub fn parse_pair_pos(r &Reader, at int) ?PairPos {
	format := r.u16_at(at)
	if format != 1 && format != 2 {
		return none
	}
	pos := at
	first_ranges := parse_coverage(r, pos + int(r.u16_at(pos + 2)))
	vf1 := r.u16_at(pos + 4)
	vf2 := r.u16_at(pos + 6)
	if first_ranges.len == 0 {
		return none
	}
	if format == 1 {
		//	PairPosFormat1
		//	    uint16   format                    = 1
		//	    Offset16 coverageOffset
		//	    uint16   valueFormat1
		//	    uint16   valueFormat2
		//	    uint16   pairSetCount
		//	    Offset16 pairSetOffsets[pairSetCount]
		//
		// The offsets are from the beginning of the subtable, and the count is a count rather than
		// an offset, so the two are read from the header rather than from a table one of them points
		// at. Reading the count out of the first PairSet instead picks up its pairValueCount, which
		// is a different number about different things, and the offsets that follow are then walked
		// from the wrong place.
		//
		// The count is a count of sets and a set is a covered first glyph, so it is the number of
		// glyphs the coverage names and not the number of ranges in it. Capping it at the range
		// count instead truncates a font whose coverage is written in few large ranges, and the
		// glyphs past the cap then have no adjustment at all.
		mut first_glyphs := 0
		for cr in first_ranges {
			first_glyphs += int(cr.last - cr.first) + 1
		}
		mut set_count := int(r.u16_at(pos + 8))
		if set_count > first_glyphs {
			set_count = first_glyphs
		}
		mut pair_sets := []PairSet{cap: set_count}
		for i in 0 .. set_count {
			set_at := pos + int(r.u16_at(pos + 10 + i * 2))
			if set := parse_pair_set(r, set_at, vf1, vf2) {
				pair_sets << set
			}
		}
		return PairPos{
			first_ranges:  first_ranges
			value_format1: vf1
			value_format2: vf2
			pair_sets:     pair_sets
		}
	}
	//	PairPosFormat2
	//	    Offset16 classDef1Offset
	//	    Offset16 classDef2Offset
	//	    uint16   class1Count
	//	    uint16   class2Count
	//	    Class1Record class1Records[class1Count]
	//	    Class2Record class2Records[class2Count]
	//
	// A Class1Record is a row of the matrix: one value for every class the first glyph can be in.
	// A Class2Record is a single value, the one for a first glyph that has no class of its own.
	cd1 := parse_class_def(r, pos + int(r.u16_at(pos + 8)))
	cd2 := parse_class_def(r, pos + int(r.u16_at(pos + 10)))
	class1_count := int(r.u16_at(pos + 12))
	class2_count := int(r.u16_at(pos + 14))
	// A Class1Record is a row of the matrix: for one class of first glyph, the adjustment for every
	// class of second glyph. Only the first glyph's value is in the row, because a format 2 rule
	// moves the first glyph and leaves the second alone, which is what the class 2 records are for.
	//
	// The reader advances by the size of one value and not by the size of a pair, because a pair of
	// records is format 1's arrangement. Stepping by both here would skip past the end of the row
	// and read the next row's numbers into this one.
	vf1_size := pair_value_size(vf1)
	mut class1_records := [][]PairValue{cap: class1_count}
	mut at2 := pos + 16
	for _ in 0 .. class1_count {
		mut row := []PairValue{cap: class2_count}
		for _ in 0 .. class2_count {
			row << read_pair_value(r, at2, vf1)
			at2 += vf1_size
		}
		class1_records << row
	}
	// The class 2 records follow the class 1 records, and the reader is already at them, because
	// each class 1 record was read whole.
	mut class2_records := []PairValue{cap: class2_count}
	for _ in 0 .. class2_count {
		class2_records << read_pair_value(r, at2, vf1)
		at2 += vf1_size
	}
	return PairPos{
		first_ranges:   first_ranges
		value_format1:  vf1
		value_format2:  vf2
		class_def1:     cd1
		class_def2:     cd2
		class1_records: class1_records
		class2_records: class2_records
		is_format2:     true
	}
}

// parse_pair_set reads one PairSet: a count, then that many records.
//
// A record is three things in a row and no more: the second glyph, the value for the first glyph, and
// the value for the second. The second glyph is a glyph id rather than an index into anything, and the
// records are ordered by it.
//
// This is the shape the bytes have, which is not the shape the specification's prose suggests. The
// specification describes the second glyphs as an array of offsets to the records followed by an array
// of the records, which would put every glyph id first and every value after it. Segoe UI's Latin
// kerning does not do that: its first PairSet is the count 65 and then C, -40, G, -40, J, 94, O, -40,
// T, -147, U, -40, V, -140, each glyph immediately followed by its value, which is what fontTools reads
// and what its own table description says the fields are.
//
// Reading it the other way produces a font that kerns A followed by V by +60 rather than -140, which is
// a gap that opens rather than one that closes and looks like a different typeface at a glance.
//
// A PairValue here is two records, one for each glyph of the pair, and both are read even when one of
// them is empty. A font that gives the second glyph a value format of zero leaves its record with no
// fields, and the record still occupies the space the format says it does, so the reader has to step
// over it to reach the next pair.
pub fn parse_pair_set(r &Reader, at int, vf1 u16, vf2 u16) ?PairSet {
	if !r.has(at, 2) {
		return none
	}
	count := int(r.u16_at(at))
	if count <= 0 {
		return none
	}
	vf1_size := pair_value_size(vf1)
	vf2_size := pair_value_size(vf2)
	step := 2 + vf1_size + vf2_size
	mut seconds := []u16{cap: count, len: 0}
	mut records := [][]PairValue{cap: count, len: 0}
	mut p := at + 2
	for _ in 0 .. count {
		if !r.has(p, step) {
			break
		}
		seconds << r.u16_at(p)
		records << [read_pair_value(r, p + 2, vf1), read_pair_value(r, p + 2 + vf1_size, vf2)]
		p += step
	}
	if seconds.len == 0 || records.len == 0 {
		return none
	}
	return PairSet{
		seconds: seconds
		records: records
	}
}

// read_pair_value reads one ValueRecord, which is a variable-length structure: each bit of the
// value format says one field is there, and the fields come in a fixed order when they are.
//
// The order is the order the format's bits are numbered in, which is placement before advance and
// x before y: xPlacement, yPlacement, xAdvance, yAdvance. The device or variation table offsets
// follow, and are skipped rather than kept, because a hint that a pair is tighter at one size than
// another is a refinement this engine does not apply.
//
// Reading the fields without consulting the format produces a record of the right length and the
// wrong numbers: a font that only writes xAdvance yields a record whose xPlacement is the kerning
// value, which is the same number in the wrong place and produces a letter that has moved rather
// than a gap that has closed.
pub fn read_pair_value(r &Reader, at int, format u16) PairValue {
	mut v := PairValue{
		format: format
	}
	mut p := at
	if format & 0x0001 != 0 {
		v.x_placement = r.i16_at(p)
		p += 2
	}
	if format & 0x0002 != 0 {
		v.y_placement = r.i16_at(p)
		p += 2
	}
	if format & 0x0004 != 0 {
		v.x_advance = r.i16_at(p)
		p += 2
	}
	if format & 0x0008 != 0 {
		v.y_advance = r.i16_at(p)
		p += 2
	}
	return v
}

// pair_value_size is how many bytes a ValueRecord of this format occupies. The size comes from the
// format rather than from what was read, because a value can be present and zero, and the reader
// has to be stepped over to reach the next record.
//
// All eight fields are counted, including the four VariationIndex offsets a variable font's value record may
// carry. Those four were missing until 2026-10-04, which meant every record after one of them was read from
// the wrong place: a font with a variable-font kern had its second pair read out of the middle of the first,
// and the words it landed on are small numbers, so nothing looked wrong. SegUIVar sets 9,430 of them and
// SitkaVF two — measured across all 379 faces on this machine — so the bits are exercised by real fonts even
// though no Device table is: the count below is zero across 2,450,058 value records. See
// `gpos_valuesize_test.v`, which is written as bytes for that reason.
pub fn pair_value_size(format u16) int {
	mut n := 0
	for bit in [0x0001, 0x0002, 0x0004, 0x0008, 0x0010, 0x0020, 0x0040, 0x0080, 0x0100, 0x0200,
		0x0400, 0x0800] {
		if format & bit != 0 {
			n += 2
		}
	}
	return n
}
