module vtext

// OpenType glyph substitution, the GSUB table.
//
// This exists because a letter's four Arabic shapes are usually not in the font's cmap. A
// font that keeps them in GSUB carries the base letter once and a rule that swaps in the
// shaped variant, so the joining pass's decision has to be handed to the font to be turned
// into a glyph index. The joining pass could not do this itself: it produces a shape, and
// which glyph carries that shape is a property of the font.
//
// The scope here is the single-substitution lookups behind the four positional features,
// isol, fina, init and medi. That is what makes a font like Dubai render properly joined.
// Ligature substitution needs a run of glyphs rather than one, so it belongs with the rest
// of the shaping pipeline and is not in this milestone.

// Lookup types, from the OpenType specification.
const gsub_lookup_single = 1
const gsub_lookup_ligature = 4
const gsub_lookup_extension = 7

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

// Lookup is one GSUB lookup, holding the rules of the kinds this milestone applies.
struct Lookup {
mut:
	kind    u16
	singles []SingleSubst
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
}

// new_gsub parses the GSUB table, or returns none when the font has none or it does not
// parse. A font without usable substitution is a font whose letters stay in their base shape,
// which is a degraded rendering rather than a broken one, so this never fails.
//
// The parameter is named raw rather than data because data is a field name in this module,
// and a local shadowing a type name makes V resolve methods on the type instead of the
// value, which compiles into a table read that returns nothing.
pub fn new_gsub(raw []u8) ?&Gsub {
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
		lookups: lookups
		scripts: parse_scripts(r, script_list, features)
	}
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
		if lookup.kind != gsub_lookup_single {
			continue
		}
		if sub := single_lookup(lookup.singles, out) {
			out = sub
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
		mut lookup := Lookup{ kind: r.u16_at(at) }
		subtable_count := int(r.u16_at(at + 4))
		for j in 0 .. subtable_count {
			// Each subtable offset is relative to the lookup.
			resolved := resolve_subtable(r, lookup.kind, at + int(r.u16_at(at + 6 + j * 2)))
			// The type that governs the lookup is the one the rules actually have, which for
			// an extension lookup is the type the extension names rather than the one in the
			// header. Recording it is what lets a caller see what was found.
			if lookup.kind == gsub_lookup_extension {
				lookup.kind = resolved.kind
			}
			if resolved.kind == gsub_lookup_single {
				if s := parse_single_subst(r, resolved.at) {
					lookup.singles << s
				}
			}
		}
		out << lookup
	}
	return out
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
