module font

// Anchor is one attachment point on a glyph, in design units.
//
// An anchor that is not there is different from an anchor at the origin, which is why this
// carries a flag: the first is "this font says nothing", and drawing a mark at the origin
// because the font was silent would be a lie about the font.
pub struct Anchor {
pub mut:
	x      i32
	y      i32
	exists bool
}

// MarkToBase is one mark-to-base lookup: for a mark and a base, the offset that puts the mark
// onto one of the base's anchors.
pub struct MarkToBase {
pub mut:
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

// LigatureAnchorPair is one component's anchor for one mark class: the point on the ligature
// a mark of that class meets at. The point on the mark lives once per mark in the rule's mark
// array, not once per component — a ComponentRecord carries one offset per class, not two —
// so the mark half of the pair is always empty and offset_for reads it from the mark array.
pub struct LigatureAnchorPair {
pub mut:
	ligature Anchor
	mark     Anchor
}

// LigatureComponent is one component of one ligature, with a pair of anchors per mark class.
pub struct LigatureComponent {
pub mut:
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
pub struct MarkToLigature {
pub mut:
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
	return g.mark_offset_on(mark_gid, base_gid, base_is_mark, g.mark_feature_lookups)
}

// mark_offset_in is mark_offset for the script the run is in, rather than for the
// script the library was developed against. The lookups are collected the same way,
// so for 'arab' the two ask exactly the same list; for anything else the second one
// reaches rules the first cannot see.
pub fn (g &Gpos) mark_offset_in(mark_gid u16, base_gid u16, base_is_mark bool, script string, lang string) ?Offset2 {
	return g.mark_offset_on(mark_gid, base_gid, base_is_mark, g.mark_feature_lookups_for(script, lang))
}

// mark_offset_on answers one mark pair from an explicit lookup list, which is what the
// two public forms share: the arab list collected at parse time, and the per-script
// list collected per run.
//
// A lookup gated by USE_MARK_FILTERING_SET applies only to marks in its GDEF
// set: the Thai SARA II stacks on MAI HAN AKAT through a rule whose set does
// not contain it, and matching it anyway puts the vowel on the wrong letter.
// The ignore-class bits and the mark attachment class are still open: only
// the filtering-set bit is honored, and only here on the mark rules.
pub fn (g &Gpos) mark_offset_on(mark_gid u16, base_gid u16, base_is_mark bool, lookups []u16) ?Offset2 {
	for li in lookups {
		if li >= g.lookups.len {
			continue
		}
		lookup := g.lookups[li]
		if lookup.flag & 0x0010 != 0 && !gpos_mark_in_set(g.mark_sets, lookup.mark_filtering_set, mark_gid) {
			continue
		}
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

// gpos_mark_in_set reports whether a mark belongs to a filtering set: a set
// index past the GDEF sets, or a font with none, answers no. No membership
// means the gated lookup does not apply, which degrades to the letter below
// rather than to a wrong stack.
fn gpos_mark_in_set(sets [][]CoverageRange, set_index u16, mark_gid u16) bool {
	if int(set_index) >= sets.len {
		return false
	}
	if _ := coverage_index(sets[set_index], mark_gid) {
		return true
	}
	return false
}

// offset_for finds the attachment for one mark on one component of one ligature.
//
// The component is the last one that carries a ligature anchor for the mark's class, because
// a mark written after a fused pair belongs to the pair's last character: Khmer KAKABAT after
// a KA+SRAII ligature rides the SRII component's anchor, and taking the first lands it a full
// component to the left of HarfBuzz. A font that fills only the first component still resolves,
// because the scan stops at whatever carries an anchor: Tahoma's lam-alef keeps its anchors on
// the first component, and the scan finds them there.
//
// Both anchors have to be there. A ligature anchor on its own says where a mark goes but not
// which way up the mark should sit, and a mark anchor on its own says where the mark's own
// origin belongs but nothing about the ligature, so a pair with only one half present is not
// enough to place the mark and none is returned.
pub fn (rule &MarkToLigature) offset_for(mark_gid u16, ligature_gid u16) ?Offset2 {
	mark_index := coverage_index(rule.mark_ranges, mark_gid) or { return none }
	ligature_index := coverage_index(rule.ligature_ranges, ligature_gid) or { return none }
	if mark_index >= rule.mark_anchors.len || mark_index >= rule.mark_classes.len {
		return none
	}
	if ligature_index >= rule.components.len {
		return none
	}
	mark_anchor := rule.mark_anchors[mark_index]
	if !mark_anchor.exists {
		return none
	}
	class := int(rule.mark_classes[mark_index])
	parts := rule.components[ligature_index]
	if parts.len == 0 {
		return none
	}
	// Which component the mark belongs to is not knowable from the text: a mark written after a
	// fused pair belongs to the pair's last character, so the scan runs from the end and takes
	// the last component that carries a ligature anchor for this mark's class. A lam-alef in
	// Tahoma is a two component ligature whose anchors are all on the first component, so the
	// scan finds them there; an engine that took the last component positionally would find
	// nothing and leave the mark at the pen.
	mut found := -1
	for ci := parts.len - 1; ci >= 0; ci-- {
		pairs := parts[ci].pairs
		if class < pairs.len && pairs[class].ligature.exists {
			found = ci
			break
		}
	}
	if found < 0 {
		return none
	}
	lig := parts[found].pairs[class].ligature
	return Offset2{
		x: lig.x - mark_anchor.x
		y: lig.y - mark_anchor.y
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
pub fn (rule &MarkToBase) offset_for(mark_gid u16, base_gid u16) ?Anchor {
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

// parse_mark_to_base reads one MarkToBasePos subtable. Only format 1 exists in the
// specification, so there is no second reading to try.
pub fn parse_mark_to_base(r &Reader, at int) ?MarkToBase {
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
pub fn parse_mark_to_ligature(r &Reader, at int) ?MarkToLigature {
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
		// A component record is one offset per class, so a count that cannot fit in what is left of
		// the table is a font claiming more than it has. Such a ligature is left with no components,
		// which attaches nothing rather than attaching somewhere arbitrary, and the ligatures after
		// it are still read because each has its own offset.
		need := component_count * class_count * 2
		if component_count == 0 || need > r.len() - attach - 2 {
			components << [][]LigatureComponent{}
			continue
		}
		mut parts := []LigatureComponent{}
		for ci in 0 .. component_count {
			mut pairs := []LigatureAnchorPair{cap: class_count}
			for k in 0 .. class_count {
				// One component of one ligature for one class, and it is one offset: the point on
				// the ligature. The point on the mark lives once per mark in the mark array, not
				// once per component, so reading two offsets here consumes the next component's
				// ligature anchor as this one's mark anchor and parks the mark a full component
				// away from where the font asked.
				rec := attach + 2 + (ci * class_count + k) * 2
				pairs << LigatureAnchorPair{
					ligature: parse_anchor_at(r, attach, int(r.u16_at(rec)))
					mark:     Anchor{}
				}
			}
			parts << LigatureComponent{
				pairs: pairs.clone()
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
