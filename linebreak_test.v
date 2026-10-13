module vtext

import os

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

// starts_of is the break positions of a text as a sorted list, which is what every assertion below
// is asked about.
fn starts_of(ctx &Context, cps []rune) []int {
	mut out := []int{}
	for o in break_opportunities(ctx, cps, true) {
		out << o.start
	}
	return out
}

// The quotation-role table is what makes the two rules below possible, so it is checked against the
// three characters the committee's own test file uses to spell the whole distinction out: U+00AB is
// opening, U+00BB is closing, and U+0022 is both.
fn test_quote_roles_are_read_from_the_ucd() {
	q := quote_ranges()
	assert quote_role_of(q, rune(0x00AB)) == .pi, 'U+00AB opens'
	assert quote_role_of(q, rune(0x00BB)) == .pf, 'U+00BB closes'
	assert quote_role_of(q, rune(0x0022)) == .both, 'U+0022 can be either'
	assert quote_role_of(q, rune(0x201C)) == .pi, 'U+201C is a left double quotation mark'
	assert quote_role_of(q, rune(0x201D)) == .pf, 'U+201D is a right double quotation mark'
	// The apostrophe is Po and not Pi or Pf, so it is both rather than an opening mark, and a
	// character that is not a quotation mark at all is the default.
	assert quote_role_of(q, rune(0x0027)) == .both, 'U+0027 is a quotation mark that is neither'
	assert quote_role_of(q, `A`) == .none, 'a letter is not a quotation mark'
	// The hand-written enum and the generated ordinals must not drift apart, or a regeneration
	// against a newer UCD would silently reassign what every rule below asks for.
	assert QuoteRole.pi.str() == 'pi', 'the ordinal the generated table uses for an opening mark'
	assert QuoteRole.pf.str() == 'pf', 'and for a closing one'
	assert QuoteRole.both.str() == 'both', 'and for one that can be either'
	assert QuoteRole.none.str() == 'qu_none', 'and for the default, which no range ever names'
}

// LB15a: an opening quotation mark holds what follows it, space and marks included.
//
// `× 00AB × 0020 × 2757 ÷` is the test file's own shape, and the answer is [15.11] — no break — on
// the marker between the space and the symbol. The pair with the space on the other side answers
// the other way, which is why this cannot be one rule about a space and a quotation mark.
fn test_an_opening_quotation_mark_holds_a_space_in_front_of_what_follows() {
	ctx := new_context()
	// « SP ×: the space is held, so there is no break before the symbol.
	assert starts_of(ctx, word(0x00AB, 0x20, 0x2757)) == [3], 'LB15a: an opening mark does not let go across a space'
	// The same with a combining mark standing in the space's place, and with both: 69 lines of each
	// shape in the test file answer [15.11] with no exception.
	assert starts_of(ctx, word(0x00AB, 0x0308, 0x2757)) == [3], 'and a mark is part of the run rather than a break in it'
	assert starts_of(ctx, word(0x00AB, 0x20, 0x0308, 0x2757)) == [4], 'the run may hold both a space and a mark'
	// Without the quotation mark in front, the space breaks as it always did.
	assert starts_of(ctx, word(0x0061, 0x20, 0x2757)) == [2, 3], 'the same pair with a letter in front still breaks'
	// A closing mark does not hold, and neither does one that is both: only QU_Pi opens.
	assert starts_of(ctx, word(0x00BB, 0x20, 0x2757)) == [2, 3], 'LB15a is an opening mark, not a quotation mark'
	assert starts_of(ctx, word(0x0022, 0x20, 0x2757)) == [2, 3], 'and a mark that can be either is not an opening one'
}

// LB15b: a closing quotation mark holds what precedes it, space included.
//
// `× 2757 × 0020 × 00BB ÷` is the test file's own shape and the answer is [15.21] — no break — on
// the marker between the space and the mark. LB19 already forbids a break straight into one, so
// this is the space that is being decided rather than the quotation mark.
fn test_a_closing_quotation_mark_holds_a_space_in_front_of_it() {
	ctx := new_context()
	// SP × «: no break, so the closing mark stays on the line with the text before it.
	assert starts_of(ctx, word(0x2757, 0x20, 0x00BB)) == [3], 'LB15b: a space before a closing mark does not break'
	// The other two kinds do break, which is the same `SP × QU` pair answering both ways.
	assert starts_of(ctx, word(0x2757, 0x20, 0x00AB)) == [2, 3], 'an opening mark breaks after a space'
	assert starts_of(ctx, word(0x2757, 0x20, 0x0022)) == [2, 3], 'and a mark that is both breaks after a space too'
	// A run of two spaces is one run, so it is the break after the last one that is decided.
	assert starts_of(ctx, word(0x2757, 0x20, 0x20, 0x00BB)) == [4], 'a run of spaces hangs on the same quotation mark'
}

// A zero width space detaches the run, because it is a break of its own.
//
// The test file asks `× 200B × 0020 ÷ 00BB ÷` and answers [8.0] — break — so the space after a zero
// width space starts a new unit and is not glued to the quotation mark in front of it. Without the
// exception LB15b would eat that break.
fn test_a_zero_width_space_detaches_the_space_from_the_quotation_mark() {
	ctx := new_context()
	assert starts_of(ctx, word(0x200B, 0x20, 0x00BB)) == [2, 3], 'a zero width space is a break of its own and the space after it breaks too'
}

// The four shapes together: an opening and a closing mark around a space are all one thing, which is
// the case a caller laying out quoted speech actually has.
//
// The positions worth reading carefully are the two that are absent. The space after the opening mark
// is held by LB15a, so there is no break between it and the first letter; and the space before the
// closing mark is held by LB15b, so there is none between it and the mark. Every other space breaks
// after itself, which is LB18 and is what the space in the middle does.
fn test_a_quoted_run_with_spaces_inside_it_stays_whole() {
	ctx := new_context()
	// « SP a SP b SP »
	assert starts_of(ctx, word(0x00AB, 0x20, 0x61, 0x20, 0x62, 0x20, 0x00BB)) == [4, 7], 'quoted speech is quoted, not split at its own quotation marks'
}

// Wrapping is the reason break opportunities exist, so these check the whole path: the rules pick
// the positions and the measurement decides which of them is far enough along.

// A font for the wrap tests, resolved corpus-first.
//
// This was `C:\Windows\Fonts\segoeui.ttf` until 2026-10-13, which meant every test below ran only on
// this machine. Amiri is committed with the corpus and carries both halves these tests need: the 58
// Latin codepoints the paragraph tests spell out, and the Arabic `سلام دنیا` the right-to-left test
// uses. Nothing here asserts a width in pixels — every threshold is `plain.width / 2.0` or a
// trivially wide or narrow bracket — so the font being a different one does not move a limit.
//
// The same resolution order the rest of the suite uses, and the same `VTEXT_TEST_FONTS` override. A
// host with neither the corpus nor a platform font directory prints a skip rather than panicking,
// because a file that panics is a file that proves nothing on three quarters of the machines this
// is supposed to run on.
fn wrap_font() &FontSet {
	fs := new_font_set()
	p := corpus_font_path('Amiri-Regular.ttf') or {
		skip_missing('Amiri-Regular.ttf')
		exit(0)
	}
	fs.add(load_font_file(p) or { panic(err) })
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

// A mark does not hold what comes after it, and that is the biggest single thing
// this engine used to get wrong.
//
// The chain refused a break after a combining mark from 2026-10-04 to 2026-10-11,
// which is 870 cases against the committee's file and was generalised from a
// single case about a zero width non-joiner. LB9 forbids a break *before* a mark.
// It says nothing about what follows one.
//
// `× 2757 × 0308 ÷ 1B05 ÷` is the committee's own case, tagged [31.01] at the
// break: a letter, a mark, and then a Balinese letter, and the line may end
// between the mark and the letter.
fn test_line_break_breaks_after_a_mark() {
	ctx := new_context()
	// 2757 AI, 0308 CM, 1B05 AK.
	cps := [rune(0x2757), rune(0x0308), rune(0x1B05)]
	mut starts := []int{}
	for o in break_opportunities(ctx, cps, true) {
		starts << o.start
	}
	assert 2 in starts, 'a line may end between the mark and the letter, got ${starts}'
}

// ...and the side the rule did cover, which is why removing it was safe rather
// than merely profitable. A line may not end *before* a mark, so a mark still
// holds what is in front of it.
fn test_line_break_still_holds_before_a_mark() {
	ctx := new_context()
	// 1B05 AK, 0308 CM.
	cps := [rune(0x1B05), rune(0x0308)]
	mut starts := []int{}
	for o in break_opportunities(ctx, cps, true) {
		starts << o.start
	}
	assert starts == [2], 'the mark still holds what is in front of it, got ${starts}'
}

// LB28 reads through a mark to a pair of letters, and that is what made the
// removal above safe rather than a trade.
//
// `× 2757 × 0308 × 2757 ÷` is annotated [28.0] at the second letter, so the
// committee reads the pair as two letters and not as a mark and a letter. This
// is the 768 cases that removing the blanket rule broke.
fn test_line_break_holds_two_letters_across_a_mark() {
	ctx := new_context()
	// 2757 AI, 0308 CM, 2757 AI.
	cps := [rune(0x2757), rune(0x0308), rune(0x2757)]
	mut starts := []int{}
	for o in break_opportunities(ctx, cps, true) {
		starts << o.start
	}
	assert starts == [3], 'two letters hold across the mark between them, got ${starts}'
}

// ...and the letter after a mark is held by a digit on the other side of the
// mark too, which is LB23's letter-digit pair reading through the same way.
fn test_line_break_holds_a_letter_and_a_digit_across_a_mark() {
	ctx := new_context()
	// 2757 AI, 0308 CM, 0030 NU.
	cps := [rune(0x2757), rune(0x0308), rune(0x0030)]
	mut starts := []int{}
	for o in break_opportunities(ctx, cps, true) {
		starts << o.start
	}
	assert starts == [3], 'a letter and a digit hold across the mark, got ${starts}'
}

// LB30 does not read through a mark, and the difference is the whole shape of
// the change.
//
// `× 2757 × 0308 × 0028 ÷` breaks, where `× 2757 × 0028 ÷` does not. So an open
// punctuation may begin a line after a marked letter but not after a bare one,
// which is the one thing that distinguishes "the mark stands in for its base"
// from "the mark is part of its base".
fn test_line_break_allows_open_punctuation_after_a_mark_but_not_a_letter() {
	ctx := new_context()
	// 2757 AI, 0308 CM, 0028 OP.
	cps := [rune(0x2757), rune(0x0308), rune(0x0028)]
	mut starts := []int{}
	for o in break_opportunities(ctx, cps, true) {
		starts << o.start
	}
	assert 2 in starts, 'open punctuation may follow a mark, got ${starts}'
	// And without the mark, the same pair is held.
	cps2 := [rune(0x2757), rune(0x0028)]
	mut starts2 := []int{}
	for o in break_opportunities(ctx, cps2, true) {
		starts2 << o.start
	}
	assert 1 !in starts2, 'but not after a bare letter, got ${starts2}'
}

// LB28 is four pairs and this engine had one of them.
//
// `× 2757 × 0308 × 05D0 ÷` is annotated [28.0] at the Hebrew letter, so LB28
// reads a Hebrew letter as the same kind of letter as a Latin one. HL was
// missing from both sides of the rule.
fn test_line_break_holds_a_hebrew_letter_like_a_latin_one() {
	ctx := new_context()
	// 2757 AI, 0308 CM, 05D0 HL.
	cps := [rune(0x2757), rune(0x0308), rune(0x05D0)]
	mut starts := []int{}
	for o in break_opportunities(ctx, cps, true) {
		starts << o.start
	}
	assert 2 !in starts, 'a Hebrew letter is held like a Latin one, got ${starts}'
	// And the same two with no mark between them.
	cps2 := [rune(0x2757), rune(0x05D0)]
	mut starts2 := []int{}
	for o in break_opportunities(ctx, cps2, true) {
		starts2 << o.start
	}
	assert 1 !in starts2, 'and directly as well, got ${starts2}'
}

// The SA mark table is what lets LB1 split the complex-context class, so it is checked against the
// marks and U+0E01 is a letter.
fn test_sa_marks_are_read_from_the_general_category() {
	m := sa_mark_ranges()
	assert sa_mark_of(m, rune(0x0E31)) == .mark, 'U+0E31 THAI CHARACTER MAI HAN-AKAT is a mark'
	assert sa_mark_of(m, rune(0x102C)) == .mark, 'U+102C MYANMAR VOWEL SIGN AA is a mark'
	// Lao vowel sign mai kan, an Mn outside Thai, and the Tai Viet sign, the same property further out.
	assert sa_mark_of(m, rune(0x0EB1)) == .mark, 'U+0EB1 LAO VOWEL SIGN MAI KAN is a mark'
	assert sa_mark_of(m, rune(0xAAB0)) == .mark, 'U+AAB0 TAI VIET MAI KANG is a mark'
	// A letter, and two non-mark marks that are still not SA at all.
	assert sa_mark_of(m, rune(0x0E01)) == .none, 'U+0E01 THAI CHARACTER KO KAI is a letter'
	assert sa_mark_of(m, rune(0x0E46)) == .none, 'U+0E46 THAI CHARACTER MAIYAMOK is a letter, not a mark'
	assert sa_mark_of(m, rune(0x0308)) == .none, 'a combining accent is a mark but is not SA'
	assert sa_mark_of(m, `A`) == .none, 'a letter that is not SA at all is the default'
	// The hand-written enum and the generated ordinals must not drift apart, the way the quotation
	// role's do not, or a regeneration against a newer UCD would silently reassign the answers.
	assert SaMark.mark.str() == 'sa_mark', 'the ordinal the generated table uses for a mark'
	assert SaMark.none.str() == 'sa_none', 'and for the default, which no range ever names'
}

// LB4a with an SA mark, which is the shape the split buys: a mark of any class that follows
// something is held to the character in front of it.
// `× FE6A × 0E31 ÷` and `× 1B05 × 102C ÷` are both from the committee's file, and the answer is a
// refusal on the marker between the pair — no break — which is what LB4a says for a Latin accent
// (`× 2757 × 0308 × 2757 ÷`) and now says for a Thai sign too.
fn test_an_sa_mark_after_a_character_is_held_to_it() {
	ctx := new_context()
	assert starts_of(ctx, word(0xFE6A, 0x0E31)) == [2], 'a Thai sign is held to what precedes it'
	assert starts_of(ctx, word(0x1B05, 0x102C)) == [2], 'and a Myanmar vowel sign is too'
	// The letter one of the same class is not, which is the whole point of the split: U+0E01 is SA
	// and resolves to a letter, so an Aksara letter in front of it breaks the way two letters would.
	assert starts_of(ctx, word(0x1B05, 0x0E01)) == [1, 2], 'a Thai letter keeps every break it had'
	// The mark keeps the letter resolution at the start of the text, which is what the committee
	// answers with `[31.01]` and what the unresolved leading mark costs elsewhere.
	assert starts_of(ctx, word(0x0E31, 0x1B05)) == [1, 2], 'a leading SA mark has nothing to attach to'
}

// A numeric prefix or postfix holds its letter across a diacritic, which is what
// LB24 reading through a mark looks like.
//
// `× FE6A × 0308 × 2757 ÷` is the committee's own case, tagged [24.02] on the letter. A postfix
// numeral followed by a mark and a letter is one unit, the way a letter followed by a mark and a
// letter is one unit under LB28. The rule was reading the character in front of it, so a diacritic
// between the numeral and its letter detached them.
//
// Measured 2026-10-12: 36 cases gained and none broken, and the control is the change itself —
// with `left` where `pair_left` now sits, the score returns to exactly the baseline.
fn test_line_break_holds_a_numeral_and_its_letter_across_a_mark() {
	ctx := new_context()
	// FE6A PO, 0308 CM, 2757 AI.
	cps := [rune(0xFE6A), rune(0x0308), rune(0x2757)]
	mut starts := []int{}
	for o in break_opportunities(ctx, cps, true) {
		starts << o.start
	}
	assert starts == [3], 'the numeral holds its letter across the mark, got ${starts}'
	// And the other direction, a prefix numeral, which is the same rule.
	cps2 := [rune(0x0024), rune(0x0308), rune(0x2757)]
	mut starts2 := []int{}
	for o in break_opportunities(ctx, cps2, true) {
		starts2 << o.start
	}
	assert starts2 == [3], 'and a prefix numeral does too, got ${starts2}'
}

// A letter does not part from a prefix numeral either, and that is the other half of the rule
// the class list was standing in for.
//
// `× 2757 × 0024 ÷` is [24.03] and `× 0024 ÷ 0024 ÷` is [31.01], so a numeral holds to a letter
// and two numerals do not hold to each other. The direction matters because `.pr` and `.po` sat in
// `is_prohibited_start_after_space`: a space in front of one is still a break the file asks for,
// `× 0020 ÷ 0024 ÷` is [18.0], which is why they are not in `is_prohibited_start` — moving them
// there measured 16 fixed against 537 newly broken.
fn test_line_break_holds_a_letter_to_a_numeral_but_not_a_space() {
	ctx := new_context()
	// 2757 AI, 0024 PR: no break between them.
	cps := [rune(0x2757), rune(0x0024)]
	mut starts := []int{}
	for o in break_opportunities(ctx, cps, true) {
		starts << o.start
	}
	assert 1 !in starts, 'a letter holds to a prefix numeral, got ${starts}'
	// A space in front of the same numeral is a break.
	cps2 := [rune(0x0020), rune(0x0024)]
	mut starts2 := []int{}
	for o in break_opportunities(ctx, cps2, true) {
		starts2 << o.start
	}
	assert 1 in starts2, 'and a space breaks in front of one, got ${starts2}'
}

// The numeric matrix is nine classes wide, not one, and the list named all forty-odd.
//
// `.pr` and `.po` sat in `is_prohibited_start_after_space`, which refuses a break before them
// wherever one is asked for. The committee's file asks for one in 244 places and refuses one in
// 216, and which of the two it does depends on the left-hand class. `× 3000 ÷ 20A9 ÷` is an
// ideographic space and a won sign, tagged [31.01] — the default break — because a break-after
// character breaks before a prefix numeral just like anything else.
//
// Measured 2026-10-13: removing the two entries is worth 220 on its own, and the 216 they were
// refusing on the engine's behalf are LB24.03, LB25.05, LB25.06, LB23.13 and LB27.01, which is
// the whole of why this reads as a mistake in a class list rather than a missing rule.
// Together the change is 1,338 to **937** failures: 425 fixed, 24 newly broken.
//
// Every shape below is one the file names, and each is checked in both directions so a later edit
// that widens the refusal back out cannot hide behind one passing case.
fn test_line_break_breaks_before_a_prefix_numeral_the_file_asks_to() {
	ctx := new_context()
	// A break-after character, a close bracket and a non-starter all break before both classes.
	// U+3000 BA, U+232A CL, U+3005 NS.
	for cp in [0x3000, 0x232A, 0x3005] {
		assert starts_of(ctx, word(cp, 0x0024)) == [1, 2], 'a break before a prefix numeral, cp ${cp:04x}'
		assert starts_of(ctx, word(cp, 0x20A9)) == [1, 2], 'and before a won sign, cp ${cp:04x}'
		assert starts_of(ctx, word(cp, 0x0025)) == [1, 2], 'and before a number sign, cp ${cp:04x}'
	}
	// Two prefixes in a row, which the file answers [31.01]: the first is not held by the second.
	assert starts_of(ctx, word(0x20A9, 0x0024)) == [1, 2], 'and a prefix numeral parts from another one'
}

// ...and the classes the leftover list still holds too tightly, which are the same shape of
// mistake one line up and are recorded rather than fixed here.
//
// `× 002D ÷ 0024 ÷` is [31.01] — a hyphen and a dollar sign, and the file asks for a break — and
// `× 002D × 0308 × 2757 ÷` is [20.1], another one. Both are refused by `.hy` sitting in
// `is_prohibited_end`, which refuses a break after *every* hyphen where the file answers it nine
// ways. Removing it is the same question as the one above and is not done in the same change:
// LB21 is what makes "well-known" break after its hyphen, and `is_prohibited_end` also carries
// `.cp`, `.ex` and `.insp`, which the mark-reading experiment showed have the same shape of hole.
fn test_line_break_records_the_hyphen_and_close_punctuation_over_refusal() {
	ctx := new_context()
	// The engine refuses; the file asks for a break at both of these.
	assert starts_of(ctx, word(0x002D, 0x0024)) == [2], 'a hyphen is still held by is_prohibited_end'
	assert starts_of(ctx, word(0x002D, 0x0308, 0x2757)) == [2, 3], 'and it also refuses the break after the mark the file asks for'
}

// ...and the other half of the matrix, which the list was getting right by accident.
//
// `× 2757 × 20A9 ÷` is [24.03] and `× 0030 ÷ 20A9 ÷` is [25.06]: a letter, a Hebrew letter or a
// digit refuses a break before either class, so the pair is three classes on the left rather than
// every one of them. It reads through a mark the way LB24.02 does, and a mark at the head of the
// text is the base in its turn — `pair_left` is `.cm` exactly when the mark run reaches the start,
// and the file tags CM × PR [24.03] as well.
fn test_line_break_holds_a_letter_a_hebrew_letter_or_a_digit_to_a_numeral() {
	ctx := new_context()
	// 2757 AI -> AL, 05D0 HL, 0030 NU, against both a prefix and a postfix.
	for cp in [0x2757, 0x05D0, 0x0030] {
		assert starts_of(ctx, word(cp, 0x20A9)) == [2], 'held to a prefix numeral, cp ${cp:04x}'
		assert starts_of(ctx, word(cp, 0xFE6A)) == [2], 'and to a postfix, cp ${cp:04x}'
	}
	// Through a mark, where the committee writes the same tags for the same pair.
	assert starts_of(ctx, word(0x2757, 0x0308, 0x20A9)) == [3], 'a letter holds across a diacritic'
	assert starts_of(ctx, word(0x05D0, 0x0308, 0xFE6A)) == [3], 'and a Hebrew letter holds to a postfix'
	// A leading mark is its own base, so the refusal still answers.
	assert starts_of(ctx, word(0x0308, 0x20A9)) == [2], 'a mark at the head of the text is the base'
}

// LB23.13 and LB27.01: an emoji, an ideograph or a Hangul syllable holds to a *postfix* numeral
// and not to a prefix one, and the asymmetry is the file's rather than a reading of it.
//
// `× 263A × 20A9 ÷` is tagged [23.13] and `× 263A ÷ 20A9 ÷` is tagged [31.01], the default break,
// so `EB × PO` and `EB × PR` are two different answers from one pair of classes. A single rule for
// both would have to be positioned by the right-hand character rather than by the rule, which is
// why these are two rules and not one list. Both read through a mark: `× 270A × 0308 × FE6A ÷` is
// tagged [23.13] and `× AC00 × 0308 × FE6A ÷` is tagged [27.01].
fn test_line_break_holds_an_emoji_an_ideograph_or_a_syllable_to_a_postfix_only() {
	ctx := new_context()
	// U+270A EB, U+231A ID, U+AC00 H2: held to a postfix.
	for cp in [0x270A, 0x231A, 0xAC00] {
		assert starts_of(ctx, word(cp, 0xFE6A)) == [2], 'held to a postfix numeral, cp ${cp:04x}'
	}
	// U+1100 JL and U+11A8 JT are jamo, and the same rule answers for them.
	assert starts_of(ctx, word(0x1100, 0xFE6A)) == [2], 'a leading jamo is held to a postfix too'
	// ...and every one of them parts from a prefix numeral, which is the other half of the pair.
	for cp in [0x270A, 0x231A, 0xAC00, 0x1100] {
		assert starts_of(ctx, word(cp, 0x20A9)) == [1, 2], 'but parts from a prefix, cp ${cp:04x}'
	}
	// Through a mark, where the raw left-hand class is the combining mark and the base is the emoji.
	assert starts_of(ctx, word(0x270A, 0x0308, 0xFE6A)) == [3], 'an emoji holds across a diacritic'
	assert starts_of(ctx, word(0xAC00, 0x0308, 0xFE6A)) == [3], 'and a syllable does too'
	assert starts_of(ctx, word(0x270A, 0x0308, 0x20A9)) == [2, 3], 'and still parts from a prefix'
}

// A word joiner with a mark on it still holds, and so does an open punctuation or a quotation mark.
//
// This is the half of the mark reading that survives the rest of it. Measured over every
// `base × CM × right` position in ucd/LineBreakTest.txt against the bare `base × right` pair, the
// two agree in 1,684 positions and disagree in 130; the bases that agree *and* refuse a break after
// every character are BB, GL, WJ, OP and QU. Reading the whole `is_prohibited_end` list through the
// mark instead fixed 20 cases and broke 94, because `.cp`, `.ex`, `.hy` and `.insp` refuse only some
// of them and the propagation carried that over-refusal into the mark side.
//
// It sits below LB20 rather than beside `is_prohibited_end`, and one case puts it there:
// `× 00B4 × 0308 ÷ FFFC ÷` is tagged [20.01], so an object replacement character still breaks
// through a mark hanging on an acute accent.
fn test_line_break_holds_a_mark_to_an_open_punctuation_or_a_word_joiner() {
	ctx := new_context()
	// U+0028 OP, U+FEFF WJ, U+00AB QU, U+00B4 BB, each with a mark and a postfix after it.
	assert starts_of(ctx, word(0x0028, 0x0308, 0xFE6A)) == [3], 'an open punctuation holds across a mark'
	assert starts_of(ctx, word(0xFEFF, 0x0308, 0xFE6A)) == [3], 'a word joiner holds across a mark'
	assert starts_of(ctx, word(0x00AB, 0x0308, 0xFE6A)) == [3], 'a quotation mark holds across a mark'
	assert starts_of(ctx, word(0x00B4, 0x0308, 0xFE6A)) == [3], 'and a break-before accent does too'
	// The contingency break character still wins, which is what fixes this rule's position.
	assert starts_of(ctx, word(0x00B4, 0x0308, 0xFFFC)) == [2, 3], 'but an object replacement character still breaks'
	// A class the mark does NOT answer for, so the refusal stays where it belongs: a comma in front
	// of a mark breaks the way the bare pair does.
	assert starts_of(ctx, word(0x002C, 0x0308, 0x2757)) == [2, 3], 'a comma does not inherit the mark'
}

// The six classes where the mark contradicts the pair it stands on, which is the file disagreeing
// with itself rather than a gap in the engine.
//
// `× 0020 ÷ 0308 × FE6A ÷` is a space, a mark and a postfix numeral, and the file refuses the second
// break — where the bare `× 0020 × FE6A ÷` is [18.0] and asks for one. The same holds for a zero
// width space and for the four hard breaks, which is 24 of the 24 cases this change still fails.
// UAX #14 has no rule for a mark standing on a space or a newline, and the file has both answers,
// so these are recorded rather than coded around: a rule refusing them would have to be keyed on
// six classes that break after every other one.
fn test_line_break_a_mark_on_a_space_or_a_hard_break_is_unresolved() {
	ctx := new_context()
	// The engine grants the break the file refuses, and these are the shapes. The file answers
	// `[1, 3]` at each of them; the engine answers `[1, 2, 3]`, so the disagreement is the one
	// position between the mark and the numeral.
	for cp in [0x0020, 0x200B, 0x000A, 0x000B, 0x000D, 0x0085] {
		assert starts_of(ctx, word(cp, 0x0308, 0xFE6A)) == [1, 2, 3], 'a mark on a space or a hard break is unresolved, cp ${cp:04x}'
	}
}

// ---------------------------------------------------------------- corpus fonts

// The same resolution every other test file in this module carries, because  test <file> compiles
// one file and not its siblings: a helper in a neighbour satisfies  test . and fails every
// single-file run tools/run_tests.v makes.

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

// skip_missing prints why a test cannot run. A skip that prints nothing is a failure pretending to be a
// pass, so every one of them names the font it wanted and where it looked, and tools/run_tests.v counts
// them file by file.
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
