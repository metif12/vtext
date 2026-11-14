module vtext

import os
import vtext.layout
import vtext.shape
import vtext.subset

// test_font_path is where a named font is on this machine: the committed corpus first, the platform's own
// font directory second, and none when neither has it. This copy lives here because
// `v test <single_file>` compiles that file and not its siblings, so a helper in
// another test file is one this file cannot see; see the Phase 4 entry on the copies.
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

fn corpus_font_bytes(name string) ?[]u8 {
	p := corpus_font_path(name) or { return none }
	return os.read_bytes(p) or { panic('${p} is not readable: ${err}') }
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

// skip_missing prints why a test cannot run. A skip that prints nothing is a failure pretending to be a
// pass, so every one of them names the font it wanted and where it looked, and tools/run_tests.v counts
// them file by file.
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

// amiri is the corpus font the structural assertions read.
fn amiri_bytes() ?[]u8 {
	return corpus_font_bytes('Amiri-Regular.ttf') or {
		skip_missing('Amiri-Regular.ttf')
		return none
	}
}

// The library behind tools/subset.v: the same checks the tool's own verification
// performs, pinned so a closure regression fails here rather than in a picture.

fn nastaliq_bytes() ?[]u8 {
	return corpus_font_bytes('NotoNastaliqUrdu-Regular.ttf') or {
		skip_missing('NotoNastaliqUrdu-Regular.ttf')
		return none
	}
}

// The seed and .notdef survive, the bytes load, the table set is unchanged, and the
// same seed builds the same bytes twice.
fn test_subset_keeps_seed_and_notdef() {
	data := amiri_bytes() or { return }
	f := shape.load_font_bytes(data) or { panic(err) }
	mut seed := []u16{}
	seed << f.glyph_index(`A`)
	seed << f.glyph_index(rune(0x0628))
	sub := subset.subset_font(f, seed) or { panic(err) }
	assert sub.keep[0], '.notdef always kept'
	for gid in seed {
		assert sub.keep[gid], 'seed gid ${gid} kept'
	}
	reread := shape.load_font_bytes(sub.bytes) or { panic('subset does not load: ${err}') }
	assert reread.tables().len == f.tables().len, 'same table set'
	again := subset.subset_font(f, seed) or { panic(err) }
	assert again.bytes == sub.bytes, 'subset is deterministic'
}

// The Segoe incident, pinned: the `i` in "difficulty" is gid 3388, a composite of
// `glyph03315` plus `dotaccent`, reached only through a substitution rule. A closure
// that runs glyf before GSUB — or no GSUB pass at all — drops dotaccent while keeping
// 3388, and the subset draws a dotless i. Windows only: Segoe UI is a platform font,
// so this skips aloud where it is not installed.
fn test_subset_keeps_composite_reached_through_substitution() {
	data := corpus_font_bytes('segoeui.ttf') or {
		skip_missing('segoeui.ttf')
		return
	}
	original := shape.load_font_bytes(data) or { panic(err) }
	text := 'difficulty'
	// Seed from the cmap, not from the shaped run: the `i` maps to its base glyph
	// and only the closure reaches the composite 3388 and its dotaccent through the
	// substitution rule. A closure that runs glyf once before GSUB — or no GSUB pass
	// at all — keeps 3388 without its dot, and the subset draws a dotless i.
	mut seed := []u16{}
	for cp in text.runes() {
		gid := original.glyph_index(cp)
		if gid !in seed {
			seed << gid
		}
	}
	sub := subset.subset_font(original, seed) or { panic(err) }
	reread := shape.load_font_bytes(sub.bytes) or { panic('subset does not load: ${err}') }
	// Measured on Segoe UI for this word: 8 from the cmap seed, 1 from a composite
	// outline, 11 from substitution rules, kept 21 with .notdef. A closure with no
	// GSUB pass reports 0 from substitution rules and keeps 10.
	assert sub.closure.from_ligatures > 0, 'substitution rules contributed'
	kept := subset.kept_glyph_ids(sub.keep)
	assert kept.len > seed.len + 1, 'the closure added beyond seed and .notdef'
	ctx := shape.new_context()
	fs := shape.new_font_set()
	fs.add(original)
	before := layout.layout_paragraph(ctx, text.runes(), .auto, fs, 16.0)
	fs2 := shape.new_font_set()
	fs2.add(reread)
	after := layout.layout_paragraph(ctx, text.runes(), .auto, fs2, 16.0)
	assert after.glyphs.len == before.glyphs.len, 'same glyph count'
	for i, a in before.glyphs {
		b := after.glyphs[i]
		assert b.gid == a.gid, 'glyph ${i} same id'
	}
	for g in before.glyphs {
		a := original.rasterize(g.gid, 16.0, 0, 0)
		b := reread.rasterize(g.gid, 16.0, 0, 0)
		assert a.coverage == b.coverage, 'gid ${g.gid} same ink'
	}
}

// The subset shapes and rasterizes like the original on a font whose shaping runs
// through GSUB: nine characters become eighteen glyphs, so a closure that drops a
// needed outline changes the ink on a glyph the run names.
fn test_subset_shapes_and_rasterizes_like_original() {
	data := nastaliq_bytes() or { return }
	original := shape.load_font_bytes(data) or { panic(err) }
	text := 'سلام دنیا'
	ctx := shape.new_context()
	fs := shape.new_font_set()
	fs.add(original)
	before := layout.layout_paragraph(ctx, text.runes(), .auto, fs, 32.0)
	mut seed := []u16{}
	for g in before.glyphs {
		if g.gid !in seed {
			seed << g.gid
		}
	}
	sub := subset.subset_font(original, seed) or { panic(err) }
	reread := shape.load_font_bytes(sub.bytes) or { panic('subset does not load: ${err}') }
	fs2 := shape.new_font_set()
	fs2.add(reread)
	after := layout.layout_paragraph(ctx, text.runes(), .auto, fs2, 32.0)
	assert after.glyphs.len == before.glyphs.len, 'same glyph count'
	for i, a in before.glyphs {
		b := after.glyphs[i]
		assert b.gid == a.gid && b.x == a.x && b.y == a.y, 'glyph ${i} placed the same'
	}
	for gid in seed {
		a := original.rasterize(gid, 32.0, 0, 0)
		b := reread.rasterize(gid, 32.0, 0, 0)
		assert a.coverage == b.coverage, 'gid ${gid} same ink'
	}
}

// codepoint_for survives subsetting, because ids are preserved and cmap is copied
// whole: every kept glyph names the same codepoint before and after. This is the pin
// that fails if ids are ever renumbered, which is the design the subset table above
// refused — and it fails if the cmap copy is ever dropped, which is the revert control
// below.
fn test_subset_codepoint_for_agrees() {
	data := amiri_bytes() or { return }
	original := shape.load_font_bytes(data) or { panic(err) }
	mut seed := []u16{}
	seed << original.glyph_index(`A`)
	seed << original.glyph_index(rune(0x0628))
	sub := subset.subset_font(original, seed) or { panic(err) }
	reread := shape.load_font_bytes(sub.bytes) or { panic('subset does not load: ${err}') }
	agid := original.glyph_index(`A`)
	assert (reread.codepoint_for(agid) or { `?` }) == `A`, 'A names A after subsetting'
	for gid in subset.kept_glyph_ids(sub.keep) {
		a := original.codepoint_for(gid) or { rune(0x110000) }
		b := reread.codepoint_for(gid) or { rune(0x110000) }
		assert a == b, 'gid ${gid} names the same codepoint'
	}
}
