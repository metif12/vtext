module vtext

import os

// corpus_font_path is where a named font is: the committed corpus first, this platform's font directory
// second, and none when neither has it.
//
// The corpus is first, but no corpus font can answer the numbers below: every one of them is a value
// fontTools read out of one specific file, and a kern of -140 for A against V is a fact about Segoe UI and
// not about a format. So these tests read Segoe UI, Times New Roman and Verdana where they are installed
// and say which font they wanted where they are not. The corpus is what the shape tests above it use.
// VTEXT_TEST_FONTS overrides both.
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

// kern_font opens a font from the corpus or from the platform's own directory, and answers none when
// neither has it so the test can say which font it wanted.
fn kern_font(name string) ?&Font {
	p := corpus_font_path(name) or {
		skip_missing(name)
		return none
	}
	return load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

// exact_kern is the kerning for a pair as one integer, for a test that compares against a number rather
// than a sign.
fn exact_kern(f &Font, left string, right string) i32 {
	off := f.kern_offset(f.glyph_index(left.runes()[0]), f.glyph_index(right.runes()[0]),
		'latn') or { return 0 }
	return off.x
}

// Pair adjustment in format 1 is a count, then that many records of three things: the second glyph, the
// value for the first glyph, and the value for the second.
//
// The specification's prose describes this as an array of the second glyphs followed by an array of the
// records, which is not what the bytes are. Segoe UI writes its first PairSet as the count 65 and then
// C, -40, G, -40, J, 94, O, -40, T, -147, U, -40, V, -140: each glyph immediately followed by its
// value. Reading it the way the prose says puts every glyph first and every value after, which
// misaligns every record and yields a kern of +60 for A followed by V where the font says -140.
//
// These tests fix the shape from the font's own bytes, so they cannot pass by agreeing with a wrong
// parse: every number here is what fontTools reads out of the same file.
fn test_gpos_pair_pos_format_one_reads_the_second_glyph_with_its_value() {
	f := kern_font('segoeui.ttf') or { return }
	// The pairs fontTools reports for Segoe UI's Latin kerning, and the values are exact.
	for pair in [['A', 'V'], ['T', 'o'], ['V', 'A'], ['Y', 'o'], ['A', 'T'], ['F', 'A']] {
		l := pair[0].runes()[0]
		r := pair[1].runes()[0]
		off := f.kern_offset(f.glyph_index(l), f.glyph_index(r), 'latn') or {
			panic('segoeui has no rule for ${pair[0]}${pair[1]}')
		}
		assert off.x < 0, '${pair[0]}${pair[1]} closes rather than opens'
	}
	// And the exact numbers, because a positive value would still be negative and would still pass the
	// test above.
	assert exact_kern(f, 'A', 'V') == -140, 'AV is the font number'
	assert exact_kern(f, 'T', 'o') == -200, 'To is the font number'
	assert exact_kern(f, 'A', 'T') == -147, 'AT is the font number'
	assert exact_kern(f, 'Y', 'o') == -180, 'Yo is the font number'
}

// The two formats are different layouts behind one number, and a fix to one must not touch the other.
// Times and Arial keep their Latin kerning in format 2, which is a class matrix rather than a list of
// pairs, and they were reading correctly before format 1 was.
fn test_gpos_pair_pos_format_two_still_answers_after_format_one_was_fixed() {
	f := kern_font('times.ttf') or { return }
	assert exact_kern(f, 'A', 'V') != 0, 'times kerns AV through the class matrix'
	assert exact_kern(f, 'T', 'o') != 0, 'and To'
	assert f.kerns('latn'), 'and reports that it kerns the script'
}

// Verdana's kerning is format 1 too, and in a lookup that is not wrapped in an extension, so it covers
// the case of a format 1 rule read without unwrapping anything first.
fn test_gpos_pair_pos_format_one_without_an_extension_wrapper() {
	f := kern_font('verdana.ttf') or { return }
	assert f.kerns('latn'), 'verdana carries Latin kerning rules'
	assert exact_kern(f, 'A', 'V') == -60, 'AV is the font number'
	assert exact_kern(f, 'T', 'o') == -220, 'and To'
}

// A glyph a font does not pair must still answer nothing after the reader changed shape, or a lookup
// that walks off the end of a set would answer a pair nobody wrote down.
fn test_gpos_pair_pos_format_one_still_refuses_a_pair_the_font_does_not_have() {
	f := kern_font('segoeui.ttf') or { return }
	// A space is not in Segoe UI's kern pair sets, so there is no record to find.
	assert f.kern_offset(f.glyph_index(' '.runes()[0]), f.glyph_index('.'.runes()[0]), 'latn') == none, 'a space and a period are not kerned'
}

// The number of sets a rule reports is the count in its header, which is the number of covered first
// glyphs rather than the number of coverage ranges. Segoe UI's Latin rule covers 87 glyphs in 59 ranges
// and has 87 sets; reading the range count instead gives 59 and loses 28 first glyphs.
fn test_gpos_pair_pos_format_one_counts_glyphs_not_ranges() {
	f := kern_font('segoeui.ttf') or { return }
	gpos := f.face.gpos or { panic('no GPOS') }
	mut sets := 0
	mut ranges := 0
	for li in gpos.lookups_for('latn', 'kern') {
		if int(li) >= gpos.lookups.len {
			continue
		}
		for rule in gpos.lookups[li].pairs {
			if rule.is_format2 {
				continue
			}
			sets = rule.pair_sets.len
			ranges = rule.first_ranges.len
		}
	}
	assert sets == 87, 'one set per covered first glyph'
	assert ranges == 59, 'and the coverage writes them as fewer ranges than that'
	assert sets > ranges, 'which is the whole of the difference the count has to respect'
}
