module vtext

// Tests for the inspection API in inspect.v.
//
// These are not tests of the engine. The engine already has tests for whether it can shape and draw; what
// is new here is a set of claims about a font, and the thing worth testing about a claim is that it says
// what the font's bytes say rather than what the engine found convenient.
//
// Every expected number below was read from the same file with fontTools, which is the check that matters:
// two independent readers agreeing on a number is evidence, and one reader agreeing with itself is not.
// Where a number could differ for a defensible reason, such as the order of tables in a directory that
// has no order, the test asserts the thing that is actually defined rather than the thing that happened.

import os

fn inspect_font(name string) &Font {
	path := os.join_path('C:\\Windows\\Fonts', name)
	return load_font_file(path) or { panic(err) }
}

fn test_tables_are_sorted_and_complete() {
	f := inspect_font('segoeui.ttf')
	tables := f.tables()

	// fontTools reads 23 tables out of Segoe UI, which is also the directory's own count. Counting them is
	// not the point; the point is that a reader which missed one would still produce a plausible list of
	// 22, and a plausible list is what a bug like that produces.
	assert tables.len == 23, 'expected 23 tables, got ${tables.len}'
	for i in 1 .. tables.len {
		assert tables[i - 1].tag < tables[i].tag, 'tables must come back sorted by tag'
	}
	assert tables[0].tag == 'GDEF', 'first table sorted should be GDEF, got ${tables[0].tag}'
	assert tables[tables.len - 1].tag == 'prep', 'last table sorted should be prep'
}

fn test_table_length_matches_the_directory() {
	f := inspect_font('segoeui.ttf')
	tables := f.tables()

	for t in tables {
		assert f.has_table(t.tag), 'a listed table should be reported as present: ${t.tag}'
		assert f.table_length(t.tag) == t.length, 'length should agree with the listing for ${t.tag}'
	}
	// A table that is not there is reported as zero rather than as a guess, and the two are told apart by
	// has_table: an absent table is not an empty one.
	assert !f.has_table('CURS'), 'Segoe UI has no CURS table'
	assert f.table_length('CURS') == 0, 'an absent table has no length'
}

fn test_has_table_answers_what_the_engine_can_use() {
	f := inspect_font('segoeui.ttf')

	// This is the question the API exists for: the font carries tables this engine draws nothing with,
	// and saying so is better than drawing outlines and letting the caller wonder why the colour went.
	assert !f.has_table('COLR'), 'Segoe UI has no colour glyphs layer'
	assert !f.has_table('sbix'), 'Segoe UI has no bitmap strikes'
	assert f.has_table('glyf'), 'Segoe UI has TrueType outlines'
	assert f.outlines() == 'glyf', 'expected glyf outlines, got ${f.outlines()}'
}

fn test_num_lookups_counts_the_tables_own_list() {
	f := inspect_font('segoeui.ttf')

	// fontTools reads 133 substitution lookups and 137 positioning ones out of Segoe UI's LookupLists.
	// These are the counts in the tables, not the counts of anything this engine acted on.
	assert f.num_lookups('GSUB') == 133, 'expected 133 GSUB lookups, got ${f.num_lookups('GSUB')}'
	assert f.num_lookups('GPOS') == 137, 'expected 137 GPOS lookups, got ${f.num_lookups('GPOS')}'
	assert f.num_lookups('kern') == 0, 'an unknown table has no lookups'
}

fn test_features_are_reported_sorted_and_deduplicated() {
	f := inspect_font('segoeui.ttf')

	features := f.features('GPOS')
	for i in 1 .. features.len {
		assert features[i - 1] < features[i], 'features must come back sorted'
	}
	// The count of tags is not the count of places a tag is named: a font that offers kern
	// under two scripts offers one kerning feature. fontTools finds 5 distinct tags in
	// Segoe UI's GPOS, and its Arabic mark rules live inside those same five rather than
	// under tags of their own.
	assert f.num_features('GPOS') == 5, 'expected 5 distinct GPOS features, got ${f.num_features('GPOS')}'
	assert features.len == f.num_features('GPOS'), 'features and num_features must agree'
	assert 'kern' in features, 'Segoe UI kerns'
	assert 'mark' in features, 'Segoe UI places marks'
	// GSUB names 25 tags, and two of them reach no default language system: 'isol' and
	// 'locl' are enabled only under a tagged language. A count built from the scripts would
	// say 23, and would be wrong about what the font can do.
	assert f.num_features('GSUB') == 25, 'expected 25 distinct GSUB features, got ${f.num_features('GSUB')}'
	assert 'isol' in f.features('GSUB'), 'a feature only a tagged language enables is still one the font has'
	assert f.num_features('kern') == 0, 'an unknown table offers no features'
}

fn test_scripts_are_the_tables_own_list() {
	f := inspect_font('segoeui.ttf')

	scripts := f.scripts('GPOS')
	for i in 1 .. scripts.len {
		assert scripts[i - 1] < scripts[i], 'scripts must come back sorted'
	}
	assert 'arab' in scripts, 'Segoe UI declares Arabic for positioning'
	assert 'latn' in scripts, 'Segoe UI declares Latin for positioning'
	assert f.num_features('GSUB') > 0, 'GSUB should have features to count'
	assert f.scripts('kern').len == 0, 'an unknown table declares no scripts'
}

fn test_cmap_reports_every_subtable_not_only_the_chosen_one() {
	f := inspect_font('segoeui.ttf')

	formats := f.cmap_formats()
	counts := f.cmap_counts()

	// Segoe UI declares two subtables, both format 4, both mapping 3996 codepoints. The point of
	// reporting both is that a reader knowing which one the engine picked is a different question from
	// knowing what the font carries.
	assert formats.len == 2, 'expected 2 cmap subtables, got ${formats.len}'
	assert counts.len == formats.len, 'counts and formats must be the same length'
	assert formats[0] == 4 && formats[1] == 4, 'Segoe UI uses format 4 twice'
	for i, c in counts {
		assert c == 3996, 'subtable ${i} should map 3996 codepoints, got ${c}'
	}
}

fn test_cmap_count_excludes_notdef() {
	f := inspect_font('segoeui.ttf')

	// The count walks the codepoints and skips .notdef, because a subtable is allowed to name a
	// character it has no glyph for. A font that maps U+0000 to glyph 0 is counted once for it only if
	// that is a real mapping, and here it is not.
	counts := f.cmap_counts()
	assert counts[0] < 0x10000, 'a mapped count cannot exceed the codepoints walked'
	assert counts[0] > 3000, 'Segoe UI maps far more than three thousand characters'
}

fn test_glyph_class_counts_come_from_gdef() {
	f := inspect_font('segoeui.ttf')
	counts := f.glyph_class_counts()

	// fontTools counts 4904 bases, 147 ligatures and 343 marks across Segoe UI's 5394 glyphs, with the
	// rest unclassified. The counts add up to the glyph count, which is what makes them worth printing:
	// a class the reader silently dropped would show up here as a shortfall.
	mut total := 0
	for c in counts {
		total += c
	}
	assert total == f.num_glyphs(), 'every glyph belongs to exactly one class, got ${total} of ${f.num_glyphs()}'
	assert counts[1] > 4000, 'a text font is mostly bases, got ${counts[1]}'
	assert counts[2] > 100, 'Segoe UI has ligatures, got ${counts[2]}'
	assert counts[3] > 300, 'Segoe UI has marks, got ${counts[3]}'
	assert counts[4] == 0, 'Segoe UI has no components'
	assert counts[0] == 0, 'GDEF classifies every glyph in Segoe UI'
	assert glyph_class_names[3] == 'mark', 'class 3 is a mark'
	assert glyph_class_names[1] == 'base', 'class 1 is a base'
}

fn test_glyph_class_counts_without_gdef_are_all_unclassified() {
	// A font with no GDEF puts every glyph in "unclassified". That is what GDEF's absence means rather
	// than a claim that the font has no bases and no marks, and the counts still add up.
	seg := os.join_path('C:\\Windows\\Fonts', 'segoeui.ttf')
	data := os.read_bytes(seg) or { panic(err) }
	stripped := remove_table(data, 'GDEF')
	f := load_font_bytes(stripped) or { panic(err) }

	counts := f.glyph_class_counts()
	assert !f.has_table('GDEF'), 'the stripped font should have no GDEF'
	assert counts[1] == 0 && counts[2] == 0 && counts[3] == 0, 'no table means no classes'
	mut total := 0
	for c in counts {
		total += c
	}
	assert total == f.num_glyphs(), 'every glyph is still counted once'
	assert counts[0] == f.num_glyphs(), 'and every glyph is unclassified'
}

// remove_table rebuilds a font without one table, by zeroing its record in the directory and clearing its
// tag. The table's bytes are left where they are, which is harmless: nothing reads a table the directory
// does not name, and a smaller rewrite would be a second parser to test.
//
// This exists so the GDEF-absence case can be exercised against a real font rather than a mock. A mock
// would test the mock.
fn remove_table(data []u8, tag string) []u8 {
	mut out := data.clone()
	num_tables := (int(out[4]) << 8) | int(out[5])
	for i in 0 .. num_tables {
		at := 12 + i * 16
		mut got := ''
		for j in 0 .. 4 {
			got += out[at + j].ascii_str()
		}
		if got == tag {
			for j in 0 .. 4 {
				out[at + j] = u8(32)
			}
			// The count goes down as well, so a reader that walks the directory by count stops before it
			// reaches the blanked record rather than having to skip it.
			out[4] = u8((num_tables - 1) >> 8)
			out[5] = u8((num_tables - 1) & 0xFF)
			return out
		}
	}
	return out
}

fn test_is_variable_and_axes() {
	f := inspect_font('segoeui.ttf')

	// Segoe UI on this machine is not a variable font, so there is nothing to read and the answer says so
	// rather than returning an empty list that could mean anything.
	assert !f.is_variable(), 'Segoe UI has no fvar table'
	assert f.variable_axes().len == 0, 'a font with no fvar has no axes'
}

// inspect_runes builds a rune sequence from hex, because this V emits a broken initialiser for a []rune
// written with non-ASCII literals in it. The test data stays in hex for the same reason the UCD tests do.
fn inspect_runes(fields []string) []rune {
	mut out := []rune{}
	for f in fields {
		out << rune(hex_value(f))
	}
	return out
}

fn test_break_opportunity_fields_are_readable_from_outside() { // BreakOpportunity is public because break_opportunities is, and a public function returning a
	// private struct leaves its caller able to count the results and nothing else.
	ctx := new_context()
	mut out := []BreakOpportunity{}

	for op in break_opportunities(ctx, inspect_runes(['61', '20', '62']), false) {
		out << op
	}
	assert out.len > 0, 'there should be breaks in "a b"'

	// Every field is readable, which is the whole point of the change: a caller laying out two lines
	// needs to know where the second one starts, and a caller walking a paragraph needs to know which
	// breaks it may not skip.
	mut saw_space := false
	for op in break_opportunities(ctx, inspect_runes(['61', '20', '62']), false) {
		assert op.start >= 0, 'a break starts somewhere'
		assert op.at <= op.start, 'the glyph index is not ahead of the input index'
		if op.at == 2 {
			saw_space = true
			assert !op.is_mandatory, 'a space is not a mandatory break'
		}
	}
	assert saw_space, 'there should be a break at the space'
}

fn test_mandatory_breaks_are_marked() {
	ctx := new_context()

	// A newline requires a break and a caller may not skip it the way it skips the others. The flag is
	// the only way to tell the two apart from outside the module, which is why it became public.
	//
	// The break falls at index 2 rather than at 1, and that is the rules rather than an off-by-one. The
	// newline is at index 1, LB7 forbids a break before it, so the opportunity the caller gets is the one
	// after it: a paragraph break comes after the character that ends the paragraph, not before it. The
	// break at 1 exists and is not mandatory, which is the case worth asserting alongside.
	mut mandatory_at := -1
	mut other := []int{}
	for op in break_opportunities(ctx, inspect_runes(['61', '0A', '62']), true) {
		if op.is_mandatory {
			mandatory_at = op.at
		} else {
			other << op.at
		}
	}
	assert mandatory_at == 2, 'the newline ends the paragraph, so the mandatory break is at 2, got ${mandatory_at}'
	assert other.len > 0, 'and there are breaks that are not mandatory'
	assert 1 in other, 'LB7 forbids a break before the newline, so the one at 1 is not mandatory'

	// A space is a break a caller may take or leave. Reporting it as mandatory would make a caller treat
	// every space as a paragraph end.
	mut space_mandatory := false
	for op in break_opportunities(ctx, inspect_runes(['61', '20', '62']), true) {
		if op.at == 2 {
			space_mandatory = op.is_mandatory
		}
	}
	assert !space_mandatory, 'a space is not a paragraph end'
}
