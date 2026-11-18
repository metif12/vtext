module font

// ContextRecord is one positioning a chaining context performs once its pattern has matched: which
// of the input positions it applies to, and which lookup does the work.
//
// A record is a pair of indices and carries no value of its own. That is worth saying because the
// substitution side of the specification has a field here that looks like it belongs in a positioning
// record too, and reading it takes a word that belongs to this record instead. The whole thing then
// shifts by one, and the lookup index becomes whatever the sequence index should have been.
pub struct ContextRecord {
pub mut:
	// position is an index into the context's input sequence, and it is deliberately not an offset
	// into the glyph run: a rule matching three input glyphs can position the second of them and
	// leave the other two alone.
	position int
	// lookup is the lookup to run at that position, resolved against the same lookup list this
	// context came from.
	lookup u16
}

// ChainPosition is a chaining context in format 3: the pattern of glyphs before, at and after the
// position being positioned, given as coverage tables.
//
// Format 3 is the form most Arabic positioning rules use: coverage tables matched directly.
// Format 2 matches the same three sequences through glyph classes, which is what Amiri's
// kern chains are written in, and format 1 matches them through glyph ids, so all three
// are read.
pub struct ChainPosition {
pub mut:
	// backtrack are the coverages to match before the first input glyph, nearest first.
	backtrack [][]CoverageRange
	// input are the coverages to match at and after the position, the first being the one a record
	// with position zero positions.
	input [][]CoverageRange
	// lookahead are the coverages to match after the last input glyph, nearest first.
	lookahead [][]CoverageRange
	// records is the list of positioning actions to apply once the pattern has matched.
	records []ContextRecord
}

// ChainClassRule is one class-based chaining rule (format 2): the same three sequences as a
// coverage rule, named as glyph classes rather than coverage tables. The input list holds
// the classes after the first glyph, whose own class selected the rule set.
pub struct ChainClassRule {
pub mut:
	// backtrack are the classes to match before the first input glyph, nearest first.
	backtrack []u16
	// input are the classes to match at and after the position, past the first glyph.
	input []u16
	// lookahead are the classes to match after the last input glyph, nearest first.
	lookahead []u16
	// records is the list of positioning actions to apply once the pattern has matched.
	records []ContextRecord
}

// ChainClass2 is one class-based chaining subtable: three class definitions and, per input
// class value, the rules for a first glyph of that class. A NULL set offset parses to an
// empty rule list, kept positionally so later sets stay aligned with their class value.
pub struct ChainClass2 {
pub mut:
	// coverage names the glyphs the first input glyph may be; unlike the GSUB
	// cousin this format gates the match on it as well as on the class.
	coverage  []CoverageRange
	backtrack ClassDef
	input     ClassDef
	lookahead ClassDef
	sets      [][]ChainClassRule
}

// ChainGlyphRule is one glyph-based chaining rule (format 1): the same three
// sequences as a coverage or class rule, named as glyph ids rather than
// coverages or classes. The input list holds the glyphs after the first, whose
// own match is the coverage that selected the rule's set.
pub struct ChainGlyphRule {
pub mut:
	// backtrack are the glyphs before the first input glyph, nearest first.
	backtrack []u16
	// input are the glyphs after the first input glyph, in order.
	input []u16
	// lookahead are the glyphs after the last input glyph, nearest first.
	lookahead []u16
	// records is the list of positioning actions to apply once the pattern has matched.
	records []ContextRecord
}

// ChainGlyph1 is one glyph-based chaining subtable: a coverage for the first
// input glyph and one rule list per covered glyph, in coverage order. A NULL
// set offset is an empty rule list, kept positionally so later sets stay
// aligned with their coverage index.
pub struct ChainGlyph1 {
pub mut:
	// coverage names the glyphs the first input glyph may be.
	coverage []CoverageRange
	// sets holds the rules for a first glyph by its coverage index.
	sets [][]ChainGlyphRule
}

// parse_chain_position reads one ChainContextPos subtable in format 3.
//
// The header interleaves: a count, then that many coverage offsets, then the next count. Reading the
// three counts off the front instead gives an input count of eighteen on a rule that matches a single
// glyph, and every coverage offset after that points at a glyph range rather than at a table.
//
// The records are the second thing this has to get right, and the mistake is an obvious one to make
// because the substitution side of the specification has a field that looks like it belongs here. There
// is no posLookupCount: a record is a pair of indices and nothing else, and the second one names a
// lookup to run. Reading a count that is not there takes a word that belongs to the first record, which
// shifts every record by one and turns the lookup index into whatever the sequence index should have
// been. Tahoma's first rule names lookup 62, which with a one glyph pattern is a perfectly ordinary
// lookup number, and reading it as a format gives 62 as a mask instead.
// class_def_at reads the class definition at a subtable-relative offset, or an empty one
// when the offset is zero or points outside the table.
pub fn class_def_at(r &Reader, at int, off int) ClassDef {
	if off == 0 || !r.has(at + off, 2) {
		return ClassDef{}
	}
	return parse_class_def(r, at + off)
}

// parse_chain_class reads one class-based chaining subtable in format 2.
//
// Format 2 matches through classes plus the coverage above, and format 3 is the coverage
// reader below; format 1 matches through a coverage plus following glyph ids and is the
// glyph reader beside them. Class definitions are required; a zero
// offset parses to an empty table, whose every glyph is class zero — which is exactly
// what an absent definition means, since zero is the class of everything unnamed.
pub fn parse_chain_class(r &Reader, at int) ?ChainClass2 {
	if r.u16_at(at) != 2 {
		return none
	}
	if !r.has(at, 12) {
		return none
	}
	mut c := ChainClass2{}
	c.coverage = parse_coverage(r, at + int(r.u16_at(at + 2)))
	c.backtrack = class_def_at(r, at, int(r.u16_at(at + 4)))
	c.input = class_def_at(r, at, int(r.u16_at(at + 6)))
	c.lookahead = class_def_at(r, at, int(r.u16_at(at + 8)))
	set_count := int(r.u16_at(at + 10))
	if set_count < 0 || 12 + set_count * 2 > r.len() - at {
		return none
	}
	for si in 0 .. set_count {
		set_off := int(r.u16_at(at + 12 + si * 2))
		if set_off == 0 {
			c.sets << []ChainClassRule{}
			continue
		}
		set_at := at + set_off
		if !r.has(set_at, 2) {
			c.sets << []ChainClassRule{}
			continue
		}
		rule_count := int(r.u16_at(set_at))
		mut rules := []ChainClassRule{cap: rule_count}
		for ri in 0 .. rule_count {
			if !r.has(set_at + 2 + ri * 2, 2) {
				break
			}
			if rule := parse_chain_class_rule(r, set_at + int(r.u16_at(set_at + 2 + ri * 2))) {
				rules << rule
			}
		}
		c.sets << rules
	}
	return c
}

// parse_chain_class_rule reads one rule of a class set: class counts and lists for the
// three sequences, then the positioning records.
//
// The input count includes the first glyph, whose class selected this set, so the stored
// list holds every class after it. A rule that fails to parse is skipped rather than
// placed half-read: the next rule starts at its own offset, so one bad rule cannot shift
// the rest.
pub fn parse_chain_class_rule(r &Reader, at int) ?ChainClassRule {
	if !r.has(at, 2) {
		return none
	}
	back_count := int(r.u16_at(at))
	mut p := at + 2
	if back_count < 0 || back_count * 2 > r.len() - p {
		return none
	}
	mut rule := ChainClassRule{}
	for _ in 0 .. back_count {
		rule.backtrack << r.u16_at(p)
		p += 2
	}
	if !r.has(p, 2) {
		return none
	}
	in_count := int(r.u16_at(p))
	p += 2
	// One of the input glyphs is the covered first, so a count of zero names nothing to
	// match and the rule can never fire.
	if in_count < 1 || (in_count - 1) * 2 > r.len() - p {
		return none
	}
	for _ in 0 .. in_count - 1 {
		rule.input << r.u16_at(p)
		p += 2
	}
	if !r.has(p, 2) {
		return none
	}
	ahead_count := int(r.u16_at(p))
	p += 2
	if ahead_count < 0 || ahead_count * 2 > r.len() - p {
		return none
	}
	for _ in 0 .. ahead_count {
		rule.lookahead << r.u16_at(p)
		p += 2
	}
	if !r.has(p, 2) {
		return none
	}
	pos_count := int(r.u16_at(p))
	p += 2
	if pos_count < 0 || pos_count * 4 > r.len() - p {
		return none
	}
	for _ in 0 .. pos_count {
		rule.records << ContextRecord{
			position: int(r.u16_at(p))
			lookup:   r.u16_at(p + 2)
		}
		p += 4
	}
	return rule
}

// parse_chain_glyph reads one glyph-based chaining subtable in format 1.
//
// The sets are aligned with the coverage index the way GSUB's plain-context
// format 1 is: the covered first glyph selects its set, and a NULL set offset
// is an empty rule list kept positionally. Each rule names its three sequences
// as glyph ids, including every input glyph but the covered first.
pub fn parse_chain_glyph(r &Reader, at int) ?ChainGlyph1 {
	if r.u16_at(at) != 1 {
		return none
	}
	if !r.has(at, 8) {
		return none
	}
	mut c := ChainGlyph1{}
	c.coverage = parse_coverage(r, at + int(r.u16_at(at + 2)))
	set_count := int(r.u16_at(at + 4))
	if set_count < 0 || 6 + set_count * 2 > r.len() - at {
		return none
	}
	for si in 0 .. set_count {
		set_off := int(r.u16_at(at + 6 + si * 2))
		if set_off == 0 {
			c.sets << []ChainGlyphRule{}
			continue
		}
		set_at := at + set_off
		if !r.has(set_at, 2) {
			c.sets << []ChainGlyphRule{}
			continue
		}
		rule_count := int(r.u16_at(set_at))
		mut rules := []ChainGlyphRule{cap: rule_count}
		for ri in 0 .. rule_count {
			if !r.has(set_at + 2 + ri * 2, 2) {
				break
			}
			if rule := parse_chain_glyph_rule(r, set_at + int(r.u16_at(set_at + 2 + ri * 2))) {
				rules << rule
			}
		}
		c.sets << rules
	}
	return c
}

// parse_chain_glyph_rule reads one rule of a glyph set: glyph-id lists for the
// three sequences, then the positioning records.
//
// The input count includes the covered first glyph, so the stored list holds
// every glyph after it. A rule that fails to parse is skipped rather than
// placed half-read: the next rule starts at its own offset, so one bad rule
// cannot shift the rest.
pub fn parse_chain_glyph_rule(r &Reader, at int) ?ChainGlyphRule {
	if !r.has(at, 2) {
		return none
	}
	back_count := int(r.u16_at(at))
	mut p := at + 2
	if back_count < 0 || back_count * 2 > r.len() - p {
		return none
	}
	mut rule := ChainGlyphRule{}
	for _ in 0 .. back_count {
		rule.backtrack << r.u16_at(p)
		p += 2
	}
	if !r.has(p, 2) {
		return none
	}
	in_count := int(r.u16_at(p))
	p += 2
	// One of the input glyphs is the covered first, so a count of zero names
	// nothing to match and the rule can never fire.
	if in_count < 1 || (in_count - 1) * 2 > r.len() - p {
		return none
	}
	for _ in 0 .. in_count - 1 {
		rule.input << r.u16_at(p)
		p += 2
	}
	if !r.has(p, 2) {
		return none
	}
	ahead_count := int(r.u16_at(p))
	p += 2
	if ahead_count < 0 || ahead_count * 2 > r.len() - p {
		return none
	}
	for _ in 0 .. ahead_count {
		rule.lookahead << r.u16_at(p)
		p += 2
	}
	if !r.has(p, 2) {
		return none
	}
	pos_count := int(r.u16_at(p))
	p += 2
	if pos_count < 0 || pos_count * 4 > r.len() - p {
		return none
	}
	for _ in 0 .. pos_count {
		rule.records << ContextRecord{
			position: int(r.u16_at(p))
			lookup:   r.u16_at(p + 2)
		}
		p += 4
	}
	return rule
}

pub fn parse_chain_position(r &Reader, at int) ?ChainPosition {
	if r.u16_at(at) != 3 {
		return none
	}
	mut c := ChainPosition{}
	mut p := at + 2

	// The three coverage lists, each a count followed by that many offsets from the subtable. The
	// same helper GSUB uses reads these, because the two formats lay them out identically.
	back := read_coverages(r, at, p)
	p = back.next
	c.backtrack = back.ranges
	inp := read_coverages(r, at, p)
	p = inp.next
	c.input = inp.ranges
	ahead := read_coverages(r, at, p)
	p = ahead.next
	c.lookahead = ahead.ranges
	if c.input.len == 0 {
		return none
	}

	pos_count := int(r.u16_at(p))
	p += 2
	// A count whose records cannot fit in what is left of the table is a font claiming more than it
	// has, and is refused rather than walked off the end.
	if pos_count <= 0 || pos_count * 4 > r.len() - p {
		return none
	}

	mut records := []ContextRecord{cap: pos_count}
	for _ in 0 .. pos_count {
		records << ContextRecord{
			position: int(r.u16_at(p))
			lookup:   r.u16_at(p + 2)
		}
		p += 4
	}
	c.records = records
	return c
}

// has_chain_classes reports whether a lookup holds any class-based chaining rule. An
// empty rule list positions nothing, and without this a lookup whose subtables all
// failed to parse would still claim the chaining type.
pub fn has_chain_classes(l &GposLookup) bool {
	for cc in l.chain_classes {
		for set in cc.sets {
			if set.len > 0 {
				return true
			}
		}
	}
	return false
}

// has_chain_glyphs reports whether a lookup holds any glyph-based chaining rule. An
// empty rule list positions nothing, and without this a lookup whose subtables all
// failed to parse would still claim the chaining type.
pub fn has_chain_glyphs(l &GposLookup) bool {
	for cg in l.chain_glyphs {
		for set in cg.sets {
			if set.len > 0 {
				return true
			}
		}
	}
	return false
}

// ChainApplication is one positioning a chaining context asks for, once its pattern has matched.
//
// It is resolved rather than raw: the record named a lookup and a glyph of the pattern, and this is
// that glyph's index in the run with the lookup that will move it. A caller applies it without knowing
// anything about contexts.
pub struct ChainApplication {
pub mut:
	// at is the index in the glyph run of the glyph to move.
	at int
	// lookup is the lookup to run at that glyph.
	lookup u16
}

// contextual_for returns the chaining-context lookups a script's features name.
//
// The features are the ones a font uses for this and the list is not the same for every font: a Latin
// font carries none at all, and an Arabic font carries them under calt, mark and mkmk depending on
// which of them has rules that need context. Asking per script rather than collecting once is what
// keeps a Latin lookup from being run over Arabic text. dist rides beside kern because Indic and
// Thai/Khmer faces kern their marks through it: Thai SARA U after 0331 and Khmer above-marks
// after a subscript resolve their chain SinglePos there, and HarfBuzz applies it over the anchor.
pub fn (g &Gpos) contextual_for(script string, lang string) []u16 {
	mut out := []u16{}
	mut named_lookups := map[u16]bool{}
	for tag in ['calt', 'mark', 'mkmk', 'abvm', 'blwm', 'rclt', 'curs', 'kern', 'dist'] {
		for li in g.lookups_for_lang(script, lang, tag) {
			if named_lookups[li] || li >= g.lookups.len {
				continue
			}
			// A feature may name a lookup that is not a context, and running a mark rule as if it
			// were one would move a mark with nothing having said it should.
			if g.lookups[li].chains.len == 0 && !has_chain_classes(g.lookups[li])
				&& !has_chain_glyphs(g.lookups[li]) {
				continue
			}
			named_lookups[li] = true
			out << li
		}
	}
	return out
}

// has_contextual_positioning reports whether the font positions a glyph based on what is around it,
// which is what a script with stacked forms needs and a Latin font does not.
pub fn (g &Gpos) has_contextual_positioning(script string, lang string) bool {
	for li in g.contextual_for(script, lang) {
		if li < g.lookups.len
			&& (g.lookups[li].chains.len > 0 || has_chain_classes(g.lookups[li])
				|| has_chain_glyphs(g.lookups[li])) {
			return true
		}
	}
	return false
}

// apply_pos_records answers one matched pattern by running its records: every record that
// names a positioning contributes, because matching lookups all apply, and the caller adds
// each pattern's answer into the pair's total for the same reason.
pub fn (g &Gpos) apply_pos_records(records []ContextRecord, m ChainMatchPositions, gids []u16,
	left int, right int, left_gid u16, right_gid u16) ?Offset2 {
	mut x := 0
	mut y := 0
	mut found := false
	for rec in records {
		if rec.position < 0 || rec.position >= m.positions.len {
			continue
		}
		target := int(rec.lookup)
		if target >= g.lookups.len {
			continue
		}
		// The lookup is asked about the glyph the record names, and then about the other of
		// the pair, because the two are not always the same glyph: a rule can match one letter
		// in order to say how to place the next one.
		named := gids[m.positions[rec.position]]
		mut other := right_gid
		if named != right_gid {
			other = left_gid
		}
		// A single positioning is the common case and is asked first, because a rule that moves
		// a glyph is what the font meant even when the same lookup also carries pair rules.
		mut placed_at := -1
		for si, rule in g.lookups[target].singles {
			if a := rule.offset_for(named) {
				x += a.x
				y += a.y
				found = true
				placed_at = si
				break
			}
			if named != other {
				if a := rule.offset_for(other) {
					x += a.x
					y += a.y
					found = true
					placed_at = si
					break
				}
			}
		}
		// A single positioning that carries only an advance adjusts the pen without
		// moving the glyph: Bengali kri widens its base by 200 through a dist
		// single nested in a chaining rule, and placement_of reports that
		// record as no rule at all. The fallback skips the rule that placed,
		// so a value carrying both (Andalus moves glyph 3 by -120 and also
		// narrows it by 120) still answers the placement alone, which is the
		// number the context-kern pin holds. Advances accumulate beside
		// placements across records, never inside one rule twice.
		for si, rule in g.lookups[target].singles {
			if si == placed_at {
				continue
			}
			if v := rule.value_for(named) {
				if v.format & 0x0004 != 0 {
					x += v.x_advance
					found = true
					break
				}
			}
			if named != other {
				if v := rule.value_for(other) {
					if v.format & 0x0004 != 0 {
						x += v.x_advance
						found = true
						break
					}
				}
			}
		}
		for rule in g.lookups[target].pairs {
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
	return Offset2{ x: x, y: y }
}

// context_offset returns what a rule under the kern feature says about a pair of adjacent glyphs in a
// run, where the answer may depend on what is around them.
//
// A record names a lookup, and that lookup's own kind is what decides the answer. This is the part
// worth writing down, because the name of the feature is misleading: a rule under kern is usually not a
// kerning rule. Across the Arabic fonts on this machine, of the records a kern feature reaches, 186 name
// a single positioning and 12 name a pair. Andalus is the clearest case: its first rule is "if one of
// glyphs 160 through 167 comes before glyph 3, apply lookup 21", and lookup 21 moves one glyph rather
// than closing a gap between two. Reading a record as though it named a pair finds no pair rule and
// answers nothing, on a font whose rules are working perfectly.
//
// The record's position says which glyph of the pattern it applies to, and the lookup then decides which
// glyph it covers. Those are two different things and they are not always the same glyph: this rule
// matches glyphs 160 to 167 followed by glyph 3, and asks lookup 21 to move something, and lookup 21
// covers glyph 3 rather than the 160s. So the answer is whichever of the pair the lookup covers, and
// asking only about the first glyph of the pattern misses every rule shaped like this one.
//
// The plain pair rules are answered first, because a rule that says one thing about a pair regardless of
// its surroundings is a more specific answer than one that says what to do only in a context, and a font
// may put both kinds under one feature.
//
// Both answers count when both exist: adjustments accumulate across lookups rather than stopping at
// the first, so a class-0 zero from the pairs does not hide a contextual kern for the same glyphs.
// e-f in Amiri is (0, 0) plain and -11 in context, and HarfBuzz draws the sum.
pub fn (g &Gpos) context_offset(gids []u16, left int, right int, script string, lang string, gdef ?&Gdef) ?Offset2 {
	if left < 0 || right >= gids.len || left >= right {
		return none
	}
	left_gid := gids[left]
	right_gid := gids[right]
	mut x := 0
	mut y := 0
	mut found := false
	if off := g.kern_offset(left_gid, right_gid, script, lang) {
		x += off.x
		y += off.y
		found = true
	}
	for li in g.kerning_for(script, lang) {
		if li >= g.lookups.len {
			continue
		}
		lookup := g.lookups[li]
		// A lookup gated by USE_MARK_FILTERING_SET matches only its set's
		// marks: the effective sequence skips every other mark, so a
		// vocalic matra between HA and its rakar does not break the dist
		// rule written for the pair. Every other flag is ignored here, the
		// way it always was.
		eff := g.chain_eff(gids, lookup.flag, lookup.mark_filtering_set, gdef)
		if eff.len == 0 {
			continue
		}
		skipped := gids.len - eff.len
		for c in lookup.chains {
			// The pattern is tried at every effective position from which
			// it could reach both of the pair: the run window of the old
			// walk widened by the skipped count, because each skipped mark
			// stretches the run further than the pattern counts.
			mut first := left - c.backtrack.len - skipped
			if first < 0 {
				first = 0
			}
			mut last := right + c.lookahead.len + skipped
			if last > gids.len - 1 {
				last = gids.len - 1
			}
			for ei in 0 .. eff.len {
				if eff[ei] < first || eff[ei] > last {
					continue
				}
				m := match_chain_position(c, gids, eff, ei)
				if m.start < 0 {
					continue
				}
				// A pattern that matched somewhere else in the run is not this pair's rule, and the
				// only thing that says so is whether it covers both of the glyphs the caller named.
				lo, hi := span_of(eff, ei, c.backtrack.len, c.input.len, c.lookahead.len, m)
				if !spans_run(lo, hi, left, right) {
					continue
				}
				if a := g.apply_pos_records(c.records, m, gids, left, right, left_gid,
					right_gid) {
					x += a.x
					y += a.y
					found = true
				}
			}
		}
		for cc in lookup.chain_classes {
			// A class rule carries its own backtrack and lookahead lengths, so unlike the
			// coverage version there is no per-lookup window to narrow: every position is
			// tried and the matcher bounds-checks each sequence itself.
			for at in 0 .. eff.len {
				m, rule := g.match_chain_class_at(cc, gids, eff, at) or { continue }
				lo, hi := span_of(eff, at, rule.backtrack.len, rule.input.len + 1, rule.lookahead.len, m)
				if !spans_run(lo, hi, left, right) {
					continue
				}
				if a := g.apply_pos_records(rule.records, m, gids, left, right, left_gid,
					right_gid) {
					x += a.x
					y += a.y
					found = true
				}
			}
		}
		for cg in lookup.chain_glyphs {
			// A glyph rule carries its own backtrack and lookahead lengths, so like the
			// class version every position is tried and the matcher bounds-checks each
			// sequence itself.
			for at in 0 .. eff.len {
				m, rule := g.match_chain_glyph_at(cg, gids, eff, at) or { continue }
				lo, hi := span_of(eff, at, rule.backtrack.len, rule.input.len + 1, rule.lookahead.len, m)
				if !spans_run(lo, hi, left, right) {
					continue
				}
				if a := g.apply_pos_records(rule.records, m, gids, left, right, left_gid,
					right_gid) {
					x += a.x
					y += a.y
					found = true
				}
			}
		}
	}
	if !found {
		return none
	}
	return Offset2{ x: x, y: y }
}

// KernChainPair is one adjacent pair's chaining adjustment: the SinglePos
// placements the run's chaining kern lookups ask for, summed the way
// context_offset sums them for one pair. found tells a real zero from no
// rule at all, the same distinction context_offset's none carries.
pub struct KernChainPair {
pub mut:
	x     int
	y     int
	found bool
}

// kern_chain_offsets answers every adjacent pair's chaining adjustment in
// one run walk, which is what kern_pairs distributes to the advances.
//
// context_offset asks the same question one pair at a time and walks the
// whole run for each, which is quadratic in the run length: a
// thousand-pair line evaluates a thousand full runs. The matches do not
// depend on the pair — only the span filter and the record application
// do — so one walk collects every match and each match pays out to the
// pairs its span covers, with the same spans_run rule and the same
// apply_pos_records call context_offset would have made for that pair:
// spans_run over (p, p+1) holds exactly for p in [lo-1, hi].
pub fn (g &Gpos) kern_chain_offsets(gids []u16, script string, lang string, gdef ?&Gdef) []KernChainPair {
	mut out := []KernChainPair{cap: gids.len}
	if gids.len < 2 {
		return out
	}
	for _ in 0 .. gids.len - 1 {
		out << KernChainPair{}
	}
	for li in g.kerning_for(script, lang) {
		if li >= g.lookups.len {
			continue
		}
		lookup := g.lookups[li]
		eff := g.chain_eff(gids, lookup.flag, lookup.mark_filtering_set, gdef)
		if eff.len == 0 {
			continue
		}
		for c in lookup.chains {
			for at in 0 .. eff.len {
				m := match_chain_position(c, gids, eff, at)
				if m.start < 0 {
					continue
				}
				lo, hi := span_of(eff, at, c.backtrack.len, c.input.len, c.lookahead.len, m)
				g.kern_chain_pay(mut out, gids, c.records, m, lo, hi)
			}
		}
		for cc in lookup.chain_classes {
			for at in 0 .. eff.len {
				m, rule := g.match_chain_class_at(cc, gids, eff, at) or { continue }
				lo, hi := span_of(eff, at, rule.backtrack.len, rule.input.len + 1, rule.lookahead.len, m)
				g.kern_chain_pay(mut out, gids, rule.records, m, lo, hi)
			}
		}
		for cg in lookup.chain_glyphs {
			for at in 0 .. eff.len {
				m, rule := g.match_chain_glyph_at(cg, gids, eff, at) or { continue }
				lo, hi := span_of(eff, at, rule.backtrack.len, rule.input.len + 1, rule.lookahead.len, m)
				g.kern_chain_pay(mut out, gids, rule.records, m, lo, hi)
			}
		}
	}
	return out
}

// kern_chain_pay adds one matched pattern's records to every adjacent pair
// the match's span covers: the pairs context_offset would claim it for.
fn (g &Gpos) kern_chain_pay(mut out []KernChainPair, gids []u16, records []ContextRecord, m ChainMatchPositions, lo int, hi int) {
	mut first := lo - 1
	if first < 0 {
		first = 0
	}
	mut last := hi
	if last > gids.len - 2 {
		last = gids.len - 2
	}
	for p := first; p <= last; p++ {
		if a := g.apply_pos_records(records, m, gids, p, p + 1, gids[p], gids[p + 1]) {
			out[p].x += a.x
			out[p].y += a.y
			out[p].found = true
		}
	}
}

// spans_run reports whether a matched pattern is about the pair the caller
// named, from the run indices of its first and last covered glyph. It is
// the effective-sequence form of spans_span below: where a gated lookup
// skips marks, backtrack and lookahead lengths count participating glyphs
// rather than run positions, so the span is read off the match instead of
// computed from the lengths.
//
// The check is one or the other rather than both, and that is the
// distinction worth writing down: a pattern naming both glyphs is about the
// pair, and a pattern naming one and reaching the other as its context is
// about one of them with a condition. Requiring both would throw away every
// rule with a backtrack, and requiring neither would let any rule in the run
// apply to any pair.
pub fn spans_run(lo int, hi int, left int, right int) bool {
	return (left >= lo && left <= hi) || (right >= lo && right <= hi)
}

// span_of answers the run indices of the first and last glyph a match
// covers: the backtrack and lookahead ends in the effective sequence the
// match was tried at, or the input ends when the pattern names none.
fn span_of(eff []int, at int, back int, input int, ahead int, m ChainMatchPositions) (int, int) {
	lo := if back > 0 { eff[at - back] } else { m.start }
	mut hi := m.positions[m.positions.len - 1]
	if ahead > 0 {
		hi = eff[at + input + ahead - 1]
	}
	return lo, hi
}

// chain_eff lists the glyphs of a run that take part in one lookup's
// chaining match, as indices into the run.
//
// A lookup gated by USE_MARK_FILTERING_SET matches only its set's marks:
// every other mark is skipped the way the GSUB matcher skips ignored
// marks, so a vocalic matra between HA and its rakar does not break the
// dist rule written for the pair. Without the flag — or without a GDEF to
// test membership — every glyph takes part, which is what every lookup did
// before this gate.
fn (g &Gpos) chain_eff(gids []u16, flag u16, mark_set u16, gdef ?&Gdef) []int {
	mut out := []int{cap: gids.len}
	for i in 0 .. gids.len {
		out << i
	}
	if flag & 0x0010 == 0 {
		return out
	}
	if gd := gdef {
		mut kept := []int{cap: gids.len}
		for i, gid in gids {
			if gd.is_mark(gid) && !gpos_mark_in_set(g.mark_sets, mark_set, gid) {
				continue
			}
			kept << i
		}
		return kept
	}
	return out
}

// spans_pair reports whether a matched pattern is about the pair the caller named.
//
// A pattern reaches further than the pair it is about: a backtrack glyph sits before it and a lookahead
// glyph after it. So the rule is this pair's rule when the span the pattern covers, from its first
// input glyph back by the number of backtrack glyphs to its last forward by the lookahead ones, includes
// either of the two named glyphs. A pattern of one glyph with one backtrack covers two positions, and
// the pair the caller asked about is inside them.
//
// The check is one or the other rather than both, and that is the distinction worth writing down: a
// pattern naming both glyphs is about the pair, and a pattern naming one and reaching the other as its
// context is about one of them with a condition. Requiring both would throw away every rule with a
// backtrack, and requiring neither would let any rule in the run apply to any pair.
pub fn spans_pair(c &ChainPosition, m ChainMatchPositions, left int, right int) bool {
	return spans_span(c.backtrack.len, c.lookahead.len, m, left, right)
}

// spans_span reports whether a matched pattern is about the pair the caller named, from the
// lengths of its backtrack and lookahead rather than from a coverage rule. Coverage and
// class patterns share it, because a span is a span whichever table named it.
pub fn spans_span(backtrack_len int, lookahead_len int, m ChainMatchPositions, left int, right int) bool {
	if m.start < 0 || m.positions.len == 0 {
		return false
	}
	mut lo := m.start - backtrack_len
	if lo < 0 {
		lo = 0
	}
	return spans_run(lo, m.positions[m.positions.len - 1] + lookahead_len, left, right)
}

// apply_contextual walks a glyph run and returns every positioning a chaining context asks for.
//
// gids is the run in logical order, which is the order the context's pattern is written in: a rule's
// backtrack list reads backwards from the position and its lookahead list reads forwards, and neither
// reverses for a right-to-left run, because the flag is about the order lookups are applied in rather
// than the order a font writes its pattern in.
//
// A glyph is reported at most once. Two rules can both match at the same position and both want to
// move it, and which one wins is the order the lookups are applied in, which the caller owns; this
// returns what each rule asks for and lets the caller decide.
pub fn (g &Gpos) apply_contextual(gids []u16, script string, lang string, gdef ?&Gdef) []ChainApplication {
	mut out := []ChainApplication{}
	if gids.len == 0 {
		return out
	}
	// The rules are tried in the order the features name them, and within a lookup in the order the
	// subtables are written, because a later one is meant to override an earlier one and the caller
	// cannot know that unless the order is preserved.
	for li in g.contextual_for(script, lang) {
		if li >= g.lookups.len {
			continue
		}
		lookup := g.lookups[li]
		eff := g.chain_eff(gids, lookup.flag, lookup.mark_filtering_set, gdef)
		if eff.len == 0 {
			continue
		}
		for c in lookup.chains {
			for at in 0 .. eff.len {
				m := match_chain_position(c, gids, eff, at)
				if m.start < 0 {
					continue
				}
				for rec in c.records {
					if rec.position < 0 || rec.position >= m.positions.len {
						continue
					}
					out << ChainApplication{
						at:     m.positions[rec.position]
						lookup: rec.lookup
					}
				}
			}
		}
		for cc in lookup.chain_classes {
			for at in 0 .. eff.len {
				m, rule := g.match_chain_class_at(cc, gids, eff, at) or { continue }
				for rec in rule.records {
					if rec.position < 0 || rec.position >= m.positions.len {
						continue
					}
					out << ChainApplication{
						at:     m.positions[rec.position]
						lookup: rec.lookup
					}
				}
			}
		}
		for cg in lookup.chain_glyphs {
			for at in 0 .. eff.len {
				m, rule := g.match_chain_glyph_at(cg, gids, eff, at) or { continue }
				for rec in rule.records {
					if rec.position < 0 || rec.position >= m.positions.len {
						continue
					}
					out << ChainApplication{
						at:     m.positions[rec.position]
						lookup: rec.lookup
					}
				}
			}
		}
	}
	return out
}

// match_chain_position tests a context's pattern at one effective position in a glyph run.
//
// The backtrack and lookahead lists are written nearest glyph first and the input list runs forwards,
// and none of that changes with the writing direction. at is an index into eff, the run's
// participating glyphs, so a lookup that skips gated marks reads what HarfBuzz reads. The
// returned start and positions are indices into the run, in pattern order, so a record's
// position indexes straight into them.
pub fn match_chain_position(c &ChainPosition, gids []u16, eff []int, at int) ChainMatchPositions {
	if c.input.len == 0 || at < 0 || at + c.input.len > eff.len {
		return ChainMatchPositions{ start: -1 }
	}
	for k, cov in c.backtrack {
		back := at - 1 - k
		if back < 0 {
			return ChainMatchPositions{ start: -1 }
		}
		if coverage_index(cov, gids[eff[back]]) == none {
			return ChainMatchPositions{ start: -1 }
		}
	}
	// Positions are assigned by index rather than appended: the slice is made at its final length so
	// that a record naming position n reads position n and not the end of the list.
	mut positions := []int{len: c.input.len}
	for k, cov in c.input {
		if coverage_index(cov, gids[eff[at + k]]) == none {
			return ChainMatchPositions{ start: -1 }
		}
		positions[k] = eff[at + k]
	}
	for k, cov in c.lookahead {
		ahead := at + c.input.len + k
		if ahead >= eff.len {
			return ChainMatchPositions{ start: -1 }
		}
		if coverage_index(cov, gids[eff[ahead]]) == none {
			return ChainMatchPositions{ start: -1 }
		}
	}
	return ChainMatchPositions{ start: eff[at], positions: positions }
}

// match_chain_class_at tests every rule of a class subtable's selected set at one effective position.
// The coverage gates first — a glyph it does not name starts no rule — and then the input
// class of the glyph selects the set; the first rule whose three class sequences all
// match wins, with classes read off the subtable's own definitions —
// including class zero, which is every glyph no definition names.
//
// It returns the match together with the rule that matched, because the span check and the
// records both belong to the rule rather than to the subtable.
pub fn (g &Gpos) match_chain_class_at(cc &ChainClass2, gids []u16, eff []int, at int) ?(ChainMatchPositions, ChainClassRule) {
	_ = g
	if at < 0 || at >= eff.len {
		return none
	}
	if coverage_index(cc.coverage, gids[eff[at]]) == none {
		return none
	}
	ic := cc.input.class_of(gids[eff[at]])
	if ic >= cc.sets.len {
		return none
	}
	for rule in cc.sets[ic] {
		if m := match_class_rule(cc, rule, gids, eff, at) {
			return m, rule
		}
	}
	return none
}

// match_class_rule tests one class rule's three sequences at an effective position. Positions are run
// indices like the coverage matcher's, so a record's position indexes straight into them.
pub fn match_class_rule(cc &ChainClass2, rule &ChainClassRule, gids []u16, eff []int, at int) ?ChainMatchPositions {
	for k, class in rule.backtrack {
		back := at - 1 - k
		if back < 0 {
			return none
		}
		if cc.backtrack.class_of(gids[eff[back]]) != class {
			return none
		}
	}
	mut positions := [eff[at]]
	for k, class in rule.input {
		next := at + 1 + k
		if next >= eff.len {
			return none
		}
		if cc.input.class_of(gids[eff[next]]) != class {
			return none
		}
		positions << eff[next]
	}
	for k, class in rule.lookahead {
		ahead := at + 1 + rule.input.len + k
		if ahead >= eff.len {
			return none
		}
		if cc.lookahead.class_of(gids[eff[ahead]]) != class {
			return none
		}
	}
	return ChainMatchPositions{
		start:     eff[at]
		positions: positions
	}
}

// match_chain_glyph_at tests every rule of a glyph subtable's selected set at one effective position.
// The coverage gates first — a glyph it does not name starts no rule — and then the
// coverage index selects the set; the first rule whose three glyph-id sequences all
// match wins.
//
// It returns the match together with the rule that matched, because the span check and the
// records both belong to the rule rather than to the subtable.
pub fn (g &Gpos) match_chain_glyph_at(cg &ChainGlyph1, gids []u16, eff []int, at int) ?(ChainMatchPositions, ChainGlyphRule) {
	_ = g
	if at < 0 || at >= eff.len {
		return none
	}
	ci := coverage_index(cg.coverage, gids[eff[at]]) or { return none }
	if ci >= cg.sets.len {
		return none
	}
	for rule in cg.sets[ci] {
		if m := match_glyph_rule(rule, gids, eff, at) {
			return m, rule
		}
	}
	return none
}

// match_glyph_rule tests one glyph rule's three sequences at an effective position. Positions are run
// indices like the coverage matcher's, so a record's position indexes straight into them.
pub fn match_glyph_rule(rule &ChainGlyphRule, gids []u16, eff []int, at int) ?ChainMatchPositions {
	for k, gid in rule.backtrack {
		back := at - 1 - k
		if back < 0 {
			return none
		}
		if gids[eff[back]] != gid {
			return none
		}
	}
	mut positions := [eff[at]]
	for k, gid in rule.input {
		next := at + 1 + k
		if next >= eff.len {
			return none
		}
		if gids[eff[next]] != gid {
			return none
		}
		positions << eff[next]
	}
	for k, gid in rule.lookahead {
		ahead := at + 1 + rule.input.len + k
		if ahead >= eff.len {
			return none
		}
		if gids[eff[ahead]] != gid {
			return none
		}
	}
	return ChainMatchPositions{
		start:     eff[at]
		positions: positions
	}
}

// ChainMatchPositions is a context pattern that has matched and where in the run it matched.
pub struct ChainMatchPositions {
pub mut:
	// start is the index of the first input glyph, or negative when nothing matched.
	start int
	// positions are the indices of every input glyph, in pattern order.
	positions []int
}
