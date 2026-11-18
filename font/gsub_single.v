module font

// SingleSubst is one single-substitution rule: the glyphs it covers and what each becomes.
pub struct SingleSubst {
pub mut:
	ranges []CoverageRange
	// delta is added to a covered glyph index, which is how the format 1 table stores a
	// substitution. subs is the explicit replacement list of format 2, indexed by coverage
	// index. Exactly one of the two is used.
	delta i32
	subs  []u16
}

// MultipleSubst is one rule that turns a single glyph into a sequence of them.
//
// It is the mirror image of a ligature, and it is the only substitution that makes one input
// character into more than one glyph. That is why it needs its own bookkeeping downstream: a
// ligature leaves a gap to be covered by one glyph, whereas this fills one character with several
// glyphs, and a layout pass that assumes one glyph per character has to be told about the
// difference.
pub struct MultipleSubst {
pub mut:
	// ranges is the coverage, which indexes the sequence list below.
	ranges []CoverageRange
	// sequences is one replacement list per covered glyph, in coverage order.
	sequences [][]u16
}

// AlternateSubst is one rule that offers a covered glyph several replacements and lets the caller
// choose.
//
// In shaping the choice is not really a choice: the first alternate is the one the font wants, and
// the rest are the variants a character palette or a user picks between. So this is read as a
// single substitution whose replacement is the first of the list, and the other alternates are
// kept because a caller that does want to choose should not have to reparse the font to do it.
//
// It matters more than it sounds. Arabic Typesetting puts its final forms under this type rather
// than under a single substitution, so a shaper that does not read it draws every final form in
// Arabic Typesetting as its isolated letter, and there is no error to notice that by.
pub struct AlternateSubst {
pub mut:
	// ranges is the coverage, which indexes the sets below.
	ranges []CoverageRange
	// sets is one list of alternates per covered glyph, in coverage order.
	sets [][]u16
}

// apply runs a list of lookups over one glyph and returns the result. A lookup that does not
// cover the glyph leaves it alone, which is what lets a feature be a set of small rules
// rather than one complete mapping.
pub fn (g &Gsub) apply(lookups []u16, gid u16) u16 {
	mut out := gid
	for li in lookups {
		if li >= g.lookups.len {
			continue
		}
		lookup := g.lookups[li]
		if lookup.kind == gsub_lookup_single {
			if sub := single_lookup(lookup.singles, out) {
				out = sub
			}
		}
		// A multiple substitution with exactly one output is a single substitution wearing
		// another type number: Amiri keeps all four joining shapes in such lookups, and a
		// query that only reads singles answers the base glyph for every one of them. A
		// sequence of any other length cannot be expressed as one glyph id, so those rules
		// are left to the run-level path, which is the documented limit of this question.
		if lookup.kind == gsub_lookup_multiple {
			if seq := multiple_lookup(lookup.multiples, out) {
				if seq.len == 1 {
					out = seq[0]
				}
			}
		}
		// A font that keeps a shape in alternates rather than in a single substitution is asking
		// the same question and answering it with a list, and Arabic Typesetting does exactly
		// that for its final forms. Reading only the single kind would leave those letters
		// unjoined, with nothing in the output to say why.
		if lookup.kind == gsub_lookup_alternate {
			if sub := alternate_lookup(lookup.alternates, out) {
				out = sub
			}
		}
	}
	return out
}

// single_lookup finds the first rule that covers gid and returns the glyph it becomes.
pub fn single_lookup(subs []SingleSubst, gid u16) ?u16 {
	for s in subs {
		i := coverage_index(s.ranges, gid) or { continue }
		if s.subs.len > 0 {
			if i < s.subs.len {
				return s.subs[i]
			}
			// A coverage index past the replacement list means this rule is not usable, so
			// the next one gets a turn rather than a wrong glyph being drawn.
			continue
		}
		return u16(i32(gid) + s.delta)
	}
	return none
}

// alternate_lookup returns the alternate a covered glyph becomes, which for shaping is always the
// first one the font offers.
//
// A covered glyph with no usable alternates is passed over, for the same reason as everywhere else
// here: a rule that cannot be read is a rule that does not fire, and the next rule in the lookup
// still gets its turn.
pub fn alternate_lookup(subs []AlternateSubst, gid u16) ?u16 {
	for s in subs {
		i := coverage_index(s.ranges, gid) or { continue }
		if i < s.sets.len && s.sets[i].len > 0 {
			return s.sets[i][0]
		}
	}
	return none
}

// multiple_lookup finds the sequence a covered glyph becomes, or none when no rule covers it.
//
// A covered glyph whose sequence failed to parse is passed over rather than treated as covering
// nothing, which is the same choice the parser made when it left that entry empty: a rule that
// cannot be read is a rule that does not fire, and the next rule in the lookup still gets its turn.
pub fn multiple_lookup(subs []MultipleSubst, gid u16) ?[]u16 {
	for s in subs {
		i := coverage_index(s.ranges, gid) or { continue }
		if i < s.sequences.len && s.sequences[i].len > 0 {
			return s.sequences[i]
		}
	}
	return none
}

// coverage_index returns the position of a glyph in the coverage table, or none when the
// table does not cover it.
pub fn coverage_index(ranges []CoverageRange, gid u16) ?int {
	// The ranges are sorted by first glyph and do not overlap, which the format guarantees,
	// so a binary search is enough.
	mut lo := 0
	mut hi := ranges.len
	for lo < hi {
		mid := (lo + hi) >> 1
		range := ranges[mid]
		if gid < range.first {
			hi = mid
		} else if gid > range.last {
			lo = mid + 1
		} else {
			return range.start_index + int(gid - range.first)
		}
	}
	return none
}

// parse_multiple_subst reads one MultipleSubst subtable, which is the only format it has.
//
// The sequence list is indexed by coverage index, so a sequence that fails to parse is left empty
// rather than dropped. Dropping it would shift every later sequence against the wrong covered
// glyph, which is a wrong glyph drawn rather than a missing rule noticed.
pub fn parse_multiple_subst(r &Reader, at int) ?MultipleSubst {
	if r.u16_at(at) != 1 {
		return none
	}
	ranges := parse_coverage(r, at + int(r.u16_at(at + 2)))
	count := int(r.u16_at(at + 4))
	if ranges.len == 0 || count == 0 {
		return none
	}
	mut sequences := [][]u16{len: count}
	for i in 0 .. count {
		base := at + 6 + i * 2
		if !r.has(base, 2) {
			break
		}
		// A sequence offset is from the start of the subtable, not from its own entry.
		seq_at := at + int(r.u16_at(base))
		glyph_count := int(r.u16_at(seq_at))
		// A sequence of no glyphs would delete the character it stood for, which is not a thing
		// a font can mean, so it is refused rather than honoured.
		if glyph_count == 0 || !r.has(seq_at + 2, glyph_count * 2) {
			continue
		}
		mut seq := []u16{cap: glyph_count}
		for k in 0 .. glyph_count {
			seq << r.u16_at(seq_at + 2 + k * 2)
		}
		sequences[i] = seq
	}
	return MultipleSubst{
		ranges:    ranges
		sequences: sequences
	}
}

// parse_alternate_subst reads one AlternateSubst subtable, which is the only format it has.
//
// The set list is indexed by coverage index, so a set that fails to parse is left empty rather
// than dropped: dropping it would shift every later set against the wrong covered glyph, which is
// a wrong glyph drawn rather than a missing rule noticed.
pub fn parse_alternate_subst(r &Reader, at int) ?AlternateSubst {
	if r.u16_at(at) != 1 {
		return none
	}
	ranges := parse_coverage(r, at + int(r.u16_at(at + 2)))
	count := int(r.u16_at(at + 4))
	if ranges.len == 0 || count == 0 {
		return none
	}
	mut sets := [][]u16{len: count}
	for i in 0 .. count {
		base := at + 6 + i * 2
		if !r.has(base, 2) {
			break
		}
		// A set offset is from the start of the subtable, not from its own entry.
		set_at := at + int(r.u16_at(base))
		glyph_count := int(r.u16_at(set_at))
		// A set with no alternates offers a choice of nothing. The specification says a font may
		// write one to mean the glyph itself, so the glyph is the answer rather than no answer.
		if glyph_count == 0 || !r.has(set_at + 2, glyph_count * 2) {
			continue
		}
		mut set := []u16{cap: glyph_count}
		for k in 0 .. glyph_count {
			set << r.u16_at(set_at + 2 + k * 2)
		}
		sets[i] = set
	}
	return AlternateSubst{
		ranges: ranges
		sets:   sets
	}
}

// parse_single_subst reads one SingleSubst subtable in either of its two formats.
//
// The coverage is reached by an offset from the start of the subtable rather than stored
// inline, and where that offset sits is worth a note. The specification puts the coverage
// offset in the second field and the delta or glyph count in the third, so the header
// reads
//
//	substFormat, coverage, deltaGlyphID | glyphCount, substituteGlyphIDs[]
//
// and that reading is tried first. A reading with the two middle fields transposed is
// tried second, because a font that gets this wrong still renders in whatever consumes
// it and a text engine has no business being the one that draws the wrong glyph. In
// each case the coverage has to fit inside the table: the transposed reading of a
// spec-order table points into the coverage itself and parses a giant count out of it
// (Noto Bengali lookup 109 reads a count of 11748 and a delta of 11754 that way, turning
// raphalabeng into glyph 12033), so a coverage that runs past the buffer rejects the
// reading instead of drawing a wrong glyph.
pub fn parse_single_subst(r &Reader, at int) ?SingleSubst {
	format := r.u16_at(at)
	if format != 1 && format != 2 {
		return none
	}
	first := int(r.u16_at(at + 2))
	second := int(r.u16_at(at + 4))
	for pass in 0 .. 2 {
		cov_off := if pass == 0 { first } else { second }
		mid := if pass == 0 { second } else { first }
		if !coverage_fits(r, at + cov_off) {
			continue
		}
		ranges := parse_coverage(r, at + cov_off)
		if ranges.len == 0 {
			continue
		}
		if format == 1 {
			return SingleSubst{
				ranges: ranges
				delta:  i32(r.i16_at(at + 4 - pass * 2))
			}
		}
		// Format 2 pairs every covered glyph with a replacement, so the number of covered
		// glyphs has to match the length of the replacement list. That is also what settles
		// the two readings: a count that does not fit belongs to the wrong one.
		if mid <= 0 || mid > covered_count(ranges) {
			continue
		}
		// The replacement list follows the header in both readings, so it starts at the same
		// place either way.
		mut subs := []u16{cap: mid}
		for i in 0 .. mid {
			subs << r.u16_at(at + 6 + i * 2)
		}
		return SingleSubst{
			ranges: ranges
			subs:   subs
		}
	}
	return none
}
