module vtext

import os

const test_fonts_dir = 'C:\\Windows\\Fonts'

fn font_path_for(name string) !string {
	p := os.join_path(test_fonts_dir, name)
	if !os.exists(p) {
		return error('${p} not found')
	}
	return p
}

fn test_parse_sfnt_table_directory() {
	data := os.read_bytes(font_path_for('segoeui.ttf')!) or { panic(err) }
	sfnt := parse_sfnt(data) or { panic(err) }
	assert sfnt.has(tag_head), 'head table missing'
	assert sfnt.has(tag_hhea), 'hhea table missing'
	assert sfnt.has(tag_maxp), 'maxp table missing'
	assert sfnt.has(tag_cmap), 'cmap table missing'
	assert sfnt.has(tag_hmtx), 'hmtx table missing'
	assert !sfnt.is_cff(), 'segoeui.ttf should use glyf outlines'
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
	data := os.read_bytes(font_path_for('segoeui.ttf')!) or { panic(err) }
	face := new_face(data) or { panic(err) }
	assert face.units_per_em > 0, 'unitsPerEm must be positive'
	assert face.num_glyphs > 100, 'numGlyphs should be a real count'
	assert face.stb_ok, 'stb_truetype failed to initialise'
	assert face.vmetrics().ascent > 0, 'ascent must be positive'
	assert face.vmetrics().descent < 0, 'descent must be negative'
	assert face.line_height(16.0) > 16.0
}

fn test_cmap_lookup() {
	data := os.read_bytes(font_path_for('segoeui.ttf')!) or { panic(err) }
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
	data := os.read_bytes(font_path_for('segoeui.ttf')!) or { panic(err) }
	face := new_face(data) or { panic(err) }
	best := face.cmaps[0]
	assert best.score >= face.cmaps[1].score, 'subtables are not score-ordered'
	assert best.platform == platform_windows, 'expected a Windows subtable to win'
}

fn test_hmtx_advances_are_monotonic_sane() {
	data := os.read_bytes(font_path_for('segoeui.ttf')!) or { panic(err) }
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
	data := os.read_bytes(font_path_for('segoeui.ttf')!) or { panic(err) }
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

fn test_persian_codepoints_map_in_an_arabic_font() {
	// Dubai is the Windows Arabic-script UI font and covers Persian letters.
	data := os.read_bytes(os.join_path(test_fonts_dir, 'DUBAI-REGULAR.TTF')) or { panic(err) }
	face := new_face(data) or { panic(err) }
	for cp in [`ب`, `س`, `ل`, `ا`, `م`, `ه`, `ی`, `ک`] {
		assert face.glyph_index(cp) != 0, 'U+${cp:04X} unmapped in Dubai'
	}
}

fn test_bidi_codepoints_map() {
	// ZWNJ and ZWJ are the two marks Persian text genuinely needs: ZWNJ breaks a
	// joining sequence (نیم‌فاصله) and ZWJ forces one. A font that lacks them
	// cannot render Persian correctly, so these must be present.
	data := os.read_bytes(os.join_path(test_fonts_dir, 'DUBAI-REGULAR.TTF')) or {
		panic(err)
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
