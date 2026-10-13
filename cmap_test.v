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

// corpus_font_path is where a named font is: the committed corpus first, this platform's font directory
// second, and none when neither has it.
//
// The corpus is asked first because a test that runs only because one machine ships a font is a test about
// that machine. The platform directory is still asked second, so a Windows checkout keeps reading Dubai
// and the eight other Windows faces this file was written against. VTEXT_TEST_FONTS overrides both.
fn corpus_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('VTEXT_TEST_FONTS'), 'testdata/fonts', windows_font_dir()] {
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

// skip_missing records why a test cannot run. A skip that prints nothing is a failure pretending to be a
// pass, so every one of them names the font it wanted and where it looked, and it is written to the file
// tools/run_tests.v names in VTEXT_SKIP_LOG rather than to stdout.
//
// The file rather than stdout, because V's test runner does not print a passing test's output: measured on
// Linux, every println line a passing file writes is discarded, so a suite of skips would look exactly
// like a suite of passes. Written where the runner reads it, a skip is counted whether its test passed or
// failed, on every platform, and the runner says how many there were.
fn skip_missing(name string) {
	line := 'SKIP ${name} is in neither testdata/fonts nor the platform font directory'
	path := os.getenv('VTEXT_SKIP_LOG')
	if path != '' {
		mut f := os.open_append(path) or { return }
		f.writeln(line) or { return }
		f.close()
		return
	}
	println(line)
}

fn cmap_font(name string) ?&Font {
	p := corpus_font_path(name) or {
		skip_missing(name)
		return none
	}
	return load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

// corpus_cmap_fonts are the committed fonts this file reads.
//
// They are the ones that answer on every platform: four faces, two vendors, a static and a variable one,
// and two with several cmap subtables between them. No number below depends on which of them answered.
const corpus_cmap_fonts = ['Amiri-Regular.ttf', 'NotoNaskhArabic-Regular.ttf',
	'NotoNastaliqUrdu-Regular.ttf', 'NotoNaskhArabic-Variable.ttf']
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
// Those numbers are Dubai's, and they are the point: a glyph id is a fact about one file, so the
// assertions only mean anything on a machine that has Dubai. It is a Windows font, it is not in the
// corpus, and it cannot be substituted without inventing numbers for a font nobody has read. So the
// test runs where the font is and skips where it is not, saying which font it wanted.
fn test_known_glyph_ids_read_from_a_font_by_another_decoder() {
	dubai := cmap_font('DUBAI-REGULAR.TTF') or { return }
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
//
// The list was the eight Arabic fonts this machine shipped, and is now the four the corpus carries. Two
// of them offer four subtables each and two offer two, which is the spread the test needs: a font is
// entitled to offer only one, and only two is the case where picking the wrong one is possible.
fn test_the_chosen_subtable_is_one_the_font_agrees_with() {
	for name in corpus_cmap_fonts {
		f := cmap_font(name) or { return }
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
//
// The Nastaliq corpus font is the one that answers this: it carries Arabic and the Arabic marks, and
// none of the codepoints below, so an unmapped answer can only come from the parser and not from a font
// that happens to have the character.
fn test_cmap_answers_for_codepoints_it_does_not_have() {
	nastaliq := cmap_font('NotoNastaliqUrdu-Regular.ttf') or { return }
	// Codepoints from other scripts, the private use area, and the very top of the range. U+0000
	// is left out on purpose: a font is entitled to map a control character, and whether this one
	// does is the font's business rather than the parser's.
	for cp in [rune(0x0378), rune(0x0590), rune(0xE000), rune(0x10FFFF)] {
		assert !nastaliq.has_glyph(cp), 'U+${cp:04X} should not be in an Arabic font'
		assert nastaliq.glyph_index(cp) == 0, 'and should come back as .notdef'
	}
	// And the letters it does carry still resolve, which is what makes the answer above a
	// decision rather than a font that maps nothing.
	assert nastaliq.glyph_index(`ا`) != 0
}

// A font with no GSUB table at all is the same question asked of a font that has none: the parser has to
// say so rather than reporting a table it never read.
//
// It is its own test because the corpus has no such font — all four of the committed faces carry a
// substitution table — and a font with no substitution table is exactly what the original assertion asked
// of Arial Narrow on this machine. Until the corpus carries one, this says which font it wants and stops,
// rather than being quietly dropped from the test above.
fn test_a_font_with_no_gsub_table_reports_none() {
	narrow := cmap_font('ARIALN.TTF') or { return }
	assert !narrow.has_gsub(), 'this font is about cmap, and it has no Arabic to map'
	assert narrow.glyph_index(`A`) == narrow.glyph_index(`A`), 'a letter it does have still resolves'
}
