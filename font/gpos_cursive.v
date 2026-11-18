module font

// cursive_anchors returns where a glyph's joining stroke enters and leaves, in design units.
//
// A glyph the font gives no anchors for returns none rather than a pair of absent anchors, because a
// font that does not describe a glyph's joining is not making a statement the caller can act on.
//
// y is positive upwards, as in the rest of the table's output. A renderer working in screen
// coordinates has to flip it.
pub fn (g &Gpos) cursive_anchors(gid u16, script string, lang string) ?CursiveAnchors {
	for li in g.lookups_for_lang(script, lang, 'curs') {
		if li >= g.lookups.len {
			continue
		}
		for rule in g.lookups[li].cursives {
			if ee := rule.offset_for(gid) {
				return CursiveAnchors{
					entry:        Offset2{ x: ee.entry.x, y: ee.entry.y }
					exit:         Offset2{ x: ee.exit.x, y: ee.exit.y }
					entry_exists: ee.entry.exists
					exit_exists:  ee.exit.exists
				}
			}
		}
	}
	return none
}

// EntryExit is one glyph's pair of cursive anchors: where its stroke enters and where it leaves.
//
// This is the difference between a joined script and merely joined letters. A font that uses these
// says the pen should carry from the exit point of one letter to the entry point of the next, so two
// letters can be drawn at whatever spacing keeps the stroke continuous, and a letter can have a
// different width from the one its advance would give it.
//
// Either anchor may be absent. A letter at the start of a word has nothing before it and some fonts
// give it no entry point, and a letter at the end has nothing after it and no exit point, so an absent
// one is a normal thing rather than a broken table.
pub struct EntryExit {
pub mut:
	entry Anchor
	exit  Anchor
}

// Cursive is one cursive attachment rule: which glyphs carry anchors, and what they are.
//
// The anchors are found by coverage index rather than by an offset, so a glyph is looked up the same
// way a mark is looked up by its class.
pub struct Cursive {
pub mut:
	// format is which of the two formats the subtable declared.
	format u16
	// ranges is the coverage of the glyphs that carry anchors.
	ranges []CoverageRange
	// marks is indexed by the glyph's coverage index.
	marks []EntryExit
}

// offset_for finds the anchors of one glyph within a single rule.
pub fn (rule &Cursive) offset_for(gid u16) ?EntryExit {
	idx := coverage_index(rule.ranges, gid) or { return none }
	if idx >= rule.marks.len {
		return none
	}
	return rule.marks[idx]
}

// parse_cursive reads one CursivePos subtable, and refuses anything that is not one.
//
// The lookup type already answers this — a cursive rule is type 3 and a single positioning is type 1 — so
// nothing here has to guess from the bytes. It does not guess anyway, because a font can wrap either in an
// extension that names its real type wrongly, and a reader that trusts that without looking is a reader
// that reads mark attachment as a joining rule.
//
// The check is structural rather than lucky. In a cursive rule the anchors are a separate table written
// after the records, so every offset in the records points past the end of the records themselves, and
// what it points at declares itself an anchor. In a single positioning the word in that place is the
// value format, which is a small bitmask and cannot point past a value array that is already there. That
// is what Andalus's lookup 21 fails: its valueFormat of 3 is a valid anchor format, so the format alone
// does not separate the two tables and an offset read as a point lands in the middle of the value array.
pub fn parse_cursive(r &Reader, at int) ?Cursive {
	format := r.u16_at(at)
	if format != 1 && format != 2 {
		return none
	}
	ranges := parse_coverage(r, at + int(r.u16_at(at + 2)))
	if ranges.len == 0 {
		return none
	}
	// The coverage decides which glyphs the rule applies to, and its glyph count is the sum of the range
	// widths rather than the length of the range list: a coverage of five glyphs written as one range still
	// covers five glyphs.
	mut glyphs := 0
	for cr in ranges {
		glyphs += int(cr.last - cr.first) + 1
	}
	// Both cursive formats are laid out the same way: posFormat, coverageOffset, entryExitCount, then the
	// records. The formats differ only in what entryExitCount is allowed to be. Format 1 demands one record
	// per covered glyph, format 2 lets the trailing covered glyphs go unrecorded. So the count is always read
	// rather than inferred from the coverage, and the records always start six bytes in.
	mut count := int(r.u16_at(at + 4))
	if count > glyphs {
		// A font that names more records than it has coverage is claiming glyphs it does not cover, so
		// only the covered ones are read.
		count = glyphs
	}
	first_record := at + 6
	records_end := first_record + 4 * count
	mut marks := []EntryExit{cap: glyphs, len: 0}
	mut p := first_record
	for _ in 0 .. count {
		// A record is two offsets from the start of the subtable, and an offset of zero means that end
		// of the letter takes no part in the joining.
		if !cursive_record_plausible(r, at, records_end, p) {
			return none
		}
		marks << EntryExit{
			entry: parse_anchor_at(r, at, int(r.u16_at(p)))
			exit:  parse_anchor_at(r, at, int(r.u16_at(p + 2)))
		}
		p += 4
	}
	// The glyphs a format 2 rule covers but does not record take no part in the joining, and they get
	// nothing at all rather than empty anchors, which is what a letter at the end of a word looks like.
	mut idx := 0
	for idx < glyphs - count {
		marks << EntryExit{}
		idx++
	}
	// A rule whose every offset is zero anchors nothing, and a font that means it wrote a positioning
	// rule rather than a cursive one.
	mut anchored := false
	for m in marks {
		if m.entry.exists || m.exit.exists {
			anchored = true
		}
	}
	if !anchored {
		return none
	}
	return Cursive{
		format: format
		ranges: ranges
		marks:  marks
	}
}

// cursive_record_plausible says whether the two offsets at p could be a cursive record.
//
// A zero offset is always allowed, since it means the anchor is absent rather than misplaced. Every
// offset that is there has to point past the records and land on something that declares itself an
// anchor, which is a format between 1 and 3.
pub fn cursive_record_plausible(r &Reader, base int, records_end int, p int) bool {
	for slot in 0 .. 2 {
		offset := int(r.u16_at(p + 2 * slot))
		if offset == 0 {
			continue
		}
		if base + offset < records_end {
			return false
		}
		if !r.has(base + offset, 4) {
			return false
		}
		declared := r.u16_at(base + offset)
		if declared < 1 || declared > 3 {
			return false
		}
	}
	return true
}
