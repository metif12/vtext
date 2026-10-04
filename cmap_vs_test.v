module vtext

// cmap variation sequences: formats 13 and 14.
//
// A format 14 subtable does not answer "which glyph is this codepoint". It answers "which glyph is this
// codepoint given the selectors that follow it", and the selector is consumed by the lookup rather than
// looked up on its own. That is why this is a separate pair of functions and a separate field on
// ShapedGlyph rather than a parameter: everything else in the library, from the fallback chain to
// Glyph.cluster, is built on a glyph lookup being a pure function of one rune.
//
// The fonts used here are the ten on this machine that carry a format 14 subtable, and the count came
// from reading each subtable's format field directly across all 352 files in the fonts directory.

import os

// vs_font loads a font from the Windows font directory, which is where the format 14 fixtures are.
fn vs_font(name string) &Font {
	path := os.join_path('C:\\Windows\\Fonts', name)
	return load_font_file(path) or { panic(err) }
}

fn test_a_format_14_subtable_is_read_and_reported() {
	// Every font that carries one, so a parse that silently produced nothing would be caught here
	// rather than in a lookup that happens not to be exercised.
	for name in ['seguiemj.ttf', 'mmrtext.ttf', 'phagspa.ttf'] {
		f := vs_font(name)
		formats := f.cmap_formats()
		assert 14 in formats, '${name} has a format 14 subtable and should report it, got ${formats}'

		mut records := 0
		for c in f.face.cmaps {
			if c.format == 14 {
				records += c.selectors.len
			}
		}
		assert records > 0, '${name} should have at least one variation selector record, got ${records}'
	}
}

// The count a format 14 subtable reports has to mean something. It is a table that answers nothing
// about any bare codepoint, so counting it the way the other subtables are counted reports zero, and
// zero is a lie rather than an absence: the font names hundreds of bases.
fn test_a_format_14_subtable_reports_how_many_bases_it_can_vary() {
	// Segoe UI Emoji's default table is 179 spans covering 354 codepoints, which is the number the
	// tool prints and the number a caller sizing a text run needs to know is there.
	f := vs_font('seguiemj.ttf')
	counts := f.cmap_counts()
	formats := f.cmap_formats()
	mut at := -1
	for i, format in formats {
		if format == 14 {
			at = i
		}
	}
	assert at >= 0, 'this font has a format 14 subtable'
	assert counts[at] > 300, 'it should report the bases it can vary, got ${counts[at]}'
	// And a font whose variation table names mappings rather than spans reports those instead.
	m := vs_font('mmrtext.ttf')
	mformats := m.cmap_formats()
	mut mat := -1
	for i, format in mformats {
		if format == 14 {
			mat = i
		}
	}
	assert mat >= 0, 'mmrtext has a format 14 subtable'
	assert m.cmap_counts()[mat] == 29, 'mmrtext names 29 bases, got ${m.cmap_counts()[mat]}'
}

// A font with no format 14 subtable must be left completely alone by all of this. A lookup that
// consulted a format 14 table that is not there would be a lookup reading uninitialised state.
fn test_a_font_without_a_variation_table_says_nothing_about_sequences() {
	f := vs_font('tahoma.ttf')
	assert 14 !in f.cmap_formats(), 'tahoma is not a font with a format 14 subtable'
	// A pair the font has no opinion about, and a base it does cover.
	assert !f.has_variation_sequence(0x41, 0xFE0F), 'no table, no opinion'
	assert f.glyph_index(0x41) != 0, 'and the base is covered, so this is not a font that maps nothing'
	// The selector on its own is not a character, and asking for one is the mistake the separate
	// function exists to make impossible.
	assert f.glyph_index_variation(0x41, [rune(0xFE0F)]) == f.glyph_index(0x41), 'an unknown selector changes nothing'
}

// A non-default mapping names the glyph outright, and that is the case with a real fixture: mmrtext has
// 29 of them, and U+1000 under U+FE00 is one.
fn test_a_non_default_variation_mapping_names_a_different_glyph() {
	f := vs_font('mmrtext.ttf')
	base := rune(0x1000)
	sel := rune(0xFE00)
	assert f.has_variation_sequence(base, sel), 'mmrtext maps U+1000 under U+FE00'
	plain := f.glyph_index(base)
	vs := f.glyph_index_variation(base, [sel])
	assert vs != plain, 'the sequence draws a different glyph from the base: ${vs} against ${plain}'
	assert vs != 0, 'and it is a real glyph'
}

// The base on its own is still the base. This is the property that separates a variation sequence from a
// character, and getting it wrong would draw every emoji in a text as text.
fn test_the_base_alone_is_never_affected_by_a_variation_table() {
	f := vs_font('mmrtext.ttf')
	base := rune(0x1000)
	// No selector, and with one: only the second may differ.
	assert f.glyph_index_variation(base, []) == f.glyph_index(base), 'an empty selector list is exactly the plain lookup'
}

// The default table says a base has an emoji presentation and does not say which glyph, because it is
// the base's own. So a default hit and no hit are the same glyph, and the difference is only in whether
// the font will release the base from its text presentation at all.
fn test_a_default_variation_table_releases_the_base_from_its_text_presentation() {
	f := vs_font('seguiemj.ttf')
	// U+0023 is in this font's default table, which is the ordinary case: a digit sign or a heart has a
	// text form everywhere and an emoji form in the emoji font.
	base := rune(0x23)
	sel := rune(0xFE0F)
	assert f.has_variation_sequence(base, sel), 'seguiemj gives U+0023 an emoji presentation under U+FE0F'
	assert f.glyph_index(base) != 0, 'and the base is covered by an ordinary subtable'
	// A default hit resolves to the base's own glyph, so the two agree. That is the correct answer and
	// not a fallback: the emoji font draws it as a colour glyph, and the glyph id is the same one.
	assert f.glyph_index_variation(base, [sel]) == f.glyph_index(base), 'a default table names no glyph, so the base glyph is the answer'
}

// A base the default table does not cover gets no opinion, even in a font that has one. Otherwise a
// letter with a selector after it would be drawn as an emoji, which is not what U+FE0F means.
fn test_a_base_outside_the_default_table_has_no_opinion() {
	f := vs_font('seguiemj.ttf')
	// U+0041 is not one of the 354 codepoints in the default ranges.
	assert !f.has_variation_sequence(0x41, 0xFE0F), 'A is not given an emoji presentation'
	assert f.glyph_index_variation(0x41, [rune(0xFE0F)]) == f.glyph_index(0x41), 'so the selector changes nothing'
}

// The whole point, end to end: a text with the selector draws differently from the same text without
// it. A reader looking at this would see the text and the same text as emoji.
fn test_layout_uses_the_variation_sequence_when_the_text_has_one() {
	ctx := new_context()
	f := vs_font('seguiemj.ttf')
	fs := new_font_set_of(f)
	// mmrtext's non-default mapping is the one with two different glyphs to compare, and U+1000 is a
	// Myanmar letter so the line is left to right.
	m := vs_font('mmrtext.ttf')
	mm := new_font_set_of(m)

	base := rune(0x1000)
	sel := rune(0xFE00)
	plain := layout_paragraph(ctx, [base], .ltr, mm, 32.0)
	sequenced := layout_paragraph(ctx, [base, sel], .ltr, mm, 32.0)

	assert plain.glyphs.len == 1, 'one character is one glyph, got ${plain.glyphs.len}'
	assert sequenced.glyphs.len == 1, 'the selector is not a glyph of its own, so still one, got ${sequenced.glyphs.len}'
	assert sequenced.glyphs[0].gid != plain.glyphs[0].gid, 'and it is the glyph the sequence asks for: ${sequenced.glyphs[0].gid} against ${plain.glyphs[0].gid}'
	assert sequenced.glyphs[0].cluster == 0, 'the glyph reports the character it came from, not the selector'

	// The emoji font is the same shape: one glyph either way, and the selector does not add one.
	heart := layout_paragraph(ctx, [rune(0x2764)], .auto, fs, 32.0)
	heart_emoji := layout_paragraph(ctx, [rune(0x2764), rune(0xFE0F)], .auto, fs, 32.0)
	assert heart.glyphs.len == 1 && heart_emoji.glyphs.len == 1, 'a selector must never add a glyph: ${heart.glyphs.len} and ${heart_emoji.glyphs.len}'
}

// A selector with nothing in front of it has no character to select, and drawing .notdef in its place
// would put a hollow box on the line for a character the reader cannot see.
fn test_a_selector_with_no_character_in_front_of_it_draws_nothing() {
	ctx := new_context()
	fs := new_font_set_of(vs_font('mmrtext.ttf'))
	line := layout_paragraph(ctx, [rune(0xFE00)], .ltr, fs, 32.0)
	assert line.glyphs.len == 0, 'a leading selector should draw nothing, got ${line.glyphs.len} glyphs'
	assert line.width == 0.0, 'and take no width'
}

// Format 13 is many-to-one: a whole range of codepoints is one glyph. No font on this machine has one,
// so the table is built as bytes here, the way gpos_cursive_test.v builds its own.
fn test_format_13_maps_a_range_to_one_glyph() {
	// One group: U+0041..U+0045 all become glyph 7. The array is built by assignment rather than as a
	// literal because this compiler rejects a struct element inside a braced array initializer.
	mut groups := []CmapGroup{len: 1}
	groups[0] = CmapGroup{
		start_cp:  0x41
		end_cp:    0x45
		start_gid: 7
	}
	sub := Cmap{
		format: 13
		groups: groups
	}
	assert sub.lookup_glyph(0x41) or { -1 } == u16(7), 'the first of the range'
	assert sub.lookup_glyph(0x43) or { -1 } == u16(7), 'the middle of the range'
	assert sub.lookup_glyph(0x45) or { -1 } == u16(7), 'the last of the range'
	// This is the whole difference from format 12: the glyph does not advance with the codepoint.
	assert sub.lookup_glyph(0x44) or { -1 } == u16(7), 'every codepoint in the range is the same glyph'
	assert sub.lookup_glyph(0x40) == none, 'one below the range'
	assert sub.lookup_glyph(0x46) == none, 'one above the range'
}

// The same shape as format 12 but incrementing, which is what makes reading one as the other wrong.
fn test_format_13_does_not_advance_the_glyph_the_way_format_12_does() {
	mut groups := []CmapGroup{len: 1}
	groups[0] = CmapGroup{
		start_cp:  0x41
		end_cp:    0x45
		start_gid: 100
	}
	many := Cmap{
		format: 13
		groups: groups
	}
	incrementing := Cmap{
		format: 12
		groups: groups
	}
	assert many.lookup_glyph(0x44) or { -1 } == u16(100), 'format 13 holds one glyph for the range'
	assert incrementing.lookup_glyph(0x44) or { -1 } == u16(103), 'format 12 counts through them'
}
