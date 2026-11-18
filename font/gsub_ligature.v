module font

// LigatureRule is one way a run of glyphs can be fused into a single glyph.
pub struct LigatureRule {
pub mut:
	// glyph is what the run becomes.
	glyph u16
	// components are the glyphs that follow the first one and are swallowed with it. The first
	// glyph is not listed, because it is the one the coverage is indexed by and every rule in a
	// set starts with the same one.
	components []u16
}

// LigatureSet holds every rule that starts with one particular glyph, longest first as the
// specification requires it to be written.
pub struct LigatureSet {
pub mut:
	// first is the glyph these rules begin with.
	first u16
	rules []LigatureRule
}

// Ligatable is what a ligature pass needs to know about one glyph on a line: which glyph it is,
// and which input character it came from. The fused glyph keeps the cluster of the first glyph
// it swallowed, which is what makes a ligature traceable back to the text it stands for.
pub struct Ligatable {
pub mut:
	gid     u16
	cluster int
	// source is the position this item had in the list that went in. A fused run is shorter than
	// what it replaced, so the two lists do not line up and the caller cannot work out which
	// original glyph a fused one came from by counting. It is the first glyph of the run, whose
	// font, shape and mark flag are the ones the fused glyph inherits.
	source int
	// form is the joining shape this glyph is drawn in, or isolated when nothing has said otherwise.
	//
	// It rides here rather than being passed alongside the list because a rule that turns one glyph
	// into several changes the length of the list, so anything indexing it by position goes stale
	// the moment a substitution fires. Travelling with the glyph is the only way a mask stays
	// aligned with the run it is masking.
	form JoiningForm
	// is_mark says this glyph is a combining mark, which takes no part in joining but does take part in
	// the features that name a shape, because in Arabic those features double as mark composition.
	is_mark bool
}

// LigatureMatch is the outcome of a fusion: the glyph that replaces the run, and how many glyphs
// it swallowed.
pub struct LigatureMatch {
pub mut:
	glyph    u16
	consumed int
}

// match_ligature finds the longest rule that fuses a run of glyphs starting at a given position,
// or none when the run does not fuse.
//
// Longest wins rather than first, because a font that offers both a two-glyph and a three-glyph
// rule for the same opening letter has to be given the three-glyph one, or "lam lam alef" would
// come out as a ligature plus a loose letter. The sets are already sorted that way when they
// are parsed, and this walks them in order, so the first rule that matches is the longest.
pub fn (l &Lookup) match_ligature(gids []Ligatable, at int) ?LigatureMatch {
	first := gids[at].gid
	for set in l.ligatures {
		if set.first != first {
			continue
		}
		for rule in set.rules {
			// The rule has to fit entirely inside what is left of the run. A rule that runs off
			// the end does not match, which is the same answer as a rule that does not apply.
			if at + rule.components.len >= gids.len {
				continue
			}
			mut ok := true
			for k, component in rule.components {
				if gids[at + 1 + k].gid != component {
					ok = false
					break
				}
			}
			if ok {
				return LigatureMatch{
					glyph:    rule.glyph
					consumed: rule.components.len + 1
				}
			}
		}
	}
	return none
}

// apply_ligature fuses the run at a position.
//
// The components are matched against the effective sequence rather than against the run, so a
// ligature rule still applies when a mark sits between the letters it names. When a mark does sit
// between them the rule is then refused, because fusing across it would swallow the mark. The
// letters stay apart, which is legible, rather than the mark vanishing, which is not.
pub fn (g &Gsub) apply_ligature(lookup Lookup, items []Ligatable, eff []int, at int) ?Substitution {
	pos := eff[at]
	// Only the first glyph of the longest ligature rule and the components that follow it can ever be
	// read, so only that many are copied.
	//
	// This used to copy the whole rest of the run, which made trying a ligature at position i cost
	// O(n - i) and trying it at every position of a run of n glyphs cost O(n squared) in copying and in
	// allocation. Measured on Segoe UI at 16 pixels, a 1024 character paragraph spent 66 milliseconds
	// inside this one function's caller, all of it copying a tail nobody looked at.
	//
	// The bound is exact rather than generous, and truncating it changes no answer. match_ligature
	// reads at most view[longest_ligature], and its own test that a rule fits inside what is left of
	// the run is `components.len + 1 <= view.len`, which every rule still satisfies because
	// components.len <= longest_ligature. Where the tail is shorter than the bound the view is the
	// whole tail, exactly as it was.
	mut want := lookup.longest_ligature + 1
	left := eff.len - at
	if want > left {
		want = left
	}
	mut view := []Ligatable{cap: want}
	for i in at .. at + want {
		view << items[eff[i]]
	}
	m := lookup.match_ligature(view, 0) or { return none }
	last := at + m.consumed - 1
	if last >= eff.len {
		return none
	}
	// Every component has to be the next glyph of the run, not merely the next one that takes
	// part, or the fusion would drop whatever is in between.
	if eff[last] - pos + 1 != m.consumed {
		return none
	}
	return Substitution{
		edits: [
			Edit{
				start:    pos
				consumed: m.consumed
				glyphs:   g.ligatables([m.glyph], items[pos], true)
			},
		]
	}
}

// parse_ligature_subst reads one LigatureSubst subtable into the sets it holds.
//
// The offsets nest three deep and each level is relative to its own table rather than to the
// subtable, which is the sort of thing that reads as plausible nonsense when a level is missed:
// a ligature set that starts at the wrong place has a glyph count taken from a coordinate pair.
pub fn parse_ligature_subst(r &Reader, at int) []LigatureSet {
	mut out := []LigatureSet{}
	if r.u16_at(at) != 1 {
		return out
	}
	ranges := parse_coverage(r, at + int(r.u16_at(at + 2)))
	set_count := int(r.u16_at(at + 4))
	for si in 0 .. set_count {
		// A set offset is from the start of the subtable, and the set belongs to the glyph at
		// the matching coverage index. The index counts glyphs, not ranges: a format-2
		// coverage packs many glyphs per range, and stopping at the range count would drop
		// every set past it (lookup 114 of Noto Sans Devanagari keeps 8 of its 42 sets
		// that way, losing the NA half-form). Past the coverage total the index reads 0,
		// which matches nothing real.
		set_at := at + int(r.u16_at(at + 6 + si * 2))
		first := coverage_glyph_at(ranges, si)
		mut set := LigatureSet{ first: first }
		lig_count := int(r.u16_at(set_at))
		for li in 0 .. lig_count {
			// A ligature offset is from the start of its set, not the subtable.
			lig_at := set_at + int(r.u16_at(set_at + 2 + li * 2))
			if rule := parse_ligature(r, lig_at) {
				set.rules << rule
			}
		}
		// Longest first, so a rule that swallows more glyphs is tried before one that swallows
		// fewer. The font is required to write them in that order, but relying on that would make
		// a font that does not fuse the longer pair, and sorting costs nothing.
		set.rules.sort_with_compare(fn (a &LigatureRule, b &LigatureRule) int {
			return b.components.len - a.components.len
		})
		out << set
	}
	return out
}

// parse_ligature reads one ligature rule: the glyph it becomes and the components after the
// first.
pub fn parse_ligature(r &Reader, at int) ?LigatureRule {
	if !r.has(at, 4) {
		return none
	}
	glyph := r.u16_at(at)
	count := int(r.u16_at(at + 2))
	if count < 2 {
		// A rule that consumes one glyph is a single substitution wearing the wrong type, and
		// treating it as a ligature would consume a glyph for nothing.
		return none
	}
	mut components := []u16{cap: count - 1}
	for i in 1 .. count {
		components << r.u16_at(at + 2 + i * 2)
	}
	return LigatureRule{
		glyph:      glyph
		components: components
	}
}
