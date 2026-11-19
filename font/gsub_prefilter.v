module font

// GidSet is the set of glyph ids in one run at one moment, as a bitset:
// bit gid is set when the run holds that glyph. 64K glyphs need 8KB, one
// memset to clear, one byte op to mark or test.
//
// It answers the only question the substitution pre-filter asks: does any
// glyph of the run fall in this lookup's first-position coverage? A lookup
// whose answer is no cannot match anywhere in the run — every apply path
// coverage-gates position zero first — so the whole walk over the run,
// including the effective-sequence scan that opens it, is skipped.
struct GidSet {
mut:
	bits []u8
}

// new_gid_set answers an empty set, cleared and ready to mark.
fn new_gid_set() GidSet {
	return GidSet{
		bits: []u8{len: 8192}
	}
}

// clear empties the set for the next run. The bits are zeroed rather than
// tracked because a run holds up to thousands of glyphs and tracking them
// costs the same as the memset it would avoid.
fn (mut s GidSet) clear() {
	for i in 0 .. s.bits.len {
		s.bits[i] = 0
	}
}

// mark records one glyph id in the set.
fn (mut s GidSet) mark(gid u16) {
	s.bits[int(gid) >> 3] |= u8(1 << (int(gid) & 7))
}

// has reports whether the set holds this glyph id.
fn (s &GidSet) has(gid u16) bool {
	return s.bits[int(gid) >> 3] & u8(1 << (int(gid) & 7)) != 0
}

// touches reports whether any glyph of the set falls in any of these
// coverage ranges. The ranges are sorted and disjoint, so each is one
// bounded byte-span check: the first and last bytes masked to the range
// edges, the bytes between read whole.
fn (s &GidSet) touches(ranges []CoverageRange) bool {
	for r in ranges {
		start := int(r.first)
		end := int(r.last)
		if start > end {
			continue
		}
		first_byte := start >> 3
		last_byte := end >> 3
		if first_byte == last_byte {
			mask := (0xff << (start & 7)) & (0xff >> (7 - (end & 7)))
			if int(s.bits[first_byte]) & mask != 0 {
				return true
			}
			continue
		}
		if int(s.bits[first_byte]) & (0xff << (start & 7)) != 0 {
			return true
		}
		if int(s.bits[last_byte]) & (0xff >> (7 - (end & 7))) != 0 {
			return true
		}
		for b in first_byte + 1 .. last_byte {
			if s.bits[b] != 0 {
				return true
			}
		}
	}
	return false
}

// lookup_touches_run reports whether this lookup's first-position coverage
// names any glyph the run holds. A miss means the walk cannot substitute
// anywhere: singles, multiples, alternates and ligatures all resolve
// position zero through their coverage, and every context and chaining
// matcher coverage-gates position zero before reading anything else.
//
// A lookup with no readable first coverage answers true and runs as
// before: skipping is an optimization, and an unrecognized table shape
// keeps the old path rather than inventing a new miss.
fn (g &Gsub) lookup_touches_run(li u16, set &GidSet) bool {
	if int(li) >= g.lookups.len {
		return true
	}
	lookup := g.lookups[li]
	if lookup.kind == gsub_lookup_single {
		for s in lookup.singles {
			if set.touches(s.ranges) {
				return true
			}
		}
		return false
	}
	if lookup.kind == gsub_lookup_multiple {
		for m in lookup.multiples {
			if set.touches(m.ranges) {
				return true
			}
		}
		return false
	}
	if lookup.kind == gsub_lookup_alternate {
		for a in lookup.alternates {
			if set.touches(a.ranges) {
				return true
			}
		}
		return false
	}
	if lookup.kind == gsub_lookup_ligature {
		for ls in lookup.ligatures {
			if set.has(ls.first) {
				return true
			}
		}
		return false
	}
	if lookup.kind == gsub_lookup_context {
		if set.touches(lookup.context_coverage) {
			return true
		}
		for cc in lookup.context_classes {
			if set.touches(cc.coverage) {
				return true
			}
		}
		// A class subtable whose coverage is empty still gates on it:
		// match_context_class_at names no rule without a covered glyph,
		// so nothing is lost by skipping.
		return false
	}
	if lookup.kind == gsub_lookup_chain_context {
		for c in lookup.chains {
			if c.input.len > 0 && set.touches(c.input[0]) {
				return true
			}
		}
		for cg in lookup.chain_glyphs {
			if set.touches(cg.coverage) {
				return true
			}
		}
		for cc in lookup.chain_classes {
			if set.touches(cc.coverage) {
				return true
			}
		}
		return false
	}
	return true
}
