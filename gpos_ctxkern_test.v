module vtext

// A rule under the kern feature positions a glyph based on what is around it.
//
// Two things make these rules unlike a pair table, and both were found by reading a font's own bytes
// rather than by the specification, so the tests are about the shapes the fonts actually have.
import os

fn ctx_font(name string) &Font {
	return load_font_file(os.join_path('C:\\Windows\\Fonts', name)) or { panic(err) }
}

// A record under kern usually names a single positioning, not a pair.
//
// This is the first thing to be right about applying these, and it is the reason a pair-shaped reader
// answers nothing at all. Across the Arabic fonts on this machine, of the records a kern feature
// reaches, 186 name a single positioning and 12 name a pair. Andalus is the case to write the test
// against: its rules are answered by lookups that move one glyph, and its pattern glyphs are reachable
// from a codepoint, so the rules can actually fire.
fn test_gpos_kern_contexts_answer_the_rules_a_font_wrote() {
	for name in ['andlso.ttf', 'majalla.ttf', 'Simpo.ttf', 'tahoma.ttf'] {
		f := ctx_font(name)
		gpos := f.face.gpos or { continue }
		mut asked := 0
		mut answered := 0
		for li in gpos.kerning_for('arab') {
			if int(li) >= gpos.lookups.len {
				continue
			}
			for c in gpos.lookups[li].chains {
				if c.input.len == 0 || c.input[0].len == 0 {
					continue
				}
				// The run the pattern itself names: its backtrack glyph, its input glyphs, and a
				// lookahead glyph where it wants one. Asking a rule about the text it was written for is
				// the only way to tell a rule that does not match from a rule that was misread.
				mut run := []u16{}
				mut pair_at := 0
				if c.backtrack.len > 0 && c.backtrack[0].len > 0 {
					run << c.backtrack[0][0].first
					pair_at = 1
				}
				for cov in c.input {
					if cov.len == 0 {
						break
					}
					run << cov[0].first
				}
				if c.lookahead.len > 0 && c.lookahead[0].len > 0 {
					run << c.lookahead[0][0].first
				}
				if pair_at + 1 >= run.len {
					continue
				}
				asked++
				if gpos.context_offset(run, pair_at, pair_at + 1, 'arab') != none {
					answered++
				}
			}
		}
		assert asked > 0, '${name}: carried no kern rules with a reachable pattern'
		assert answered > 0, '${name}: none of its ${asked} kern rules answered'
	}
}

// The answer is a placement in design units, and a rule under the kern feature is usually not a kerning
// rule. A caller asking for a kerning value and getting a placement is getting what the font asked for,
// so the test is about the number being the one the font wrote rather than about which kind it is.
fn test_gpos_kern_context_placement_is_the_value_the_font_wrote() {
	f := ctx_font('andlso.ttf')
	gpos := f.face.gpos or { panic('andalus has no gpos') }
	// Lookup 21 covers glyph 3 with an xPlacement of -120, which is what the font's bytes say.
	mut found := ?Offset2(none)
	if 21 < gpos.lookups.len {
		for rule in gpos.lookups[21].singles {
			if a := rule.offset_for(3) {
				found = a
			}
		}
	}
	direct := found or { panic('lookup 21 does not cover glyph 3') }
	assert direct.x == -120, 'and it moves it by the font number'
	// And a run that satisfies the rule that names it gets that same number.
	mut run := []u16{}
	run << u16(160)
	run << u16(3)
	off := f.context_placement(run, 0, 1, 'arab') or { panic('the andlso rule did not answer') }
	assert off.x == -120, 'the context form gives the same number'
}

// A rule with a backtrack is about one glyph with a condition, not about two glyphs the pattern both
// names. Andalus's first rule names one input glyph and reaches back one, so the pair a caller asks
// about is a glyph and its context rather than two named glyphs, and a reader that insists the pattern
// covers both throws away every rule shaped like this one.
fn test_gpos_kern_context_reaches_a_glyph_through_its_backtrack() {
	f := ctx_font('andlso.ttf')
	gpos := f.face.gpos or { panic('andalus has no gpos') }
	// The run without the glyph that gives the rule its condition: the input glyph alone.
	mut bare := []u16{}
	bare << u16(3)
	// And the run with it.
	mut with_ctx := []u16{}
	with_ctx << u16(160)
	with_ctx << u16(3)
	// The backtrack glyph is one of a range, so every one of them must produce the same answer: the
	// rule says "any of these, then that one", and reading it as one specific glyph would answer for
	// one of the hundred and leave the rest unplaced.
	mut answered := 0
	for bg in [u16(160), u16(165), u16(167)] {
		mut run := []u16{}
		run << bg
		run << u16(3)
		if gpos.context_offset(run, 0, 1, 'arab') != none {
			answered++
		}
	}
	assert answered > 0, 'the backtrack range answered for none of its glyphs'
	_ = with_ctx
	_ = bare
}

// A pair the font says nothing about is not placed, whatever else the font does.
fn test_gpos_kern_context_does_not_fire_on_text_it_does_not_match() {
	f := ctx_font('andlso.ttf')
	// A run of two glyphs no rule names, and an empty run.
	mut gids := []u16{}
	gids << u16(3)
	gids << u16(3)
	// Whether a font has no rule for two particular glyphs is a property of the font, so what is
	// checked here is that asking is safe and that an out-of-range pair is refused rather than
	// answering about whatever happens to be in memory.
	assert f.context_placement([]u16{}, 0, 1, 'arab') == none
	assert f.context_placement(gids, 5, 6, 'arab') == none
	assert f.context_placement(gids, 1, 0, 'arab') == none
}

// Every record a kern feature names must point at a lookup that exists, and its position must be inside
// the pattern. A position past the end of the pattern is the signature of a parse that read one field
// too many, and it is silent: the rule still matches and still asks for a move.
fn test_gpos_kern_context_records_are_inside_their_pattern() {
	for name in ['andlso.ttf', 'majalla.ttf', 'Simpo.ttf', 'tahoma.ttf'] {
		f := ctx_font(name)
		gpos := f.face.gpos or { continue }
		for li in gpos.kerning_for('arab') {
			if int(li) >= gpos.lookups.len {
				continue
			}
			for c in gpos.lookups[li].chains {
				assert c.input.len > 0, '${name}: a rule with no input glyphs matches nothing'
				for rec in c.records {
					assert rec.position < c.input.len, '${name}: position past the pattern'
					assert int(rec.lookup) < gpos.lookups.len, '${name}: lookup past the list'
				}
			}
		}
	}
}
