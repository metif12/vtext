module vtext

// Tests for line layout: the passes meeting, in the order a caller sees them.

import os

// approx reports whether two pixel measurements agree to within tol. Advance widths come out
// of a scale from font units, so an exact compare is the wrong test.
fn approx(got f64, want f64, tol f64) bool {
	d := got - want
	return d > -tol && d < tol
}

// glyph_at_cluster returns the glyph that came from the input character at that index.
fn glyph_at_cluster(glyphs []Glyph, cluster int) ?Glyph {
	for g in glyphs {
		if g.cluster == cluster {
			return g
		}
	}
	return none
}

// font_from loads a font from the Windows font directory, which is where the tests get a
// real cmap and real metrics from.
fn font_from(name string) &Font {
	path := os.join_path('C:\\Windows\\Fonts', name)
	return load_font_file(path) or { panic(err) }
}

// persian_fonts returns the chain the Persian tests use.
//
// Segoe UI is first because it carries the Arabic presentation forms, so the shaping the
// joining pass did is what actually reaches the screen and the glyph counts are decided by
// the pipeline rather than by whichever font happens to be installed. Dubai is behind it as
// a real second opinion, and is the font the base-letter tests use on its own.
fn persian_fonts() &FontSet {
	fs := new_font_set()
	fs.add(font_from('segoeui.ttf'))
	fs.add(font_from('DUBAI-REGULAR.TTF'))
	return fs
}

fn test_layout_latin_line_runs_left_to_right() {
	ctx := new_context()
	fs := new_font_set_of(font_from('segoeui.ttf'))
	line := layout_paragraph(ctx, [`a`, `b`, `c`], .ltr, fs, 32)
	assert line.paragraph_level == 0, 'a forced LTR paragraph is level 0'
	assert line.glyphs.len == 3, 'three letters should give three glyphs'
	// Visual order is logical order here, and the clusters are the input positions.
	for i in 0 .. 3 {
		assert line.glyphs[i].cluster == i
	}
	// Each glyph starts where the previous one ended.
	mut x := f64(0)
	for g in line.glyphs {
		assert approx(g.x, x, 0.001), 'glyph at x ${g.x} should be at ${x}'
		x += g.advance
	}
	assert approx(line.width, x, 0.001), 'the line is as wide as its advances'
	assert line.ascent > 0 && line.descent > 0, 'the line reports a vertical extent'
}

fn test_layout_rtl_line_reverses_the_glyphs() {
	ctx := new_context()
	fs := persian_fonts()
	// sin lam alef meem. The lam and the alef are one glyph, so four characters give three
	// glyphs, and the paragraph is right to left so they come back reversed.
	line := layout_paragraph(ctx, [`س`, `ل`, `ا`, `م`], .auto, fs, 32)
	assert line.paragraph_level == 1, '.auto should read the direction off the text'
	assert line.glyphs.len == 3, 'the lam-alef is one glyph, so 3 not 4'
	// The meem is the first character written and the leftmost drawn.
	assert line.glyphs[0].cluster == 3, 'the meem is drawn leftmost'
	assert line.glyphs[1].cluster == 1, 'the lam-alef is drawn next'
	assert line.glyphs[2].cluster == 0, 'the sin is drawn rightmost'
	// x still increases left to right whatever the direction.
	for i in 0 .. line.glyphs.len {
		if i == 0 {
			continue
		}
		assert line.glyphs[i].x >= line.glyphs[i - 1].x, 'x must not go backwards'
	}
}

fn test_layout_covers_every_visible_character() {
	ctx := new_context()
	fs := persian_fonts()
	cps := [`س`, `ل`, `ا`, `م`]
	line := layout_paragraph(ctx, cps, .rtl, fs, 32)
	mut seen := map[int]bool{}
	for g in line.glyphs {
		seen[g.cluster] = true
	}
	// Every character that was written has to have produced a glyph. The alef of the
	// lam-alef is the exception, because that character is drawn by the ligature's glyph
	// and the ligature reports the lam.
	assert seen[0] && seen[1] && seen[3], 'every character outside the ligature needs a glyph'
	assert !seen[2], 'the alef is covered by the lam-alef glyph, not by one of its own'
}

fn test_layout_places_a_mark_on_its_letter() {
	ctx := new_context()
	fs := persian_fonts()
	// beh + fatha: the mark is a glyph of its own, but it costs nothing and sits where the
	// beh is.
	line := layout_paragraph(ctx, [`ب`, rune(0x064E)], .rtl, fs, 32)
	assert line.glyphs.len == 2, 'the mark is a glyph of its own'
	mark := glyph_at_cluster(line.glyphs, 1) or { panic('no mark glyph') }
	base := glyph_at_cluster(line.glyphs, 0) or { panic('no base glyph') }
	assert mark.is_mark && !base.is_mark, 'only the mark is a mark'
	assert mark.advance == 0, 'the mark costs no advance'
	assert approx(mark.x, base.x, 0.001), 'the mark sits on the letter it follows'
	// A mark must not widen the line, and the two glyphs are the only ones on it.
	assert approx(line.width, base.advance, 0.001), 'the mark adds no width'
}

fn test_layout_draws_marks_after_letters() {
	ctx := new_context()
	fs := persian_fonts()
	line := layout_paragraph(ctx, [`ب`, rune(0x064E)], .rtl, fs, 32)
	order := line.draw_order()
	assert order.len == 2
	// The mark shares a position with its letter, so whichever is painted last is on top,
	// and the mark has to be that one or the letter hides its own accent.
	assert !order[0].is_mark && order[1].is_mark, 'marks are painted last'
}

fn test_layout_mixed_script_uses_fallback() {
	ctx := new_context()
	fs := persian_fonts()
	// A Persian letter with a Latin digit, which is the shape of a real line with a number
	// in it.
	line := layout_paragraph(ctx, [`س`, `1`], .rtl, fs, 32)
	assert line.glyphs.len == 2
	letter := glyph_at_cluster(line.glyphs, 0) or { panic('no letter glyph') }
	digit := glyph_at_cluster(line.glyphs, 1) or { panic('no digit glyph') }
	// Both scripts resolve to real glyphs, and each glyph names a font that is actually in
	// the chain. Which one of the two serves a given character is a question about the
	// installed fonts, and the dedicated fallback test below is where the chain itself is
	// held to account.
	assert letter.gid != 0 && digit.gid != 0, 'both have to be real glyphs'
	for g in line.glyphs {
		f := g.font or { panic('a glyph has to name its font') }
		assert f == fs.fonts[0] || f == fs.fonts[1], 'the font has to be one the caller asked for'
	}
	// A digit and a letter are the same height on the line, so the pen moves by their
	// advances and nothing else.
	assert line.width == line.glyphs[0].advance + line.glyphs[1].advance
}

// A chain earns its keep when the fonts disagree about a codepoint: the preferred font has
// none, so the one behind it answers. Consolas is a programming font with no Arabic at all,
// which makes the disagreement structural rather than accidental, and Segoe UI carries the
// whole Arabic block.
fn test_layout_falls_back_when_the_preferred_font_lacks_the_codepoint() {
	ctx := new_context()
	mono := font_from('consola.ttf')
	arabic := font_from('segoeui.ttf')
	assert !mono.has_glyph(rune(0xFEFB)) && arabic.has_glyph(rune(0xFEFB))
	fs := new_font_set()
	fs.add(mono)
	fs.add(arabic)

	line := layout_paragraph(ctx, [`س`, `ل`, `ا`, `م`], .rtl, fs, 32)
	assert line.glyphs.len == 3, 'the lam-alef is one glyph, so 3 not 4'
	for g in line.glyphs {
		// The glyph has to come from the font that actually has the character, not from the
		// one that was asked first, and it has to be a real glyph rather than a .notdef box.
		assert (g.font or { panic('a glyph has to name its font') }) == arabic
		assert g.gid != 0, 'the fallback font has to really have this letter'
	}
}

// Dubai is the case that makes the base-letter route necessary. It carries the Arabic
// letters but almost none of the presentation forms, because it keeps its four shapes in a
// GSUB table rather than in the cmap, so the form codepoint the joining pass produced is
// .notdef in it.
fn test_layout_draws_the_base_letter_when_the_form_is_missing() {
	ctx := new_context()
	dubai := font_from('DUBAI-REGULAR.TTF')
	fs := new_font_set_of(dubai)
	// A lone beh is an isolated beh, U+FE8F, which Dubai does not have. It does have the
	// base letter, so that is what gets drawn.
	assert !dubai.has_glyph(rune(0xFE8F)), 'this test is about a font without the form'
	assert dubai.has_glyph(rune(0x0628)), 'Dubai carries the base letter'

	line := layout_paragraph(ctx, [`ب`], .rtl, fs, 32)
	assert line.glyphs.len == 1, 'the base letter stands in for the missing form'
	g := line.glyphs[0]
	assert g.gid == dubai.glyph_index(rune(0x0628)), 'the base letter is what is drawn'
	assert g.gid != 0
	// The shape is still carried, because that is what the OpenType pass needs to pick the
	// right variant of the base letter.
	assert g.form == .isolated, 'the shape survives the missing form'
}

// A lam-alef is the one shaped letter that can stand for two characters, so a font without
// the ligature form has to draw two letters rather than one.
//
// Arabic Typesetting is the font that shows this on Windows: it carries the base Arabic
// letters and no presentation forms at all, because it puts all four shapes in a GSUB table.
// Every shaped letter laid out against it comes out as its base letter, and the ligature, which
// has no single base letter, is the one that has to come apart.
fn test_layout_splits_a_ligature_the_font_does_not_have() {
	ctx := new_context()
	arabic := font_from('ARABTYPE.TTF')
	fs := new_font_set_of(arabic)
	// A lam and an alef with nothing either side of them: the pair is isolated, U+FEFB.
	assert !arabic.has_glyph(rune(0xFEFB)), 'this test is about a font with no forms'
	assert !arabic.has_glyph(rune(0xFEFC)), 'this test is about a font with no forms'
	assert arabic.has_glyph(rune(0x0644)) && arabic.has_glyph(rune(0x0627)), 'it has both base letters'

	line := layout_paragraph(ctx, [`ل`, `ا`], .rtl, fs, 32)
	// One glyph would be the ligature. Two means the pair was drawn as its two letters.
	assert line.glyphs.len == 2, 'the ligature is drawn as a lam and an alef'
	mut clusters := []int{}
	for g in line.glyphs {
		clusters << g.cluster
	}
	// The alef is the second character written and, in a right-to-left line, the leftmost
	// drawn. Each half of the pair keeps its own input position, which is what makes the two
	// traceable back to the lam and the alef separately.
	assert clusters == [1, 0]
	lam := glyph_at_cluster(line.glyphs, 0) or { panic('no lam glyph') }
	alef := glyph_at_cluster(line.glyphs, 1) or { panic('no alef glyph') }
	// Both halves are real glyphs, because this font does carry the base letters.
	assert lam.gid == arabic.glyph_index(rune(0x0644))
	assert alef.gid == arabic.glyph_index(rune(0x0627))
	// Nothing joined to the pair, so neither half is final.
	assert lam.form == .isolated && alef.form == .isolated
}

// The same line laid out with only a font that has neither the letter nor the form has to
// report .notdef rather than quietly borrowing from a font the caller did not ask for.
fn test_layout_reports_notdef_when_no_font_covers() {
	ctx := new_context()
	mono := font_from('consola.ttf')
	fs := new_font_set_of(mono)
	// The form is missing, so the base letter is asked for instead, and that is missing too.
	assert !mono.has_glyph(rune(0x0628))
	line := layout_paragraph(ctx, [`ب`], .rtl, fs, 32)
	assert line.glyphs.len == 1, 'the character is still placed, it is just not drawn properly'
	g := line.glyphs[0]
	assert g.gid == 0, 'no font in the chain has this letter, so it is .notdef'
	assert (g.font or { panic('a glyph has to name its font') }) == mono
}

// Rule X9 removes the characters that only exist to steer the algorithm, so they are never
// drawn. U+2060 WORD JOINER is one of them: a format character with no glyph and no width.
fn test_layout_strips_x9_removed_format_controls() {
	ctx := new_context()
	fs := persian_fonts()
	word_joiner := rune(0x2060)
	assert ctx.properties.bidi_class_of(word_joiner) == .bn, 'U+2060 is meant to be BN'
	// It has to disappear without disturbing the rest of the line: the two glyphs that
	// survive are the same two, in the same order, as wide, at the same places. Only the
	// cluster numbers move, because the control did take an input position of its own, and
	// so the second letter is the third character written.
	marked := layout_paragraph(ctx, [`س`, word_joiner, `م`], .rtl, fs, 32)
	plain := layout_paragraph(ctx, [`س`, `م`], .rtl, fs, 32)
	assert marked.glyphs.len == 2, 'the format control is not drawn'
	assert marked.glyphs.len == plain.glyphs.len
	mut marked_clusters := []int{}
	for g in marked.glyphs {
		marked_clusters << g.cluster
	}
	mut plain_clusters := []int{}
	for g in plain.glyphs {
		plain_clusters << g.cluster
	}
	assert marked_clusters == [2, 0], 'the control took input position 1 and drew nothing'
	assert plain_clusters == [1, 0]
	for i in 0 .. plain.glyphs.len {
		assert marked.glyphs[i].x == plain.glyphs[i].x
		assert marked.glyphs[i].gid == plain.glyphs[i].gid
	}
	assert marked.width == plain.width, 'a character with no width must not move the line'
}

fn test_layout_empty_input_gives_an_empty_line() {
	ctx := new_context()
	fs := persian_fonts()
	line := layout_paragraph(ctx, []rune{}, .auto, fs, 32)
	assert line.glyphs.len == 0
	assert line.width == 0
	assert line.ascent == 0 && line.descent == 0
}

fn test_layout_zwnj_drops_out_and_keeps_the_rest() {
	ctx := new_context()
	fs := persian_fonts()
	// beh ZWNJ beh: the non-joiner breaks the join, so both behs are isolated, and the
	// control itself contributes no glyph.
	line := layout_paragraph(ctx, [`ب`, rune(0x200C), `ب`], .rtl, fs, 32)
	assert line.glyphs.len == 2, 'the ZWNJ is not drawn'
	for g in line.glyphs {
		assert g.gid != 0
	}
}
