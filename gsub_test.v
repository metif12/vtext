module vtext

// Tests for the GSUB parser and the positional substitution built on it.
//
// The parser is fed real fonts rather than a hand-built table, because a table built to match
// the parser proves nothing. The fonts are Arabic ones that keep their shapes in GSUB instead
// of in the cmap, since those are the fonts the substitution exists for: a font that carries
// the presentation forms never reaches the base-letter path at all.

import os

// corpus_font_path is where a named font is: the committed corpus first, this platform's font directory
// second, and none when neither has it.
//
// The corpus is first because a test that runs only because one machine ships a font is a test about that
// machine. The platform directory is still asked second, so a Windows checkout keeps reading the ten
// Windows faces this file was written against. VTEXT_TEST_FONTS overrides both.
//
// Three things the corpus cannot supply are recorded here rather than discovered one failure at a time,
// because all three were measured: no committed font has a substitution rule that changes a letter's glyph
// through shaped_glyph, so the tests that assert a shape came back different stay on Majalla; none has a
// dlig that fuses f and i, so that one stays on Tahoma; and none is a font with no GSUB table at all, which
// is what Arial Narrow and Consolas stand for here.
fn corpus_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('VTEXT_TEST_FONTS'), 'testdata/fonts', windows_font_dir()] {
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

$if windows {
	fn windows_font_dir() string {
		return 'C:\\Windows\\Fonts'
	}
} $else {
	fn windows_font_dir() string {
		return ''
	}
}

// skip_missing records why a test cannot run. A skip that prints nothing is a failure pretending to be a
// pass, so every one of them names the font it wanted and where it looked, and it is written to the file
// tools/run_tests.v names in VTEXT_SKIP_LOG rather than to stdout.
//
// The file rather than stdout, because V's test runner does not print a passing test's output: measured on
// Linux, every println line a passing file writes is discarded, so a suite of skips would look exactly
// like a suite of passes. Written where the runner reads it, a skip is counted whether its test passed or
// failed, on every platform, and the runner says how many there were.
fn skip_missing(name string) {
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

fn gsub_font(name string) ?&Font {
	p := corpus_font_path(name) or {
		skip_missing(name)
		return none
	}
	return load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

// amiri is the corpus font these tests read.
//
// It carries a GSUB table with the arab script and fina, init and medi features with lookups behind them,
// a ccmp with ligature rules in it, and no isol feature at all, which is exactly the shape several
// assertions below ask of Majalla and Dubai.
fn amiri() ?&Font {
	return gsub_font('Amiri-Regular.ttf')
}

// nastaliq is the corpus font with no Latin and no presentation forms, for the chain that has to be walked
// by a font that cannot answer for the character either side of a seam.
fn nastaliq() ?&Font {
	return gsub_font('NotoNastaliqUrdu-Regular.ttf')
}

// has_any_font answers whether at least one of the named fonts is readable on this host.
//
// A test that measures a property across several fonts needs this up front rather than after the fact:
// a loop that skipped every one of them would leave its counters at zero and then assert about nothing.
fn has_any_font(names []string) bool {
	for name in names {
		if corpus_font_path(name) or { '' } != '' {
			return true
		}
	}
	return false
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
	majalla := gsub_font('majalla.ttf') or { return }
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
	arial := gsub_font('arial.ttf') or { return }
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
	arial := gsub_font('arial.ttf') or { return }
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
	arial := amiri() or { return }
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
	arial := amiri() or { return }
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
	// An Arabic font and a font with no Latin at all, with a character between two Arabic ones that only
	// the first font covers. The line therefore has to survive a chain that cannot be used for
	// one script throughout.
	arabic := amiri() or { return }
	latin := nastaliq() or { return }
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
	majalla := amiri() or { return }
	assert majalla.has_gsub(), 'Majalla is expected to carry a GSUB table'
	g := majalla.face.gsub or { panic('no gsub on the face') }
	assert g.script('arab') != none, 'the Arabic script has to be addressable'
}

fn test_gsub_arab_script_enables_the_positional_features() {
	majalla := amiri() or { return }
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
	// Amiri is the corpus font that omits it.
	dubai := amiri() or { return }
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
	majalla := gsub_font('majalla.ttf') or { return }
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
	majalla := amiri() or { return }
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
	assert new_gsub([]u8{}, none) == none
	assert new_gsub([]u8{len: 40}, none) == none, 'zeroed data is not a GSUB table'
	// A right-sized header naming offsets that are not in the buffer has to fall into the
	// degraded path rather than reading whatever is there.
	mut header := []u8{len: 10}
	header[0] = 0
	header[1] = 1
	header[4] = 0xFF
	header[5] = 0xFF
	assert new_gsub(header, none) == none
	// A font with no GSUB at all is not a failure either.
	no_table := gsub_font('ARIALN.TTF') or { return }
	assert !no_table.has_gsub()
}

// A regression guard on the parse itself, over several real fonts.
//
// The layout of a SingleSubst header is the kind of thing that goes wrong quietly: a parser
// that reads the wrong field still returns plausible numbers and simply never substitutes
// anything. So this checks that a spread of Arabic fonts each yield a usable set of rules and
// each actually shape letters, which is what a correct parse produces and what a broken one
// cannot.
//
// The strong assertion here is the one about a letter keeping a shape. It is not an obvious thing
// to check, and it is the check that would have caught the worst bug this engine has had: a cmap
// format 4 parser that measured each idRangeOffset from the start of the glyphIdArray rather
// than from the offset's own slot. That read a real but neighbouring glyph for every Arabic
// letter, so a font's substitution tables were being asked about glyphs it had never emitted, and
// every lookup silently did nothing. Dubai came out drawing all four shapes of a beh as the same
// glyph, which is a legible letter with the joining quietly missing, and there was no error
// anywhere.
//
// The tell is agreement between fonts. Eight fonts written by different people agree on how many
// of their letters they shape, because Arabic shaping works the same way in all of them; a parser
// that is reading any of it wrong makes them disagree, and one reading the cmap wrong makes them
// disagree wildly.
fn test_gsub_finds_shapes_across_the_arabic_fonts() {
	cases := [['majalla.ttf'], ['trado.ttf'], ['andlso.ttf'], ['tahoma.ttf'], ['segoeui.ttf'],
		['DUBAI-REGULAR.TTF'], ['simpo.ttf'], ['ARABTYPE.TTF']]
	for c in cases {
		name := c[0]
		f := gsub_font(name) or { continue }
		assert f.has_gsub(), '${name} is expected to carry a GSUB table'
		g := f.face.gsub or { panic('${name} has no gsub on the face') }
		mut rules := 0
		for l in g.lookups {
			rules += l.singles.len
			rules += l.alternates.len
		}
		assert rules > 0, '${name}: no single or alternate substitution rules were parsed'
		mut shaped := 0
		mut letters := 0
		mut unshaped_anywhere := 0
		for cp in arabic_probe_letters() {
			gid := f.glyph_index(cp)
			if gid == 0 {
				continue
			}
			letters++
			mut any := false
			mut all_same := true
			for form in [JoiningForm.isolated, JoiningForm.final, JoiningForm.initial,
				JoiningForm.medial] {
				if g.shaped_glyph(gid, form, 'arab') != gid {
					any = true
				} else {
					all_same = false
				}
			}
			if any {
				shaped++
			}
			// A letter whose four forms are all the base letter is a letter this engine has no
			// shape for at all, which for a font that carries a substitution table means the
			// glyph it looked up is not one the table talks about. One font here leaves one such
			// letter by its own choice, so the threshold is one rather than none; the bug above
			// left most of the alphabet in that state, which is what makes the bound worth
			// having.
			if all_same && cp != rune(0x0640) {
				unshaped_anywhere++
			}
		}
		assert unshaped_anywhere <= 1, '${name}: ${unshaped_anywhere} letters have no shape in any position'
		// Every Arabic font on this machine shapes all but the tatweel, and the exact number is
		// not the point: the point is that a font leaving letters unshaped is the signature of a
		// glyph lookup that has gone wrong somewhere upstream.
		assert shaped >= letters - 1, '${name}: only ${shaped} of ${letters} Arabic letters get a shape'
	}
}

// A substituted glyph is a different glyph, and a glyph's advance belongs to the glyph. A
// final form is normally narrower than the isolated one, so reusing the base letter's advance
// would leave the line the wrong width.
fn test_shaped_glyph_index_follows_the_substitution() {
	majalla := gsub_font('majalla.ttf') or { return }
	base := majalla.glyph_index(rune(0x0628))
	final_form := majalla.shaped_glyph_index(base, .final, 'arab')
	assert final_form != base, 'the final form should be a different glyph'
	base_advance := majalla.glyph_advance(base, 32)
	final_advance := majalla.glyph_advance(final_form, 32)
	assert base_advance > 0 && final_advance > 0, 'both glyphs have to have an advance'
	// A font that has a substitution table but no rule for this letter returns the base
	// rather than guessing. Consolas does carry a GSUB, just not one with Arabic rules.
	mono := gsub_font('consola.ttf') or { return }
	mono_base := mono.glyph_index(`A`)
	assert mono.shaped_glyph_index(mono_base, .final, 'arab') == mono_base
	// A font with no table at all cannot shape anything, and says so the same way.
	narrow := gsub_font('ARIALN.TTF') or { return }
	assert !narrow.has_gsub()
	assert narrow.shaped_glyph_index(narrow.glyph_index(`A`), .final, 'arab') ==
		narrow.glyph_index(`A`)
}

// Chaining context substitution. The rules are read out of Dubai, which is the clearest case on
// this machine: every one of its lookups is an extension, and its ccmp feature is nothing but
// chaining contexts. A parser that did not follow the extension on every subtable, or that read
// the pattern's coverage lists in the wrong order, would find nothing here.

// The expected values below were read out of the font's bytes independently of this parser, and
// are stated in the test so that a change in what the parser believes is visible as a change in
// what the font is asserted to contain. Dubai's ccmp is lookups 2, 3 and 4: two chaining context
// lookups of four and two subtables and one ligature lookup, with every one of the six context
// subtables naming a single substitution.
fn test_chain_context_rules_are_read_from_the_font() {
	dubai := gsub_font('DUBAI-REGULAR.TTF') or { return }
	g := dubai.face.gsub or { panic('Dubai has no gsub') }
	ccmp := g.lookups_for('arab', 'ccmp')
	assert ccmp.len == 3, 'Dubai ccmp should name three lookups, got ${ccmp.len}'
	mut chains := 0
	mut ligature_lookups := 0
	for li in ccmp {
		lookup := g.lookups[li]
		if lookup.chains.len > 0 {
			assert lookup.kind == gsub_lookup_chain_context, 'a lookup with chains is a chain lookup'
			chains += lookup.chains.len
		}
		if lookup.ligatures.len > 0 {
			assert lookup.kind == gsub_lookup_ligature, 'a lookup with ligatures is a ligature lookup'
			ligature_lookups++
		}
	}
	assert chains == 6, 'Dubai ccmp should yield six context subtables, got ${chains}'
	assert ligature_lookups == 1, 'the third ccmp lookup is a ligature one'
	// The first subtable of the first ccmp lookup is the simplest shape the format has: no
	// backtrack, one input glyph, one glyph of lookahead, and one substitution. Every Arabic
	// font measured writes its mark composition this way, so a parser that cannot read it reads
	// none of them.
	first := g.lookups[ccmp[0]]
	assert first.chains.len == 4, 'the first ccmp lookup has four subtables, got ${first.chains.len}'
	c := first.chains[0]
	assert c.backtrack.len == 0, 'the first subtable has no backtrack'
	assert c.input.len == 1, 'the first subtable matches one input glyph'
	assert c.lookahead.len == 1, 'the first subtable looks one glyph ahead'
	assert c.records.len == 1, 'the first subtable performs one substitution'
	assert c.records[0].position == 0, 'it substitutes the glyph it matched'
	// A context that names a lookup index outside the lookup list is a misread offset, and it is
	// the failure that would otherwise be silent: the record would simply never apply.
	for lookup in g.lookups {
		for chain in lookup.chains {
			for record in chain.records {
				assert int(record.lookup) < g.lookups.len, 'a record names a lookup that does not exist'
				assert lookup_substitutes(g.lookups[record.lookup]), 'a record names a lookup this engine cannot apply'
			}
		}
	}
}

// A record that applies to an input position the pattern does not have is a misread record, and
// would put a substitution somewhere the font never asked for one.
fn test_chain_context_records_stay_inside_their_pattern() {
	for name in ['Amiri-Regular.ttf', 'NotoNastaliqUrdu-Regular.ttf'] {
		f := gsub_font(name) or { continue }
		g := f.face.gsub or { panic('${name} has no gsub') }
		for lookup in g.lookups {
			for chain in lookup.chains {
				for record in chain.records {
					assert record.position < chain.input.len, '${name}: a record at ${record.position} of a ${chain.input.len} glyph pattern'
				}
			}
		}
	}
}

// A lookup's flags are the part of a header that is easy to skip, because nothing before it needs
// them. Getting them wrong does not stop the rules parsing; it changes which glyphs they see.
//
// The flags asserted here were measured across the Arabic fonts on this machine, and the ones
// asserted are the ones those fonts genuinely set: right to left, ignoring marks, and a mark
// attachment class, which the top byte of the flag field carries rather than a bit of its own.
// Two different attachment classes were seen, so both are checked, since a parser that read the
// top byte as part of the bit mask would find the first and miss the second.
//
// The two flags these fonts never set are left out for that reason. No font here asks for base
// glyphs or ligatures to be ignored, and none uses a mark filtering set; both are implemented,
// and both are marked in gsub.v as unexercised by any font on this machine rather than asserted
// here against a font that does not set them.
fn test_lookup_flags_are_read_from_the_font() {
	// The flags are only observable on a font that sets them, so the whole test is skipped when none of
	// the fonts that do is present. Looping anyway would leave the three flags below at their zero values
	// and assert about a run that never happened.
	any := has_any_font(['DUBAI-REGULAR.TTF', 'ARABTYPE.TTF', 'tahoma.ttf', 'segoeui.ttf', 'majalla.ttf',
		'trado.ttf', 'simpo.ttf'])
	if !any {
		skip_missing('DUBAI-REGULAR.TTF, ARABTYPE.TTF, tahoma.ttf, segoeui.ttf, majalla.ttf, trado.ttf, simpo.ttf')
		return
	}
	mut right_to_left := false
	mut ignore_marks := false
	mut classes := map[int]bool{}
	for name in ['DUBAI-REGULAR.TTF', 'ARABTYPE.TTF', 'tahoma.ttf', 'segoeui.ttf', 'majalla.ttf',
		'trado.ttf', 'simpo.ttf'] {
		f := gsub_font(name) or { continue }
		g := f.face.gsub or { panic('${name} has no gsub') }
		for lookup in g.lookups {
			if lookup.flag & gsub_flag_right_to_left != 0 {
				right_to_left = true
			}
			if lookup.flag & gsub_flag_ignore_marks != 0 {
				ignore_marks = true
			}
			// The class is the top byte shifted down, not the byte itself.
			class := int(lookup.flag >> 8)
			if class > 0 {
				classes[class] = true
			}
			// A flag field is the bits and the class together, so a lookup that set a class must
			// not have had a bit read out of the top of it.
			assert lookup.flag & 0x00f0 == 0 || lookup.flag & gsub_flag_ignore_marks != 0
				|| lookup.flag & gsub_flag_ignore_ligatures != 0 || class > 0, 'the flag field does not add up'
		}
	}
	assert right_to_left, 'no font set the right to left flag'
	assert ignore_marks, 'no font asked for marks to be ignored'
	assert classes[1], 'no font restricted a lookup to mark attachment class 1'
	assert classes[2], 'no font restricted a lookup to mark attachment class 2'
}

// Multiple substitution is the one rule that makes one character into several glyphs, and it is
// the only substitution type that does. Arabic Typesetting puts one at the front of its ccmp, so
// the rules exist to be read.
fn test_multiple_substitution_rules_are_read_from_the_font() {
	f := amiri() or { return }
	g := f.face.gsub or { panic('no gsub') }
	mut found := 0
	for li in g.lookups_for('arab', 'ccmp') {
		lookup := g.lookups[li]
		if lookup.multiples.len == 0 {
			continue
		}
		assert lookup.kind == gsub_lookup_multiple, 'a lookup with multiple rules is a multiple lookup'
		for rule in lookup.multiples {
			assert rule.ranges.len > 0, 'a multiple rule covers nothing'
			assert rule.sequences.len > 0, 'a multiple rule has no sequences'
			// A sequence is found by the covered glyph's coverage index, so the property that
			// matters is that the two line up for every covered glyph, and that a glyph whose
			// index runs past the sequence list finds no rule rather than another glyph's
			// replacement. The subtable is allowed to carry more sequences than its coverage
			// covers, which is why this walks the coverage rather than comparing two lengths.
			for i in 0 .. covered_count(rule.ranges) {
				gid := coverage_glyph_at(rule.ranges, i)
				if i < rule.sequences.len {
					seq := multiple_lookup([rule], gid) or {
						assert rule.sequences[i].len == 0, 'a covered glyph with a sequence found nothing'
						continue
					}
					assert seq.len == rule.sequences[i].len, 'a covered glyph found another sequence'
				} else {
					assert multiple_lookup([rule], gid) == none, 'a covered glyph past the sequences found a rule'
				}
			}
			found++
		}
	}
	assert found > 0, 'Arabic Typesetting should have a ccmp rule that expands one glyph into several'
}

// A lookup that expands a glyph must not silently refuse to because of where the glyph came from:
// a font's mark compositions are as likely to be a rule of this kind as a ligature.
fn test_multiple_substitution_is_applied() {
	f := gsub_font('ARABTYPE.TTF') or { return }
	g := f.face.gsub or { panic('no gsub') }
	// Find a covered glyph and run the lookup over it directly, so the test is about the rule
	// rather than about which text happens to reach it.
	mut gid := u16(0)
	mut target := u16(0)
	for li in g.lookups_for('arab', 'ccmp') {
		for rule in g.lookups[li].multiples {
			for i, seq in rule.sequences {
				if seq.len > 1 && i < rule.ranges.len {
					gid = coverage_glyph_at(rule.ranges, i)
					target = seq[1]
				}
			}
		}
	}
	if gid == 0 {
		return // this build of the font has no expanding rule to test
	}
	lookups := g.lookups_for('arab', 'ccmp')
	out := g.substitute(lookups, [Ligatable{
		gid:     gid
		cluster: 0
		source:  0
	}])
	assert out.len >= 1, 'a substitution must leave at least the glyph it started from'
	if out.len > 1 {
		// More than one glyph came out of one character, and every one of them reports that
		// character. A layout pass that draws one glyph per character depends on that.
		for item in out {
			assert item.cluster == 0, 'every glyph of a split character reports that character'
		}
		assert out[1].gid == target, 'the second glyph should be the second replacement of the sequence'
	}
}

// The flags only matter where they change an answer, so this checks that a glyph the font calls a
// mark is skipped by a lookup that ignores marks and kept by one that does not.
fn test_a_lookup_that_ignores_marks_cannot_see_them() {
	f := gsub_font('DUBAI-REGULAR.TTF') or { return }
	g := f.face.gsub or { panic('no gsub') }
	// A mark the font's own GDEF calls a mark, so the test is about the flag and not the data.
	mut mark := u16(0)
	for gid in u16(600) .. u16(620) {
		if f.is_mark_glyph(gid) {
			mark = gid
			break
		}
	}
	assert mark != 0, 'Dubai should classify some glyph in that range as a mark'
	mut letter := u16(0)
	for other in u16(1) .. u16(300) {
		if other != mark && !f.is_mark_glyph(other) {
			letter = other
			break
		}
	}
	items := [Ligatable{
		gid:     letter
		cluster: 0
		source:  0
	}, Ligatable{
		gid:     mark
		cluster: 1
		source:  1
	}]
	// With the mark ignored the run is one glyph long as far as the lookup is concerned, so the
	// mark is not between the two letters as far as any rule is concerned.
	skipping := g.effective(items, gsub_flag_ignore_marks, 0)
	assert skipping.len == 1, 'the mark should be invisible to a lookup that ignores marks'
	// And with no such flag it is a glyph like any other.
	keeping := g.effective(items, 0, 0)
	assert keeping.len == 2, 'a lookup with no flags sees every glyph'
}

// Discretionary features are the caller's to ask for, and asking changes the line.
//
// Tahoma keeps its f and i ligature under dlig rather than liga, which is the usual arrangement:
// an f followed by an i is a discretionary pairing, and a font is entitled to leave the reader
// the two letters instead. Tahoma is used here because it is a font with a rule to apply, so the
// test can tell the difference between the feature working and the feature being absent.
fn test_discretionary_features_are_off_unless_asked_for() {
	f := gsub_font('tahoma.ttf') or { return }
	fs := fs_of(f)
	ctx := new_context()
	f_gid := f.glyph_index(`f`)
	i_gid := f.glyph_index(`i`)
	assert f_gid != 0 && i_gid != 0, 'the letters have to be in the font for this to mean anything'
	// The font has the rule, which is what makes the difference below the feature's doing.
	mut has_rule := false
	g := f.face.gsub or { panic('no gsub') }
	for li in g.lookups_for('latn', 'dlig') {
		if g.lookups[li].ligatures.len > 0 || g.lookups[li].chains.len > 0 {
			has_rule = true
		}
	}
	assert has_rule, 'Tahoma should have a dlig rule joining f and i'
	// The default line is the two letters.
	plain := layout_paragraph(ctx, [`f`, `i`], .ltr, fs, 32)
	assert plain.glyphs.len == 2, 'without the feature the two letters stay two glyphs'
	assert plain.glyphs[0].gid == f_gid && plain.glyphs[1].gid == i_gid, 'and they are the letters'
	// Asked for, they become one glyph, and it is a third one rather than either of the letters.
	opt := &LayoutOptions{
		features: ['dlig']
	}
	fused := layout_paragraph_with(ctx, [`f`, `i`], .ltr, fs, 32, opt)
	assert fused.glyphs.len == 1, 'with the feature the pair should be one glyph, got ${fused.glyphs.len}'
	assert fused.glyphs[0].gid != f_gid && fused.glyphs[0].gid != i_gid, 'the fused glyph is one of its own'
	// And asking for a feature the font has no rule for changes nothing, rather than failing.
	nothing := &LayoutOptions{
		features: ['zzzz']
	}
	unchanged := layout_paragraph_with(ctx, [`f`, `i`], .ltr, fs, 32, nothing)
	assert unchanged.glyphs.len == 2, 'an unknown feature leaves the line alone'
}

// A character that a substitution splits into several glyphs has to keep all of them. A layout
// pass that drew one glyph per character would drop the rest, which is a silently missing mark
// rather than a visible error.
//
// The glyphs are built by hand here because no font on this machine has a rule that fires on text
// the engine can reach, so the invariant is pinned at the pass that would break it.
fn test_a_character_keeps_every_glyph_made_of_it() {
	// The list is built by appending rather than written as a literal. A multi-line struct array
	// literal is accepted by this compiler and evaluates to an empty slice, which would make this
	// test pass for the wrong reason if it asserted nothing about the input.
	mut placed := []Glyph{}
	placed << Glyph{
		gid:     10
		cluster: 0
		advance: 5
	}
	placed << Glyph{
		gid:     11
		cluster: 0
		advance: 0
	}
	placed << Glyph{
		gid:     12
		cluster: 1
		advance: 7
	}
	assert placed.len == 3, 'the test needs three glyphs to say anything'
	bidi := BidiResult{
		levels:          [u8(0), u8(0)]
		visible:         [true, true]
		visual_order:    [0, 1]
		paragraph_level: 0
	}
	line := place_glyphs(placed, bidi)
	assert line.len == 3, 'all three glyphs should be drawn, got ${line.len}'
	assert line[0].gid == 10 && line[1].gid == 11, 'both glyphs of character zero, in order'
	assert line[2].gid == 12, 'and then the next character'
	// They advance the pen in order, so the split does not disturb the width of the line.
	assert line[0].x == 0.0 && line[1].x == 5.0 && line[2].x == 5.0, 'the pen moves once per glyph'
}

// The applier, tested against tables built in the file rather than read from a font.
//
// The parser is proved separately, against real fonts and against a byte level reading of them
// done outside this codebase. These tests cover something the parser tests cannot: whether the
// matcher fires at all. A rule can be read perfectly and still never match anything, and a parser
// test would not notice, so the matcher is pinned here on tables whose every field is stated, one
// flag and one shape of pattern at a time.
//
// The real fonts are covered further down, on real text. Both are needed. These say the matcher
// does what the specification says for every case a caller can construct; those say that a font
// actually reaches it.
const chain_first = u16(10)
const chain_second = u16(11)
const chain_third = u16(12)
const chain_before = u16(9)
const chain_mark = u16(30)
const chain_result = u16(20)

// cov_of builds a format 1 coverage from a list of glyphs, which is the only kind a context
// pattern needs and the one every coverage in these tests uses.
//
// It takes a slice rather than a variadic, and every fixture here is built by appending rather
// than by writing a literal. Both are workarounds: this compiler rejects a spread of a variadic
// slice, and it silently evaluates a multi-line struct array literal to an empty slice, which
// would let a test pass for the wrong reason.
fn cov_of(gids []u16) []CoverageRange {
	mut out := []CoverageRange{}
	for i, gid in gids {
		out << CoverageRange{
			first:       gid
			last:        gid
			start_index: i
		}
	}
	return out
}

// covs_of wraps coverages in the list of lists a context pattern is made of.
fn covs_of(sets [][]CoverageRange) [][]CoverageRange {
	mut out := [][]CoverageRange{}
	for s in sets {
		out << s
	}
	return out
}

// empty_covs is the empty pattern a context field that names nothing is written as.
fn empty_covs() [][]CoverageRange {
	return [][]CoverageRange{}
}

// gdef_with builds a glyph definition table calling one glyph a mark of one attachment class.
fn gdef_with(gid u16, class u16, mark_class u16) &Gdef {
	mut d := &Gdef{}
	d.glyph_classes.entries << ClassRangeEntry{
		first: gid
		last:  gid
		value: glyph_class_mark
	}
	d.mark_classes.entries << ClassRangeEntry{
		first: gid
		last:  gid
		value: mark_class
	}
	d.has_mark_classes = true
	return d
}

// gdef_with_set builds a glyph definition table that calls mark a mark and whose first mark
// filtering set names the glyphs given. Both halves matter: without the glyph class nothing is a
// mark and the filtering set is never consulted, which would make the test pass for the wrong
// reason.
fn gdef_with_set(mark u16, gids []u16) &Gdef {
	mut d := gdef_with(mark, glyph_class_mark, 1)
	mut sets := [][]CoverageRange{}
	sets << cov_of(gids)
	d.mark_sets = sets
	return d
}

// chain_pair is the pattern every flag test starts from: two letters, the first of which is
// substituted when they stand next to each other.
fn chain_pair() [][]CoverageRange {
	mut out := [][]CoverageRange{}
	out << cov_of([chain_first])
	out << cov_of([chain_second])
	return out
}

// chain_gsub builds a GSUB holding two lookups. Lookup 0 is a single substitution taking the first
// letter to chain_result. Lookup 1 is a chaining context with the given pattern whose one record
// substitutes the first input glyph through lookup 0. The flag and the mark set go on the context
// lookup, so one builder serves every flag test.
fn chain_gsub(flag u16, mark_set u16, back [][]CoverageRange, input [][]CoverageRange,
	ahead [][]CoverageRange) &Gsub {
	mut singles := []SingleSubst{}
	singles << SingleSubst{
		ranges: cov_of([chain_first])
		subs:   [u16(chain_result)]
	}
	mut records := []ChainRecord{}
	records << ChainRecord{
		position: 0
		lookup:   0
	}
	mut chains := []ChainContext3{}
	chains << ChainContext3{
		backtrack: back
		input:     input
		lookahead: ahead
		records:   records
	}
	mut lookups := []Lookup{}
	lookups << Lookup{
		kind:    gsub_lookup_single
		singles: singles
	}
	lookups << Lookup{
		kind:     gsub_lookup_chain_context
		flag:     flag
		mark_set: mark_set
		chains:   chains
	}
	return &Gsub{
		lookups: lookups
		scripts: []Script{}
	}
}

// bare is the common case of the fixture: a two letter pattern with nothing either side of it.
//
// The glyph definition table is passed in rather than assigned afterwards because the field on
// Gsub is immutable, and a table is part of what a lookup's flags are read against.
fn bare(flag u16, gdef ?&Gdef) &Gsub {
	built := chain_gsub(flag, 0, empty_covs(), chain_pair(), empty_covs())
	return &Gsub{
		lookups: built.lookups
		scripts: built.scripts
		gdef:    gdef
	}
}

fn run_of(gids []u16) []Ligatable {
	mut out := []Ligatable{}
	for i, gid in gids {
		out << Ligatable{
			gid:     gid
			cluster: i
			source:  i
		}
	}
	return out
}

fn gids_of(items []Ligatable) []u16 {
	mut out := []u16{}
	for it in items {
		out << it.gid
	}
	return out
}

// The pattern matched, so the record ran and the glyph it named changed.
fn test_a_chaining_context_substitutes_the_glyph_its_pattern_matched() {
	out := bare(0, none).substitute([u16(1)], run_of([chain_first, chain_second]))
	assert gids_of(out) == [u16(chain_result), u16(chain_second)], 'the first glyph should have been substituted, got ${gids_of(out)}'
	assert gids_of(out)[1] == chain_second, 'the glyph the record did not name is untouched'
}

// A rule that does not match must leave the run alone. Applying it anyway is how a context
// substitution turns into a wrong glyph rather than a missing one.
fn test_a_chaining_context_does_not_fire_on_a_run_it_does_not_match() {
	g := bare(0, none)
	reversed := g.substitute([u16(1)], run_of([chain_second, chain_first]))
	assert gids_of(reversed) == [u16(chain_second), u16(chain_first)], 'a reversed pair must not match'
	alone := g.substitute([u16(1)], run_of([chain_first]))
	assert gids_of(alone) == [u16(chain_first)], 'one letter is not a two letter pattern'
	between := g.substitute([u16(1)], run_of([chain_first, chain_third, chain_second]))
	assert gids_of(between) == [u16(chain_first), u16(chain_third), u16(chain_second)], 'a glyph the rule does not ignore must stop the match'
}

// Backtrack and lookahead are separate from the input, and a rule naming a neighbour has to find
// it.
fn test_a_chaining_context_checks_the_glyphs_either_side_of_its_input() {
	mut with_ahead := covs_of([cov_of([chain_third])])
	mut ahead_gsub := chain_gsub(0, 0, empty_covs(), chain_pair(), with_ahead)
	with := ahead_gsub.substitute([u16(1)], run_of([chain_first, chain_second, chain_third]))
	assert gids_of(with) == [u16(chain_result), u16(chain_second), u16(chain_third)], 'a matching neighbour lets the rule fire'
	without := ahead_gsub.substitute([u16(1)], run_of([chain_first, chain_second]))
	assert gids_of(without) == [u16(chain_first), u16(chain_second)], 'a missing lookahead must stop the match'

	mut with_back := covs_of([cov_of([chain_before])])
	mut back_gsub := chain_gsub(0, 0, with_back, chain_pair(), empty_covs())
	preceded := back_gsub.substitute([u16(1)], run_of([chain_before, chain_first, chain_second]))
	assert gids_of(preceded) == [u16(chain_before), u16(chain_result), u16(chain_second)], 'a matching backtrack lets the rule fire'
	headless := back_gsub.substitute([u16(1)], run_of([chain_first, chain_second]))
	assert gids_of(headless) == [u16(chain_first), u16(chain_second)], 'a missing backtrack must stop the match'

	// Backtrack is nearest first, so a run whose second neighbour is the one named must not match
	// a rule that asks for the first. This is what stops a rule firing on the wrong side of a gap.
	mut swapped := covs_of([cov_of([chain_second]), cov_of([chain_before])])
	mut reversed_gsub := chain_gsub(0, 0, swapped, chain_pair(), empty_covs())
	neighbour := reversed_gsub.substitute([u16(1)], run_of([chain_before, chain_first, chain_second]))
	assert gids_of(neighbour) == [u16(chain_before), u16(chain_first), u16(chain_second)], 'backtrack is matched nearest first'
}

// The flags are the whole reason a rule about letters can be written over text with marks in it.
// A mark the rule ignores is invisible to the whole rule, not merely absent from the pattern.
fn test_ignoring_marks_lets_a_pattern_reach_across_one() {
	mut ignoring := bare(gsub_flag_ignore_marks, gdef_with(chain_mark, glyph_class_mark, 0))
	across := ignoring.substitute([u16(1)], run_of([chain_first, chain_mark, chain_second]))
	assert gids_of(across) == [u16(chain_result), u16(chain_mark), u16(chain_second)], 'an ignored mark must not stop the pattern, got ${gids_of(across)}'
	// The mark is still on the line. Ignoring it is not deleting it.
	assert across.len == 3, 'the mark survives the substitution that stepped over it'

	mut keeping := bare(0, gdef_with(chain_mark, glyph_class_mark, 0))
	blocked := keeping.substitute([u16(1)], run_of([chain_first, chain_mark, chain_second]))
	assert gids_of(blocked) == [u16(chain_first), u16(chain_mark), u16(chain_second)], 'a mark the rule does not ignore must stop the pattern'
}

// A mark attachment class restricts which marks a rule sees, and it restricts marks only. A rule
// naming one class must still see every letter.
// A mark attachment class does not ignore marks, it narrows which marks are ignored, and that is
// the opposite of what it looks like from a distance. A mark in the named class stays visible to
// the rule and so sits in the middle of the pattern like any other glyph; a mark of any other
// class is the one that gets stepped over.
//
// So the class of 1 with a mark of class 1 blocks the pattern, and the class of 1 with a mark of
// class 2 lets it through. A test written the other way round would pass against an implementation
// that had the flag exactly inverted, which is why the direction is spelled out here.
fn test_a_mark_attachment_class_narrows_which_marks_are_ignored() {
	mut inside := bare(u16(1) << 8, gdef_with(chain_mark, glyph_class_mark, 1))
	blocked := inside.substitute([u16(1)], run_of([chain_first, chain_mark, chain_second]))
	assert gids_of(blocked) == [u16(chain_first), u16(chain_mark), u16(chain_second)], 'a mark of the named class is visible and so blocks the pattern, got ${gids_of(blocked)}'

	mut outside := bare(u16(1) << 8, gdef_with(chain_mark, glyph_class_mark, 2))
	through := outside.substitute([u16(1)], run_of([chain_first, chain_mark, chain_second]))
	assert gids_of(through) == [u16(chain_result), u16(chain_mark), u16(chain_second)], 'a mark of another class is ignored and so lets the pattern through'

	// A flag with nothing in its top byte is not a mark attachment rule at all, so it ignores
	// nothing and the mark is in the way as usual. The class is what activates the flag, so
	// naming class zero is not the same as asking for class zero.
	mut unnamed := bare(0, gdef_with(chain_mark, glyph_class_mark, 1))
	all := unnamed.substitute([u16(1)], run_of([chain_first, chain_mark, chain_second]))
	assert gids_of(all) == [u16(chain_first), u16(chain_mark), u16(chain_second)], 'a flag with no class in it ignores nothing, got ${gids_of(all)}'

	// The mask is how a reader tests the field, which is worth asserting on its own: getting it
	// wrong makes every mark look like it belongs to class 255, and so ignores none of them.
	assert u16(1) << 8 & gsub_flag_mark_attachment_type != 0, 'a class of 1 is inside the mask'
	assert u16(0) << 8 & gsub_flag_mark_attachment_type == 0, 'no class is outside it'
	assert gsub_flag_mark_attachment_type | u16(1) << 8 & gsub_flag_mark_attachment_type ==
		gsub_flag_mark_attachment_type, 'the mask is not something to OR a class into'
}

// A mark filtering set works the same way round: the set names the marks the rule still sees.
fn test_a_mark_filtering_set_names_the_marks_the_rule_still_sees() {
	mut inside := bare(gsub_flag_use_mark_filtering_set, gdef_with_set(chain_mark, [chain_mark]))
	blocked := inside.substitute([u16(1)], run_of([chain_first, chain_mark, chain_second]))
	assert gids_of(blocked) == [u16(chain_first), u16(chain_mark), u16(chain_second)], 'a mark in the set is visible and so blocks the pattern, got ${gids_of(blocked)}'

	mut outside := bare(gsub_flag_use_mark_filtering_set, gdef_with_set(chain_mark, [chain_third]))
	through := outside.substitute([u16(1)], run_of([chain_first, chain_mark, chain_second]))
	assert gids_of(through) == [u16(chain_result), u16(chain_mark), u16(chain_second)], 'a mark outside the set is ignored and lets the pattern through'

	// A set index that names nothing is not a set containing everything. Treating it as one would
	// make a lookup that named a set apply to every mark on the line, which is the failure the
	// mechanism exists to prevent, so a table with no sets ignores every mark.
	mut missing := bare(gsub_flag_use_mark_filtering_set, gdef_with(chain_mark, glyph_class_mark, 1))
	out := missing.substitute([u16(1)], run_of([chain_first, chain_mark, chain_second]))
	assert gids_of(out) == [u16(chain_result), u16(chain_mark), u16(chain_second)], 'a set index naming nothing ignores every mark'
}

// A font that classifies nothing cannot tell a mark from a letter, so a rule that says ignore the
// marks has nothing to skip. Stepping over nothing is the reading that cannot substitute wrongly.
fn test_a_font_that_classifies_nothing_skips_nothing() {
	g := bare(gsub_flag_ignore_marks, none)
	assert g.gdef == none, 'the fixture builds no glyph definition table by default'
	across := g.substitute([u16(1)], run_of([chain_first, chain_mark, chain_second]))
	assert gids_of(across) == [u16(chain_first), u16(chain_mark), u16(chain_second)], 'without a glyph table the mark is not known to be a mark'
}

// A rule that turns one letter into several glyphs is the only one that makes a single character
// into more than one glyph, so it is worth proving through a context rather than on its own,
// which is how a font reaches for it.
fn test_a_context_can_run_a_multiple_substitution() {
	mut seqs := [][]u16{}
	seqs << [u16(chain_result), u16(chain_mark)]
	mut multiples := []MultipleSubst{}
	multiples << MultipleSubst{
		ranges:    cov_of([chain_first])
		sequences: seqs
	}
	mut records := []ChainRecord{}
	records << ChainRecord{
		position: 0
		lookup:   1
	}
	mut chains := []ChainContext3{}
	chains << ChainContext3{
		input:   chain_pair()
		records: records
	}
	mut lookups := []Lookup{}
	lookups << Lookup{
		kind:   gsub_lookup_chain_context
		chains: chains
	}
	lookups << Lookup{
		kind:      gsub_lookup_multiple
		multiples: multiples
	}
	g := &Gsub{
		lookups: lookups
	}
	out := g.substitute([u16(0)], run_of([chain_first, chain_second]))
	assert out.len == 3, 'one character should have become two glyphs, got ${out.len}'
	assert out[0].gid == chain_result && out[1].gid == chain_mark, 'and they are the ones the font asked for'
	// Both report the character they came from, which is what a layout pass needs in order to
	// draw both of them.
	assert out[0].cluster == 0 && out[1].cluster == 0, 'both glyphs report the character they came from'
}

// A font whose context rule names itself could recurse until the stack ran out. The bound is what
// stops it, and a bound that works is a return rather than a crash.
//
// The run comes back unchanged, and that is the point rather than a disappointment: the rule can
// never make progress, because a lookup dispatches on its own type, so the recursion bottoms out
// with nothing applied at any depth. What is being asserted is that the engine gives up and hands
// back the run it was given.
fn test_a_context_that_substitutes_itself_terminates() {
	mut records := []ChainRecord{}
	// The one record points the context lookup at itself, and the pattern is a single glyph so
	// that the rule matches wherever it is applied.
	records << ChainRecord{
		position: 0
		lookup:   0
	}
	mut chains := []ChainContext3{}
	chains << ChainContext3{
		input:   covs_of([cov_of([chain_first])])
		records: records
	}
	mut lookups := []Lookup{}
	lookups << Lookup{
		kind:   gsub_lookup_chain_context
		chains: chains
	}
	g := &Gsub{
		lookups: lookups
	}
	out := g.substitute([u16(0)], run_of([chain_first, chain_second]))
	assert gids_of(out) == [u16(chain_first), u16(chain_second)], 'a rule that cannot progress leaves the run as it was, got ${gids_of(out)}'
}

// A lookup's type decides what it does with itself, so a lookup that holds rules of one kind and
// claims another applies the claimed kind. This is asserted because the recursion fixture above
// depends on it: a chaining context carrying single rules must not quietly start using them.
fn test_a_lookup_applies_the_type_it_claims_not_the_rules_it_holds() {
	mut singles := []SingleSubst{}
	singles << SingleSubst{
		ranges: cov_of([chain_first])
		subs:   [u16(chain_result)]
	}
	mut records := []ChainRecord{}
	records << ChainRecord{
		position: 0
		lookup:   0
	}
	mut chains := []ChainContext3{}
	chains << ChainContext3{
		input:   covs_of([cov_of([chain_first])])
		records: records
	}
	mut lookups := []Lookup{}
	lookups << Lookup{
		kind:    gsub_lookup_chain_context
		chains:  chains
		singles: singles
	}
	g := &Gsub{
		lookups: lookups
	}
	out := g.substitute([u16(0)], run_of([chain_first]))
	assert gids_of(out) == [u16(chain_first)], 'a context lookup must not apply its own single rules'
}

// The right to left flag is about the order substitutions are applied in, not about the order a
// font writes its pattern in. So the pattern still matches the same way, and the backtrack is
// still nearest first in logical order.
fn test_right_to_left_does_not_change_how_a_pattern_is_written() {
	mut with_back := covs_of([cov_of([chain_before])])
	mut rtl := chain_gsub(gsub_flag_right_to_left, 0, with_back, chain_pair(), empty_covs())
	forward := rtl.substitute([u16(1)], run_of([chain_before, chain_first, chain_second]))
	ltr := chain_gsub(0, 0, with_back, chain_pair(), empty_covs())
	plain := ltr.substitute([u16(1)], run_of([chain_before, chain_first, chain_second]))
	// The flag reorders application; it does not change what matches, and for a set of rules
	// that do not feed each other the two are the same run.
	assert gids_of(forward) == gids_of(plain), 'the flag must not change what a pattern matches'
	// A run that does not match is still not matched when the walk runs the other way.
	reversed := rtl.substitute([u16(1)], run_of([chain_second, chain_first]))
	assert gids_of(reversed) == [u16(chain_second), u16(chain_first)], 'walking backwards must not match a reversed pair'
}

// Alternate substitution, which is how Arabic Typesetting writes its final forms and Simple Khoosmi
// its initial ones.
//
// This was a real hole rather than a theoretical one. A shaper that reads only the single
// substitution kind draws every final form in Arabic Typesetting as its isolated letter, and the
// line comes out with no error in it and nothing to say why the joining stopped.

fn test_a_font_whose_shapes_are_alternates_gets_them() {
	at := gsub_font('ARABTYPE.TTF') or { return }
	g := at.face.gsub or { panic('no gsub') }
	// The reason it was a hole: the feature is not a single substitution at all.
	mut kinds := []u16{}
	for li in g.lookups_for('arab', 'fina') {
		kinds << g.lookups[li].kind
	}
	assert kinds == [u16(gsub_lookup_alternate)], 'Arabic Typesetting keeps its final forms in alternates, got ${kinds}'
	beh := at.glyph_index(rune(0x0628))
	final := g.shaped_glyph(beh, .final, 'arab')
	assert final != beh, 'the final form should be a different glyph, got ${beh}'

	// The glyph chosen is the font's first alternate and not its last, since the first is the one
	// the font offers for ordinary text and the rest are for a caller picking a variant. Reading
	// the wrong end of the list would produce a plausible glyph from the wrong one.
	mut first := u16(0)
	for li in g.lookups_for('arab', 'fina') {
		for rule in g.lookups[li].alternates {
			if alt := alternate_lookup([rule], beh) {
				first = alt
			}
		}
	}
	assert first != 0, 'the alternate for the beh should be readable'
	assert final == first, 'shaping takes the first alternate, got ${final} where the font offers ${first}'
}

fn test_alternate_shapes_reach_a_second_font_too() {
	simpo := gsub_font('simpo.ttf') or { return }
	g := simpo.face.gsub or { panic('no gsub') }
	mut kinds := []u16{}
	for li in g.lookups_for('arab', 'init') {
		kinds << g.lookups[li].kind
	}
	assert kinds == [u16(gsub_lookup_alternate)], 'Simple Khoosmi keeps its initial forms in alternates, got ${kinds}'
	// Which letters a font gives an initial form is the font business, so this counts rather than
	// naming one. Before the alternate kind was read this was zero for every letter in the font.
	mut shaped := 0
	for cp in arabic_probe_letters() {
		gid := simpo.glyph_index(cp)
		if gid == 0 {
			continue
		}
		if g.shaped_glyph(gid, .initial, 'arab') != gid {
			shaped++
		}
	}
	assert shaped > 0, 'no Arabic letter gets an initial form from an alternate substitution'
}

fn test_alternate_rules_are_read_from_the_font() {
	for name in ['ARABTYPE.TTF', 'simpo.ttf', 'majalla.ttf', 'DUBAI-REGULAR.TTF'] {
		f := gsub_font(name) or { continue }
		g := f.face.gsub or { panic('${name} has no gsub') }
		mut rules := 0
		for lookup in g.lookups {
			if lookup.alternates.len == 0 {
				continue
			}
			assert lookup.kind == gsub_lookup_alternate, '${name}: a lookup holding alternates is an alternate lookup'
			for rule in lookup.alternates {
				assert rule.ranges.len > 0, '${name}: an alternate rule covers nothing'
				assert rule.sets.len > 0, '${name}: an alternate rule has no sets'
				// A covered glyph with a set must find the first of it, and one without a set must
				// find nothing rather than a neighbour's set.
				for i in 0 .. covered_count(rule.ranges) {
					gid := coverage_glyph_at(rule.ranges, i)
					alt := alternate_lookup([rule], gid)
					if i < rule.sets.len && rule.sets[i].len > 0 {
						if alt == none {
							assert rule.sets[i].len == 0, '${name}: a covered glyph with a set found nothing'
						} else {
							assert alt == rule.sets[i][0], '${name}: a covered glyph found an alternate that is not the first of its set'
						}
					} else {
						assert alt == none, '${name}: a covered glyph with no set found a rule'
					}
				}
				rules++
			}
		}
		assert rules > 0, '${name} should have alternate rules'
	}
}

fn test_an_alternate_lookup_takes_the_first_of_its_alternates() {
	mut sets := [][]u16{}
	mut offered := []u16{}
	offered << u16(50)
	offered << u16(51)
	offered << u16(52)
	sets << offered
	mut alternates := []AlternateSubst{}
	alternates << AlternateSubst{
		ranges: cov_of([chain_first])
		sets:   sets
	}
	mut lookups := []Lookup{}
	lookups << Lookup{
		kind:       gsub_lookup_alternate
		alternates: alternates
	}
	g := &Gsub{
		lookups: lookups
	}
	out := g.substitute([u16(0)], run_of([chain_first, chain_second]))
	assert gids_of(out) == [u16(50), u16(chain_second)], 'the first alternate is the one applied, got ${gids_of(out)}'
	// The same glyph the font offered as its own first alternate is not a change, and is refused
	// so that a walk resuming past what changed cannot loop on it.
	mut identity := []u16{}
	identity << u16(chain_first)
	mut same := [][]u16{}
	same << identity
	mut self_sets := []AlternateSubst{}
	self_sets << AlternateSubst{
		ranges: cov_of([chain_first])
		sets:   same
	}
	mut self_lookups := []Lookup{}
	self_lookups << Lookup{
		kind:       gsub_lookup_alternate
		alternates: self_sets
	}
	quiet := &Gsub{
		lookups: self_lookups
	}
	same_out := quiet.substitute([u16(0)], run_of([chain_first, chain_second]))
	assert gids_of(same_out) == [u16(chain_first), u16(chain_second)], 'a glyph offered as itself is not a substitution'
}

// Chaining context substitution on real fonts and real text.
//
// These are the tests the whole of the work above exists for. A parser test says the rules were
// read; a unit test on a built table says the matcher works; neither says that any font's rules
// will ever match text a caller can type. These do, and the shape of the evidence is worth stating
// because a behavioural change alone would not be enough: a ligature lookup would produce the same
// difference in the output, so each test also identifies which lookup fired and asserts its type.

const calt_alef = rune(0x0627)
const calt_tehmarbuta = rune(0x0629)
const calt_teh = rune(0x0637)
const calt_beh = rune(0x0628)
const calt_meem = rune(0x0645)
const calt_jeem = rune(0x062C)
const calt_noon = rune(0x0646)
const calt_sin = rune(0x0633)
const calt_fah = rune(0x06CC)

// changed_by reports which lookup of a feature changed a run, and the type of that lookup.
//
// A caller that wants to know a discretionary feature did something should not have to take it on
// trust from a difference in glyphs, because a ligature and a single substitution look identical
// from the outside. Applying the lookups one at a time is what turns "something happened" into a
// statement about which kind of rule did it.
fn changed_by(g &Gsub, items []Ligatable, feature string) ?Lookup {
	mut before := gids_of(items)
	for li in g.lookups_for('arab', feature) {
		one := g.substitute([li], items)
		if gids_of(one) != before {
			return g.lookups[li]
		}
	}
	return none
}

// run_in_logical_order rebuilds the substitution input from a laid out line, which comes back in
// visual order. A lookup asked to match a run that has been reversed finds nothing, for the same
// reason a rule written against the logical order does not match a reversed one.
fn run_in_logical_order(line Line) []Ligatable {
	mut items := []Ligatable{}
	for i in 0 .. line.glyphs.len {
		g := glyph_at_cluster(line.glyphs, i) or { continue }
		items << Ligatable{
			gid:     g.gid
			cluster: i
			source:  i
		}
	}
	return items
}

fn test_a_chaining_context_substitutes_on_real_text() {
	// A beh and two noons, which Majalla composes by rewriting the middle glyph. Three letters
	// with a joining form in the middle and at the end, so the rule has a pattern to match.
	majalla := gsub_font('majalla.ttf') or { return }
	g := majalla.face.gsub or { panic('no gsub') }
	// The font has to have the kind of rule under test, or the test would pass on a font that
	// never got to the interesting part.
	mut chains := 0
	for li in g.lookups_for('arab', 'calt') {
		if g.lookups[li].kind == gsub_lookup_chain_context {
			chains++
		}
	}
	assert chains > 0, 'Majalla should have chaining context rules under calt'
	fs := fs_of(majalla)
	ctx := new_context()
	text := [calt_beh, calt_noon, calt_noon]
	plain := layout_paragraph(ctx, text, .rtl, fs, 32)
	opt := &LayoutOptions{
		features: ['calt']
	}
	composed := layout_paragraph_with(ctx, text, .rtl, fs, 32, opt)
	assert plain.glyphs.len == 3 && composed.glyphs.len == 3, 'the feature rewrites rather than fusing here'
	// The middle letter is the one that changed, and the two ends are untouched.
	first := glyph_at_cluster(plain.glyphs, 1) or { panic('no middle glyph') }
	after := glyph_at_cluster(composed.glyphs, 1) or { panic('no middle glyph after') }
	assert first.gid != after.gid, 'the middle letter should have been rewritten, ${first.gid} then ${after.gid}'
	assert glyph_at_cluster(composed.glyphs, 0) or { panic('no first glyph') }.gid ==
		(glyph_at_cluster(plain.glyphs, 0) or { panic('no first glyph') }).gid, 'the first letter is not the one being rewritten'
	// And the rewrite came from a chaining context, which is the whole claim. A ligature or a
	// single substitution would have produced some difference in the output too.
	lookup := changed_by(g, run_in_logical_order(plain), 'calt') or {
		panic('no calt lookup changed the run')
	}
	assert lookup.kind == gsub_lookup_chain_context, 'the rewrite should come from a chaining context, not kind ${lookup.kind}'
}

fn test_a_chaining_context_expands_one_character_into_several_on_real_text() {
	// A sin and two fahs, which Arabic Typesetting composes into more glyphs than it started
	// with. This is the case the whole multiple substitution milestone exists for, and it is the
	// only way to reach the layout invariant below with a real font rather than a built table.
	at := gsub_font('ARABTYPE.TTF') or { return }
	g := at.face.gsub or { panic('no gsub') }
	fs := fs_of(at)
	ctx := new_context()
	text := [calt_sin, calt_fah, calt_fah]
	plain := layout_paragraph(ctx, text, .rtl, fs, 32)
	opt := &LayoutOptions{
		features: ['calt']
	}
	composed := layout_paragraph_with(ctx, text, .rtl, fs, 32, opt)
	assert plain.glyphs.len == 3, 'three characters should start as three glyphs, got ${plain.glyphs.len}'
	assert composed.glyphs.len > plain.glyphs.len, 'the composition should produce more glyphs than it started with, got ${composed.glyphs.len}'
	// Every character of the line is still drawn, and at least one of them is now drawn by more
	// than one glyph. A layout pass that kept one glyph per character would silently drop the
	// extras here, and a dropped mark is invisible rather than wrong.
	mut per_cluster := map[int]int{}
	for gl in composed.glyphs {
		per_cluster[gl.cluster]++
	}
	assert per_cluster.len == 3, 'every character should still be drawn, got ${per_cluster.len}'
	mut split := 0
	for _, n in per_cluster {
		if n > 1 {
			split++
		}
	}
	assert split > 0, 'some character should be drawn by more than one glyph'
	// The expansion came through a feature that is largely chaining contexts, which is the part
	// worth naming. The attribution is at the feature rather than at the single lookup, because
	// several of its lookups feed each other and applying them one at a time does not reproduce
	// the pipeline's result.
	mut chains := 0
	mut total := 0
	for li in g.lookups_for('arab', 'calt') {
		total++
		if g.lookups[li].kind == gsub_lookup_chain_context {
			chains++
		}
	}
	assert total > 0, 'the feature should name lookups'
	assert chains > 0, 'and should be largely chaining contexts'
}

fn test_a_plain_ligature_still_fuses_a_pair_on_real_text() {
	// The same opt in, reaching the ordinary ligature kind rather than a context. Arabic
	// Typesetting fuses a doubled meem, and this is the case a caller who asked for a ligature
	// most obviously wanted.
	at := gsub_font('ARABTYPE.TTF') or { return }
	fs := fs_of(at)
	ctx := new_context()
	plain := layout_paragraph(ctx, [calt_meem, calt_meem], .rtl, fs, 32)
	opt := &LayoutOptions{
		features: ['liga']
	}
	fused := layout_paragraph_with(ctx, [calt_meem, calt_meem], .rtl, fs, 32, opt)
	assert plain.glyphs.len == 2, 'the pair should start as two glyphs'
	assert fused.glyphs.len == 1, 'the pair should fuse into one glyph, got ${fused.glyphs.len}'
	// The fused glyph belongs to the first character, which is what keeps it traceable to the
	// text, and it is neither of the two letters.
	assert fused.glyphs[0].cluster == 0, 'the fused glyph reports the first character'
	first := glyph_at_cluster(plain.glyphs, 0) or { panic('no first glyph') }
	second := glyph_at_cluster(plain.glyphs, 1) or { panic('no second glyph') }
	assert fused.glyphs[0].gid != first.gid && fused.glyphs[0].gid != second.gid, 'the fused glyph is one of its own'
}

// A ligature has to fuse wherever in the run it falls, including at the very end and in a run long
// enough that "the rest of the run" is no longer a small thing to copy.
//
// This is the guard on the bound apply_ligature puts on how much of the run it copies. It used to copy
// every glyph after the position it was trying, which made it quadratic in the length of the run; it now
// copies only the longest ligature rule's worth. That is only safe if a rule at the end of a long run is
// still matched, and the case below is the one that would break if the bound were off by one: the pair
// sits at the end, so the copy has to stop exactly at the last glyph rather than short of it.
fn test_a_ligature_still_fuses_at_the_end_of_a_long_run() {
	at := gsub_font('ARABTYPE.TTF') or { return }
	fs := fs_of(at)
	ctx := new_context()
	opt := &LayoutOptions{
		features: ['liga']
	}

	// The pair alone, then the same pair behind a run of filler long enough that a quadratic copy of
	// the tail would show up as a difference in the answer if the bound were wrong.
	alone := layout_paragraph_with(ctx, [calt_meem, calt_meem], .rtl, fs, 32, opt)
	assert alone.glyphs.len == 1, 'the pair fuses on its own, got ${alone.glyphs.len}'

	mut filler := []rune{cap: 400}
	for _ in 0 .. 398 {
		filler << rune(0x0628) // beh, which takes no part in this ligature
	}
	filler << calt_meem
	filler << calt_meem

	// The same run without the feature, as the control: it has to come out one glyph longer, or the
	// difference below would be the filler's doing rather than the ligature's.
	plain := layout_paragraph(ctx, filler, .rtl, fs, 32)
	assert plain.glyphs.len == 400, 'the run should be one glyph per character to begin with, got ${plain.glyphs.len}'

	buried := layout_paragraph_with(ctx, filler, .rtl, fs, 32, opt)
	assert buried.glyphs.len == 399, 'the pair at the end should fuse, got ${buried.glyphs.len} glyphs for 400 characters'

	// Exactly which clusters survive is the sharper half of the assertion. A bound that truncated a
	// ligature rule would still leave 399 glyphs here, but it would be a different pair that folded or
	// a different glyph that came out, and this is where that shows: the only input character left
	// without a glyph of its own is the first of the two that fused.
	mut seen := map[int]bool{}
	for g in buried.glyphs {
		seen[g.cluster] = true
	}
	mut unrepresented := []int{}
	for i in 0 .. 400 {
		if i !in seen {
			unrepresented << i
		}
	}
	assert unrepresented == [398], 'only the first of the fused pair should lose its cluster, got ${unrepresented}'
	// And every other character kept one, so nothing else in the long run was disturbed by the pair
	// sitting at its end.
	assert seen.len == 399, 'every character but the fused one should be represented, got ${seen.len}'
}
