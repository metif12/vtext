module vtext

import os
import vtext.shape
import vtext.layout

// Phase 8.4: wrap modes, ellipsize, tabs.
//
// WrapMode threads through wrap_paragraph_with and wrap_paragraph_with_policy
// alike: word breaks only at the policy's opportunities (all prior behavior),
// char between any two characters, word_char at word breaks with overlong
// words split between characters. Hyphenation lives in word mode only — char
// and word_char strip hyphen points — and a set with no ellipsis glyph
// ellipsizes nothing, the way a set with no hyphen glyph hyphenates nothing.
//
// Measured on FiraCode-Variable (fontTools, default instance, upm 2000):
// every advance below is 1200 units, 19.2 px at 32 px. The gids are the
// font's own: a 136, b 148, hyphen 1056, ellipsis (U+2026) 1000, and a tab
// has no cmap entry so it draws .notdef (gid 0, 1200 units).
//
// Self-contained: every helper here is this file's own, because `v test`
// compiles one file and not its neighbours.

// e84_approx reports whether two pixel measurements agree to within tol.
// Advances come out of a scale from font units, so an exact compare is the
// wrong test.
fn e84_approx(got f64, want f64, tol f64) bool {
	d := got - want
	return d > -tol && d < tol
}

// e84_font loads the face every pin is measured on. It is committed under
// testdata/fonts, so a miss is a failure rather than a skip.
fn e84_font() &shape.Font {
	return shape.load_font_file(os.join_path('testdata/fonts', 'FiraCode-Variable.ttf')) or {
		panic('FiraCode-Variable.ttf is not readable: ${err}')
	}
}

// e84_ctx_fs is the context and the single-font set the pins shape against.
fn e84_ctx_fs() (shape.Context, shape.FontSet) {
	ctx := shape.new_context()
	return ctx, shape.new_font_set_of(e84_font())
}

// e84_ranges flattens wrapped lines to their [from, to) pairs, which is what
// every mode pin below is asked about.
fn e84_ranges(lines []layout.WrappedLine) []int {
	mut out := []int{}
	for w in lines {
		out << w.from
		out << w.to
	}
	return out
}

// e84_widths lists what each wrapped line measures, in order.
fn e84_widths(lines []layout.WrappedLine) []f64 {
	mut out := []f64{}
	for w in lines {
		out << w.line.width
	}
	return out
}

// Word mode breaks only at spaces: 'aa bb cc' at 100 px is 'aa ' and 'bb cc'
// (57.6 and 96.0), because each of the 8 characters costs 19.2.
fn test_e84_word_mode_breaks_only_at_spaces() {
	ctx, fs := e84_ctx_fs()
	mut opts := layout.LayoutOptions{}
	lines := layout.wrap_paragraph_with(ctx, 'aa bb cc'.runes(), .ltr, fs, 32.0, 100.0, &opts)
	assert e84_ranges(lines) == [0, 3, 3, 8], 'word breaks at the spaces, got ${e84_ranges(lines)}'
	got := e84_widths(lines)
	assert got.len == 2 && e84_approx(got[0], 57.6, 0.01) && e84_approx(got[1], 96.0, 0.01), 'line widths, got ${got}'
}

// Char mode breaks anywhere: the same text at the same width is 'aa bb' and
// ' cc' (96.0 and 57.6), splitting between the second b and the space where
// word mode held. The ranges differ from the word pin above on purpose: that
// difference is the break-fix control, and a char branch neutered to word
// answers [0, 3, 3, 8] here instead.
fn test_e84_char_mode_splits_inside_words() {
	ctx, fs := e84_ctx_fs()
	mut opts := layout.LayoutOptions{
		wrap_mode: .char
	}
	lines := layout.wrap_paragraph_with(ctx, 'aa bb cc'.runes(), .ltr, fs, 32.0, 100.0, &opts)
	assert e84_ranges(lines) == [0, 5, 5, 8], 'char splits mid-word, got ${e84_ranges(lines)}'
	got := e84_widths(lines)
	assert got.len == 2 && e84_approx(got[0], 96.0, 0.01) && e84_approx(got[1], 57.6, 0.01), 'line widths, got ${got}'
}

// A word wider than the line overflows whole in word mode: 'aaaaaa' at 50 px
// is one 115.2 line, because a click on half a word maps nowhere.
fn test_e84_word_mode_overflows_a_long_word() {
	ctx, fs := e84_ctx_fs()
	mut opts := layout.LayoutOptions{}
	lines := layout.wrap_paragraph_with(ctx, 'aaaaaa'.runes(), .ltr, fs, 32.0, 50.0, &opts)
	assert lines.len == 1, 'one overflowing line, got ${lines.len}'
	assert e84_ranges(lines) == [0, 6], 'the whole word, got ${e84_ranges(lines)}'
	assert e84_approx(lines[0].line.width, 115.2, 0.01), 'overflows: ${lines[0].line.width}'
	assert lines[0].line.width > 50.0, 'wider than the width it was given'
}

// Char and word_char both split the same word into three 38.4 lines. The
// word_char half of this is the second break-fix control: neutered to word it
// answers the one overflowing line above instead.
fn test_e84_char_and_word_char_split_a_long_word() {
	ctx, fs := e84_ctx_fs()
	for mode in [layout.WrapMode.char, layout.WrapMode.word_char] {
		mut opts := layout.LayoutOptions{
			wrap_mode: mode
		}
		lines := layout.wrap_paragraph_with(ctx, 'aaaaaa'.runes(), .ltr, fs, 32.0, 50.0, &opts)
		assert e84_ranges(lines) == [0, 2, 2, 4, 4, 6], '${mode} splits by character, got ${e84_ranges(lines)}'
		for w in lines {
			assert e84_approx(w.line.width, 38.4, 0.01), '${mode} line width, got ${w.line.width}'
		}
	}
}

// Word_char keeps word breaks where they fit: 'aaaaaa bb' at 50 px splits
// the long word by character and then takes the space and 'bb' as words.
fn test_e84_word_char_keeps_word_breaks() {
	ctx, fs := e84_ctx_fs()
	mut opts := layout.LayoutOptions{
		wrap_mode: .word_char
	}
	lines := layout.wrap_paragraph_with(ctx, 'aaaaaa bb'.runes(), .ltr, fs, 32.0, 50.0, &opts)
	assert e84_ranges(lines) == [0, 2, 2, 4, 4, 6, 6, 7, 7, 9], 'words split, then word breaks, got ${e84_ranges(lines)}'
	got := e84_widths(lines)
	want := [38.4, 38.4, 38.4, 19.2, 38.4]
	assert got.len == want.len, 'five lines, got ${got.len}'
	for i, w in got {
		assert e84_approx(w, want[i], 0.01), 'line ${i} width, got ${w}'
	}
}

// A mark rides its base across a char split: 'a' + acute + 'b' at 20.2 px is
// [0, 2) and [2, 3), because no break falls before the acute (combining class
// 230). The first line carries the mark, and no line starts with it.
fn test_e84_char_keeps_a_mark_with_its_base() {
	ctx, fs := e84_ctx_fs()
	mut opts := layout.LayoutOptions{
		wrap_mode: .char
	}
	cps := [rune(0x61), rune(0x0301), rune(0x62)]
	lines := layout.wrap_paragraph_with(ctx, cps, .ltr, fs, 32.0, 20.2, &opts)
	assert e84_ranges(lines) == [0, 2, 2, 3], 'the mark stays with its base, got ${e84_ranges(lines)}'
	assert lines[0].line.glyphs.len == 2, 'a and its acute, got ${lines[0].line.glyphs.len}'
	assert lines[1].line.glyphs.len == 1 && lines[1].line.glyphs[0].cluster == 2, 'b starts the second line'
}

// The policy path honors the mode the same way the plain path does:
// Uax14Breaks under char answers exactly what wrap_paragraph_with answers.
fn test_e84_policy_char_matches_plain_char() {
	ctx, fs := e84_ctx_fs()
	mut opts := layout.LayoutOptions{
		wrap_mode: .char
	}
	a := layout.wrap_paragraph_with(ctx, 'aa bb cc'.runes(), .ltr, fs, 32.0, 100.0, &opts)
	b := layout.wrap_paragraph_with_policy(ctx, 'aa bb cc'.runes(), .ltr, fs, 32.0, 100.0,
		&opts, layout.Uax14Breaks{})
	assert e84_ranges(a) == e84_ranges(b), 'same breaks, got ${e84_ranges(a)} vs ${e84_ranges(b)}'
	assert a.len == b.len, 'same line count'
	for i, w in a {
		assert e84_approx(w.line.width, b[i].line.width, 0.01), 'line ${i} same width'
		assert w.line.glyphs.len == b[i].line.glyphs.len, 'line ${i} same glyphs'
	}
}

// Hyphenation is word-mode only: HyphenBreaks under char strips its points
// ([2, 6] for "hyphenation"), so at 100 px the word splits by character with
// no hyphen drawn — gid 1056 appears nowhere.
fn test_e84_policy_char_strips_hyphen_points() {
	ctx, fs := e84_ctx_fs()
	mut opts := layout.LayoutOptions{
		wrap_mode: .char
	}
	lines := layout.wrap_paragraph_with_policy(ctx, 'hyphenation'.runes(), .ltr, fs, 32.0,
		100.0, &opts, layout.HyphenBreaks{})
	assert e84_ranges(lines) == [0, 5, 5, 10, 10, 11], 'char splits, got ${e84_ranges(lines)}'
	for w in lines {
		for g in w.line.glyphs {
			assert g.gid != 1056, 'no hyphen glyph in char mode, found one at cluster ${g.cluster}'
		}
	}
}

// Word_char strips hyphens the same way: at 135.4 px (which fits 'hyphen' plus
// its hyphen in word mode) the split falls at 7 by character, not at the
// hyphen point 6, and draws no hyphen.
fn test_e84_policy_word_char_strips_hyphens() {
	ctx, fs := e84_ctx_fs()
	mut opts := layout.LayoutOptions{
		wrap_mode: .word_char
	}
	lines := layout.wrap_paragraph_with_policy(ctx, 'hyphenation'.runes(), .ltr, fs, 32.0,
		135.4, &opts, layout.HyphenBreaks{})
	assert lines.len == 2, 'one split, got ${lines.len}'
	assert lines[0].to == 7, 'by character at 7, not the hyphen point 6, got ${lines[0].to}'
	assert e84_approx(lines[0].line.width, 134.4, 0.01), 'first line width, got ${lines[0].line.width}'
	for w in lines {
		for g in w.line.glyphs {
			assert g.gid != 1056, 'no hyphen glyph in word_char mode, found one at cluster ${g.cluster}'
		}
	}
}

// End ellipsize keeps the longest fitting head: ten a's (192.0) at 100 px
// keep four (76.8) beside the 19.2 ellipsis for 96.0. The ellipsis is gid 1000
// naming the cut at cluster 4.
fn test_e84_ellipsize_end_keeps_the_head() {
	ctx, fs := e84_ctx_fs()
	mut opts := layout.LayoutOptions{}
	line := layout.ellipsize_line(ctx, 'aaaaaaaaaa'.runes(), .ltr, fs, 32.0, 100.0, &opts, .end)
	assert line.glyphs.len == 5, 'four letters and the ellipsis, got ${line.glyphs.len}'
	assert e84_approx(line.width, 96.0, 0.01), 'head plus ellipsis, got ${line.width}'
	mut clusters := []int{}
	for g in line.glyphs {
		clusters << g.cluster
	}
	assert clusters == [0, 1, 2, 3, 4], 'the head and the cut, got ${clusters}'
	last := line.glyphs[line.glyphs.len - 1]
	assert last.gid == 1000, 'the ellipsis glyph, got ${last.gid}'
	assert e84_approx(last.x + last.advance, 96.0, 0.01), 'the ellipsis ends the line'
}

// Start ellipsize keeps the longest fitting tail: the same line keeps the
// last four a's, and the ellipsis (gid 1000, cluster 6) opens the line.
fn test_e84_ellipsize_start_keeps_the_tail() {
	ctx, fs := e84_ctx_fs()
	mut opts := layout.LayoutOptions{}
	line := layout.ellipsize_line(ctx, 'aaaaaaaaaa'.runes(), .ltr, fs, 32.0, 100.0, &opts, .start)
	assert line.glyphs.len == 5, 'the ellipsis and four letters, got ${line.glyphs.len}'
	assert e84_approx(line.width, 96.0, 0.01), 'ellipsis plus tail, got ${line.width}'
	first := line.glyphs[0]
	assert first.gid == 1000, 'the ellipsis glyph opens, got ${first.gid}'
	assert first.cluster == 6 && first.x == 0.0, 'the cut at 6, drawn first'
	mut clusters := []int{}
	for g in line.glyphs[1..] {
		clusters << g.cluster
	}
	assert clusters == [6, 7, 8, 9], 'the tail, got ${clusters}'
}

// Middle ellipsize keeps both ends: two a's, the ellipsis at index 2, two
// a's, 96.0 wide. Half the 80.8 budget keeps two letters (38.4); the rest
// keeps the last two.
fn test_e84_ellipsize_middle_keeps_both_ends() {
	ctx, fs := e84_ctx_fs()
	mut opts := layout.LayoutOptions{}
	line := layout.ellipsize_line(ctx, 'aaaaaaaaaa'.runes(), .ltr, fs, 32.0, 100.0, &opts, .middle)
	assert line.glyphs.len == 5, 'two letters, the ellipsis, two letters, got ${line.glyphs.len}'
	assert e84_approx(line.width, 96.0, 0.01), 'ends plus ellipsis, got ${line.width}'
	mid := line.glyphs[2]
	assert mid.gid == 1000, 'the ellipsis sits in the middle, got ${mid.gid}'
	assert mid.cluster == 2, 'naming the cut, got ${mid.cluster}'
	assert line.glyphs[0].cluster == 0 && line.glyphs[1].cluster == 1, 'the head'
	assert line.glyphs[3].cluster == 8 && line.glyphs[4].cluster == 9, 'the tail'
}

// A line that fits is drawn whole (no ellipsis at 200 px), and .none draws
// the whole 192.0 line however narrow the width.
fn test_e84_ellipsize_leaves_fitting_and_none_lines_whole() {
	ctx, fs := e84_ctx_fs()
	mut opts := layout.LayoutOptions{}
	fits := layout.ellipsize_line(ctx, 'aaaaaaaaaa'.runes(), .ltr, fs, 32.0, 200.0, &opts, .end)
	assert fits.glyphs.len == 10, 'fits: all ten letters, got ${fits.glyphs.len}'
	assert e84_approx(fits.width, 192.0, 0.01), 'fits: full width, got ${fits.width}'
	plain := layout.ellipsize_line(ctx, 'aaaaaaaaaa'.runes(), .ltr, fs, 32.0, 100.0, &opts, .none)
	assert plain.glyphs.len == 10, 'none: all ten letters, got ${plain.glyphs.len}'
	assert plain.width > 100.0, 'none: overflowing and unellipsized, got ${plain.width}'
	for g in fits.glyphs {
		assert g.gid != 1000, 'no ellipsis when the line fits'
	}
}

// No ellipsis glyph, no ellipsize: NotoNaskhArabic-Variable carries no
// U+2026 (fontTools: absent from its cmap), so 'سلام' narrowed to half its
// width comes back whole and overflowing rather than truncated.
fn test_e84_ellipsize_without_a_glyph_ellipsizes_nothing() {
	p := os.join_path('testdata/fonts', 'NotoNaskhArabic-Variable.ttf')
	if !os.exists(p) {
		panic('${p} is committed and was not found')
	}
	f := shape.load_font_file(p) or { panic('${p} is not readable: ${err}') }
	assert f.glyph_index(rune(0x2026)) == 0, 'this font carries no ellipsis'
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	cps := [rune(0x0633), rune(0x0644), rune(0x0627), rune(0x0645)]
	full := layout.layout_paragraph(ctx, cps, .rtl, fs, 32.0)
	assert full.width > 0, 'there is a line to narrow'
	mut opts := layout.LayoutOptions{}
	got := layout.ellipsize_line(ctx, cps, .rtl, fs, 32.0, full.width / 2.0, &opts, .end)
	assert got.glyphs.len == full.glyphs.len, 'nothing cut: ${got.glyphs.len} vs ${full.glyphs.len}'
	assert e84_approx(got.width, full.width, 0.01), 'nothing narrowed: ${got.width} vs ${full.width}'
	assert got.width > full.width / 2.0, 'still overflowing, as drawn'
}

// Tabs take the pen to the first stop past it: 'a\tb' with stops at 40 and 80
// puts the tab's advance at 20.8 (40 minus the 19.2 'a'), b at 40.0, and the
// line at 59.2. The tab itself is still .notdef (gid 0): stops move ink.
fn test_e84_tab_stops_move_the_pen() {
	ctx, fs := e84_ctx_fs()
	mut opts := layout.LayoutOptions{
		tab_stops: [40.0, 80.0]
	}
	line := layout.layout_paragraph_with(ctx, 'a\tb'.runes(), .ltr, fs, 32.0, &opts)
	assert line.glyphs.len == 3, 'three glyphs, got ${line.glyphs.len}'
	tab := line.glyphs[1]
	assert tab.cluster == 1 && tab.gid == 0, 'the tab glyph'
	assert e84_approx(tab.advance, 20.8, 0.01), 'tab advance to the 40 stop, got ${tab.advance}'
	assert e84_approx(line.glyphs[2].x, 40.0, 0.01), 'b starts at the stop, got ${line.glyphs[2].x}'
	assert e84_approx(line.width, 59.2, 0.01), 'line width, got ${line.width}'
}

// Without stops nothing changes: the tab keeps its 19.2 font advance and the
// line is 57.6, exactly as before tab stops existed.
fn test_e84_tab_without_stops_keeps_the_font_advance() {
	ctx, fs := e84_ctx_fs()
	line := layout.layout_paragraph(ctx, 'a\tb'.runes(), .ltr, fs, 32.0)
	assert line.glyphs.len == 3
	assert e84_approx(line.glyphs[1].advance, 19.2, 0.01), 'font advance, got ${line.glyphs[1].advance}'
	assert e84_approx(line.width, 57.6, 0.01), 'unchanged width, got ${line.width}'
}

// Past the last stop the last interval repeats: with stops at 20 and 40 the
// tab after 'abcd' (pen 76.8) lands on 80, an advance of 3.2, and 'e' at 80.0
// for a 99.2 line.
fn test_e84_tab_past_the_last_stop_repeats_the_interval() {
	ctx, fs := e84_ctx_fs()
	mut opts := layout.LayoutOptions{
		tab_stops: [20.0, 40.0]
	}
	line := layout.layout_paragraph_with(ctx, 'abcd\te'.runes(), .ltr, fs, 32.0, &opts)
	tab := line.glyphs[4]
	assert tab.cluster == 4, 'the tab'
	assert e84_approx(tab.advance, 3.2, 0.01), 'to the repeated stop at 80, got ${tab.advance}'
	assert e84_approx(line.glyphs[5].x, 80.0, 0.01), 'e starts there, got ${line.glyphs[5].x}'
	assert e84_approx(line.width, 99.2, 0.01), 'line width, got ${line.width}'
}

// With fewer than two stops there is no interval to repeat, so a stop short
// of the pen leaves the tab on its font advance.
fn test_e84_tab_with_one_short_stop_keeps_the_font_advance() {
	ctx, fs := e84_ctx_fs()
	mut opts := layout.LayoutOptions{
		tab_stops: [10.0]
	}
	line := layout.layout_paragraph_with(ctx, 'a\tb'.runes(), .ltr, fs, 32.0, &opts)
	assert e84_approx(line.glyphs[1].advance, 19.2, 0.01), 'font advance, got ${line.glyphs[1].advance}'
	assert e84_approx(line.width, 57.6, 0.01), 'unchanged width, got ${line.width}'
}

// Break-fix control, stated as one test: the new branches are load-bearing.
// Neuter ops_for_mode's char arm to return the base list and the char pin
// below answers the word ranges; neuter emit_char_splits to emit whole words
// and word_char answers the one overflowing line; drop the ellipsis append
// and the end pin answers four glyphs at 76.8 with no gid 1000.
fn test_e84_breakfix_control_pins_the_new_branches() {
	ctx, fs := e84_ctx_fs()
	mut word_opts := layout.LayoutOptions{}
	worded := layout.wrap_paragraph_with(ctx, 'aa bb cc'.runes(), .ltr, fs, 32.0, 100.0, &word_opts)
	mut char_opts := layout.LayoutOptions{
		wrap_mode: .char
	}
	chared := layout.wrap_paragraph_with(ctx, 'aa bb cc'.runes(), .ltr, fs, 32.0, 100.0, &char_opts)
	assert e84_ranges(worded) != e84_ranges(chared), 'the char arm must add breaks: ${e84_ranges(worded)} vs ${e84_ranges(chared)}'
	mut wc_opts := layout.LayoutOptions{
		wrap_mode: .word_char
	}
	split := layout.wrap_paragraph_with(ctx, 'aaaaaa'.runes(), .ltr, fs, 32.0, 50.0, &wc_opts)
	assert split.len == 3 && worded.len == 2, 'word_char splits (${split.len}) where word overflows whole'
	mut el_opts := layout.LayoutOptions{}
	elided := layout.ellipsize_line(ctx, 'aaaaaaaaaa'.runes(), .ltr, fs, 32.0, 100.0, &el_opts, .end)
	assert elided.glyphs.len == 5, 'four letters plus the ellipsis, got ${elided.glyphs.len}'
	assert elided.glyphs[elided.glyphs.len - 1].gid == 1000, 'the ellipsis is drawn'
	assert e84_approx(elided.width, 96.0, 0.01), 'head plus ellipsis, got ${elided.width}'
	tabbed := layout.layout_paragraph_with(ctx, 'a\tb'.runes(), .ltr, fs, 32.0, &layout.LayoutOptions{
		tab_stops: [40.0, 80.0]
	})
	assert e84_approx(tabbed.width, 59.2, 0.01), 'the stop moved the pen, got ${tabbed.width}'
}
