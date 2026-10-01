module vtext

// Tests for the cmap parser, and in particular for the one bug in it that mattered most.
//
// The bug is worth a file of its own. Format 4 addresses its glyphIdArray through a byte offset
// stored per segment, measured from the address of the offset's own slot rather than from the
// start of the array. Reading it from the array's start is off by two bytes per segment, which is
// one glyph index per segment, and glyphIdArray is a dense run of glyph indices, so the result is
// a real glyph that is simply the wrong one.
//
// Nothing failed. Fonts loaded, glyphs came back, tests passed, and lines came out. What was wrong
// was that every Arabic letter was drawn one glyph along from the one the font's own tables
// described, so the font's substitution and positioning rules were being asked about glyphs it had
// never emitted and every one of them silently did nothing. The visible symptom was that joining
// stopped working on some fonts while the letters stayed legible, which is the worst shape a
// shaping bug can take: wrong output with no error in it.

import os

fn cmap_font(name string) &Font {
	path := os.join_path('C:\\Windows\\Fonts', name)
	return load_font_file(path) or { panic(err) }
}

const probe_beh = rune(0x0628)
const probe_alef = rune(0x0627)
const probe_fatha = rune(0x064E)
const probe_shadda = rune(0x0651)

fn cmap_probe_letters() []rune {
	return [rune(0x0628), rune(0x0627), rune(0x062B), rune(0x0633), rune(0x0644), rune(0x0645),
		rune(0x0646), rune(0x0647), rune(0x0648), rune(0x06A9), rune(0x06CC), rune(0x067E),
		rune(0x0686), rune(0x06AF)]
}

// The specific glyphs, read out of Dubai's bytes by a separate decoder rather than by this parser,
// so they say what the font contains rather than what the parser believes.
//
// A failure here means either the font on this machine has been replaced or the parser has changed
// its answer, and both are worth stopping for. This is a change detector, not the proof: the proof
// that the parser is right is the shaping consistency test in gsub_test.v, which would fail for a
// wrong answer however many right answers were pinned alongside it.
fn test_known_glyph_ids_read_from_a_font_by_another_decoder() {
	dubai := cmap_font('DUBAI-REGULAR.TTF')
	assert dubai.glyph_index(probe_beh) == 157, 'beh'
	assert dubai.glyph_index(probe_alef) == 139, 'alef'
	assert dubai.glyph_index(rune(0x064B)) == 656, 'fathatan'
	assert dubai.glyph_index(probe_fatha) == 659, 'fatha'
	assert dubai.glyph_index(probe_shadda) == 662, 'shadda'
	// The Latin side of the same table. These land in a completely different part of the glyph
	// numbering from the Arabic ones, so a reader that is off by a segment count cannot happen to
	// be right about both.
	assert dubai.glyph_index(`h`) == 86
	assert dubai.glyph_index(`j`) == 93
	assert dubai.glyph_index(`r`) == 112
	// Codepoints reached through the glyphIdArray rather than a plain delta, which is the case the
	// offset arithmetic exists for.
	assert dubai.glyph_index(rune(0x0312)) == 598
	assert dubai.glyph_index(rune(0x0338)) == 606
}

// Where a font offers more than one Unicode subtable they should agree about the Arabic letters,
// and the one the engine picks has to be one of them. A font offering a subtable that disagrees
// with the one in use is a font with two opinions, and picking the wrong one produces the same
// class of quiet wrongness as the offset bug: real glyphs, none of them the ones the rest of the
// font describes.
fn test_the_chosen_subtable_is_one_the_font_agrees_with() {
	for name in ['DUBAI-REGULAR.TTF', 'majalla.ttf', 'tahoma.ttf', 'segoeui.ttf', 'ARABTYPE.TTF',
		'trado.ttf', 'andlso.ttf', 'simpo.ttf'] {
		f := cmap_font(name)
		// The subtable in use has to be a format the engine claims to read.
		mut used := 0
		for c in f.face.cmaps {
			if c.score > used {
				used = c.score
			}
		}
		assert used > 0, '${name}: no subtable scored above zero, so none is being used'
		// Every subtable the font offers that is meant for Unicode, and what it says about a few
		// letters. Windows and Unicode platforms both qualify, and a font is entitled to offer
		// only the Windows one.
		mut agreeing := 0
		mut unicode_subtables := 0
		for c in f.face.cmaps {
			if c.platform != platform_unicode && c.platform != platform_windows {
				continue
			}
			unicode_subtables++
			mut same := true
			for cp in cmap_probe_letters() {
				if c.lookup_glyph(u32(cp)) or { 0 } != f.glyph_index(cp) {
					same = false
				}
			}
			if same {
				agreeing++
			}
		}
		assert unicode_subtables > 0, '${name}: no Unicode or Windows subtable at all'
		assert agreeing == unicode_subtables, '${name}: a Unicode subtable disagrees with the one in use'
	}
}

// A codepoint the font has no character for is a question with an answer, and the answer is
// .notdef rather than a crash or a glyph from somewhere else in the table.
fn test_cmap_answers_for_codepoints_it_does_not_have() {
	dubai := cmap_font('DUBAI-REGULAR.TTF')
	// Codepoints from other scripts, the private use area, and the very top of the range. U+0000
	// is left out on purpose: a font is entitled to map a control character, and whether this one
	// does is the font's business rather than the parser's.
	for cp in [rune(0x0378), rune(0x0590), rune(0xE000), rune(0x10FFFF)] {
		assert !dubai.has_glyph(cp), 'U+${cp:04X} should not be in an Arabic font'
		assert dubai.glyph_index(cp) == 0, 'and should come back as .notdef'
	}
	// A font with no cmap at all is the same question asked of a font that has none.
	narrow := cmap_font('ARIALN.TTF')
	assert !narrow.has_gsub(), 'this font is about cmap, and it has no Arabic to map'
	assert narrow.glyph_index(`A`) == narrow.glyph_index(`A`), 'a letter it does have still resolves'
}
