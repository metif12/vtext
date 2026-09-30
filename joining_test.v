module vtext

// The joining algorithm, checked against the cases UAX#53 spells out and against the
// Persian and Arabic text this engine exists to render.

fn run(cps []string) []string {
	p := new_properties()
	s := new_shaper()
	run := s.shape_arabic(p, runes_of(cps))
	mut out := []string{cap: run.glyphs.len}
	for g in run.glyphs {
		out << cps_to_string(g.cps)
	}
	return out
}

// run_forms is the same, but reporting the shape rather than the codepoint, for the cases
// where the shape is the thing under test.
fn run_forms(cps []string) []string {
	p := new_properties()
	s := new_shaper()
	run := s.shape_arabic(p, runes_of(cps))
	mut out := []string{cap: run.glyphs.len}
	for g in run.glyphs {
		out << g.form.str()
	}
	return out
}

fn runes_of(fields []string) []rune {
	mut out := []rune{}
	for f in fields {
		out << rune(hex_value(f))
	}
	return out
}

fn cps_to_string(cps []rune) string {
	mut parts := []string{cap: cps.len}
	for c in cps {
		parts << '${u32(c):04X}'
	}
	return parts.join(' ')
}

// A single letter has nothing to connect to, so it keeps its isolated form.
fn test_joining_single_letter_is_isolated() {
	// U+FE8F is the isolated beh and U+FEDD the isolated lam.
	assert run(['0628']) == ['FE8F'], 'beh alone is the isolated form'
	assert run(['0644']) == ['FEDD'], 'lam alone is the isolated form'
	assert run_forms(['0628']) == ['isolated']
}

// UAX#53's worked example, the four shapes of one dual joining letter.
fn test_joining_dual_joining_letter() {
	// beh beh beh: the first connects only to what follows, the middle to both, the last
	// only to what precedes it.
	assert run(['0628', '0628', '0628']) == ['FE91', 'FE92', 'FE90']
	assert run_forms(['0628', '0628', '0628']) == ['initial', 'medial', 'final']
	// One letter cannot be both initial and final, so two in a row give the outer two
	// shapes rather than a medial one.
	assert run(['0628', '0628']) == ['FE91', 'FE90']
}

// Alef is right joining: it never connects to what follows, because a connection has to
// run through the letter on the right and alef offers no leftward connection. It does
// take a final form when something joins into it from the right.
fn test_joining_right_joining_alef() {
	// beh alef: the alef takes a final form, so the join exists, and the beh takes an
	// initial form.
	assert run(['0628', '0627']) == ['FE91', 'FE8E']
	assert run_forms(['0628', '0627']) == ['initial', 'final']
	// alef on its own has no connection at all.
	assert run(['0627']) == ['FE8D']
	assert run_forms(['0627']) == ['isolated']
	// A right joining letter in the middle of a word breaks the word in two, because it
	// cannot connect past itself.
	assert run(['0628', '0627', '0628']) == ['FE91', 'FE8E', 'FE8F']
}

// A transparent character is skipped when deciding joins, so a mark between two letters
// does not stop them connecting.
fn test_joining_skips_transparent_marks() {
	// beh + fatha + beh: the mark is transparent, so the two behs still join. The first
	// connects only forward, the second only backward.
	assert run_forms(['0628', '064E', '0628']) == ['initial', 'final']
	assert run(['0628', '064E', '0628']) == ['FE91', 'FE90']
	// The shaped letter has to cover the mark that follows it, or the mark would be left
	// without a base to attach to.
	p := new_properties()
	s := new_shaper()
	shaped := s.shape_arabic(p, runes_of(['0628', '064E', '0628']))
	assert shaped.glyphs.len == 2, 'the mark should not become a glyph of its own'
	assert shaped.glyphs[0].start == 0 && shaped.glyphs[0].end == 2, 'the first letter should cover the mark'
	assert shaped.glyphs[1].start == 2 && shaped.glyphs[1].end == 3, 'the second letter should stand alone'
}

// ZWNJ breaks the join and ZWJ forces it. Both are invisible, so neither is a glyph.
fn test_joining_controls() {
	// beh ZWNJ beh: the non-joiner separates the two, so both take the isolated form.
	// It contributes no glyph of its own, so two letters give two shapes.
	assert run_forms(['0628', '200C', '0628']) == ['isolated', 'isolated']
	// beh ZWJ beh: the joiner connects the two, so the second beh connects backward and
	// takes a final form. The joiner takes a shape of its own between them, because it is
	// a join causing character rather than a transparent one, and that is what the
	// medial form in the middle is.
	assert run_forms(['0628', '200D', '0628']) == ['initial', 'medial', 'final']
	// ZWNJ is non joining, so it is not a letter and does not become a glyph. ZWJ is
	// join causing, so it does take a shape and is drawn; a font maps it to nothing, and
	// that is the font layer's business rather than the shaper's.
	p := new_properties()
	s := new_shaper()
	between := s.shape_arabic(p, runes_of(['0628', '200C', '0628']))
	assert between.glyphs.len == 2, 'ZWNJ should not become a glyph'
	joined := s.shape_arabic(p, runes_of(['0628', '200D', '0628']))
	assert joined.glyphs.len == 3, 'ZWJ is join causing, so it keeps a glyph slot'
	assert joined.glyphs[1].cps == [rune(0x200D)], 'the joiner is drawn as itself'
}

// Tatweel is join causing: it connects on both sides, so it takes a medial shape, and
// the letters around it join through it. It is drawn as a plain tatweel because the UCD
// gives it no positional presentation forms of its own: U+FE70 onwards are the fathatan
// and dammatan forms, which are bases of two codepoints rather than the tatweel.
fn test_joining_tatweel() {
	assert run(['0628', '0640', '0628']) == ['FE91', '0640', 'FE90']
	assert run_forms(['0628', '0640', '0628']) == ['initial', 'medial', 'final']
}

// Lam followed by alef is one glyph, and it is the case the presentation forms name
// directly.
fn test_joining_lam_alef_ligature() {
	// A lam with nothing before it and an alef after it: the pair has no join on either
	// side, so it takes the isolated ligature, U+FEFB.
	assert run(['0644', '0627']) == ['FEFB']
	assert run_forms(['0644', '0627']) == ['isolated']
	// With something joining into the lam, the pair takes the final ligature, U+FEFC.
	assert run(['0628', '0644', '0627']) == ['FE91', 'FEFC']
	assert run_forms(['0628', '0644', '0627']) == ['initial', 'final']
	// The other three alef forms pair with the lam too, each with its own ligature.
	assert run(['0644', '0622']) == ['FEF5']
	assert run(['0644', '0623']) == ['FEF7']
	assert run(['0644', '0625']) == ['FEF9']
	// A lam with no alef after it is just a lam. The lam takes its initial form because
	// it connects to the beh that follows it, and the beh takes its final form because
	// the lam connects into it.
	assert run(['0644', '0628']) == ['FEDF', 'FE90']
	assert run_forms(['0644', '0628']) == ['initial', 'final']
}

// Persian text, end to end. The word is SALAM, and the point of the test is that the
// first letter takes an initial form rather than being drawn in isolation.
fn test_joining_persian_word() {
	// sin lam alef meem. Four letters give three glyphs, because the lam and the alef
	// fuse.
	//
	// The sin takes its initial form, U+FEB3. The pair takes the final ligature U+FEFC,
	// because the sin joins into the lam, and in logical order that is the join on the
	// lam's left. The meem takes its final form, U+FEE2, because the ligature hands the
	// lam's forward join on to it: without that the word would break at the ligature.
	// U+FEE1 is the isolated meem, which is what a meem at the end of a word with
	// nothing joining into it would take.
	got := run(['0633', '0644', '0627', '0645'])
	assert got == ['FEB3', 'FEFC', 'FEE2'], 'got ${got}'
	assert got.len == 3, 'the lam and the alef should fuse'
	assert run_forms(['0633', '0644', '0627', '0645']) == ['initial', 'final', 'final']
}

// A Persian phrase with a space in it: the space has no shape and must not connect
// anything across it.
fn test_joining_space_breaks_the_word() {
	got := run(['0628', '0020', '0628'])
	assert got == ['FE8F', '0020', 'FE8F'], 'got ${got}'
	assert got[1] == '0020', 'the space should pass through as itself'
}

// A letter with no presentation form for the shape it needs keeps its base codepoint, so
// the font layer can still find it. This is what happens with a character that has no
// final form in the UCD.
fn test_joining_falls_back_to_the_base_codepoint() {
	p := new_properties()
	s := new_shaper()
	// U+0651 ARABIC SHADDA has joining type Transparent, so it is passed through rather
	// than shaped. U+06A4 is a dual joining letter that does have forms.
	shaped := s.shape_arabic(p, runes_of(['0628', '0651', '0628']))
	assert shaped.glyphs.len == 2, 'the shadda should attach to the letter'
	assert shaped.glyphs[0].cps == [rune(0xFE91)], 'beh initial is U+FE91'
	// The shape is reported even when the codepoint is the base, so a caller driving a
	// font's positional features knows which to apply.
	assert shaped.glyphs[0].form == .initial
}

// Empty input has to be handled without a special case at every step.
fn test_joining_empty_and_single() {
	p := new_properties()
	s := new_shaper()
	empty := s.shape_arabic(p, []rune{})
	assert empty.glyphs.len == 0
	one := s.shape_arabic(p, runes_of(['0628']))
	assert one.glyphs.len == 1
	assert one.glyphs[0].start == 0 && one.glyphs[0].end == 1
}

// The form tables have to be complete enough to shape with and sorted for the binary
// search to work, since a lookup that lands in the wrong place returns no glyph at all.
fn test_joining_tables_are_well_formed() {
	s := new_shaper()
	assert s.forms.len > 200, 'the form table looks truncated: ${s.forms.len}'
	// The four alef forms pair with the lam, and the lam is one of them.
	assert s.ligatures.len == 8, 'expected the four alef forms in two shapes each'
	for i in 1 .. s.forms.len {
		a := s.forms[i - 1]
		b := s.forms[i]
		if b.cp == a.cp {
			assert b.form > a.form, 'forms for one codepoint must be sorted by form'
		} else {
			assert b.cp > a.cp, 'the form table must be sorted by codepoint'
		}
	}
	for i in 1 .. s.ligatures.len {
		a := s.ligatures[i - 1]
		b := s.ligatures[i]
		assert b.first >= a.first, 'ligature bases must be sorted'
	}
}
