module vtext

// OpenType glyph substitution, the GSUB table.
//
// This exists because a letter's four Arabic shapes are usually not in the font's cmap. A
// font that keeps them in GSUB carries the base letter once and a rule that swaps in the
// shaped variant, so the joining pass's decision has to be handed to the font to be turned
// into a glyph index. The joining pass could not do this itself: it produces a shape, and
// which glyph carries that shape is a property of the font.
//
// The scope here is the single substitution behind the four positional features, isol, fina,
// init and medi; the alternate substitution some fonts use for the same shapes; the ligature
// substitution behind ccmp and rlig; the multiple substitution that turns one glyph into several;
// and the chaining context substitution that reads a whole run and substitutes according to what
// surrounds the glyph. The first two are what make a font like Dubai render properly joined, the
// third is what fuses a lam and an alef into one glyph and composes two marks a font draws as one,
// and the last is what lets a font compose its marks from a pattern rather than from a single
// glyph.
//
// Having the context rules is not by itself enough to compose a mark. Dubai's ccmp is entirely
// chaining contexts and all of it parses here, but those rules are written against glyphs its own
// cmap never hands out, so no text the pipeline can produce reaches them. See the note on
// mark_glyphs_passthrough in gpos.v for what that gap actually is.
//
// What is not here is the rest of context substitution: the plain context format, lookup type 5,
// and the two chaining formats that need a class definition and a nested rule set, which are
// formats 1 and 2 of type 6. Every Arabic font this engine is pointed at composes through format
// 3 alone, so those are named here as deliberately absent rather than shipped untested against a
// font that does not reach for them.

// Lookup types, from the OpenType specification.
const gsub_lookup_single = 1
const gsub_lookup_multiple = 2
const gsub_lookup_alternate = 3
const gsub_lookup_ligature = 4
const gsub_lookup_chain_context = 6
const gsub_lookup_extension = 7

// The bits of a lookup's flag field, which say which glyphs the lookup's rules take part in.
//
// A context rule is written against a whole run, and these are how the font says "ignore the
// marks" or "this is for right to left text" or "only marks of this attachment class". Without
// them a rule about three letters would be broken by a mark sitting between two of them, which
// is the common case in Arabic rather than an edge of it.
const gsub_flag_right_to_left = 0x0001
const gsub_flag_ignore_base_glyphs = 0x0002
const gsub_flag_ignore_ligatures = 0x0004
const gsub_flag_ignore_marks = 0x0008
const gsub_flag_use_mark_filtering_set = 0x0010

// The top byte of the flag field is not a bit but a value: a mark attachment class that marks
// have to belong to for this lookup to see them. It shares the field with the bits below, which
// is why it is written as a mask rather than as a flag.
//
// Four of these are set by the fonts this engine is pointed at: right to left, ignoring marks,
// and mark attachment classes of 1 and 2. Two are not set by any of them: ignoring base glyphs
// and using a mark filtering set. Both are implemented, and both are noted as unexercised rather
// than left out, because a font outside the set on this machine may well need them and a missing
// flag is a wrong glyph while a present one is at worst the font's own behaviour.
const gsub_flag_mark_attachment_type = 0xff00

// CoverageRange is one span of the glyphs a coverage table covers. Coverage is stored as
// ranges rather than one entry per glyph because a font that covers a whole contiguous block
// would otherwise need an entry for every glyph in it.
struct CoverageRange {
	first u16
	last  u16
	// start_index is the coverage index of first. The index of a glyph inside the range is
	// start_index + (glyph - first), and it is what the substitution tables index their
	// replacements by.
	start_index int
}

// SingleSubst is one single-substitution rule: the glyphs it covers and what each becomes.
struct SingleSubst {
	ranges []CoverageRange
	// delta is added to a covered glyph index, which is how the format 1 table stores a
	// substitution. subs is the explicit replacement list of format 2, indexed by coverage
	// index. Exactly one of the two is used.
	delta i32
	subs  []u16
}

// LigatureRule is one way a run of glyphs can be fused into a single glyph.
struct LigatureRule {
	// glyph is what the run becomes.
	glyph u16
	// components are the glyphs that follow the first one and are swallowed with it. The first
	// glyph is not listed, because it is the one the coverage is indexed by and every rule in a
	// set starts with the same one.
	components []u16
}

// LigatureSet holds every rule that starts with one particular glyph, longest first as the
// specification requires it to be written.
struct LigatureSet {
mut:
	// first is the glyph these rules begin with.
	first u16
	rules []LigatureRule
}

// MultipleSubst is one rule that turns a single glyph into a sequence of them.
//
// It is the mirror image of a ligature, and it is the only substitution that makes one input
// character into more than one glyph. That is why it needs its own bookkeeping downstream: a
// ligature leaves a gap to be covered by one glyph, whereas this fills one character with several
// glyphs, and a layout pass that assumes one glyph per character has to be told about the
// difference.
struct MultipleSubst {
mut:
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
struct AlternateSubst {
mut:
	// ranges is the coverage, which indexes the sets below.
	ranges []CoverageRange
	// sets is one list of alternates per covered glyph, in coverage order.
	sets [][]u16
}

// ChainRecord is one substitution a chaining context performs once its pattern has matched: which
// of the input positions it applies to, and which lookup does the work.
struct ChainRecord {
mut:
	// position is an index into the context's input sequence. It is deliberately not an offset
	// into the glyph run, so a rule matching three input glyphs can substitute the second of
	// them and leave the other two alone.
	position int
	// lookup is the index of the lookup to run at that position, resolved against the same
	// lookup list this context came from.
	lookup u16
}

// ChainContext3 is a chaining context in format 3: the pattern of glyphs before, at and after the
// position being substituted, given as coverage tables.
//
// Format 3 is the form every Arabic font this engine reads uses, and the reason is that it is the
// only context form needing neither a class definition nor an indirection. It names coverage
// tables directly, so matching it is a run of binary searches with no second lookup step, where
// formats 1 and 2 would need a class for every glyph in the pattern and then a jump through a
// rule set to find out what to do about it.
struct ChainContext3 {
mut:
	// backtrack are the coverages to match before the first input glyph, nearest first.
	backtrack [][]CoverageRange
	// input are the coverages to match at and after the position, the first being the one a
	// record with position zero substitutes.
	input [][]CoverageRange
	// lookahead are the coverages to match after the last input glyph, nearest first.
	lookahead [][]CoverageRange
	records   []ChainRecord
}

// ChainMatch is a chaining context that has found its pattern, and where in the run it is.
struct ChainMatch {
mut:
	// start is the index in the glyph list of the first input glyph.
	start int
	// positions are the indices in the glyph list of every input glyph, in pattern order, so a
	// record's position indexes straight into this.
	positions []int
	// consumed is how many glyphs the pattern spanned in total, which is the furthest input
	// glyph reached to rather than the furthest of any lookahead.
	consumed int
}

// Lookup is one GSUB lookup, holding the rules of the kinds this milestone applies.
struct Lookup {
mut:
	kind u16
	// flag says which glyphs the rules take part in, as a set of gsub_flag bits.
	flag u16
	// mark_set names the mark filtering set to use, and is only meaningful when
	// gsub_flag_use_mark_filtering_set is set.
	mark_set   u16
	singles    []SingleSubst
	alternates []AlternateSubst
	ligatures  []LigatureSet
	multiples  []MultipleSubst
	chains     []ChainContext3
	// longest_ligature is how many components the longest ligature rule in this lookup has, and so
	// how many glyphs a match can read past the one it starts from.
	//
	// It is counted once when the lookup is parsed rather than while matching, because the matcher
	// needs an upper bound on how much of the run to look at and recomputing that bound at every
	// position of every run is the same walk it is trying to avoid. A lookup with no ligature rules
	// leaves it at zero, which is the correct bound: nothing can read past the first glyph.
	longest_ligature int
}

// ScriptFeature pairs a feature tag with the lookups it names, for one script.
struct ScriptFeature {
	tag     string
	lookups []u16
}

// Script is one script in the table, with its features in the order the language system lists
// them. Order is kept because a font can give the same feature more than one lookup and the
// order decides which wins.
struct Script {
	tag      string
	features []ScriptFeature
}

// Gsub is a parsed GSUB table, reduced to what the positional features need.
pub struct Gsub {
	lookups []Lookup
	scripts []Script
	// declared is the whole FeatureList, including the features no language system enables.
	//
	// It is kept apart from the scripts for a reason that only shows up in a report. A script's features
	// are the ones its default language system enables, which is the right answer for shaping a run of
	// text and the wrong answer for "what does this font offer": a font can enable 'isol' only under a
	// tagged language, and a count built from the scripts misses it. Segoe UI is exactly that case, and
	// its FeatureList names two tags no default language system reaches. So the list is kept whole and
	// the shaping path is left reading the scripts.
	declared []Feature
	// gdef is the glyph definition table, which the lookup flags are written in terms of. A font
	// without one classifies nothing, so every glyph is unclassified and only the flags that
	// need no class do anything. That is a real answer rather than a default: a rule that says
	// "ignore the marks" against a font that does not say which glyphs are marks has to see
	// every glyph, and skipping nothing is what that means.
	gdef ?&Gdef
}

// feature_tags lists every feature tag the table's FeatureList names, with the duplicates a font creates
// by listing the same tag twice collapsed into one.
//
// The list is the FeatureList rather than the scripts' features, and the difference is not academic. A
// script enables the features of one language system, which is the right question when shaping a run of
// text, and the wrong one when asking what a font has: Segoe UI declares 25 tags in GSUB and only 23 of
// them are reachable from any default language system, with 'isol' and 'locl' living under a tagged
// language alone. A count of 23 would say the font cannot isolate a letter, which is false. It is enabled
// only when the text says which language, and this engine does not ask the text.
//
// Dubai is the other half of the shape of this: its GPOS offers a 'curs' tag, so a report of the tags says
// the font has cursive positioning, while nothing this engine reads will ever use it. Both facts are
// wanted, and they are wanted together.
pub fn (g &Gsub) feature_tags() []string {
	mut out := []string{}
	mut seen := map[string]bool{}
	for f in g.declared {
		if seen[f.tag] {
			continue
		}
		seen[f.tag] = true
		out << f.tag
	}
	return out
}

// script_tags lists the script tags the table declares, which is what its ScriptList holds.
//
// The table may declare a script the font carries nothing for, and it may declare 'DFLT' rather than a
// real script tag. Both are reported as they are, because a caller comparing two fonts wants to know that
// one of them used DFLT rather than a script list.
pub fn (g &Gsub) script_tags() []string {
	mut out := []string{}
	mut seen := map[string]bool{}
	for script in g.scripts {
		if seen[script.tag] {
			continue
		}
		seen[script.tag] = true
		out << script.tag
	}
	return out
}

// new_gsub parses the GSUB table, or returns none when the font has none or it does not
// parse. A font without usable substitution is a font whose letters stay in their base shape,
// which is a degraded rendering rather than a broken one, so this never fails.
//
// gdef is the same font's glyph definition table, and is needed at match time rather than at parse
// time, which is why it is held rather than resolved into the rules here.
//
// The parameter is named raw rather than data because data is a field name in this module,
// and a local shadowing a type name makes V resolve methods on the type instead of the
// value, which compiles into a table read that returns nothing.
pub fn new_gsub(raw []u8, gdef ?&Gdef) ?&Gsub {
	r := new_reader(raw)
	if r.len() < 10 || r.u16_at(0) != 1 {
		return none
	}
	// The three lists the header points at have to be inside the table. Font data is
	// untrusted, so a header claiming an offset past the end is not a table to be read
	// leniently: it is a table to be refused.
	script_list := int(r.u16_at(4))
	feature_list := int(r.u16_at(6))
	lookup_list := int(r.u16_at(8))
	for at in [script_list, feature_list, lookup_list] {
		if at == 0 || !r.has(at, 2) {
			return none
		}
	}
	lookups := parse_lookups(r, lookup_list)
	if lookups.len == 0 {
		return none
	}
	// The scripts are resolved against the FeatureList, so the features are read first. The
	// order of the two reads is the only thing that matters: a feature index means nothing
	// without the list it indexes.
	features := parse_features(r, feature_list)
	return &Gsub{
		lookups:  lookups
		scripts:  parse_scripts(r, script_list, features)
		declared: features
		gdef:     gdef
	}
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
struct LigatureMatch {
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
fn (l &Lookup) match_ligature(gids []Ligatable, at int) ?LigatureMatch {
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

// Edit is one replacement inside a run: where it starts, how many glyphs it took, and what stands
// there now.
//
// consumed counts glyphs of the run rather than of the pattern, because a rule that ignores marks
// can match two letters that had a mark between them, and that mark is not part of the edit. The
// mark stays on the line.
struct Edit {
mut:
	start    int
	consumed int
	glyphs   []Ligatable
}

// Substitution is what a lookup did at one place in a run.
//
// It is a list of edits rather than one replacement because a context rule may substitute several
// of its input glyphs, and because which of them it touched is not knowable until each record has
// been tried: a record naming a lookup that does not cover the glyph there is simply skipped.
struct Substitution {
mut:
	edits []Edit
}

// span is the range of the run the edits cover, and is what the caller steps over so the same
// rule is not immediately reapplied to what it just changed. It is none when there is nothing to
// step over, which happens when every record in a matched context found nothing to do.
fn (s &Substitution) span() ?EditSpan {
	if s.edits.len == 0 {
		return none
	}
	mut first := s.edits[0].start
	mut last := s.edits[0].start + s.edits[0].consumed
	for e in s.edits {
		first = imin(first, e.start)
		last = imax(last, e.start + e.consumed)
		// The output has to be in the span as well as the input, because the walk resumes from here and a
		// resume that lands on a glyph this substitution just produced re-substitutes it. A MultipleSubst
		// that replaces one glyph with three ends up covering three run positions, not one, and resuming at
		// start+consumed walks straight back onto its own output: the piece is in the rule's coverage
		// because it is the same shaped form, so it expands again, and again, and the run grows without end.
		//
		// Taking the larger of the two extents is right for every shape: a fusion consumes more than it
		// produces and the input extent is the one that matters, a substitution produces more than it
		// consumes and the output extent is, and a 1:1 is the same number either way.
		last = imax(last, e.start + e.glyphs.len)
	}
	return EditSpan{
		first: first
		last:  last
	}
}

// EditSpan is a half open range of run indices, first up to but not including last.
struct EditSpan {
mut:
	first int
	last  int
}

// substitute runs a list of lookups over a run, in the order given.
//
// The glyphs are in logical order, because that is the order the text was written in and the
// order a font's rules are written against. Reordering for display comes later and does not
// change which glyphs were substituted with which.
pub fn (g &Gsub) substitute(lookups []u16, items []Ligatable) []Ligatable {
	return g.substitute_forms(lookups, items, none)
}

// substitute_forms is substitute with the run restricted to the glyphs in one joining shape.
//
// This exists because the four joining features cannot be applied by calling substitute four times over
// the same run. Each of them is written against the base letters, so unmasked, `init` would claim every
// letter and turn the run entirely initial before `medi` ever ran. Passing the shape restricts the run to
// the glyphs that shape applies to, and each rule then finds the base letter it was written against.
//
// It has to be a parameter and not a separate entry point that pre-filters the list, because a MultipleSubst
// rule changes the length of the list as it runs: 46 of Noto Nastaliq's 68 `init` rules turn one glyph into
// several, so a mask built from the input list would be addressing the wrong glyphs a few rules in.
pub fn (g &Gsub) substitute_forms(lookups []u16, items []Ligatable, want ?JoiningForm) []Ligatable {
	if lookups.len == 0 || items.len == 0 {
		return items
	}
	mut out := items
	for li in lookups {
		if li >= g.lookups.len {
			continue
		}
		if !lookup_substitutes(g.lookups[li]) {
			continue
		}
		out = g.substitute_one(li, mut out, want)
	}
	return out
}

// lookup_substitutes reports whether a lookup holds anything this engine can apply. A lookup of
// any other type is left alone rather than treated as empty, because a font mixing in a rule this
// engine cannot read should have its other rules still work.
fn lookup_substitutes(l &Lookup) bool {
	return l.kind == gsub_lookup_single || l.kind == gsub_lookup_multiple
		|| l.kind == gsub_lookup_alternate || l.kind == gsub_lookup_ligature
		|| l.kind == gsub_lookup_chain_context
}

// substitute_one runs one lookup over a whole run.
//
// The run is rebuilt and the effective sequence recomputed after every substitution, and the walk
// then resumes from just past what changed rather than from the beginning. Recomputing is not
// tidiness, it is the point: composing two marks can produce the glyph that a third mark's rule
// is written against, so a later match can be reachable only once an earlier one has been
// applied, and every position from before that edit is stale.
//
// Resuming rather than restarting is what makes this terminate. Each edit consumes at least one
// glyph and the walk continues past all of them, so the run index under the walk strictly
// increases and the loop ends at the end of the run. A font whose rules do not reach a fixed
// point is a font this handles in one pass, which is the same contract every shaper works to.
fn (g &Gsub) substitute_one(li u16, mut items []Ligatable, want ?JoiningForm) []Ligatable {
	lookup := g.lookups[li]
	rtl := lookup.flag & gsub_flag_right_to_left != 0
	mut step := 1
	mut eff := g.effective(items, lookup.flag, lookup.mark_set, want)
	mut walk := 0
	if rtl {
		step = -1
		walk = eff.len - 1
	}
	for {
		if rtl {
			if walk < 0 {
				break
			}
		} else if walk >= eff.len {
			break
		}
		if sub := g.apply_at(li, items, eff, walk, 0) {
			if span := sub.span() {
				items = splice(items, sub)
				eff = g.effective(items, lookup.flag, lookup.mark_set, want)
				walk = eff.len - 1
				if !rtl {
					walk = eff_at_or_after(eff, span.last)
				}
				continue
			}
		}
		walk += step
	}
	return items
}

// effective lists the glyphs of a run that take part in matching, as indices into the run.
//
// The flags do not merely filter the pattern, they filter the text. A mark a lookup says to
// ignore is not merely allowed to be missing from the pattern, it is invisible to the whole
// rule, which is why "letter, mark, letter" can match a pattern of two letters. That is what
// lets an Arabic font write a composition rule over letters at all, since a mark almost always
// sits between the letters whose combination it changes.
fn (g &Gsub) effective(items []Ligatable, flag u16, mark_set u16, want ?JoiningForm) []int {
	mut out := []int{cap: items.len}
	for i, item in items {
		// A masked run only lets through the glyphs in one joining shape, which is what makes the four
		// joining features safe to apply one after another over the same run. Without it, `init` turns
		// every covered letter into its initial form and `medi` then looks up an initial form in a
		// coverage that holds base letters, finds nothing, and leaves the letter stuck initial.
		if w := want {
			// A mark takes part in every shape. It has no joining shape of its own, and in Arabic fonts
			// the joining features double as mark composition: Noto Naskh Arabic's lookup 4 turns a
			// dot-centred mark into a dot-below one and is named by `init`, `medi` and `fina` alike,
			// because a dot sits below the letter in one joining shape and above it in another. Excluding
			// marks from the mask leaves the dots in the composition meant for a different shape and the
			// text reads wrong — which is exactly what happened when this mask was first written.
			if !item.is_mark && item.form != w {
				continue
			}
		}
		if g.skipped(flag, mark_set, item.gid) {
			continue
		}
		out << i
	}
	return out
}

// eff_at_or_after returns the effective position at or past a run index, which is where a forward
// walk resumes once a substitution has changed the run up to that point. A run index and an
// effective position are not the same number once glyphs are being skipped, so this has to be
// looked up rather than computed by adding.
fn eff_at_or_after(eff []int, from int) int {
	for i, at in eff {
		if at >= from {
			return i
		}
	}
	return eff.len
}

// skipped reports whether a lookup's flags say this glyph takes no part in matching.
//
// A font with no glyph definition table classifies nothing, so nothing is skipped at all. That is
// deliberate rather than a fallback: a rule that says "ignore the marks" against a font that does
// not say which glyphs are marks has no way to tell a mark from a letter, and stepping over
// nothing is the reading that cannot substitute the wrong glyph.
fn (g &Gsub) skipped(flag u16, mark_set u16, gid u16) bool {
	gdef := g.gdef or { return false }
	is_mark := gdef.is_mark(gid)
	if flag & gsub_flag_use_mark_filtering_set != 0 {
		// A filtering set is the more precise of the two ways to restrict marks, and the
		// specification makes the two mutually exclusive, so the set is asked and the plain
		// ignore bit is not. A mark outside the named set is skipped; a mark inside it is not,
		// and neither is anything that is not a mark.
		if is_mark && !gdef.in_mark_set(int(mark_set), gid) {
			return true
		}
	} else if flag & gsub_flag_ignore_marks != 0 && is_mark {
		return true
	}
	// A mark attachment class restricts marks only. A letter of some other class does not
	// become skipped by it, or a rule naming one class would stop seeing every letter.
	if is_mark && flag & gsub_flag_mark_attachment_type != 0 {
		if gdef.mark_class(gid) != int(flag >> 8) {
			return true
		}
	}
	if flag & gsub_flag_ignore_ligatures != 0 && gdef.is_ligature(gid) {
		return true
	}
	if flag & gsub_flag_ignore_base_glyphs != 0 && gdef.is_base_or_component(gid) {
		return true
	}
	return false
}

// apply_at runs one lookup against the run at one effective position and returns what it changed.
//
// This is separate from the walk over a run because the two answer different questions. The walk
// asks where in a run a rule applies, which is the run's problem. This asks what a given lookup
// makes of the glyphs at a position it has been handed, which is the rule's problem, and it is
// what a chaining context needs in order to run a lookup of its own choosing.
fn (g &Gsub) apply_at(li u16, items []Ligatable, eff []int, at int, depth int) ?Substitution {
	if li >= g.lookups.len || at < 0 || at >= eff.len {
		return none
	}
	// A font whose lookups name each other in a cycle would otherwise recurse until the stack ran
	// out. No real font nests this deeply, and one that does is describing a loop.
	if depth > 8 {
		return none
	}
	lookup := g.lookups[li]
	pos := eff[at]
	if pos < 0 || pos >= items.len {
		return none
	}
	if lookup.kind == gsub_lookup_single {
		sub := single_lookup(lookup.singles, items[pos].gid) or { return none }
		// A rule that maps a glyph to itself has changed nothing, and counting it as a change is
		// how a walk that resumes past what changed ends up looping.
		if sub == items[pos].gid {
			return none
		}
		return Substitution{
			edits: [
				Edit{
					start:    pos
					consumed: 1
					glyphs:   ligatables([sub], items[pos])
				},
			]
		}
	}
	if lookup.kind == gsub_lookup_multiple {
		seq := multiple_lookup(lookup.multiples, items[pos].gid) or { return none }
		return Substitution{
			edits: [
				Edit{
					start:    pos
					consumed: 1
					glyphs:   ligatables(seq, items[pos])
				},
			]
		}
	}
	if lookup.kind == gsub_lookup_alternate {
		alt := alternate_lookup(lookup.alternates, items[pos].gid) or { return none }
		// A font offering a glyph as its own first alternate has said nothing, and the same
		// reasoning as for a single substitution applies.
		if alt == items[pos].gid {
			return none
		}
		return Substitution{
			edits: [
				Edit{
					start:    pos
					consumed: 1
					glyphs:   ligatables([alt], items[pos])
				},
			]
		}
	}
	if lookup.kind == gsub_lookup_ligature {
		return g.apply_ligature(lookup, items, eff, at)
	}
	if lookup.kind == gsub_lookup_chain_context {
		return g.apply_chain(lookup, items, eff, at, depth)
	}
	return none
}

// apply_ligature fuses the run at a position.
//
// The components are matched against the effective sequence rather than against the run, so a
// ligature rule still applies when a mark sits between the letters it names. When a mark does sit
// between them the rule is then refused, because fusing across it would swallow the mark. The
// letters stay apart, which is legible, rather than the mark vanishing, which is not.
fn (g &Gsub) apply_ligature(lookup Lookup, items []Ligatable, eff []int, at int) ?Substitution {
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
				glyphs:   ligatables([m.glyph], items[pos])
			},
		]
	}
}

// apply_chain runs a chaining context's records against the run once its pattern has matched.
//
// The records are applied from the last input position backwards, which is what lets each one be
// run against the run as it stands: every edit made so far was at a higher index, and changing
// the length of a list after an index does not move that index.
fn (g &Gsub) apply_chain(lookup Lookup, items []Ligatable, eff []int, at int,
	depth int) ?Substitution {
	for chain in lookup.chains {
		if m := g.match_chain_at(chain, eff, items, at) {
			mut work := items
			mut edits := []Edit{}
			for record in chain.records {
				if record.position >= m.positions.len {
					continue
				}
				pos := m.positions[record.position]
				if pos < 0 || pos >= work.len {
					continue
				}
				if sub := g.apply_at(record.lookup, work, one_at(pos), 0, depth + 1) {
					for e in sub.edits {
						edits << e
					}
					work = splice(work, sub)
				}
			}
			if edits.len > 0 {
				return Substitution{ edits: edits }
			}
		}
	}
	return none
}

// match_chain_at tests a context's pattern at one effective position.
//
// The backtrack and lookahead lists are both written nearest glyph first, in logical order, and
// that does not change with the right to left flag: the flag is about the order substitutions are
// applied in, not about the order a font writes its pattern in.
fn (g &Gsub) match_chain_at(c &ChainContext3, eff []int, items []Ligatable,
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

// one_at is an effective sequence of a single glyph, which is what a chaining record's position
// is: one glyph, with nothing skipped either side of it because the pattern has already decided
// what takes part.
//
// It is a function rather than a one element literal because this compiler's formatter rewrites
// []int{pos} into a struct literal, which does not parse.
fn one_at(pos int) []int {
	mut out := []int{cap: 1}
	out << pos
	return out
}

// ligatables turns a replacement sequence into run items that all carry one character's cluster.
//
// They share it because that is what they are: several glyphs of a single input character, which
// is the case a layout pass has to be told about separately.
fn ligatables(seq []u16, from Ligatable) []Ligatable {
	mut out := []Ligatable{cap: seq.len}
	for gid in seq {
		out << Ligatable{
			gid:     gid
			cluster: from.cluster
			source:  from.source
			form:    from.form
			is_mark: from.is_mark
		}
	}
	return out
}

// splice applies a substitution's edits to a run.
fn splice(items []Ligatable, sub Substitution) []Ligatable {
	mut out := []Ligatable{cap: items.len}
	mut i := 0
	for i < items.len {
		edit := edit_at(sub.edits, i) or {
			out << items[i]
			i++
			continue
		}
		for g in edit.glyphs {
			out << g
		}
		i += edit.consumed
	}
	return out
}

// edit_at finds the edit that starts at a run index.
fn edit_at(edits []Edit, at int) ?Edit {
	for e in edits {
		if e.start == at {
			return e
		}
	}
	return none
}

// script returns the script with the given tag.
//
// The tag is lowercased first, because the two sources disagree on case and the engine has
// both: Unicode's Script property spells a tag 'Arab' while an OpenType script tag is 'arab'.
// Passing the Unicode spelling straight through would find nothing, and the symptom would be
// Arabic letters quietly drawing in their base shape with nothing to say why.
pub fn (g &Gsub) script(tag string) ?Script {
	want := ascii_lower(tag)
	for s in g.scripts {
		if s.tag == want {
			return s
		}
	}
	return none
}

// ascii_lower lowercases the ASCII letters in a tag, leaving anything else alone. The tags
// involved are always ASCII, so this does not need to be Unicode-aware.
fn ascii_lower(s string) string {
	mut out := []u8{len: s.len}
	for i in 0 .. s.len {
		b := s[i]
		out[i] = if b >= `A` && b <= `Z` { b + 32 } else { b }
	}
	return out.bytestr()
}

// feature_tag_for is the GSUB feature tag that carries a joining shape.
pub fn feature_tag_for(form JoiningForm) string {
	return match form {
		.isolated { 'isol' }
		.final { 'fina' }
		.initial { 'init' }
		.medial { 'medi' }
	}
}

// shaped_glyph returns the glyph that carries a shape, or the base glyph when the font has no
// rule for it.
//
// script is the script of the letter rather than a fixed one, so a font that offers the same
// feature tag for several scripts resolves the right rule. Joining only produces Arabic
// shapes, so in practice this is 'arab'.
pub fn (g &Gsub) shaped_glyph(gid u16, form JoiningForm, script string) u16 {
	tag := feature_tag_for(form)
	if tag == '' {
		return gid
	}
	return g.apply(g.lookups_for(script, tag), gid)
}

// lookups_for returns the lookups a script's feature names, in the order to apply them.
pub fn (g &Gsub) lookups_for(script string, feature string) []u16 {
	s := g.script(script) or { return []u16{} }
	for f in s.features {
		if f.tag == feature {
			return f.lookups
		}
	}
	return []u16{}
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
fn single_lookup(subs []SingleSubst, gid u16) ?u16 {
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
fn alternate_lookup(subs []AlternateSubst, gid u16) ?u16 {
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
fn multiple_lookup(subs []MultipleSubst, gid u16) ?[]u16 {
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
fn coverage_index(ranges []CoverageRange, gid u16) ?int {
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

// parse_lookups reads the LookupList and every rule this milestone understands.
fn parse_lookups(r &Reader, off int) []Lookup {
	mut out := []Lookup{}
	if !r.has(off, 2) {
		return out
	}
	count := int(r.u16_at(off))
	for i in 0 .. count {
		// Each entry is an offset from the start of the LookupList.
		at := off + int(r.u16_at(off + 2 + i * 2))
		if !r.has(at, 6) {
			out << Lookup{ kind: 0 }
			continue
		}
		// The header of a lookup is its type, then its flags, then how many subtables follow.
		header_kind := r.u16_at(at)
		mut lookup := Lookup{
			kind: header_kind
			flag: r.u16_at(at + 2)
		}
		subtable_count := int(r.u16_at(at + 4))
		// The mark filtering set is one field after the subtable offsets, and it is only there
		// when the flag says to use one. It is read on the flag alone rather than on a length
		// check, because a lookup that does not use one has nothing there to find and the read
		// is bounds checked anyway.
		if lookup.flag & gsub_flag_use_mark_filtering_set != 0 {
			lookup.mark_set = r.u16_at(at + 6 + subtable_count * 2)
		}
		for j in 0 .. subtable_count {
			// Each subtable offset is relative to the lookup.
			//
			// The type passed here is the one from the header and not the one accumulated so far.
			// That distinction is load bearing for a lookup with more than one subtable: almost
			// every lookup in Dubai is an extension, and its ccmp rules come four to a subtable,
			// so resolving the second one against the type the first resolved to would read the
			// extension header as if it were the rule itself.
			resolved := resolve_subtable(r, header_kind, at + int(r.u16_at(at + 6 + j * 2)))
			if resolved.kind == gsub_lookup_single {
				if s := parse_single_subst(r, resolved.at) {
					lookup.singles << s
				}
			}
			if resolved.kind == gsub_lookup_multiple {
				if s := parse_multiple_subst(r, resolved.at) {
					lookup.multiples << s
				}
			}
			if resolved.kind == gsub_lookup_alternate {
				if s := parse_alternate_subst(r, resolved.at) {
					lookup.alternates << s
				}
			}
			if resolved.kind == gsub_lookup_ligature {
				for set in parse_ligature_subst(r, resolved.at) {
					lookup.ligatures << set
				}
			}
			if resolved.kind == gsub_lookup_chain_context {
				if c := parse_chain3(r, resolved.at) {
					lookup.chains << c
				}
			}
		}
		lookup.kind = lookup_kind_of(lookup, header_kind)
		lookup.longest_ligature = longest_ligature_of(lookup)
		out << lookup
	}
	return out
}

// longest_ligature_of counts the components of the longest ligature rule a lookup holds.
//
// It is a separate function because it runs once per lookup rather than once per position, which is the
// whole reason it is not written inline where it would be needed.
fn longest_ligature_of(l &Lookup) int {
	mut longest := 0
	for set in l.ligatures {
		for rule in set.rules {
			if rule.components.len > longest {
				longest = rule.components.len
			}
		}
	}
	return longest
}

// lookup_kind_of reports what a lookup turned out to hold, so that a caller filtering on the type
// does not have to know that the type may have come from an extension header.
//
// A lookup whose rules were of a type this milestone does not read reports the type from its
// header. That is what makes an unread lookup distinguishable from an empty one: an empty one has
// nothing to apply and is skipped, and an unread one is left alone so the rest of the font's rules
// still work.
fn lookup_kind_of(l &Lookup, header_kind u16) u16 {
	if l.chains.len > 0 {
		return gsub_lookup_chain_context
	}
	if l.multiples.len > 0 {
		return gsub_lookup_multiple
	}
	if l.alternates.len > 0 {
		return gsub_lookup_alternate
	}
	if l.ligatures.len > 0 {
		return gsub_lookup_ligature
	}
	if l.singles.len > 0 {
		return gsub_lookup_single
	}
	return header_kind
}

// parse_multiple_subst reads one MultipleSubst subtable, which is the only format it has.
//
// The sequence list is indexed by coverage index, so a sequence that fails to parse is left empty
// rather than dropped. Dropping it would shift every later sequence against the wrong covered
// glyph, which is a wrong glyph drawn rather than a missing rule noticed.
fn parse_multiple_subst(r &Reader, at int) ?MultipleSubst {
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
fn parse_alternate_subst(r &Reader, at int) ?AlternateSubst {
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

// parse_chain3 reads one ChainingContextSubst subtable in format 3.
//
// Formats 1 and 2 are the two that need a class definition and a nested rule set, and no font
// this engine reads writes either, so the format is checked rather than guessed at.
fn parse_chain3(r &Reader, at int) ?ChainContext3 {
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
	// there is nothing past it to be out of step with.
	if count < 1 || count * 4 > r.len() - p {
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

// CoverageList is one of a chaining context's three coverage lists, together with where the field
// after it begins.
//
// The position is returned rather than advanced through a mutable argument because the three
// lists are read in sequence from one running offset, and threading an int by reference is not
// something V will do.
struct CoverageList {
mut:
	ranges [][]CoverageRange
	next   int
}

// read_coverages reads one of a chaining context's three coverage lists.
//
// Every offset in the list is two bytes and relative to the start of the subtable. A coverage that
// does not parse is kept as an empty entry rather than dropped, because these lists are positional:
// the third input coverage belongs to the third input glyph whatever happens to the first two, and
// dropping a bad one would match every glyph after it against the wrong rule.
fn read_coverages(r &Reader, at int, p int) CoverageList {
	if !r.has(p, 2) {
		return CoverageList{ next: p }
	}
	count := int(r.u16_at(p))
	mut q := p + 2
	// A count whose offsets cannot fit in what is left of the table is a font claiming more than
	// it has, and is refused rather than walked off the end.
	if count * 2 > r.len() - q {
		return CoverageList{ next: q }
	}
	mut out := [][]CoverageRange{cap: count}
	for _ in 0 .. count {
		out << parse_coverage(r, at + int(r.u16_at(q)))
		q += 2
	}
	return CoverageList{
		ranges: out
		next:   q
	}
}

// parse_ligature_subst reads one LigatureSubst subtable into the sets it holds.
//
// The offsets nest three deep and each level is relative to its own table rather than to the
// subtable, which is the sort of thing that reads as plausible nonsense when a level is missed:
// a ligature set that starts at the wrong place has a glyph count taken from a coordinate pair.
fn parse_ligature_subst(r &Reader, at int) []LigatureSet {
	mut out := []LigatureSet{}
	if r.u16_at(at) != 1 {
		return out
	}
	ranges := parse_coverage(r, at + int(r.u16_at(at + 2)))
	set_count := int(r.u16_at(at + 4))
	for si in 0 .. set_count {
		// A set offset is from the start of the subtable, and the set belongs to the glyph at
		// the matching coverage index.
		set_at := at + int(r.u16_at(at + 6 + si * 2))
		if si >= ranges.len {
			break
		}
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
fn parse_ligature(r &Reader, at int) ?LigatureRule {
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

// coverage_glyph_at returns the glyph at a coverage index, which is the glyph a ligature set
// belongs to.
//
// Coverage format 2 stores a range's start index rather than every glyph in it, so this walks
// the ranges counting their lengths. That is the only way to get from a coverage index back to
// a glyph, and a font using format 2 for its ligature coverage needs it.
fn coverage_glyph_at(ranges []CoverageRange, index int) u16 {
	mut remaining := index
	for range in ranges {
		length := int(range.last) - int(range.first) + 1
		if remaining < length {
			return range.first + u16(remaining)
		}
		remaining -= length
	}
	return 0
}

// resolve_subtable follows an extension lookup to the table it wraps.
//
// Following it is not optional. Dubai, Majalla and several other Arabic fonts on Windows put
// their positional rules inside extension lookups, so ignoring the wrapper would leave every
// letter in its base shape while the font looked perfectly reasonable to a parser that only
// understood the older lookup types.
fn resolve_subtable(r &Reader, kind u16, at int) ResolvedSubtable {
	if kind != gsub_lookup_extension {
		return ResolvedSubtable{
			kind: kind
			at:   at
		}
	}
	if !r.has(at, 8) {
		return ResolvedSubtable{ kind: 0, at: 0 }
	}
	return ResolvedSubtable{
		// The wrapped offset is a 32-bit value relative to the extension subtable, which is
		// what lets a rule outgrow the 16-bit offsets of the original format.
		kind: r.u16_at(at + 2)
		at:   at + int(r.u32_at(at + 4))
	}
}

// parse_single_subst reads one SingleSubst subtable in either of its two formats.
// parse_single_subst reads one SingleSubst subtable in either of its two formats.
//
// The coverage is reached by an offset from the start of the subtable rather than stored
// inline, and where that offset sits is worth a note. The specification puts the delta and
// the glyph count in the second field and the coverage offset in the third, so the header
// reads either
//
//	substFormat, deltaGlyphID | glyphCount, coverage, substituteGlyphIDs[]
//
// and that reading is tried first. Every Arabic font on Windows was measured putting those
// two middle fields the other way round, giving
//
//	substFormat, coverage, deltaGlyphID | glyphCount, substituteGlyphIDs[]
//
// and in each case only the second reading leaves the subtable ending exactly where the next
// subtable begins. Both are accepted, documented order first, because a font that gets this
// wrong still renders in whatever consumes it and a text engine has no business being the
// one that draws the wrong glyph.
fn parse_single_subst(r &Reader, at int) ?SingleSubst {
	format := r.u16_at(at)
	if format != 1 && format != 2 {
		return none
	}
	first := int(r.u16_at(at + 2))
	second := int(r.u16_at(at + 4))
	for pass in 0 .. 2 {
		mid := if pass == 0 { first } else { second }
		cov_off := if pass == 0 { second } else { first }
		ranges := parse_coverage(r, at + cov_off)
		if ranges.len == 0 {
			continue
		}
		if format == 1 {
			return SingleSubst{
				ranges: ranges
				delta:  i32(r.i16_at(at + 2 + pass * 2))
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

// covered_count is how many glyphs a coverage table covers, which is the total length of its
// ranges.
fn covered_count(ranges []CoverageRange) int {
	mut total := 0
	for r in ranges {
		total += int(r.last) - int(r.first) + 1
	}
	return total
}

// parse_coverage reads a Coverage table as ranges.
//
// Format 1 lists glyphs one at a time, which becomes a range per glyph. Format 2 gives the
// ranges directly, which is the compact form and the one a large font uses.
fn parse_coverage(r &Reader, at int) []CoverageRange {
	mut out := []CoverageRange{}
	format := r.u16_at(at)
	if format == 1 {
		count := int(r.u16_at(at + 2))
		out = []CoverageRange{cap: count}
		for i in 0 .. count {
			out << CoverageRange{
				first:       r.u16_at(at + 4 + i * 2)
				last:        r.u16_at(at + 4 + i * 2)
				start_index: i
			}
		}
		return out
	}
	if format != 2 {
		return out
	}
	count := int(r.u16_at(at + 2))
	for i in 0 .. count {
		base := at + 4 + i * 6
		out << CoverageRange{
			first:       r.u16_at(base)
			last:        r.u16_at(base + 2)
			start_index: int(r.u16_at(base + 4))
		}
	}
	return out
}

// Feature is one entry of the FeatureList: a tag and the lookups it names.
struct Feature {
	tag     string
	lookups []u16
}

fn parse_features(r &Reader, off int) []Feature {
	mut out := []Feature{}
	if !r.has(off, 2) {
		return out
	}
	count := int(r.u16_at(off))
	for i in 0 .. count {
		base := off + 2 + i * 6
		if !r.has(base, 6) {
			continue
		}
		// The feature offset is relative to the FeatureList.
		feature_at := off + int(r.u16_at(base + 4))
		lookup_count := int(r.u16_at(feature_at + 2))
		mut lookups := []u16{cap: lookup_count}
		for j in 0 .. lookup_count {
			lookups << r.u16_at(feature_at + 4 + j * 2)
		}
		out << Feature{
			tag:     r.tag_at(base)
			lookups: lookups
		}
	}
	return out
}

// parse_scripts reads the ScriptList and resolves each script's language system into the
// features it enables.
fn parse_scripts(r &Reader, off int, features []Feature) []Script {
	mut out := []Script{}
	if !r.has(off, 2) {
		return out
	}
	count := int(r.u16_at(off))
	for i in 0 .. count {
		base := off + 2 + i * 6
		if !r.has(base, 6) {
			continue
		}
		tag := r.tag_at(base)
		script_at := off + int(r.u16_at(base + 4))
		indices := langsys_features(r, script_at)
		mut enabled := []ScriptFeature{}
		// A feature index that points outside the FeatureList is a font that is telling us
		// something untrue, so it is skipped rather than allowed to index nothing.
		for fi in indices {
			if fi >= features.len {
				continue
			}
			enabled << ScriptFeature{
				tag:     features[fi].tag
				lookups: features[fi].lookups
			}
		}
		out << Script{
			tag:      tag
			features: enabled
		}
	}
	return out
}

// langsys_features returns the feature indices a script's language system enables.
//
// The default language system is preferred, because a font that only tags one language is
// describing the behaviour for text with no language tag, which is most of it. A font that
// lists several is asked about the default rather than about the first, because the first is
// whichever the compiler put there.
fn langsys_features(r &Reader, script_at int) []u16 {
	mut at := 0
	default := int(r.u16_at(script_at))
	if default != 0 && r.has(script_at + default, 4) {
		at = script_at + default
	} else {
		// No default language system, so fall back to the first one listed.
		count := int(r.u16_at(script_at + 2))
		if count == 0 {
			return []u16{}
		}
		at = script_at + int(r.u16_at(script_at + 4 + 2))
	}
	mut out := []u16{}
	// A required feature is not counted in featureIndexCount, so it is read from its own
	// field and put first, since a required feature applies whether or not it is listed.
	required := int(r.u16_at(at + 2))
	if required != 0xFFFF {
		out << u16(required)
	}
	count := int(r.u16_at(at + 4))
	for i in 0 .. count {
		out << r.u16_at(at + 6 + i * 2)
	}
	return out
}
