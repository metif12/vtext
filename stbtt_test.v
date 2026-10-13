module vtext

// The box query and the rasterizer must agree about where a glyph's ink is.
//
// Face.box_only exists because measure_line used to rasterize every glyph of every paragraph to read two
// numbers out of the result and throw the pixels away. That is a large cost to pay for an extent, and
// removing it is only safe if the two paths really do report the same box.
//
// That is asserted here rather than argued in a comment. The argument would be one step from the header's
// own definition — stbtt_GetGlyphBitmapBox is a call to the subpixel form with a shift of zero, at
// stb_truetype.h:2739 — and a future stb_truetype that changed it would fail silently. This test is what
// would notice.
//
// The sweep is over every glyph the font has rather than over a sample, so a font with an outline that
// reaches outside the usual box in either direction is covered rather than missed.
//
// What this file does not test is that measure_line calls box_only. Proving which of two functions a
// caller reached needs a counter on Face, and a mutable field added for a test is a worse cost than the
// performance it would guard: it would make every loaded font's face mutable, which is the one thing
// about Font that is currently load-bearing. The call site is one line, and the numbers it produces are
// pinned by the sweep below whichever path it takes.

import os

// corpus_font_path is where a named font is: the committed corpus first, this platform's font directory
// second, and none when neither has it.
//
// The corpus is first because a test that runs only because one machine ships a font is a test about that
// machine, and the whole sweep below is about the two box queries agreeing rather than about any one
// font's outlines. The platform directory is still asked second, so a Windows checkout keeps reading Segoe
// UI and Tahoma. VTEXT_TEST_FONTS overrides both.
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

// font_from loads a font for a test, or reports that it cannot and lets the test skip.
fn font_from(name string) ?&Font {
	p := corpus_font_path(name) or {
		skip_missing(name)
		return none
	}
	return load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

// amiri is the corpus font these tests sweep.
//
// It has the widest repertoire of the committed faces — Latin, Arabic, the marks and the ligatures — and
// every glyph in it has an outline, so the sweep covers everything the sweep is for. The width of the
// repertoire is what the original assertion wanted from Segoe UI; the glyph count is what makes the sweep
// worth running at all.
fn amiri() ?&Font {
	return font_from('Amiri-Regular.ttf')
}

fn test_box_only_reports_the_same_box_as_rasterizing() {
	f := amiri() or { return }
	em_px := 32.0
	mut checked := 0
	for gid in 0 .. u16(f.num_glyphs()) {
		rendered := f.face.rasterize_glyph(gid, em_px, 0, 0)
		box := f.face.box_only(gid, em_px)
		assert box.width == rendered.width, 'gid ${gid}: width ${box.width} against ${rendered.width}'
		assert box.height == rendered.height, 'gid ${gid}: height ${box.height} against ${rendered.height}'
		assert box.left == rendered.left, 'gid ${gid}: left ${box.left} against ${rendered.left}'
		assert box.top == rendered.top, 'gid ${gid}: top ${box.top} against ${rendered.top}'
		// The box carries no pixels, which is the entire point of it. A caller that reached for the
		// coverage finds nothing rather than a stale or shared buffer.
		assert box.coverage.len == 0, 'gid ${gid}: the box should have no coverage'
		checked++
	}
	assert checked > 3000, 'the sweep should have covered the font, got ${checked} glyphs'
}

// The agreement has to hold at more than one size, because the box is a scale of the outline and a
// disagreement could be a rounding one that only appears at some sizes.
fn test_box_only_agrees_at_every_size() {
	f := amiri() or { return }
	last := u16(f.num_glyphs()) - 1
	for em_px in [f64(8.0), 12.0, 16.0, 33.0, 64.0, 128.0] {
		for gid in [u16(0), 1, 36, 1499, 2354, last] {
			rendered := f.face.rasterize_glyph(gid, em_px, 0, 0)
			box := f.face.box_only(gid, em_px)
			assert box.width == rendered.width, 'gid ${gid} at ${em_px}: width ${box.width} against ${rendered.width}'
			assert box.height == rendered.height, 'gid ${gid} at ${em_px}: height ${box.height} against ${rendered.height}'
			assert box.left == rendered.left, 'gid ${gid} at ${em_px}: left ${box.left} against ${rendered.left}'
			assert box.top == rendered.top, 'gid ${gid} at ${em_px}: top ${box.top} against ${rendered.top}'
		}
	}
}

// A glyph with no ink has no box, and both paths have to agree about that rather than one of them
// reporting a zero-sized box the other calls empty.
fn test_box_only_agrees_about_a_glyph_with_no_ink() {
	f := amiri() or { return }
	// A space is the ordinary empty glyph: it has an advance and no outline.
	space := f.glyph_index(` `)
	assert f.face.box_only(space, 32.0).is_empty(), 'a space has no ink'
	assert f.face.rasterize_glyph(space, 32.0, 0, 0).is_empty(), 'a space has no ink either way'
	// And .notdef is the other direction: the font does draw something for it, as a hollow box, so an
	// empty box here would mean the box query had thrown away a real outline.
	assert !f.face.box_only(0, 32.0).is_empty(), 'notdef is drawn, it is not empty'
	assert f.face.box_only(0, 32.0).coverage.len == 0, 'and the box still carries no pixels'
}
