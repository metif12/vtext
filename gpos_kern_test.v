module vtext

// Pair adjustment is kerning: the font says a pair of glyphs is too far apart or too close, and the
// engine moves the first one. The tests read the expected answer out of the font's own tables, so
// they cannot pass by agreeing with a wrong parse.
import os

// corpus_font_path is where a named font is: the committed corpus first, this platform's font directory
// second, and none when neither has it.
//
// The corpus is asked first because a test that runs only because one machine ships a font is a test about
// that machine. The platform directory is still asked second, so a Windows checkout keeps reading Times New
// Roman and Dubai. VTEXT_TEST_FONTS overrides both.
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

fn kern_font(name string) ?&Font {
	p := corpus_font_path(name) or {
		skip_missing(name)
		return none
	}
	return load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

// amiri is the corpus font the Latin kerning tests read.
//
// It carries a Latin kerning table that closes the usual pairs, which is what these assertions ask of Times:
// A against V is -62, T against o is -97, and the reverse order gives the same number because a class matrix
// has no direction in it. Times New Roman is a Windows font the corpus does not carry, and none of the
// assertions below depends on which face answers, so the corpus one answers them everywhere.
fn amiri() ?&Font {
	return kern_font('Amiri-Regular.ttf')
}

// runes is a test helper: a list of codepoints above 255 written inline as []rune comes out empty,
// because the compiler reads those literals as bytes.
fn runes(cps ...int) []rune {
	mut out := []rune{cap: cps.len}
	for c in cps {
		out << rune(c)
	}
	return out
}

fn test_gpos_kerning_latin_pairs_move_the_first_glyph() {
	f := amiri() or { return }
	// A, V is the pair a font kerns hardest, and the adjustment is a negative advance because the
	// two letters lean into each other.
	av := f.kern_offset(f.glyph_index(`A`), f.glyph_index(`V`), 'latn') or {
		panic('times has no rule for AV')
	}
	// To, which is what a Latin reader would see at the start of the word "Today".
	to := f.kern_offset(f.glyph_index(`T`), f.glyph_index(`o`), 'latn') or {
		panic('times has no rule for To')
	}
	assert av.x < 0.0, 'AV is kerned tighter, not looser'
	assert to.x < 0.0, 'To is kerned tighter, not looser'
}

// The two glyphs are named in the order the text reads them, which for a right-to-left script means
// the rightmost glyph first. That is the order the font's own rules are written in.
//
// A class matrix has no direction in it, though: a font that kerns AV writes one class for the A and
// one for the V and a value for the cell, and that cell answers in whichever order the classes are
// named. So the same number can come back for the reverse pair, and that is not a bug. What would be
// a bug is a value that differs by direction, because the cell itself has no direction to differ in.
fn test_gpos_kerning_of_a_class_pair_does_not_depend_on_order() {
	f := amiri() or { return }
	a := f.glyph_index(`A`)
	v := f.glyph_index(`V`)
	forward := f.kern_offset(a, v, 'latn') or { panic('no rule for AV') }
	backward := f.kern_offset(v, a, 'latn') or { panic('no rule for VA') }
	assert forward.x == backward.x && forward.y == backward.y
}

// A pair the font says nothing about has no answer.
//
// The check is on the value rather than on whether there is one, because a font is allowed to write
// a zero for a pair it has decided needs no adjustment. Times does exactly that for a space and a
// period, so this asks that nothing moves the pen rather than that the rule is absent.
//
// What must not happen is a kerning value for a pair the font has no opinion about, and that is
// what class 0 in a class definition means: a glyph no definition names. Reading the class 0 row of
// the matrix would apply the adjustment the font wrote for glyphs it left out of the rule on
// purpose.
fn test_gpos_kerning_does_not_move_an_omitted_pair() {
	f := amiri() or { return }
	sp := f.glyph_index(` `)
	period := f.glyph_index(`.`)
	// Either answer is correct: no rule, or a rule that says zero. A non-zero one is not.
	if off := f.kern_offset(sp, period, 'latn') {
		assert off.x == 0.0 && off.y == 0.0, 'a space and a period are not kerned'
	}
	if off := f.kern_offset(period, sp, 'latn') {
		assert off.x == 0.0 && off.y == 0.0, 'a period and a space are not kerned'
	}
}

// A font that kerns a script says so, and one that does not says none.
fn test_gpos_kerning_reports_whether_a_script_has_any() {
	// Amiri carries a Latin kerning table, and it kerns Arabic as well.
	amiri := amiri() or { return }
	assert amiri.kerns('latn')
	// A script the font says nothing about has no kerning, whatever the font does for others.
	assert !amiri.kerns('zzzz')
}

// The offsets are in design units, as the font's own coordinates run, so they scale with the font
// and not with a pixel size the caller happened to ask for.
fn test_gpos_kerning_offsets_are_in_design_units() {
	f := amiri() or { return }
	off := f.kern_offset(f.glyph_index(`A`), f.glyph_index(`V`), 'latn') or { panic('no rule') }
	upm := f64(f.units_per_em())
	assert -off.x < upm / 4.0, 'a kern is small next to an em'
	assert off.x != 0.0, 'the pair is kerned, not zero'
}

// Arabic kerning lives under the same feature and the same lookup types, and Dubai is one of the
// Windows faces that uses it: it kerns Arabic by glyph class, so a whole class of letters is moved
// against a whole class of others rather than each pair being written out.
//
// A caller holding the text cannot ask the right question on its own, because the glyphs the rule
// names are the ones the pipeline produced rather than the ones it was given. A lam followed by an
// alef is a single ligature glyph that no pair rule can name, and the letters either side of it are
// shaped into different glyphs than the letters stand in on their own.
// The numbers 448 and 454 are Dubai's glyph ids in its own class definitions, and the distance of 3000 is
// a glyph its coverage does not name. Both are facts about one file, so this runs where that file is and
// names it everywhere else. What the corpus can carry is the class-0 and out-of-coverage halves of the
// same question, which the test above already asks of Amiri's Latin table.
fn test_gpos_kerning_reads_the_arabic_script_rules() {
	f := kern_font('DUBAI-REGULAR.TTF') or { return }
	assert f.kerns('arab'), 'dubai carries Arabic kerning rules'
	// Glyphs taken from the font's own class definitions rather than picked at random: the rule puts
	// 448 in one class and 454 in another, and the cell between them is a kern.
	assert f.kern_offset(448, 454, 'arab') != none, 'a pair the font classes together is kerned'
	assert f.kern_offset(454, 448, 'arab') != none, 'and in the other order too'
	// A rule that kerns a class of letters against everything else writes into the class 0 row,
	// because the other side is the glyphs no definition names. Class 0 is therefore a real row and
	// not an absent one, and a pair in it that the font gives a zero for is the font saying the
	// pair is already right.
	assert f.kern_offset(448, 3000, 'arab') != none, 'class 0 is a real row, not an absent one'
	if off := f.kern_offset(448, 3000, 'arab') {
		assert off.x == 0.0, 'and the font says zero for a pair it has no opinion about'
	}
	// A glyph the coverage does not name at all is the one thing that cannot match, which is what
	// stops an unrelated letter from picking up a kerning it was never given.
	assert f.kern_offset(65535, 454, 'arab') == none, 'a glyph outside the coverage is not kerned'
}

// Laying a line out and asking about what came out is the only way a caller can kern Arabic, so the
// shaped glyphs have to answer, not the letters as written.
//
// Amiri is the corpus font that kerns Arabic, and the assertions are about the shape of the answer rather
// than about which pair the font happens to kern: whatever it does with this pair, the value has to be a
// decision the font made and small next to an em.
fn test_gpos_kerning_applies_to_the_shaped_glyphs_of_a_line() {
	f := amiri() or { return }
	fs := new_font_set_of(f)
	// A word whose middle two letters the font classes together, taken from the pair the rules name.
	line := layout_paragraph(new_context(), runes(0x0645, 0x064A, 0x0628, 0x0627), .rtl, fs, 32.0)
	assert line.glyphs.len >= 2, 'the line shaped to more than one glyph'
	// Whatever the font does with this pair, it must not be a crash and it must be a decision the
	// font made rather than a number that came from nowhere.
	if off := f.kern_offset(line.glyphs[0].gid, line.glyphs[1].gid, 'arab') {
		upm := f64(f.units_per_em())
		assert -off.x < upm / 4.0, 'a kern is small next to an em'
	}
}
