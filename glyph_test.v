module vtext

// Tests for the font layer: codepoint to glyph, and the fallback chain.

import os

// corpus_font_path is where a named font is: the committed corpus first, this platform's font directory
// second, and none when neither has it.
//
// The corpus is first because a test that runs only because one machine ships Segoe UI is a test about
// that machine. The platform directory is still asked second, so a Windows checkout keeps reading the
// fonts this file was written against where the corpus has none of them. VTEXT_TEST_FONTS overrides both.
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

// load_test_font loads a font for a test, or reports that it cannot and lets the test skip.
fn load_test_font(name string) ?&Font {
	p := corpus_font_path(name) or {
		skip_missing(name)
		return none
	}
	return load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

// The two corpus fonts this file reads, and why each is the one for the job.
//
// amiri is a naskh Arabic face with Latin, the presentation forms and real marks, so it stands in for
// Segoe UI everywhere this file needs a font that covers a letter.
//
// nastaliq maps none of the Arabic presentation forms: it carries the base letters and keeps their shapes
// in GSUB, which is the shape the form-missing branches need. It replaces both Dubai (which also lacks the
// forms) and Consolas (which has no Arabic at all).
fn amiri() ?&Font {
	return load_test_font('Amiri-Regular.ttf')
}

fn nastaliq() ?&Font {
	return load_test_font('NotoNastaliqUrdu-Regular.ttf')
}

fn test_glyph_for_a_covered_codepoint() {
	f := amiri() or { return }
	g := f.glyph_for(`A`, 32)
	assert g.gid != 0, 'A is in the corpus font, so it should not be .notdef'
	assert (g.font or { panic('a glyph from a font has to name it') }) == f
	assert !g.is_mark, 'a letter is not a mark'
	// An advance is a fixed slice of the em, so twice the size is twice the advance.
	d := f.glyph_advance(g.gid, 64) - 2 * g.advance
	assert d > -0.001 && d < 0.001, 'the advance should scale with the em, off by ${d}'
}

fn test_glyph_for_an_uncovered_codepoint() {
	f := amiri() or { return }
	// A codepoint no font covers is .notdef rather than an error, because a single font
	// cannot answer for a whole line and a caller still needs a glyph to place.
	assert !f.has_glyph(0x10FFFF)
	assert f.glyph_for(0x10FFFF, 32).gid == 0
}

fn test_mark_glyph_has_no_advance() {
	f := amiri() or { return }
	g := f.mark_glyph(rune(0x064E), 32) // ARABIC FATHA
	assert g.is_mark, 'a mark should be flagged as one'
	assert g.advance == 0, 'a mark must not move the pen'
	assert g.gid != 0, 'the corpus font covers fatha, so the mark should have a real glyph'
}

fn test_font_set_prefers_the_first_font() {
	latin := amiri() or { return }
	arabic := load_test_font('NotoNaskhArabic-Regular.ttf') or { return }
	fs := new_font_set()
	fs.add(latin)
	fs.add(arabic)
	assert fs.len() == 2
	// Both fonts cover Latin, so the preferred one wins even though the other would too.
	assert picked(fs, `A`) == latin
	assert picked(fs, `Z`) == latin
}

// picked is pick with the chain known to be non-empty, which keeps the assertions about
// which font was chosen readable.
fn picked(fs &FontSet, cp rune) &Font {
	return fs.pick(cp) or { panic('the chain is not empty') }
}

fn test_font_set_falls_through_to_a_later_font() {
	// The Nastaliq font maps none of the Arabic presentation forms, which makes it exactly the preferred
	// font that has to be passed over, and Amiri behind it answers.
	formless := nastaliq() or { return }
	arabic := amiri() or { return }
	assert !formless.has_glyph(rune(0xFEFB)), 'the Nastaliq font is not expected to cover the lam-alef form'
	fs := new_font_set()
	fs.add(formless)
	fs.add(arabic)
	// The ligature form is only in the second font, so the chain has to reach it.
	assert picked(fs, rune(0xFEFB)) == arabic
	g := fs.glyph(rune(0xFEFB), 32)
	assert (g.font or { panic('the glyph has to report its font') }) == arabic
	assert g.gid == arabic.glyph_index(rune(0xFEFB))
	assert g.advance == arabic.glyph_advance(g.gid, 32)
}

fn test_font_set_lands_on_the_preferred_font_when_nothing_covers() {
	f := amiri() or { return }
	fs := new_font_set_of(f)
	ctx := new_context()
	assert fs.len() == 1
	// Nothing in the chain covers it, so the first font answers with .notdef. Dropping the
	// character instead would silently reflow the line.
	assert picked(fs, 0x10FFFF) == f
	assert fs.glyph(0x10FFFF, 32).gid == 0
}

fn test_empty_font_set_answers_safely() {
	fs := new_font_set()
	assert fs.len() == 0
	// An empty chain is a wiring mistake rather than a missing character, and it stays
	// distinct from one so that pick can report it.
	assert fs.pick(`A`) == none
	// Asking anyway has to give a .notdef glyph rather than crash.
	g := fs.glyph(`A`, 32)
	assert g.gid == 0
	assert g.advance == 0
	assert g.font == none
}

// Tests for mapping a shaped letter onto glyphs, which is the decision about whether the
// shape can be drawn at all.

fn test_shaped_glyphs_prefers_the_form_when_a_font_has_it() {
	// Amiri carries the presentation forms, so the form is what gets drawn.
	arabic := amiri() or { return }
	fs := new_font_set_of(arabic)
	ctx := new_context()
	sg := ShapedGlyph{
		cps:  [rune(0xFE8F)] // ARABIC LETTER BEH ISOLATED FORM
		base: [rune(0x0628)]
		form: .isolated
	}
	out := fs.shaped_glyphs(ctx, sg, 32)
	assert out.len == 1, 'one shaped letter is one glyph when the form is there'
	assert out[0].gid == arabic.glyph_index(rune(0xFE8F))
	assert out[0].form == .isolated
}

fn test_shaped_glyphs_falls_back_to_the_base_letter() {
	// The Nastaliq font carries the base letters but not the presentation forms, because it keeps
	// its shapes in a GSUB table rather than in the cmap.
	formless := nastaliq() or { return }
	assert !formless.has_glyph(rune(0xFE8F))
	assert formless.has_glyph(rune(0x0628))
	fs := new_font_set_of(formless)
	ctx := new_context()
	sg := ShapedGlyph{
		cps:  [rune(0xFE8F)]
		base: [rune(0x0628)]
		form: .final
	}
	out := fs.shaped_glyphs(ctx, sg, 32)
	assert out.len == 1, 'the base letter stands in for the missing form'
	assert out[0].gid == formless.glyph_index(rune(0x0628))
	// The shape has to survive the substitution, because that is what the OpenType pass
	// needs to pick the right variant of the base letter.
	assert out[0].form == .final, 'the shape survives a missing form'
}

// A ligature is the only shaped letter that stands for more than one character, so a chain
// that cannot draw it has to produce more than one glyph.
fn test_shaped_glyphs_splits_a_ligature_the_chain_cannot_draw() {
	// The Nastaliq font has no Arabic presentation forms at all, so the base route is the only one left.
	// What is under test is that the pair becomes two glyphs with the right shapes.
	formless := nastaliq() or { return }
	fs := new_font_set_of(formless)
	ctx := new_context()
	sg := ShapedGlyph{
		cps:  [rune(0xFEFC)] // ARABIC LIGATURE LAM WITH ALEF FINAL FORM
		base: [rune(0x0644), rune(0x0627)]
		form: .final
	}
	out := fs.shaped_glyphs(ctx, sg, 32)
	assert out.len == 2, 'a lam-alef is drawn as its two letters'
	// The lam takes the shape the ligature had, and the alef connects backwards because the
	// lam did.
	assert out[0].form == .final
	assert out[1].form == .final
	// A pair standing on its own joined nothing, so neither half is final.
	lone := ShapedGlyph{
		cps:  [rune(0xFEFB)] // ARABIC LIGATURE LAM WITH ALEF ISOLATED FORM
		base: [rune(0x0644), rune(0x0627)]
		form: .isolated
	}
	apart := fs.shaped_glyphs(ctx, lone, 32)
	assert apart.len == 2
	assert apart[0].form == .isolated && apart[1].form == .isolated
}

fn test_shaped_glyphs_asks_the_whole_chain_about_the_form() {
	// The form is in neither font, so the base letter is asked for instead and the second
	// font is the one that answers.
	//
	// The corpus holds exactly one font that carries no presentation forms, so both entries in the chain
	// are it. What is under test is that the whole chain is walked rather than the first font answered,
	// and a chain whose two members are the same font still walks twice.
	formless := nastaliq() or { return }
	ctx := new_context()
	fs := new_font_set()
	fs.add(formless)
	fs.add(formless)
	sg := ShapedGlyph{
		cps:  [rune(0xFE8F)]
		base: [rune(0x0628)]
		form: .isolated
	}
	assert !fs.covers(rune(0xFE8F)), 'neither font has the isolated form'
	out := fs.shaped_glyphs(ctx, sg, 32)
	assert out.len == 1
	assert out[0].gid == formless.glyph_index(rune(0x0628))
}

fn test_shaped_glyphs_keeps_a_mark_flagged_and_advanceless() {
	arabic := amiri() or { return }
	fs := new_font_set_of(arabic)
	ctx := new_context()
	sg := ShapedGlyph{
		cps:     [rune(0x064E)] // ARABIC FATHA
		base:    [rune(0x064E)]
		form:    .isolated
		is_mark: true
	}
	out := fs.shaped_glyphs(ctx, sg, 32)
	assert out.len == 1
	assert out[0].is_mark, 'a mark stays a mark whichever route produced its glyph'
	assert out[0].advance == 0, 'a mark must not move the pen'
}

fn test_shaped_glyphs_with_no_base_characters_draws_nothing() {
	fs := new_font_set_of(amiri() or { return })
	ctx := new_context()
	assert fs.shaped_glyphs(ctx, ShapedGlyph{ cps: [rune(0x41)], base: []rune{} }, 32).len == 0
}
