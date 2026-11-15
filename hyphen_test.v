module vtext

import os
import vtext.layout

// Hyphenation points inside a word, by Liang's algorithm (unwired).
//
// These tests pin the hyphenator against the generated US-English subset in
// ucd/ucd_hyphen.v. The expected breaks below were measured from the
// algorithm over that table on 2026-11-15, then checked against US
// dictionary hyphenations: hyphenation is hy-phen-ation, example is
// ex-am-ple, algorithm is al-go-rithm, university is uni-ver-sity,
// presentation is pre-sen-ta-tion, typesetting is type-set-ting. "Measured,
// don't invent" means exactly this: the pins record what the code gives for
// this table, and the comments record why that is also what the dictionary
// wants.
//
// The hyphenator is deliberately NOT wired into wrap_paragraph here (that
// BreakPolicy integration is a later step): these tests call
// layout.hyphenate directly with layout.hyphen_patterns().

// ---------------------------------------------------------------- font helper
//
// This copy of the helpers lives here because `v test <single_file>`
// compiles that file and not its siblings, so a helper in another test file
// is one this file cannot see. The hyphenator itself needs no font; the
// helper exists so a single-file run resolves the same way every other test
// file's does, and the last test below pins that it does.

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

fn corpus_font_bytes(name string) ?[]u8 {
	p := corpus_font_path(name) or { return none }
	return os.read_bytes(p) or { panic('${p} is not readable: ${err}') }
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

// hyph hyphenates an ASCII word with the generated US-English table.
fn hyph(word string) []int {
	return layout.hyphenate(word.runes(), layout.hyphen_patterns())
}

// The canonical Liang example: hy-phen-ation.
fn test_hyphen_hyphenation_breaks_after_hy_and_phen() {
	assert hyph('hyphenation') == [2, 6], 'hy-phen-ation'
}

// ex-am-ple: both breaks clear the right edge (3 left on "ple").
fn test_hyphen_example_breaks_after_ex_and_am() {
	assert hyph('example') == [2, 4], 'ex-am-ple'
}

// com-put-er, except the table's vote for the -er break is hidden by the
// right edge: "er" is 2 characters and hyphen_right_min is 3, so only the
// com- break at 3 survives. put3er still votes odd at 6 underneath (the
// overlay keeps the maximum, so the vote is there), which is why this pins
// [3] rather than []: the edge rule, not a missing row, hides -er.
fn test_hyphen_computer_keeps_com_and_hides_er() {
	assert hyph('computer') == [3], 'com-puter, with -er hidden by the right edge'
}

// al-go-rithm: the even rows ri4thm/rith4m hold -rithm together.
fn test_hyphen_algorithm_breaks_after_al_and_go() {
	assert hyph('algorithm') == [2, 4], 'al-go-rithm'
}

// uni-ver-sity: the last break leaves "sity" (4), clear of the right edge.
fn test_hyphen_university_breaks_after_uni_and_ver() {
	assert hyph('university') == [3, 6], 'uni-ver-sity'
}

// pre-sen-ta-tion: three breaks, all clear of both edges.
fn test_hyphen_presentation_breaks_three_times() {
	assert hyph('presentation') == [3, 6, 8], 'pre-sen-ta-tion'
}

// type-set-ting.
fn test_hyphen_typesetting_breaks_after_type_and_set() {
	assert hyph('typesetting') == [4, 7], 'type-set-ting'
}

// A short word is one unbreakable unit: "hyphen" still breaks once.
fn test_hyphen_hyphen_breaks_once() {
	assert hyph('hyphen') == [2], 'hy-phen'
}

// Words shorter than left+right minima have no gap satisfying both edges.
fn test_hyphen_short_words_have_no_breaks() {
	assert hyph('word') == [], 'four letters cannot clear 2+3'
	assert hyph('at') == [], 'nor can two'
	assert hyph('a') == [], 'nor one'
	assert layout.hyphenate([]rune{}, layout.hyphen_patterns()) == [], 'nor none'
}

// Matching folds ASCII case, so a capitalised word breaks like its lowercase.
fn test_hyphen_is_case_insensitive() {
	assert layout.hyphenate('Hyphenation'.runes(), layout.hyphen_patterns()) == [2, 6]
	assert layout.hyphenate('COMPUTER'.runes(), layout.hyphen_patterns()) == [3]
}

// The table is injected, not hardcoded: a one-row custom table hyphenates a
// word the US table never breaks, and an even level in the same place does
// not. "abcde" is 5 letters, so only gap 2 clears both edges (2 left, 3
// right): b3c votes odd there and breaks, b2c votes even and holds.
fn test_hyphen_uses_the_injected_table_not_a_hardcoded_one() {
	assert layout.hyphenate('abcde'.runes(), ['b3c']) == [2], 'an odd level breaks'
	assert layout.hyphenate('abcde'.runes(), ['b2c']) == [], 'an even level holds'
	assert layout.hyphenate('abcde'.runes(), ['b3c', 'b2c']) == [2], 'the higher level wins ties by maximum'
}

// Break-fix control 1: with no patterns nothing breaks. If hyphenate ever
// broke a word with an empty table, the pins above would be meaningless;
// this is the test that would catch it.
fn test_hyphen_control_empty_patterns_give_no_breaks() {
	assert layout.hyphenate('hyphenation'.runes(), []string{}) == [], 'no patterns, no breaks'
	assert layout.hyphenate('presentation'.runes(), []string{}) == [], 'on any word'
}

// Break-fix control 2: dropping the hen3a row loses hyphenation's second
// break and only that break. If the [2, 6] pin above passed without the
// table driving it (a hardcoded answer, a test that cannot fail), removing
// the row that votes for 6 would change nothing; it changes [2, 6] to [2].
fn test_hyphen_control_dropping_hen3a_loses_the_second_break() {
	mut kept := []string{}
	for p in layout.hyphen_patterns() {
		if p != 'hen3a' {
			kept << p
		}
	}
	assert kept.len == layout.hyphen_patterns().len - 1, 'exactly one row dropped'
	assert layout.hyphenate('hyphenation'.runes(), kept) == [2], 'the n-a break goes with its row'
	assert layout.hyphenate('hyphen'.runes(), kept) == [2], 'and the hy-p break does not'
}

// The font helper resolves the way every sibling test file's does, so a
// single-file run of this file behaves like the rest of the suite.
fn test_hyphen_corpus_helper_resolves_or_skips() {
	p := corpus_font_path('Amiri-Regular.ttf') or {
		skip_missing('Amiri-Regular.ttf')
		return
	}
	assert os.exists(p), 'the corpus font the helper found is really there'
}
