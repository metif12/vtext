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

// font_from loads a font from the Windows font directory, which is where the tests get real outlines from.
//
// Copied per test file rather than shared, because the runner builds one file at a time and a helper in
// one test file is not visible from another.
fn font_from(name string) &Font {
	path := os.join_path('C:\\Windows\\Fonts', name)
	return load_font_file(path) or { panic(err) }
}

fn test_box_only_reports_the_same_box_as_rasterizing() {
	// Segoe UI because it has the widest repertoire of the fonts here: Latin, Arabic, symbols and a
	// colour-format glyph or two, so the sweep covers marks and ligatures as well as letters.
	f := font_from('segoeui.ttf')
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
	f := font_from('tahoma.ttf')
	for em_px in [f64(8.0), 12.0, 16.0, 33.0, 64.0, 128.0] {
		for gid in [u16(0), 1, 36, 1499, 2354, u16(f.num_glyphs()) - 1] {
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
	f := font_from('segoeui.ttf')
	// A space is the ordinary empty glyph: it has an advance and no outline.
	space := f.glyph_index(` `)
	assert f.face.box_only(space, 32.0).is_empty(), 'a space has no ink'
	assert f.face.rasterize_glyph(space, 32.0, 0, 0).is_empty(), 'a space has no ink either way'
	// And .notdef is the other direction: the font does draw something for it, as a hollow box, so an
	// empty box here would mean the box query had thrown away a real outline.
	assert !f.face.box_only(0, 32.0).is_empty(), 'notdef is drawn, it is not empty'
	assert f.face.box_only(0, 32.0).coverage.len == 0, 'and the box still carries no pixels'
}
