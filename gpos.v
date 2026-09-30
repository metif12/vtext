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
const gpos_lookup_mark_to_base = 4
const gpos_lookup_mark_to_ligature = 5
const gpos_lookup_mark_to_mark = 6
const gpos_lookup_extension = 9

// The GDEF glyph classes. Only the first two matter to attachment: a mark attaches to a base or
// to a ligature, and those are the only things it attaches to.
const glyph_class_base = 1
const glyph_class_ligature = 2
const glyph_class_mark = 3

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
	if g.glyph_classes.entries.len == 0 {
		return none
	}
	return g
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
	kind       u16
	mark_bases []MarkToBase
}

// mark_glyphs_passthrough reports whether the mark glyphs a font uses in its positioning rules
// are the ones its cmap maps the marks to.
//
// It exists because the two are not always the same and the difference matters. A font that
// composes its marks through a ccmp substitution has its positioning rules written against the
// composed glyph, not against the one the cmap hands out, so a mark that has not been through
// that substitution will not be found in any coverage. This is a diagnostic for that situation
// rather than a correction for it: the fix is to run the composition, which is a different
// feature and a different milestone.
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
	// The order is abvm, blwm then mark, and it matters only in that a rule found first wins.
	// A font does not put the same mark under two of them, so the order is not load bearing; it
	// is written this way because those are the features a mark can be under.
	for feat in ['abvm', 'blwm', 'mark'] {
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
pub fn (g &Gpos) mark_offset(mark_gid u16, base_gid u16) ?Offset2 {
	for li in g.mark_feature_lookups {
		if li >= g.lookups.len {
			continue
		}
		lookup := g.lookups[li]
		if lookup.kind != gpos_lookup_mark_to_base {
			continue
		}
		for rule in lookup.mark_bases {
			if off := rule.offset_for(mark_gid, base_gid) {
				return Offset2{ x: off.x, y: off.y }
			}
		}
	}
	return none
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
		}
		if lookup.kind == gpos_lookup_extension && lookup.mark_bases.len > 0 {
			lookup.kind = gpos_lookup_mark_to_base
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
		mark_anchors << parse_anchor(r, mark_array + int(r.u16_at(record + 2)))
	}

	// The base array is one record per covered base, and each record is one anchor per class.
	mut base_anchors := [][]Anchor{}
	base_count := int(r.u16_at(base_array))
	for i in 0 .. base_count {
		record := base_array + 2 + i * class_count * 2
		mut anchors := []Anchor{cap: class_count}
		for c in 0 .. class_count {
			anchors << parse_anchor(r, base_array + int(r.u16_at(record + c * 2)))
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

// parse_anchor reads an Anchor table.
//
// Format 1 is a point. Formats 2 and 3 add a contour point and device tables, both of which are
// about hinting and variations rather than about where the mark goes, so the coordinates are
// read from all three and the rest is ignored. The tables a font uses here are small, and the
// offsets are all bounds checked, so a malformed one costs nothing but the placement.
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
