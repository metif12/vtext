module harfara

import harfara.layout
import harfara.shape

// Tests for the C spelling of the 8.4 fields: wrap_mode and tab_stops on
// COptions, resolved by c_options the way harfara_line_with, harfara_wrap_with
// and harfara_measure_with consume them.
//
// The contract is append-only: the two fields sit after align_width, so the
// offsets of every older field never move and a caller built against the
// old struct still reads its own fields. What is pinned here is that the
// spelling drives the engine: each C value resolves to the LayoutOptions
// the V caller would have written, and the resolved options shape and wrap
// identically.
//
// COptions and c_options live in the same module as this test, so the test
// builds the struct directly instead of going through C: the layout question
// is what c_options answers, not how a C compiler packs the struct (both
// sides declare the fields in the same order, which is what keeps them in
// step).

// copts builds a zeroed COptions the way a C caller callocing the struct
// would: every field off unless the test sets it.
fn copts() COptions {
	return COptions{
		features:  unsafe { nil }
		script:    unsafe { nil }
		language:  unsafe { nil }
		tab_stops: unsafe { nil }
	}
}

fn test_coptions_default_is_word_without_stops() {
	mut o := copts()
	opts := c_options(&o)
	assert opts.wrap_mode == .word, 'zeroed wrap_mode is word'
	assert opts.tab_stops.len == 0, 'null stops are no stops'
}

fn test_coptions_wrap_mode_mapping() {
	mut o := copts()
	o.wrap_mode = 1
	assert c_options(&o).wrap_mode == .char, '1 is char'
	o.wrap_mode = 2
	assert c_options(&o).wrap_mode == .word_char, '2 is word_char'
	o.wrap_mode = 0
	assert c_options(&o).wrap_mode == .word, '0 is word'
	o.wrap_mode = 9
	assert c_options(&o).wrap_mode == .word, 'anything else is word, got ${c_options(&o).wrap_mode}'
	o.wrap_mode = -1
	assert c_options(&o).wrap_mode == .word, 'negative is word'
}

fn test_coptions_tab_stops_copy() {
	mut stops := [40.0, 80.0]
	mut o := copts()
	o.tab_stops = stops.data
	o.num_tab_stops = stops.len
	got := c_options(&o)
	assert got.tab_stops == [40.0, 80.0], 'stops arrive in order, got ${got.tab_stops}'
	// The values are copied: mutating the caller's array afterwards must
	// not move the resolved stops.
	stops[0] = 99.0
	assert got.tab_stops == [40.0, 80.0], 'the copy survives the caller'
}

fn test_coptions_empty_stops() {
	stops := [40.0]
	mut o := copts()
	o.tab_stops = stops.data
	o.num_tab_stops = 0
	assert c_options(&o).tab_stops.len == 0, 'zero count is no stops'
	o.num_tab_stops = -3
	assert c_options(&o).tab_stops.len == 0, 'negative count is no stops'
	mut n := copts()
	n.num_tab_stops = 2
	assert c_options(&n).tab_stops.len == 0, 'null pointer is no stops whatever the count'
}

fn test_coptions_null_is_default() {
	opts := c_options(unsafe { nil })
	assert opts.wrap_mode == .word, 'null options are word'
	assert opts.tab_stops.len == 0, 'null options carry no stops'
}

// coptions_font_set shapes against the same face the 8.4 pins use.
fn coptions_font_set() (shape.Context, shape.FontSet) {
	ctx := shape.new_context()
	f := shape.load_font_file('testdata/fonts/FiraCode-Variable.ttf') or {
		panic('FiraCode-Variable.ttf is not readable: ${err}')
	}
	return ctx, shape.new_font_set_of(f)
}

fn test_coptions_tab_stops_drive_the_engine() {
	// 'a\tb' with stops at 40 and 80: the tab advances 20.8 to the 40
	// stop and b starts at 40.0 — the 8.4 pin, reached through the C
	// spelling instead of a hand-built LayoutOptions.
	ctx, fs := coptions_font_set()
	stops := [40.0, 80.0]
	mut o := copts()
	o.tab_stops = stops.data
	o.num_tab_stops = stops.len
	resolved := c_options(&o)
	line := layout.layout_paragraph_with(ctx, 'a\tb'.runes(), .ltr, fs, 32.0, &resolved)
	assert line.glyphs.len == 3, 'three glyphs, got ${line.glyphs.len}'
	assert line.glyphs[1].advance > 20.79 && line.glyphs[1].advance < 20.81, 'tab advance to the 40 stop, got ${line.glyphs[1].advance}'
	assert line.glyphs[2].x > 39.99 && line.glyphs[2].x < 40.01, 'b starts at the stop, got ${line.glyphs[2].x}'
}

fn test_coptions_wrap_mode_drives_the_engine() {
	// The same long word wrapped two ways: char mode splits inside it,
	// word mode lets it overflow whole — decided by one C int.
	ctx, fs := coptions_font_set()
	mut o := copts()
	o.wrap_mode = 1
	resolved := c_options(&o)
	char_lines := layout.wrap_paragraph_with(ctx, 'aaabbbccc'.runes(), .ltr, fs, 32.0,
		60.0, &resolved)
	mut w := copts()
	w_resolved := c_options(&w)
	word_lines := layout.wrap_paragraph_with(ctx, 'aaabbbccc'.runes(), .ltr, fs, 32.0,
		60.0, &w_resolved)
	assert char_lines.len > 1, 'char mode splits the overlong word, got ${char_lines.len} lines'
	assert word_lines.len == 1, 'word mode lets it overflow whole, got ${word_lines.len} lines'
}
