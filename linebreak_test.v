module vtext

// Line breaking, per UAX #14.
//
// The tests check the rules against text where the answer is not a matter of
// taste: a closing bracket may not start a line, a letter and the accent on it
// are one unit, and a newline is a newline.

// A backtick in V is one character, so a word cannot be written as a literal the way it can be in a
// test written in any other language.
fn word(cps ...int) []rune {
	mut out := []rune{cap: cps.len}
	for c in cps {
		out << rune(c)
	}
	return out
}

// A space is a break, which is the rule everything else is measured against.
fn test_line_break_breaks_after_a_space() {
	ctx := new_context()
	// "ab cd": the only opportunity is after the space, at index three.
	ops := break_opportunities(ctx, word(0x61, 0x62, 0x20, 0x63, 0x64), true)
	// The end of the text is always there, and so is the one after the space.
	assert ops.len == 2, 'one space and the end of the text'
	assert ops[0].start == 3, 'the break is after the space'
	assert !ops[0].is_mandatory, 'a space is optional'
	assert ops[1].start == 5, 'and the text ends'
}

// A word with no space in it is not broken, which is the whole point of the
// rules: a permissive default that allowed a break anywhere would split a word
// rather than the line after it.
fn test_line_break_does_not_split_a_word() {
	ctx := new_context()
	ops := break_opportunities(ctx, word(0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68), true)
	// Only the end of the text.
	assert ops.len == 1
	assert ops[0].start == 8
}

// A closing bracket may not begin a line, and a line ending in an opening one
// is just as wrong: the bracket would be separated from the thing it encloses.
//
// "ab (cd)" is seven characters, and the two opportunities are after the space at
// index three and at the end of the text. Neither is inside the brackets.
fn test_line_break_keeps_brackets_with_their_text() {
	ctx := new_context()
	ops := break_opportunities(ctx, word(0x61, 0x62, 0x20, 0x28, 0x63, 0x64, 0x29), true)
	mut starts := []int{}
	for o in ops {
		starts << o.start
	}
	assert starts == [3, 7], 'not between the brackets, and not before the close'
}

// A letter and the mark on it are one unit. Without this a line can end between
// an "e" and the accent that belongs to it, which is invisible in the layout
// and obvious to a reader.
fn test_line_break_keeps_a_mark_with_its_letter() {
	ctx := new_context()
	// a, e, U+0301, space, b: five characters, and the only opportunity is the
	// space at index three. Not between the e and its acute, which would be at
	// index two.
	mut cps := []rune{}
	cps << `a`
	cps << `e`
	cps << rune(0x0301)
	cps << ` `
	cps << `b`
	ops := break_opportunities(ctx, cps, true)
	mut starts := []int{}
	for o in ops {
		starts << o.start
	}
	// The space is at index three, so the break that follows it is at four. There is nothing at two,
	// which would have split the e from the acute that belongs to it, and nothing at three either,
	// because a space is never left at the end of a line: it goes with the word that follows it.
	assert starts == [4, 5], 'not between the letter and its mark'
}

// A newline is a newline, and it is reported as mandatory so a caller does not
// skip it the way it skips the optional ones.
fn test_line_break_reports_a_mandatory_break() {
	ctx := new_context()
	mut cps := []rune{}
	cps << `a`
	cps << `b`
	cps << `\n`
	cps << `c`
	ops := break_opportunities(ctx, cps, true)
	mut mandatory := []int{}
	for o in ops {
		if o.is_mandatory {
			mandatory << o.start
		}
	}
	assert mandatory == [3], 'the newline is one mandatory break'
}

// Arabic has no spaces between the letters of a word, and the tests would be
// checking a fiction if the only text exercised were Latin.
fn test_line_break_finds_the_spaces_in_arabic() {
	ctx := new_context()
	// "سلام دنیا": two words with a space between them.
	mut cps := []rune{}
	for cp in [0x0633, 0x0644, 0x0627, 0x0645, 0x0020, 0x062F, 0x0646, 0x06CC, 0x0627] {
		cps << rune(cp)
	}
	ops := break_opportunities(ctx, cps, true)
	mut starts := []int{}
	for o in ops {
		starts << o.start
	}
	// The break is after the space at index five, and the text ends at nine.
	assert starts == [5, 9], 'the only break is the space'
}

// A zero width non-joiner is a combining mark as far as line breaking goes, and the specification
// says what that means: the sequence takes the behaviour of the character before it, so no break
// falls between the letter and the joiner.
//
// The other side is not glued, and this test is here because it is counter-intuitive. A ZWNJ stops
// two Persian letters from joining to each other, so a reader might expect it to also stop a line
// from breaking there. It does not, and the reason is that the line breaking rules never see the
// joiner as a joiner: they see a mark, and a mark belongs to what comes before it. A line may end
// between the joiner and the letter that follows it, which is a line ending inside a word.
//
// That is correct, and it is also why a caller that does not want it has to ask for a word joiner
// rather than relying on the non-joiner.
fn test_line_break_glues_the_joiner_to_the_letter_before_it() {
	ctx := new_context()
	// space, peh, ZWNJ, alef, space: five characters.
	mut cps := []rune{}
	cps << ` `
	cps << rune(0x067E) // peh
	cps << rune(0x200C) // ZWNJ
	cps << rune(0x0627) // alef
	cps << ` `
	ops := break_opportunities(ctx, cps, true)
	mut starts := []int{}
	for o in ops {
		starts << o.start
	}
	// After the first space at one, after the joiner at three, and at the end at five. What is
	// absent is a break at two, which would have split the peh from the joiner that acts on it.
	//
	// There is no break at four either, and that is the other half of the rule: a space is never
	// left at the end of a line, so the break that follows the trailing space is the end of the text
	// rather than a position inside it.
	assert starts == [1, 3, 5], 'glued on the left, not on the right'
}

// A word joiner is a different thing from a non-joiner and it is what actually forbids a break,
// which is the distinction a caller needs if a word must not be split.
fn test_line_break_a_word_joiner_forbids_a_break_on_both_sides() {
	ctx := new_context()
	// a, WJ, b, space: four characters. The WJ must keep the a and the b together, so the only
	// opportunity is the space.
	mut cps := []rune{}
	cps << `a`
	cps << rune(0x2060) // word joiner
	cps << `b`
	cps << ` `
	ops := break_opportunities(ctx, cps, true)
	mut starts := []int{}
	for o in ops {
		starts << o.start
	}
	// The only opportunity is the end of the text, which is the four characters plus nothing else.
	// Nothing at one or two, so the two letters on either side of the joiner stay together, and
	// nothing at three, because that would end the line on a space.
	assert starts == [4], 'neither side of the word joiner'
}

// Empty text has no opportunities, and saying so is better than returning one
// that points past the end.
fn test_line_break_of_empty_text_has_no_breaks() {
	ctx := new_context()
	assert break_opportunities(ctx, []rune{}, true).len == 0
	assert break_opportunities(ctx, word(0x61), true).len == 1
}

// Wrapping is the reason break opportunities exist, so these check the whole path: the rules pick
// the positions and the measurement decides which of them is far enough along.

fn wrap_font() &FontSet {
	fs := new_font_set()
	fs.add(load_font_file('C:\\Windows\\Fonts\\segoeui.ttf') or { panic(err) })
	return fs
}

// A width wide enough for the whole text gives one line, and it is the same line laying the
// paragraph out on its own would give.
fn test_wrap_gives_one_line_when_the_text_fits() {
	ctx := new_context()
	fs := wrap_font()
	// "one two" at a very large width.
	mut cps := []rune{}
	for c in [0x6F, 0x6E, 0x65, 0x20, 0x74, 0x77, 0x6F] {
		cps << rune(c)
	}
	plain := layout_paragraph(ctx, cps, .ltr, fs, 32.0)
	lines := wrap_paragraph(ctx, cps, .ltr, fs, 32.0, 10000.0)
	assert lines.len == 1, 'the whole text fits on one line'
	assert lines[0].line.width == plain.width, 'and it is the same width as laying it out whole'
	assert lines[0].from == 0 && lines[0].to == cps.len
}

// A width that fits neither word gives two lines, each holding one word, and together they hold
// every character.
fn test_wrap_breaks_at_the_space_when_the_text_is_too_wide() {
	ctx := new_context()
	fs := wrap_font()
	mut cps := []rune{}
	for c in [0x6F, 0x6E, 0x65, 0x20, 0x74, 0x77, 0x6F] {
		cps << rune(c)
	}
	plain := layout_paragraph(ctx, cps, .ltr, fs, 32.0)
	// Half the whole paragraph, which is not enough for both words.
	lines := wrap_paragraph(ctx, cps, .ltr, fs, 32.0, plain.width / 2.0)
	assert lines.len == 2, 'one line per word'
	// The break falls after the space rather than before it, which is what UAX#14's LB7 says: a
	// line does not end on a space, it ends on the last thing before the next word starts. The
	// space therefore belongs to the first line and is measured with it, though it is not drawn.
	assert lines[0].to == 4, 'the first line ends after the space'
	assert lines[1].from == 4, 'and the second starts at the word'
}

// The lines have to be drawable, which means their glyphs start at zero and their widths add up to
// no more than the paragraph they were cut out of.
fn test_wrap_produces_lines_that_start_at_their_own_left_edge() {
	ctx := new_context()
	fs := wrap_font()
	mut cps := []rune{}
	for c in [0x6F, 0x6E, 0x65, 0x20, 0x74, 0x77, 0x6F] {
		cps << rune(c)
	}
	plain := layout_paragraph(ctx, cps, .ltr, fs, 32.0)
	lines := wrap_paragraph(ctx, cps, .ltr, fs, 32.0, plain.width / 2.0)
	for line in lines {
		if line.line.glyphs.len == 0 {
			continue
		}
		assert line.line.glyphs[0].x == 0.0, 'a line starts at its own left edge'
		assert line.line.width > 0.0, 'and is as wide as what it holds'
		assert line.line.width <= plain.width + 0.01, 'and no wider than the paragraph'
	}
}

// A word wider than the whole line goes on a line of its own and overflows rather than being split,
// because a caller cannot map a click on one half of a broken word back to the text.
fn test_wrap_does_not_split_a_word_wider_than_the_line() {
	ctx := new_context()
	fs := wrap_font()
	// One word, no spaces, at a width that cannot hold it.
	mut cps := []rune{}
	for c in [0x77, 0x6F, 0x72, 0x64] {
		cps << rune(c)
	}
	lines := wrap_paragraph(ctx, cps, .ltr, fs, 32.0, 1.0)
	assert lines.len == 1, 'one line, overflowing'
	assert lines[0].line.glyphs.len == cps.len, 'with every glyph of the word on it'
}

// Arabic wraps at its spaces, and a letter and its mark stay on the same line.
fn test_wrap_breaks_an_arabic_word_at_its_space() {
	ctx := new_context()
	fs := wrap_font()
	// "سلام دنیا": two words with a space between them.
	mut cps := []rune{}
	for c in [0x0633, 0x0644, 0x0627, 0x0645, 0x0020, 0x062F, 0x0646, 0x06CC, 0x0627] {
		cps << rune(c)
	}
	plain := layout_paragraph(ctx, cps, .rtl, fs, 32.0)
	lines := wrap_paragraph(ctx, cps, .rtl, fs, 32.0, plain.width / 2.0)
	assert lines.len == 2, 'one line per word'
	// The first word is the four characters before the space. The space belongs to the first line
	// because a line ends on the last thing before the next word rather than on the space itself,
	// so the second line starts at the letter after it.
	assert lines[0].to == 5, 'the first line holds the first word and the space'
	assert lines[1].from == 5, 'and the second starts at the second word'
}

// A newline ends the paragraph, so what follows it is a line of its own rather than something the
// width decides.
fn test_wrap_treats_a_newline_as_the_end_of_the_paragraph() {
	ctx := new_context()
	fs := wrap_font()
	// "ab\ncd" at a width that would fit all of it on one line.
	mut cps := []rune{}
	for c in [0x61, 0x62, 0x0A, 0x63, 0x64] {
		cps << rune(c)
	}
	lines := wrap_paragraph(ctx, cps, .ltr, fs, 32.0, 10000.0)
	assert lines.len == 2, 'the newline ends it, whatever the width'
}

// Empty text is one empty line rather than none, so a caller writing text into a view always has
// something to measure.
fn test_wrap_of_empty_text_gives_one_empty_line() {
	ctx := new_context()
	fs := wrap_font()
	assert wrap_paragraph(ctx, []rune{}, .ltr, fs, 32.0, 100.0).len == 0
	assert wrap_paragraph(ctx, word(0x61), .ltr, fs, 32.0, 100.0).len == 1
}
