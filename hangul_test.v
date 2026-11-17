module vtext

import os
import vtext.shape
import vtext.layout

// Tests for 9.1, first half: Hangul conjoining-Jamo composition, plus the
// vertical CJK punctuation that rides the same face.
//
// The face ships in testdata/fonts with its OFL text, so it loads on every
// platform with no skips: no host font, no platform directory. It is the
// variable NotoSansKR from google/fonts main (upm 1000, 24964 glyphs),
// renamed the way the other wave faces are.
//
// Every gid, advance and cluster below was read off HarfBuzz (uharfbuzz,
// scale 1000 = font units) and fontTools before it was written here;
// agreement with two readers is the evidence. Input clusters double as
// pins: a cluster is an input position, so "the glyph reporting cluster 0"
// names no engine output of its own.
//
// What this slice proves, and what stays open:
//   - conjoining Jamo (U+1100 block) compose into precomposed syllables
//     the way HarfBuzz composes them: L+V and LV+T fold to one glyph on
//     the first cluster, a trailing lone lead stays a glyph of its own on
//     its own cluster, and compatibility Jamo (U+3131) never compose.
//     The fold is UAX#15 section 10.2 arithmetic, so no UCD generator
//     feeds it and no new table is committed for it.
//   - vertical CJK punctuation draws its vert variant in vertical mode
//     the way the vertical_test pattern pins it: the comma and the corner
//     brackets substitute, a CJK letter without a variant is unchanged,
//     and the column hangs below the pen by the vhea ascender.
//   - open: ljmo/vjmo/tjmo keep no pin because composition wins wherever
//     the font carries the syllable, which on this face is everywhere the
//     tests look; a syllable the font does not carry stays a composition
//     the cmap answers with .notdef, and a face that needs the Jamo-form
//     fallback owns that slice.

fn hangul_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('VTEXT_TEST_FONTS'), 'testdata/fonts'] {
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

fn hangul_font(name string) ?&shape.Font {
	p := hangul_font_path(name) or { return none }
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

// hangul_at returns the glyph that came from the input character at that
// index, or none when the character drew nothing.
fn hangul_at(glyphs []shape.Glyph, cluster int) ?shape.Glyph {
	for g in glyphs {
		if g.cluster == cluster {
			return g
		}
	}
	return none
}

// hangul_dump renders a line as gid:cluster:advance cells so a failing pin
// shows the whole engine answer in the message.
fn hangul_dump(line layout.Line) string {
	mut parts := []string{cap: line.glyphs.len}
	for g in line.glyphs {
		parts << '${g.gid:x}:${g.cluster}:${g.advance:.2f}'
	}
	return '[' + parts.join(' ') + ']'
}

fn hangul_line(f &shape.Font, text []rune) layout.Line {
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	mut opts := layout.LayoutOptions{}
	return layout.layout_paragraph_with(ctx, text, .auto, fs, 32.0, &opts)
}

fn hangul_vline(f &shape.Font, text []rune) layout.Line {
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	mut opts := layout.LayoutOptions{
		vertical: true
	}
	return layout.layout_paragraph_with(ctx, text, .auto, fs, 32.0, &opts)
}

fn test_hangul_font_loads() {
	f := hangul_font('NotoSansKR-Variable.ttf') or {
		panic('NotoSansKR-Variable.ttf is not in testdata/fonts')
	}
	assert f.num_glyphs() == 24964, 'KR has 24964 glyphs, got ${f.num_glyphs()}'
	assert f.units_per_em() == 1000, 'KR is upm 1000'
	assert f.has_vertical_metrics(), 'KR carries vhea/vmtx'
}

fn test_hangul_font_covers_korean() {
	f := hangul_font('NotoSansKR-Variable.ttf') or { return }
	assert f.has_glyph(`A`), 'KR covers Latin'
	assert f.has_glyph(rune(0xAC00)), 'KR covers the precomposed syllable GA'
	assert f.has_glyph(rune(0xD55C)), 'KR covers HAN'
	assert f.has_glyph(rune(0x1100)), 'KR covers conjoining choseong KIYEOK'
	assert f.has_glyph(rune(0x1161)), 'KR covers conjoining jungseong A'
	assert f.has_glyph(rune(0x11A8)), 'KR covers conjoining jongseong KIYEOK'
	assert f.has_glyph(rune(0x3131)), 'KR covers compatibility KIYEOK'
	assert f.has_glyph(rune(0x4E00)), 'KR covers CJK U+4E00'
	assert f.has_glyph(rune(0x3001)), 'KR covers the ideographic comma'
	assert f.has_glyph(rune(0x300C)), 'KR covers the corner bracket'
}

fn test_hangul_hangeul_matches_harfbuzz() {
	// HarfBuzz shapes "hangul" as two syllable glyphs in order with no
	// substitution: HAN 0x51a8 at advance 920, GEUL 0x2a4c at 920. The
	// engine draws the same two gids under their own clusters with the
	// same advances: 920 units at 32 px is 29.44.
	f := hangul_font('NotoSansKR-Variable.ttf') or { return }
	line := hangul_line(f, [rune(0xD55C), rune(0xAE00)])
	assert line.glyphs.len == 2, 'hangeul draws two syllables, got ${hangul_dump(line)}'
	want := [u16(0x51a8), 0x2a4c]
	for i in 0 .. want.len {
		g := hangul_at(line.glyphs, i) or {
			panic('hangeul input ${i} drew nothing: ${hangul_dump(line)}')
		}
		assert g.gid == want[i], 'hangeul cluster ${i} is ${want[i]:x}, got ${g.gid:x}: ${hangul_dump(line)}'
		assert g.advance > 29.38 && g.advance < 29.50, 'hangeul cluster ${i} advances 29.44'
		assert g.gid != 0, 'no .notdef in a covered hangeul line'
	}
	assert line.glyphs[0].x == 0, 'first syllable starts at the pen'
	assert line.glyphs[1].x > 29.38 && line.glyphs[1].x < 29.50, 'second syllable starts past the first advance'
}

fn test_hangul_conjoining_jamo_compose() {
	// HarfBuzz composes choseong KIYEOK plus jungseong A into the GA
	// syllable: one glyph 0x284c on cluster 0 at advance 920, the same gid
	// the precomposed U+AC00 maps to. The engine folds the same pair to
	// the same glyph on the same cluster with the same advance.
	f := hangul_font('NotoSansKR-Variable.ttf') or { return }
	line := hangul_line(f, [rune(0x1100), rune(0x1161)])
	assert line.glyphs.len == 1, 'L+V composes to one syllable, got ${hangul_dump(line)}'
	g := hangul_at(line.glyphs, 0) or { panic('the composed syllable drew nothing') }
	assert g.gid == 0x284c, 'L+V is the GA glyph, got ${g.gid:x}: ${hangul_dump(line)}'
	assert g.advance > 29.38 && g.advance < 29.50, 'the composed syllable advances 29.44'
	pre := hangul_line(f, [rune(0xAC00)])
	assert pre.glyphs.len == 1, 'precomposed GA draws one glyph, got ${hangul_dump(pre)}'
	assert pre.glyphs[0].gid == 0x284c, 'precomposed and composed agree on the gid'
}

fn test_hangul_jamo_lvt_and_trailing_lead() {
	// HarfBuzz composes L+V+T into the GAK syllable 0x284d on cluster 0
	// and leaves a trailing lone lead on its own cluster: [1100 1161
	// 11A8 1100] draws [0x284d cl0, 0x174 cl3], each at advance 920. A
	// precomposed GA ahead of a composing pair draws the same gid twice
	// on two clusters: [AC00 1100 1161] is [0x284c cl0, 0x284c cl1].
	f := hangul_font('NotoSansKR-Variable.ttf') or { return }
	line := hangul_line(f, [rune(0x1100), rune(0x1161), rune(0x11A8), rune(0x1100)])
	assert line.glyphs.len == 2, 'LVT plus a lone lead draws two glyphs, got ${hangul_dump(line)}'
	first := hangul_at(line.glyphs, 0) or { panic('the LVT syllable drew nothing') }
	assert first.gid == 0x284d, 'LVT is the GAK glyph, got ${first.gid:x}'
	trail := hangul_at(line.glyphs, 3) or { panic('the trailing lead drew nothing') }
	assert trail.gid == 0x174, 'the lone lead keeps its cmap glyph, got ${trail.gid:x}'
	assert hangul_at(line.glyphs, 1) == none, 'the vowel reports no glyph of its own'
	assert hangul_at(line.glyphs, 2) == none, 'the trailing part reports no glyph of its own'
	mixed := hangul_line(f, [rune(0xAC00), rune(0x1100), rune(0x1161)])
	assert mixed.glyphs.len == 2, 'precomposed plus composing draws two, got ${hangul_dump(mixed)}'
	assert mixed.glyphs[0].gid == 0x284c && mixed.glyphs[1].gid == 0x284c, 'both halves are the GA glyph'
	assert mixed.glyphs[0].cluster == 0 && mixed.glyphs[1].cluster == 1, 'clusters stay with their inputs'
}

fn test_hangul_compat_jamo_stay_separate() {
	// HarfBuzz never composes compatibility Jamo: 3131 314F draws two
	// glyphs 0x69c and 0x6ba on clusters 0 and 1 at advance 920 each.
	// A lone conjoining lead is the same story: one cmap glyph 0x174.
	f := hangul_font('NotoSansKR-Variable.ttf') or { return }
	line := hangul_line(f, [rune(0x3131), rune(0x314F)])
	assert line.glyphs.len == 2, 'compat Jamo stay two glyphs, got ${hangul_dump(line)}'
	a := hangul_at(line.glyphs, 0) or { panic('compat KIYEOK drew nothing') }
	assert a.gid == 0x69c, 'compat KIYEOK is its cmap glyph, got ${a.gid:x}'
	b := hangul_at(line.glyphs, 1) or { panic('compat A drew nothing') }
	assert b.gid == 0x6ba, 'compat A is its cmap glyph, got ${b.gid:x}'
	lone := hangul_line(f, [rune(0x1100)])
	assert lone.glyphs.len == 1, 'a lone lead draws one glyph, got ${hangul_dump(lone)}'
	assert lone.glyphs[0].gid == 0x174, 'a lone lead is its cmap glyph, got ${lone.glyphs[0].gid:x}'
}

fn test_hangul_composition_is_live() {
	// Break-fix control: the fold above is what turns two decomposed
	// parts into one syllable. The raw NFD of GA is two runes, so a
	// neutered composition lays out two glyphs and the count pins fail;
	// the unit pin below fails the same way, off by one syllable.
	ctx := shape.new_context()
	raw := ctx.normalizer.nfd([rune(0xAC00)])
	assert raw.len == 2, 'NFD splits GA into lead plus vowel, got ${raw.len}'
	assert raw[0] == rune(0x1100) && raw[1] == rune(0x1161), 'NFD names the conjoining parts'
	composed, map_ := shape.compose_hangul_runs([rune(0x1100), rune(0x1161)], [5, 6])
	assert composed == [rune(0xAC00)], 'the run folds to GA'
	assert map_ == [5], 'the syllable reports its first input'
	assert composed[0] != rune(0xAC01), 'off-by-one syllable must not match: the pin is exact'
	f := hangul_font('NotoSansKR-Variable.ttf') or { return }
	line := hangul_line(f, [rune(0x1100), rune(0x1161)])
	assert line.glyphs.len == 1, 'the layout folds where the unit folds, got ${hangul_dump(line)}'
	assert line.glyphs.len != raw.len, 'a neutered composition would lay out the raw two'
}

fn test_hangul_draws_bases() {
	// One rasterised syllable and one rasterised Jamo part: a face that
	// shapes but never inks is a face the test cannot see.
	f := hangul_font('NotoSansKR-Variable.ttf') or { return }
	ga := f.rasterize(f.glyph_index(rune(0xAC00)), 32.0, 0, 0)
	assert !ga.is_empty(), 'GA rasterises'
	lead := f.rasterize(f.glyph_index(rune(0x1100)), 32.0, 0, 0)
	assert !lead.is_empty(), 'the choseong part rasterises'
}

fn test_hangul_vertical_punctuation_substitutes() {
	// The vert pin in the vertical_test pattern: the ideographic comma
	// draws its vertical variant in vertical mode while a CJK letter
	// without one is unchanged. The gids are the fontTools-measured ones
	// for NotoSansKR, and the horizontal halves prove the mode is what
	// substitutes rather than the text.
	f := hangul_font('NotoSansKR-Variable.ttf') or { return }
	hline := hangul_line(f, [rune(0x3001), rune(0x4E00)])
	assert hline.glyphs.len == 2
	assert hline.glyphs[0].gid == 0x575, 'horizontal comma, got ${hline.glyphs[0].gid:x}'
	assert hline.glyphs[1].gid == 0x9e7, 'horizontal CJK, got ${hline.glyphs[1].gid:x}'
	vline := hangul_vline(f, [rune(0x3001), rune(0x4E00)])
	assert vline.glyphs.len == 2
	assert vline.glyphs[0].gid == 0x548e, 'vertical comma, got ${vline.glyphs[0].gid:x}'
	assert vline.glyphs[1].gid == 0x9e7, 'CJK letter has no vertical form'
	brackets := hangul_vline(f, [rune(0x300C), rune(0x4E00), rune(0x300D)])
	assert brackets.glyphs.len == 3
	assert brackets.glyphs[0].gid == 0x54a8, 'open bracket substitutes, got ${brackets.glyphs[0].gid:x}'
	assert brackets.glyphs[1].gid == 0x9e7, 'CJK letter has no vertical form'
	assert brackets.glyphs[2].gid == 0x54a9, 'close bracket substitutes, got ${brackets.glyphs[2].gid:x}'
}

fn test_hangul_vertical_line_places_downward() {
	// A vertical line is one column: full-width advance boxes at x 0
	// with y accumulating downward by 1000-unit steps, hung below the
	// pen by the vhea ascender (500 units). At 32 px on this upm-1000
	// face the step is 32.0 and the hang is 16.0, which is the TTB
	// geometry HarfBuzz reports beside the same gids.
	f := hangul_font('NotoSansKR-Variable.ttf') or { return }
	vline := hangul_vline(f, [rune(0x3001), rune(0x4E00)])
	assert vline.glyphs.len == 2, 'two characters draw two glyphs, got ${hangul_dump(vline)}'
	assert vline.glyphs[0].gid == 0x548e, 'vertical comma'
	assert vline.glyphs[1].gid == 0x9e7, 'CJK letter'
	for g in vline.glyphs {
		assert g.x == 0, 'full-width fills the column'
		assert g.advance == 32.0, 'full vertical step'
	}
	assert vline.glyphs[0].y == -16.0, 'hung below the pen by the vhea ascender'
	assert vline.glyphs[1].y == 16.0, 'second step starts where the first ends'
	assert vline.width == 32.0, 'column fits the full em'
	assert vline.height == 48.0, 'shifted column extent'
	assert vline.line_height == 32.0, 'stacking step is the column width'
	assert vline.ascent == 0, 'no horizontal ink metrics on a vertical line'
	assert vline.descent == 0
	hline := hangul_line(f, [rune(0x3001), rune(0x4E00)])
	assert hline.glyphs[0].x == 0
	assert hline.glyphs[1].x == 32.0, 'horizontal advances rightward by full steps'
	assert hline.height == 0, 'height is the vertical mode field'
}
