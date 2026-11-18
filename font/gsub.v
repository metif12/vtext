module font

// JoiningForm is one of the four shapes a letter can take. The ordinals have to match the
// generated arabic_form_names table.
pub enum JoiningForm {
	isolated = 0
	final    = 1
	initial  = 2
	medial   = 3
}

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
// What is not here is the rest of context substitution: the class-based formats 2 and 3
// of lookup type 5, and the two chaining formats that need a class definition and a nested
// rule set, which are formats 1 and 2 of type 6. The one format-1 context in the corpus,
// Noto Nastaliq's lam-alef rule, is read; the class-based ones have no font reaching for
// them here and stay named as deliberately absent rather than shipped untested.

// Lookup types, from the OpenType specification.
pub const gsub_lookup_single = 1
pub const gsub_lookup_multiple = 2
pub const gsub_lookup_alternate = 3
pub const gsub_lookup_ligature = 4
pub const gsub_lookup_context = 5
pub const gsub_lookup_chain_context = 6
pub const gsub_lookup_extension = 7

// The bits of a lookup's flag field, which say which glyphs the lookup's rules take part in.
//
// A context rule is written against a whole run, and these are how the font says "ignore the
// marks" or "this is for right to left text" or "only marks of this attachment class". Without
// them a rule about three letters would be broken by a mark sitting between two of them, which
// is the common case in Arabic rather than an edge of it.
pub const gsub_flag_right_to_left = 0x0001
pub const gsub_flag_ignore_base_glyphs = 0x0002
pub const gsub_flag_ignore_ligatures = 0x0004
pub const gsub_flag_ignore_marks = 0x0008
pub const gsub_flag_use_mark_filtering_set = 0x0010

// The top byte of the flag field is not a bit but a value: a mark attachment class that marks
// have to belong to for this lookup to see them. It shares the field with the bits below, which
// is why it is written as a mask rather than as a flag.
//
// Four of these are set by the fonts this engine is pointed at: right to left, ignoring marks,
// and mark attachment classes of 1 and 2. Two are not set by any of them: ignoring base glyphs
// and using a mark filtering set. Both are implemented, and both are noted as unexercised rather
// than left out, because a font outside the set on this machine may well need them and a missing
// flag is a wrong glyph while a present one is at worst the font's own behaviour.
pub const gsub_flag_mark_attachment_type = 0xff00

// CoverageRange is one span of the glyphs a coverage table covers. Coverage is stored as
// ranges rather than one entry per glyph because a font that covers a whole contiguous block
// would otherwise need an entry for every glyph in it.
pub struct CoverageRange {
pub mut:
	first u16
	last  u16
	// start_index is the coverage index of first. The index of a glyph inside the range is
	// start_index + (glyph - first), and it is what the substitution tables index their
	// replacements by.
	start_index int
}

// Lookup is one GSUB lookup, holding the rules of the kinds this milestone applies.
pub struct Lookup {
pub mut:
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
	// context_coverage names the first glyph of each plain-context rule, and
	// context_sets holds one rule list per covered glyph, in coverage order. A NULL
	// set offset parses to an empty list rather than shifting the rest, for the same
	// positional reason an empty multiple sequence is kept.
	context_coverage []CoverageRange
	context_sets     [][]ContextRule
	// context_classes holds the class-based plain-context subtables (format 2), one
	// per subtable in the order read. A lookup holds one context kind or the other.
	context_classes []ContextClass2
	// chain_glyphs holds the glyph-based chaining subtables (format 1), and
	// chain_classes holds the class-based ones (format 2). Like the plain side, a
	// lookup holds one chaining kind or the other.
	chain_glyphs  []ChainGlyphSub1
	chain_classes []ChainClassSub2
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
pub struct ScriptFeature {
pub mut:
	tag     string
	lookups []u16
}

// ScriptLang is one tagged language inside a script: its tag and the features
// that language system enables. The default language system is not listed
// here; it is `Script.features`, which is what every line shaped before the
// language control existed.
pub struct ScriptLang {
pub mut:
	tag      string
	features []ScriptFeature
}

// Script is one script in the table, with its features in the order the language system lists
// them. Order is kept because a font can give the same feature more than one lookup and the
// order decides which wins.
pub struct Script {
pub mut:
	tag      string
	features []ScriptFeature
	// langs holds every tagged language system in the script, in the order the
	// ScriptList names them. A language override resolves here; an empty
	// language answers `features`, which is the default language system.
	langs []ScriptLang
}

// Gsub is a parsed GSUB table, reduced to what the positional features need.
pub struct Gsub {
pub mut:
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
	// The three lists the header points at have to be inside the table. shape.Font data is
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

// Edit is one replacement inside a run: where it starts, how many glyphs it took, and what stands
// there now.
//
// consumed counts glyphs of the run rather than of the pattern, because a rule that ignores marks
// can match two letters that had a mark between them, and that mark is not part of the edit. The
// mark stays on the line.
pub struct Edit {
pub mut:
	start    int
	consumed int
	glyphs   []Ligatable
}

// Substitution is what a lookup did at one place in a run.
//
// It is a list of edits rather than one replacement because a context rule may substitute several
// of its input glyphs, and because which of them it touched is not knowable until each record has
// been tried: a record naming a lookup that does not cover the glyph there is simply skipped.
pub struct Substitution {
pub mut:
	edits []Edit
}

// span is the range of the run the edits cover, and is what the caller steps over so the same
// rule is not immediately reapplied to what it just changed. It is none when there is nothing to
// step over, which happens when every record in a matched context found nothing to do.
pub fn (s &Substitution) span() ?EditSpan {
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
pub struct EditSpan {
pub mut:
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
pub fn lookup_substitutes(l &Lookup) bool {
	return l.kind == gsub_lookup_single || l.kind == gsub_lookup_multiple
		|| l.kind == gsub_lookup_alternate || l.kind == gsub_lookup_ligature
		|| l.kind == gsub_lookup_chain_context || l.kind == gsub_lookup_context
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
pub fn (g &Gsub) substitute_one(li u16, mut items []Ligatable, want ?JoiningForm) []Ligatable {
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
				// A substitution that replaces glyphs in place leaves the effective
				// sequence valid: it is indices into the run, and nothing moved. The
				// splice and the full recompute are then pure overhead, paid once per
				// substitution, which is what makes a joining pass over a long run
				// quadratic in copying. Only length-preserving edits whose glyphs
				// take part in matching exactly as before qualify; anything else —
				// an expansion, a fusion, or a base letter becoming a mark — goes
				// through the rebuild, because the positions after it are stale.
				if edits_preserve_matching(g, items, sub, lookup.flag, lookup.mark_set) {
					for e in sub.edits {
						for k, ng in e.glyphs {
							items[e.start + k] = ng
						}
					}
				} else {
					items = splice(items, sub)
					eff = g.effective(items, lookup.flag, lookup.mark_set, want)
				}
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

// edits_preserve_matching reports whether applying a substitution leaves the effective
// sequence valid, so the walk can continue without rebuilding the run and re-deriving
// who takes part. Two things would invalidate it: a change in length, which moves
// every index after the edit, and a change in participation, which is what the
// lookup's own flags decide per glyph.
//
// Length alone is not enough, and participation alone is not enough either. Two
// edits can trade lengths with each other while moving everything between them,
// so every edit is asked on its own. A base letter becoming a mark changes what
// an ignore-marks flag steps over, and a mark becoming a base does the reverse,
// so the check is the flag's own answer on both glyphs rather than a kind
// comparison written a second time. Form and mark-ness ride along on the items
// the rules produce, so the mask sees the same run either way.
pub fn edits_preserve_matching(g &Gsub, items []Ligatable, sub Substitution, flag u16, mark_set u16) bool {
	for e in sub.edits {
		if e.start < 0 || e.glyphs.len != e.consumed || e.start + e.consumed > items.len {
			return false
		}
		for k, ng in e.glyphs {
			if g.skipped(flag, mark_set, items[e.start + k].gid) != g.skipped(flag,
				mark_set, ng.gid) {
				return false
			}
		}
	}
	return true
}

// effective lists the glyphs of a run that take part in matching, as indices into the run.
//
// The flags do not merely filter the pattern, they filter the text. A mark a lookup says to
// ignore is not merely allowed to be missing from the pattern, it is invisible to the whole
// rule, which is why "letter, mark, letter" can match a pattern of two letters. That is what
// lets an Arabic font write a composition rule over letters at all, since a mark almost always
// sits between the letters whose combination it changes.
pub fn (g &Gsub) effective(items []Ligatable, flag u16, mark_set u16, want ?JoiningForm) []int {
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
pub fn eff_at_or_after(eff []int, from int) int {
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
pub fn (g &Gsub) skipped(flag u16, mark_set u16, gid u16) bool {
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
pub fn (g &Gsub) apply_at(li u16, items []Ligatable, eff []int, at int, depth int) ?Substitution {
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
					glyphs:   g.ligatables([sub], items[pos], false)
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
					glyphs:   g.ligatables(seq, items[pos], false)
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
					glyphs:   g.ligatables([alt], items[pos], false)
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
	if lookup.kind == gsub_lookup_context {
		return g.apply_context(lookup, items, eff, at, depth)
	}
	return none
}

// one_at is an effective sequence of a single glyph, which is what a chaining record's position
// is: one glyph, with nothing skipped either side of it because the pattern has already decided
// what takes part.
//
// It is a function rather than a one element literal because this compiler's formatter rewrites
// []int{pos} into a struct literal, which does not parse.
pub fn one_at(pos int) []int {
	mut out := []int{cap: 1}
	out << pos
	return out
}

// ligatables turns a replacement sequence into run items that all carry one character's cluster.
//
// They share it because that is what they are: several glyphs of a single input character, which
// is the case a layout pass has to be told about separately.
//
// A piece the font classifies as a mark is flagged as one even when the input was not: a 1:N
// split of a base letter produces the letter's dot components, and the font's GDEF table is
// what says those are marks. Without the flag they draw at the pen unplaced, which is how
// Nastaliq rendered its dots. A font with no GDEF answers from the input alone, which is what
// this did before.
//
// A fusion is a new glyph, so the font classifies it: a ligature whose
// inputs are marks is still a mark only when the font says its product
// is one. Khmer's COENG is a mark, and every coeng fusion would otherwise
// ride as one — but the pstf and pref products are GDEF bases with a real
// advance (COENG+KHO is 0xba at 294 units, COENG+RO is 0xdc at 287), and
// HarfBuzz advances them as bases. Only the blwf products are GDEF marks.
// A single, multiple or alternate product the font positively classifies
// is classified the same way: a Bengali pres single turns the U-matra
// into a spacing variant (gid 276 is GDEF base with a 194-unit advance)
// and an abvs chain swaps AA and candrabindu (gid 59 is GDEF base), and a
// mark input staying a mark there would park both at the pen with no
// advance. A product the font leaves unclassified keeps the input flag,
// which is what a mark composing through ccmp keeps when the font never
// classified it.
pub fn (g &Gsub) ligatables(seq []u16, from Ligatable, is_fusion bool) []Ligatable {
	mut out := []Ligatable{cap: seq.len}
	for gid in seq {
		mut is_mark := from.is_mark
		if gd := g.gdef {
			if is_fusion || !is_mark || gd.is_base(gid) {
				is_mark = gd.is_mark(gid)
			}
		}
		out << Ligatable{
			gid:     gid
			cluster: from.cluster
			source:  from.source
			form:    from.form
			is_mark: is_mark
		}
	}
	return out
}

// splice applies a substitution's edits to a run.
pub fn splice(items []Ligatable, sub Substitution) []Ligatable {
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
pub fn edit_at(edits []Edit, at int) ?Edit {
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
	want := ot_script_tag(tag)
	for s in g.scripts {
		if s.tag == want {
			return s
		}
	}
	return none
}

// ascii_lower lowercases the ASCII letters in a tag, leaving anything else alone. The tags
// involved are always ASCII, so this does not need to be Unicode-aware.
pub fn ascii_lower(s string) string {
	mut out := []u8{len: s.len}
	for i in 0 .. s.len {
		b := s[i]
		out[i] = if b >= `A` && b <= `Z` { b + 32 } else { b }
	}
	return out.bytestr()
}

// ot_script_tag is the OpenType script tag for a Unicode script tag: lowercased,
// with the scripts OpenType files under a shared tag folded together. Hiragana
// has no tag of its own — a font files hiragana and katakana rules alike under
// kana, which is where MS Gothic keeps its vert variants and its dakuten
// anchors, so asking under hira finds nothing on a file that reads correctly
// everywhere else. Katakana, Han and Latin already arrive spelled the way the
// files spell them and pass through unchanged.
pub fn ot_script_tag(tag string) string {
	lower := ascii_lower(tag)
	if lower == 'hira' {
		return 'kana'
	}
	// Three OpenType tags pad with a space where the engine's UCD-derived
	// spelling has a letter: Laoo/Nkoo/Yiii are 'lao '/'nko '/'yi ' in the
	// fonts. Without the pad a Lao run resolves no script and silently
	// draws unshaped: cmap gids with no features and marks at the pen.
	return match lower {
		'laoo' { 'lao ' }
		'nkoo' { 'nko ' }
		'yiii' { 'yi ' }
		else { lower }
	}
}

// ot_script_tags_in_order answers the OpenType tags one script name can
// mean, most likely first. UCD names arrive in full ('Deva', 'Bengali');
// OpenType files them under four-letter tags, and Indic v2 layouts live
// under sibling tags the v1 spelling does not name ('bng2' beside 'beng',
// 'dev2' beside 'deva', 'mym2' beside 'mymr'). The engine tries each tag
// the font actually carries, so a bng2-only face answers Bengali runs
// while a deva/dev2 face keeps answering under the tag it always did.
// New sibling pairs arrive with their faces, the way the scripts
// themselves do.
fn ot_script_tags_in_order(script string) []string {
	want := ot_script_tag(script)
	// The v2 tag goes first: HarfBuzz resolves the v2 shaping model, and a
	// font can split a feature across the two records — Noto Bengali files
	// dist lookups 0 and 1 under `beng` but the chaining contextual kern
	// (kri +200) only under `bng2`, so a v1-first order never sees it.
	// A v1-only face still answers under its own tag when v2 misses.
	if want == 'bengali' {
		return ['bng2', 'beng']
	}
	sibling := match want {
		'deva' { ['dev2', 'deva'] }
		'dev2' { ['dev2', 'deva'] }
		'beng' { ['bng2', 'beng'] }
		'bng2' { ['bng2', 'beng'] }
		'mymr' { ['mym2', 'mymr'] }
		'mym2' { ['mym2', 'mymr'] }
		else { [want] }
	}
	return sibling
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
pub fn (g &Gsub) shaped_glyph(gid u16, form JoiningForm, script string, lang string) u16 {
	tag := feature_tag_for(form)
	if tag == '' {
		return gid
	}
	return g.apply(g.lookups_for_lang(script, lang, tag), gid)
}

// lookups_for returns the lookups a script's feature names, in the order to apply them.
pub fn (g &Gsub) lookups_for(script string, feature string) []u16 {
	return g.lookups_for_lang(script, '', feature)
}

// lookups_for_lang is lookups_for under a language: the tagged language
// system when the font names it, the default language system otherwise. An
// empty language is the default, which is what every line shaped before the
// language control existed. A language the font does not tag falls back to
// the default the way HarfBuzz falls back, rather than to nothing.
pub fn (g &Gsub) lookups_for_lang(script string, lang string, feature string) []u16 {
	for tag in ot_script_tags_in_order(script) {
		if out := g.lookups_in_script(tag, lang, feature) {
			return out
		}
	}
	return []u16{}
}

// lookups_in_script is one tag of lookups_for_lang: the tagged language
// system when the font names it, the default language system otherwise. An
// empty language is the default, which is what every line shaped before the
// language control existed. A language the font does not tag falls back to
// the default the way HarfBuzz falls back, rather than to nothing.
//
// A language the font tags but that names no rule for the feature answers
// nothing: the language system was found, so there is no wider net to cast.
fn (g &Gsub) lookups_in_script(tag string, lang string, feature string) ?[]u16 {
	for s in g.scripts {
		if s.tag != tag {
			continue
		}
		if lang != '' {
			want := ot_lang_tag(lang)
			for l in s.langs {
				if ot_lang_tag(l.tag) == want {
					for f in l.features {
						if f.tag == feature {
							return f.lookups
						}
					}
					return []u16{}
				}
			}
		}
		for f in s.features {
			if f.tag == feature {
				return f.lookups
			}
		}
	}
	return none
}

// ot_lang_tag is the OpenType language tag for a caller's language: uppercased
// with the surrounding space tolerated, so 'urd', 'URD' and 'URD ' name one
// language. It is deliberately not a BCP 47 map: a two-letter code is not an
// OpenType tag ('ur' is not 'URD'), and a table mapping every code the way
// HarfBuzz does would be data no font here needs. The caller names the tag
// the font spells.
pub fn ot_lang_tag(lang string) string {
	mut out := []u8{len: lang.len}
	for i in 0 .. lang.len {
		b := lang[i]
		out[i] = if b >= `a` && b <= `z` { b - 32 } else { b }
	}
	return out.bytestr().trim_space()
}

// parse_lookups reads the LookupList and every rule this milestone understands.
pub fn parse_lookups(r &Reader, off int) []Lookup {
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
				if c := parse_chain1(r, resolved.at) {
					lookup.chain_glyphs << c
				}
				if c := parse_chain2(r, resolved.at) {
					lookup.chain_classes << c
				}
			}
			if resolved.kind == gsub_lookup_context {
				if c := parse_context1(r, resolved.at) {
					// Coverage indices are per subtable, so the two lists grow
					// together: appending both keeps every set aligned with the
					// coverage range that owns it.
					lookup.context_coverage << c.context_coverage
					lookup.context_sets << c.context_sets
				}
				if c := parse_context2(r, resolved.at) {
					lookup.context_classes << c
				}
				if c := parse_context3(r, resolved.at) {
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

// has_context_rules reports whether a lookup holds any plain-context rule at all. An
// empty rule list substitutes nothing, and without this a lookup whose subtables all
// failed to parse would still claim the context type and skip the other kinds.
pub fn has_context_rules(l &Lookup) bool {
	for set in l.context_sets {
		if set.len > 0 {
			return true
		}
	}
	// A class subtable with no non-empty set substitutes nothing either, so both
	// halves of the plain side are checked before the kind is claimed.
	for cc in l.context_classes {
		for set in cc.sets {
			if set.len > 0 {
				return true
			}
		}
	}
	return false
}

// has_chain_rules reports whether a lookup holds any chaining rule at all, in any of
// the three forms. Like the plain side, an unparsable subtable claims nothing.
pub fn has_chain_rules(l &Lookup) bool {
	if l.chains.len > 0 {
		return true
	}
	for cg in l.chain_glyphs {
		for set in cg.sets {
			if set.len > 0 {
				return true
			}
		}
	}
	for cc in l.chain_classes {
		for set in cc.sets {
			if set.len > 0 {
				return true
			}
		}
	}
	return false
}

// longest_ligature_of counts the components of the longest ligature rule a lookup holds.
//
// It is a separate function because it runs once per lookup rather than once per position, which is the
// whole reason it is not written inline where it would be needed.
pub fn longest_ligature_of(l &Lookup) int {
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
pub fn lookup_kind_of(l &Lookup, header_kind u16) u16 {
	if has_chain_rules(l) {
		return gsub_lookup_chain_context
	}
	if has_context_rules(l) {
		return gsub_lookup_context
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

// CoverageList is one of a chaining context's three coverage lists, together with where the field
// after it begins.
//
// The position is returned rather than advanced through a mutable argument because the three
// lists are read in sequence from one running offset, and threading an int by reference is not
// something V will do.
pub struct CoverageList {
pub mut:
	ranges [][]CoverageRange
	next   int
}

// read_coverages reads one of a chaining context's three coverage lists.
//
// Every offset in the list is two bytes and relative to the start of the subtable. A coverage that
// does not parse is kept as an empty entry rather than dropped, because these lists are positional:
// the third input coverage belongs to the third input glyph whatever happens to the first two, and
// dropping a bad one would match every glyph after it against the wrong rule.
pub fn read_coverages(r &Reader, at int, p int) CoverageList {
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

// coverage_glyph_at returns the glyph at a coverage index, which is the glyph a ligature set
// belongs to.
//
// Coverage format 2 stores a range's start index rather than every glyph in it, so this walks
// the ranges counting their lengths. That is the only way to get from a coverage index back to
// a glyph, and a font using format 2 for its ligature coverage needs it.
pub fn coverage_glyph_at(ranges []CoverageRange, index int) u16 {
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
pub fn resolve_subtable(r &Reader, kind u16, at int) ResolvedSubtable {
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

// coverage_fits reports whether the coverage table at cov_at lies fully inside the
// buffer. A count read from the wrong offset is usually enormous, so this is what
// rejects a transposed reading before it draws a wrong glyph: out-of-bounds reads
// answer zero, which would otherwise parse as ranges of glyph 0 rather than failing.
fn coverage_fits(r &Reader, cov_at int) bool {
	format := r.u16_at(cov_at)
	count := int(r.u16_at(cov_at + 2))
	if format == 1 {
		return r.has(cov_at, 4 + count * 2)
	}
	if format == 2 {
		return r.has(cov_at, 4 + count * 6)
	}
	return false
}

// covered_count is how many glyphs a coverage table covers, which is the total length of its
// ranges.
pub fn covered_count(ranges []CoverageRange) int {
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
pub fn parse_coverage(r &Reader, at int) []CoverageRange {
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
pub struct Feature {
pub mut:
	tag     string
	lookups []u16
}

pub fn parse_features(r &Reader, off int) []Feature {
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
pub fn parse_scripts(r &Reader, off int, features []Feature) []Script {
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
			langs:    parse_script_langs(r, script_at, features)
		}
	}
	return out
}

// parse_script_langs reads the tagged language systems of one script: every
// LangSysRecord beside the default, with its tag and the features it enables.
// A language the font does not tag is not listed, and the caller falls back
// to the default language system for it.
pub fn parse_script_langs(r &Reader, script_at int, features []Feature) []ScriptLang {
	mut out := []ScriptLang{}
	count := int(r.u16_at(script_at + 2))
	for i in 0 .. count {
		base := script_at + 4 + i * 6
		if !r.has(base, 6) {
			continue
		}
		tag := r.tag_at(base)
		at := script_at + int(r.u16_at(base + 4))
		mut enabled := []ScriptFeature{}
		for fi in langsys_features_at(r, at) {
			if fi >= features.len {
				continue
			}
			enabled << ScriptFeature{
				tag:     features[fi].tag
				lookups: features[fi].lookups
			}
		}
		out << ScriptLang{
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
pub fn langsys_features(r &Reader, script_at int) []u16 {
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
	return langsys_features_at(r, at)
}

// langsys_features_at returns the feature indices one language system enables,
// read at its own offset: the required feature first, then the listed ones.
// A required feature is not counted in featureIndexCount, so it is read from
// its own field and put first, since a required feature applies whether or
// not it is listed.
pub fn langsys_features_at(r &Reader, at int) []u16 {
	mut out := []u16{}
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
