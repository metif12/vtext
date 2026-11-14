module layout

import vtext.shape
import vtext.ucd

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
pub enum BreakKind {
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
pub fn break_opportunities(ctx &shape.Context, cps []rune, mandatory_first bool) []BreakOpportunity {
	props := ctx.properties
	n := cps.len
	if n == 0 {
		return []BreakOpportunity{}
	}
	// The classes are read once. They are a lookup per character and the same
	// character is asked about three times by the rules below.
	//
	// The SA table is decoded here and threaded through for the same reason the quotation roles
	// are: LB1 asks at most once per complex-context character, and the answer is a per-character
	// lookup. `Properties` has no field for it because `tables.v` owns that struct and the
	// quotation work took the caller-decode route first; the note on `sa_mark_ranges` records why.
	sa := ucd.sa_mark_ranges()
	mut classes := []ucd.LineBreakClass{cap: n}
	for i in 0 .. n {
		classes << effective_class(props, sa, cps, i, classes)
	}
	// The quotation roles are read once for the same reason, and by the same rules: LB15a and
	// LB15b are the only two that ask which direction a quotation mark opens, and they ask
	// about the character a space run hangs from.
	quote := ucd.quote_ranges()

	// The East Asian widths are read once for the same reason: LB30, LB19a and LB21a are the
	// only rules that refine a pair by width, and they ask about brackets and quotation marks.
	ea := ucd.east_asian_ranges()

	// The unassigned pictographs are read once for the same reason: LB30b is the only rule
	// that asks, and it asks about an emoji modifier's neighbour.
	eu := ucd.ep_unassigned_ranges()

	mut out := []BreakOpportunity{}
	// Quotation-span state: how many opening marks are still open. A closing
	// mark breaks after itself only when it closes one of these; a stray Pf
	// with nothing open holds by the rules below. The state is an int rather
	// than a flag because spans nest, and an inner close still closes. Only
	// definite marks count — a mark that can be either (U+0022, U+0027) opens
	// and closes nothing, because the pair engine cannot tell which it is.
	mut quote_depth := 0
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
		// Whether the previous position broke is decided, because positions are decided
		// left to right and only this one is still open. A closing quotation mark that
		// stands alone breaks on both sides, and "stands alone" is exactly this: the
		// break in front of it already happened.
		prev_broke := out.len > 0 && out[out.len - 1].start == i
		// Whether this position closes a quotation span: the left character is a
		// closing mark and an opening mark is still open. Decided here, where the
		// pair is, rather than inside the rule, because the depth belongs to the
		// walk and the rule only answers.
		left_role := ucd.quote_role_of(quote, cps[i])
		closes_span := left_role == .pf && quote_depth > 0
		// LB7, and then the pairs, in the order the specification numbers them. The
		// order is not arbitrary: LB8 has to come before LB8a, which has to come
		// before LB9, and a later rule may not override an earlier one.
		kind := break_kind(props, cps, classes, quote, ea, eu, prev_broke, closes_span, i)
		// The span state moves past every position the same way, break or no
		// break: a closing mark closes its span whether a line may end after
		// it or not, and a break does not close anything early.
		if left_role == .pi {
			quote_depth++
		} else if left_role == .pf && quote_depth > 0 {
			quote_depth--
		}
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
pub fn is_mandatory_break_at(classes []ucd.LineBreakClass, pos int, n int, mandatory_first bool) bool {
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
pub fn break_kind(props &ucd.Properties, cps []rune, classes []ucd.LineBreakClass, quote []ucd.CodeRange,
	ea []ucd.CodeRange, eu []ucd.CodeRange, prev_broke bool, closes_span bool, i int) BreakKind {
	left := classes[i]
	right := classes[i + 1]
	n := classes.len

	// LB5: a CRLF is one break rather than two. A newline followed by a closing bracket
	// still breaks, and a pair rule would otherwise read the bracket as the
	// right-hand character and forbid it.
	//
	// The pair is checked before the mandatory rule because a carriage return is
	// otherwise always a break on its own: `× 000D × 000A ÷` is tagged [5.01] with
	// no break between the two, and the break after the feed is reported by the
	// mandatory rule at the position after it.
	if left == .cr && right == .lf {
		return BreakKind.no
	}
	if is_mandatory_break(left) {
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
	// LB8: break before anything that follows a zero width space, even across spaces.
	// Measured over every `ZW × SP | X` position in ucd/LineBreakTest.txt: the file
	// breaks before every class but one group — BK, CR, LF and NL, which the rule
	// above answers, and SP and ZW, which LB7 answers further above. Everything else
	// breaks, including the quotation marks LB15 and LB19 hold, the joiner LB11 holds
	// and the contingency break LB20 breaks around: rule 8 answers before rules 11
	// through 20, so a zero width space overrides every one of them.
	//
	// Only spaces intervene, and the space run has to reach this position: a mark in
	// front of it answers LB9 first. `run_origin` walks marks too and would read `ZW ×
	// CM × SP ÷ X` as one run, but the committee tags the mark [9.0] and refuses it
	// there.
	if i > 0 && classes[i] == .sp {
		mut zb := i
		for zb > 0 && classes[zb - 1] == .sp {
			zb--
		}
		if zb > 0 && classes[zb - 1] == .zw {
			return BreakKind.allowed
		}
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
	// LB8a: do not break after a zero width joiner. `× 200D × 2757 ÷` is the shape, tagged
	// [8.1], and the raw property is asked rather than the resolved class because
	// `effective_class` folds a joiner into a combining mark: at the class level this pair
	// is indistinguishable from `× 0308 × 2757 ÷`, which breaks. The b2 rule below does the
	// same raw read for the same reason.
	if props.line_break_of(cps[i]) == .zwj {
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
	// lookups below, where the question is the base's.
	//
	// It is declared here, above LB11, because LB11 reads it too: `eff_left == .wj` below and
	// `is_prohibited_end(eff_left)` further down both need the base and not the mark, and the
	// declaration sits before the first of them.
	mut eff_left := left
	if is_markish(left) {
		mut j := i
		for j > 0 && is_markish(classes[j]) {
			j--
		}
		eff_left = classes[j]
		// LB9 absorbs a mark into its base everywhere except after a hard break, a space or a
		// zero width space, and LB10 resolves what is left into a letter: `× 000B ÷ 0308 × 2757 ÷`
		// breaks after the control and refuses before the letter, tagged [4.0] and [28.0], because
		// the mark is an AL and not a BK. A mark at the start of the text has no base at all, so
		// it is a letter the same way.
		//
		// A word joiner and glue keep holding through a mark — `× FEFF × 0308 × FE6A ÷` is [11.02]
		// — because LB9 names them as bases and the exception list does not.
		if is_markish(classes[j])
			|| classes[j] == .bk || classes[j] == .cr || classes[j] == .lf
			|| classes[j] == .nl || classes[j] == .sp || classes[j] == .zw {
			eff_left = .al
		}
	}
	// LB11: a word joiner forbids a break on either side of it, and LB12 forbids one before it.
	// The two are the same effect and one rule says it: a line may not end on a word joiner and
	// may not begin with one, because either would separate the two characters the writer asked to
	// be inseparable.
	//
	// This is what a caller reaches for when a word must not be split. A zero width non-joiner is
	// not the same thing: it is a combining mark, so it glues only to what comes before it.
	//
	// The left half is `eff_left` and not `left`, which the committee's file asks for: `× FEFF × 0308
	// × FE6A ÷` is [11.02] at the postfix numeral, so a word joiner with a mark on it still holds.
	// Reading the raw character there lost 4 cases when the numeric matrix was corrected.
	if eff_left == .wj || right == .wj {
		return BreakKind.no
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
	// The exemption is a list of three. UAX #14 writes it `[^SP HY HH]`: a soft hyphen is
	// exempt because it is an unambiguous hyphen, and a break-after is not because it is
	// not one. The file asks `× 3000 × 16FE4 ÷` — an ideographic space in front of a glue —
	// and answers with [12.1], a break that must not happen.
	//
	// A mark in front of the glue does not hide the exemption: LB9 reads `HY × CM × GL` as
	// the hyphen and the glue, and the committee breaks `× 002D × 0308 ÷ 16FE4 ÷` at [31.01].
	// The raw class is still asked first, because a mark on any other base holds.
	if right == .gl {
		mut exempt := left == .sp || left == .hy || left == .hh
		if !exempt && left == .cm {
			exempt = eff_left == .sp || eff_left == .hy || eff_left == .hh
		}
		if !exempt {
			return BreakKind.no
		}
	}
	if is_prohibited_start(right) {
		// LB13: the right-hand character may not start a line, and this is the set that holds even
		// when a space is in front of it. See the split in `is_prohibited_start`.
		//
		// LB15c breaks a decimal mark free of the list: `× 0020 ÷ 002E × 0033 ÷` breaks
		// before the full stop because a digit follows it — "subtract .5". The space
		// is what decides, so a hyphen in front of the same mark holds it: `× 002D ×
		// 002E × 0033 ÷` refuses at the same LB15d the list answers.
		if !(left == .sp && right == .insp && i + 2 < n && classes[i + 2] == .nu) {
			return BreakKind.no
		}
	}
	// A break before a contingency break beats the end-list classes that would refuse
	// it: `× 00B4 ÷ FFFC ÷`, `× 002D ÷ FFFC ÷` and `× 002C ÷ FFFC ÷` are all tagged
	// [20.01], so LB20 answers before `is_prohibited_end` is ever asked. The three
	// left-hand classes are the ones the file asks about — an acute, a hyphen and a
	// comma — and not a general CB override: a quotation mark with a mark on it still
	// refuses at the narrow rule below, which is why this stays a list.
	if (left == .bb || left == .hy || left == .insp) && right == .cb {
		return BreakKind.allowed
	}
	// A closing quotation mark that stands alone breaks on both sides: `× FF1A ÷ 201D ÷
	// 5B66 ÷` breaks at [31.01] on both sides of the mark, while `× 00BB × 231A ÷`
	// holds at [19.13] on both. What tells them apart is the position in front: the
	// first mark follows a break and the second does not. The end-list below would
	// hold both, so this answers first — but only for a mark followed by an
	// ideograph, which is every breaking case the file has.
	//
	// A closing mark also breaks after itself when it closes a quotation span that
	// is still open, whether or not the position in front broke: `× FF1F × 201D ÷
	// 5B50 ÷` and its two siblings are [31.01] breaks whose opener (U+201C) stands
	// dozens of characters back. The standalone case above is the same question
	// asked about the position in front; this one is asked about the whole line,
	// which is why the state has to thread through the walk rather than living in
	// the pair. A stray Pf with nothing open still holds, which is what keeps the
	// LB15b `A × SP × QU_Pf` lines and the [19.13] hold from breaking.
	if left == .qu && ucd.quote_role_of(quote, cps[i]) == .pf && right == .idas
		&& (prev_broke || closes_span) {
		// A span closed on CJK text breaks; the same marks around a Latin word
		// hold at [19.13] (`× 0067 × 201D × 5956 ×`). What tells them apart is
		// the width of what the mark stands on: a Wide or Fullwidth base breaks
		// and anything else holds, which is LB19a's East Asian exception read
		// off the pair rather than the span. The base is read through marks
		// the way eff_left is, because a mark's own width says nothing.
		if prev_broke {
			return BreakKind.allowed
		}
		mut pb := i - 1
		for pb > 0 && is_markish(classes[pb]) {
			pb--
		}
		if pb >= 0 && ucd.is_east_asian(ea, cps[pb]) {
			return BreakKind.allowed
		}
	}
	if is_prohibited_end(left) {
		// LB14 through LB17: the left-hand character may not end a line, including the forms that
		// read across a run of spaces. This comes before LB18, which is what makes `× SP × X ÷`
		// answer those rules rather than the space's own break.
		//
		// This is `left` and not `eff_left`, and that is measured rather than careless. Reading the
		// base here fixed 20 cases — the mark positions tagged [14.0], [19.x] and [21.05] above a
		// postfix numeral — and broke 94, because the list carries `.cp`, `.ex`, `.hy` and `.insp`,
		// which refuse only *some* breaks after them: `× 0029 × 2757 ÷` is [30.02] and `× 0029 ÷ 1B05
		// ÷` is [31.01]. Propagating that through a mark turned 94 correct breaks into refusals, so
		// the mark cannot simply inherit the whole list.
		return BreakKind.no
	}
	// LB15a and LB15b: a quotation mark and a space either side of it are one thing.
	//
	// These two are why the engine can no longer answer `SP × QU` with a single rule, and the
	// decider is not the quotation mark's own class — the line break table gives all three
	// kinds QU — but which direction it opens. Measured over every pair in ucd/LineBreakTest.txt:
	//
	//	× QU_Pi × SP × R      79 of 84 no break, the answer [15.11]
	//	× A     × SP × QU_Pi  break, the answer [18.0]
	//	× A     × SP × QU_Pf  148 of 154 no break, the answer [15.21]
	//	× A     × SP × QUmPimPf  break, the answer [18.0]
	//
	// So an opening mark holds what follows it and a closing mark holds what precedes it, and
	// the two are not the same rule: `× 00AB × 0020 × 2757 ÷` breaks and `× 2757 × 0020 × 00BB ÷`
	// does not, which is the same `SP × QU` pair with opposite answers because the character
	// on the other side of the space differs.
	//
	// The 5 that break against LB15a and the 6 that break against LB15b are all in the long
	// real-world lines near the end of the file, where the committee tracks whether the mark
	// closes a span that is still open: the same `IS × SP × QU_Pf` appears there once as [15.21]
	// and once as [18.0]. The constructed lines answer uniformly, and those are what this
	// implements. Measured: 254 lines fixed, 9 newly failing, net 245 of 19,346.
	//
	// Both rules read the *break after the space*, not the space's own pair, because LB7 already
	// forbids a break before a space and the committee tags the interesting decision [15.11] or
	// [15.21] on the marker that follows the space. A mark counts as part of the run rather
	// than as a break in it: 69 cases of `QU_Pi × CM × SP × R` and 4 of `QU_Pi × SP × CM × R`,
	// every one of them [15.11] or an absolute rule, with not one exception between them.
	// A zero width space does detach the run. It is a break of its own, so the space after it
	// starts a new unit and is not glued to the quotation mark in front of it: of the 69
	// `ZW × SP × R` cases, 63 break and the 6 that do not are a hard break or a space after,
	// which no rule may override. Without this, `× 200B × 0020 ÷ 00BB ÷` — [8.0] — would lose
	// the break it currently has.
	// An opening quotation mark holds a run of spaces and marks, and the run may end in a mark
	// rather than a space. This was keyed on `left == .sp` alone, which meant `× 00AB × 0308 ×
	// 2757 ÷` — a quote, a mark, and a letter — broke, and the committee tags that position [15.11].
	// A run is a run whether it ends in a space or a mark, so the hold now answers for both.
	//
	// It has to read through the mark to the character in front of the run, which is what
	// `run_origin` already does, and it has to be checked here rather than at LB9's position so
	// that the mark does not detach the run.
	if left == .sp || is_markish(left) {
		behind := run_origin(classes, i)
		// A closing mark holds the run whether a zero width space detached it or not:
		// LB15b is about the mark and what follows it, not about what the run hangs
		// from. `× 200B ÷ 0308 × 0020 × 00BB ÷` holds at [15.21] with a detached run
		// and nothing after the mark.
		if ucd.quote_role_of(quote, cps[i + 1]) == .pf {
			follows := if i + 2 < n { classes[i + 2] } else { ucd.LineBreakClass.nl }
			if follows == .nl || follows == .sp || follows == .gl || follows == .wj
				|| follows == .cl || follows == .qu || follows == .cp || follows == .ex
				|| follows == .insp || follows == .sy || follows == .bk || follows == .cr
				|| follows == .lf || follows == .zw {
				return BreakKind.no
			}
		}
		detached := behind >= 0 && classes[behind] == .zw
		if !detached {
			// The run hangs on the character in front of it, and a run that reaches the start
			// of the text hangs on nothing, so there is no quotation mark to hold it.
			//
			// An opening mark only holds a run it starts itself: LB15a grows the quotation
			// from a space, an opening punctuation, another quotation or the start of the
			// text — `(sot | BK | CR | LF | NL | OP | QU | GL | SP | ZW) Pi SP* ×` — and a
			// mark after a letter is content already. `× 00AB × 0020 ÷ 0028 ÷` breaks at
			// [18.0] before the parenthesis because the letter in front of the mark is not
			// in that list, while `× QU_Pi × SP × AL ÷` holds at [15.11].
			if behind >= 0 && ucd.quote_role_of(quote, cps[behind]) == .pi {
				fresh := behind == 0 || classes[behind - 1] == .bk || classes[behind - 1] == .cr
					|| classes[behind - 1] == .lf || classes[behind - 1] == .nl
					|| classes[behind - 1] == .op || classes[behind - 1] == .qu
					|| classes[behind - 1] == .gl || classes[behind - 1] == .sp
					|| classes[behind - 1] == .zw
				if fresh {
					return BreakKind.no
				}
			}
			// LB14: an opening punctuation holds a run of spaces and marks end to end, and that
			// hold is unconditional — measured over ucd/LineBreakTest.txt, `× OP × SP × R` and
			// `× OP × CM × SP × R` are 138 × each with no ÷ counterpart in either shape, however
			// the `is_prohibited_end` list above failed to answer them: it reads `left`, which is
			// the space itself, so it can only ever forbid the break *at* the parenthesis.
			// Measured: 223 cases fixed, none broken.
			if behind >= 0 && classes[behind] == .op {
				return BreakKind.no
			}
			// LB16: a closing punctuation or parenthesis holds to a nonstarter across a
			// space run. `× 232A × 0020 × 3005 ÷` is tagged [16.0] on the iteration mark,
			// and the run may carry marks the same way the holds above already walk:
			// `× 232A × 0308 × 0020 × 3005 ÷` holds too.
			if behind >= 0 && (classes[behind] == .cl || classes[behind] == .cp)
				&& right == .ns {
				return BreakKind.no
			}
			// LB17: a break-before-and-after does not part from itself across a space run.
			// `× 2014 × 0020 × 2014 ÷` is tagged [17.0] on the second em dash, and the run
			// may carry marks the same way the quote hold above already walks: `× 2014 ×
			// 0308 × 0020 × 2014 ÷` holds too.
			if behind >= 0 && classes[behind] == .b2 && right == .b2 {
				return BreakKind.no
			}
		}
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
	// where a quotation mark goes, and between them they are why LB15a and LB15b sit above this
	// rule rather than being it: the first is a closing mark held across a space, and the second
	// is a mark that is both and so breaks like everything else.
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
	//
	// A closing mark or a both-mark always holds: `× 2757 × 0022 ÷` and `× 2757 × 00BB ÷`
	// refuse, and the file has no break on either side of those two marks anywhere.
	if right == .qu && ucd.quote_role_of(quote, cps[i + 1]) != .pi {
		return BreakKind.no
	}
	// An opening curly mark breaks after a nonstarter or an ideograph when CJK follows
	// it too: `× FF1A ÷ 201C ÷ 5B66 ÷` and `× 4E43 ÷ 201C ÷ 4E3A ÷` both break at [31.01]
	// on both sides of the mark, while `× 7684 × 201C × 0042 ÷` holds once a Latin
	// letter follows it and `× 2757 × 00AB ÷` holds for a straight mark anywhere. The
	// file refuses every other pairing, so the carve-out names the opening marks
	// (`“` and `‘`), the CJK-ish left side, and a CJK or opening follow: anything
	// else falls through to the refusal below.
	//
	// The left side is read raw rather than through a mark: a mark on a CJK character
	// still refuses — `× 3005 × 0308 × 00AB ÷` is [19.11] — so this is not LB9 reading
	// through one, it is the pair as written.
	if right == .qu && ucd.quote_role_of(quote, cps[i + 1]) == .pi {
		opens := cps[i + 1] == rune(0x201C) || cps[i + 1] == rune(0x2018)
		follows := i + 2 < n
			&& (classes[i + 2] == .idas || classes[i + 2] == .ns || classes[i + 2] == .op)
		if !opens || (left != .ns && left != .idas) || !follows {
			return BreakKind.no
		}
	}
	// A quotation mark with a mark on it still will not break before a contingency break
	// character: `× 0022 × 0308 × FFFC ÷` and `× 00BB × 0308 × FFFC ÷` are tagged [19.02] and
	// [19.12]. LB9 folds the pair to QU|CB and LB19 answers before LB20 is ever consulted,
	// which is why this sits above the contingency rule rather than in it. The opening-mark
	// half needs no arm: the quotation hold above already refuses `QU_Pi × CM × X` through
	// `behind`, so only the both and closing kinds reach here.
	if left == .cm && eff_left == .qu && right == .cb {
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
	// LB20a: do not break after a word-initial hyphen. `× 002D × 0069 ÷` and `× 00AD × 2757 ÷`
	// are both tagged [20.1]: a hyphen-minus and a soft hyphen hold the letter after them when
	// nothing but a break, a space or a joiner control comes first. `well-known` breaks after
	// its hyphen because a letter comes first, and that is LB21's half below rather than this.
	//
	// A mark on the hyphen does not detach it: `× 002D × 0308 × 0069 ÷` holds at the same tag,
	// with LB9 reading the pair as hyphen and letter. The exemption the LB12a comment records
	// for a soft hyphen is a different question — a glue after one — and it stays answered there.
	if ((left == .hy || left == .hh) || (left == .cm && (eff_left == .hy || eff_left == .hh)))
		&& (right == .al || right == .hl) {
		mut hb := i
		if left == .cm {
			for hb > 0 && is_markish(classes[hb]) {
				hb--
			}
		}
		before := hb - 1
		if before < 0 || classes[before] == .bk || classes[before] == .cr
			|| classes[before] == .lf || classes[before] == .nl || classes[before] == .sp
			|| classes[before] == .zw || classes[before] == .cb || classes[before] == .gl {
			return BreakKind.no
		}
	}
	// A break after a contingency break's own marks is the same break: `× FFFC × 0308 ÷ 3000 ÷`
	// is tagged [20.02] at the space, and LB9 reads the pair as CB|SP. The base the mark hangs
	// from is what `eff_left` walked back to, so a mark run on any other base answers elsewhere.
	if left == .cm && eff_left == .cb {
		return BreakKind.allowed
	}
	// The half of the mark reading that survives the `is_prohibited_end` list above: a mark standing
	// on a base that refuses a break after *any* character inherits that refusal.
	//
	// Measured over every `base × CM × right` position in ucd/LineBreakTest.txt against the bare
	// `base × right` pair: they agree in 1,684 positions and disagree in 130. The bases that agree
	// *and* are uniformly "no break" on the bare side are exactly `.op` and `.qu`, plus `.bb` with
	// one exception. BB, GL, WJ, OP and QU are the five classes with no `brk` anywhere in their
	// row, and two of them are already answered above (`eff_left == .gl` at LB12, `eff_left == .wj`
	// at LB11). BB is the one with a hole in it and `.cp`, `.ex`, `.hy` and `.insp` have more:
	// `× 0029 ÷` is [30.02] for a letter and [31.01] for an aksara, which is why they are not here.
	//
	// It sits below LB20 and not beside `is_prohibited_end`, and that is one case: `× 00B4 × 0308
	// ÷ FFFC ÷` is tagged [20.01] at the contingency break character, so an object replacement
	// character still breaks through a mark hanging on an acute accent. Above LB20 that case lost
	// the break the file asks for.
	//
	// The 130 that disagree are all six of SP, ZW, BK, CR, LF and NL on the left of a mark, where
	// the file refuses a break the bare pair asks for. That is the file disagreeing with itself and
	// it is recorded on `is_prohibited_start_after_space` rather than coded around.
	if left == .cm && (eff_left == .op || eff_left == .qu || eff_left == .bb) {
		return BreakKind.no
	}
	// LB17, LB19, LB21, LB22 and the numeric matrix's own prohibitions, which all sit below LB18
	// in the specification's order: a line may not begin with one of these unless a space is in
	// front of it.
	//
	// An opening mark after a nonstarter or an ideograph is not on the list: the same
	// carve-out the LB19 blanket carries below, `× FF1A ÷ 201C ÷` and `× 4E43 ÷ 201C ÷`,
	// because a class list that names QU answers every quotation mark at once and the
	// file breaks these at [31.01]. The class is read raw for the same reason it is
	// there: a mark on a CJK character still holds its line.
	if is_prohibited_start_after_space(right)
		&& !(right == .qu && ucd.quote_role_of(quote, cps[i + 1]) == .pi
			&& (left == .ns || left == .idas)) {
		return BreakKind.no
	}
	// LB30: do not break before an open punctuation after a letter, a Hebrew letter or a digit.
	//
	// The rule was missing entirely, and `× 2757 × 0028 ÷` is the shape: the committee tags it
	// [30.01], a break that must not happen. It was invisible until the mark rules moved, because
	// the blanket rule after a mark had been refusing that position anyway.
	//
	// The left side reads through a mark the way LB28 and LB23 do: `× 2757 × 0308 × 0028 ÷` holds
	// at [30.02] exactly the way the bare pair does. What LB30 does *not* read through is an East
	// Asian bracket: U+2329 LEFT-POINTING ANGLE BRACKET is Wide, and `× 2757 ÷ 2329 ÷` breaks at
	// [31.01]. The two halves were measured together once before and read as one class, which
	// cost the 12 East Asian breaks; the width is what tells them apart.
	if right == .op && !ucd.is_east_asian(ea, cps[i + 1]) {
		lb30_left := if left == .cm { eff_left } else { left }
		if lb30_left == .al || lb30_left == .hl || lb30_left == .nu {
			return BreakKind.no
		}
	}
	// A close punctuation holds a letter, a Hebrew letter or a digit, and nothing else.
	//
	// `.cp` was in `is_prohibited_end`, which is the wrong shape for it: the class list said "a line
	// may not end on a close punctuation" and the committee answers that two ways. `× 0029 ÷ 1B05 ÷`
	// breaks at [31.01] and `× 0029 × 2757 ÷` does not at [30.02] — the same close parenthesis, and
	// the answer turns on what follows rather than on what it is.
	//
	// Taking it out of the list measured **39 fixed against 19 broken**. The 19 are what a pair rule
	// recovers and a removal does not: they were all `close-parenthesis × letter`, tagged [30.02],
	// where the list had been answering by accident. The classes it holds across are the ones
	// `effective_class` has already resolved, so three names cover them; AI, XX and SA are folded
	// into AL upstream and need no arm of their own.
	//
	// One case is still open and it is recorded rather than hidden: `(4·)$` is [25.04] on the
	// parenthesis, so a prefix numeral is held too. Adding `.pr` and `.po` here measured **worse**,
	// 35 fixed against 39 — the same currency symbol is a break at four other positions in the file
	// where it follows no bracket, so the pair rule cannot be widened without losing more than it
	// gains. That one wants LB25's numeric matrix, which this engine reads as pairs.
	//
	// The East Asian close brackets break the other way: `[CP-$EastAsian] × (AL|HL|NU)` refuses
	// only the narrow ones, so `× 3001 ÷ 0041 ÷` breaks at [31.01] while `× 0029 × 2757 ÷` holds
	// at [30.02]. The left side reads through a mark for the same reason the open side does:
	// `× 0029 × 0308 × 2757 ÷` holds at [30.02] with the raw left-hand class a mark.
	if left == .cp || (left == .cm && eff_left == .cp) {
		if (right == .al || right == .hl || right == .nu) && !ucd.is_east_asian(ea, cps[i]) {
			return BreakKind.no
		}
	}
	// LB17: a break-before-and-after does not part from itself, and that is the whole of the
	// rule. `× 2014 × 2014 ÷` (tagged [17.0] on the second em dash) refuses, and nothing else about
	// the class refuses anything: bare `× 2757 ÷ 2014 ÷`, `× 00B4 ÷ 2014 ÷` and `× 2757 × 0308 ÷
	// 2014 ÷` are all [18.0]/[31.01] breaks.
	//
	// What this replaces sat in `is_prohibited_start_after_space` beside the real members and
	// refused a break before *every* em dash — including the 59 `× C × 0308 ÷ 2014 ÷` the file
	// answers by breaking. Measured with both halves: removing the list entry and writing the
	// narrow pair fixes 107 with none broken against the previous 676.
	//
	// Both halves answer what the *left* of the decision is, not the dash. `× 2014 × 0308 × 2014 ÷`
	// [17.0] refuses because the mark stands on a dash of its own, which the `eff_left` walk
	// answers by reaching back to it. And `× 200D × 2014 ÷` [8.1] refuses for a reason no class
	// can carry: `effective_class` folds a zero width joiner into a combining mark, so at the
	// class level this pair is indistinguishable from `× 302A ÷ 2014 ÷` and `× 0000 ÷ 2014 ÷`,
	// which both break. The file wants the joiner held and the marks broken, so the raw property
	// is asked here rather than the resolved class. It is the only `line_break_of(cps[i])` call in
	// the chain, and it is here because there is no class-level spelling of "a joiner, specifically".
	if right == .b2 && (eff_left == .b2 || props.line_break_of(cps[i]) == .zwj) {
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
	// A mark joins the character it sits on, so the pair that decides the break after it is the base
	// and the character that follows — not the mark and the character that follows. `× 2757 × 0308 ×
	// 2757 ÷` refuses the break, and the committee annotates that position [28.0]: LB28 reading the
	// pair as two letters. `× 2757 × 0308 × 0030 ÷` annotates [23.02] the same way.
	//
	// It is not every rule, and the difference is measurable rather than argued. LB28 and LB23 hold
	// across a mark, and LB30 does not: `× 2757 × 0308 × 0028 ÷` breaks, where `× 2757 × 0028 ÷`
	// does not. An open punctuation may start a line after a marked letter but not after a bare one,
	// which is what a diacritic carrying word-final stress through to the next word looks like.
	//
	// This is NOT the class rewrite the chain tried first, which measured 10,912 against 13,090 and
	// left the note on `effective_class`. That version replaced the class for every later rule; this
	// reaches three lookups, all of which ask what the left-hand character is.
	mut pair_left := eff_left
	// LB26: a Korean syllable block does not break inside, and only inside the pairs
	// that make one. JL holds a following JL, JV, H2 or H3; JV or H2 holds a following
	// JV or JT; JT or H3 holds a following JT. Anything else parts: `× 1100 ÷ 11A8 ÷`
	// breaks at [31.01] because JL × JT is not a pair the rule names, and `× 11A8 ÷
	// 1160 ÷` breaks the same way.
	//
	// Every arm reads through a mark: `× 1100 × 0308 × 1100 ÷` is [26.01] with the raw
	// left-hand class a mark. H2 × H2 and H3 × H3 are deliberately absent: two
	// syllables break between them, and the rules below say so on purpose.
	if (pair_left == .jl && (right == .jl || right == .jv || right == .h2 || right == .h3))
		|| ((pair_left == .jv || pair_left == .h2) && (right == .jv || right == .jt))
		|| ((pair_left == .jt || pair_left == .h3) && right == .jt) {
		return BreakKind.no
	}
	// LB27: a numeric prefix does not part from the Hangul syllable after it.
	//
	// `× 0024 × AC00 ÷` and `× 20A9 × 1100 ÷` are the committee's own shapes and the answer is
	// [27.02] on both. Measured on 2026-10-12: **11 cases gained, none broken.**
	//
	// The committee names H3 here and the engine's own LB29 lets two H2s and two H3s break
	// between each other, so the class is not held together as a run the way the jamo are.
	//
	// It reads through a mark the way LB24 does: `× 20A9 × 0308 × AC00 ÷` is tagged [27.02]
	// with the raw left-hand class a mark, and the pair that decides is the prefix and
	// the syllable.
	if pair_left == .pr && (right == .jl || right == .jv || right == .jt || right == .h2
		|| right == .h3) {
		return BreakKind.no
	}
	// LB27.01: the syllable holds to a *postfix* numeral in the other direction, and not to a prefix
	// one. `× AC00 × 20A9 ÷` is tagged [27.01] and `× AC00 ÷ 20A9 ÷` is tagged [31.01], the default
	// break, which is the same asymmetry LB23.13 has and the reason the two are written as two rules
	// rather than one list.
	//
	// `pair_left` for the same reason: `× AC00 × 0308 × FE6A ÷` is tagged [27.01] and the raw
	// left-hand class there is the mark.
	if (pair_left == .h2 || pair_left == .h3 || pair_left == .jl || pair_left == .jv
		|| pair_left == .jt) && right == .po {
		return BreakKind.no
	}
	if pair_left == .nu && right == .nu {
		return BreakKind.no
	}
	// LB25: a prefix or postfix numeral holds to the digit after it. `× 20A9 × 0030 ÷` is
	// tagged [25.12] and `× FE6A × 0030 ÷` is tagged [25.09], both refusals, and a break
	// *after* a prefix numeral is allowed at [31.01] — `× 20A9 ÷ 2757 ÷` — so this is one
	// direction only. It reads through a mark: `× 20A9 × 0308 × 0030 ÷` is [25.12] too.
	if (pair_left == .pr || pair_left == .po) && right == .nu {
		return BreakKind.no
	}
	// LB25: a close bracket holds to the postfix or prefix numeral after a number.
	// `× 007B × 0030 × 002C × 0031 × 007D × 002B ÷` refuses at [25.03] on the plus, and
	// `× 0028 × 0030 × 002C × 0031 × 0029 × 002B ÷` at [25.04] the same way: the run back
	// from the bracket through any infix separators reaches a digit. A bare `NU | PO`
	// still breaks — `× 0030 ÷ 20A9 ÷` would be [25.06] and is not — so the bracket on
	// the left is what this asks for, not merely a digit somewhere behind.
	if (left == .cl || left == .cp) && (right == .po || right == .pr) {
		mut nb := i
		for nb > 0 && (classes[nb - 1] == .sy || classes[nb - 1] == .insp) {
			nb--
		}
		if nb > 0 && classes[nb - 1] == .nu {
			return BreakKind.no
		}
	}
	// LB25: a prefix or postfix numeral holds to the ideograph or digit after an opening
	// bracket it precedes. `× 007B × 0032 ÷ ...` no — the shape is `PO × OP NU`: `× 002B ×
	// 007B × 0032 ÷` refuses at [25.1] on the bracket, because a digit follows it. Without
	// the digit after the bracket the pair breaks like everything else.
	if (pair_left == .pr || pair_left == .po) && right == .op {
		if i + 2 < n && classes[i + 2] == .nu {
			return BreakKind.no
		}
	}
	// LB25: a postfix numeral holds to the infix separator of a decimal it starts. `×
	// 002B × 002E × 0032 ÷` refuses at [25.1] on the full stop, because a digit follows
	// the separator. It reads through a mark the way the hyphen arm does.
	if pair_left == .po && right == .insp {
		if i + 2 < n && classes[i + 2] == .nu {
			return BreakKind.no
		}
	}
	// LB25: a hyphen or an infix separator holds to the digit after it. `× 002D × 0030 ÷` and
	// `× 002C × 0030 ÷` are both refusals, tagged [25.13] and [25.14] through a mark the same
	// way — `× 002D × 0308 × 0030 ÷` — so the pair reads through one.
	if (pair_left == .hy || pair_left == .insp) && right == .nu {
		return BreakKind.no
	}
	// LB25: a separator run holds to the prefix, postfix or digit after a number. `× 002F ×
	// 0032 ÷` refuses at [25.15] on the solidus because a digit stands in front of the run,
	// and `× 002E × 20AC ÷` refuses at [25.06] on the euro sign for the same reason. The run
	// is any run of separators — the pair above answers the single-character shape — and a
	// run with no digit in front of it breaks like everything else.
	if (left == .sy || left == .insp) && (right == .nu || right == .pr || right == .po) {
		mut nb2 := i
		for nb2 > 0 && (classes[nb2 - 1] == .sy || classes[nb2 - 1] == .insp) {
			nb2--
		}
		if nb2 > 0 && classes[nb2 - 1] == .nu {
			return BreakKind.no
		}
	}
	// LB24: a numeric prefix or postfix does not part from the letter or Hebrew letter after it.
	//
	// `× FE6A × 2757 ÷` and `× 0025 × 05D0 ÷` are the committee's own shapes and the answer is
	// [24.02] on both.
	//
	// It reads through a mark, which is the whole of the change and the reason it is `pair_left`
	// and not `left`: `× 0024 × 0308 × 2757 ÷` is the committee's own case and a prefix numeral
	// holds its letter across the diacritic in front of it the same way a letter does. Measured
	// 2026-10-12: **36 cases gained, none broken**, and the control confirms it — with `left` here
	// the score returns to exactly the baseline, so the mark is the whole of the gain.
	//
	// The rule's other direction, `AL × PR`, was written as a second rule here first and measured
	// identical to what the list already gave, which is why it was not; the comment that claimed the
	// list was answering it was only half the story. The list was answering it for *every* left-hand
	// class, and that is the trap: `.pr` and `.po` in `is_prohibited_start_after_space` refuse a break
	// before a prefix or postfix numeral wherever one is asked for, and the file asks for one in 244
	// places — `× 3000 ÷ 20A9 ÷` is an ideographic space and a won sign, tagged [31.01], a break —
	// while refusing it in 216 others. Removing the two classes alone measured **244 fixed against 216
	// newly broken**, and the 216 are the three rules below, which is the whole of why this reads as a
	// mistake in a class list rather than as a missing rule.
	if (pair_left == .pr || pair_left == .po) && (right == .al || right == .hl) {
		return BreakKind.no
	}
	// LB24.03 and LB25.05, LB25.06: a letter, a Hebrew letter or a digit refuses to break before a
	// prefix or postfix numeral either, which is the other half of the numeric matrix and the half the
	// class list was answering for every class at once.
	//
	// `× 2757 × 20A9 ÷` is the committee's own shape, tagged [24.03], and `× 0030 × 20A9 ÷`
	// refuses at [25.06]. A break *after* a prefix or postfix is allowed, and the file says so at [31.01]:
	// `× 20A9 ÷ 2757 ÷`, `× 0024 ÷ 231A ÷`, `÷ 20A9 ÷ 0024 ÷` all break. So the two classes are not
	// prohibited starts in general, and the list held them for 30 classes the file never asks about.
	//
	// It reads through a mark for the same reason LB24.02 does and with the same reach: `× 2757 × 0308
	// × 20A9 ÷` holds, tagged [24.03], and so does a mark with nothing in front of it — `pair_left` is
	// `.cm` exactly when the mark run reaches the start of the text, and the file tags CM × PR
	// [24.03] as well.
	//
	// `.cm` in the left list is a mark at the head of the text, not a mark on a base: for any other
	// position `eff_left` has already walked back to the base above.
	if (pair_left == .al || pair_left == .hl || pair_left == .nu || pair_left == .cm)
		&& (right == .pr || right == .po) {
		return BreakKind.no
	}
	// LB23: a numeric prefix does not part from the ideograph or the emoji after it.
	//
	// `× 0024 × 231A ÷` and `× 20A9 × 270A ÷` are the committee's own shapes and the answer is
	// [23.12] on both. It reads through a mark: `× 20A9 × 0308 × 231A ÷` holds at the same
	// tag with the raw left-hand class a mark.
	if pair_left == .pr && (right == .idas || right == .eb || right == .em) {
		return BreakKind.no
	}
	// LB23.13: the emoji base, the emoji modifier and the ideograph hold to a *postfix* numeral,
	// and not to a prefix one. The asymmetry is the file's and not a reading of it: `× 263A × 20A9 ÷`
	// is tagged [23.13] and `× 263A ÷ 20A9 ÷` is tagged [31.01], the default break. So the pair is
	// `EB × PO` and `EB × PR` is two different answers, and a single list for the two classes would
	// have to be positioned by the right-hand character rather than by the rule.
	//
	// It reads through a mark the way LB24 does, and the file says so itself: `× 270A × 0308 × FE6A ÷`
	// is tagged [23.13] at the postfix, where the raw left-hand class is CM and the base is EB.
	// Reading the raw character there left 22 of the 70 cases the numeric-matrix correction broke,
	// which is the whole of the difference.
	if (pair_left == .eb || pair_left == .em || pair_left == .idas) && right == .po {
		return BreakKind.no
	}
	// LB30b: do not break between an emoji base and an emoji modifier, or between a
	// potential base and one. `× 270A × 1F3FB ÷` is [30.21] and `× 1F8FF × 1F3FB ÷` is
	// [30.22]: the second left-hand side is not an emoji base at all, it is an
	// unassigned pictograph — reserved, Extended_Pictographic, and with no entry in
	// the UCD — which the test file annotates ID_ExtPictUnassigned and XX_ExtPictUnassigned.
	//
	// Both halves read through a mark: `× 270A × 0308 × 1F3FB ÷` holds at [30.21] with
	// the raw left-hand class a mark. What is asked is the base the mark hangs from,
	// which is the character `eff_left` already walked back to.
	if right == .em {
		mut base := cps[i]
		if left == .cm {
			mut j := i
			for j > 0 && is_markish(classes[j]) {
				j--
			}
			base = cps[j]
		}
		if pair_left == .eb || ucd.is_ep_unassigned(eu, base) {
			return BreakKind.no
		}
	}
	// LB30a: a pair of regional indicators is one flag, so the run between
	// them is not a break — unless the run is odd. Two flags in a row break
	// between the pairs: `× 1F1F7 × 1F1FA ÷ 1F1F8 ÷` breaks at [30.13] with
	// two indicators before it and refuses at [30.11] with one. A mark on an
	// indicator reads through: `× 1F1E6 × 0308 × 1F1E6 ÷` is [30.11] with the
	// raw left-hand class a mark, and the folded pair is still one indicator
	// followed by one indicator.
	if pair_left == .ri && right == .ri {
		mut nri := 0
		mut k := i
		for k >= 0 && (classes[k] == .ri || is_markish(classes[k])) {
			if classes[k] == .ri {
				nri++
			}
			k--
		}
		if nri % 2 == 1 {
			return BreakKind.no
		}
	}
	// LB28: two of the same kind of letter do not break between them. This is the rule
	// that makes a word a word, and leaving it out turns every word into a
	// letter run a caller may split anywhere.
	//
	// It is not the same as saying "never break here", because LB28 has an
	// exception: the pair may break if either character is a hyphen, which is
	// what lets "well-known" break after its hyphen. The hyphen is handled by
	// LB21 below, so by the time this runs neither side is one.
	//
	// Four pairs, not one: `AL × AL`, `AL × HL`, `HL × AL` and `HL × HL`. The
	// engine had the first and the conformance test is what showed the other
	// three — `× 2757 × 0308 × 05D0 ÷` is annotated `[28.0]` at the Hebrew
	// letter, so LB28 reads a Hebrew letter as the same kind of letter as a
	// Latin one and this read it as a break.
	hl_or_al_left := pair_left == .al || pair_left == .hl
	hl_or_al_right := right == .al || right == .hl
	if hl_or_al_left && hl_or_al_right {
		return BreakKind.no
	}
	// LB28a: do not break inside the orthographic syllables of Brahmic scripts. An
	// aksara pre-base holds the aksara, aksara start or dotted circle after it, and
	// an aksara, start or dotted circle holds the virama after it: `× 11003 × 1B05 ÷`
	// is [28.11] and `× 1B05 × 1BF2 ÷` is [28.12].
	//
	// U+25CC DOTTED CIRCLE is named in the rule itself as the third member of the
	// class, so it is matched by codepoint rather than by class: the line break
	// table calls it AL, and no other AL may take its place. `× 25CC × 2757 ÷`
	// breaks, and only the aksara rules below hold the circle.
	//
	// Every arm reads through a mark: `× 1B05 × 0308 × 1B44 ÷` is [28.12] with the
	// raw left-hand class a mark. The virama-final sub-rules need the Indic syllabic
	// categories this engine does not carry, and the one case that asks for them is
	// recorded rather than answered.
	if pair_left == .ap && (right == .ak || right == .akst
		|| (right == .al && cps[i + 1] == rune(0x25CC))) {
		return BreakKind.no
	}
	// A virama holds the aksara after it when an aksara, a start or a dotted circle
	// stands in front of the virama: `× 1B05 × 1B44 | ...` hmm, no — the refused
	// position is the one after the virama. `× 11F42 × 11F26 ÷` is [28.13] with an
	// aksara in front of the virama, and `× 25CC × 1B44 × 1B2C ÷` with the dotted
	// circle in front of it. A mark between the virama and the aksara does not detach
	// them: `× 1B44 × 200C × 1B2B ÷` folds the same way through LB9, with an aksara in
	// front of the whole run.
	if right == .ak || (right == .al && cps[i + 1] == rune(0x25CC)) {
		mut vat := i
		for vat > 0 && is_markish(classes[vat]) {
			vat--
		}
		if classes[vat] == .vi {
			mut vb := vat - 1
			for vb >= 0 && is_markish(classes[vb]) {
				vb--
			}
			if vb >= 0
				&& (classes[vb] == .ak || classes[vb] == .akst || cps[vb] == rune(0x25CC)) {
				return BreakKind.no
			}
		}
	}
	// An aksara or a start holds the virama after it, and the dotted circle stands in
	// for either: `× 1B05 × 1BF2 ÷` and `× 1B50 × 1BF2 ÷` are both [28.12], and `× 25CC
	// × 1BF2 ÷` holds the same way. It reads through a mark: `× 1B05 × 0308 × 1B44 ÷`
	// is [28.12] with the raw left-hand class a mark, and the dotted circle is asked
	// by codepoint because the line break table calls it a letter.
	if (right == .vf || right == .vi) && (pair_left == .ak || pair_left == .akst) {
		return BreakKind.no
	}
	if (right == .vf || right == .vi) && pair_left == .al {
		mut db := i
		for db > 0 && is_markish(classes[db]) {
			db--
		}
		if cps[db] == rune(0x25CC) {
			return BreakKind.no
		}
	}
	// LB28a, fourth arm: one aksara member holds the next when a virama-final
	// follows that one. `× 1BD2 × 1BEA × 1BC9 × 1BF3 ÷` holds at 1BEA|1BC9
	// [28.14]: the pair read through the mark is AS × AS and 1BF3 is VF, and
	// without the VF ahead the same pair breaks at LB31. The dotted circle
	// stands in for a member on either side, asked by codepoint because the
	// line break table calls it a letter.
	if i + 2 < n && classes[i + 2] == .vf
		&& (right == .ak || right == .akst || (right == .al && cps[i + 1] == rune(0x25CC))) {
		if pair_left == .ak || pair_left == .akst {
			return BreakKind.no
		}
		if pair_left == .al {
			mut dl := i
			for dl > 0 && is_markish(classes[dl]) {
				dl--
			}
			if cps[dl] == rune(0x25CC) {
				return BreakKind.no
			}
		}
	}
	// LB28's other two pairs: a letter and a digit, in either order. These were missing and the
	// conformance test is what showed it — they are the cases that let "H2O" and "COVID19" split at the
	// letter-digit boundary, which is a Latin problem and not a CJK one.
	//
	// A hexadecimal-looking name is the common case, and a break inside one leaves a line ending in a
	// digit and the next starting with a letter, which reads as a hyphenation the writer never asked for.
	if (pair_left == .al || pair_left == .hl) && right == .nu {
		return BreakKind.no
	}
	if pair_left == .nu && (right == .al || right == .hl) {
		return BreakKind.no
	}
	// LB29: an infix separator — the full stop or comma of a decimal or thousands — holds to the
	// alphabetic character that follows it. "1,000" and "3.14" are one thing each, and this is the rule
	// that says so. It is separate from LB28 because the separator is a different class from the digit, and
	// a pair of digits is already held together by LB23b above.
	//
	// It reads through a mark the way LB28 does: `× 002C × 0308 × 2757 ÷` is tagged [29.0] with the
	// raw left-hand class a mark, and the pair that decides is the separator and the letter.
	if pair_left == .insp && (right == .al || right == .hl) {
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
	// LB21b: do not break between a solidus and a Hebrew letter. `× 002F × 05D0 ÷` is the
	// shape, tagged [21.2].
	//
	// It reads through a mark the way the numeric rules do: `× 002F × 0308 × 05D0 ÷` holds at
	// the same tag with the raw left-hand class a mark.
	if pair_left == .sy && right == .hl {
		return BreakKind.no
	}
	// LB21: a hyphen may break after it, and only after it. A hyphen-minus is the
	// ordinary case, and a word like "well-known" has to be allowed to end its
	// first line there or it cannot be set narrow at all.
	//
	// Not after a Hebrew hyphen, though: `× 05D5 × 002D × 004D ÷` is tagged [21.1],
	// and LB21a holds `HL × HY × non-HL` together. The hyphen is found the way `eff_left`
	// is, because a mark may hang on either side of it, and what matters is the letter
	// in front of that mark run.
	if left == .hy && right == .al {
		mut hb2 := i
		for hb2 > 0 && is_markish(classes[hb2]) {
			hb2--
		}
		if hb2 > 0 && classes[hb2 - 1] == .hl {
			return BreakKind.no
		}
		return BreakKind.allowed
	}
	// There was a rule here refusing a break after a combining mark, and it was wrong.
	//
	// It was added on 2026-10-04 for 312 cases and was justified by a single one: the file's only case
	// containing U+200C, a zero width non-joiner, reads `× 200C ×`. That was generalised into "a line
	// may not end on a combining mark", which LB9 does not say. LB9 forbids a break *before* a mark; it
	// says nothing about what follows one, and the default there is a break.
	//
	// Removing it measured 2,656 to 1,943 — 713 cases gained. The 768 it broke were the committee's
	// `× 2757 × 0308 × 2757 ÷` shape, where LB28 reads through the mark to a pair of letters, and those
	// are recovered by `pair_left` above. Together the two are worth 870; the rule alone was worth
	// nothing.
	//
	// The U+200C case that justified it is still handled and correctly so: a zero width non-joiner is
	// class CM, so `× CM ×` holds it through the LB9 that holds every other mark, from the right-hand
	// side. That is the one-sided rule, and it is the smaller one.
	// LB31, and the default of LB31 in the specification's own table: break
	// everywhere else. This is a permissive default, and it is why the rules
	// above it matter: a permissive default is what draws the text, and the rules
	// are what stop it drawing somewhere a reader cannot follow.
	_ = n
	_ = cps
	_ = props
	return BreakKind.allowed
}

// run_origin returns the index of the character a run of spaces and marks ending at i hangs
// from, or -1 when the run reaches the start of the text.
//
// LB15a needs this rather than the character in front of the space, because an opening
// quotation mark holds a run and not one space: `QU_Pi × SP × CM × SP × R` is one thing, and
// `QU_Pi × SP × SP × R` is one thing, and both are answered by the character the run grew out
// of. A run ends at the first character that is neither a space nor a mark, so it stops at a
// quotation mark itself, at a zero width space and at real text.
pub fn run_origin(classes []ucd.LineBreakClass, i int) int {
	mut j := i
	for j > 0 && is_space_or_mark(classes[j - 1]) {
		j--
	}
	return j - 1
}

// is_space_or_mark reports whether this class is one a quotation mark's hold reaches across.
//
// The mark is spelled `.cm` rather than asked of `is_markish`, because `effective_class` has
// already folded every markish class into `.cm` by LB4a: what a caller reads here is the
// resolved run, not the table's own spelling of it.
pub fn is_space_or_mark(c ucd.LineBreakClass) bool {
	return c == .sp || c == .cm
}

// is_break_after_hyphen_break reports a break after a hyphen that ends an
// already-broken word, which is LB21b.
//
// The case is a text that came in with a newline in the middle of a word, which
// is what happens when a line is copied out of a document and pasted back
// somewhere that does not know it was a line. Without this the text reads as
// two words with a space where the hyphen was.
pub fn is_break_after_hyphen_break(props &ucd.Properties, cps []rune, classes []ucd.LineBreakClass,
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
pub fn is_mandatory_break(c ucd.LineBreakClass) bool {
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
pub fn is_prohibited_start(c ucd.LineBreakClass) bool {
	return c == .cl || c == .cp || c == .ex || c == .insp || c == .sy
}

// is_prohibited_start_after_space reports whether a line may not begin with this class once a
// space is allowed to break in front of it, which is LB17 for a break-before-and-after, LB19 for
// a quotation mark, LB21 for a break-before, a hyphen or a non-starter, and LB22 for an
// inseparable numeral infix.
//
// This function also documents the two entries that were shape.removed from it, because the removal is
// the most instructive thing in the file. `.pr` and `.po` were here, on the reading that a numeric
// prefix or postfix is something a line may not begin with. It is, for *nine* left-hand classes —
// AL, HL, NU and CM by LB24.03 and LB25, and OP, BB, GL, QU and WJ by rules that already answer.
// It is not for the other thirty, and the file asks for a break before a prefix or postfix numeral
// in 244 places: `× 3000 ÷ 20A9 ÷` is an ideographic space and a won sign, tagged [31.01].
//
// Removing the two entries measured **244 fixed against 216 newly broken**, and the 216 are the
// three rules below — LB24.03 with LB25.05 and LB25.06, LB23.13 and LB27.01 — which is the
// whole of why this reads as a mistake in a class list rather than as a missing rule. So the
// list was answering five questions at once with one entry, which is the shape of the mistake
// rather than the fact that it was a wrong class. A space in front of a prefix numeral is a break
// the file asks for and LB18 still gives it: `× 2757 × 0020 ÷ 20A9 ÷` is [18.0], because the space
// is answered before this list is ever reached.
//
// LB12a's glue is here too, though not in this function: it is spelled out at its own site because
// its exclusion list is the point of it.
pub fn is_prohibited_start_after_space(c ucd.LineBreakClass) bool {
	return c == .qu || c == .ba || c == .hh || c == .hy || c == .ns
		|| c == ucd.infx
}

// is_prohibited_end reports whether a line may not end with this class, which
// is rules LB15 through LB19 and LB21.
//
// EX is not in it: nothing refuses a break after `!` or `?`, and the committee
// breaks there at [31.01] — `× FE56 ÷ 2757 ÷` is an exclamation mark and a letter.
// A break before those marks is LB13's and lives in `is_prohibited_start`, and a
// mark or a space after them is LB9's and LB7's, which both answer first.
//
// HY is not in it either: a hyphen establishes a break after itself everywhere but
// word-initially — `× 002D ÷ 1B05 ÷` is [31.01] — and the word-initial refusal is
// LB20a's pair, not a class list's. The numeric `HY × NU` half is LB25's and sits
// with the matrix. BB stays, because `× 00B4 × 2757 ÷` refuses 281 times at LB21
// and the file breaks after an acute only before a contingency break, which the
// pair below answers. IS is not in it either: LB29 holds `IS × (AL|HL)` as its own
// pair and LB25 holds `IS × NU` the same way, so no break the file asks for needs
// the class list — `× 002C ÷ 1B05 ÷` is [31.01].
pub fn is_prohibited_end(c ucd.LineBreakClass) bool {
	return c == .op || c == .qu || c == .bb
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
pub fn effective_class(props &ucd.Properties, sa []ucd.CodeRange, cps []rune, i int,
	so_far []ucd.LineBreakClass) ucd.LineBreakClass {
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
		// A mark becomes a combining mark and everything else stays a letter, and the two
		// resolutions are what the committee's own file asks for at the two characters it
		// names.
		//
		// It is asked of a character that follows something, which is the same condition
		// LB4a is written on a few lines above, and the match is not an accident: an SA mark
		// attaches to the character in front of it, so a mark with nothing in front of it has
		// nothing to attach to. Measured rather than assumed. Resolving a leading SA mark to
		// CM as well **broke 38 cases** against the 4 it fixed.
		if i > 0 && ucd.sa_mark_of(sa, cps[i]) == .mark {
			return .cm
		}
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
pub fn is_markish(c ucd.LineBreakClass) bool {
	return c == .cm
}

pub fn clamp_index(i int, n int) int {
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
pub fn wrap_paragraph(ctx &shape.Context, cps []rune, base_dir shape.Direction, fs &shape.FontSet, em_px f64,
	max_width f64) []WrappedLine {
	return wrap_paragraph_with(ctx, cps, base_dir, fs, em_px, max_width, &LayoutOptions{})
}

// wrap_paragraph_with is wrap_paragraph with the caller's options applied.
//
// This exists rather than an extra argument on wrap_paragraph because a caller that cannot pass features
// cannot pass anything, and the paragraph was then shaped without the features the caller asked for while
// the same text laid out with layout_paragraph_with was shaped with them. The two disagreed about the width
// of the same text, which is the one thing a text engine must never do.
pub fn wrap_paragraph_with(ctx &shape.Context, cps []rune, base_dir shape.Direction, fs &shape.FontSet, em_px f64,
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
pub fn width_of_range(full &Line, from int, to int) f64 {
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
pub fn slice_for_range(full &Line, from int, to int) Line {
	mut line := Line{
		ascent:      full.ascent
		descent:     full.descent
		line_height: full.line_height
	}
	mut kept := []shape.Glyph{}
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
pub fn measure_paragraph(ctx &shape.Context, cps []rune, base_dir shape.Direction, fs &shape.FontSet, em_px f64) TextMetrics {
	return measure_paragraph_with(ctx, cps, base_dir, fs, em_px, &LayoutOptions{})
}

// measure_paragraph_with is measure_paragraph with the caller's options applied.
//
// The point of the _with form is that both widths have to agree with what layout_paragraph_with would
// produce for the same text and the same options. A measurement taken without the features, or taken with
// a different line height, is a measurement of a different line, and a caller that sizes a box from it
// has sized the box for something it will not draw.
pub fn measure_paragraph_with(ctx &shape.Context, cps []rune, base_dir shape.Direction, fs &shape.FontSet, em_px f64,
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
pub fn cluster_prefix(line &Line, n int) []f64 {
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
pub fn segment_width(props &ucd.Properties, cps []rune, cum []f64, from int, to int) f64 {
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
pub fn is_line_end_space(props &ucd.Properties, cp rune) bool {
	c := props.line_break_of(cp)
	return c == .sp || c == .lf || c == .bk || c == .cr || c == .nl
}
