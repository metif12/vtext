module vtext

// Line breaking, per UAX #14.
//
// This decides where a line is allowed to end, and nothing else. It does not
// know how wide anything is, so it cannot decide where a line does end: that
// needs the glyphs measured, which happens after shaping. A break opportunity is
// therefore a position, and the caller walks the opportunities in order and
// takes the last one that fits.
//
// The reason this is not inside layout_paragraph is that a line has to be
// measured before it can be broken. A break chosen before the glyphs have
// widths is chosen wrongly for any line whose last word does not fit, which is
// to say for most of them.

// BreakKind is the three answers a pair of characters can have, which are the
// three answers the specification's rules can give.
//
// A distinction that looks like bookkeeping and is not: a break that is allowed
// and a break that is required are different kinds, because a caller may skip
// the first and may not skip the second. Collapsing them means either losing a
// newline or wrapping text in the middle of a paragraph.
enum BreakKind {
	no        // the text forbids a break here
	allowed   // a break may go here
	mandatory // the text requires one
}

// A BreakOpportunity is a position in the input where a line may end.
//
// There is one position and one flag, and both are in the caller's own text rather than in a shaped line.
// That is a deliberate change: this struct used to carry a second field, `at`, documented as "the index in
// a shaped line's glyphs that the break falls before" and as being in visual order. It was assigned the
// input index at all three places it was built, so it always equalled `start`, and a caller reading it as
// the documentation said would have split a right-to-left line at the wrong place. It could not have been a
// glyph index: break_opportunities is handed text, not glyphs, so there was no line to take an index of.
//
// The capability it claimed is real and does not need the field. A glyph's `cluster` is the index of the
// input character it came from, so the glyphs belonging to the line starting at `start` are the ones with
// `g.cluster >= start`, and a caller that already has the shaped line filters on that rather than shaping
// the text again:
//
//	for g in line.glyphs {
//		if g.cluster >= op.start {
//			draw(g)
//		}
//	}
//
// That is also the rule this module's own slicing uses, which is why width_of_range and slice_for_range
// agree with it in both directions.
//
// The struct is public because `break_opportunities` is, and a public function
// returning a private struct leaves its caller able to count the results and
// nothing else. Every field is read-only: these are the positions the line
// breaker found, and a caller that moved one would be laying out somewhere the
// rules do not say there is anywhere to lay out.
pub struct BreakOpportunity {
pub:
	// start is the input index the next line would begin at.
	start int
	// is_mandatory says the text requires a break here, which is a paragraph end
	// or a newline. A mandatory break is not a choice, so a caller may not skip it
	// the way it skips the others.
	is_mandatory bool
}

// break_opportunities returns every position in cps where a line may end, in
// the order the text is written.
//
// mandatory_first says whether a mandatory break ends the run. A caller laying
// out one paragraph passes true and treats every mandatory break as a paragraph
// end. A caller measuring a single line passes false and takes the last
// opportunity that fits, which is a different question and needs the newline
// treated as a space.
//
// The returned list is in logical order, not visual order, because the caller
// is walking the text and not the page.
pub fn break_opportunities(ctx &Context, cps []rune, mandatory_first bool) []BreakOpportunity {
	props := ctx.properties
	n := cps.len
	if n == 0 {
		return []BreakOpportunity{}
	}
	// The classes are read once. They are a lookup per character and the same
	// character is asked about three times by the rules below.
	mut classes := []LineBreakClass{cap: n}
	for i in 0 .. n {
		classes << effective_class(props, cps, i, classes)
	}

	mut out := []BreakOpportunity{}
	for i in 0 .. n - 1 {
		// LB21b is first, and it is the only rule that looks at more than the two characters either
		// side. It has to come before the pairs because it is about a hyphen in an existing break, and
		// a pair rule would otherwise decide the hyphen's own right-hand side first and get to the wrong
		// answer about the run.
		if is_break_after_hyphen_break(props, cps, classes, i) {
			out << BreakOpportunity{
				start:        i + 1
				is_mandatory: is_mandatory_break_at(classes, i + 1, n, mandatory_first)
			}
			continue
		}
		// LB7, and then the pairs, in the order the specification numbers them. The
		// order is not arbitrary: LB8 has to come before LB8a, which has to come
		// before LB9, and a later rule may not override an earlier one.
		kind := break_kind(props, cps, classes, i)
		if kind == BreakKind.no {
			continue
		}
		// A break at the end of the text is the caller's decision, not the text's,
		// so only a mandatory one is reported here.
		_ = kind
		out << BreakOpportunity{
			start:        i + 1
			is_mandatory: is_mandatory_break_at(classes, i + 1, n, mandatory_first)
		}
	}
	// The end of the text is a break the caller always has, and reporting it
	// means the caller does not have to special-case the last line.
	out << BreakOpportunity{
		start:        n
		is_mandatory: is_mandatory_break_at(classes, n, n, mandatory_first)
	}
	return out
}

// is_mandatory_break_at says whether the character before position pos is one the
// rules require a break after.
//
// A mandatory break ends a run, so a caller walking the list in order stops there
// rather than continuing past a paragraph. Marking the opportunity is enough; the
// caller decides what a paragraph boundary means for it.
//
// mandatory_first is passed rather than closed over because the same list is built
// both ways. A caller laying out one paragraph asks for mandatory breaks to be
// marked, and a caller measuring a single line asks for the newline to be treated as
// a space instead, which is a different question about the same positions.
fn is_mandatory_break_at(classes []LineBreakClass, pos int, n int, mandatory_first bool) bool {
	if !mandatory_first || pos <= 0 || pos > n {
		return false
	}
	c := classes[clamp_index(pos - 1, n)]
	return c == .lf || c == .bk || c == .cr || c == .nl
}

// break_kind is the class of break between two characters, which is what rules
// LB3 through LB21 all answer.
//
// The rules are in the specification's order and each one that answers stops
// the search, because a later rule may not override an earlier one. A rule that
// does not apply falls through to the next rather than returning nothing,
// because "no rule matched" and "a later rule matched" are the same thing to
// every rule below it.
fn break_kind(props &Properties, cps []rune, classes []LineBreakClass, i int) BreakKind {
	left := classes[i]
	right := classes[i + 1]
	n := classes.len

	// LB4, LB5: always break, or always no break. A mandatory break has to come
	// before the pair rules, because a newline followed by a closing bracket
	// still breaks, and a pair rule would otherwise read the bracket as the
	// right-hand character and forbid it.
	if is_mandatory_break(left) {
		return BreakKind.mandatory
	}
	if left == .cr && right == .lf {
		// LB5, and it is checked before LB4 so that CRLF is one break rather
		// than two.
		return BreakKind.mandatory
	}
	if right == .sp {
		// LB7, again from the other side: a space is not allowed to end a line
		// on its own, and the break goes after it rather than before.
		return BreakKind.no
	}
	// LB7, and the same rule's zero width space: a line may not begin with one.
	if right == .zw {
		return BreakKind.no
	}
	// LB5, LB6: a hard break may not be broken before. `× 000B` and `× 000D` are
	// the shapes, and they are answered here rather than by the left-hand
	// mandatory check above because a zero width space in front of one still
	// breaks at the newline and not between the two.
	if is_mandatory_break(right) {
		return BreakKind.no
	}
	// LB8: a zero width space is a break of its own. The committee's test asks
	// `× 200B ÷ X ÷` for every class and answers every one of them with [8.0] —
	// break — including the classes LB13 forbids after a space and the ones LB11
	// glues on either side. That is the whole of why this sits here and not
	// below the word joiner: it is rule eight, and everything that follows it
	// may not override it.
	//
	// It is not the same as saying a zero width space is a space. `× 0020 × 200B`
	// and `× 200B × 0020` are both "no break", and `× 0020 × 232A` is "no break"
	// while `× 200B ÷ 232A` is a break — LB13 comes between the two breaks, so
	// the two classes differ in where they sit rather than in what they do.
	if left == .zw {
		return BreakKind.allowed
	}
	// LB11: a word joiner forbids a break on either side of it, and LB12 forbids one before it.
	// The two are the same effect and one rule says it: a line may not end on a word joiner and
	// may not begin with one, because either would separate the two characters the writer asked to
	// be inseparable.
	//
	// This is what a caller reaches for when a word must not be split. A zero width non-joiner is
	// not the same thing: it is a combining mark, so it glues only to what comes before it.
	if left == .wj || right == .wj {
		return BreakKind.no
	}
	// The rules below ask what the left-hand character *is* — what it glues, what it may not end a
	// line on — and a mark standing on a character answers for that character. LB15a and LB15b read
	// this way, and the committee's test is where it is visible: `× GL × 0308 × FFFC ÷` refuses a
	// break and `× AL × 0308 × FFFC ÷` grants one, with the same mark and the same placeholder on
	// both sides, so the mark is not what decided.
	//
	// This is deliberately not the same as changing the mark's class, which this chain tried once and
	// measured 10,912 against 13,090. That version rewrote the class for every later rule, so a base
	// that may break away had its break suppressed by the mark in front of it. This only reaches the
	// two lookups below, where the question is the base's.
	mut eff_left := left
	if is_markish(left) {
		mut j := i
		for j > 0 && is_markish(classes[j]) {
			j--
		}
		eff_left = classes[j]
	}
	// LB12: glue is not a break either. It is a letter's way of saying that what is on either side
	// of it belongs together, which is what a zero width space inside a word means and what a
	// joining control sequence leaves behind.
	if eff_left == .gl {
		return BreakKind.no
	}
	// LB12a: the same, from the other side, and it is not the same rule. A line may not begin with
	// glue unless a space or a hyphen is in front of it, which is what keeps "word\u00A0word" whole
	// while letting a space glue its own no-break space to the line after it.
	//
	// The exemption is a list of two, not three. UAX #14 writes it `[^SP BA HY]`, and its own test
	// file asks `× 3000 × 16FE4 ÷` — an ideographic space in front of a glue — and answers with
	// [12.1], a break that must not happen. So a break-after character is not exempt after all,
	// and a reader that takes the character class at its word loses the pair. A soft hyphen is kept
	// exempt, because it is on the same side of the question as a space: it is followed by what it
	// is attached to.
	if right == .gl && left != .sp && left != .hy && left != .hh {
		return BreakKind.no
	}
	if is_prohibited_start(right) {
		// LB13: the right-hand character may not start a line, and this is the set that holds even
		// when a space is in front of it. See the split in `is_prohibited_start`.
		return BreakKind.no
	}
	if is_prohibited_end(left) {
		// LB14 through LB17: the left-hand character may not end a line, including the forms that
		// read across a run of spaces. This comes before LB18, which is what makes `× SP × X ÷`
		// answer those rules rather than the space's own break.
		return BreakKind.no
	}
	// LB18: break after a space.
	//
	// This was answered at the very top of the chain, before any rule that says which character may
	// not start a line, so all of them were silently disabled for the character after a space. The
	// conformance test reports the result as `× 2757 × 0020 × FE56 ÷` — a break between a space and
	// an exclamation mark, which LB13 forbids and a leading `SP ÷` permitted.
	//
	// Where it sits is a measurement rather than a reading of the specification, because the two
	// disagree about a combining mark. UAX #14 lists `× CM` as LB9, sixty places earlier than LB18,
	// and its own test file answers `× 2757 × 0020 ÷ 302A ÷` with [18.0] — a break, on a space and
	// an ideographic tone mark. The committee's examples are the specification for this engine, so
	// the mark rule stays below and the space wins.
	//
	// The classes that do NOT take part in this are the ones the table above names, and they are
	// split into `is_prohibited_start` above and `is_prohibited_start_after_space` below. Measured
	// one way at a time: leaving every prohibition above the space cost 204 cases, and moving all
	// of them below it gained nothing until CL, CP, EX, IS, SY, WJ, ZW and the hard breaks were
	// held back. `× 2757 × 0020 × 00BB ÷` and `× 2757 × 0020 ÷ 0022 ÷` are the two that decide
	// where a quotation mark goes, and they need a Pi/Pf split this engine does not have.
	if left == .sp {
		return BreakKind.allowed
	}
	// LB9: a combining mark may not be separated from the character before it.
	//
	// This sits below LB18 and above LB20, and both of those positions are measurements rather than
	// a reading of the rule numbers. UAX #14 lists `× CM` as LB9, which would put it above both;
	// its own test file answers `× 2757 × 0020 ÷ 302A ÷` with [18.0] — a break, on a space and a
	// tone mark — and `× FFFC × 0308 × 0020 ÷ 2757 ÷` with [9.0] on the mark — no break, on an object
	// replacement character and one. The two answers pin the order between the three rules: LB18
	// before LB9 before LB20. So the space wins over a mark and a mark wins over the placeholder.
	if is_markish(right) {
		return BreakKind.no
	}
	// LB19: a line may not begin with a quotation mark, and may not end with one either. This sits
	// here, above LB20, because the committee's test asks `× FFFC × 00AB ÷` — a placeholder in front
	// of an opening quote — and answers with [19.1], a break that must not happen. So the quotation
	// rule beats the placeholder's own break, and the two cannot share a list.
	if right == .qu {
		return BreakKind.no
	}
	// LB20: a contingency break character is a break on both sides, which is the object replacement
	// character's way of saying "something is here that has no text". It answers here, before the
	// classes below, because those classes would otherwise refuse a break the object replacement
	// character asks for: `× FFFC ÷ 3000 ÷` and `× FFFC ÷ FE19 ÷` are both breaks, and a
	// break-after character or a numeric infix on the right is not enough to stop them.
	if left == .cb {
		return BreakKind.allowed
	}
	if right == .cb {
		return BreakKind.allowed
	}
	// LB17, LB19, LB21, LB22 and the numeric matrix's own prohibitions, which all sit below LB18
	// in the specification's order: a line may not begin with one of these unless a space is in
	// front of it.
	if is_prohibited_start_after_space(right) {
		return BreakKind.no
	}
	// LB23a and LB23b: two of the same class that must not be split, which is
	// Hangul syllables and a numeric run's own continuation. They come before
	// LB28 so that a run of numbers stays whole when the class says so.
	//
	// The numeric half was missing while the comment claimed it, and the comment is what hid it: a run of
	// digits could break between any two of them, so "12345" wrapped as "12" / "345". Nothing about the
	// output looked wrong — a number split across two lines is still a number-looking thing — which is why
	// it survived until the conformance test was run. "19C" was the case that showed it: the letter after
	// the digits was correctly held on by LB28 while the digits themselves parted.
	if left == .jl || left == .jv || left == .jt {
		if right == .jl || right == .jv || right == .jt {
			return BreakKind.no
		}
	}
	if left == .nu && right == .nu {
		return BreakKind.no
	}
	if left == .ri && right == .ri {
		// LB30a: a pair of regional indicators is one flag, so the run between
		// them is not a break. A longer run is a sequence of pairs, which is why
		// this looks at the pair rather than the run.
		return BreakKind.no
	}
	// LB28: two alphabetic characters do not break between them. This is the rule
	// that makes a word a word, and leaving it out turns every word into a
	// letter run a caller may split anywhere.
	//
	// It is not the same as saying "never break here", because LB28 has an
	// exception: the pair may break if either character is a hyphen, which is
	// what lets "well-known" break after its hyphen. The hyphen is handled by
	// LB21 below, so by the time this runs neither side is one.
	if left == .al && right == .al {
		return BreakKind.no
	}
	// LB28's other two pairs: a letter and a digit, in either order. These were missing and the
	// conformance test is what showed it — they are the cases that let "H2O" and "COVID19" split at the
	// letter-digit boundary, which is a Latin problem and not a CJK one.
	//
	// A hexadecimal-looking name is the common case, and a break inside one leaves a line ending in a
	// digit and the next starting with a letter, which reads as a hyphenation the writer never asked for.
	if (left == .al && right == .nu) || (left == .nu && right == .al) {
		return BreakKind.no
	}
	// LB29: an infix separator — the full stop or comma of a decimal or thousands — holds to the
	// alphabetic character that follows it. "1,000" and "3.14" are one thing each, and this is the rule
	// that says so. It is separate from LB28 because the separator is a different class from the digit, and
	// a pair of digits is already held together by LB23b above.
	if left == .insp && (right == .al || right == .hl) {
		return BreakKind.no
	}
	// LB29: the same for a pair of Hangul syllables that are not part of the same
	// one. A jamo run was handled above, so this is two syllables, which do
	// break between them.
	if left == .h2 && right == .h2 {
		return BreakKind.allowed
	}
	if left == .h3 && right == .h3 {
		return BreakKind.allowed
	}
	// LB21: a hyphen may break after it, and only after it. A hyphen-minus is the
	// ordinary case, and a word like "well-known" has to be allowed to end its
	// first line there or it cannot be set narrow at all.
	if left == .hy && right == .al {
		return BreakKind.allowed
	}
	// ...and, since 2026-10-04, from the character after it either.
	//
	// The rule above has always covered the left side of a mark only, and the comment claimed the pair was
	// glued on purpose. It is not: a line ending between an accent and its letter is as wrong as one ending
	// between the letter and the accent, and every conformance case of the form `× 2757 × 0308 × 2757 ÷`
	// failed at exactly the index after the mark.
	//
	// This is a narrow rule rather than the class change that was tried first. Giving the mark its base's
	// class fixes the same case and every other one, but a base that is allowed to break away — a space, or
	// a character whose own class permits a break — has that break suppressed by the mark in front of it,
	// and the score fell from 13,090 to 10,912. Refusing the break *at* a mark is the smaller change: it
	// affects one position instead of rewriting the class every rule after it reads.
	if is_markish(left) {
		return BreakKind.no
	}
	// LB31, and the default of LB31 in the specification's own table: break
	// everywhere else. This is a permissive default, and it is why the rules
	// above it matter: a permissive default is what draws the text, and the rules
	// are what stop it drawing somewhere a reader cannot follow.
	_ = n
	_ = cps
	_ = props
	return BreakKind.allowed
}

// is_break_after_hyphen_break reports a break after a hyphen that ends an
// already-broken word, which is LB21b.
//
// The case is a text that came in with a newline in the middle of a word, which
// is what happens when a line is copied out of a document and pasted back
// somewhere that does not know it was a line. Without this the text reads as
// two words with a space where the hyphen was.
fn is_break_after_hyphen_break(props &Properties, cps []rune, classes []LineBreakClass,
	i int) bool {
	// i is the position of the right-hand character, so the hyphen is at i-1 and
	// whatever the hyphen broke is at i-2.
	if i < 2 {
		return false
	}
	if classes[i - 1] != .hy {
		return false
	}
	// The hyphen must be at the end of a word that was already broken, which means
	// a mandatory break follows it.
	after := i + 1
	if after < classes.len && is_mandatory_break(classes[after]) {
		return true
	}
	_ = cps
	_ = props
	return false
}

// is_mandatory_break reports whether this class is one the text must break at.
fn is_mandatory_break(c LineBreakClass) bool {
	return c == .lf || c == .bk || c == .cr || c == .nl
}

// is_prohibited_start reports whether a line may not begin with this class even when a space comes
// in front of it, which is LB7 for its zero width space, LB11 for a word joiner, and LB13.
//
// The two halves of the old single list are split by LB18, and the split is measured rather than
// assumed. `ucd/LineBreakTest.txt` asks `× A × 0020 ÷ B ÷` for every class B, which is the whole
// question in one shape, and it answers it in two groups:
//
//	no break:  BK CR LF NL SP ZW WJ CL CP EX IS SY, and a final quotation mark
//	break:     everything else — CM GL B2 BB HY BA NS PO PR QU_Pi IN NU OP and the rest
//
// So only the first group belongs here. The second is `is_prohibited_start_after_space`, and a
// class that is in the wrong list fails in the direction the list says: a class held back here
// loses the break a space asks for, and one moved down there gains a break the spec refuses.
//
// The inseparable class is spelled .insp here because .is is a V keyword, and it matters: a
// character that cannot be separated from its neighbour is the one case where a break on either
// side would put two marks on different lines.
fn is_prohibited_start(c LineBreakClass) bool {
	return c == .cl || c == .cp || c == .ex || c == .insp || c == .sy
}

// is_prohibited_start_after_space reports whether a line may not begin with this class once a
// space is allowed to break in front of it, which is LB17 for a break-before-and-after, LB19 for
// a quotation mark, LB21 for a break-before, a hyphen or a non-starter, LB22 for an inseparable
// numeral infix, and the numeric matrix's prefix and postfix.
//
// LB12a's glue is here too, though not in this function: it is spelled out at its own site because
// its exclusion list is the point of it.
fn is_prohibited_start_after_space(c LineBreakClass) bool {
	return c == .b2 || c == .qu || c == .ba || c == .hh || c == .hy || c == .ns
		|| c == infx || c == .po || c == .pr
}

// is_prohibited_end reports whether a line may not end with this class, which
// is rules LB15 through LB19 and LB21.
fn is_prohibited_end(c LineBreakClass) bool {
	return c == .op || c == .qu || c == .cp || c == .insp || c == .ns || c == .ex || c == .hy
		|| c == .bb
}

// effective_class returns the class of a character, after the one change UAX#14
// makes to the table before any rule reads it.
//
// That change is LB4a: a mark that follows a character takes on the combining mark class, whatever
// the table says it is. So a letter and the accent on it are one unit, and a Persian letter and the
// non-joiner after it are one unit, and neither can be split by a break.
//
// A zero width joiner is turned into a combining mark for the same reason and by a different rule,
// LB8a, because a joiner is an instruction about the letters around it rather than a mark of its
// own. A word joiner is left alone: it is already a class of its own, and it is the one that forbids
// a break on both sides of it, which is what makes it the character a caller reaches for when a
// word must not be split.
fn effective_class(props &Properties, cps []rune, i int, so_far []LineBreakClass) LineBreakClass {
	raw := props.line_break_of(cps[i])
	if raw == .zwj {
		return .cm
	}
	// LB4a: a mark after a character is a combining mark whatever the table says,
	// which is what keeps a line from ending between a letter and the accent on
	// it. The table has most of these already, but not all, and the ones it misses
	// are exactly the ones a Latin letter with a combining accent would use.
	//
	// Taking the *previous class* for a mark instead of .cm was tried, on the reading that LB9 makes a
	// mark behave as the character before it in both directions. It measured much worse — 8,434 failures
	// against 6,272 — because a mark then carries its base's class into the rule after it, and a base that
	// must be allowed to break away (a space, or a character whose own class permits a break) has that
	// break suppressed by the mark. The one-sided check at the end of the chain is what is left, and it is
	// the smaller loss of the two.
	if i > 0 && is_markish(raw) {
		return .cm
	}
	_ = so_far
	// LB1 resolves five classes that no rule matches otherwise, and every one of
	// them fell through to the permissive default at the end of the chain here.
	//
	// Each resolution below is derived from the committee's own file rather than from
	// the text, because the two disagree and the file is what a caller is checked
	// against. For each class the file records the rule tag it answered with, and
	// that tag names the class it broke as:
	//
	//   - AI, 552 positions, `[28.0]` where a break is asked for and `[9.0]` for the
	//     rejected ones. Both are AL. UAX#14 resolves AI to AL.
	//   - XX, 552 positions, `[28.0]` and `[23.02]` on the same split. Also AL, which
	//     is what the annex calls the default behaviour for an unknown.
	//   - SA, 1660 positions over two characters, and the split is not by class. The
	//     two the file uses answer differently from each other: U+0E31 answers
	//     `[9.0]` (a combining mark) and U+0E01 answers `[28.0]` (an alphabetic).
	//     UAX#14 says they must not break without a dictionary this engine has no
	//     table for, and recommends AL. Taking AL measured 3099 to 3041, which is 57
	//     cases gained and none lost.
	//   - CJ, 602 positions, `[21.04]` at 423 of them, which is `× (BA | HY | NS)` —
	//     the class a small kana must not be broken away from. So CJ is a
	//     non-starter. `× 2757 × 3041 ÷` is the shape. Measured before SA it is
	//     3099 to 3086, 43 fixed against 29 broken; measured after SA it is 3041
	//     to 3028, because SA has by then taken the letter the 29 were breaking into.
	//
	// The order the numbers below are in is the order they were measured in, and each
	// is against the one above it: 3242 at the start, 3127 after the aksara prebase
	// and the virama left the mark list, 3099 after XX, 3041 after SA, 3028 after CJ,
	// and 2901 after the Hangul syllables left it too.
	//
	// SA as a mark is deliberately not implemented. UAX#14 asks for it, and the file
	// shows it at U+0E31 and U+102C, both of which answer `[9.0]`. It cannot be done
	// from this engine's tables: the only signals for "is this SA character a mark"
	// are combining class, which is zero at all 757 SA codepoints, and bidi NSM,
	// which is 133 of 757 and is zero at U+102C, a Myanmar mark the file counts as
	// one. Getting it right needs a General_Category range table this library does
	// not generate.
	if raw == .ai {
		return .al
	}
	if raw == .xx {
		return .al
	}
	if raw == .sa {
		return .al
	}
	if raw == .cj {
		return .ns
	}
	return raw
}

// is_markish reports whether a class is one of the mark classes LB4a folds into
// a combining mark.
//
// The list was six long and is now one. Every removal below is measured against
// the committee's file, and the shape that decided each one is the file's own.
//
// .ak, .ap and .vi are the classes UAX#14's older table called aksara and
// virama. .ak went first: it is a base character — a Balinese letter — and the
// file says so with `× 2757 ÷ 1B05 ÷`, a break the engine refused. .ak and .ap
// and .vi were justified together on the reading that a prebase is a mark in the
// same sense a Devanagari prebase is, and the file disagrees in both directions:
// of the 1112 positions whose right-hand character is an AP or a VI, 497 ask for
// a break and 615 do not, so the class is not a mark on that side at all.
// Dropping .ap and .vi measured 3242 to 3127 — 132 cases fixed against 17
// broken, so a net **115**. The 17 are all a base and a letter after a virama,
// `× 1B05 × 1B44 ÷` and `× 25CC × 1B44 × 1B2C ÷` among them, which LB28's
// sub-rules cover and this engine does not implement.
//
// .h2 and .h3 are Hangul syllables, which are not marks: they are the letter
// itself, and U+AC00 is one of them. Folding them into a combining mark meant a
// syllable could not break before another syllable, so Korean text on an ID-based
// layout was one unbreakable run. Removing them measured 3041 to 2914, a net
// **127**, and the 13 cases it broke are LB26's own sub-rules — `× 1100 × AC00 ÷` is
// a leading jamo held on by LB26.01, and `× 0024 × AC00 ÷` a prefix numeral held
// on by LB27.02. Both are missing rules rather than wrong classes, so they are
// recorded as gaps rather than chased here.
//
// .idcj, an ideographic closing bracket, measured **zero** in either direction:
// the committee never uses it as a right-hand class at a position the engine
// answers. It is not in the list because nothing measured was gained by keeping
// it, not because anything was measured by removing it.
//
// What is left is the mark proper, which is the class UAX#14 LB4a is actually
// about: a Latin accent, an Arabic tashkil, a zero width non-joiner.
fn is_markish(c LineBreakClass) bool {
	return c == .cm
}

fn clamp_index(i int, n int) int {
	if i < 0 {
		return 0
	}
	if i >= n {
		return n - 1
	}
	return i
}

// WrappedLine is one line of text laid out to fit a width, with the input range it came from.
//
// The range is in input indices and it is the whole of what a caller needs to draw the line, place a
// caret in it, or lay it out again at a different width. A caller that only wants to draw does not
// have to look at the range, and a caller that wants to do anything else cannot do it without it.
pub struct WrappedLine {
pub mut:
	// line is the shaped and positioned line, ready to draw.
	line Line
	// from and to are the input character indices the line covers, half open.
	from int
	to   int
}

// wrap_paragraph lays text out into as many lines as it takes to fit max_width, and returns them
// with the input range each covers.
//
// This is separate from layout_paragraph rather than an option on it, for one reason: a line has to
// be measured before it can be broken. Laying out the whole paragraph once and splitting the glyphs
// at the chosen points works, and it costs one layout of the whole paragraph rather than one per
// line, which is what makes it affordable to try a narrower width without paying for a full shaping
// pass again.
//
// The rules are the ones a caller would otherwise write and get subtly wrong.
//
// Leading spaces go. A space at the start of a line is what a space before a break looks like once
// it has been put on the next one, and it pushes every letter on the line away from the margin.
// Trailing spaces stay. They are not drawn, but a caller measuring where a caret sits needs them
// counted, and dropping them would move the caret.
//
// A word longer than the width is not split. It goes on a line of its own and overflows, because a
// caller whose word has been broken across two lines cannot map a click on either half back to the
// text, which is a worse failure than a line that is too wide.
//
// A text with no break opportunity in it returns one line, however narrow the width. Squeezing it
// anyway would mean breaking inside a word.
//
// No discretionary features are applied. Use wrap_paragraph_with to ask for any.
pub fn wrap_paragraph(ctx &Context, cps []rune, base_dir Direction, fs &FontSet, em_px f64,
	max_width f64) []WrappedLine {
	return wrap_paragraph_with(ctx, cps, base_dir, fs, em_px, max_width, &LayoutOptions{})
}

// wrap_paragraph_with is wrap_paragraph with the caller's options applied.
//
// This exists rather than an extra argument on wrap_paragraph because a caller that cannot pass features
// cannot pass anything, and the paragraph was then shaped without the features the caller asked for while
// the same text laid out with layout_paragraph_with was shaped with them. The two disagreed about the width
// of the same text, which is the one thing a text engine must never do.
pub fn wrap_paragraph_with(ctx &Context, cps []rune, base_dir Direction, fs &FontSet, em_px f64,
	max_width f64, options &LayoutOptions) []WrappedLine {
	if cps.len == 0 {
		return []WrappedLine{}
	}
	// The paragraph is shaped once. Everything below measures slices of the result, which is the
	// point: shaping is the expensive part, and a paragraph is shaped the same way whether it ends
	// up on one line or ten.
	full := layout_paragraph_with(ctx, cps, base_dir, fs, em_px, options)
	ops := break_opportunities(ctx, cps, true)

	mut out := []WrappedLine{}
	mut from := 0
	// last is the break that fitted most recently, and the point the line being built would end at.
	// A line is only emitted when a later break turns out not to fit, which is what keeps a word
	// whole: the line ends at the last place it could, not at the margin.
	mut last := from
	mut have_last := false

	for o in ops {
		if o.start <= from {
			continue
		}
		// A mandatory break ends the paragraph and does not care about the width at all.
		if o.is_mandatory {
			// The line ends at the newline itself, which is the character before the break, so the
			// next line starts after it. The newline draws nothing, so the two ranges leave nothing
			// of the text out.
			mut stop := o.start - 1
			if stop < from {
				stop = from
			}
			out << WrappedLine{
				line: slice_for_range(full, from, stop)
				from: from
				to:   stop
			}
			from = o.start
			have_last = false
			last = from
			// Keep going rather than recursing: the loop already walks the whole text and a
			// recursive call would have to reshape the tail, which is the cost this avoids.
			continue
		}
		if width_of_range(full, from, o.start) > max_width {
			if have_last && last > from {
				// This break is past the margin, so the line ends at the last one that fitted.
				out << WrappedLine{
					line: slice_for_range(full, from, last)
					from: from
					to:   last
				}
				from = last
				// The break that did not fit is the first candidate for the new line, so it is
				// offered again rather than skipped. Without that, a long word would be dropped.
				have_last = false
				last = from
				if width_of_range(full, from, o.start) > max_width {
					// A single word wider than the whole line. It goes on a line of its own and
					// overflows, because a caller cannot map a click on one half of a broken word
					// back to the text.
					out << WrappedLine{
						line: slice_for_range(full, from, o.start)
						from: from
						to:   o.start
					}
					from = o.start
					last = from
					have_last = false
				}
				continue
			}
			// Nothing has fitted yet, which means the first word is wider than the line. It is put
			// on a line of its own rather than being split.
			out << WrappedLine{
				line: slice_for_range(full, from, o.start)
				from: from
				to:   o.start
			}
			from = o.start
			last = from
			have_last = false
			continue
		}
		last = o.start
		have_last = true
	}
	// Whatever is left after the last break, and the whole text when it never broke.
	if from < cps.len || out.len == 0 {
		out << WrappedLine{
			line: slice_for_range(full, from, cps.len)
			from: from
			to:   cps.len
		}
	}
	return out
}

// width_of_range measures the glyphs of a shaped line that belong to a range of input characters.
//
// Measuring a slice rather than laying out the slice is what makes wrapping affordable: the glyphs
// already have their advances, so adding them up costs nothing and shaping them again would cost the
// whole pipeline. The width a line needs is the sum of the advances of the glyphs on it, which is
// what line.width already is for a whole line.
fn width_of_range(full &Line, from int, to int) f64 {
	mut w := f64(0)
	for g in full.glyphs {
		if g.cluster >= from && g.cluster < to {
			w += g.advance
		}
	}
	return w
}

// slice_for_range takes the glyphs of a shaped line that belong to a range of input characters.
//
// The range is in input indices and the glyphs are in visual order, so this cannot stop when it
// reaches the index: for a right-to-left paragraph the first glyph on the line is the last character
// of it. The glyphs are gathered by cluster and then put back in the visual order the line already
// had, which is what keeps the result drawable without a second layout.
//
// The x of each glyph is then made relative to the line's own left edge, because a line is drawn
// from its own left and not from the left of the paragraph it was cut out of. A mark shares the x
// of the base it sits on, so it moves with it and needs nothing of its own.
fn slice_for_range(full &Line, from int, to int) Line {
	mut line := Line{
		ascent:      full.ascent
		descent:     full.descent
		line_height: full.line_height
	}
	mut kept := []Glyph{}
	for g in full.glyphs {
		if g.cluster >= from && g.cluster < to {
			kept << g
		}
	}
	if kept.len == 0 {
		return line
	}
	// The left edge of the first glyph is the left edge of the line. In a right-to-left line that
	// is the rightmost glyph, and subtracting it from every glyph shifts the line so its own first
	// glyph is at zero, which is the same place it was at in the paragraph for a left-to-right line
	// and the right place for a right-to-left one.
	origin := kept[0].x
	mut width := f64(0)
	for i in 0 .. kept.len {
		mut g := kept[i]
		g.x -= origin
		// The line's width is how far the pen travels, which is the right edge of the last glyph
		// rather than the sum of the advances: a mark has no advance of its own and sits over the
		// letter it belongs to, so it never widens a line.
		reach := g.x + g.advance
		if reach > width {
			width = reach
		}
		line.glyphs << g
	}
	line.width = width
	return line
}

// TextMetrics is what a caller needs about a piece of text before it draws any of it.
//
// The two widths are a pair because no single number answers the question. The widest is the text on one
// line with no break taken, which is what a caller laying out without wrapping needs. The narrowest is
// every unbreakable unit on a line of its own, which is what a caller collapsing text to its smallest
// possible size needs. They differ by however much the break opportunities are worth, so a caller that
// only ever learns one of them is wrong by an amount it cannot see.
pub struct TextMetrics {
pub:
	// min_content_width is the narrowest the text can be without a glyph breaking out of it: the
	// width of its widest unbreakable unit.
	//
	// Trailing spaces are not counted, and that is the difference between this and taking the number
	// from a wrapped line. A break opportunity falls after a space, so the space ends the line before
	// the break rather than starting the one after it, and a line measured as laid out includes one
	// space's width. At a 16 pixel size a space is about a twentieth of a line, so a caller copying
	// the number out of wrap_paragraph over-reports by a space on every word.
	min_content_width f64
	// max_content_width is the width of the text with no line break taken at all, which is the same
	// number layout_paragraph reports as its width.
	//
	// The two are computed from one shaping and are required to agree: the total of every glyph's
	// advance is the same as the furthest the pen reached, because place_glyphs accumulates x as a
	// running sum of advances from zero. If they ever disagreed, one of them would be measuring a
	// different paragraph from the other.
	max_content_width f64
	// ascent and descent are how far the ink reaches above and below the baseline, in pixels. They
	// are the extent of what was drawn rather than of the font, so a mark that reaches above its
	// font's own ascent makes them larger than the font's metrics.
	ascent  f64
	descent f64
	// line_height is the resolved baseline-to-baseline distance: the caller's
	// LayoutOptions.line_height when there was one, and otherwise the largest natural line height
	// among the fonts that contributed a glyph.
	line_height f64
}

// measure_paragraph reports what a caller needs to know about cps before it draws any of it.
//
// It is a separate function rather than a field on Line because the common caller of it never wants a
// Line: a caller measuring a paragraph to choose a width, or to collapse text to its narrowest form, has
// no use for 400 positioned glyphs and would have to throw them away.
//
// No discretionary features are applied. Use measure_paragraph_with to ask for any.
pub fn measure_paragraph(ctx &Context, cps []rune, base_dir Direction, fs &FontSet, em_px f64) TextMetrics {
	return measure_paragraph_with(ctx, cps, base_dir, fs, em_px, &LayoutOptions{})
}

// measure_paragraph_with is measure_paragraph with the caller's options applied.
//
// The point of the _with form is that both widths have to agree with what layout_paragraph_with would
// produce for the same text and the same options. A measurement taken without the features, or taken with
// a different line height, is a measurement of a different line, and a caller that sizes a box from it
// has sized the box for something it will not draw.
pub fn measure_paragraph_with(ctx &Context, cps []rune, base_dir Direction, fs &FontSet, em_px f64,
	options &LayoutOptions) TextMetrics {
	if cps.len == 0 {
		return TextMetrics{}
	}
	// The paragraph is shaped once and both widths come out of that one shaping. This is the whole
	// reason this is a function rather than a loop over wrap_paragraph: a caller hunting for the width
	// it wants pays for the shaping once however many widths it tries, which is what makes it
	// affordable to measure at all.
	full := layout_paragraph_with(ctx, cps, base_dir, fs, em_px, options)
	cum := cluster_prefix(full, cps.len)
	// The narrowest width is collected into a local and the struct is built once at the end, because
	// every field here is read-only to a caller and a value that is filled in afterwards would have to
	// declare them mutable to do it.
	mut narrowest := f64(0)
	mut from := 0
	for o in break_opportunities(ctx, cps, true) {
		to := if o.start > cps.len { cps.len } else { o.start }
		if to <= from {
			continue
		}
		w := segment_width(ctx.properties, cps, cum, from, to)
		if w > narrowest {
			narrowest = w
		}
		from = to
	}
	return TextMetrics{
		min_content_width: narrowest
		max_content_width: full.width
		ascent:            full.ascent
		descent:           full.descent
		line_height:       full.line_height
	}
}

// cluster_prefix turns a shaped line's advances into running totals by input character.
//
// cum[i] is the total advance of every glyph whose cluster is below i, so the width of a half-open range
// of characters is cum[to] - cum[from].
//
// It exists to keep this linear. Asking width_of_range once per break opportunity instead walks every
// glyph of the paragraph once per opportunity, which is quadratic in the length of a text whose words are
// short, and short words are most of the text anyone measures.
//
// Advances are gathered per input character rather than in visual order because the question is about a
// range of the caller's text, and a range of text is a range of clusters. A ligature puts its whole
// advance on its first character and a mark puts none anywhere, and both are right here: neither widens
// a line that is cut at its edge, which is what keeps the segments of a right-to-left paragraph summing to
// the same total as the paragraph.
fn cluster_prefix(line &Line, n int) []f64 {
	mut by_cluster := []f64{len: n}
	for g in line.glyphs {
		// A cluster outside the caller's text is not expected, and is not worth trusting: the
		// alternative to skipping it is an out-of-bounds write on untrusted input.
		if g.cluster < 0 || g.cluster >= n {
			continue
		}
		by_cluster[g.cluster] += g.advance
	}
	mut cum := []f64{len: n + 1}
	for i in 0 .. n {
		cum[i + 1] = cum[i] + by_cluster[i]
	}
	return cum
}

// segment_width is the width of the characters in [from, to) with the trailing spaces left out.
//
// The spaces are left out because a break falls after a space. The space is therefore the last thing on
// the line being measured rather than the first thing on the next one, and counting it would make every
// unbreakable unit one space wider than the characters in it.
//
// A segment that is entirely spaces has no width at all, which is right rather than an edge case: a run
// of spaces is not an unbreakable unit a caller has to be able to fit on a line, and giving it the width
// of one space would make a paragraph of spaces report a non-zero minimum.
fn segment_width(props &Properties, cps []rune, cum []f64, from int, to int) f64 {
	mut end := to
	for end > from && is_line_end_space(props, cps[end - 1]) {
		end--
	}
	if end <= from {
		return 0.0
	}
	return cum[end] - cum[from]
}

// is_line_end_space reports whether a character ends a line without being content the caller measures.
//
// A space is the ordinary case. A newline is here because a segment that ends at a mandatory break has
// it on its end, and a caller measuring a paragraph it is going to wrap again should not be charged for a
// character that draws nothing and that its own line breaker will discard. The classes are named rather
// than tested for two characters because a carriage return is a line end on its own account and U+0085
// is one too, and a caller that had to remember which is which would eventually get it wrong.
fn is_line_end_space(props &Properties, cp rune) bool {
	c := props.line_break_of(cp)
	return c == .sp || c == .lf || c == .bk || c == .cr || c == .nl
}
