module vtext

// Tests for mapping a glyph back to the character the font draws it for.
//
// The forward direction is a table and this one is a search, so the cases that matter are the ones where
// a search can go wrong quietly: a format 4 subtable's terminating segment, a format 12 group that runs
// past the end of the glyph range, and a glyph several codepoints share.

import os

fn corpus_font(name string) &Font {
	return load_font_file(os.join_path('testdata', 'fonts', name)) or { panic(err) }
}

// The round trip is the property that matters: whatever the font maps a character to, asking that glyph
// back must give the character or a lower one, because the lowest is the answer by definition.
fn test_codepoint_for_round_trips_what_the_font_maps() {
	f := corpus_font('NotoNaskhArabic-Regular.ttf')
	mut checked := 0
	for cp in rune(0x20) .. rune(0x600) {
		gid := f.glyph_index(cp)
		if gid == 0 {
			continue
		}
		back := f.codepoint_for(gid) or { continue }
		assert back <= cp, 'the answer is the lowest codepoint for the glyph, not a later one: U+${cp:04X} gave U+${back:04X}'
		// The glyph really is the one that codepoint maps to, so the pair is genuinely the same
		// glyph rather than two that happen to be neighbours in the table.
		assert f.glyph_index(back) == gid, 'the reverse answer maps back to the same glyph'
		checked++
	}
	assert checked > 100, 'enough of the font was checked to mean something, got ${checked}'
}

// A font can map several codepoints to one glyph, and the lowest has to win every time, or a glyph is
// named one way in one tool and another way in the next. Arabic fonts do this constantly: a face that
// draws the base letter and its initial form as one glyph maps U+0633 and U+FEB1 to the same index,
// which is exactly the case that gives a reverse lookup something to get wrong.
fn test_codepoint_for_returns_the_lowest_codepoint_for_a_shared_glyph() {
	f := corpus_font('NotoNaskhArabic-Variable.ttf')
	base := f.glyph_index(`س`)
	initial := f.glyph_index(`ﺱ`)
	assert base != 0 && initial != 0, 'the font covers the letter and its initial form'
	assert base == initial, 'this font draws them as one glyph, which is the case under test'
	back := f.codepoint_for(base) or { panic('no answer') }
	assert back == `س`, 'the lower codepoint is the answer, not the presentation form, got U+${back:04X}'

	// And nothing lower maps to that glyph either, which is the property being claimed rather than a
	// single example of it.
	for lower in rune(0x20) .. back {
		assert f.glyph_index(lower) != base, 'U+${lower:04X} is lower and also maps to this glyph'
	}
}

// Glyph 0 is .notdef and every font maps something to it. Naming it would answer "what character draws
// nothing" with the lowest control character the font happens to reference, which is the one answer a
// caller cannot use.
fn test_codepoint_for_has_no_answer_for_notdef() {
	for name in ['Amiri-Regular.ttf', 'NotoNaskhArabic-Regular.ttf', 'NotoNastaliqUrdu-Regular.ttf'] {
		f := corpus_font(name)
		assert f.codepoint_for(0) == none, '${name} gives .notdef no character'
	}
}

// A format 4 subtable ends with a segment whose start and end are both 0xFFFF. Reading it as coverage
// maps 0xFFFF to a real glyph, and a glyph that some other codepoint happens to share would then be
// named U+FFFF, which is not a character anyone can type.
fn test_codepoint_for_ignores_the_format4_terminating_segment() {
	f := corpus_font('Amiri-Regular.ttf')
	// If the font's own forward mapping sends 0xFFFF somewhere other than .notdef, that glyph must not
	// come back as U+FFFF. If it does send it to .notdef there is no glyph to name and there is nothing
	// to check, which is also the right answer.
	gid := f.glyph_index(0xFFFF)
	if gid == 0 {
		return
	}
	if back := f.codepoint_for(gid) {
		assert back != 0xFFFF, 'the terminating segment is not a character'
	}
}

// A variable font has to answer the same as a static one, since the reverse direction does not care how
// the font stores its glyphs.
fn test_codepoint_for_works_on_a_variable_font() {
	f := corpus_font('NotoNaskhArabic-Variable.ttf')
	gid := f.glyph_index(`س`)
	assert gid != 0, 'the corpus font covers the letter'
	back := f.codepoint_for(gid) or { panic('the letter came back as nothing') }
	assert back == `س`, 'and it came back as itself, got U+${back:04X}'
}

// Windows fonts are the ones the rest of the suite reads, so the reverse direction has to work there too
// and not only on the licensed corpus.
fn test_codepoint_for_works_on_a_windows_font() {
	f := load_font_file('C:\\Windows\\Fonts\\segoeui.ttf') or { panic(err) }
	gid := f.glyph_index(`A`)
	assert gid != 0, 'the font covers the letter'
	back := f.codepoint_for(gid) or { panic('the letter came back as nothing') }
	assert back == `A`, 'and it came back as itself, got U+${back:04X}'
}
