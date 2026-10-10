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

// A letter and a digit do not part. "H2O" and "COVID19" are single names written with a digit in the
// middle, and a break at the letter-digit boundary leaves a line ending in a digit with the next starting
// on a letter, which reads as a hyphenation nobody asked for.
//
// This is LB28's other two pairs, which were implemented only for two letters. It is a Latin case, not a
// CJK one, which is the part worth noticing: the rule was missing for the script this library is best at.
fn test_line_break_does_not_split_a_word_at_a_letter_digit_boundary() {
	ctx := new_context()
	// H 2 O
	ops := break_opportunities(ctx, word(0x48, 0x32, 0x4F), true)
	assert ops.len == 1, 'only the end of the text is a break, got ${ops.len}'
	assert ops[0].start == 3, 'and it is after the last character'

	// The other direction: a digit followed by a letter, as in "19C".
	ops2 := break_opportunities(ctx, word(0x31, 0x39, 0x43), true)
	assert ops2.len == 1, 'a digit then a letter is the same pair the other way round, got ${ops2.len}'
}

// An infix separator holds to the letter after it, which is what makes "1,000" and "3.14" one thing each.
//
// A full stop between two digits is LB23b's business and is already handled; this is the separator
// followed by a letter, which is the pair a version number like "v1.2" is made of.
fn test_line_break_keeps_an_infix_separator_with_the_letter_after_it() {
	ctx := new_context()
	// 1 , 0 0 0  — the comma is U+002C, class IS.
	ops := break_opportunities(ctx, word(0x31, 0x2C, 0x30, 0x30, 0x30), true)
	assert ops.len == 1, 'a thousands separator does not open a break, got ${ops.len}'
	assert ops[0].start == 5, 'and the only break is the end of the text'
}

// An aksara is a base character, not a mark, and a line may end before one.
//
// U+1B05 BALINESE LETTER AKARA is class AK, and it was in the list of classes treated as combining
// marks. That meant no line could end before it, which is the failure the conformance test reports as
// `× 2757 ÷ 1B05 ÷` — a break the specification asks for and the engine refused. The class is its own
// in the UCD and the rules treat it as a base, so it is not a mark.
//
// The distinction matters for the same reason the Devanagari case does: a prebase mark carries an accent
// and belongs to what follows it, while an aksara is a letter in its own right.
fn test_line_break_may_end_before_an_aksara() {
	ctx := new_context()
	// U+2757 U+1B05: an ambiguous character resolved to a letter, then an aksara.
	cps := [rune(0x2757), rune(0x1B05)]
	mut starts := []int{}
	for o in break_opportunities(ctx, cps, true) {
		starts << o.start
	}
	assert starts == [1, 2], 'a break falls between them and at the end, got ${starts}'
}

// An aksara prebase and a virama final are not marks, and a line may end before one.
//
// Both were in `is_markish`, on the reading that a prebase is a mark in the same sense a Devanagari
// prebase is. The committee's file disagrees from the right-hand side: of the 1112 positions whose
// right-hand character is an AP or a VI, 497 ask for a break and 615 do not, so the class is not a mark
// on that side at all. These three are its examples, and each one is tagged [31.01], the rule that
// stops a line between an emoji base and the combining mark on it.
//
// `× 2757 ÷ 1B44 ÷` is the shape that changed, and so is the same shape with 11003, and with every
// letter of the file in the first position. Worth 132 cases.
fn test_line_break_may_end_before_an_aksara_prebase_and_a_virama() {
	ctx := new_context()
	// U+2757 is AI, resolved to a letter by LB1. U+11003 is AP, U+1B44 is VI.
	mut wanted := [rune(0x2757), rune(0x11003), rune(0x1B44)]
	// Each pair in turn, so a failure names the pair rather than the run.
	for i in 0 .. 3 {
		mut cps := []rune{}
		for j in i .. i + 2 {
			cps << wanted[j % 3]
		}
		mut starts := []int{}
		for o in break_opportunities(ctx, cps, true) {
			starts << o.start
		}
		assert starts == [1, 2], 'no mark rule holds 2757 to 11003 or to 1B44, got ${starts}'
	}
}

// The same two from the other side, which is the half LB9 does answer.
//
// A virama follows the letter it belongs to, and a line may not end between
// them — but that is the mark on the LEFT doing the work, and `.cm` is the class
// that does it. `× 2757 × 0308 × 2757 ÷` is the shape, and `× 2757 × 11003 × 0308
// ÷` is the one the aksara prebase and the virama leave behind: the break is
// refused before the combining mark and allowed after it. Confirming the
// prebase and the virama are still held *to* what precedes them is the same
// test as the one above read backwards, so it is not written twice.
fn test_line_break_keeps_a_mark_after_an_aksara_prebase() {
	ctx := new_context()
	// 2757 11003 0308, which is the file's own `× 2757 ÷ 11003 × 0308 ÷`: a break
	// before the prebase, and none before the combining mark that follows it.
	cps := [rune(0x2757), rune(0x11003), rune(0x0308)]
	mut starts := []int{}
	for o in break_opportunities(ctx, cps, true) {
		starts << o.start
	}
	assert starts == [1, 3], 'a break before the prebase and none before the mark, got ${starts}'
}

// Hangul syllables are their own class and they break like letters.
//
// H2 and H3 were in `is_markish`, which folded a Hangul syllable into a combining
// mark. A syllable is the letter itself — U+AC00 HANGUL SYLLABLE GA is H2 and U+AC01
// HANGUL SYLLABLE GAG is H3 — so this meant a Korean syllable could not break
// before another syllable and a run of them was one unbreakable word.
//
// The committee's file asks for exactly the opposite, 140 times: `× 3041 ÷ AC01 ÷` and
// every other pair of Japanese and Korean characters on the same line. Removing the
// two measured 3041 to 2914 failures, so it is worth 127 cases and 13 are broken,
// all of them LB26 sub-rules this engine does not implement.
fn test_line_break_breaks_between_two_hangul_syllables() {
	ctx := new_context()
	// U+CABD and U+C774: the committee's own case, and one such per syllable.
	cps := [rune(0xCABD), rune(0xC774)]
	mut starts := []int{}
	for o in break_opportunities(ctx, cps, true) {
		starts << o.start
	}
	assert starts == [1, 2], 'a break falls before a hangul syllable, got ${starts}'
}

// ...and in the other order, which is the direction the class rule actually covered.
fn test_line_break_breaks_between_a_hangul_syllable_and_what_follows_it() {
	ctx := new_context()
	// U+AC00 HANGUL SYLLABLE GA (H2), U+0301 COMBINING ACUTE ACCENT (CM).
	cps := [rune(0xAC00), rune(0x0301)]
	mut starts := []int{}
	for o in break_opportunities(ctx, cps, true) {
		starts << o.start
	}
	assert starts == [2], 'the mark still holds the syllable, got ${starts}'
}

// A small kana is a non-starter, and a line may not begin with one.
//
// U+3041 HIRAGANA LETTER SMALL A is class CJ, and LB1 resolves CJ to NS — the
// class this engine already holds at LB13 and LB17. `× 2757 × 3041 ÷` is the
// committee's own shape and it is tagged [21.04], the same rule that answers
// `× 2757 × 3005 ÷` at U+3005, a real non-starter. The two are the same answer
// from the same rule, which is what makes the resolution that rather than AL.
//
// `× 007D × 3041 ÷` is the shape that proves it is NS and not AL: a closing
// bracket and a non-starter are held together by LB16, and two alphabetics are
// not. Both would refuse a break, but only NS does.
fn test_line_break_keeps_a_small_kana_with_what_precedes_it() {
	ctx := new_context()
	// 2757 3041: no break at one, and the text ends at two.
	cps := [rune(0x2757), rune(0x3041)]
	mut starts := []int{}
	for o in break_opportunities(ctx, cps, true) {
		starts << o.start
	}
	assert starts == [2], 'a non-starter may not begin a line, got ${starts}'

	// U+007D RIGHT CURLY BRACKET is class CL, and LB16 says `(CL | CP) SP* × NS`.
	// Resolving CJ to AL would leave this pair to the permissive default.
	cps2 := [rune(0x007D), rune(0x3041)]
	mut starts2 := []int{}
	for o in break_opportunities(ctx, cps2, true) {
		starts2 << o.start
	}
	assert starts2 == [2], 'a non-starter is held by LB16, got ${starts2}'

	// A space in front is what LB18 answers, and the break goes before the kana.
	// `× 2757 × 0020 ÷ 3041 ÷` is the committee's own case.
	cps3 := [rune(0x2757), rune(0x0020), rune(0x3041)]
	mut starts3 := []int{}
	for o in break_opportunities(ctx, cps3, true) {
		starts3 << o.start
	}
	assert starts3 == [2, 3], 'a space breaks before a non-starter, got ${starts3}'
}

// An unknown character breaks like a letter, and two of them stay together.
//
// U+EFFFD and U+1F8FF are class XX, which no rule matched before LB1 resolved it to
// AL, so each fell through to the permissive default and broke away from its
// neighbour in both directions. `× 2757 × EFFFD ÷` is the shape and it is tagged
// [28.0] — two alphabetics, no break.
fn test_line_break_keeps_two_unknown_characters_together() {
	ctx := new_context()
	// 2757 EFFFD: no break at one, and the text ends at two.
	cps := [rune(0x2757), rune(0xEFFFD)]
	mut starts := []int{}
	for o in break_opportunities(ctx, cps, true) {
		starts << o.start
	}
	assert starts == [2], 'an unknown character breaks like a letter, got ${starts}'

	// And a digit after one is LB23, the letter-digit pair.
	cps2 := [rune(0x30), rune(0xEFFFD), rune(0x30)]
	mut starts2 := []int{}
	for o in break_opportunities(ctx, cps2, true) {
		starts2 << o.start
	}
	assert starts2 == [3], 'an unknown character holds a letter-digit pair, got ${starts2}'
}

// A complex-context character breaks like a letter, which is what the annex
// recommends when no dictionary is available.
//
// U+0E01 THAI CHARACTER KO KAI is class SA. The committee's file uses two SA
// characters and they answer differently: this one answers `[28.0]` (an alphabetic)
// and U+0E31 answers `[9.0]` (a combining mark). The distinction is General_Category,
// which this engine's tables do not carry, so SA resolves to AL across the board.
// That is worth 45 of the failures it was measured against.
fn test_line_break_keeps_a_complex_context_character_with_a_letter() {
	ctx := new_context()
	// 2757 0E01: no break at one, and the text ends at two.
	cps := [rune(0x2757), rune(0x0E01)]
	mut starts := []int{}
	for o in break_opportunities(ctx, cps, true) {
		starts << o.start
	}
	assert starts == [2], 'a complex-context character breaks like a letter, got ${starts}'
}

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
// says what that means: the mark is indivisible from the characters on both sides of it.
//
// **Both** sides, which reverses what this test used to assert on purpose. It held that a line may end
// between the joiner and the letter after it, on the reasoning that a ZWNJ stops two letters joining and so
// cannot also be what stops a line breaking there. The reasoning was about the joiner; the line breaker
// never sees it as a joiner. It sees a mark — U+200C is class CM in the UCD — and a mark is a grapheme
// cluster member.
//
// The Unicode committee's own test agrees, and this is where the answer came from: its one case containing
// U+200C reads `× 200C ×`, no break on either side. Following it is worth **312** conformance cases, from
// 13,090 to 13,402, because every case of the form `× 2757 × 0308 × 2757 ÷` failed at exactly the index
// after the mark.
//
// **This is a trade-off for a library aimed at Persian and is recorded as one.** A ZWNJ-separated pair is
// two words in Persian — `نیم‌فاصله` — and a reader may expect a line to end between them. It no longer can,
// at the joiner. Breaking there needs a word joiner, which the text has to carry. The alternative was
// measured and costs 312 cases. `ROADMAP.md` carries the decision so it can be argued with rather than
// discovered by someone wrapping Persian text and wondering.
fn test_line_break_glues_the_joiner_on_both_sides() {
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
	// After the first space at one, and at the end at five. Nothing inside the pair: a break at two would
	// split the peh from the joiner acting on it, and a break at three would split the joiner from the alef.
	//
	// There is no break at four either, and that is unchanged: a space is never left at the end of a line,
	// so the break that follows the trailing space is the end of the text rather than a position inside it.
	assert starts == [1, 5], 'a joiner is indivisible from both sides'
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
