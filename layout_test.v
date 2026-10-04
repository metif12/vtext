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
	// beh + fatha: the mark is a glyph of its own, but it costs nothing and sits on the beh.
	line := layout_paragraph(ctx, [`ب`, rune(0x064E)], .rtl, fs, 32)
	assert line.glyphs.len == 2, 'the mark is a glyph of its own'
	mark := glyph_at_cluster(line.glyphs, 1) or { panic('no mark glyph') }
	base := glyph_at_cluster(line.glyphs, 0) or { panic('no base glyph') }
	assert mark.is_mark && !base.is_mark, 'only the mark is a mark'
	assert mark.advance == 0, 'the mark costs no advance'
	// The mark is not at the pen: it is at the anchor the font gives it, which is the whole point
	// of parsing GPOS. Before the font's own glyph for a fatha was being read, this pair had no
	// rule and the mark landed on the baseline beside the letter, which is a legible but wrong
	// accent and is exactly what the earlier cmap bug produced.
	f := font_from('segoeui.ttf')
	off := f.mark_offset(f.glyph_index(rune(0x064E)), f.glyph_index(rune(0x0628)), false) or {
		panic('the font should have an offset for this pair')
	}
	scale := 32.0 / f64(f.units_per_em())
	assert approx(mark.x - base.x, f64(off.x) * scale, 0.01), 'the mark sits at the font horizontal anchor'
	// Font y is positive upwards and the line's is positive downwards, so the mark's y is the
	// negation of the font's.
	assert approx(mark.y, -f64(off.y) * scale, 0.01), 'the mark sits at the font vertical anchor'
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

// ExpectedLetter is a base codepoint, the shape a word gives it, and whether the font is
// expected to carry that shape in its substitution table. The last is there so that a test can
// cover both routes at once: a letter the font shapes, and one it does not.
struct ExpectedLetter {
	base   rune
	form   JoiningForm
	shaped bool
}

// The point of the whole GSUB pass: a Persian word laid out against a font that keeps its
// Arabic shapes in a substitution table comes out with each letter in the shape the joining
// pass chose, and each glyph carrying its own advance.
// The point of the whole GSUB pass: a Persian word laid out against a font that keeps some of
// its Arabic shapes only in a substitution table comes out with each letter in the shape the
// joining pass chose, and each glyph carrying its own advance.
fn test_layout_shapes_persian_through_gsub() {
	ctx := new_context()
	// Majalla is the font that shows this. It carries most of its Arabic presentation forms in
	// the cmap but is missing some of them, so the letters whose forms it lacks can only be
	// drawn correctly shaped by going through the table. Dubai, which carries almost none of
	// them, would put every letter on the table route and this test would not tell the two
	// apart.
	//
	// The font is one whose cmap is genuinely incomplete for the word, which is the only way this
	// test can tell the two routes apart. Most Arabic fonts on Windows carry every presentation
	// form of these letters, and a font that does has nothing to send down the table route at all,
	// so choosing one of those would leave this asserting half of what it claims to.
	arabic := font_from('trado.ttf')
	assert arabic.has_gsub(), 'this test is about a font that shapes through GSUB'
	fs := new_font_set_of(arabic)

	// beh sin lam kaf yeh meem. A word with a letter in each position is the only way to reach
	// the medial and final forms: a letter on its own is isolated, and a probe that forgets
	// that reports the wrong thing about the other three shapes.
	//
	// The middle letters are the interesting ones. This font carries the presentation form for
	// all of them but the yeh, so the yeh has to be shaped through the table instead, and that
	// one letter is what makes the word worth testing.
	word := [`ب`, `س`, `ل`, `ک`, `ی`, `م`]
	line := layout_paragraph(ctx, word, .rtl, fs, 32)
	assert line.paragraph_level == 1, 'Persian resolves to a right-to-left paragraph'
	assert line.glyphs.len == 6, 'six letters give six glyphs'
	assert line.glyphs[0].cluster == 5, 'the meem is written last and drawn leftmost'

	// The shape the joining pass gave each letter, and what this font is expected to draw for
	// it. The form codepoint comes from the shaper rather than being written out, so a change to
	// the joining tables shows up here as a failure about the shape rather than about a glyph.
	run := ctx.shaper.shape_arabic(ctx.properties, word)
	assert run.glyphs.len == 6, 'the word should shape into one glyph per letter'
	// base, the shape the word gives it, and whether the letter is one this font keeps its
	// shape for in the table rather than in the cmap. The last column is what makes the word
	// worth testing: it has to contain a letter of each kind, or the word only exercises the
	// route that is already known to work.
	expected := [
		ExpectedLetter{rune(0x0628), JoiningForm.initial, false}, // beh, has a cmap form
		ExpectedLetter{rune(0x0633), JoiningForm.medial, false}, // sin, has a cmap form
		ExpectedLetter{rune(0x0644), JoiningForm.medial, false}, // lam, has a cmap form
		ExpectedLetter{rune(0x06A9), JoiningForm.medial, false}, // kaf, has a cmap form
		ExpectedLetter{rune(0x06CC), JoiningForm.medial, true}, // yeh, no cmap form, so the table
		ExpectedLetter{rune(0x0645), JoiningForm.final, false}, // meem, has a cmap form
	]
	// The word has to contain at least one letter of each kind, or this test is not covering
	// both routes and would pass even if one of them were broken.
	mut via_cmap := 0
	mut via_table := 0
	for i, e in expected {
		if arabic.has_glyph(run.glyphs[i].cps[0]) {
			via_cmap++
		} else {
			via_table++
		}
	}
	assert via_cmap > 0 && via_table > 0, 'the word should exercise both the cmap route and the table route'
	mut width := f64(0)
	for i, e in expected {
		// The line is in visual order and the word is right to left, so the glyphs are asked
		// for by the input character they came from rather than by position on the line.
		g := glyph_at_cluster(line.glyphs, i) or { panic('no glyph for the character at ${i}') }
		sg := run.glyphs[i]
		assert sg.form == e.form, 'the letter at ${i} should be shaped ${e.form}'
		assert g.form == e.form, 'the letter at ${i} should be drawn in the ${e.form} shape'

		base := arabic.glyph_index(e.base)
		assert base != 0, 'the font carries the base letter'
		form_cp := sg.cps[0]
		uses_cmap := arabic.has_glyph(form_cp)
		// Whichever route the font layer takes is its business, but the drawn glyph has to be
		// the right one for it, and it must never be .notdef.
		assert g.gid != 0, 'the letter at ${i} came out as .notdef'
		if uses_cmap {
			assert g.gid == arabic.glyph_index(form_cp), 'the letter at ${i} should use the cmap form, which the font has'
		} else {
			// No cmap form, so the letter has to be drawn from its base glyph put through the
			// font's table. The drawn glyph then has to differ from the unjoined base, since a
			// letter with no cmap form is a letter this font only draws correctly shaped.
			want := arabic.shaped_glyph_index(base, e.form, 'arab')
			assert g.gid == want, 'the letter at ${i} should be the font shaped base glyph'
			assert want != base, 'the letter at ${i} is meant to be shaped through GSUB'
			assert e.shaped, 'the letter at ${i} was expected to come from the table'
		}
		// The advance has to belong to the drawn glyph. A shaped form is usually narrower than
		// the base, so reusing the base advance would leave the line the wrong width.
		assert approx(g.advance, arabic.glyph_advance(g.gid, 32), 0.001), 'the letter at ${i} should carry its own advance'
		width += g.advance
	}
	assert approx(line.width, width, 0.001), 'the line is as wide as its shaped advances'
}

// A font that keeps its shapes in the cmap needs no substitution, and a font that has both
// uses the cmap form: it is available without a second lookup, and both name the same shape.
fn test_layout_prefers_the_cmap_form_over_substitution() {
	ctx := new_context()
	segoe := font_from('segoeui.ttf')
	fs := new_font_set_of(segoe)
	line := layout_paragraph(ctx, [`س`], .rtl, fs, 32)
	assert line.glyphs.len == 1
	g := line.glyphs[0]
	assert g.gid == segoe.glyph_index(rune(0xFEB1)), 'the isolated sin form comes from the cmap'
	assert approx(g.advance, segoe.glyph_advance(g.gid, 32), 0.001)
}

// A lam-alef is the one shaped letter that stands for two characters, so it is the only place
// where two input characters are legitimately drawn by one glyph, and the only place where a
// character can be left with no glyph of its own.
//
// This used to assert the opposite, against Arabic Typesetting on the grounds that it carried no
// presentation forms at all. That was an artefact of a cmap bug: the font does carry them, and so
// does every other Arabic font on this machine, so there is now no font here that has the two
// base letters and lacks the ligature. The shape of the pipeline when a form is missing is still
// covered, at the font seam, by test_shaped_glyphs_splits_a_ligature_the_chain_cannot_draw in
// glyph_test.v, which reaches the same branch without needing a font that does not exist.
fn test_a_ligature_covers_both_of_its_characters() {
	ctx := new_context()
	arabic := font_from('ARABTYPE.TTF')
	fs := new_font_set_of(arabic)
	// A lam and an alef with nothing either side of them: the pair is isolated.
	assert arabic.has_glyph(rune(0xFEFB)), 'the font has the isolated form of the pair'
	assert arabic.has_glyph(rune(0x0644)) && arabic.has_glyph(rune(0x0627)), 'it has both base letters'

	line := layout_paragraph(ctx, [`ل`, `ا`], .rtl, fs, 32)
	// One glyph for two characters, and it is the ligature rather than either letter.
	assert line.glyphs.len == 1, 'the pair should be one glyph, got ${line.glyphs.len}'
	fused := line.glyphs[0]
	assert fused.gid == arabic.glyph_index(rune(0xFEFB)), 'the fused glyph is the ligature form'
	// It reports the lam, which is the first character written, so a caret can still be traced
	// back to the text.
	assert fused.cluster == 0, 'the fused glyph reports the first of its two characters'
	// The alef's character is covered by that glyph rather than being drawn separately, which is
	// what keeps the pair from coming out as three things on the line.
	assert glyph_at_cluster(line.glyphs, 1) == none, 'the alef is covered by the ligature'
	// And the pair is narrower fused than apart, which is the reason it is fused at all.
	assert approx(fused.advance, arabic.glyph_advance(fused.gid, 32), 0.001)
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

// A mark's cluster is the character the reader wrote, not the position the mark ended up in after
// normalization reordered it.
fn test_layout_a_mark_reports_its_own_character_after_reordering() {
	ctx := new_context()
	f := font_from('tahoma.ttf')
	fs := new_font_set_of(f)
	beh := f.glyph_index(0x0628)
	shadda := f.glyph_index(0x0651)
	fatha := f.glyph_index(0x064E)
	// Written as beh, shadda, fatha. A shadda is a higher combining class than a fatha, so
	// decomposition has to swap them, which used to hand each mark the other's cluster and leave
	// the shadda looking for a base it was not written after.
	line := layout_paragraph(ctx, [rune(0x0628), rune(0x0651), rune(0x064E)], .rtl, fs, 64)
	mut seen := map[int]int{}
	for g in line.glyphs {
		seen[g.cluster] = g.gid
	}
	assert seen[0] == beh
	assert seen[1] == shadda, 'the shadda reports the character it was written for'
	assert seen[2] == fatha, 'the fatha reports the character it was written for'
}

// Letter spacing goes onto advances, not onto positions, so the line's width and the positions have to
// come out of the same number. That is the whole assertion: a spacing pass that moved x instead of
// advance would make these two disagree and the line would still draw correctly.
fn test_letter_spacing_adds_to_every_letter_advance() {
	ctx := new_context()
	fs := new_font_set_of(font_from('segoeui.ttf'))
	cps := [`a`, `b`, `c`]
	plain := layout_paragraph(ctx, cps, .ltr, fs, 32)
	mut opts := LayoutOptions{}
	opts.letter_spacing = 2.0
	spaced := layout_paragraph_with(ctx, cps, .ltr, fs, 32, &opts)

	assert spaced.glyphs.len == plain.glyphs.len, 'spacing must not change how many glyphs there are'
	for i in 0 .. spaced.glyphs.len {
		assert approx(spaced.glyphs[i].advance, plain.glyphs[i].advance + 2.0, 0.001), 'letter ${i}: advance ${spaced.glyphs[i].advance} should be ${plain.glyphs[i].advance} + 2'
	}
	// Three letters and three additions, including the last: letter spacing trails every character,
	// which is what CSS says and what makes a caller's own arithmetic agree with this engine's.
	assert approx(spaced.width, plain.width + 6.0, 0.001), 'width ${spaced.width} should be ${plain.width} + 3 * 2'
	// And the advances still add up to the width, which is the invariant a spacing pass on x would break.
	mut sum := f64(0)
	for g in spaced.glyphs {
		sum += g.advance
	}
	assert approx(sum, spaced.width, 0.001), 'the advances must still account for the whole width'
}

// Negative spacing tightens rather than failing, because that is what a caller setting a negative value
// is asking for and a text engine that refused would force them to scale the font instead.
fn test_letter_spacing_can_be_negative() {
	ctx := new_context()
	fs := new_font_set_of(font_from('segoeui.ttf'))
	cps := [`a`, `b`, `c`, `d`, `e`, `f`]
	plain := layout_paragraph(ctx, cps, .ltr, fs, 32)
	mut opts := LayoutOptions{}
	opts.letter_spacing = -1.5
	spaced := layout_paragraph_with(ctx, cps, .ltr, fs, 32, &opts)
	assert approx(spaced.width, plain.width - 9.0, 0.001), 'six letters tightened by 1.5 each'
	assert spaced.width < plain.width
}

// A mark is not a letter. It shares its base's position and has no advance, so paying it letter spacing
// would charge one character twice and push everything after it along by a spacing nobody asked for.
fn test_a_combining_mark_does_not_take_letter_spacing() {
	ctx := new_context()
	fs := new_font_set_of(font_from('tahoma.ttf'))
	cps := [rune(0x0628), rune(0x064E)] // beh with a fatha
	plain := layout_paragraph(ctx, cps, .rtl, fs, 32)
	mut opts := LayoutOptions{}
	opts.letter_spacing = 2.0
	spaced := layout_paragraph_with(ctx, cps, .rtl, fs, 32, &opts)

	mut marks := 0
	for g in spaced.glyphs {
		if g.is_mark {
			marks++
			assert g.advance == 0.0, 'a mark has no advance whatever the spacing'
		}
	}
	assert marks == 1, 'there should be one mark on this pair, got ${marks}'
	// One letter paid the spacing once. Two would mean the mark was counted as a letter.
	assert approx(spaced.width, plain.width + 2.0, 0.001), 'width ${spaced.width} should be ${plain.width} + 2, not + 4'
}

// Word spacing is on top of letter spacing and only on the spaces. Charging it to every character would
// make it indistinguishable from letter spacing, which is the difference between a property and a second
// name for one.
fn test_word_spacing_moves_only_the_spaces() {
	ctx := new_context()
	fs := new_font_set_of(font_from('segoeui.ttf'))
	cps := [`a`, ` `, `b`, ` `, `c`] // two spaces
	plain := layout_paragraph(ctx, cps, .ltr, fs, 32)
	mut opts := LayoutOptions{}
	opts.word_spacing = 3.0
	spaced := layout_paragraph_with(ctx, cps, .ltr, fs, 32, &opts)
	assert approx(spaced.width, plain.width + 6.0, 0.001), 'two spaces widened by 3 each'

	mut with_both := LayoutOptions{}
	with_both.letter_spacing = 1.0
	with_both.word_spacing = 3.0
	// Three letters, two spaces: five characters for the letter spacing and two more for the word spacing.
	both := layout_paragraph_with(ctx, cps, .ltr, fs, 32, &with_both)
	assert approx(both.width, plain.width + 5.0 + 6.0, 0.001), 'letter spacing applies to all five characters and word spacing to the two spaces'
}

// The font's own line height is the default, and it is the largest among the fonts that contributed
// rather than the first one's, because a paragraph that fell back mid-line is spaced for the tallest face
// in it.
fn test_line_height_defaults_to_the_font_and_takes_an_override() {
	ctx := new_context()
	f := font_from('segoeui.ttf')
	fs := new_font_set_of(f)
	cps := [`a`, `b`, `c`]
	line := layout_paragraph(ctx, cps, .ltr, fs, 32)
	assert approx(line.line_height, f.line_height(32.0), 0.001), 'line height ${line.line_height} should be the font own ${f.line_height(32.0)}'

	mut opts := LayoutOptions{}
	opts.line_height = 50.0
	tall := layout_paragraph_with(ctx, cps, .ltr, fs, 32, &opts)
	assert tall.line_height == 50.0, 'the caller asked for 50 and got ${tall.line_height}'
	// The box moved and the ink did not. This is the distinction the field exists to make: ascent and
	// descent are how far the ink reaches, and shrinking them to fit a smaller box would be reporting an
	// extent this engine never measured.
	assert approx(tall.ascent, line.ascent, 0.001), 'a taller box must not change the ink'
	assert approx(tall.descent, line.descent, 0.001), 'a taller box must not change the ink'
}

// Every wrapped line reports the paragraph's line height, because a caller stacking them by one number
// has to get the same answer from each. A line that reported its own would make the stack drift.
fn test_wrapped_lines_all_report_the_same_line_height() {
	ctx := new_context()
	fs := new_font_set_of(font_from('segoeui.ttf'))
	cps := 'the quick brown fox jumps over the lazy dog'.runes()
	mut opts := LayoutOptions{}
	opts.line_height = 44.0
	runs := wrap_paragraph_with(ctx, cps, .ltr, fs, 32, 200.0, &opts)
	assert runs.len > 2, 'this text should wrap into several lines at 200, got ${runs.len}'
	for w in runs {
		assert w.line.line_height == 44.0, 'every line reports the same box, got ${w.line.line_height}'
	}
}

// The narrowest width is the widest unbreakable unit, measured without the space that ends its line.
//
// The comparison is computed rather than hardcoded so the test says what it means: if the font happened
// to make the first word the widest one tomorrow, this would still be the right assertion.
fn test_min_content_width_is_the_widest_word_without_its_space() {
	ctx := new_context()
	fs := new_font_set_of(font_from('segoeui.ttf'))
	cps := 'the quick brown fox'.runes()
	m := measure_paragraph(ctx, cps, .ltr, fs, 32)

	words := [[`t`, `h`, `e`], [`q`, `u`, `i`, `c`, `k`], [`b`, `r`, `o`, `w`, `n`], [`f`, `o`,
		`x`]]
	mut widest := f64(0)
	for w in words {
		x := layout_paragraph(ctx, w, .ltr, fs, 32).width
		if x > widest {
			widest = x
		}
	}
	assert approx(m.min_content_width, widest, 0.001), 'narrowest ${m.min_content_width} should be the widest word ${widest}'
	assert m.min_content_width < m.max_content_width, 'the narrowest is narrower than the widest'
}

// This is the mistake the function exists to remove, so it is pinned rather than described. The widest
// wrapped line carries the space that ended it, so taking the number from wrap_paragraph gives a minimum
// width one space too wide on every word.
fn test_min_content_width_excludes_the_trailing_space_a_wrapped_line_carries() {
	ctx := new_context()
	f := font_from('segoeui.ttf')
	fs := new_font_set_of(f)
	cps := 'the quick brown fox'.runes()
	m := measure_paragraph(ctx, cps, .ltr, fs, 32)

	runs := wrap_paragraph(ctx, cps, .ltr, fs, 32, 0.0)
	mut from_wrapped := f64(0)
	for w in runs {
		if w.line.width > from_wrapped {
			from_wrapped = w.line.width
		}
	}
	space := f.glyph_advance(f.glyph_index(` `), 32.0)
	assert from_wrapped > m.min_content_width, 'a wrapped line is ${from_wrapped} and the minimum is ${m.min_content_width}'
	assert approx(from_wrapped - m.min_content_width, space, 0.5), 'the difference is one space of ${space} and nothing else, got ${from_wrapped - m.min_content_width}'
}

// A paragraph of spaces has no unbreakable unit in it, so it collapses to nothing. Charging it one space
// would mean a paragraph that is entirely whitespace reports a non-zero minimum width.
fn test_a_paragraph_of_spaces_collapses_to_nothing() {
	ctx := new_context()
	fs := new_font_set_of(font_from('segoeui.ttf'))
	m := measure_paragraph(ctx, '   '.runes(), .ltr, fs, 32)
	assert m.min_content_width == 0.0, 'spaces alone are not content, got ${m.min_content_width}'
	assert m.max_content_width > 0.0, 'the space still has a width when it is laid out'
}

// Both widths come out of one shaping, and the widest is the same number layout_paragraph reports. If
// these two could disagree, a caller measuring a box and a caller drawing into it would be sizing
// different lines.
fn test_measurement_agrees_with_layout() {
	ctx := new_context()
	fs := new_font_set_of(font_from('segoeui.ttf'))
	cps := 'the quick brown fox'.runes()
	m := measure_paragraph(ctx, cps, .ltr, fs, 32)
	line := layout_paragraph(ctx, cps, .ltr, fs, 32)
	assert approx(m.max_content_width, line.width, 0.001), 'measured ${m.max_content_width} against laid out ${line.width}'
	assert approx(m.ascent, line.ascent, 0.001)
	assert approx(m.descent, line.descent, 0.001)
	assert approx(m.line_height, line.line_height, 0.001)
	// The total of the per-character advances is the furthest the pen reached, because place_glyphs
	// accumulates x as a running sum from zero. That is what lets the segments of a paragraph be summed
	// back up, and it is a property of the positioner rather than of this function.
	mut sum := f64(0)
	for g in line.glyphs {
		sum += g.advance
	}
	assert approx(sum, line.width, 0.001), 'the advances must account for the whole line'
}

// The same holds in the other direction, where visual order is the reverse of the writing and a
// measurement that indexed glyphs by position would report the wrong segment widths.
fn test_measurement_works_for_a_right_to_left_paragraph() {
	ctx := new_context()
	fs := persian_fonts()
	cps := 'سلام دنیا'.runes()
	m := measure_paragraph(ctx, cps, .rtl, fs, 32)
	line := layout_paragraph(ctx, cps, .rtl, fs, 32)
	assert approx(m.max_content_width, line.width, 0.001), 'measured ${m.max_content_width} against laid out ${line.width}'
	assert m.min_content_width > 0.0, 'there is content'
	assert m.min_content_width < m.max_content_width, 'two words break, so the narrowest is smaller'
	mut sum := f64(0)
	for g in line.glyphs {
		sum += g.advance
	}
	assert approx(sum, line.width, 0.001), 'the same invariant holds when the run is reversed'
}

fn test_measurement_of_empty_text_is_all_zeroes() {
	ctx := new_context()
	fs := new_font_set_of(font_from('segoeui.ttf'))
	m := measure_paragraph(ctx, []rune{}, .ltr, fs, 32)
	assert m.min_content_width == 0.0 && m.max_content_width == 0.0
	assert m.ascent == 0.0 && m.descent == 0.0
}

// Wrapping and measuring have to agree about the features they were given. wrap_paragraph used to take no
// options at all, so a paragraph wrapped with liga on was measured without it and every width it reported
// was of a line nobody would draw.
fn test_wrapping_and_measuring_agree_about_features() {
	ctx := new_context()
	fs := persian_fonts()
	cps := 'فارسی'.runes()
	mut opts := LayoutOptions{}
	opts.features = ['liga']

	laid := layout_paragraph_with(ctx, cps, .rtl, fs, 32, &opts)
	measured := measure_paragraph_with(ctx, cps, .rtl, fs, 32, &opts)
	assert approx(measured.max_content_width, laid.width, 0.001), 'measured ${measured.max_content_width} against laid out ${laid.width}'

	runs := wrap_paragraph_with(ctx, cps, .rtl, fs, 32, 10000.0, &opts)
	assert runs.len == 1, 'the whole paragraph fits, got ${runs.len} lines'
	assert approx(runs[0].line.width, laid.width, 0.001), 'wrapped ${runs[0].line.width} against laid out ${laid.width}'

	// And the feature is doing something, or agreeing about it would be untested.
	plain := measure_paragraph(ctx, cps, .rtl, fs, 32)
	assert laid.width < plain.max_content_width, 'liga should narrow this line: ${laid.width} against ${plain.max_content_width}'
}
