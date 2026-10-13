module vtext

import os

// test_font_path is where a named font is on this machine: the committed corpus first, the platform's own
// font directory second, and none when neither has it.
//
// The corpus is asked first because a test that only runs because one machine happens to ship Segoe UI is
// a test about that machine. testdata/fonts is committed, carries its licences, and answers on Linux and
// macOS as well as here. The platform directory is still asked second, so a Windows checkout keeps
// measuring the fonts this suite was originally written against wherever the corpus has no equivalent —
// which for the exact glyph ids and table counts in cmap_test.v and inspect_test.v is all of them, and
// those tests say so rather than inventing numbers for a font they do not have.
//
// VTEXT_TEST_FONTS points the whole suite at another directory, for measuring a font the corpus does not
// carry without committing it.
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

// amiri is the corpus font this file reads.
//
// It is a naskh Arabic face with Latin, several cmap subtables, glyf outlines and a real mark, so it
// answers the same questions these assertions ask of Segoe UI — and it answers them identically on every
// platform, which is the whole point of reading a committed font instead of an installed one.
fn amiri_bytes() ?[]u8 {
	return corpus_font_bytes('Amiri-Regular.ttf') or {
		skip_missing('Amiri-Regular.ttf')
		return none
	}
}

fn test_parse_sfnt_table_directory() {
	data := amiri_bytes() or { return }
	sfnt := parse_sfnt(data) or { panic(err) }
	assert sfnt.has(tag_head), 'head table missing'
	assert sfnt.has(tag_hhea), 'hhea table missing'
	assert sfnt.has(tag_maxp), 'maxp table missing'
	assert sfnt.has(tag_cmap), 'cmap table missing'
	assert sfnt.has(tag_hmtx), 'hmtx table missing'
	assert !sfnt.is_cff(), 'Amiri should use glyf outlines'
	assert sfnt.has_glyf_outlines()
}

fn test_parse_sfnt_rejects_garbage() {
	if _ := parse_sfnt([]u8{}) {
		assert false, 'empty input must not parse'
	}
	if _ := parse_sfnt([]u8{len: 32}) {
		assert false, 'zeroed input must not parse'
	}
	// A truncated but plausible header must still fail cleanly.
	mut bad := []u8{len: 12}
	bad[0] = 0x00
	bad[1] = 0x01
	bad[2] = 0x00
	bad[3] = 0x00
	if _ := parse_sfnt(bad) {
		assert false, 'header with zero tables must not parse'
	}
}

fn test_face_metrics() {
	data := amiri_bytes() or { return }
	face := new_face(data) or { panic(err) }
	assert face.units_per_em > 0, 'unitsPerEm must be positive'
	assert face.num_glyphs > 100, 'numGlyphs should be a real count'
	assert face.stb_ok, 'stb_truetype failed to initialise'
	assert face.vmetrics().ascent > 0, 'ascent must be positive'
	assert face.vmetrics().descent < 0, 'descent must be negative'
	assert face.line_height(16.0) > 16.0
}

fn test_cmap_lookup() {
	data := amiri_bytes() or { return }
	face := new_face(data) or { panic(err) }
	assert face.cmaps.len > 0, 'no cmap subtables parsed'
	assert face.glyph_index(`A`) != 0, 'latin A unmapped'
	assert face.glyph_index(`a`) != 0, 'latin a unmapped'
	// U+200C ZERO WIDTH NON-JOINER and U+200D ZWJ must resolve; they are the
	// two codepoints Persian text depends on and a naive cmap drops them.
	assert face.glyph_index(rune(0x200C)) != 0, 'ZWNJ unmapped'
	assert face.glyph_index(rune(0x200D)) != 0, 'ZWJ unmapped'
	// A codepoint no font maps should give .notdef, not a crash.
	assert face.glyph_index(0x10FFFF) == 0
}

fn test_cmap_prefers_wide_subtable() {
	data := amiri_bytes() or { return }
	face := new_face(data) or { panic(err) }
	best := face.cmaps[0]
	assert best.score >= face.cmaps[1].score, 'subtables are not score-ordered'
	assert best.platform == platform_windows, 'expected a Windows subtable to win'
}

fn test_hmtx_advances_are_monotonic_sane() {
	data := amiri_bytes() or { return }
	face := new_face(data) or { panic(err) }
	space := face.glyph_index(` `)
	assert space != 0, 'space unmapped'
	i := face.glyph_index(`i`)
	assert i != 0
	w := face.glyph_index(`W`)
	assert w != 0
	// In a proportional font i must be narrower than W.
	assert f64(face.glyph_advance_units(i)) < f64(face.glyph_advance_units(w)), '"i" should be narrower than "W"'
	// Pixel advance must be a sane fraction of the em size.
	adv := face.glyph_advance(w, 32.0)
	assert adv > 8.0 && adv < 40.0, 'unexpected advance ${adv} for W at 32px'
}

fn test_rasterize_glyph() {
	data := amiri_bytes() or { return }
	face := new_face(data) or { panic(err) }
	bmp := face.rasterize_glyph(face.glyph_index(`A`), 32.0, 0, 0)
	assert !bmp.is_empty(), 'A produced no bitmap'
	assert bmp.coverage.len == bmp.width * bmp.height
	mut inked := 0
	for b in bmp.coverage {
		if b > 0 {
			inked++
		}
	}
	assert inked > 0, 'A bitmap is entirely blank'
	// Glyph 0 is .notdef and must rasterise to something.
	notdef := face.rasterize_glyph(0, 32.0, 0, 0)
	assert !notdef.is_empty(), '.notdef produced no bitmap'
}

// The Persian letters are asked of a corpus Arabic font rather than of Dubai, because the question is
// whether an Arabic font maps them, and the corpus has three that do.
fn test_persian_codepoints_map_in_an_arabic_font() {
	data := corpus_font_bytes('NotoNastaliqUrdu-Regular.ttf') or {
		skip_missing('NotoNastaliqUrdu-Regular.ttf')
		return
	}
	face := new_face(data) or { panic(err) }
	for cp in [`ب`, `س`, `ل`, `ا`, `م`, `ه`, `ی`, `ک`] {
		assert face.glyph_index(cp) != 0, 'U+${cp:04X} unmapped in the corpus Arabic font'
	}
}

fn test_bidi_codepoints_map() {
	// ZWNJ and ZWJ are the two marks Persian text genuinely needs: ZWNJ breaks a
	// joining sequence (نیم‌فاصله) and ZWJ forces one. A font that lacks them
	// cannot render Persian correctly, so these must be present.
	data := corpus_font_bytes('Amiri-Regular.ttf') or {
		skip_missing('Amiri-Regular.ttf')
		return
	}
	face := new_face(data) or { panic(err) }
	for cp in [0x200C, 0x200D] {
		assert face.glyph_index(rune(cp)) != 0, 'U+${cp:04X} unmapped'
	}
	// The directional marks are formatting controls. Most fonts do not put them
	// in cmap, and a missing glyph must resolve to .notdef rather than crash.
	for cp in [0x200E, 0x200F, 0x061C] {
		_ := face.glyph_index(rune(cp))
	}
}
