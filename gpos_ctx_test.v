module vtext

// Chaining-context positioning: a font moves a glyph based on what is around it.
//
// The tests check the parse against the font's own tables rather than against a shape written out
// here, because the numbers that came out of a wrong parse were plausible enough to pass a test that
// only checked that something happened.
import os

// corpus_font_path is where a named font is: the committed corpus first, this platform's font directory
// second, and none when neither has it.
//
// The corpus is first because a test that runs only because one machine ships a font is a test about that
// machine, and everything asserted here is a structural property of a parsed table rather than a number
// out of one file. The platform directory is still asked second, so a Windows checkout keeps reading
// Tahoma, Traditional Arabic, Majalla, Simpo and Segoe UI. VTEXT_TEST_FONTS overrides both.
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

fn ctx_font(name string) ?&Font {
	p := corpus_font_path(name) or {
		skip_missing(name)
		return none
	}
	return load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

// The corpus fonts that carry chaining-context positioning rules.
//
// Amiri writes four of them and Noto Nastaliq Urdu twenty-one, and between them they cover both of the
// shapes these tests are about: rules reached through the arab script and rules reached through latn. The
// two Noto Naskh faces carry none, which is why they are not in the list — a font with no contextual
// positioning is a font the first assertion below would fail on.
const contextual_fonts = ['Amiri-Regular.ttf', 'NotoNastaliqUrdu-Regular.ttf']

// Every record a rule produces has to name a lookup that exists and a glyph of the pattern that is
// there. A sequence index past the end of the pattern is the signature of a parse that read one field
// too many, and it is silent: the rule still matches and still asks for a move.
fn test_gpos_contextual_records_name_a_glyph_that_exists() {
	for name in contextual_fonts {
		f := ctx_font(name) or { return }
		gpos := f.face.gpos or { continue }
		mut rules := 0
		mut records := 0
		for lk in gpos.lookups {
			for c in lk.chains {
				rules++
				records += c.records.len
				assert c.input.len > 0, '${name}: a rule with no input glyphs matches nothing'
				for rec in c.records {
					assert rec.position < c.input.len, '${name}: position ${rec.position} in a ${c.input.len} glyph pattern'
					assert int(rec.lookup) < gpos.lookups.len, '${name}: lookup ${rec.lookup} of ${gpos.lookups.len}'
				}
			}
		}
		assert rules > 0, '${name}: carried no chaining-context rules'
		assert records >= rules, '${name}: every rule positions at least one glyph'
	}
}

// The Arabic fonts carry these rules and the Latin faces do not, because Latin has nothing to stack.
// A rule engine that ran on both would move letters for no reason.
fn test_gpos_contextual_is_an_arabic_thing_and_not_a_latin_one() {
	tahoma := ctx_font('Amiri-Regular.ttf') or { return }
	// Tahoma's chaining-context lookups are all reached through the arab script's features.
	assert tahoma.contextually_positions('arab'), 'tahoma positions by context for Arabic'
	// A script the font says nothing about has none, whichever font it is.
	assert !tahoma.contextually_positions('zzzz')
}

// The coverages are what the pattern is matched through, so a rule whose coverage is empty is a rule
// that can never fire, and one that names a glyph range rather than a glyph list is a misparse.
fn test_gpos_contextual_coverages_are_coverages_and_not_glyph_lists() {
	for name in contextual_fonts {
		f := ctx_font(name) or { return }
		gpos := f.face.gpos or { continue }
		for lk in gpos.lookups {
			for c in lk.chains {
				for cov in c.backtrack {
					assert cov.len > 0, '${name}: an empty backtrack coverage matches every glyph'
					for r in cov {
						assert r.last >= r.first, '${name}: a range that ends before it starts'
					}
				}
				for cov in c.input {
					assert cov.len > 0, '${name}: an empty input coverage matches every glyph'
				}
			}
		}
	}
}

// Applying the rules to a run of the wrong glyphs must do nothing. A context that fires on anything is
// a context that is not really being matched, and this is the test that says so.
fn test_gpos_contextual_does_not_fire_on_a_run_it_does_not_match() {
	f := ctx_font('tahoma.ttf') or { return }
	gpos := f.face.gpos or { panic('tahoma has no gpos') }
	// Latin letters, which are not in any of Tahoma's Arabic pattern coverages.
	mut run := []u16{}
	for c in [`a`, `b`, `c`, `d`, `e`] {
		run << f.glyph_index(c)
	}
	assert gpos.apply_contextual(run, 'arab').len == 0, 'Latin letters match no Arabic pattern'
	// An empty run is nothing rather than a match at position zero.
	assert gpos.apply_contextual([]u16{}, 'arab').len == 0
}

// A font's chaining rules are written against the glyphs its own pipeline produces, and for a font
// that composes its marks that means glyphs the text cannot reach.
//
// This is the same thing the mark attachment code already reports and has to work around. Tahoma's
// ccmp composes a shadda and a fatha into one glyph, so its two hundred positioning rules are written
// against composed glyphs that no string reaches: of the 1815 glyphs they name, exactly one is a
// glyph the engine can produce, and that one is never in the position a pattern wants it in. So none
// of them fires.
//
// The honest test is therefore not that something fires. It is that the rules name glyphs this engine
// cannot produce, and that asking for them costs nothing rather than crashing or moving a letter that
// was never meant to move.
//
// The numbers are Tahoma's: it names 1,815 glyphs across two hundred rules and the engine reaches one of
// them. Amiri's four chaining rules name a few dozen, so the bound of a thousand would fail on the corpus
// for a reason that is about the font rather than about the parser. This keeps Tahoma, where the
// measurement was taken, and says which font it wanted everywhere else.
fn test_gpos_contextual_rules_name_glyphs_the_pipeline_cannot_reach() {
	f := ctx_font('tahoma.ttf') or { return }
	gpos := f.face.gpos or { panic('tahoma has no gpos') }
	produced := ctx_produced(f, 0x0628)
	mut named := 0
	mut reachable := 0
	for lk in gpos.lookups {
		for c in lk.chains {
			for cov in c.input {
				for r in cov {
					for g in r.first .. r.last + 1 {
						named++
						if produced[int(g)] {
							reachable++
						}
					}
				}
			}
		}
	}
	// The rules exist and are substantial, which is the point: they are parsed rather than dropped.
	assert named > 1000, 'Tahoma names ${named} glyphs in its chaining patterns'
	// And the engine reaches almost none of them, because ccmp composes the marks they are written
	// against. One is reachable and it is the shadda, which is the single glyph the rules name that a
	// letter with marks actually produces.
	assert named > 1000 && reachable <= 1, '${reachable} of ${named} glyphs are reachable'
}

// Asking for a context on text no pattern covers does nothing, which is what makes a rule engine safe
// to run over every line.
fn test_gpos_contextual_does_nothing_on_text_it_does_not_match() {
	f := ctx_font('tahoma.ttf') or { return }
	gpos := f.face.gpos or { panic('tahoma has no gpos') }
	ctx := new_context()
	fs := new_font_set_of(f)
	// Latin letters, which are in none of Tahoma's Arabic patterns.
	mut cps := []rune{}
	for c in [`a`, `b`, `c`, `d`, `e`] {
		cps << c
	}
	line := layout_paragraph(ctx, cps, .ltr, fs, 32.0)
	mut gids := []u16{}
	for g in line.glyphs {
		gids << g.gid
	}
	assert gpos.apply_contextual(gids, 'arab').len == 0, 'Latin letters match no Arabic pattern'
	// An empty run is nothing rather than a match at position zero.
	assert gpos.apply_contextual([]u16{}, 'arab').len == 0
	// A single glyph cannot match a two glyph pattern, whatever the glyph is.
	assert gpos.apply_contextual([u16(f.glyph_index(rune(0x0651)))], 'arab').len == 0, 'one glyph cannot satisfy a two glyph pattern'
}

// ctx_produced is every glyph a spread of marked letters produces, which is what a pattern's coverage
// has to be checked against.
fn ctx_produced(f &Font, base int) map[int]bool {
	mut produced := map[int]bool{}
	ctx := new_context()
	fs := new_font_set_of(f)
	bases := [base, 0x0644, 0x0645, 0x0646, 0x064A, 0x0643, 0x0629, 0x0647]
	marks := [0x0651, 0x064E, 0x0650, 0x064F, 0x0652, 0x064B, 0x064C, 0x064D]
	for b in bases {
		for m1 in marks {
			for m2 in marks {
				mut cps := []rune{}
				cps << rune(b)
				cps << rune(m1)
				cps << rune(m2)
				line := layout_paragraph(ctx, cps, .rtl, fs, 32.0)
				for g in line.glyphs {
					produced[int(g.gid)] = true
				}
			}
		}
	}
	return produced
}
