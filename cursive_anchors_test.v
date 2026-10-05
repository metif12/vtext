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

// The reader agrees with an independent implementation, glyph for glyph.
//
// These are fontTools' numbers for Noto Nastaliq Urdu's one cursive lookup, taken glyph by glyph rather
// than in aggregate: 378 records, 38 carrying an entry anchor only, 182 an exit anchor only and 158 both.
// No glyph has neither. An earlier entry in the roadmap recorded this font as a parser mystery, and it was
// not one — it was a measurement nobody had compared against anything. Pinning the counts means a reader
// that quietly loses the 158 both-ended glyphs, or shifts the record array and reshuffles which end a glyph
// claims, fails here instead of looking plausible.
//
// The shape of the data is also what a cursive rule should look like, and that is worth asserting rather
// than assuming: a letter that joins both ways carries both ends, and a letter at the end of a word carries
// one.
fn test_cursive_anchor_counts_match_an_independent_reader() {
	f := corpus_font('NotoNastaliqUrdu-Regular.ttf')
	gpos := f.face.gpos or { panic('no GPOS') }
	mut entry_only := 0
	mut exit_only := 0
	mut both := 0
	mut neither := 0
	for l in gpos.lookups {
		for rule in l.cursives {
			for m in rule.marks {
				if m.entry.exists && m.exit.exists {
					both++
				} else if m.entry.exists {
					entry_only++
				} else if m.exit.exists {
					exit_only++
				} else {
					neither++
				}
			}
		}
	}
	assert both == 158, 'glyphs carrying both ends, got ${both}'
	assert entry_only == 38, 'glyphs carrying an entry only, got ${entry_only}'
	assert exit_only == 182, 'glyphs carrying an exit only, got ${exit_only}'
	assert neither == 0, 'and none carrying neither, got ${neither}'
	assert both + entry_only + exit_only + neither == 378, 'over 378 glyphs in total'
}

// Amiri gives no glyph both ends, which is the other shape a font can have and the reason the two ends are
// reported independently rather than one being inferred from the other.
fn test_cursive_anchors_agree_with_an_independent_reader_on_amiri() {
	f := corpus_font('Amiri-Regular.ttf')
	gpos := f.face.gpos or { panic('no GPOS') }
	mut entry_only := 0
	mut exit_only := 0
	mut both := 0
	for l in gpos.lookups {
		for rule in l.cursives {
			for m in rule.marks {
				if m.entry.exists && m.exit.exists {
					both++
				} else if m.entry.exists {
					entry_only++
				} else if m.exit.exists {
					exit_only++
				}
			}
		}
	}
	assert both == 0, 'Amiri gives no glyph both ends, got ${both}'
	assert entry_only == 52, '52 entry only, got ${entry_only}'
	assert exit_only == 236, '236 exit only, got ${exit_only}'
	assert entry_only + exit_only == 288, 'over 288 glyphs in total'
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
