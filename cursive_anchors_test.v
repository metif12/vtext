module vtext

// Tests for reading a font's cursive anchors: where a letter's stroke enters and leaves.
//
// A cursive rule is one record per covered glyph naming two points, and the two are separately optional
// because a font says what a letter needs rather than what it has. What is worth testing here is that the
// two really are separate, that a glyph the rule does not cover returns nothing rather than a pair of
// absent anchors, and that the numbers are points in the font's own coordinates rather than fragments of
// a neighbouring record.

import os

// corpus_font loads one of the licensed fonts the suite ships, so these answer the same on a machine
// with no Arabic fonts installed as on one with them.
fn corpus_font(name string) &Font {
	return load_font_file(os.join_path('testdata', 'fonts', name)) or { panic(err) }
}

// Amiri declares its rule directly, Nastaliq through an extension, and Naskh has none at all. Between
// them they cover both dispatch paths and the negative case.
fn test_cursive_anchors_are_read_from_real_fonts() {
	mut with_anchors := 0
	mut ends := 0
	for name in ['Amiri-Regular.ttf', 'NotoNaskhArabic-Regular.ttf', 'NotoNastaliqUrdu-Regular.ttf'] {
		f := corpus_font(name)
		for gid in u16(0) .. u16(f.num_glyphs()) {
			a := f.cursive_anchors(gid, 'arab') or { continue }
			with_anchors++
			if a.entry_exists {
				ends++
			}
			if a.exit_exists {
				ends++
			}
		}
	}
	assert with_anchors > 100, 'the corpus carries anchors on many glyphs, got ${with_anchors}'
	assert ends > with_anchors, 'and on both ends of many of them, got ${ends} ends for ${with_anchors} glyphs'
}

// The two ends are genuinely independent, and a font uses both patterns. Nastaliq gives 158 glyphs both
// ends and Amiri gives none, so a reader that treated one as implying the other would silently drop half
// of one font and most of the other.
fn test_cursive_anchors_report_each_end_separately() {
	nastaliq := corpus_font('NotoNastaliqUrdu-Regular.ttf')
	amiri := corpus_font('Amiri-Regular.ttf')
	mut n_both := 0
	mut a_both := 0
	for gid in u16(0) .. u16(nastaliq.num_glyphs()) {
		if a := nastaliq.cursive_anchors(gid, 'arab') {
			if a.entry_exists && a.exit_exists {
				n_both++
			}
		}
	}
	for gid in u16(0) .. u16(amiri.num_glyphs()) {
		if a := amiri.cursive_anchors(gid, 'arab') {
			if a.entry_exists && a.exit_exists {
				a_both++
			}
		}
	}
	assert n_both > 100, 'Nastaliq gives many glyphs both ends, got ${n_both}'
	assert a_both == 0, 'Amiri gives none both ends, so the two are independent, got ${a_both}'
}

// A glyph the rule does not cover returns nothing. Returning a pair of absent anchors instead would make
// a caller treat every glyph in the font as having a join point at the origin.
fn test_cursive_anchors_are_absent_for_an_uncovered_glyph() {
	f := corpus_font('NotoNaskhArabic-Regular.ttf')
	// The control font has no cursive rule at all, so every glyph is uncovered.
	assert f.cursive_anchors(f.glyph_index(`س`), 'arab') == none, 'no rule means no anchors'
	assert f.cursive_anchors(0, 'arab') == none, 'not even for the first glyph'
}

// The anchors are points in the font's own units. A record array read from two bytes out of position
// still produces numbers, and they pass a bounds check far more often than they should, so the check
// here is that they are in a plausible em rather than that they are small.
fn test_cursive_anchors_are_points_in_font_units() {
	f := corpus_font('Amiri-Regular.ttf')
	mut checked := 0
	for gid in u16(0) .. u16(f.num_glyphs()) {
		a := f.cursive_anchors(gid, 'arab') or { continue }
		for p in [a.entry, a.exit] {
			if !in_font_range(p) {
				assert false, 'an anchor is a point, not a fragment: (${p.x}, ${p.y})'
			}
		}
		if a.entry_exists {
			checked++
		}
		if a.exit_exists {
			checked++
		}
	}
	assert checked > 100, 'enough anchors were checked to mean something, got ${checked}'
}

// in_font_range reports whether a point is inside a plausible em. Amiri's is 1000 units, so four times
// that is generous enough for a raised mark and far too small for a field of a neighbouring record.
fn in_font_range(p Offset2) bool {
	return p.x > -4000 && p.x < 4000 && p.y > -4000 && p.y < 4000
}
