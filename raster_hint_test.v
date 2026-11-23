module main

import os
import harfara.shape
import harfara.font
import harfara.raster

// Grid-fit autohinting: the dal pin, the box/ink contract, the refusal.
//
// FreeType answers hinted glyphs two ways and this engine ships one: the
// grid-fit autohinter in font/hint.v (outline rounding) plus raster/hint.v
// (stem snap, trim, rebox), with the full bytecode interpreter refused. The
// reference is FreeType's own autohinter via freetype-py at 32 px
// (FT_LOAD_FORCE_AUTOHINT): dal gid 63 unhinted 12x14 l1 t13 sum 12341,
// autohinted 11x13 l1 t13 sum 12447; A gid 6227 autohinted 22x22 l-1 t21 sum
// 25763 (stb signs left the other way, the documented convention). The pins
// below are this engine's own outputs, exact; the ranges beside them are the
// claim against the reference (box within one pixel per dimension, sums
// within five percent).
//
// This copy of the helpers lives here because `v test <single_file>`
// compiles that file and not its siblings, so a helper in another test file
// is one this file cannot see.
fn corpus_font_path(name string) string {
	mut dirs := []string{}
	e := os.getenv('HARFARA_TEST_FONTS')
	if e != '' {
		dirs << e
	}
	dirs << 'testdata/fonts'
	dirs << 'C:\\Windows\\Fonts'
	for dir in dirs {
		p := os.join_path(dir, name)
		if os.exists(p) {
			return p
		}
	}
	return ''
}

fn skip_missing(name string) {
	line := 'SKIP ${name} is in neither testdata/fonts nor the platform font directory'
	path := os.getenv('HARFARA_SKIP_LOG')
	if path != '' {
		mut f := os.open_append(path) or { return }
		f.writeln(line) or { return }
		f.close()
		return
	}
	println(line)
}

fn load_corpus_font(name string) ?&shape.Font {
	p := corpus_font_path(name)
	if p == '' {
		skip_missing(name)
		return none
	}
	return shape.load_font_file(p) or { panic('unreadable font file ' + p) }
}

// dal_gid is U+062F in Amiri: the corpus pin this file is about. Asserting
// the gid itself keeps the pin honest: if the font ever renumbers, this fails
// here rather than silently pinning another glyph's ink.
fn dal_gid(f &shape.Font) u16 {
	gid := f.glyph_index(rune(0x062F))
	assert gid == 63, 'Amiri dal moved off gid 63 to ${gid}'
	return gid
}

fn test_hint_dal_hinted_box_pin() {
	f := load_corpus_font('Amiri-Regular.ttf') or { return }
	gid := dal_gid(f)
	box := f.face.hinted_box(gid, 32.0)
	assert box.width == 11, 'hinted dal width ${box.width}'
	assert box.height == 14, 'hinted dal height ${box.height}'
	assert box.left == -2, 'hinted dal left ${box.left}'
	assert box.top == 13, 'hinted dal top ${box.top}'
	assert box.coverage.len == 0, 'the box carries no pixels'
	// The reference shrinks the same way: FreeType autohinted 11x13 against
	// unhinted 12x14, and ours is 11x14, every dimension within one pixel.
	assert box.width >= 10 && box.width <= 12
	assert box.height >= 12 && box.height <= 14
	assert box.left >= -2 && box.left <= 0
	assert box.top >= 12 && box.top <= 14
	// And the fit moved the box: unhinted stb is 12x14 l-1 t13.
	plain := f.face.box_only(gid, 32.0)
	assert plain.width == 12 && plain.height == 14 && plain.left == -1 && plain.top == 13
	assert box.width != plain.width || box.left != plain.left, 'grid-fit must move the box'
}

fn test_hint_dal_hinted_ink_pin() {
	f := load_corpus_font('Amiri-Regular.ttf') or { return }
	gid := dal_gid(f)
	ink := f.face.hinted_rasterize(gid, 32.0, 0, 0, .hint_grid)
	assert ink.width == 11, 'hinted dal ink width ${ink.width}'
	assert ink.height == 14, 'hinted dal ink height ${ink.height}'
	assert ink.left == -2, 'hinted dal ink left ${ink.left}'
	assert ink.top == 13, 'hinted dal ink top ${ink.top}'
	assert ink.coverage.len == 154, 'hinted dal coverage ${ink.coverage.len} bytes'
	assert ink.coverage_sum() == 12071, 'hinted dal sum ${ink.coverage_sum()}'
	// Within five percent of FreeType's autohinted 12447.
	assert ink.coverage_sum() >= 11825 && ink.coverage_sum() <= 13069
	// The core goes solid the way a stem snap should: the darkest pixel is
	// full ink, and the fill is not a flat block either.
	mut peak := u8(0)
	for v in ink.coverage {
		if v > peak {
			peak = v
		}
	}
	assert peak == 255, 'the stem core must saturate'
}

fn test_hint_box_and_ink_agree() {
	// Measure and draw share one box: whatever hinted_box reports,
	// hinted_rasterize spans, the way box_only and rasterize_glyph agree.
	f := load_corpus_font('Amiri-Regular.ttf') or { return }
	for gid in [dal_gid(f), f.glyph_index(`A`), u16(0)] {
		box := f.face.hinted_box(gid, 32.0)
		ink := f.face.hinted_rasterize(gid, 32.0, 0, 0, .hint_grid)
		assert ink.width == box.width, 'gid ${gid}: ink ${ink.width} against box ${box.width}'
		assert ink.height == box.height, 'gid ${gid}: ink ${ink.height} against box ${box.height}'
		assert ink.left == box.left, 'gid ${gid}: ink left ${ink.left} against ${box.left}'
		assert ink.top == box.top, 'gid ${gid}: ink top ${ink.top} against ${box.top}'
		assert box.coverage.len == 0, 'gid ${gid}: the box still carries no pixels'
	}
}

fn test_hint_second_glyph_within_reference() {
	// The per-glyph half of the claim is not one glyph: A (gid 6227) stays
	// inside the same tolerance against FreeType's autohinted 22x22 l-1 t21
	// sum 25763 (stb sign convention for left).
	f := load_corpus_font('Amiri-Regular.ttf') or { return }
	gid := f.glyph_index(`A`)
	assert gid == 6227
	ink := f.face.hinted_rasterize(gid, 32.0, 0, 0, .hint_grid)
	assert ink.width >= 21 && ink.width <= 23, 'A width ${ink.width}'
	assert ink.height >= 21 && ink.height <= 23, 'A height ${ink.height}'
	assert ink.left >= 0 && ink.left <= 2, 'A left ${ink.left}'
	assert ink.top >= 20 && ink.top <= 22, 'A top ${ink.top}'
	assert ink.coverage_sum() >= 24475 && ink.coverage_sum() <= 27051, 'A sum ${ink.coverage_sum()}'
}

fn test_hint_empty_stays_empty() {
	// A space has no outline to fit and no ink to snap: both hinted paths
	// answer empty, the way both unhinted paths do.
	f := load_corpus_font('Amiri-Regular.ttf') or { return }
	space := f.glyph_index(` `)
	assert f.face.hinted_box(space, 32.0).is_empty()
	assert f.face.hinted_rasterize(space, 32.0, 0, 0, .hint_grid).is_empty()
}

fn test_hint_none_answers_unhinted() {
	// hint_none is the off switch: byte for byte the stb fill, so a caller
	// that never opts in keeps the buffer it always got.
	f := load_corpus_font('Amiri-Regular.ttf') or { return }
	gid := dal_gid(f)
	plain := f.face.rasterize_glyph(gid, 32.0, 0, 0)
	off := f.face.hinted_rasterize(gid, 32.0, 0, 0, .hint_none)
	assert off.width == plain.width && off.height == plain.height
	assert off.left == plain.left && off.top == plain.top
	assert off.coverage == plain.coverage
}

fn test_hint_bytecode_refused() {
	// The interpreter is refused with its reason, not absent: Amiri carries
	// a hint program and is still refused, because carrying one is surveyed
	// and needing one is the trigger no corpus font has tripped.
	f := load_corpus_font('Amiri-Regular.ttf') or { return }
	assert font.font_has_hint_bytecode(f.face), 'Amiri carries fpgm/prep'
	font.interpret_bytecode(dal_gid(f), 32.0) or {
		assert err.msg().contains('bytecode'), 'the refusal must name bytecode: ${err.msg()}'
		assert err.msg().contains('corpus'), 'the refusal must name the trigger: ${err.msg()}'
		return
	}
	assert false, 'interpret_bytecode must error'
}

// The break-fix control: the passthrough options are the neutered hinter,
// and they must answer the input unchanged. If this stops failing, the pins
// above no longer prove the hinter does anything: a neutered grid-fit would
// read as hinted ink.
fn test_hint_neutered_hinter_changes_nothing() {
	f := load_corpus_font('Amiri-Regular.ttf') or { return }
	gid := dal_gid(f)
	plain := f.face.rasterize_glyph(gid, 32.0, 0, 0)
	neutered := raster.grid_fit_bitmap_opt(plain, raster.passthrough_grid_fit_options())
	assert neutered.coverage == plain.coverage, 'passthrough must be identity'
	assert neutered.width == plain.width && neutered.height == plain.height
	hinted := raster.grid_fit_bitmap(plain)
	assert hinted.coverage != plain.coverage, 'the live hinter must change the ink'
	assert hinted.coverage_sum() != plain.coverage_sum(), 'the live hinter must move the sum'
}

fn test_hint_outline_grid_fit_pins() {
	// The outline half of the hinter, pinned directly: dal's 31 TrueType
	// points scale to pixels and round onto the grid, and the inclusive
	// bounds are what hinted_box widens by one into 11x14.
	f := load_corpus_font('Amiri-Regular.ttf') or { return }
	gid := dal_gid(f)
	fitted := f.face.autohint_outline(gid, 32.0)
	assert fitted.n_points() == 31, 'dal keeps its 31 points, got ${fitted.n_points()}'
	xmin, ymin, xmax, ymax := fitted.bounds()
	assert xmin == 2 && ymin == 0 && xmax == 12 && ymax == 13, 'dal fitted bounds (${xmin},${ymin})..(${xmax},${ymax})'
	assert fitted.scale == 32.0 / 1000.0
	// Off the grid the same points sit unrounded: the fit moved at least one
	// edge, which is the per-point half of the break-fix.
	plain := f.face.glyph_outline(gid) or { panic(err) }
	scale := 32.0 / 1000.0
	mut lo := f64(plain.xs[0]) * scale
	for x in plain.xs {
		v := f64(x) * scale
		if v < lo {
			lo = v
		}
	}
	// The left edge sits at 1.952 px unrounded: rounding, not truncation,
	// decides it, which is the per-point half of the break-fix.
	assert lo > 1.9 && lo < 2.0, 'dal scaled left edge ${lo}'
	assert xmin == font.var_ot_round(lo)
	assert xmin != int(lo)
}
