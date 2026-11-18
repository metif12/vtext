module font

// single_offset_on answers one glyph's single positioning from an explicit lookup list, in
// design units: the placements and the advances together, with the format saying which
// fields the font wrote. A value of zero in every field is a real answer, like it is for
// kern_offset, and none means no rule at all.
//
// Adjustments accumulate across lookups rather than stopping at the first, the same rule
// kern_offset keeps: every lookup that matches applies, and the line moves by their sum.
// Within one lookup the first matching rule wins, because one lookup applies once however
// many of its subtables cover the glyph.
pub fn (g &Gpos) single_offset_on(gid u16, lookups []u16) ?PairValue {
	mut x_pl := 0
	mut y_pl := 0
	mut x_adv := 0
	mut y_adv := 0
	mut format := u16(0)
	mut found := false
	for li in lookups {
		if li >= g.lookups.len {
			continue
		}
		for rule in g.lookups[li].singles {
			if v := rule.value_for(gid) {
				x_pl += v.x_placement
				y_pl += v.y_placement
				x_adv += v.x_advance
				y_adv += v.y_advance
				format |= v.format
				found = true
				break
			}
		}
	}
	if !found {
		return none
	}
	return PairValue{
		x_placement: i16(x_pl)
		y_placement: i16(y_pl)
		x_advance:   i16(x_adv)
		y_advance:   i16(y_adv)
		format:      format
	}
}

// SinglePos is one positioning rule: for a covered glyph on its own, move it.
//
// It is the smallest of the positioning tables and the one a context record most often names. A font
// says "this glyph sits further left when it follows that one" with a rule of this shape inside a
// context, and a rule of this shape is a placement rather than a kern: the glyph moves and the gap
// after it does not, which is the difference between the two that matters when a context record is
// applied.
pub struct SinglePos {
pub mut:
	// ranges is the coverage of the glyphs this rule moves.
	ranges []CoverageRange
	// format is the value format, which says which of the four numbers each record holds. It is kept
	// because a record with an x of zero and no x at all means the font says nothing about the
	// horizontal, which is not the same as saying zero.
	format u16
	// values is indexed by the glyph's coverage index, so a record is found through the coverage
	// rather than by an offset the caller would have to know about.
	values []PairValue
	// base is format 2's single value, which every covered glyph takes unless an override names it.
	// It is an Option because format 1 has no such thing, and a rule that has a base of zero would
	// otherwise be indistinguishable from one that has none.
	base ?PairValue
	// overrides are format 2's exceptions, keyed by the glyph's *coverage index* rather than by glyph
	// id, which is the whole reason format 2 cannot be read as format 1.
	overrides []PosOverride
}

// PosOverride is one format 2 exception: a set of coverage indices and the value they take instead of
// the rule's single value.
pub struct PosOverride {
pub mut:
	index int
	value PairValue
}

// offset_for finds the adjustment for one glyph within a single rule.
pub fn (rule &SinglePos) offset_for(gid u16) ?Offset2 {
	idx := coverage_index(rule.ranges, gid) or { return none }
	// Format 2 asks the exceptions first and the shared value second, and a rule cannot have both, so
	// which pair of these is live is decided by whether base is set rather than by a format number. That
	// keeps one lookup path for both formats instead of two that can disagree.
	if rule.base != none {
		for o in rule.overrides {
			if o.index == int(idx) {
				return placement_of(o.value)
			}
		}
		return placement_of(rule.base or { return none })
	}
	if idx >= rule.values.len {
		return none
	}
	return placement_of(rule.values[idx])
}

// value_for finds the full value record for one glyph within a single rule: the
// placements and the advances together, with the format saying which fields the
// font wrote. offset_for answers the placement half for callers that position
// marks; a caller that also folds advances needs the record itself, because a
// record that says nothing about placement is still a kern when it carries an
// advance, and placement_of would report it as no rule at all.
pub fn (rule &SinglePos) value_for(gid u16) ?PairValue {
	idx := coverage_index(rule.ranges, gid) or { return none }
	// Format 2 asks the exceptions first and the shared value second, and a rule cannot have both, so
	// which pair of these is live is decided by whether base is set rather than by a format number. That
	// keeps one lookup path for both formats instead of two that can disagree.
	if rule.base != none {
		for o in rule.overrides {
			if o.index == int(idx) {
				return o.value
			}
		}
		return rule.base or { return none }
	}
	if idx >= rule.values.len {
		return none
	}
	return rule.values[idx]
}

// placement_of turns a value record into an offset, or reports that the record says nothing about
// where the glyph goes.
//
// A rule that says nothing about either placement is no rule, and answering it with a zero would look
// like a font that had decided the glyph was already in the right place.
pub fn placement_of(v PairValue) ?Offset2 {
	if v.format & 0x0003 == 0 {
		return none
	}
	return Offset2{ x: i32(v.x_placement), y: i32(v.y_placement) }
}

// parse_single_position reads one SinglePos subtable, in either format.
//
// Format 1 has one value for every covered glyph, and the value comes straight after the format that
// says how wide it is. There is no count of the values: the coverage already says how many glyphs there
// are, so a count would be redundant, and reading the first value as a count turns a value of -120 into
// a count of 65416 and then walks 65416 records off the end of the table. That is why the numbers this
// produced were the wrong ones rather than merely noisy ones, and it is a mistake worth naming because
// the pair tables beside it do have a count and the two sit next to each other in the same table.
//
// Format 2 has one value for the whole coverage, a count of it, and then a run of exceptions to the end
// of the subtable — unless the count equals the coverage size, which is per-glyph values in coverage
// order with no exceptions (Noto's dist singles, Segoe UI's extension-wrapped one). The count is read
// and must be 1 or the coverage size; reading any other format 2 as format 1 takes that count as
// the number of per-glyph values, walks `glyphs` values out of a table that has one, and then reads the
// exception list's coverage indices as though they were records.
//
// The exceptions run "to the end of the subtable", which is the awkward part: a lookup's subtables
// carry no length of their own unless they came through an extension, and one that did does. So the
// scan is bounded twice — by the extension's length when there is one, and always by the coverage.
//
// The second bound is the one that matters and it is structural rather than a guess: an exception names
// *coverage indices*, so it cannot name more glyphs than the coverage covers. A count larger than that
// is not a badly-aligned record, it is the end of this table and the beginning of whatever follows, and
// stopping there is what keeps a format 2 subtable from reading the next lookup's bytes as exceptions.
pub fn parse_single_position(r &Reader, resolved ResolvedSubtable) ?SinglePos {
	at := resolved.at
	format := r.u16_at(at)
	if format != 1 && format != 2 {
		return none
	}
	ranges := parse_coverage(r, at + int(r.u16_at(at + 2)))
	value_format := r.u16_at(at + 4)
	if ranges.len == 0 {
		return none
	}
	// The coverage's number of glyphs is the number of values, and a coverage is written as ranges, so
	// it is the sum of the range widths rather than the length of the range list. A coverage of three
	// glyphs in one range is still three values.
	mut glyphs := 0
	for cr in ranges {
		glyphs += int(cr.last - cr.first) + 1
	}
	if format == 1 {
		step := pair_value_size(value_format)
		mut values := []PairValue{cap: glyphs, len: 0}
		mut p := at + 6
		for _ in 0 .. glyphs {
			values << read_pair_value(r, p, value_format)
			p += step
		}
		return SinglePos{
			ranges: ranges
			format: value_format
			values: values
		}
	}
	//	SinglePosFormat2
	//	    uint16   posFormat               = 2
	//	    Offset16 coverageOffset
	//	    uint16   valueFormat
	//	    uint16   valueCount              (must be 1)
	//	    Value   value1[valueCount]
	//	    PosRule posRuleSet[]             (to the end of the subtable)
	if !r.has(at + 6, 2) {
		return none
	}
	value_count := int(r.u16_at(at + 6))
	step := pair_value_size(value_format)
	// A count equal to the coverage size is per-glyph values in coverage
	// order, the way Noto writes format 2 (Bengali dist lookup 10 carries
	// twelve values for twelve glyphs and no exceptions) and Segoe UI its
	// extension-wrapped format 2 (fifteen YPlacement values for fifteen
	// glyphs). The values land
	// in the same per-index list format 1 uses, so the lookup path below
	// serves both without knowing which format wrote them.
	if value_count == glyphs {
		if value_count <= 0 {
			return none
		}
		mut values := []PairValue{cap: glyphs, len: 0}
		mut p := at + 8
		for _ in 0 .. glyphs {
			if !r.has(p, step) {
				return none
			}
			values << read_pair_value(r, p, value_format)
			p += step
		}
		return SinglePos{
			ranges: ranges
			format: value_format
			values: values
		}
	}
	if value_count != 1 {
		// The specification says one, apart from the per-glyph shape above.
		// A count of anything else is a table this reader does not
		// understand, and guessing how many values follow would be guessing where the exceptions
		// start.
		return none
	}
	base := read_pair_value(r, at + 8, value_format)

	mut p := at + 8 + step
	// The extension's length is measured from the start of the extension, so the bound is relative to
	// the extension's own offset rather than to the subtable it points at.
	mut limit := r.len()
	if resolved.length > 0 {
		mut from_wrapper := resolved.wrapper + resolved.length
		if from_wrapper > 0 && from_wrapper < limit {
			limit = from_wrapper
		}
	}
	mut overrides := []PosOverride{}
	for p + 2 <= limit {
		glyph_count := int(r.u16_at(p))
		// The bound that does not depend on knowing where the subtable ends.
		if glyph_count == 0 || glyph_count > glyphs {
			break
		}
		if p + 2 + glyph_count * 2 + step > limit {
			break
		}
		// Every index named has to be one the coverage has, or the record is not this table's.
		mut indices := []int{cap: glyph_count}
		mut bad := false
		for k in 0 .. glyph_count {
			at_index := int(r.u16_at(p + 2 + k * 2))
			if at_index >= glyphs {
				bad = true
				break
			}
			indices << at_index
		}
		if bad {
			break
		}
		v := read_pair_value(r, p + 2 + glyph_count * 2, value_format)
		for ix in indices {
			overrides << PosOverride{
				index: ix
				value: v
			}
		}
		p += 2 + glyph_count * 2 + step
	}
	return SinglePos{
		ranges:    ranges
		format:    value_format
		base:      base
		overrides: overrides
	}
}
