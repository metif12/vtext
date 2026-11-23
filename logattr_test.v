module harfara

import harfara.layout
import harfara.shape

// Tests for the PangoLogAttr surface in layout/logattr.v: one attribute set
// per boundary, decided by the same engines the conformance floors pin.
// Word-break, sentence-break and grapheme engines are covered by their own
// floors; what is pinned here is the combination: word runs, deletion spans,
// whitespace flags and the line-break agreement.

// logattr_ctx builds a shaping context for the engines the pass reads.
fn logattr_ctx() &shape.Context {
	return shape.new_context()
}

// la_starts collects the boundaries flagged as word starts.
fn la_starts(attrs []layout.LogAttr) []int {
	mut out := []int{}
	for i, a in attrs {
		if a.is_word_start {
			out << i
		}
	}
	return out
}

// la_ends collects the boundaries flagged as word ends.
fn la_ends(attrs []layout.LogAttr) []int {
	mut out := []int{}
	for i, a in attrs {
		if a.is_word_end {
			out << i
		}
	}
	return out
}

// la_sentences collects the sentence boundaries.
fn la_sentences(attrs []layout.LogAttr) []int {
	mut out := []int{}
	for i, a in attrs {
		if a.is_sentence_boundary {
			out << i
		}
	}
	return out
}

fn test_logattr_word_runs_on_plain_text() {
	ctx := logattr_ctx()
	attrs := layout.log_attrs(ctx, 'hello world'.runes())
	assert attrs.len == 12, 'one entry per boundary, got ${attrs.len}'
	assert la_starts(attrs) == [0, 6], 'words start at h and w, got ${la_starts(attrs)}'
	assert la_ends(attrs) == [5, 11], 'words end after o and d, got ${la_ends(attrs)}'
	assert la_sentences(attrs) == [0, 11], 'one sentence edge to edge, got ${la_sentences(attrs)}'
	for i, a in attrs {
		assert a.is_char_break, 'plain ASCII breaks everywhere, boundary ${i} does not'
		assert a.is_cursor_position == a.is_char_break, 'cursor follows graphemes'
		assert !a.is_white || i == 5, 'only the space is white, boundary ${i} claims otherwise'
		want_del := if i == 0 { 0 } else { 1 }
		assert a.backspace_deletes == want_del, 'plain text deletes one rune, boundary ${i} deletes ${a.backspace_deletes}'
	}
}

fn test_logattr_double_space_starts_no_word() {
	// A naive "every word break starts a word" implementation flags both
	// spaces. The segment test exists to fail exactly that: neither space
	// holds a word character, so neither starts one.
	ctx := logattr_ctx()
	attrs := layout.log_attrs(ctx, 'a  b'.runes())
	assert la_starts(attrs) == [0, 3], 'words start at a and b, got ${la_starts(attrs)}'
	assert la_ends(attrs) == [1, 4], 'words end after a and b, got ${la_ends(attrs)}'
	assert attrs[1].is_white && attrs[2].is_white, 'both spaces are white'
	assert !attrs[0].is_white && !attrs[3].is_white, 'letters are not white'
}

fn test_logattr_combining_mark_deletes_with_its_base() {
	ctx := logattr_ctx()
	attrs := layout.log_attrs(ctx, [rune(0x0061), rune(0x0308), rune(0x0062)])
	assert attrs.len == 4, 'one entry per boundary, got ${attrs.len}'
	assert !attrs[1].is_char_break, 'a holds its mark: no boundary between them'
	assert attrs[2].is_char_break, 'the mark parts from what follows it'
	assert attrs[2].backspace_deletes == 2, 'backspace at b takes mark and base, takes ${attrs[2].backspace_deletes}'
	assert attrs[3].backspace_deletes == 1, 'backspace at the end takes b'
	assert attrs[0].backspace_deletes == 0, 'nothing to delete at the start'
}

fn test_logattr_sentence_edges() {
	ctx := logattr_ctx()
	attrs := layout.log_attrs(ctx, 'Hi. You.'.runes())
	assert la_sentences(attrs) == [0, 4, 8], 'sentences break after the space, got ${la_sentences(attrs)}'
	assert la_starts(attrs) == [0, 4], 'Hi and You start words, got ${la_starts(attrs)}'
}

fn test_logattr_line_breaks_agree_with_the_wrap_engine() {
	// The line flags are the wrap engine's own opportunities, not a second
	// implementation: every mandatory break is a line break, and a soft
	// break inside a word is not reported where the wrapper finds none.
	ctx := logattr_ctx()
	cps := 'aa bb cc'.runes()
	attrs := layout.log_attrs(ctx, cps)
	ops := layout.break_opportunities(ctx, cps, true)
	mut soft := map[int]bool{}
	mut hard := map[int]bool{}
	for o in ops {
		soft[o.start] = true
		if o.is_mandatory {
			hard[o.start] = true
		}
	}
	for i, a in attrs {
		assert a.is_line_break == (i in soft), 'line flag disagrees at ${i}'
		assert a.is_mandatory_break == (i in hard), 'mandatory flag disagrees at ${i}'
	}
}
