module vtext

import os
import math
import vtext.layout
import vtext.shape

// Tests for slice 7.4: alignment and justification, with kashida where the
// font carries it and spaces elsewhere.
//
// Every number below was read off the engine before it was written here, and
// the suite fails if the engine moves: a wrong shift, a wrong tatweel count
// or a stretched letter advance breaks an exact assert. The one deliberate
// non-assert is Pango parity — Pango justifies spaces and kashida by its own
// rules, so justified widths are engine-arithmetic (width hits the target,
// tatweel count times advance) rather than cross-reader pins.

fn align_approx(got f64, want f64, tol f64) bool {
	return math.abs(got - want) < tol
}

fn align_skip(name string) {
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

fn align_font(name string) ?&shape.Font {
	mut dirs := []string{}
	for d in [os.getenv('VTEXT_TEST_FONTS'), 'testdata/fonts'] {
		if d != '' && d !in dirs {
			dirs << d
		}
	}
	for dir in dirs {
		p := os.join_path(dir, name)
		if os.exists(p) {
			return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
		}
	}
	align_skip(name)
	return none
}

fn align_line(f &shape.Font, text string, em_px f64) layout.Line {
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	return layout.layout_paragraph(ctx, text.runes(), .auto, fs, em_px)
}

fn align_line_with(f &shape.Font, text string, em_px f64, mode layout.Align, width f64) layout.Line {
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	mut opts := layout.LayoutOptions{
		align:       mode
		align_width: width
	}
	return layout.layout_paragraph_with(ctx, text.runes(), .auto, fs, em_px, &opts)
}

// kashida_new_gids is the multiset difference of two laid-out lines: the
// glyphs the grown line holds that the base does not, each occurrence paired
// off once. With one tatweel per gap nothing fuses, so these are exactly the
// inserted tatweel forms — whatever form each gap chose, which the test does
// not presume to name.
fn kashida_new_gids(plain layout.Line, grown layout.Line) []u16 {
	mut remaining := []u16{}
	for g in plain.glyphs {
		remaining << g.gid
	}
	mut out := []u16{}
	for g in grown.glyphs {
		at := remaining.index(g.gid)
		if at < 0 {
			out << g.gid
		} else {
			remaining.delete(at)
		}
	}
	return out
}

fn test_align_left_is_a_noop() {
	f := align_font('FiraCode-Variable.ttf') or { return }
	plain := align_line(f, 'hello', 32.0)
	shifted := align_line_with(f, 'hello', 32.0, .left, 300.0)
	assert shifted.glyphs.len == plain.glyphs.len, 'left keeps every glyph'
	for i, g in shifted.glyphs {
		assert g.x == plain.glyphs[i].x, 'left moves nothing, glyph ${i}'
		assert g.advance == plain.glyphs[i].advance, 'left widens nothing, glyph ${i}'
	}
	assert shifted.width == plain.width, 'left keeps the width'
}

fn test_align_center_splits_the_slack() {
	f := align_font('FiraCode-Variable.ttf') or { return }
	plain := align_line(f, 'hello', 32.0)
	target := plain.width + 100.0
	centered := align_line_with(f, 'hello', 32.0, .center, target)
	assert centered.width == plain.width, 'center keeps the width'
	assert centered.glyphs.len == plain.glyphs.len, 'center keeps every glyph'
	for i, g in centered.glyphs {
		assert align_approx(g.x, plain.glyphs[i].x + 50.0, 1e-6), 'center moves every glyph by half the slack, glyph ${i}'
		assert g.advance == plain.glyphs[i].advance, 'center widens nothing, glyph ${i}'
	}
	// The symmetry, not just the shift: the left margin equals the right one.
	first := centered.glyphs[0]
	last := centered.glyphs[centered.glyphs.len - 1]
	assert align_approx(first.x, target - (last.x + last.advance), 1e-6), 'margins match'
}

fn test_align_right_moves_by_the_slack() {
	f := align_font('Amiri-Regular.ttf') or { return }
	plain := align_line(f, 'مدرسة', 32.0)
	target := plain.width + 60.0
	right := align_line_with(f, 'مدرسة', 32.0, .right, target)
	assert right.width == plain.width, 'right keeps the width'
	for i, g in right.glyphs {
		assert align_approx(g.x, plain.glyphs[i].x + 60.0, 1e-6), 'right moves every glyph by the slack, glyph ${i}'
	}
	last := right.glyphs[right.glyphs.len - 1]
	assert align_approx(last.x + last.advance, target, 1e-6), 'right edge lands on the target'
}

fn test_align_ignores_overflow() {
	f := align_font('FiraCode-Variable.ttf') or { return }
	plain := align_line(f, 'hello world', 32.0)
	for mode in [layout.Align.center, layout.Align.right, layout.Align.justify] {
		got := align_line_with(f, 'hello world', 32.0, mode, plain.width - 10.0)
		assert got.width == plain.width, 'a narrower target widens nothing (${int(mode)})'
		for i, g in got.glyphs {
			assert g.x == plain.glyphs[i].x, 'a narrower target moves nothing (${int(mode)})'
		}
	}
}

fn test_justify_stretches_spaces_not_letters() {
	f := align_font('FiraCode-Variable.ttf') or { return }
	plain := align_line(f, 'a b c', 32.0)
	target := plain.width + 30.0
	got := align_line_with(f, 'a b c', 32.0, .justify, target)
	// FiraCode has no kashida path (no tatweel, Latin text), so this is the
	// spaces half: the slack lands on the two spaces and nowhere else.
	assert got.width == target, 'justified width hits the target, got ${got.width}'
	mut spaces := 0
	for i, g in got.glyphs {
		if plain.glyphs[i].advance == 0 {
			continue
		}
		if g.cluster == 1 || g.cluster == 3 {
			assert align_approx(g.advance, plain.glyphs[i].advance + 15.0, 1e-6), 'each space takes half the slack, glyph ${i}'
			spaces++
		} else {
			assert g.advance == plain.glyphs[i].advance, 'letters keep their advance, glyph ${i}'
		}
	}
	assert spaces == 2, 'both spaces stretched, got ${spaces}'
}

fn test_justify_without_spaces_keeps_width() {
	f := align_font('FiraCode-Variable.ttf') or { return }
	plain := align_line(f, 'abc', 32.0)
	got := align_line_with(f, 'abc', 32.0, .justify, plain.width + 40.0)
	assert got.width == plain.width, 'no stretchable point, no stretch'
	for i, g in got.glyphs {
		assert g.x == plain.glyphs[i].x, 'no stretchable point, no shift, glyph ${i}'
	}
}

fn test_justify_single_line_answers_its_width() {
	// The wrap path keeps Pango's last-line rule; a single line answers its
	// explicit width instead, because align_width is an order, not a paragraph.
	f := align_font('FiraCode-Variable.ttf') or { return }
	plain := align_line(f, 'a b', 32.0)
	got := align_line_with(f, 'a b', 32.0, .justify, plain.width + 20.0)
	assert got.width == plain.width + 20.0, 'a single justified line stretches'
}

fn test_justify_kashida_inserts_tatweel() {
	f := align_font('Amiri-Regular.ttf') or { return }
	plain := align_line(f, 'مدرسة', 32.0)
	tat := f.glyph_index(rune(0x0640))
	assert tat != 0, 'Amiri carries the tatweel'
	tat_adv := f.glyph_advance(tat, 32.0)
	assert tat_adv > 0, 'the tatweel has a positive advance'
	// Two points in مدرسة (before the dal and before the teh marbuta), so a
	// slack of two advances buys two tatweels at distinct gaps — never
	// stacked, because stacked tatweels fuse into dedicated ligature forms.
	target := plain.width + tat_adv * 2.2
	got := align_line_with(f, 'مدرسة', 32.0, .justify, target)
	// The new glyphs are the multiset difference: no fusion at distinct gaps
	// means the grown line is the base plus exactly the inserted tatweels.
	new_gids := kashida_new_gids(plain, got)
	assert new_gids.len == 2, 'two tatweels inserted, got ${new_gids.len}'
	// The neighbours keep their forms: the grown line minus its tatweels is
	// the base line. A re-shaping that re-formed its neighbours would fail.
	mut stripped := []u16{}
	for g in got.glyphs {
		if g.gid !in new_gids {
			stripped << g.gid
		}
	}
	mut base := []u16{}
	for g in plain.glyphs {
		base << g.gid
	}
	assert stripped == base, 'tatweels split the joins without re-forming them'
	// HarfBuzz-measured width of the same grown text at 32 px: 82.432. Gid
	// forms may differ between readers; the advance agrees, which is the
	// documented width-parity policy.
	assert align_approx(got.width, 82.432, 0.05), 'kashida width matches HarfBuzz, got ${got.width}'
	assert got.width < target, 'discrete tatweels undershoot the target'
}

fn test_justify_kashida_skips_lam_alef() {
	// سلام holds one usable point: the pre-alef gap is skipped and the
	// tatweel goes before the lam instead, so the ligature both engines fuse
	// survives. One point caps the buy at one however wide the slack.
	f := align_font('Amiri-Regular.ttf') or { return }
	plain := align_line(f, 'سلام', 32.0)
	tat_adv := f.glyph_advance(f.glyph_index(rune(0x0640)), 32.0)
	target := plain.width + tat_adv * 1.2
	got := align_line_with(f, 'سلام', 32.0, .justify, target)
	new_gids := kashida_new_gids(plain, got)
	assert new_gids.len == 1, 'the slack buys exactly one, got ${new_gids.len}'
	// The grown line minus its tatweel is the base: the lam-alef ligature
	// survived, which breaking it would fail.
	mut stripped := []u16{}
	for g in got.glyphs {
		if g.gid !in new_gids {
			stripped << g.gid
		}
	}
	mut base := []u16{}
	for g in plain.glyphs {
		base << g.gid
	}
	assert stripped == base, 'the lam-alef ligature survives the insertion'
	// HarfBuzz-measured width of س + tatweel + لام at 32 px: 60.672.
	assert align_approx(got.width, 60.672, 0.05), 'kashida width matches HarfBuzz, got ${got.width}'
	// The tatweel names the lam it precedes (index 1), not the pair it skipped.
	for g in got.glyphs {
		if g.gid in new_gids {
			assert g.cluster == 1, 'tatweel clusters with the lam, got ${g.cluster}'
		}
	}
}

fn test_justify_kashida_mixed_line_uses_spaces() {
	// A mixed line is not a kashida line: re-laying a slice with Latin in it
	// could order differently from its paragraph, so the slack goes to the
	// spaces and no tatweel is drawn.
	f := align_font('Amiri-Regular.ttf') or { return }
	plain := align_line(f, 'مدرسة test', 32.0)
	tat := f.glyph_index(rune(0x0640))
	target := plain.width + 24.0
	got := align_line_with(f, 'مدرسة test', 32.0, .justify, target)
	for g in got.glyphs {
		assert g.gid != tat, 'no tatweel in a mixed line'
	}
	assert got.width == target, 'the slack lands on the space, got ${got.width}'
}

fn test_justify_clusters_survive_kashida() {
	// The re-laid kashida line names the caller's characters, not the grown
	// text's: everything after an insertion point would otherwise drift by
	// the tatweel count and carets would land on the wrong letter.
	f := align_font('Amiri-Regular.ttf') or { return }
	plain := align_line(f, 'مدرسة', 32.0)
	tat_adv := f.glyph_advance(f.glyph_index(rune(0x0640)), 32.0)
	got := align_line_with(f, 'مدرسة', 32.0, .justify, plain.width + tat_adv * 2.2)
	new_gids := kashida_new_gids(plain, got)
	assert new_gids.len == 2, 'two tatweels inserted, got ${new_gids.len}'
	mut tat_clusters := []int{}
	mut stripped := []int{}
	for g in got.glyphs {
		if g.gid in new_gids {
			tat_clusters << g.cluster
		} else {
			stripped << g.cluster
		}
	}
	// One tatweel precedes the teh marbuta (index 4), one the dal (index 1).
	tat_clusters.sort()
	assert tat_clusters == [1, 4], 'tatweels name the letters they precede, got ${tat_clusters}'
	mut plain_clusters := []int{}
	for g in plain.glyphs {
		plain_clusters << g.cluster
	}
	assert stripped == plain_clusters, 'other clusters unchanged'
	for c in tat_clusters {
		assert c >= 0 && c < 5, 'every cluster names the caller text, got ${c}'
	}
}

fn test_justify_wrap_leaves_last_line_flush() {
	f := align_font('FiraCode-Variable.ttf') or { return }
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	text := 'aa bb cc dd ee ff gg hh ii jj kk ll mm nn'
	mut opts := layout.LayoutOptions{
		align: .justify
	}
	wrapped := layout.wrap_paragraph_with(ctx, text.runes(), .auto, fs, 32.0, 200.0, &opts)
	assert wrapped.len > 1, 'the text wraps, got ${wrapped.len} line'
	for i, wl in wrapped {
		if i < wrapped.len - 1 {
			assert wl.line.width == 200.0, 'line ${i} fills the wrap width, got ${wl.line.width}'
		} else {
			assert wl.line.width <= 200.0, 'the last line keeps its width'
			if wl.line.glyphs.len > 0 {
				assert wl.line.glyphs[0].x == 0.0, 'the last line stays flush'
			}
		}
	}
}

fn test_align_wrap_centers_every_line() {
	f := align_font('FiraCode-Variable.ttf') or { return }
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	text := 'aa bb cc dd ee ff gg hh'
	mut opts := layout.LayoutOptions{
		align: .center
	}
	wrapped := layout.wrap_paragraph_with(ctx, text.runes(), .auto, fs, 32.0, 300.0, &opts)
	assert wrapped.len > 0, 'the text lays out'
	for i, wl in wrapped {
		if wl.line.width < 300.0 && wl.line.glyphs.len > 0 {
			want := (300.0 - wl.line.width) / 2.0
			assert align_approx(wl.line.glyphs[0].x, want, 1e-6), 'line ${i} centered'
		}
	}
	// The wrap width is the target: align_width is ignored on wrapped lines.
	mut wide := layout.LayoutOptions{
		align:       .center
		align_width: 50.0
	}
	regardless := layout.wrap_paragraph_with(ctx, text.runes(), .auto, fs, 32.0, 300.0, &wide)
	assert regardless.len == wrapped.len, 'same breaks either way'
	for i, wl in regardless {
		assert wl.line.width == wrapped[i].line.width, 'align_width changes no wrapped line'
	}
}

fn test_align_vertical_ignores() {
	// Alignment is horizontal: a vertical column's length is the pen travel
	// and a target width names nothing, so the mode is ignored there.
	f := align_font('Amiri-Regular.ttf') or { return }
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	mut opts := layout.LayoutOptions{
		vertical:    true
		align:       .center
		align_width: 400.0
	}
	vertical := layout.layout_paragraph_with(ctx, 'مدرسة'.runes(), .auto, fs, 32.0, &opts)
	plain_opts := layout.LayoutOptions{
		vertical: true
	}
	plain := layout.layout_paragraph_with(ctx, 'مدرسة'.runes(), .auto, fs, 32.0, &plain_opts)
	assert vertical.glyphs.len == plain.glyphs.len, 'same glyphs either way'
	for i, g in vertical.glyphs {
		assert g.x == plain.glyphs[i].x && g.y == plain.glyphs[i].y, 'vertical ignores align, glyph ${i}'
	}
}
