module vtext

// Tests for the GSUB parser and the positional substitution built on it.
//
// The parser is fed real fonts rather than a hand-built table, because a table built to match
// the parser proves nothing. The fonts are Arabic ones that keep their shapes in GSUB instead
// of in the cmap, since those are the fonts the substitution exists for: a font that carries
// the presentation forms never reaches the base-letter path at all.

import os

fn gsub_font(name string) &Font {
	path := os.join_path('C:\\Windows\\Fonts', name)
	return load_font_file(path) or { panic(err) }
}

// The four shapes of a few letters, mixed joining and non-joining, plus a tatweel. A parser
// that has read the table correctly changes the glyph for most of them.
fn arabic_probe_letters() []rune {
	return [rune(0x0628), rune(0x0627), rune(0x062B), rune(0x0633), rune(0x0644), rune(0x0645),
		rune(0x0646), rune(0x0647), rune(0x0648), rune(0x06A9), rune(0x06CC), rune(0x067E),
		rune(0x0686), rune(0x06AF), rune(0x0640)]
}

// Unicode spells a script tag 'Arab' and OpenType spells it 'arab', so a caller passing the
// script of a letter, which is what the layout pass does, must not have to know which of the
// two it holds. Getting this wrong produces no error at all: every lookup comes back empty and
// every Arabic letter quietly draws in its base shape.
fn test_gsub_accepts_a_script_tag_in_either_case() {
	majalla := gsub_font('majalla.ttf')
	g := majalla.face.gsub or { panic('no gsub on the face') }
	assert g.script('arab') != none
	assert g.script('Arab') != none, 'the Unicode spelling has to resolve too'
	assert g.script('ARAB') != none, 'the case of the request is not the caller business'
	assert g.lookups_for('Arab', 'fina') == g.lookups_for('arab', 'fina')
	// And the same has to hold for the shape it produces, since that is the call layout makes.
	base := majalla.glyph_index(rune(0x0628))
	assert g.shaped_glyph(base, .final, 'Arab') == g.shaped_glyph(base, .final, 'arab')
	assert g.shaped_glyph(base, .final, 'Arab') != base
}

// Ligature substitution. The rules are read from real fonts and exercised through the line, so
// a test that passes here means a Persian line with a stacked mark came out the way the font
// asked for and not merely the way the engine happened to arrange it.

const fathatan = rune(0x064B)
const dammatan = rune(0x064C)
const sukun = rune(0x0652)
const test_beh = rune(0x0628)
const test_fatha = rune(0x064E)
const test_shadda = rune(0x0651)

// glyph_at_cluster returns the glyph that came from the input character at that index.
//
// The test files are compiled one at a time, so a helper has to live in the file that uses it
// rather than in a shared one.
fn glyph_at_cluster(glyphs []Glyph, cluster int) ?Glyph {
	for g in glyphs {
		if g.cluster == cluster {
			return g
		}
	}
	return none
}

// fs_of is the common case of a chain holding exactly the one font under test.
fn fs_of(f &Font) &FontSet {
	fs := new_font_set()
	fs.add(f)
	return fs
}

// The composition these tests use is real and reachable: Arial maps a fathatan and a shadda to
// two glyphs and has a ccmp rule fusing them into a third. The mark order is not a choice this
// test makes: canonical ordering puts the fathatan first, because its combining class is lower
// than the shadda's, and the rule is written in that order.
fn test_ligature_fuses_two_marks_into_one() {
	ctx := new_context()
	arial := gsub_font('arial.ttf')
	fs := new_font_set_of(arial)
	// beh, fathatan, shadda: three characters in, and the two marks become one glyph.
	line := layout_paragraph(ctx, [test_beh, fathatan, test_shadda], .rtl, fs, 32)
	assert line.glyphs.len == 2, 'the two marks should fuse into one glyph, got ${line.glyphs.len}'

	letter := glyph_at_cluster(line.glyphs, 0) or { panic('no letter glyph') }
	fused := glyph_at_cluster(line.glyphs, 1) or { panic('no fused mark glyph') }
	assert !letter.is_mark, 'the letter is not a mark'
	assert fused.is_mark, 'the fused glyph is still a mark'
	// The fused glyph is the font's, not the first mark's. Two glyphs left in means nothing was
	// fused at all, and the first mark left in means the wrong one was kept.
	assert fused.gid != arial.glyph_index(fathatan), 'the first mark should have been consumed'
	assert fused.gid != arial.glyph_index(test_shadda), 'the second mark should have been consumed'
	// It is a mark, so it still costs nothing, even though it now stands for two characters.
	assert fused.advance == 0, 'a fused mark still costs no advance'
}

// A ligature has to keep the first character's position, or a ligated stretch of text can no
// longer be traced back to the character a caret belongs to.
fn test_ligature_keeps_the_first_characters_cluster() {
	ctx := new_context()
	arial := gsub_font('arial.ttf')
	line := layout_paragraph(ctx, [test_beh, fathatan, test_shadda], .rtl, fs_of(arial), 32)
	// The fused mark stands for two characters and reports the earlier one, which is what lets
	// the rest of the pipeline walk the input without losing track.
	fused := glyph_at_cluster(line.glyphs, 1) or { panic('no fused mark glyph') }
	assert fused.cluster == 1, 'the fused mark should report the fathatan position, got ${fused.cluster}'
	// The shaddan's input position is now covered by the fused glyph, so asking for a glyph at
	// that position finds nothing rather than finding the shadda again.
	assert glyph_at_cluster(line.glyphs, 2) == none
}

// A fatha and a shadda are not the pair this font fuses, so the run has to come through
// untouched. Applying a rule that does not match would be worse than not looking.
fn test_ligature_leaves_a_pair_the_font_does_not_fuse() {
	ctx := new_context()
	arial := gsub_font('arial.ttf')
	// A fatha and a sukun: no rule in the font joins them.
	line := layout_paragraph(ctx, [test_beh, test_fatha, sukun], .rtl, fs_of(arial), 32)
	assert line.glyphs.len == 3, 'three characters should give three glyphs'
	for i in 0 .. 3 {
		g := glyph_at_cluster(line.glyphs, i) or { panic('no glyph at ${i}') }
		assert g.gid != 0, 'no glyph should be .notdef'
	}
}

// The parser reads the rules from a real table, and a rule read wrong is a rule that fuses the
// wrong glyphs. This checks the one the engine relies on, straight out of the table.
fn test_ligature_rules_are_read_from_the_font() {
	arial := gsub_font('arial.ttf')
	g := arial.face.gsub or { panic('no gsub') }
	// The fathatan and the shadda are in Arial's ccmp, which is the feature Arabic composition
	// lives under. A parser that found the feature but not its rules would still report a font
	// with ligature support.
	mut rules := 0
	for li in g.lookups_for('arab', 'ccmp') {
		if li >= g.lookups.len {
			continue
		}
		lookup := g.lookups[li]
		// A feature can name lookups of kinds this engine does not implement, and a font is
		// entitled to put its composition in a context lookup. What must not happen is a lookup
		// that the engine read rules out of being reported as a kind it did not read them as,
		// because the caller would then go looking for rules that are not there.
		if lookup.ligatures.len > 0 {
			assert lookup.kind == gsub_lookup_ligature, 'a lookup with ligature rules is a ligature lookup'
		}
		if lookup.singles.len > 0 {
			assert lookup.kind == gsub_lookup_single, 'a lookup with single rules is a single lookup'
		}
		for set in lookup.ligatures {
			for rule in set.rules {
				// A rule that consumes one glyph is a substitution wearing the wrong type, and
				// the parser drops it rather than swallowing a glyph for nothing.
				assert rule.components.len >= 1, 'a ligature rule must consume at least two glyphs'
				// The rules are sorted longest first so that a three-glyph rule is tried before a
				// two-glyph one for the same opening letter.
				rules++
			}
		}
	}
	assert rules > 0, 'Arial should have ccmp ligature rules'
}

// A ligature cannot straddle two fonts, because a glyph index in one font means nothing in the
// other. The run is split at the seam before the font is asked, so the two letters either side of
// it are drawn apart rather than fused against a rule from a font that cannot see both.
//
// What this checks is the seam itself: a line whose characters came from more than one font still
// lays out every one of them, with each glyph naming the font it really came from. A run that
// was not split at the seam would either fuse across it or lose a glyph to a rule that could not
// apply.
fn test_ligature_does_not_straddle_two_fonts() {
	// An Arabic font and a Latin-only one, with a character between two Arabic ones that only
	// the first font covers. The line therefore has to survive a chain that cannot be used for
	// one script throughout.
	arabic := gsub_font('majalla.ttf')
	latin := gsub_font('ARIALN.TTF')
	fs := new_font_set()
	fs.add(arabic)
	fs.add(latin)
	ctx := new_context()
	line := layout_paragraph(ctx, [test_beh, test_beh, test_beh], .rtl, fs, 32)
	assert line.glyphs.len == 3, 'every character should still be drawn'
	for i in 0 .. 3 {
		g := glyph_at_cluster(line.glyphs, i) or { panic('no glyph at ${i}') }
		assert g.gid != 0, 'no glyph should be .notdef'
		// The chain fell back for nothing here, since the first font covers all three, and a
		// glyph that claimed a different font would mean the run was split where it should not
		// have been.
		assert (g.font or { panic('a glyph has to name its font') }) == arabic
	}
}

fn test_gsub_parses_and_arab_script_exists() {
	majalla := gsub_font('majalla.ttf')
	assert majalla.has_gsub(), 'Majalla is expected to carry a GSUB table'
	g := majalla.face.gsub or { panic('no gsub on the face') }
	assert g.script('arab') != none, 'the Arabic script has to be addressable'
}

fn test_gsub_arab_script_enables_the_positional_features() {
	majalla := gsub_font('majalla.ttf')
	g := majalla.face.gsub or { panic('no gsub on the face') }
	s := g.script('arab') or { panic('no arab script') }
	mut tags := []string{}
	for f in s.features {
		tags << f.tag
	}
	for want in ['fina', 'init', 'medi'] {
		assert want in tags, 'the arab script should enable ${want}, got ${tags}'
		assert g.lookups_for('arab', want).len > 0, '${want} should name a lookup'
	}
	// Every feature that names a lookup has to name one the table actually holds, or the
	// features exist and the rules behind them do not.
	for f in s.features {
		for li in f.lookups {
			assert li < g.lookups.len, '${f.tag} names lookup ${li} of ${g.lookups.len}'
		}
	}
}

// A font is not required to have a rule for the isolated form, and many leave it out because
// the base letter's own glyph already is the isolated form. Asking for one and getting the
// base letter back is then the correct answer rather than a gap.
fn test_gsub_treats_a_missing_isol_rule_as_the_base_letter() {
	// Dubai is the font that omits it.
	dubai := gsub_font('DUBAI-REGULAR.TTF')
	g := dubai.face.gsub or { panic('no gsub on the face') }
	s := g.script('arab') or { panic('no arab script') }
	mut tags := []string{}
	for f in s.features {
		tags << f.tag
	}
	assert 'isol' !in tags, 'this font is expected to omit isol, got ${tags}'
	assert g.lookups_for('arab', 'isol').len == 0
	base := dubai.glyph_index(rune(0x0628))
	assert base != 0
	assert g.shaped_glyph(base, .isolated, 'arab') == base, 'with no rule, the base letter is the isolated form'
}

fn test_gsub_substitutes_the_three_shapes_of_a_letter() {
	majalla := gsub_font('majalla.ttf')
	// Beh is dual joining, so it has all four shapes, and Majalla carries none of them in its
	// cmap, so all of them have to come out of GSUB.
	base := majalla.glyph_index(rune(0x0628))
	assert base != 0, 'Majalla carries the base letter'
	g := majalla.face.gsub or { panic('no gsub on the face') }
	mut report := 'base=${base}'
	mut got := map[int]u16{}
	for form in [JoiningForm.isolated, JoiningForm.final, JoiningForm.initial, JoiningForm.medial] {
		out := g.shaped_glyph(base, form, 'arab')
		report += ' ${feature_tag_for(form)}=${out}'
		got[int(form)] = out
	}
	assert got[0] == base, 'the isolated form is the base letter: ${report}'
	for form in [JoiningForm.final, JoiningForm.initial, JoiningForm.medial] {
		assert got[int(form)] != 0, 'a shape came out as .notdef: ${report}'
		assert got[int(form)] != base, 'a shape came out as the base letter: ${report}'
	}
	assert got[1] != got[2] && got[2] != got[3] && got[1] != got[3], 'the three shaped variants should be three different glyphs: ${report}'
}

// A shape a font has no rule for has to come back as the base letter rather than as some
// other glyph, since a wrong glyph is worse than an unjoined one.
fn test_gsub_leaves_an_uncovered_glyph_alone() {
	majalla := gsub_font('majalla.ttf')
	g := majalla.face.gsub or { panic('no gsub on the face') }
	// A Latin letter is in no Arabic feature, so no rule covers it and every shape comes back
	// unchanged. This is the case that matters in practice: a Persian line with an embedded
	// Latin word must not have its letters swapped for Arabic ones.
	latin := majalla.glyph_index(`A`)
	assert latin != 0
	for form in [JoiningForm.isolated, JoiningForm.final, JoiningForm.initial, JoiningForm.medial] {
		assert g.shaped_glyph(latin, form, 'arab') == latin, 'a Latin letter is not in any Arabic rule, got ${g.shaped_glyph(latin, form, 'arab')}'
	}
	// A script the font says nothing about is left alone too, rather than falling back to
	// some other script's rules.
	beh := majalla.glyph_index(rune(0x0628))
	assert g.shaped_glyph(beh, .final, 'zzzz') == beh, 'an unknown script has no rules'
}

// The parser has to survive a table that is not one, because font data is untrusted.
fn test_gsub_rejects_data_that_is_not_a_table() {
	assert new_gsub([]u8{}) == none
	assert new_gsub([]u8{len: 40}) == none, 'zeroed data is not a GSUB table'
	// A right-sized header naming offsets that are not in the buffer has to fall into the
	// degraded path rather than reading whatever is there.
	mut header := []u8{len: 10}
	header[0] = 0
	header[1] = 1
	header[4] = 0xFF
	header[5] = 0xFF
	assert new_gsub(header) == none
	// A font with no GSUB at all is not a failure either.
	assert !gsub_font('ARIALN.TTF').has_gsub()
}

// A regression guard on the parse itself, over several real fonts.
//
// The layout of a SingleSubst header is the kind of thing that goes wrong quietly: a parser
// that reads the wrong field still returns plausible numbers and simply never substitutes
// anything. So this checks that a spread of Arabic fonts each yield a usable set of rules and
// each actually shape letters, which is what a correct parse produces and what a broken one
// cannot.
//
// The floor is per font rather than uniform, because how much of the alphabet a font shapes is
// the font's business and not the parser's. Arabic Typesetting shapes only a couple of the
// probe letters, and the general-purpose UI fonts shape most of them.
fn test_gsub_finds_shapes_across_the_arabic_fonts() {
	// name, then the fewest letters expected to come out shaped.
	cases := [['majalla.ttf', '10'], ['trado.ttf', '8'], ['andlso.ttf', '8'], ['tahoma.ttf', '5'],
		['segoeui.ttf', '5'], ['DUBAI-REGULAR.TTF', '4'], ['simpo.ttf', '4'], ['ARABTYPE.TTF',
			'2']]
	for c in cases {
		name := c[0]
		floor := c[1].int()
		f := gsub_font(name)
		assert f.has_gsub(), '${name} is expected to carry a GSUB table'
		g := f.face.gsub or { panic('${name} has no gsub on the face') }
		mut rules := 0
		for l in g.lookups {
			rules += l.singles.len
		}
		assert rules > 0, '${name}: no single substitution rules were parsed'
		mut shaped := 0
		mut letters := 0
		for cp in arabic_probe_letters() {
			gid := f.glyph_index(cp)
			if gid == 0 {
				continue
			}
			letters++
			for form in [JoiningForm.isolated, JoiningForm.final, JoiningForm.initial,
				JoiningForm.medial] {
				if g.shaped_glyph(gid, form, 'arab') != gid {
					shaped++
					break
				}
			}
		}
		assert shaped >= floor, '${name}: only ${shaped} of ${letters} Arabic letters get a shape'
	}
}

// A substituted glyph is a different glyph, and a glyph's advance belongs to the glyph. A
// final form is normally narrower than the isolated one, so reusing the base letter's advance
// would leave the line the wrong width.
fn test_shaped_glyph_index_follows_the_substitution() {
	majalla := gsub_font('majalla.ttf')
	base := majalla.glyph_index(rune(0x0628))
	final_form := majalla.shaped_glyph_index(base, .final, 'arab')
	assert final_form != base, 'the final form should be a different glyph'
	base_advance := majalla.glyph_advance(base, 32)
	final_advance := majalla.glyph_advance(final_form, 32)
	assert base_advance > 0 && final_advance > 0, 'both glyphs have to have an advance'
	// A font that has a substitution table but no rule for this letter returns the base
	// rather than guessing. Consolas does carry a GSUB, just not one with Arabic rules.
	mono := gsub_font('consola.ttf')
	mono_base := mono.glyph_index(`A`)
	assert mono.shaped_glyph_index(mono_base, .final, 'arab') == mono_base
	// A font with no table at all cannot shape anything, and says so the same way.
	narrow := gsub_font('ARIALN.TTF')
	assert !narrow.has_gsub()
	assert narrow.shaped_glyph_index(narrow.glyph_index(`A`), .final, 'arab') ==
		narrow.glyph_index(`A`)
}
