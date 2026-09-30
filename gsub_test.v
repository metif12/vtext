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
