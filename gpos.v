module vtext

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

// GPOS lookup types, from the OpenType specification.
const gpos_lookup_single_position = 1
const gpos_lookup_pair = 2
const gpos_lookup_mark_to_base = 4
const gpos_lookup_mark_to_ligature = 5
const gpos_lookup_mark_to_mark = 6
const gpos_lookup_chain_context = 8
const gpos_lookup_extension = 9

// The GDEF glyph classes. Attachment cares about the first three: a mark attaches to a base or
// to a ligature, and those are the only things it attaches to. The fourth is a component, which
// attachment never sees but the substitution flags do, because a lookup told to ignore base
// glyphs has to step over components too.
const glyph_class_base = 1
const glyph_class_ligature = 2
const glyph_class_mark = 3
const glyph_class_component = 4

// ClassDef is a sorted set of glyph ranges carrying a class value, which is how both the glyph
// class table and the mark attachment class table are built.
struct ClassDef {
mut:
	entries []ClassRangeEntry
}

// ClassRangeEntry is one span of glyphs sharing a class.
struct ClassRangeEntry {
	first u16
	last  u16
	value u16
}

// Gdef is the parsed glyph definition table: what kind of glyph each glyph is, and which mark
// attachment class each mark belongs to.
pub struct Gdef {
mut:
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
fn parse_mark_glyph_sets(r &Reader, at int) [][]CoverageRange {
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
fn (c &ClassDef) class_of(gid u16) u16 {
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
fn parse_class_def(r &Reader, at int) ClassDef {
	mut c := ClassDef{}
	format := r.u16_at(at)
	if format == 1 {
		start := r.u16_at(at + 2)
		count := int(r.u16_at(at + 4))
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

// Anchor is one attachment point on a glyph, in design units.
//
// An anchor that is not there is different from an anchor at the origin, which is why this
// carries a flag: the first is "this font says nothing", and drawing a mark at the origin
// because the font was silent would be a lie about the font.
struct Anchor {
	x      i32
	y      i32
	exists bool
}

// MarkToBase is one mark-to-base lookup: for a mark and a base, the offset that puts the mark
// onto one of the base's anchors.
struct MarkToBase {
	// mark_ranges is the coverage of the marks this lookup covers.
	mark_ranges []CoverageRange
	// base_ranges is the coverage of the bases it can attach to.
	base_ranges []CoverageRange
	// class_count is how many anchors each base carries.
	class_count int
	// mark_anchors and mark_classes are indexed by the mark's coverage index, which is the
	// order the mark array is written in.
	mark_anchors []Anchor
	mark_classes []u16
	// base_anchors is indexed by the base's coverage index, and each entry is indexed by the
	// mark's class.
	base_anchors [][]Anchor
}

// LigatureAnchorPair is one component's two anchors for one mark class: the point on the ligature
// and the point on the mark that have to meet.
struct LigatureAnchorPair {
mut:
	ligature Anchor
	mark     Anchor
}

// LigatureComponent is one component of one ligature, with a pair of anchors per mark class.
struct LigatureComponent {
mut:
	pairs []LigatureAnchorPair
}

// MarkToLigature is one mark-to-ligature lookup: where a mark goes on a ligature, which is not the
// same place for every part of the ligature.
//
// A lam-alef is the case this exists for. The pair is drawn as one glyph, and a mark written
// after it belongs to the alef rather than to the lam, so the font carries an anchor per component
// and the engine has to know which component the mark belongs to. A mark written after the pair
// belongs to the last component, which is the only case a caller can express today: a mark in the
// middle of a lam-alef is a third thing, and one this does not model.
struct MarkToLigature {
	// mark_ranges is the coverage of the marks this lookup covers.
	mark_ranges []CoverageRange
	// ligature_ranges is the coverage of the ligatures it can attach to.
	ligature_ranges []CoverageRange
	// class_count is how many mark classes there are, and so how many anchor pairs each component
	// carries.
	class_count int
	// mark_anchors and mark_classes are indexed by the mark's coverage index, which is the order
	// the mark array is written in.
	mark_anchors []Anchor
	mark_classes []u16
	// components is indexed by the ligature's coverage index, and each entry is that ligature's
	// components in order.
	components [][]LigatureComponent
}

// ContextRecord is one positioning a chaining context performs once its pattern has matched: which
// of the input positions it applies to, and which lookup does the work.
//
// A record is a pair of indices and carries no value of its own. That is worth saying because the
// substitution side of the specification has a field here that looks like it belongs in a positioning
// record too, and reading it takes a word that belongs to this record instead. The whole thing then
// shifts by one, and the lookup index becomes whatever the sequence index should have been.
struct ContextRecord {
mut:
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
// Format 3 is the form the Arabic fonts this engine reads use. It names coverage tables directly, so
// matching it is a run of binary searches with no second lookup step, where formats 1 and 2 would
// need a class for every glyph in the pattern and then a jump through a rule set to find out what to
// do about it.
struct ChainPosition {
mut:
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
fn parse_chain_position(r &Reader, at int) ?ChainPosition {
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

// Gpos is a parsed GPOS table, reduced to mark attachment.
pub struct Gpos {
mut:
	lookups []GposLookup
	scripts []Script
	// mark_feature_lookups are the lookups of the mark feature for the Arabic script, which is
	// where a font puts mark-to-base rules for Arabic letters.
	mark_feature_lookups []u16
}

// GposLookup is one positioning lookup, holding the rules of the kinds this milestone applies.
struct GposLookup {
mut:
	kind u16
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
	// singles are single positioning rules, which move one glyph on its own. A context record usually
	// names one of these rather than a pair rule, so a font that says "this glyph moves when it follows
	// that one" is reachable only if these are parsed.
	singles []SinglePos
}

// mark_glyphs_passthrough reports whether the mark glyphs a font uses in its positioning rules
// are the ones its cmap maps the marks to.
//
// It exists because the two are not always the same and the difference matters. A font that
// composes its marks through a ccmp substitution has its positioning rules written against the
// composed glyph, not against the one the cmap hands out, so a mark that has not been through
// that substitution will not be found in any coverage.
//
// The composition is run, so this is no longer a report of something the engine has not done. It
// is a report of a font whose composition rules are written against glyphs the pipeline never
// produces, which is Dubai's case and is not a thing the substitution pass can fix: the rules are
// reachable and parsed, and there is simply no path from the text to the glyphs they name.
pub fn (f &Font) mark_glyphs_passthrough() bool {
	gpos := f.face.gpos or { return true }
	return gpos.covers_mark(f.glyph_index(rune(0x064E)))
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
	// written this way because those are the features a mark can be under.
	for feat in ['abvm', 'blwm', 'mark', 'mkmk'] {
		g.mark_feature_lookups << g.lookups_for('arab', feat)
	}
	return g
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

// lookups_for returns the lookups a script's feature names, in the order to apply them.
pub fn (g &Gpos) lookups_for(script string, feature string) []u16 {
	want := ascii_lower(script)
	for s in g.scripts {
		if s.tag != want {
			continue
		}
		for f in s.features {
			if f.tag == feature {
				return f.lookups
			}
		}
	}
	return []u16{}
}

// covers_mark reports whether any mark-to-base rule covers this glyph, which is how a caller
// can tell "this font has no rule for that mark" from "this font's rules are written against a
// different glyph".
pub fn (g &Gpos) covers_mark(gid u16) bool {
	for li in g.mark_feature_lookups {
		if li >= g.lookups.len {
			continue
		}
		for rule in g.lookups[li].mark_bases {
			if coverage_index(rule.mark_ranges, gid) != none {
				return true
			}
		}
	}
	return false
}

// mark_offset returns where to put a mark, relative to the origin of the base it belongs to, in
// design units.
//
// The offset is the difference between the two anchors: the mark's own anchor has to land on
// the base's anchor for the mark's class, so the mark moves by however far apart they are. A
// base with no anchor for that class is not an error, it is a font that does not say where to
// put this mark, and none is returned so that the caller can leave the mark at the pen rather
// than invent a position for it.
//
// y is positive upwards, which is the direction the font's own coordinates run in. A renderer
// working in screen coordinates has to flip it.
pub fn (g &Gpos) mark_offset(mark_gid u16, base_gid u16, base_is_mark bool) ?Offset2 {
	for li in g.mark_feature_lookups {
		if li >= g.lookups.len {
			continue
		}
		lookup := g.lookups[li]
		if base_is_mark {
			for rule in lookup.mark_marks {
				if off := rule.offset_for(mark_gid, base_gid) {
					return Offset2{ x: off.x, y: off.y }
				}
			}
			continue
		}
		// The ligature rules are tried before the base rules because a ligature is not a base: a
		// font that positions marks on a lam-alef does so per component, and a mark-to-base rule
		// that happened to cover the same glyph would place it on the wrong part of the pair.
		for rule in lookup.mark_ligatures {
			if off := rule.offset_for(mark_gid, base_gid) {
				return Offset2{ x: off.x, y: off.y }
			}
		}
		// The base rules are whatever landed in mark_bases, which is only ever filled from a
		// mark-to-base subtable. Asking whether the lookup is typed 4 would work too, but it is
		// the rules that were read that matter, and an extension lookup that resolved to this is
		// typed 9 until something says otherwise.
		for rule in lookup.mark_bases {
			if off := rule.offset_for(mark_gid, base_gid) {
				return Offset2{ x: off.x, y: off.y }
			}
		}
	}
	return none
}

// offset_for finds the attachment for one mark and one component of one ligature.
//
// The component is the ligature's last one, because that is the only one a caller can mean: a mark
// written after a fused pair belongs to the last character of the pair, and a mark written between
// the two characters is a thing this does not represent.
//
// Both anchors have to be there. A ligature anchor on its own says where a mark goes but not
// which way up the mark should sit, and a mark anchor on its own says where the mark's own origin
// belongs but nothing about the ligature, so a pair with only one half present is not enough to
// place the mark and none is returned.
fn (rule &MarkToLigature) offset_for(mark_gid u16, ligature_gid u16) ?Offset2 {
	mark_index := coverage_index(rule.mark_ranges, mark_gid) or { return none }
	ligature_index := coverage_index(rule.ligature_ranges, ligature_gid) or { return none }
	if mark_index >= rule.mark_anchors.len || mark_index >= rule.mark_classes.len {
		return none
	}
	if ligature_index >= rule.components.len {
		return none
	}
	parts := rule.components[ligature_index]
	if parts.len == 0 {
		return none
	}
	class := int(rule.mark_classes[mark_index])
	// Which component the mark belongs to is not knowable from the text: a mark written after a
	// lam-alef goes on the alef, but the font says which component by giving that one the anchors
	// and leaving the others empty. A lam-alef in Tahoma is a two component ligature whose
	// anchors are all on the first component, so picking the last component finds nothing and
	// leaves the mark at the pen.
	//
	// So the component is the first one that has an anchor for this mark's class. Scanning for it
	// rather than assuming a position is also what makes a ligature with a mark in the middle of
	// it work: there the anchor is on the component the mark was written over, wherever that is.
	mut found := -1
	for ci in 0 .. parts.len {
		pairs := parts[ci].pairs
		if class < pairs.len && pairs[class].ligature.exists && pairs[class].mark.exists {
			found = ci
			break
		}
	}
	if found < 0 {
		return none
	}
	pair := parts[found].pairs[class]
	return Offset2{
		x: pair.ligature.x - pair.mark.x
		y: pair.ligature.y - pair.mark.y
	}
}

// has_mark_to_ligature reports whether the font places marks on ligatures at all, which is what
// tells a caller that a mark over a fused pair is going to be found rather than assumed.
pub fn (g &Gpos) has_mark_to_ligature() bool {
	for li in g.mark_feature_lookups {
		if li < g.lookups.len && g.lookups[li].mark_ligatures.len > 0 {
			return true
		}
	}
	return false
}

// kern_lookups are the lookups of the kern feature, for the script a caller names, which is where
// a font puts its pair adjustments.
//
// They are resolved per script rather than collected once, because a font is free to give a script
// its own kerning: a Persian font kerns Arabic letters with one set of rules and Latin letters with
// another, and a single list would apply the wrong one to both. The Arabic set is collected eagerly
// because that is the script this library shapes.
pub fn (g &Gpos) kerning_for(script string) []u16 {
	return g.lookups_for(script, 'kern')
}

// kern_offset returns how far to move left_gid when right_gid follows it, in design units.
//
// The order of the arguments is the order of the pair in the text's own direction, which for a
// right-to-left script means the rightmost glyph comes first. This matches the specification's rule
// that a pair is written in the order the layout direction reads, and getting it backwards is
// silent: a font that kerns "AV" tightly has a rule for A then V, and asking for V then A finds
// nothing and leaves the line a little too wide rather than wrong.
//
// A value of zero is a real answer, and it is different from no answer: it is the font saying the
// pair is already correct. The caller cannot tell the two apart from the number, so this returns
// none only when the font has no rule at all.
pub fn (g &Gpos) kern_offset(left_gid u16, right_gid u16, script string) ?Offset2 {
	for li in g.kerning_for(script) {
		if li >= g.lookups.len {
			continue
		}
		for rule in g.lookups[li].pairs {
			if a := rule.offset_for(left_gid, right_gid) {
				return Offset2{
					x: a.x
					y: a.y
				}
			}
		}
	}
	return none
}

// has_kerning reports whether the font has any pair adjustment for a script, which is what a
// caller needs to know before deciding whether to lay a line out twice to find the answer.
//
// A context counts. A font whose only rules are context-sensitive kerns just as much as one with a
// plain pair table, and reporting false for it would make a caller lay a line out twice to learn there
// was nothing to learn.
pub fn (g &Gpos) has_kerning(script string) bool {
	for li in g.kerning_for(script) {
		if li >= g.lookups.len {
			continue
		}
		lk := g.lookups[li]
		if lk.pairs.len > 0 || lk.chains.len > 0 {
			return true
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
// keeps a Latin lookup from being run over Arabic text.
pub fn (g &Gpos) contextual_for(script string) []u16 {
	mut out := []u16{}
	mut named_lookups := map[u16]bool{}
	for tag in ['calt', 'mark', 'mkmk', 'abvm', 'blwm', 'rclt', 'curs', 'kern'] {
		for li in g.lookups_for(script, tag) {
			if named_lookups[li] || li >= g.lookups.len {
				continue
			}
			// A feature may name a lookup that is not a context, and running a mark rule as if it
			// were one would move a mark with nothing having said it should.
			if g.lookups[li].chains.len == 0 {
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
pub fn (g &Gpos) has_contextual_positioning(script string) bool {
	for li in g.contextual_for(script) {
		if li < g.lookups.len && g.lookups[li].chains.len > 0 {
			return true
		}
	}
	return false
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
pub fn (g &Gpos) context_offset(gids []u16, left int, right int, script string) ?Offset2 {
	if left < 0 || right >= gids.len || left >= right {
		return none
	}
	left_gid := gids[left]
	right_gid := gids[right]
	if off := g.kern_offset(left_gid, right_gid, script) {
		return off
	}
	for li in g.kerning_for(script) {
		if li >= g.lookups.len {
			continue
		}
		for c in g.lookups[li].chains {
			// The pattern is tried at every position from which it could reach both of the pair, which
			// is from the left of the pair back by the number of backtrack glyphs to the right of it
			// forward by the number of lookahead glyphs. Trying only the pair's own left position
			// misses every rule with a backtrack, and a rule with a backtrack is most of them: the point
			// of a backtrack is that the answer depends on what came before.
			mut first := left - c.backtrack.len
			if first < 0 {
				first = 0
			}
			mut last := right + c.lookahead.len
			if last > gids.len - 1 {
				last = gids.len - 1
			}
			for at in first .. last + 1 {
				m := match_chain_position(c, gids, at)
				if m.start < 0 {
					continue
				}
				// A pattern that matched somewhere else in the run is not this pair's rule, and the
				// only thing that says so is whether it covers both of the glyphs the caller named.
				if !spans_pair(c, m, left, right) {
					continue
				}
				for rec in c.records {
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
					for rule in g.lookups[target].singles {
						if a := rule.offset_for(named) {
							return a
						}
						if named != other {
							if a := rule.offset_for(other) {
								return a
							}
						}
					}
					for rule in g.lookups[target].pairs {
						if a := rule.offset_for(left_gid, right_gid) {
							return Offset2{ x: a.x, y: a.y }
						}
					}
				}
			}
		}
	}
	return none
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
fn spans_pair(c &ChainPosition, m ChainMatchPositions, left int, right int) bool {
	if m.start < 0 || m.positions.len == 0 {
		return false
	}
	mut low := m.start - c.backtrack.len
	if low < 0 {
		low = 0
	}
	mut high := m.positions[m.positions.len - 1]
	high += c.lookahead.len
	return (left >= low && left <= high) || (right >= low && right <= high)
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
pub fn (g &Gpos) apply_contextual(gids []u16, script string) []ChainApplication {
	mut out := []ChainApplication{}
	if gids.len == 0 {
		return out
	}
	// The rules are tried in the order the features name them, and within a lookup in the order the
	// subtables are written, because a later one is meant to override an earlier one and the caller
	// cannot know that unless the order is preserved.
	for li in g.contextual_for(script) {
		if li >= g.lookups.len {
			continue
		}
		lookup := g.lookups[li]
		for c in lookup.chains {
			for at in 0 .. gids.len {
				m := match_chain_position(c, gids, at)
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
	}
	return out
}

// match_chain_position tests a context's pattern at one position in a glyph run.
//
// The backtrack and lookahead lists are written nearest glyph first and the input list runs forwards,
// and none of that changes with the writing direction. The returned start is negative when the pattern
// does not match, and the positions are the indices in the run of every input glyph, in pattern order,
// so a record's position indexes straight into them.
fn match_chain_position(c &ChainPosition, gids []u16, at int) ChainMatchPositions {
	if c.input.len == 0 || at + c.input.len > gids.len {
		return ChainMatchPositions{ start: -1 }
	}
	for k, cov in c.backtrack {
		back := at - 1 - k
		if back < 0 {
			return ChainMatchPositions{ start: -1 }
		}
		if coverage_index(cov, gids[back]) == none {
			return ChainMatchPositions{ start: -1 }
		}
	}
	// Positions are assigned by index rather than appended: the slice is made at its final length so
	// that a record naming position n reads position n and not the end of the list.
	mut positions := []int{len: c.input.len}
	for k, cov in c.input {
		if coverage_index(cov, gids[at + k]) == none {
			return ChainMatchPositions{ start: -1 }
		}
		positions[k] = at + k
	}
	for k, cov in c.lookahead {
		ahead := at + c.input.len + k
		if ahead >= gids.len {
			return ChainMatchPositions{ start: -1 }
		}
		if coverage_index(cov, gids[ahead]) == none {
			return ChainMatchPositions{ start: -1 }
		}
	}
	return ChainMatchPositions{ start: at, positions: positions }
}

// ChainMatchPositions is a context pattern that has matched and where in the run it matched.
struct ChainMatchPositions {
mut:
	// start is the index of the first input glyph, or negative when nothing matched.
	start int
	// positions are the indices of every input glyph, in pattern order.
	positions []int
}

// has_mark_to_mark reports whether the font places a mark on another mark, which is what stacking
// two accents needs.
pub fn (g &Gpos) has_mark_to_mark() bool {
	for li in g.mark_feature_lookups {
		if li < g.lookups.len && g.lookups[li].mark_marks.len > 0 {
			return true
		}
	}
	return false
}

// offset_for finds the attachment for one mark and base pair within a single rule.
//
// The mark class the font recorded in its own mark array wins over the one the caller asked
// with. Both come from the same GDEF, so they agree, and reading it from the lookup keeps the
// rule self contained: a caller that has not read GDEF still gets the right anchor.
fn (rule &MarkToBase) offset_for(mark_gid u16, base_gid u16) ?Anchor {
	mark_index := coverage_index(rule.mark_ranges, mark_gid) or { return none }
	base_index := coverage_index(rule.base_ranges, base_gid) or { return none }
	if mark_index >= rule.mark_anchors.len || mark_index >= rule.mark_classes.len {
		return none
	}
	if base_index >= rule.base_anchors.len {
		return none
	}
	class := int(rule.mark_classes[mark_index])
	anchors := rule.base_anchors[base_index]
	if class >= anchors.len {
		return none
	}
	base_anchor := anchors[class]
	mark_anchor := rule.mark_anchors[mark_index]
	// One of the two anchors being absent means the font does not place this mark, which is a
	// different thing from placing it at the origin.
	if !base_anchor.exists || !mark_anchor.exists {
		return none
	}
	return Anchor{
		x:      base_anchor.x - mark_anchor.x
		y:      base_anchor.y - mark_anchor.y
		exists: true
	}
}

// offset_for finds the adjustment for one pair of glyphs within a single rule.
//
// The two formats are answered from different tables and it is worth saying which, because the
// answer is the same number either way and only one of them can be checked by looking.
//
// Format 1 names each pair, so it has to find the first glyph in its coverage, then the second
// glyph in that glyph's own set. The second coverage is what says how many records follow, and a
// record is found through it rather than by assuming an order, so a font that writes its records in
// a different order still works.
//
// Format 2 names no pair at all. It says what class each glyph is in and looks the answer up in a
// matrix, so every pair of glyphs in two classes shares one adjustment. A font that uses it has
// usually also written a format 1 rule for the pairs it wants to treat differently, and a lookup
// holds both, so the order of the rules decides which one is reached.
//
// The adjustment returned is the first glyph's, and it is only reported when it is a change of
// advance. A record that only moves a glyph without changing the gap is a placement rule, and
// reporting it as a kern would take a letter out from under its neighbour.
fn (rule &PairPos) offset_for(left_gid u16, right_gid u16) ?Anchor {
	// The second glyph is the one that advances, so it is the one a zero value format 2 leaves
	// without a record of its own.
	mut first_side := PairValue{}
	if rule.is_format2 {
		// Class 0 is the class of a glyph the definitions do not name, and a font is free to put a
		// pair there on purpose: a rule that kerns everything next to a punctuation mark writes its
		// adjustments in the class 0 row, because the other glyphs are the ones in no class. So class
		// 0 cannot be skipped.
		//
		// What does decide the pair is the coverage, which lists the first glyphs the rule is about
		// at all. A glyph outside it is not in the rule whatever class the definitions give it, and
		// the class matrix is indexed by class rather than by glyph, so without this check any glyph
		// would match any cell.
		if coverage_index(rule.first_ranges, left_gid) == none {
			return none
		}
		first_class := int(rule.class_def1.class_of(left_gid))
		second_class := int(rule.class_def2.class_of(right_gid))
		if first_class >= rule.class1_records.len {
			return none
		}
		row := rule.class1_records[first_class]
		if second_class >= row.len {
			return none
		}
		first_side = row[second_class]
	} else {
		first_index := coverage_index(rule.first_ranges, left_gid) or { return none }
		if first_index >= rule.pair_sets.len {
			return none
		}
		set := rule.pair_sets[first_index]
		second_index := coverage_index(set.coverage, right_gid) or { return none }
		if second_index >= set.records.len {
			return none
		}
		first_side = set.records[second_index][0]
	}
	if !first_side.has_x_advance() {
		return none
	}
	return Anchor{
		x:      int(first_side.x_advance)
		y:      int(first_side.y_advance)
		exists: true
	}
}

// parse_gpos_lookups reads the LookupList and the mark-to-base rules.
fn parse_gpos_lookups(r &Reader, off int) []GposLookup {
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
		subtable_count := int(r.u16_at(at + 4))
		for j in 0 .. subtable_count {
			resolved := resolve_gpos_subtable(r, lookup.kind, at + int(r.u16_at(at + 6 + j * 2)))
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
				}
			}
			if resolved.kind == gpos_lookup_single_position {
				if rule := parse_single_position(r, resolved.at) {
					lookup.singles << rule
				}
			}
		}
		if lookup.mark_ligatures.len > 0 {
			lookup.kind = gpos_lookup_mark_to_ligature
		} else if lookup.mark_marks.len > 0 {
			lookup.kind = gpos_lookup_mark_to_mark
		} else if lookup.kind == gpos_lookup_extension && lookup.mark_bases.len > 0 {
			lookup.kind = gpos_lookup_mark_to_base
		} else if lookup.kind == gpos_lookup_extension && lookup.chains.len > 0 {
			// A lookup that reached its real type through an extension reports that type, so that
			// a caller asking what a lookup is gets the answer rather than the extension.
			lookup.kind = gpos_lookup_chain_context
		}
		out << lookup
	}
	return out
}

// ResolvedSubtable is a subtable together with the lookup type that actually governs it. It is
// shared with the substitution parser, because the idea is the same: a lookup header may point
// at an extension that names the real type and where it lives.
struct ResolvedSubtable {
	kind u16
	at   int
}

// resolve_gpos_subtable follows an extension lookup to the table it wraps.
//
// Fonts wrap their positioning rules in extensions for the same reason they wrap substitution
// rules, so ignoring the wrapper would leave every mark at the pen position.
fn resolve_gpos_subtable(r &Reader, kind u16, at int) ResolvedSubtable {
	if kind != gpos_lookup_extension {
		return ResolvedSubtable{
			kind: kind
			at:   at
		}
	}
	if !r.has(at, 8) {
		return ResolvedSubtable{ kind: 0, at: 0 }
	}
	return ResolvedSubtable{
		kind: r.u16_at(at + 2)
		at:   at + int(r.u32_at(at + 4))
	}
}

// parse_pair_pos reads one PairPos subtable, in whichever of the two formats it declares.
//
// The formats are the same rule with a different indexing scheme, and the format is the first field
// because the two cannot be told apart any other way: both start with a coverage, and both go on
// writing structures whose width depends on the value formats.
//
// Format 1 names every pair. Format 2 says which glyphs share an adjustment by class and writes the
// adjustments in a matrix, which is how a font keeps a kerning table to a size that can be shipped.
// PairValue is one side of a pair adjustment: the four numbers a font can change about a glyph, and
// which of them it wrote.
//
// The four are placement and advance in each direction, and they are not the same adjustment:
// xPlacement moves the glyph where it is drawn without changing how far the pen travels, and
// xAdvance changes the gap after it. Kerning uses xAdvance, because the whole point is the space
// between two letters, and a rule that used xPlacement instead would move the first letter out from
// under the second one and leave the gap the same.
//
// Which fields a record has is decided by the subtable's value format, not by the record itself, so
// this keeps a mask per side. A record with x of zero and no x at all is not a kern of nothing, it
// is a rule that says nothing about the horizontal, and the two cannot be told apart without it.
struct PairValue {
mut:
	x_placement i16
	y_placement i16
	x_advance   i16
	y_advance   i16
	// format is the value format of the side this record came from, which is what says whether a
	// field is present or merely zero.
	format u16
}

// present_x_advance reports whether this record adjusts the horizontal advance at all, which is
// what kerning is. A rule that adjusts only a placement is not a kern, and applying it as one would
// move a letter without closing the gap.
pub fn (v &PairValue) has_x_advance() bool {
	return v.format & 0x0004 != 0
}

// PairSet is every adjustment one first glyph has, indexed by the second glyph through a coverage.
struct PairSet {
mut:
	coverage []CoverageRange
	// records is indexed by the second glyph's coverage index, and holds the two sides of the
	// adjustment in order.
	records [][]PairValue
}

// PairPos is one pair-adjustment rule: for a covered first glyph, how far to move it and the glyph
// that follows it.
//
// The two formats are kept apart in the fields rather than resolved at parse time, because they
// share a header and diverge immediately after it: format 1 has a pairSetCount where format 2 has
// two class definitions, so reading one as the other produces a plausible count and rows of numbers
// that are not adjustments of anything.
struct PairPos {
mut:
	// first_ranges is the coverage of the first glyph of a pair, which is the glyph that moves.
	first_ranges []CoverageRange
	// value_format1 and value_format2 are the field masks of the first and second sides. They are
	// kept because they say how wide a record is, which is what steps the reader onto the next pair.
	value_format1 u16
	value_format2 u16
	// pair_sets is the set of rules of format 1, indexed by the first glyph's coverage index.
	pair_sets []PairSet
	// class_def1 and class_def2 are the class definitions of format 2. A glyph's class says which
	// column or row of the matrix its adjustment is in, which is how a font writes one rule for a
	// group of glyphs rather than one rule for each pair.
	class_def1 ClassDef
	class_def2 ClassDef
	// class1_records is indexed by the second glyph's class, and each entry is that row of the
	// matrix: one value for every class the first glyph might be in.
	class1_records [][]PairValue
	// class2_records is the last column, which is what a glyph with a valueFormat2 of zero gets.
	class2_records []PairValue
	// is_format2 says which format the subtable declared, and is what the lookup does with it.
	is_format2 bool
}

// SinglePos is one positioning rule: for a covered glyph on its own, move it.
//
// It is the smallest of the positioning tables and the one a context record most often names. A font
// says "this glyph sits further left when it follows that one" with a rule of this shape inside a
// context, and a rule of this shape is a placement rather than a kern: the glyph moves and the gap
// after it does not, which is the difference between the two that matters when a context record is
// applied.
struct SinglePos {
mut:
	// ranges is the coverage of the glyphs this rule moves.
	ranges []CoverageRange
	// format is the value format, which says which of the four numbers each record holds. It is kept
	// because a record with an x of zero and no x at all means the font says nothing about the
	// horizontal, which is not the same as saying zero.
	format u16
	// values is indexed by the glyph's coverage index, so a record is found through the coverage
	// rather than by an offset the caller would have to know about.
	values []PairValue
}

// offset_for finds the adjustment for one glyph within a single rule.
fn (rule &SinglePos) offset_for(gid u16) ?Offset2 {
	idx := coverage_index(rule.ranges, gid) or { return none }
	if idx >= rule.values.len {
		return none
	}
	v := rule.values[idx]
	// A rule that says nothing about either placement is no rule, and answering it with a zero would
	// look like a font that had decided the glyph was already in the right place.
	if v.format & 0x0003 == 0 {
		return none
	}
	return Offset2{ x: i32(v.x_placement), y: i32(v.y_placement) }
}

// parse_single_position reads one SinglePos subtable, in format 1.
//
// Format 1 has one value for every covered glyph, and the value comes straight after the format that
// says how wide it is. There is no count of the values: the coverage already says how many glyphs there
// are, so a count would be redundant, and reading the first value as a count turns a value of -120 into
// a count of 65416 and then walks 65416 records off the end of the table. That is why the numbers this
// produced were the wrong ones rather than merely noisy ones, and it is a mistake worth naming because
// the pair tables beside it do have a count and the two sit next to each other in the same table.
//
// Format 2 has one value for the whole coverage and a second array naming the glyphs that want
// something else. It is not read here: no font on this machine uses it, and reading it as format 1 takes
// the valueCount as a count and then reads coverage indices as records.
fn parse_single_position(r &Reader, at int) ?SinglePos {
	if r.u16_at(at) != 1 {
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

// parse_pair_pos reads one PairPos subtable, in whichever of the two formats it declares.
//
// The format is read first because the two cannot be told apart any other way: both begin with a
// coverage of the first glyph, both declare the same two value formats, and both go on to write
// structures whose width depends on those formats, so a record cannot even be stepped over before
// the format is known.
//
// They diverge at the sixth field. Format 1 has a count of PairSet tables there, and format 2 has two
// class definitions. Reading a format 2 subtable as format 1 takes the first class definition's
// offset as a count of sets, which is a small number that looks fine, and then walks offsets out of
// a class definition that is not an array of them. The result is thousands of pair records with
// numbers in them that are not kerning.
fn parse_pair_pos(r &Reader, at int) ?PairPos {
	format := r.u16_at(at)
	if format != 1 && format != 2 {
		return none
	}
	pos := at
	first_ranges := parse_coverage(r, pos + int(r.u16_at(pos + 2)))
	vf1 := r.u16_at(pos + 4)
	vf2 := r.u16_at(pos + 6)
	if first_ranges.len == 0 {
		return none
	}
	if format == 1 {
		//	PairPosFormat1
		//	    uint16   format                    = 1
		//	    Offset16 coverageOffset
		//	    uint16   valueFormat1
		//	    uint16   valueFormat2
		//	    uint16   pairSetCount
		//	    Offset16 pairSetOffsets[pairSetCount]
		//
		// The offsets are from the beginning of the subtable, and the count is a count rather than
		// an offset, so the two are read from the header rather than from a table one of them points
		// at. Reading the count out of the first PairSet instead picks up its pairValueCount, which
		// is a different number about different things, and the offsets that follow are then walked
		// from the wrong place.
		//
		// The count is a count of sets and a set is a covered first glyph, so it is the number of
		// glyphs the coverage names and not the number of ranges in it. Capping it at the range
		// count instead truncates a font whose coverage is written in few large ranges, and the
		// glyphs past the cap then have no adjustment at all.
		mut first_glyphs := 0
		for cr in first_ranges {
			first_glyphs += int(cr.last - cr.first) + 1
		}
		mut set_count := int(r.u16_at(pos + 8))
		if set_count > first_glyphs {
			set_count = first_glyphs
		}
		mut pair_sets := []PairSet{cap: set_count}
		for i in 0 .. set_count {
			set_at := pos + int(r.u16_at(pos + 10 + i * 2))
			if set := parse_pair_set(r, set_at, vf1, vf2) {
				pair_sets << set
			}
		}
		return PairPos{
			first_ranges:  first_ranges
			value_format1: vf1
			value_format2: vf2
			pair_sets:     pair_sets
		}
	}
	//	PairPosFormat2
	//	    Offset16 classDef1Offset
	//	    Offset16 classDef2Offset
	//	    uint16   class1Count
	//	    uint16   class2Count
	//	    Class1Record class1Records[class1Count]
	//	    Class2Record class2Records[class2Count]
	//
	// A Class1Record is a row of the matrix: one value for every class the first glyph can be in.
	// A Class2Record is a single value, the one for a first glyph that has no class of its own.
	cd1 := parse_class_def(r, pos + int(r.u16_at(pos + 8)))
	cd2 := parse_class_def(r, pos + int(r.u16_at(pos + 10)))
	class1_count := int(r.u16_at(pos + 12))
	class2_count := int(r.u16_at(pos + 14))
	// A Class1Record is a row of the matrix: for one class of first glyph, the adjustment for every
	// class of second glyph. Only the first glyph's value is in the row, because a format 2 rule
	// moves the first glyph and leaves the second alone, which is what the class 2 records are for.
	//
	// The reader advances by the size of one value and not by the size of a pair, because a pair of
	// records is format 1's arrangement. Stepping by both here would skip past the end of the row
	// and read the next row's numbers into this one.
	vf1_size := pair_value_size(vf1)
	mut class1_records := [][]PairValue{cap: class1_count}
	mut at2 := pos + 16
	for _ in 0 .. class1_count {
		mut row := []PairValue{cap: class2_count}
		for _ in 0 .. class2_count {
			row << read_pair_value(r, at2, vf1)
			at2 += vf1_size
		}
		class1_records << row
	}
	// The class 2 records follow the class 1 records, and the reader is already at them, because
	// each class 1 record was read whole.
	mut class2_records := []PairValue{cap: class2_count}
	for _ in 0 .. class2_count {
		class2_records << read_pair_value(r, at2, vf1)
		at2 += vf1_size
	}
	return PairPos{
		first_ranges:   first_ranges
		value_format1:  vf1
		value_format2:  vf2
		class_def1:     cd1
		class_def2:     cd2
		class1_records: class1_records
		class2_records: class2_records
		is_format2:     true
	}
}

// parse_pair_set reads one PairSet: a coverage of the second glyphs, and one pair of value records
// per glyph in it, in coverage order.
//
// A PairValue here is two records, one for each glyph of the pair, and both are read even when one
// of them is empty. A font that gives the second glyph a value format of zero leaves its record
// with no fields, and the record still occupies the space the format says it does, so the reader has
// to step over it to reach the next pair.
fn parse_pair_set(r &Reader, at int, vf1 u16, vf2 u16) ?PairSet {
	ranges := parse_coverage(r, at + int(r.u16_at(at + 2)))
	if ranges.len == 0 {
		return none
	}
	// pairValueCount is a count of pairs, which is a count of glyphs the coverage names and not a
	// count of ranges in it. A coverage of three glyphs in one range is still three records.
	count := int(r.u16_at(at + 4))
	vf1_size := pair_value_size(vf1)
	step := vf1_size + pair_value_size(vf2)
	mut records := [][]PairValue{cap: count}
	mut at2 := at + 6
	for _ in 0 .. count {
		records << [read_pair_value(r, at2, vf1), read_pair_value(r, at2 + vf1_size, vf2)]
		at2 += step
	}
	return PairSet{
		coverage: ranges
		records:  records
	}
}

// read_pair_value reads one ValueRecord, which is a variable-length structure: each bit of the
// value format says one field is there, and the fields come in a fixed order when they are.
//
// The order is the order the format's bits are numbered in, which is placement before advance and
// x before y: xPlacement, yPlacement, xAdvance, yAdvance. The device or variation table offsets
// follow, and are skipped rather than kept, because a hint that a pair is tighter at one size than
// another is a refinement this engine does not apply.
//
// Reading the fields without consulting the format produces a record of the right length and the
// wrong numbers: a font that only writes xAdvance yields a record whose xPlacement is the kerning
// value, which is the same number in the wrong place and produces a letter that has moved rather
// than a gap that has closed.
fn read_pair_value(r &Reader, at int, format u16) PairValue {
	mut v := PairValue{
		format: format
	}
	mut p := at
	if format & 0x0001 != 0 {
		v.x_placement = r.i16_at(p)
		p += 2
	}
	if format & 0x0002 != 0 {
		v.y_placement = r.i16_at(p)
		p += 2
	}
	if format & 0x0004 != 0 {
		v.x_advance = r.i16_at(p)
		p += 2
	}
	if format & 0x0008 != 0 {
		v.y_advance = r.i16_at(p)
		p += 2
	}
	return v
}

// pair_value_size is how many bytes a ValueRecord of this format occupies. The size comes from the
// format rather than from what was read, because a value can be present and zero, and the reader
// has to be stepped over to reach the next record.
fn pair_value_size(format u16) int {
	mut n := 0
	// The four value fields, then the device and variation offsets, which are read past.
	for bit in [0x0001, 0x0002, 0x0004, 0x0008, 0x0010, 0x0020, 0x0040, 0x0080] {
		if format & bit != 0 {
			n += 2
		}
	}
	return n
}

// parse_mark_to_base reads one MarkToBasePos subtable. Only format 1 exists in the
// specification, so there is no second reading to try.
fn parse_mark_to_base(r &Reader, at int) ?MarkToBase {
	if r.u16_at(at) != 1 {
		return none
	}
	mark_ranges := parse_coverage(r, at + int(r.u16_at(at + 2)))
	base_ranges := parse_coverage(r, at + int(r.u16_at(at + 4)))
	class_count := int(r.u16_at(at + 6))
	mark_array := at + int(r.u16_at(at + 8))
	base_array := at + int(r.u16_at(at + 10))
	if mark_ranges.len == 0 || base_ranges.len == 0 {
		return none
	}

	// The mark array is one record per covered mark, in coverage order: the mark's class, and
	// an offset to the mark's own anchor.
	mut mark_anchors := []Anchor{}
	mut mark_classes := []u16{}
	mark_count := int(r.u16_at(mark_array))
	for i in 0 .. mark_count {
		record := mark_array + 2 + i * 4
		mark_classes << r.u16_at(record)
		// The anchor offset is relative to the start of the mark array, not to the record.
		mark_anchors << parse_anchor_at(r, mark_array, int(r.u16_at(record + 2)))
	}

	// The base array is one record per covered base, and each record is one anchor per class.
	mut base_anchors := [][]Anchor{}
	base_count := int(r.u16_at(base_array))
	for i in 0 .. base_count {
		record := base_array + 2 + i * class_count * 2
		mut anchors := []Anchor{cap: class_count}
		for c in 0 .. class_count {
			anchors << parse_anchor_at(r, base_array, int(r.u16_at(record + c * 2)))
		}
		base_anchors << anchors
	}

	return MarkToBase{
		mark_ranges:  mark_ranges
		base_ranges:  base_ranges
		class_count:  class_count
		mark_anchors: mark_anchors
		mark_classes: mark_classes
		base_anchors: base_anchors
	}
}

// parse_mark_to_ligature reads one MarkToLigaturePos subtable. Only format 1 exists, so there is
// no second reading to try.
//
// The ligature array is where this differs from a mark-to-base rule: each ligature carries one
// record per component, and each component carries an anchor per mark class. A ligature that does
// not say how many components it has is a ligature this cannot attach to.
// parse_mark_to_ligature reads one MarkToLigaturePos subtable. Only format 1 exists, so there is
// no second reading to try.
//
// The ligature array is the part worth spelling out, because reading it wrongly is silent and every
// wrong reading produces a plausible looking number. From the specification it is:
//
//	LigatureArray
//	    uint16        ligatureCount
//	    Offset16      ligatureAttachOffsets[ligatureCount]
//
//	and each offset names a LigatureAttach elsewhere in the table:
//
//	LigatureAttach
//	    uint16        componentCount
//	    ComponentRecord[componentCount], each one classCount ligature and mark anchor offsets
//
// So there is no ComponentCount in the LigatureArray at all: what sits after the count is a list of
// offsets, and the count each ligature has is inside the table its offset names. The offsets are
// from the beginning of the LigatureArray, not from the offset list and not from the LigatureAttach.
//
// A version of this read the offsets as component counts, which gave sixty four components for a
// two character ligature, and then built anchors for all sixty four of them out of whatever bytes
// followed, every one of which was read from the wrong place. The numbers looked like counts, so
// nothing complained. Another version read one shared count for the whole array, which is not in
// the specification either. The count is per record and the record is reached through an offset.
fn parse_mark_to_ligature(r &Reader, at int) ?MarkToLigature {
	if r.u16_at(at) != 1 {
		return none
	}
	mark_ranges := parse_coverage(r, at + int(r.u16_at(at + 2)))
	ligature_ranges := parse_coverage(r, at + int(r.u16_at(at + 4)))
	class_count := int(r.u16_at(at + 6))
	mark_array := at + int(r.u16_at(at + 8))
	ligature_array := at + int(r.u16_at(at + 10))
	if mark_ranges.len == 0 || ligature_ranges.len == 0 || class_count == 0 {
		return none
	}
	// The mark array is one record per covered mark, in coverage order: the mark's class, and an
	// offset to the mark's own anchor, measured from the start of the mark array.
	mut mark_anchors := []Anchor{}
	mut mark_classes := []u16{}
	mark_count := int(r.u16_at(mark_array))
	// The count is how many four byte records follow, so a count the table cannot hold is a font
	// claiming more than it has.
	if mark_count * 4 > r.len() - mark_array - 2 {
		return none
	}
	for i in 0 .. mark_count {
		record := mark_array + 2 + i * 4
		mark_classes << r.u16_at(record)
		mark_anchors << parse_anchor_at(r, mark_array, int(r.u16_at(record + 2)))
	}

	// The ligature array is a count and a list of offsets, one per covered ligature. The count is
	// taken at face value because the offsets are what decide whether it is right: a count with an
	// offset list that does not fit the table is refused here, and a count naming a table that does
	// not exist is refused per record below, which is where the damage would otherwise happen.
	ligature_count := int(r.u16_at(ligature_array))
	if ligature_count == 0 || ligature_count * 2 > r.len() - ligature_array - 2 {
		return none
	}

	mut components := [][]LigatureComponent{}
	for li in 0 .. ligature_count {
		// The offset is from the start of the ligature array, and the component count is inside the
		// table the offset names rather than beside the offset.
		attach := ligature_array + int(r.u16_at(ligature_array + 2 + li * 2))
		component_count := int(r.u16_at(attach))
		// A component record is two offsets per class, so a count that cannot fit in what is left of
		// the table is a font claiming more than it has. Such a ligature is left with no components,
		// which attaches nothing rather than attaching somewhere arbitrary, and the ligatures after
		// it are still read because each has its own offset.
		need := component_count * class_count * 4
		if component_count == 0 || need > r.len() - attach - 2 {
			components << [][]LigatureComponent{}
			continue
		}
		mut parts := []LigatureComponent{}
		for ci in 0 .. component_count {
			mut pairs := []LigatureAnchorPair{cap: class_count}
			for k in 0 .. class_count {
				// One component of one ligature for one class, and it is two offsets: the point on
				// the ligature and the point on the mark that have to meet.
				rec := attach + 2 + (ci * class_count + k) * 4
				pairs << LigatureAnchorPair{
					ligature: parse_anchor_at(r, attach, int(r.u16_at(rec)))
					mark:     parse_anchor_at(r, attach, int(r.u16_at(rec + 2)))
				}
			}
			parts << LigatureComponent{
				pairs: pairs
			}
		}
		components << parts
	}

	return MarkToLigature{
		mark_ranges:     mark_ranges
		ligature_ranges: ligature_ranges
		class_count:     class_count
		mark_anchors:    mark_anchors
		mark_classes:    mark_classes
		components:      components
	}
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
fn parse_anchor_at(r &Reader, base int, offset int) Anchor {
	if offset == 0 {
		return Anchor{}
	}
	return parse_anchor(r, base + offset)
}

fn parse_anchor(r &Reader, at int) Anchor {
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
