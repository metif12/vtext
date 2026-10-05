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
	if left == .sp || left == .bk {
		// LB7: break after a space.
		return BreakKind.allowed
	}
	if right == .sp {
		// LB7, again from the other side: a space is not allowed to end a line
		// on its own, and the break goes after it rather than before.
		return BreakKind.no
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
	// LB12: glue is not a break either. It is a letter's way of saying that what is on either side
	// of it belongs together, which is what a zero width space inside a word means and what a
	// joining control sequence leaves behind.
	if left == .gl || right == .gl {
		return BreakKind.no
	}
	if is_prohibited_start(right) {
		// LB8 through LB14, LB21b: the right-hand character may not start a line.
		return BreakKind.no
	}
	if is_prohibited_end(left) {
		// LB15 through LB19, LB21: the left-hand character may not end a line.
		return BreakKind.no
	}
	// LB20: a run of spaces, where only the last of them is a break and the rest
	// are glued to it. LB18 already forbids a space ending a line, so reaching
	// here with a space on the left is only possible through a class the pairs
	// treated as a space.
	if left == .sp {
		return BreakKind.allowed
	}
	// LB23a and LB23b: two of the same class that must not be split, which is
	// Hangul syllables and a numeric run's own continuation. They come before
	// LB28 so that a run of numbers stays whole when the class says so.
	if left == .jl || left == .jv || left == .jt {
		if right == .jl || right == .jv || right == .jt {
			return BreakKind.no
		}
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
	// LB9: a combining mark takes the behaviour of the character before it, so a run of them
	// cannot be split from their base and behaves as the base does.
	//
	// This is what glues an accent to its letter and a zero width non-joiner to the Persian letter
	// in front of it. It glues one side only, which is deliberate: the mark belongs to what comes
	// before it, and a line may still end between the mark and what follows. A caller who needs
	// both sides held together wants a word joiner, not a combining mark.
	if is_markish(right) {
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

// is_prohibited_start reports whether a line may not begin with this class,
// which is rules LB8 through LB14 and LB21b.
//
// The inseparable class is spelled .insp here because .is is a V keyword, and
// it matters: a character that cannot be separated from its neighbour is the one
// case where a break on either side would put two marks on different lines.
//
// The ambiguous class is not here. LB17a forbids a break before it, but only
// under the resolved level, which this library does not carry a level for, and
// treating it as forbidden would stop a line breaking before an em dash in a
// language that does not use them to divide words.
fn is_prohibited_start(c LineBreakClass) bool {
	return c == .cl || c == .cp || c == .ex || c == .insp || c == .sy || c == .ns || c == .bb
		|| c == .po || c == .pr || c == .hy || c == .qu || c == .b2
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
	// The resolution of an ambiguous character, which is what UAX#14 calls AI. The table names it as a
	// class of its own and no rule matches it, so an ambiguous character fell through to the permissive
	// default at the end of the chain and broke away from its neighbours on both sides — which is why the
	// conformance score was 67.5% and the first eight failures were all ambiguous characters.
	//
	// The default resolution is to a letter. An ambiguous character is one whose width depends on the
	// script it is rendered as, and UAX#14 resolves it to a letter unless the text is being treated as
	// East Asian, which this engine has no mode for. Resolving it to a letter is what makes LB28 hold
	// across it, so two of them stay together instead of each breaking away.
	if raw == .ai {
		return .al
	}
	return raw
}

// is_markish reports whether a class is one of the mark classes LB4a folds into
// a combining mark.
//
// The list is the classes this library's generated table actually names. UAX#14
// also folds in the ones called aksara and virama in older versions of the
// table, which are .ak and .vi here, so a Devanagari cluster is treated as one
// unit by the same rule as a Latin letter with an accent on it.
fn is_markish(c LineBreakClass) bool {
	return c == .cm || c == .ak || c == .ap || c == .vi || c == .idcj || c == .h2 || c == .h3
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
