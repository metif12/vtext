module layout

import vtext.shape
import vtext.ucd

// Log attributes over a laid-out line: the PangoLogAttr surface editors
// need. Cursor movement, word runs and deletion spans all read these rather
// than re-running the boundary rules, and every flag below is decided by the
// same engines the conformance floors pin (word and sentence in
// textbreaks.v, graphemes in graphemes.v, lines in break_opportunities).
//
// One entry per boundary: entry i describes the boundary before cps[i], and
// entry cps.len the end of the text — the same indexing the break engines
// use, so a caller walks text and attributes together.

// LogAttr is the per-boundary attribute set.
pub struct LogAttr {
pub:
	// is_line_break reports a UAX #14 opportunity here (soft or hard).
	is_line_break bool
	// is_mandatory_break reports a hard break here: a paragraph end or
	// newline, not a mere opportunity.
	is_mandatory_break bool
	// is_char_break reports a grapheme cluster boundary here: a cursor can
	// go here, and backspace stops here.
	is_char_break bool
	// is_cursor_position matches is_char_break. Pango reports both flags;
	// this engine moves by graphemes everywhere, so the two agree by
	// construction.
	is_cursor_position bool
	// is_white reports that cps[i] is white space (false at the end of
	// the text, which names no character).
	is_white bool
	// is_word_start reports that a word begins at cps[i]: the segment
	// starting here holds a word character.
	is_word_start bool
	// is_word_end reports that a word ends before cps[i]: the segment
	// ending here holds a word character.
	is_word_end bool
	// is_sentence_boundary reports a UAX #29 sentence break here,
	// including both ends of the text.
	is_sentence_boundary bool
	// backspace_deletes reports how many runes backspace consumes at this
	// boundary: the grapheme cluster ending here, so a combining mark
	// deletes with its base. Zero at the start of the text.
	backspace_deletes int
}

// is_logattr_word_char reports whether a word-break class counts as a word
// character for word runs: letters, numbers, katakana, ExtendNumLet and
// regional indicators. Punctuation, spaces and emoji modifiers are not
// words on their own — a lone mark rides the segment it sits in.
fn is_logattr_word_char(c ucd.WordBreakClass) bool {
	return c == .aletter || c == .hebrew_letter || c == .numeric || c == .katakana
		|| c == .extendnumlet || c == .regional_indicator
}

// word_segment_is_word reports whether the segment cps[from..to] holds a
// word: at least one word character. Spaces, punctuation-only runs and lone
// marks are segments but not words, which is what keeps "a  b" from
// starting a word at either space.
fn word_segment_is_word(cls []ucd.WordBreakClass, from int, to int) bool {
	for k in from .. to {
		if is_logattr_word_char(cls[k]) {
			return true
		}
	}
	return false
}

// log_attrs answers one LogAttr per boundary of cps: indexes 0..cps.len,
// where entry i describes the boundary before cps[i].
pub fn log_attrs(ctx &shape.Context, cps []rune) []LogAttr {
	n := cps.len
	wt := word_tables()
	mut wcls := []ucd.WordBreakClass{len: n}
	for i, cp in cps {
		wcls[i] = wb_class_of(wt, WordOpts{}, cp)
	}
	wb := word_breaks(cps, wt, WordOpts{})
	st := sentence_tables()
	sb := sentence_breaks(cps, st, SentenceOpts{})
	gb := grapheme_breaks(ctx, cps, GraphemeOpts{})
	ws := ucd.white_space_ranges()
	ops := break_opportunities(ctx, cps, true)
	mut line_at := map[int]bool{}
	mut hard_at := map[int]bool{}
	for o in ops {
		line_at[o.start] = true
		if o.is_mandatory {
			hard_at[o.start] = true
		}
	}
	// Word segments are the runs between word breaks; a segment is a word
	// when it holds a word character.
	mut seg_word := map[int]bool{}
	mut seg_of := []int{len: n + 1}
	mut from := 0
	for i in 1 .. n + 1 {
		if wb[i] {
			seg_word[from] = word_segment_is_word(wcls, from, i)
			for k in from .. i {
				seg_of[k] = from
			}
			from = i
		}
	}
	seg_of[n] = from
	mut out := []LogAttr{len: n + 1}
	for i in 0 .. n + 1 {
		starts := i < n && seg_word[i]
		ends := i > 0 && wb[i] && word_segment_is_word(wcls, seg_of[i - 1], i)
		// The end of the text closes whatever segment runs into it: the
		// last break is eot itself, which word_breaks always reports.
		white := i < n && ucd.is_white_space(ws, cps[i])
		mut del := 0
		if i > 0 {
			mut j := i - 1
			for j > 0 && !gb[j] {
				j--
			}
			del = i - j
		}
		out[i] = LogAttr{
			is_line_break:        i in line_at
			is_mandatory_break:   i in hard_at
			is_char_break:        gb[i]
			is_cursor_position:   gb[i]
			is_white:             white
			is_word_start:        starts
			is_word_end:          ends
			is_sentence_boundary: sb[i]
			backspace_deletes:    del
		}
	}
	return out
}
