module harfara

import os
import harfara.shape
import harfara.layout

// Tests for the 7.5 wiring: BreakPolicy plumbing and hyphen-aware wrapping.
// The algorithm and tables are pinned in hyphen_test.v; what is pinned here
// is the integration: the default policy answers exactly what the plain call
// answers, a hyphen break draws its hyphen and fits, and nothing hyphenates
// where it must not (digits, vertical text, fitting words).

fn hwrap_font(name string) ?&shape.Font {
	p := os.join_path('testdata/fonts', name)
	if !os.exists(p) {
		return none
	}
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

fn hwrap_ctx_fs() (shape.Context, shape.FontSet, shape.Font) {
	f := hwrap_font('FiraCode-Variable.ttf') or { panic('FiraCode missing') }
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	return ctx, fs, f
}

fn test_wrap_policy_uax14_matches_plain_wrap() {
	// The default policy changes no decision: every line matches the plain
	// call in width, glyph count and range. A divergence here is a regression
	// in the shared loop, not a hyphenation feature.
	ctx, fs, _ := hwrap_ctx_fs()
	text := 'aa bb hyphenation cc dd ee ff gg'
	mut opts := layout.LayoutOptions{}
	a := layout.wrap_paragraph_with(ctx, text.runes(), .auto, fs, 32.0, 200.0, &opts)
	b := layout.wrap_paragraph_with_policy(ctx, text.runes(), .auto, fs, 32.0, 200.0,
		&opts, layout.Uax14Breaks{})
	assert a.len == b.len, 'same breaks, got ${a.len} vs ${b.len}'
	for i, wl in a {
		assert wl.line.width == b[i].line.width, 'line ${i} same width'
		assert wl.line.glyphs.len == b[i].line.glyphs.len, 'line ${i} same glyphs'
		assert wl.from == b[i].from && wl.to == b[i].to, 'line ${i} same range'
	}
}

fn test_wrap_hyphen_breaks_overlong_word() {
	ctx, fs, f := hwrap_ctx_fs()
	hy_gid := f.glyph_index(`-`)
	assert hy_gid != 0, 'FiraCode carries the hyphen'
	hy_adv := f.glyph_advance(hy_gid, 32.0)
	// A width that fits "hyphen" plus its hyphen but not the whole word:
	// hyphenation points for "hyphenation" are [2, 6].
	part := layout.layout_paragraph(ctx, 'hyphen'.runes(), .auto, fs, 32.0)
	target := part.width + hy_adv + 1.0
	full := layout.layout_paragraph(ctx, 'hyphenation'.runes(), .auto, fs, 32.0)
	assert full.width > target, 'the whole word overflows the target'
	mut opts := layout.LayoutOptions{}
	pol := layout.HyphenBreaks{}
	wrapped := layout.wrap_paragraph_with_policy(ctx, 'hyphenation'.runes(), .auto, fs,
		32.0, target, &opts, pol)
	assert wrapped.len == 2, 'one hyphen break, got ${wrapped.len} lines'
	first := wrapped[0]
	assert first.to == 6, 'break at the second hyphen point, got ${first.to}'
	assert first.line.glyphs.len > 0, 'first line draws'
	last_g := first.line.glyphs[first.line.glyphs.len - 1]
	assert last_g.gid == hy_gid, 'the break draws its hyphen, got ${last_g.gid}'
	assert last_g.cluster == 6, 'the hyphen names the break position'
	assert first.line.width <= target, 'hyphenated line fits, got ${first.line.width}'
	assert wrapped[1].from == 6, 'the rest resumes at the break'
	assert wrapped[1].line.width <= target, 'the rest fits'
	// The same text under UAX alone overflows whole: one line, wider than target.
	plain := layout.wrap_paragraph_with(ctx, 'hyphenation'.runes(), .auto, fs, 32.0,
		target, &opts)
	assert plain.len == 1, 'no hyphen points, no split'
	assert plain[0].line.width > target, 'overflows whole, as before'
}

fn test_wrap_hyphen_needs_no_hyphen_points() {
	// Digits form no words for the hyphenator: an overlong digit run
	// overflows exactly the way it did before hyphenation existed.
	ctx, fs, _ := hwrap_ctx_fs()
	mut opts := layout.LayoutOptions{}
	pol := layout.HyphenBreaks{}
	wrapped := layout.wrap_paragraph_with_policy(ctx, '123456789012345678901234567890'.runes(),
		.auto, fs, 32.0, 100.0, &opts, pol)
	assert wrapped.len == 1, 'no points, no split, got ${wrapped.len}'
	assert wrapped[0].line.width > 100.0, 'overflows whole'
}

fn test_wrap_hyphen_skipped_in_vertical() {
	// Hyphenation is horizontal: a vertical column takes no hyphen breaks,
	// so the policy answers what UAX answers.
	ctx, fs, _ := hwrap_ctx_fs()
	mut opts := layout.LayoutOptions{
		vertical: true
	}
	a := layout.wrap_paragraph_with(ctx, 'hyphenation aa bb'.runes(), .auto, fs, 32.0,
		200.0, &opts)
	b := layout.wrap_paragraph_with_policy(ctx, 'hyphenation aa bb'.runes(), .auto, fs,
		32.0, 200.0, &opts, layout.HyphenBreaks{})
	assert a.len == b.len, 'same columns, got ${a.len} vs ${b.len}'
	for i, wl in a {
		assert wl.line.glyphs.len == b[i].line.glyphs.len, 'column ${i} same glyphs'
	}
}
