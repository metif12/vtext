module font

// ChainRecord is one substitution a chaining context performs once its pattern has matched: which
// of the input positions it applies to, and which lookup does the work.
pub struct ChainRecord {
pub mut:
	// position is an index into the context's input sequence. It is deliberately not an offset
	// into the glyph run, so a rule matching three input glyphs can substitute the second of
	// them and leave the other two alone.
	position int
	// lookup is the index of the lookup to run at that position, resolved against the same
	// lookup list this context came from.
	lookup u16
}

// Context1 is one plain context (type 5) subtable in format 1: a coverage naming the
// first glyph and, per covered glyph, the rules for what follows it.
//
// Format 1 names glyphs directly, which is why it needs no class definition: the input
// is a list of glyph ids matched in order against the run, and the records name the
// lookups to run at each matched position. Formats 2 and 3 match through classes and
// are not read. The one format-1 rule in the corpus is Noto Nastaliq's lam-alef:
// coverage lam-medi/lam-init, input alef-fina, lookup 0 at both positions, which is
// what turns the pair into the .LA forms HarfBuzz draws.
pub struct ContextRule {
pub mut:
	// input are the glyphs after the first, matched in order.
	input []u16
	// records are the lookups to run at the matched positions, position zero being
	// the covered glyph itself.
	records []ChainRecord
}

// ContextClassRule is one class-based plain-context rule (type 5, format 2): the
// same three-part idea as a plain rule, with classes in place of glyphs. The input
// list holds the classes after the first glyph, whose own class selected the rule
// set it came from.
pub struct ContextClassRule {
pub mut:
	// input are the classes after the first input glyph, in order.
	input []u16
	// records are the lookups to run at the matched positions, position zero being
	// the covered glyph itself.
	records []ChainRecord
}

// ContextClass2 is one class-based plain-context subtable (type 5, format 2): a
// coverage for the first input glyph, one class definition, and one rule list per
// input class value. A NULL set offset is an empty rule list, kept positionally so
// later sets stay aligned with their class value.
pub struct ContextClass2 {
pub mut:
	// coverage names the glyphs the first input glyph may be.
	coverage []CoverageRange
	// input is the class definition the first glyph and every following one are
	// read against.
	input ClassDef
	// sets holds the rules for a first glyph by its coverage index.
	sets [][]ContextClassRule
}

// ChainContext3 is a chaining context in format 3: the pattern of glyphs before, at and after the
// position being substituted, given as coverage tables.
//
// Format 3 is the form every Arabic font this engine reads uses, and the reason is that it is the
// only context form needing neither a class definition nor an indirection. It names coverage
// tables directly, so matching it is a run of binary searches with no second lookup step.
// Formats 1 and 2 match the same three sequences through glyph ids and glyph classes;
// they are read too, each in its own tables beside this one.
pub struct ChainContext3 {
pub mut:
	// backtrack are the coverages to match before the first input glyph, nearest first.
	backtrack [][]CoverageRange
	// input are the coverages to match at and after the position, the first being the one a
	// record with position zero substitutes.
	input [][]CoverageRange
	// lookahead are the coverages to match after the last input glyph, nearest first.
	lookahead [][]CoverageRange
	records   []ChainRecord
}

// GlyphChainRule is one glyph-based chaining rule (format 1 of lookup type 6): the same
// three sequences as a coverage or class rule, named as glyph ids. The input list holds
// the glyphs after the covered first, whose own match is the coverage that selected
// the rule's set.
pub struct GlyphChainRule {
pub mut:
	// backtrack are the glyphs before the first input glyph, nearest first.
	backtrack []u16
	// input are the glyphs after the first input glyph, in order.
	input []u16
	// lookahead are the glyphs after the last input glyph, nearest first.
	lookahead []u16
	// records is the list of substitutions to apply once the pattern has matched.
	records []ChainRecord
}

// ChainGlyphSub1 is one glyph-based chaining subtable (type 6, format 1): a coverage
// for the first input glyph and one rule list per covered glyph, in coverage order.
// A NULL set offset is an empty rule list, kept positionally so later sets stay
// aligned with their coverage index.
pub struct ChainGlyphSub1 {
pub mut:
	// coverage names the glyphs the first input glyph may be.
	coverage []CoverageRange
	// sets holds the rules for a first glyph by its coverage index.
	sets [][]GlyphChainRule
}

// ClassChainRule is one class-based chaining rule (format 2 of lookup type 6): the
// same three sequences, named as glyph classes. The input list holds the classes
// after the first glyph, whose own class selected the rule set it came from.
pub struct ClassChainRule {
pub mut:
	// backtrack are the classes before the first input glyph, nearest first.
	backtrack []u16
	// input are the classes after the first input glyph, in order.
	input []u16
	// lookahead are the classes after the last input glyph, nearest first.
	lookahead []u16
	// records is the list of substitutions to apply once the pattern has matched.
	records []ChainRecord
}

// ChainClassSub2 is one class-based chaining subtable (type 6, format 2): three class
// definitions and, per input class value, the rules for a first glyph of that class.
// A NULL set offset parses to an empty rule list, kept positionally so later sets
// stay aligned with their class value.
pub struct ChainClassSub2 {
pub mut:
	// coverage names the glyphs the first input glyph may be; like the class-based
	// positioning reader, this format gates the match on it as well as on the class.
	coverage  []CoverageRange
	backtrack ClassDef
	input     ClassDef
	lookahead ClassDef
	sets      [][]ClassChainRule
}

// ChainMatch is a chaining context that has found its pattern, and where in the run it is.
pub struct ChainMatch {
pub mut:
	// start is the index in the glyph list of the first input glyph.
	start int
	// positions are the indices in the glyph list of every input glyph, in pattern order, so a
	// record's position indexes straight into this.
	positions []int
	// consumed is how many glyphs the pattern spanned in total, which is the furthest input
	// glyph reached to rather than the furthest of any lookahead.
	consumed int
}

// apply_records runs a matched context's records against the run. Records run from the
// last input position backwards, which is what lets each one be run against the run as
// it stands: every edit made so far was at a higher index, and changing the length of a
// list after an index does not move that index. Both chaining and plain contexts share
// it, because a matched pattern is a matched pattern whichever table named it.
//
// A nested lookup reads the run from its own position onward, not a single
// glyph: a chaining record that nests a ligature (Bengali cjct fusing
// consonant, halant, consonant through lookup 56) has to see the components
// that follow, and a one-glyph window starves every multi-glyph match while
// changing nothing for the single substitutions the window was written for.
pub fn (g &Gsub) apply_records(records []ChainRecord, m ChainMatch, items []Ligatable,
	eff []int, depth int) ?Substitution {
	mut work := items
	mut edits := []Edit{}
	for record in records {
		if record.position >= m.positions.len {
			continue
		}
		pos := m.positions[record.position]
		if pos < 0 || pos >= work.len {
			continue
		}
		mut start := eff.len
		for k, e in eff {
			if e == pos {
				start = k
				break
			}
		}
		if start >= eff.len {
			continue
		}
		if sub := g.apply_at(record.lookup, work, eff[start..], 0, depth + 1) {
			for e in sub.edits {
				edits << e
			}
			work = splice(work, sub)
		}
	}
	if edits.len > 0 {
		return Substitution{ edits: edits }
	}
	return none
}

// apply_chain runs a chaining context's records against the run once its pattern has matched.
//
// The first subtable whose pattern matches claims the glyph, even when it names no
// records at all: a no-op match still ends the search. MS Gothic's ccmp keeps a
// rule that expands a dakuten into a dotted circle plus the mark behind a rule
// that matches a dakuten after any of 127 bases and names nothing, and trying on
// past the no-op draws the dotted circle on every composed kana exactly as
// HarfBuzz does not.
pub fn (g &Gsub) apply_chain(lookup Lookup, items []Ligatable, eff []int, at int,
	depth int) ?Substitution {
	for chain in lookup.chains {
		if m := g.match_chain_at(chain, eff, items, at) {
			return g.apply_records(chain.records, m, items, eff, depth)
		}
	}
	for cg in lookup.chain_glyphs {
		if m, rule := g.match_chain_glyph_at(cg, eff, items, at) {
			return g.apply_records(rule.records, m, items, eff, depth)
		}
	}
	for cc in lookup.chain_classes {
		if m, rule := g.match_chain_class_at(cc, eff, items, at) {
			return g.apply_records(rule.records, m, items, eff, depth)
		}
	}
	return none
}

// apply_context runs a plain context's rules against the run: the first rule whose input
// follows the covered glyph wins, and its records run through the same path as a chain's.
pub fn (g &Gsub) apply_context(lookup Lookup, items []Ligatable, eff []int, at int,
	depth int) ?Substitution {
	if at < 0 || at >= eff.len {
		return none
	}
	// The coverage selects the format-1 set the way the class selects the format-2 one
	// below: a glyph it does not name starts no format-1 rule, but the class subtables
	// still get their turn, because a lookup that only carries format 2 has an empty
	// coverage and every glyph misses it.
	if ci := coverage_index(lookup.context_coverage, items[eff[at]].gid) {
		if ci < lookup.context_sets.len {
			for rule in lookup.context_sets[ci] {
				if m := g.match_context_at(rule, eff, items, at) {
					return g.apply_records(rule.records, m, items, eff, depth)
				}
			}
		}
	}
	for cc in lookup.context_classes {
		if m, rule := g.match_context_class_at(cc, eff, items, at) {
			return g.apply_records(rule.records, m, items, eff, depth)
		}
	}
	return none
}

// match_context_at tests one plain-context rule at one effective position: the covered
// glyph is already known to match, so the rule's input list is checked against the glyphs
// that follow it, in order, with nothing skipped that the effective sequence kept.
pub fn (g &Gsub) match_context_at(rule &ContextRule, eff []int, items []Ligatable,
	at int) ?ChainMatch {
	if at + rule.input.len + 1 > eff.len {
		return none
	}
	mut positions := []int{cap: rule.input.len + 1}
	positions << at
	for k, gid in rule.input {
		if items[eff[at + 1 + k]].gid != gid {
			return none
		}
		positions << at + 1 + k
	}
	return ChainMatch{
		start:     at
		positions: positions
		consumed:  rule.input.len + 1
	}
}

// match_chain_at tests a context's pattern at one effective position.
//
// The backtrack and lookahead lists are both written nearest glyph first, in logical order, and
// that does not change with the right to left flag: the flag is about the order substitutions are
// applied in, not about the order a font writes its pattern in.
pub fn (g &Gsub) match_chain_at(c &ChainContext3, eff []int, items []Ligatable,
	at int) ?ChainMatch {
	if c.input.len == 0 || at + c.input.len > eff.len {
		return none
	}
	for k, cov in c.backtrack {
		back := at - 1 - k
		if back < 0 {
			return none
		}
		if coverage_index(cov, items[eff[back]].gid) == none {
			return none
		}
	}
	// The input is checked before the positions are collected, and that order is the point rather than
	// taste. A chaining rule is tried at every position of every run, and almost every one of those
	// tries fails, so collecting the positions first meant allocating a slice to discover that the very
	// first glyph was not in the coverage. The checks read the same glyphs in the same order either
	// way; only the allocation moved behind them.
	for k, cov in c.input {
		if coverage_index(cov, items[eff[at + k]].gid) == none {
			return none
		}
	}
	for k, cov in c.lookahead {
		ahead := at + c.input.len + k
		if ahead >= eff.len {
			return none
		}
		if coverage_index(cov, items[eff[ahead]].gid) == none {
			return none
		}
	}
	// Positions are assigned by index rather than appended: the slice is made at its final length
	// so that a record naming position n reads position n and not the end of the list.
	mut positions := []int{len: c.input.len}
	for k in 0 .. c.input.len {
		positions[k] = eff[at + k]
	}
	return ChainMatch{
		start:     positions[0]
		positions: positions
		consumed:  positions[c.input.len - 1] - positions[0] + 1
	}
}

// match_context_class_at tests every rule of a class subtable's selected set at one effective
// position. The coverage gates first — a glyph it does not name starts no rule — and then the
// input class of the glyph selects the set; the first rule whose input classes all match
// wins. The covered glyph is already known to match, so the rule's input list is checked
// against the glyphs that follow it.
//
// It returns the match together with the rule that matched, because the records belong to
// the rule rather than to the subtable.
pub fn (g &Gsub) match_context_class_at(cc &ContextClass2, eff []int, items []Ligatable,
	at int) ?(ChainMatch, ContextClassRule) {
	_ = g
	if at < 0 || at >= eff.len {
		return none
	}
	if coverage_index(cc.coverage, items[eff[at]].gid) == none {
		return none
	}
	ic := cc.input.class_of(items[eff[at]].gid)
	if ic >= cc.sets.len {
		return none
	}
	for rule in cc.sets[ic] {
		if at + rule.input.len + 1 > eff.len {
			continue
		}
		mut ok := true
		for k, class in rule.input {
			if cc.input.class_of(items[eff[at + 1 + k]].gid) != class {
				ok = false
				break
			}
		}
		if !ok {
			continue
		}
		mut positions := []int{cap: rule.input.len + 1}
		positions << at
		for k in 0 .. rule.input.len {
			positions << at + 1 + k
		}
		return ChainMatch{
			start:     at
			positions: positions
			consumed:  rule.input.len + 1
		}, rule
	}
	return none
}

// match_chain_glyph_at tests every rule of a glyph subtable's selected set at one effective
// position. The coverage gates first — a glyph it does not name starts no rule — and then
// the coverage index selects the set; the first rule whose three glyph-id sequences all
// match wins.
//
// It returns the match together with the rule that matched, because the span check and
// the records both belong to the rule rather than to the subtable.
pub fn (g &Gsub) match_chain_glyph_at(cg &ChainGlyphSub1, eff []int, items []Ligatable,
	at int) ?(ChainMatch, GlyphChainRule) {
	_ = g
	if at < 0 || at >= eff.len {
		return none
	}
	ci := coverage_index(cg.coverage, items[eff[at]].gid) or { return none }
	if ci >= cg.sets.len {
		return none
	}
	for rule in cg.sets[ci] {
		if m := match_glyph_chain_rule(rule, eff, items, at) {
			return m, rule
		}
	}
	return none
}

// match_glyph_chain_rule tests one glyph rule's three sequences at one effective position:
// backtrack nearest glyph first, then the input glyphs after the covered first, then the
// lookahead. Positions are run indices like the coverage matcher's, so a record's position
// indexes straight into them.
pub fn match_glyph_chain_rule(rule &GlyphChainRule, eff []int, items []Ligatable, at int) ?ChainMatch {
	for k, gid in rule.backtrack {
		back := at - 1 - k
		if back < 0 {
			return none
		}
		if items[eff[back]].gid != gid {
			return none
		}
	}
	if at + rule.input.len + 1 > eff.len {
		return none
	}
	for k, gid in rule.input {
		if items[eff[at + 1 + k]].gid != gid {
			return none
		}
	}
	for k, gid in rule.lookahead {
		ahead := at + 1 + rule.input.len + k
		if ahead >= eff.len {
			return none
		}
		if items[eff[ahead]].gid != gid {
			return none
		}
	}
	mut positions := []int{cap: rule.input.len + 1}
	positions << at
	for k in 0 .. rule.input.len {
		positions << at + 1 + k
	}
	return ChainMatch{
		start:     at
		positions: positions
		consumed:  rule.input.len + 1
	}
}

// match_chain_class_at tests every rule of a class subtable's selected set at one effective
// position. The coverage gates first — a glyph it does not name starts no rule — and then
// the input class of the glyph selects the set; the first rule whose three class sequences
// all match wins.
//
// It returns the match together with the rule that matched, because the span check and
// the records both belong to the rule rather than to the subtable.
pub fn (g &Gsub) match_chain_class_at(cc &ChainClassSub2, eff []int, items []Ligatable,
	at int) ?(ChainMatch, ClassChainRule) {
	_ = g
	if at < 0 || at >= eff.len {
		return none
	}
	if coverage_index(cc.coverage, items[eff[at]].gid) == none {
		return none
	}
	ic := cc.input.class_of(items[eff[at]].gid)
	if ic >= cc.sets.len {
		return none
	}
	for rule in cc.sets[ic] {
		if m := match_class_chain_rule(cc, rule, eff, items, at) {
			return m, rule
		}
	}
	return none
}

// match_class_chain_rule tests one class rule's three sequences at one effective position:
// backtrack classes nearest first, then the input classes after the covered first, then
// the lookahead classes. Positions are run indices like the coverage matcher's, so a
// record's position indexes straight into them.
pub fn match_class_chain_rule(cc &ChainClassSub2, rule &ClassChainRule, eff []int,
	items []Ligatable, at int) ?ChainMatch {
	for k, class in rule.backtrack {
		back := at - 1 - k
		if back < 0 {
			return none
		}
		if cc.backtrack.class_of(items[eff[back]].gid) != class {
			return none
		}
	}
	if at + rule.input.len + 1 > eff.len {
		return none
	}
	for k, class in rule.input {
		if cc.input.class_of(items[eff[at + 1 + k]].gid) != class {
			return none
		}
	}
	for k, class in rule.lookahead {
		ahead := at + 1 + rule.input.len + k
		if ahead >= eff.len {
			return none
		}
		if cc.lookahead.class_of(items[eff[ahead]].gid) != class {
			return none
		}
	}
	mut positions := []int{cap: rule.input.len + 1}
	positions << at
	for k in 0 .. rule.input.len {
		positions << at + 1 + k
	}
	return ChainMatch{
		start:     at
		positions: positions
		consumed:  rule.input.len + 1
	}
}

// parse_context1 reads one plain ContextSubst subtable in format 1.
//
// Only format 1 is read: formats 2 and 3 match through glyph classes, and no font
// here reaches for them. A NULL rule set offset is an empty rule list, kept
// positionally so later sets stay aligned with their coverage index.
pub fn parse_context1(r &Reader, at int) ?Lookup {
	if r.u16_at(at) != 1 {
		return none
	}
	mut out := Lookup{ kind: gsub_lookup_context }
	out.context_coverage = parse_coverage(r, at + int(r.u16_at(at + 2)))
	set_count := int(r.u16_at(at + 4))
	if set_count < 0 || 6 + set_count * 2 > r.len() - at {
		return none
	}
	for si in 0 .. set_count {
		set_off := int(r.u16_at(at + 6 + si * 2))
		if set_off == 0 {
			out.context_sets << []ContextRule{}
			continue
		}
		set_at := at + set_off
		if !r.has(set_at, 2) {
			out.context_sets << []ContextRule{}
			continue
		}
		rule_count := int(r.u16_at(set_at))
		mut rules := []ContextRule{cap: rule_count}
		for ri in 0 .. rule_count {
			if !r.has(set_at + 2 + ri * 2, 2) {
				break
			}
			rule_at := set_at + int(r.u16_at(set_at + 2 + ri * 2))
			if rule := parse_context_rule(r, rule_at) {
				rules << rule
			}
		}
		out.context_sets << rules
	}
	return out
}

// parse_context_rule reads one SubRule: the glyphs after the covered first one and the
// lookups to run at each matched position.
pub fn parse_context_rule(r &Reader, at int) ?ContextRule {
	if !r.has(at, 4) {
		return none
	}
	glyph_count := int(r.u16_at(at))
	subst_count := int(r.u16_at(at + 2))
	if glyph_count < 1 || subst_count < 0 {
		return none
	}
	// The input list holds every glyph but the covered first, then the records.
	if 4 + (glyph_count - 1 + subst_count * 2) * 2 > r.len() - at {
		return none
	}
	mut rule := ContextRule{}
	for i in 0 .. glyph_count - 1 {
		rule.input << r.u16_at(at + 4 + i * 2)
	}
	for i in 0 .. subst_count {
		base := at + 4 + (glyph_count - 1) * 2 + i * 4
		rule.records << ChainRecord{
			position: int(r.u16_at(base))
			lookup:   r.u16_at(base + 2)
		}
	}
	// Last position first, as in parse_chain3: applying the records one after another
	// must not move a position a later record still needs.
	rule.records.sort_with_compare(fn (a &ChainRecord, b &ChainRecord) int {
		return b.position - a.position
	})
	return rule
}

// parse_chain3 reads one ChainingContextSubst subtable in format 3.
//
// Formats 1 and 2 are the two that need a class definition and a nested rule set, and no font
// this engine reads writes either, so the format is checked rather than guessed at.
pub fn parse_chain3(r &Reader, at int) ?ChainContext3 {
	if r.u16_at(at) != 3 {
		return none
	}
	mut c := ChainContext3{}
	mut p := at + 2
	back := read_coverages(r, at, p)
	p = back.next
	c.backtrack = back.ranges
	inp := read_coverages(r, at, p)
	p = inp.next
	c.input = inp.ranges
	ahead := read_coverages(r, at, p)
	p = ahead.next
	c.lookahead = ahead.ranges
	// A context with no input glyphs describes a pattern that cannot be placed on the run, so
	// there is nowhere to substitute and nothing to do.
	if c.input.len == 0 {
		return none
	}
	count := int(r.u16_at(p))
	p += 2
	// Every record is four bytes, so a count that cannot fit in what is left of the table is a
	// font claiming more than it has. The count is the last thing read from the subtable, so
	// there is nothing past it to be out of step with. Zero records is kept rather than
	// dropped: a rule that matches and names nothing still claims the glyph, which is what
	// keeps MS Gothic's dakuten from gaining a dotted circle whenever a base precedes it.
	if count * 4 > r.len() - p {
		return none
	}
	for i in 0 .. count {
		base := p + i * 4
		c.records << ChainRecord{
			position: int(r.u16_at(base))
			lookup:   r.u16_at(base + 2)
		}
	}
	// Last position first, so that applying the records one after another cannot leave a record
	// pointing at a position an earlier one has already moved.
	c.records.sort_with_compare(fn (a &ChainRecord, b &ChainRecord) int {
		return b.position - a.position
	})
	return c
}

// parse_chain_records reads one SubstLookupRecord array: a count followed by that many
// (sequence index, lookup index) pairs. All four contextual formats end their rules
// with one, so the bound check lives here rather than in each reader.
pub fn parse_chain_records(r &Reader, p int) ?ChainRecords {
	if !r.has(p, 2) {
		return none
	}
	count := int(r.u16_at(p))
	if count < 0 || count * 4 > r.len() - (p + 2) {
		return none
	}
	mut out := ChainRecords{
		records: []ChainRecord{cap: count}
		next:    p + 2 + count * 4
	}
	for i in 0 .. count {
		base := p + 2 + i * 4
		out.records << ChainRecord{
			position: int(r.u16_at(base))
			lookup:   r.u16_at(base + 2)
		}
	}
	return out
}

// ChainRecords is a SubstLookupRecord array together with where the field after it
// begins, which is what lets one reader hand the next its start.
pub struct ChainRecords {
pub mut:
	records []ChainRecord
	next    int
}

// parse_context2 reads one class-based plain ContextSubst subtable in format 2.
//
// The sets are aligned with the input class: the covered first glyph's class selects
// its set, and a NULL set offset is an empty rule list kept positionally. Each rule
// names the classes after the covered first, then its records.
pub fn parse_context2(r &Reader, at int) ?ContextClass2 {
	if r.u16_at(at) != 2 {
		return none
	}
	if !r.has(at, 8) {
		return none
	}
	mut c := ContextClass2{}
	c.coverage = parse_coverage(r, at + int(r.u16_at(at + 2)))
	c.input = parse_class_def(r, at + int(r.u16_at(at + 4)))
	set_count := int(r.u16_at(at + 6))
	if set_count < 0 || 8 + set_count * 2 > r.len() - at {
		return none
	}
	for si in 0 .. set_count {
		set_off := int(r.u16_at(at + 8 + si * 2))
		if set_off == 0 {
			c.sets << []ContextClassRule{}
			continue
		}
		set_at := at + set_off
		if !r.has(set_at, 2) {
			c.sets << []ContextClassRule{}
			continue
		}
		rule_count := int(r.u16_at(set_at))
		mut rules := []ContextClassRule{cap: rule_count}
		for ri in 0 .. rule_count {
			if !r.has(set_at + 2 + ri * 2, 2) {
				break
			}
			if rule := parse_context_class_rule(r, set_at + int(r.u16_at(set_at + 2 + ri * 2))) {
				rules << rule
			}
		}
		c.sets << rules
	}
	return c
}

// parse_context_class_rule reads one rule of a class set: the classes after the covered
// first, then the records.
//
// The input count includes the covered first, so the stored list holds every class after
// it. A rule that fails to parse is skipped rather than placed half-read: the next rule
// starts at its own offset, so one bad rule cannot shift the rest.
pub fn parse_context_class_rule(r &Reader, at int) ?ContextClassRule {
	if !r.has(at, 4) {
		return none
	}
	in_count := int(r.u16_at(at))
	sub_count := int(r.u16_at(at + 2))
	if in_count < 1 {
		return none
	}
	mut p := at + 4
	if (in_count - 1) * 2 > r.len() - p {
		return none
	}
	mut rule := ContextClassRule{}
	for _ in 0 .. in_count - 1 {
		rule.input << r.u16_at(p)
		p += 2
	}
	// The records follow the input list, and their count is the substitution count
	// read above rather than a second count: each record is four bytes.
	if sub_count < 0 || sub_count * 4 > r.len() - p {
		return none
	}
	for _ in 0 .. sub_count {
		rule.records << ChainRecord{
			position: int(r.u16_at(p))
			lookup:   r.u16_at(p + 2)
		}
		p += 4
	}
	return rule
}

// parse_context3 reads one coverage-based plain ContextSubst subtable in format 3.
//
// Like the chaining format 3 it is a list of coverages followed by records, but with
// no backtrack or lookahead: the pattern is the input alone. Unlike the chaining
// format 3, the substitution count comes before the coverage offsets rather than after
// them: format, input count, substitution count, offsets, records. Reading the count
// from after the offsets walks into the next subtable — measured on Amiri lookup 27,
// whose count of 3 sits at the fourth word while the offset array's own third word
// happens to hold a 60, which then reads sixty records out of whatever follows.
pub fn parse_context3(r &Reader, at int) ?ChainContext3 {
	if r.u16_at(at) != 3 {
		return none
	}
	if !r.has(at, 6) {
		return none
	}
	glyph_count := int(r.u16_at(at + 2))
	subst_count := int(r.u16_at(at + 4))
	// A subtable with no records substitutes nothing, and parsing it as a chain would
	// claim the chaining kind for a lookup that does nothing. The chaining reader
	// refuses the same shape for the same reason.
	if glyph_count < 1 || subst_count < 1 {
		return none
	}
	if 6 + glyph_count * 2 + subst_count * 4 > r.len() - at {
		return none
	}
	mut c := ChainContext3{}
	for i in 0 .. glyph_count {
		c.input << parse_coverage(r, at + int(r.u16_at(at + 6 + i * 2)))
	}
	mut p := at + 6 + glyph_count * 2
	for _ in 0 .. subst_count {
		c.records << ChainRecord{
			position: int(r.u16_at(p))
			lookup:   r.u16_at(p + 2)
		}
		p += 4
	}
	// Last position first, like the chaining reader: each record runs against the run
	// as it stands, so an earlier record must not move a later one's position.
	c.records.sort_with_compare(fn (a &ChainRecord, b &ChainRecord) int {
		return b.position - a.position
	})
	return c
}

// parse_chain1 reads one glyph-based ChainingContextSubst subtable in format 1.
//
// The sets are aligned with the coverage index the way plain format 1 is: the covered
// first glyph selects its set, and a NULL set offset is an empty rule list kept
// positionally. Each rule names its three sequences as glyph ids, including every
// input glyph but the covered first.
pub fn parse_chain1(r &Reader, at int) ?ChainGlyphSub1 {
	if r.u16_at(at) != 1 {
		return none
	}
	if !r.has(at, 8) {
		return none
	}
	mut c := ChainGlyphSub1{}
	c.coverage = parse_coverage(r, at + int(r.u16_at(at + 2)))
	set_count := int(r.u16_at(at + 4))
	if set_count < 0 || 6 + set_count * 2 > r.len() - at {
		return none
	}
	for si in 0 .. set_count {
		set_off := int(r.u16_at(at + 6 + si * 2))
		if set_off == 0 {
			c.sets << []GlyphChainRule{}
			continue
		}
		set_at := at + set_off
		if !r.has(set_at, 2) {
			c.sets << []GlyphChainRule{}
			continue
		}
		rule_count := int(r.u16_at(set_at))
		mut rules := []GlyphChainRule{cap: rule_count}
		for ri in 0 .. rule_count {
			if !r.has(set_at + 2 + ri * 2, 2) {
				break
			}
			if rule := parse_glyph_chain_rule(r, set_at + int(r.u16_at(set_at + 2 + ri * 2))) {
				rules << rule
			}
		}
		c.sets << rules
	}
	return c
}

// parse_glyph_chain_rule reads one rule of a glyph chaining set: glyph-id lists for the
// three sequences, then the positioning records.
//
// The input count includes the covered first glyph, so the stored list holds every glyph
// after it. A rule that fails to parse is skipped rather than placed half-read: the next
// rule starts at its own offset, so one bad rule cannot shift the rest.
pub fn parse_glyph_chain_rule(r &Reader, at int) ?GlyphChainRule {
	if !r.has(at, 2) {
		return none
	}
	back_count := int(r.u16_at(at))
	mut p := at + 2
	if back_count < 0 || back_count * 2 > r.len() - p {
		return none
	}
	mut rule := GlyphChainRule{}
	for _ in 0 .. back_count {
		rule.backtrack << r.u16_at(p)
		p += 2
	}
	if !r.has(p, 2) {
		return none
	}
	in_count := int(r.u16_at(p))
	p += 2
	// One of the input glyphs is the covered first, so a count of zero names nothing
	// to match and the rule can never fire.
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
	if recs := parse_chain_records(r, p) {
		rule.records = recs.records
		return rule
	}
	return none
}

// parse_chain2 reads one class-based ChainingContextSubst subtable in format 2.
//
// Three class definitions and, per input class value, the rules for a first glyph of
// that class. A NULL set offset parses to an empty rule list, kept positionally so
// later sets stay aligned with their class value.
pub fn parse_chain2(r &Reader, at int) ?ChainClassSub2 {
	if r.u16_at(at) != 2 {
		return none
	}
	if !r.has(at, 12) {
		return none
	}
	mut c := ChainClassSub2{}
	c.coverage = parse_coverage(r, at + int(r.u16_at(at + 2)))
	c.backtrack = parse_class_def(r, at + int(r.u16_at(at + 4)))
	c.input = parse_class_def(r, at + int(r.u16_at(at + 6)))
	c.lookahead = parse_class_def(r, at + int(r.u16_at(at + 8)))
	set_count := int(r.u16_at(at + 10))
	if set_count < 0 || 12 + set_count * 2 > r.len() - at {
		return none
	}
	for si in 0 .. set_count {
		set_off := int(r.u16_at(at + 12 + si * 2))
		if set_off == 0 {
			c.sets << []ClassChainRule{}
			continue
		}
		set_at := at + set_off
		if !r.has(set_at, 2) {
			c.sets << []ClassChainRule{}
			continue
		}
		rule_count := int(r.u16_at(set_at))
		mut rules := []ClassChainRule{cap: rule_count}
		for ri in 0 .. rule_count {
			if !r.has(set_at + 2 + ri * 2, 2) {
				break
			}
			if rule := parse_class_chain_rule(r, set_at + int(r.u16_at(set_at + 2 + ri * 2))) {
				rules << rule
			}
		}
		c.sets << rules
	}
	return c
}

// parse_class_chain_rule reads one rule of a class set: class counts and lists for the
// three sequences, then the substitution records.
//
// The input count includes the first glyph, whose class selected this set, so the stored
// list holds every class after it. A rule that fails to parse is skipped rather than
// placed half-read: the next rule starts at its own offset, so one bad rule cannot shift
// the rest.
pub fn parse_class_chain_rule(r &Reader, at int) ?ClassChainRule {
	if !r.has(at, 2) {
		return none
	}
	back_count := int(r.u16_at(at))
	mut p := at + 2
	if back_count < 0 || back_count * 2 > r.len() - p {
		return none
	}
	mut rule := ClassChainRule{}
	for _ in 0 .. back_count {
		rule.backtrack << r.u16_at(p)
		p += 2
	}
	if !r.has(p, 2) {
		return none
	}
	in_count := int(r.u16_at(p))
	p += 2
	// One of the input glyphs is the first, whose class selected this set. A count of
	// zero names nothing to match and the rule can never fire.
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
	if recs := parse_chain_records(r, p) {
		rule.records = recs.records
		return rule
	}
	return none
}
