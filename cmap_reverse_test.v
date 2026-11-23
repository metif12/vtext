module harfara

import harfara.shape
// Tests for mapping a glyph back to the character the font draws it for.
//
// The forward direction is a table and this one is a search, so the cases that matter are the ones where
// a search can go wrong quietly: a format 4 subtable's terminating segment, a format 12 group that runs
// past the end of the glyph range, and a glyph several codepoints share.

import os
import harfara.font

fn corpus_font(name string) &shape.Font {
	return shape.load_font_file(os.join_path('testdata', 'fonts', name)) or { panic(err) }
}

// corpus_font_path is where a named font is, with the platform's own directory as a fallback so a Windows
// checkout can still be asked about a font the corpus does not carry.
fn corpus_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('HARFARA_TEST_FONTS'), 'testdata/fonts', windows_font_dir()] {
		if d != '' && d !in dirs {
			dirs << d
		}
	}
	for dir in dirs {
		p := os.join_path(dir, name)
		if os.exists(p) {
			return p
		}
	}
	return none
}

$if windows {
	fn windows_font_dir() string {
		return 'C:\\Windows\\Fonts'
	}
} $else {
	fn windows_font_dir() string {
		return ''
	}
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

// The round trip above can be served by a format 12 subtable when the
// font carries one, which leaves the format 4 delta inversion above
// unexercised: a +1 there would pass. Amiri's first subtable answers
// through format 4, so the same property over Amiri pins the delta
// arm — neutering the inversion fails here.
fn test_codepoint_for_round_trips_through_format4() {
	f := corpus_font('Amiri-Regular.ttf')
	mut checked := 0
	for cp in rune(0x20) .. rune(0x600) {
		gid := f.glyph_index(cp)
		if gid == 0 {
			continue
		}
		back := f.codepoint_for(gid) or { continue }
		assert back <= cp, 'the answer is the lowest codepoint for the glyph, not a later one: U+${cp:04X} gave U+${back:04X}'
		assert f.glyph_index(back) == gid, 'the reverse answer maps back to the same glyph'
		checked++
	}
	assert checked > 100, 'enough of the font was checked to mean something, got ${checked}'
}

// The round trips above take whichever subtable answers first, which in
// these faces is not necessarily format 4 — neutering the delta
// inversion below still passes them. This test filters the face's own
// subtables down to format 4, so the delta arm must answer: a +1 in the
// inversion fails here.
fn test_codepoint_for_format4_delta_inversion() {
	f := corpus_font('Amiri-Regular.ttf')
	mut f4 := []font.Cmap{}
	for c in f.face.cmaps {
		if c.format == 4 {
			f4 << c
		}
	}
	assert f4.len > 0, 'Amiri carries a format 4 subtable'
	mut checked := 0
	for cp in rune(0x20) .. rune(0x600) {
		gid := f.glyph_index(cp)
		if gid == 0 {
			continue
		}
		back := font.codepoint_for(f4, gid) or { continue }
		assert back <= cp, 'the answer is the lowest codepoint for the glyph, not a later one: U+${cp:04X} gave U+${back:04X}'
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

// shape.Glyph 0 is .notdef and every font maps something to it. Naming it would answer "what character draws
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

// The fonts the rest of the suite reads have to answer here too, and not only the licensed corpus.
//
// It asked Segoe UI, which is a Windows font the corpus does not carry, so the question is now asked of
// Amiri: a corpus face with Latin, so the property holds everywhere rather than on one machine. A Windows
// checkout still has Segoe UI, and HARFARA_TEST_FONTS points at any other directory.
fn test_codepoint_for_works_on_a_windows_font() {
	f := corpus_font('Amiri-Regular.ttf')
	gid := f.glyph_index(`A`)
	assert gid != 0, 'the font covers the letter'
	back := f.codepoint_for(gid) or { panic('the letter came back as nothing') }
	assert back == `A`, 'and it came back as itself, got U+${back:04X}'
}
