module font

// OpenType glyph positioning, the GPOS table, and the GDEF table that says what it is talking
// about.
//
// The job here is mark attachment. A combining mark is not a letter that happens to sit above
// another letter: it has an anchor on the letter it belongs to, and the font says where. The
// mark carries its own anchor, the base carries one per mark class, and the mark goes wherever
// the two agree. Without this a mark lands at the pen position, which for an Arabic letter is
// at the baseline and at the left edge, so a fatha over a beh comes out beside it rather than
// above it.
//
// GDEF is read alongside because a font will not say which glyphs are marks without a class
// definition, and a mark-to-base lookup needs the class of the mark to pick which of the base's
// anchors to use.

// Offset2 is a displacement in font design units, with y positive upwards. It is returned as an
// option everywhere it appears, because a font that does not say where to put a mark has to be
// distinguishable from a font that says to put it at the origin.
pub struct Offset2 {
pub:
	x i32
	y i32
}

// CursiveAnchors are the two ends of one glyph's joining stroke, in design units.
//
// The two are separately optional, because a font says what a letter needs rather than what it has: the
// first letter of a word has an entry and no exit, the last has an exit and no entry, and a letter in the
// middle of a word has both. `entry_exists` and `exit_exists` say which a font actually gave, rather than
// a caller having to treat an absent anchor as the origin and attach a stroke that does not exist.
pub struct CursiveAnchors {
pub:
	entry        Offset2
	exit         Offset2
	entry_exists bool
	exit_exists  bool
}

// GPOS lookup types, from the OpenType specification.
pub const gpos_lookup_single_position = 1
pub const gpos_lookup_pair = 2
// Cursive attachment. It is named here for the same reason every other kind is and is not applied: the
// reader below parses the entry and exit anchors, and the two-pass attachment that would use them is not
// written. Naming it means a report can say "this font has cursive positioning and this engine does not
// use it" rather than leaving that to be inferred from a feature tag.
pub const gpos_lookup_cursive = 3
pub const gpos_lookup_mark_to_base = 4
pub const gpos_lookup_mark_to_ligature = 5
pub const gpos_lookup_mark_to_mark = 6
pub const gpos_lookup_chain_context = 8
pub const gpos_lookup_extension = 9

// The GDEF glyph classes. Attachment cares about the first three: a mark attaches to a base or
// to a ligature, and those are the only things it attaches to. The fourth is a component, which
// attachment never sees but the substitution flags do, because a lookup told to ignore base
// glyphs has to step over components too.
pub const glyph_class_base = 1
pub const glyph_class_ligature = 2
pub const glyph_class_mark = 3
pub const glyph_class_component = 4

// ClassDef is a sorted set of glyph ranges carrying a class value, which is how both the glyph
// class table and the mark attachment class table are built.
pub struct ClassDef {
pub mut:
	entries []ClassRangeEntry
}

// ClassRangeEntry is one span of glyphs sharing a class.
pub struct ClassRangeEntry {
pub mut:
	first u16
	last  u16
	value u16
}

// Gdef is the parsed glyph definition table: what kind of glyph each glyph is, and which mark
// attachment class each mark belongs to.
pub struct Gdef {
pub mut:
	// glyph_classes says what each glyph is. Marks are the ones attachment cares about.
	glyph_classes ClassDef
	// mark_classes says which anchor on a base each mark belongs under. A font may leave this
	// out, in which case every mark is class zero and uses the base's only anchor.
	mark_classes     ClassDef
	has_mark_classes bool
	// mark_sets are the mark filtering sets, which a lookup can name in place of testing the
	// mark class. They are a later addition than the classes and live behind a version check,
	// and no Arabic font on Windows carries them, so this is empty for most of the fonts this
	// engine is pointed at.
	mark_sets [][]CoverageRange
}

// new_gdef parses the GDEF table, or returns none when the font has none.
pub fn new_gdef(raw []u8) ?&Gdef {
	r := new_reader(raw)
	if r.len() < 12 || r.u16_at(0) != 1 {
		return none
	}
	mut g := &Gdef{}
	// The four offsets are all from the start of the table, not from their own field, which is
	// the one place GDEF is unlike GSUB and GPOS. Reading them relative to the field lands in
	// the middle of a neighbouring subtable and finds a format number that is not a format.
	if r.u16_at(4) != 0 {
		g.glyph_classes = parse_class_def(r, int(r.u16_at(4)))
	}
	if r.u16_at(10) != 0 {
		g.mark_classes = parse_class_def(r, int(r.u16_at(10)))
		g.has_mark_classes = true
	}
	// The mark glyph sets are a fifth offset, and only version 1.2 and later has one. The
	// version has to be the gate rather than the offset being nonzero: in a 1.0 table the fifth
	// slot does not exist, so reading it lands inside the glyph class table and finds whatever
	// class count happens to be sitting there.
	if r.u16_at(2) >= 2 && r.has(12, 2) && r.u16_at(12) != 0 {
		g.mark_sets = parse_mark_glyph_sets(r, int(r.u16_at(12)))
	}
	if g.glyph_classes.entries.len == 0 {
		return none
	}
	return g
}

// parse_mark_glyph_sets reads a MarkGlyphSetsDef, which is a list of coverage tables.
//
// The offsets in it are 32 bits and relative to the start of the MarkGlyphSetsDef rather than to
// their own entry. That is the one thing about this table a 16-bit offset could not have done: a
// font is allowed more coverage tables in here than fit in 64KB of 16-bit offsets.
pub fn parse_mark_glyph_sets(r &Reader, at int) [][]CoverageRange {
	mut out := [][]CoverageRange{}
	if r.u16_at(at) != 1 {
		return out
	}
	count := int(r.u16_at(at + 2))
	for i in 0 .. count {
		base := at + 4 + i * 4
		if !r.has(base, 4) {
			break
		}
		out << parse_coverage(r, at + int(r.u32_at(base)))
	}
	return out
}

// glyph_class returns what kind of glyph this is: 0 unclassified, 1 base, 2 ligature, 3 mark.
// An unclassified glyph is not a mark, which is the answer a font that classifies nothing gives.
pub fn (g &Gdef) glyph_class(gid u16) u16 {
	return g.glyph_classes.class_of(gid)
}

// is_mark reports whether the font says this glyph is a mark.
pub fn (g &Gdef) is_mark(gid u16) bool {
	return g.glyph_class(gid) == glyph_class_mark
}

// mark_class returns the attachment class of a mark, which selects one of the base's anchors.
// A font with no mark attachment class table puts every mark in class zero.
pub fn (g &Gdef) mark_class(gid u16) int {
	if !g.has_mark_classes {
		return 0
	}
	return int(g.mark_classes.class_of(gid))
}

// is_base reports whether the font says this glyph is something a mark can attach to. A
// ligature counts, since a mark over a ligature attaches to the ligature's own anchor.
pub fn (g &Gdef) is_base(gid u16) bool {
	c := g.glyph_class(gid)
	return c == glyph_class_base || c == glyph_class_ligature
}

// is_ligature reports whether the font says this glyph is a ligature, which a substitution
// lookup told to ignore ligatures has to be able to recognise.
pub fn (g &Gdef) is_ligature(gid u16) bool {
	return g.glyph_class(gid) == glyph_class_ligature
}

// is_base_or_component reports whether a lookup told to ignore base glyphs has to step over
// this one. Components count as base for that purpose, which is the whole reason GDEF 1.3
// introduced them: a mark that is a component of a composite glyph is a mark, and a base that
// is one is a base.
pub fn (g &Gdef) is_base_or_component(gid u16) bool {
	c := g.glyph_class(gid)
	return c == glyph_class_base || c == glyph_class_component
}

// in_mark_set reports whether a glyph is in one of the mark filtering sets.
//
// A set index that names nothing is not a match. The alternative is to treat a missing set as
// covering everything, which would make a lookup that named a set silently apply to every mark
// on the line, which is the failure this whole mechanism exists to avoid.
pub fn (g &Gdef) in_mark_set(index int, gid u16) bool {
	if index < 0 || index >= g.mark_sets.len {
		return false
	}
	return coverage_index(g.mark_sets[index], gid) != none
}

// class_of returns the class of a glyph, or 0 when the table does not cover it.
pub fn (c &ClassDef) class_of(gid u16) u16 {
	entries := c.entries
	// The ranges are sorted and do not overlap, which the format guarantees.
	mut lo := 0
	mut hi := entries.len
	for lo < hi {
		mid := (lo + hi) >> 1
		e := entries[mid]
		if gid < e.first {
			hi = mid
		} else if gid > e.last {
			lo = mid + 1
		} else {
			return e.value
		}
	}
	return 0
}

// parse_class_def reads a ClassDef table in either of its two formats.
pub fn parse_class_def(r &Reader, at int) ClassDef {
	mut c := ClassDef{}
	format := r.u16_at(at)
	if format == 1 {
		start := r.u16_at(at + 2)
		mut count := int(r.u16_at(at + 4))
		for i in 0 .. count {
			c.entries << ClassRangeEntry{
				first: start + u16(i)
				last:  start + u16(i)
				value: r.u16_at(at + 6 + i * 2)
			}
		}
		return c
	}
	if format != 2 {
		return c
	}
	count := int(r.u16_at(at + 2))
	for i in 0 .. count {
		base := at + 4 + i * 6
		c.entries << ClassRangeEntry{
			first: r.u16_at(base)
			last:  r.u16_at(base + 2)
			value: r.u16_at(base + 4)
		}
	}
	return c
}

// Gpos is a parsed GPOS table, reduced to mark attachment.
pub struct Gpos {
pub mut:
	lookups []GposLookup
	scripts []Script
	// declared is the whole FeatureList, including the features no language system enables.
	//
	// It is kept apart from the scripts for a reason that only shows up in a report. A script's features
	// are the ones its default language system enables, which is the right answer for shaping a run of
	// text and the wrong answer for "what does this font offer": a font can enable a feature only under a
	// tagged language, and a count built from the scripts misses it. So the list is kept whole and the
	// shaping path is left reading the scripts.
	declared []Feature
	// mark_feature_lookups are the lookups of the mark feature for the Arabic script, which is
	// where a font puts mark-to-base rules for Arabic letters.
	mark_feature_lookups []u16
	// mark_sets are the GDEF mark filtering sets, carried so a gated lookup
	// can test membership: a lookup whose flag names USE_MARK_FILTERING_SET
	// applies only to marks in its set. Copied from the face's GDEF at load;
	// a font with no sets answers no membership, so a gated lookup in it
	// matches nothing rather than everything.
	mark_sets [][]CoverageRange
}

// GposLookup is one positioning lookup, holding the rules of the kinds this milestone applies.
pub struct GposLookup {
pub mut:
	kind u16
	// flag is the lookup's flag field: mark attachment class high, ignore
	// glyph classes and USE_MARK_FILTERING_SET (0x0010) low. Only the
	// filtering-set bit is honored, and only on the mark rules below: a
	// lookup gated to a set the mark is not in is skipped. The ignore bits
	// and the attachment class stay open, recorded on mark_offset_on.
	flag u16
	// mark_filtering_set is the GDEF mark glyph set index, meaningful only
	// when flag names USE_MARK_FILTERING_SET. A font whose GDEF carries no
	// sets answers no membership, so a gated lookup in it matches nothing.
	mark_filtering_set u16
	// mark_bases are mark-to-base rules, where the second glyph is a letter.
	mark_bases []MarkToBase
	// mark_marks are mark-to-mark rules, which have exactly the shape of a mark-to-base rule and
	// differ only in what the second glyph is. They are held apart because the engine has to know
	// which one it is applying: a mark attaches to a mark only when the font says how, and
	// attaching it to the letter underneath instead is a different placement.
	mark_marks []MarkToBase
	// mark_ligatures are mark-to-ligature rules, where the second glyph has one anchor set per
	// component.
	mark_ligatures []MarkToLigature
	// pairs are pair-adjustment rules, which is kerning: how far to move one glyph when a
	// particular glyph follows it. A lookup holds either these or the mark rules, never both,
	// because a lookup has one type and the type says which of the two it is.
	pairs []PairPos
	// chains are chaining-context rules, which position a glyph based on what is around it.
	chains []ChainPosition
	// chain_classes are the class-based chaining rules, the same idea through glyph
	// classes rather than coverage tables. A lookup holds one kind or the other.
	chain_classes []ChainClass2
	// chain_glyphs are the glyph-based chaining rules (format 1): the same idea
	// through glyph ids, one rule list per covered first glyph.
	chain_glyphs []ChainGlyph1
	// singles are single positioning rules, which move one glyph on its own. A context record usually
	// names one of these rather than a pair rule, so a font that says "this glyph moves when it follows
	// that one" is reachable only if these are parsed.
	singles []SinglePos
	// cursives are cursive attachment rules, which say where a glyph's stroke enters and leaves. This
	// is what makes a cursive script continuous rather than merely joined, and it changes the shape of
	// a line rather than adding something beside it.
	cursives []Cursive
}

// new_gpos parses the GPOS table, or returns none when the font has none or it does not parse.
pub fn new_gpos(raw []u8) ?&Gpos {
	r := new_reader(raw)
	if r.len() < 10 || r.u16_at(0) != 1 {
		return none
	}
	script_list := int(r.u16_at(4))
	feature_list := int(r.u16_at(6))
	lookup_list := int(r.u16_at(8))
	for at in [script_list, feature_list, lookup_list] {
		if at == 0 || !r.has(at, 2) {
			return none
		}
	}
	lookups := parse_gpos_lookups(r, lookup_list)
	if lookups.len == 0 {
		return none
	}
	features := parse_features(r, feature_list)
	mut g := &Gpos{}
	g.lookups = lookups
	g.scripts = parse_scripts(r, script_list, features)
	g.declared = features
	// Arabic fonts do not put their mark rules under the generic mark feature. Above-base marks
	// live under abvm and below-base marks under blwm, which is what lets a font attach a fatha
	// high on a letter and a kasra low on the same one. Asking for mark alone finds them on the
	// Latin fonts and nothing at all on the Arabic ones, which is the same silent failure the
	// script tag case caused.
	//
	// A mark on another mark is a fourth feature, mkmk, and it is not one of the three above. The
	// fonts that carry these rules put them there and nowhere else: Tahoma has thirteen mark-to-mark
	// subtables and every one of them is under mkmk, so a lookup of abvm, blwm and mark finds none
	// of them and stacking two accents silently falls back to putting both against the letter.
	//
	// The order is abvm, blwm, mark then mkmk, and it matters only in that a rule found first wins.
	// A font does not put the same mark under two of them, so the order is not load bearing; it is
	// written this way because those are the features a mark can be under. Within one
	// feature the first matching lookup wins. That is an approximation: a
	// font can stack a chaining rule past an absolute one, and composing a
	// chain adjustment over an absolute mark placement belongs to the GPOS
	// open work. The Khmer SRA II that used to witness it (+615 off TA
	// under first-wins against HarfBuzz's -32 from the chain) now resolves
	// HB-exact — the coeng fusion removed TA and the first match agrees —
	// so the approximation stands without a pinned witness.
	for feat in ['abvm', 'blwm', 'mark', 'mkmk'] {
		g.mark_feature_lookups << g.lookups_for('arab', feat)
	}
	return g
}

// mark_feature_lookups_for returns the lookups of the mark features for the script a
// caller names, which is where a font puts mark-to-base rules for that script. Arabic
// fonts put above-base marks under abvm and below-base marks under blwm; Latin fonts
// use mark and mkmk the same way. Asking per script rather than collecting once is
// what keeps an Arabic rule from placing a Latin mark, and a Latin rule from placing
// an Arabic one. The parse-time list names arab because that is the script this
// library was developed against; the shaping path asks per run instead.
pub fn (g &Gpos) mark_feature_lookups_for(script string, lang string) []u16 {
	mut out := []u16{}
	for feat in ['abvm', 'blwm', 'mark', 'mkmk'] {
		out << g.lookups_for_lang(script, lang, feat)
	}
	return out
}

// has_mark_attachment reports whether the font has any mark-to-base rule, which is the
// difference between a mark that lands on its letter and one that lands beside it.
pub fn (g &Gpos) has_mark_attachment() bool {
	if g.mark_feature_lookups.len == 0 {
		return false
	}
	for li in g.mark_feature_lookups {
		if li < g.lookups.len && g.lookups[li].kind == gpos_lookup_mark_to_base {
			return true
		}
	}
	return false
}

// feature_tags lists every feature tag the table's FeatureList names, with the duplicates a font creates
// by listing the same tag twice collapsed into one.
//
// The list is the FeatureList rather than the scripts' features, because those are one language system's
// answer and this is a question about the font. The two differ in both directions, and both directions
// matter: a font can offer a feature no default language system reaches, and it can offer one nothing in
// this engine will ever read.
//
// Dubai is the case worth naming for the second. Its GPOS declares 'curs', so a report of the tags says
// the font has cursive positioning, and not one of its lookups is applied by anything here. That is not a
// contradiction to be resolved by hiding the tag. It is the difference between what a font can do and
// what this engine does, and the only way to see it is to print both.
pub fn (g &Gpos) feature_tags() []string {
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
pub fn (g &Gpos) script_tags() []string {
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

// lookups_for returns the lookups a script's feature names, in the order to apply them.
pub fn (g &Gpos) lookups_for(script string, feature string) []u16 {
	return g.lookups_for_lang(script, '', feature)
}

// lookups_for_lang is lookups_for under a language: the tagged language
// system when the font names it, the default language system otherwise. An
// empty language is the default, which is what every line shaped before the
// language control existed. Sibling script tags are tried in order, the way
// the GSUB resolver does, so Indic v2 layouts answer under either spelling.
pub fn (g &Gpos) lookups_for_lang(script string, lang string, feature string) []u16 {
	for tag in ot_script_tags_in_order(script) {
		if out := g.lookups_in_script(tag, lang, feature) {
			return out
		}
	}
	return []u16{}
}

// lookups_in_script is one tag of lookups_for_lang. A language the font
// tags but that names no rule for the feature answers nothing: the language
// system was found, so there is no wider net to cast.
fn (g &Gpos) lookups_in_script(tag string, lang string, feature string) ?[]u16 {
	for s in g.scripts {
		if s.tag != tag {
			continue
		}
		if lang != '' {
			want_lang := ot_lang_tag(lang)
			for l in s.langs {
				if ot_lang_tag(l.tag) == want_lang {
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

// parse_gpos_lookups reads the LookupList and the mark-to-base rules.
pub fn parse_gpos_lookups(r &Reader, off int) []GposLookup {
	mut out := []GposLookup{}
	if !r.has(off, 2) {
		return out
	}
	count := int(r.u16_at(off))
	for i in 0 .. count {
		at := off + int(r.u16_at(off + 2 + i * 2))
		if !r.has(at, 6) {
			out << GposLookup{ kind: 0 }
			continue
		}
		mut lookup := GposLookup{ kind: r.u16_at(at) }
		// The type the lookup declares, kept apart from `lookup.kind` because the latter is rewritten at the
		// end of this loop to whatever the lookup turned out to hold. The resolver has to see the declared
		// type on every subtable: a lookup wrapping four rules has one extension header covering all four,
		// and resolving the second against the type the first resolved to would read a rule as if it were a
		// wrapper.
		header_kind := lookup.kind
		subtable_count := int(r.u16_at(at + 4))
		lookup.flag = r.u16_at(at + 2)
		// The mark filtering set trails the subtable offsets, and only when
		// the flag asks for it: reading it unconditionally lands in the next
		// lookup's header on fonts that never set the bit.
		if lookup.flag & 0x0010 != 0 {
			set_at := at + 6 + subtable_count * 2
			if r.has(set_at, 2) {
				lookup.mark_filtering_set = r.u16_at(set_at)
			}
		}
		for j in 0 .. subtable_count {
			resolved := resolve_gpos_subtable(r, header_kind, at + int(r.u16_at(at + 6 + j * 2)))
			if resolved.kind == gpos_lookup_mark_to_base {
				if rule := parse_mark_to_base(r, resolved.at) {
					lookup.mark_bases << rule
				}
			}
			if resolved.kind == gpos_lookup_mark_to_mark {
				// The two formats are the same shape with a different second glyph, so the same
				// reader serves both and the kind is what tells them apart later.
				if rule := parse_mark_to_base(r, resolved.at) {
					lookup.mark_marks << rule
				}
			}
			if resolved.kind == gpos_lookup_pair {
				if rule := parse_pair_pos(r, resolved.at) {
					lookup.pairs << rule
				}
			}
			if resolved.kind == gpos_lookup_mark_to_ligature {
				if rule := parse_mark_to_ligature(r, resolved.at) {
					lookup.mark_ligatures << rule
				}
			}
			if resolved.kind == gpos_lookup_chain_context {
				if rule := parse_chain_position(r, resolved.at) {
					lookup.chains << rule
				} else {
					if rule := parse_chain_class(r, resolved.at) {
						lookup.chain_classes << rule
					} else {
						if rule := parse_chain_glyph(r, resolved.at) {
							lookup.chain_glyphs << rule
						}
					}
				}
			}
			if resolved.kind == gpos_lookup_cursive {
				if rule := parse_cursive(r, resolved.at) {
					lookup.cursives << rule
				}
			}
			if resolved.kind == gpos_lookup_single_position {
				if rule := parse_single_position(r, resolved) {
					lookup.singles << rule
				}
			}
		}
		// A lookup that reached its real type through an extension reports that type rather than the extension, so
		// that a report counting lookup kinds says what the font does rather than how it is packaged. This runs
		// after every subtable is read, because what a lookup is a function of everything it turned out to hold
		// rather than of its first rule, and the order of the checks is the order of specificity: a lookup with
		// ligature rules in it is a mark-to-ligature lookup even if it also has mark-to-base rules, because that
		// is the rule that would fire on a ligature.
		//
		// A lookup that wraps nothing this engine reads keeps its declared kind, which for an extension is 9 and
		// for anything else is its own number. That is the honest answer: the lookup holds rules of a kind this
		// engine does not read, and saying so is more useful than naming a kind it was inferred to be.
		if lookup.mark_ligatures.len > 0 {
			lookup.kind = gpos_lookup_mark_to_ligature
		} else if lookup.mark_marks.len > 0 {
			lookup.kind = gpos_lookup_mark_to_mark
		} else if lookup.chains.len > 0 || has_chain_classes(lookup)
			|| has_chain_glyphs(lookup) {
			lookup.kind = gpos_lookup_chain_context
		} else if lookup.pairs.len > 0 {
			lookup.kind = gpos_lookup_pair
		} else if lookup.cursives.len > 0 {
			lookup.kind = gpos_lookup_cursive
		} else if lookup.mark_bases.len > 0 {
			lookup.kind = gpos_lookup_mark_to_base
		} else if lookup.singles.len > 0 {
			lookup.kind = gpos_lookup_single_position
		}
		out << lookup
	}
	return out
}

// ResolvedSubtable is a subtable together with the lookup type that actually governs it. It is
// shared with the substitution parser, because the idea is the same: a lookup header may point
// at an extension that names the real type and where it lives.
pub struct ResolvedSubtable {
pub mut:
	kind u16
	at   int
	// length is the subtable's own length in bytes, or zero when nothing states one.
	//
	// Only an extension states one: ExtensionPos writes a uint32 extensionLength after its offset, and
	// the reader had no use for it until a format that runs to the end of its subtable. A lookup's
	// own subtable offsets carry no length, so a subtable reached directly has none and a parser that
	// needs a bound has to find another.
	length int
	// wrapper is where that length is measured from, which is the start of the extension rather than
	// the start of the subtable it points at.
	wrapper int
}

// resolve_gpos_subtable follows an extension lookup to the table it wraps.
//
// Fonts wrap their positioning rules in extensions for the same reason they wrap substitution
// rules, so ignoring the wrapper would leave every mark at the pen position.
pub fn resolve_gpos_subtable(r &Reader, kind u16, at int) ResolvedSubtable {
	if kind != gpos_lookup_extension {
		return ResolvedSubtable{
			kind: kind
			at:   at
		}
	}
	//	ExtensionPosFormat1
	//	    uint16   format            = 1
	//	    uint16   extensionLookupType
	//	    uint32   extensionOffset
	//	    uint32   extensionLength
	if !r.has(at, 12) {
		return ResolvedSubtable{ kind: 0, at: 0 }
	}
	return ResolvedSubtable{
		kind:    r.u16_at(at + 2)
		at:      at + int(r.u32_at(at + 4))
		length:  int(r.u32_at(at + 8))
		wrapper: at
	}
}

// Device is one size-dependent adjustment: how many pixels to add to a value at each ppem in a
// range. A Device table corrects the scaled design units where rounding lands a pixel off, so its
// deltas are pixels at a ppem, not design units, and there is one delta per size from start to end.
//
// No font measured carries one — zero across 2,450,058 value records on this machine — so nothing
// in the engine applies it. This reader is the tested primitive for when one appears, in the same
// standing as the SinglePos format 2 reader: correct against the specification and pinned by bytes.
pub struct Device {
pub mut:
	// start and end are the smallest and largest ppem the table corrects.
	start u16
	end   u16
	// format is 1, 2 or 3: signed 2-, 4- or 8-bit deltas packed most-significant first.
	format u16
	// deltas holds one signed pixel adjustment per ppem from start, clamped to the bytes present.
	deltas []i8
}

// read_device parses one Device table at `at`, bounded by `limit`, which is the exclusive end of
// whatever encloses the table — the buffer's own length, or the extension wrapper's bound the way
// the SinglePos format 2 scan bounds itself. A table that overruns its bound is read as far as it
// goes rather than refused, because a truncated table still corrects the sizes its bytes cover.
//
// A 0x8000 format is a VariationIndex, which names a delta-set index in the item variation store
// rather than carrying deltas, and resolves to zero at the default instance — the only instance
// this engine shapes. It is not a Device table and reads as none here.
pub fn read_device(r &Reader, at int, limit int) ?Device {
	if !r.has(at, 6) {
		return none
	}
	start := r.u16_at(at)
	end := r.u16_at(at + 2)
	format := r.u16_at(at + 4)
	if format != 1 && format != 2 && format != 3 {
		return none
	}
	if end < start {
		return none
	}
	bits := if format == 1 {
		2
	} else if format == 2 {
		4
	} else {
		8
	}
	per := 16 / bits
	mut count := int(end - start) + 1
	mut avail := 0
	if limit > at + 6 {
		avail = (limit - (at + 6)) / 2
	}
	if count > avail * per {
		count = avail * per
	}
	mut deltas := []i8{cap: count}
	for i in 0 .. count {
		w := int(r.u16_at(at + 6 + (i / per) * 2))
		shift := 16 - bits * (i % per + 1)
		mut raw := (w >> shift) & ((1 << u32(bits)) - 1)
		half := 1 << u32(bits - 1)
		if raw >= half {
			raw -= 1 << u32(bits)
		}
		deltas << i8(raw)
	}
	return Device{
		start:  start
		end:    end
		format: format
		deltas: deltas
	}
}

// delta_at returns the pixel adjustment for ppem, or zero outside the table's range or past what
// its bytes cover. A ppem the table does not name is not corrected, which is the same answer as a
// table that never existed.
pub fn (d &Device) delta_at(ppem int) int {
	if ppem < int(d.start) || ppem > int(d.end) {
		return 0
	}
	i := ppem - int(d.start)
	if i < 0 || i >= d.deltas.len {
		return 0
	}
	return int(d.deltas[i])
}

// parse_anchor reads an Anchor table.
//
// Format 1 is a point. Formats 2 and 3 add a contour point and device tables, both of which are
// about hinting and variations rather than about where the mark goes, so the coordinates are
// read from all three and the rest is ignored. The tables a font uses here are small, and the
// offsets are all bounds checked, so a malformed one costs nothing but the placement.
// parse_anchor_at resolves an anchor offset against the array the offset is measured from.
//
// A zero offset means there is no anchor, and that has to be tested before the addition rather
// than after: adding it lands on the array itself, where the bytes read as an anchor format are
// the first record's own offset. Those are usually small numbers, so a missing anchor silently
// becomes a real anchor at a plausible-looking place instead of being reported missing. That is
// how a mark ends up somewhere the font never asked for.
pub fn parse_anchor_at(r &Reader, base int, offset int) Anchor {
	if offset == 0 {
		return Anchor{}
	}
	return parse_anchor(r, base + offset)
}

pub fn parse_anchor(r &Reader, at int) Anchor {
	format := r.u16_at(at)
	if format < 1 || format > 3 {
		return Anchor{}
	}
	if !r.has(at, 4) {
		return Anchor{}
	}
	return Anchor{
		x:      i32(r.i16_at(at + 2))
		y:      i32(r.i16_at(at + 4))
		exists: true
	}
}
