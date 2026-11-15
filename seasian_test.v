module vtext

import os
import vtext.shape
import vtext.layout

// Tests for the third corpus wave: Southeast Asian faces (Thai, Lao, Khmer,
// Myanmar). Every gid, advance and cluster below was read off HarfBuzz
// (uharfbuzz) and fontTools before it was written here; agreement with a
// second reader is the evidence. Input clusters double as pins: a cluster is
// an input position, so "the glyph reporting cluster 3" names no engine
// output of its own.
//
// The four faces ship in testdata/fonts with their OFL texts, so they load on
// every platform with no skips: no host font, no platform directory.
//
// Where the engine diverges from HarfBuzz, the assert pins the current
// behaviour and the comment names the gap for the engine slice that owns it:
//   - spacing marks with combining class zero (Thai MAI HAN-AKAT and SARA II,
//     Lao SARA II, Khmer SRA U and SRA II) draw no glyph at all. The joining
//     pass only emits glyphs for transparent characters with a nonzero
//     combining class, so a ccc=0 mark is swallowed even though the font
//     classes it as a GDEF mark with zero advance.
//   - no Southeast Asian GSUB runs: Khmer COENG+TA never fuses to the
//     subscript ligature, and Myanmar never forms the kinzi or the stacks, so
//     the engine draws the cmap glyphs where HarfBuzz draws one fused glyph
//     and merges the clusters.
//
// Tibetan is explicitly out of scope for this wave: stacking composition needs
// a stacking machine the engine does not have yet.

fn seasian_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('VTEXT_TEST_FONTS'), 'testdata/fonts'] {
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

fn seasian_font(name string) ?&shape.Font {
	p := seasian_font_path(name) or { return none }
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

// seasian_at returns the glyph that came from the input character at that
// index, or none when the character drew nothing.
fn seasian_at(glyphs []shape.Glyph, cluster int) ?shape.Glyph {
	for g in glyphs {
		if g.cluster == cluster {
			return g
		}
	}
	return none
}

fn test_seasian_fonts_load() {
	for name in ['NotoSansThai-Variable.ttf', 'NotoSansLao-Variable.ttf', 'NotoSansKhmer-Variable.ttf',
		'NotoSansMyanmar-Variable.ttf'] {
		f := seasian_font(name) or { panic('${name} is not in testdata/fonts') }
		assert f.num_glyphs() > 100, '${name} has almost no glyphs'
		assert f.units_per_em() > 0, '${name} has no units per em'
	}
}

fn test_seasian_fonts_cover_what_they_claim() {
	// fontTools cmap: each face covers Latin plus its own script, and none of
	// the other three Southeast Asian scripts.
	th := seasian_font('NotoSansThai-Variable.ttf') or { return }
	assert th.has_glyph(`A`), 'Thai covers Latin'
	assert th.has_glyph(rune(0x0E01)), 'Thai covers THAI CHARACTER KO KAI'
	assert th.has_glyph(rune(0x0E35)), 'Thai covers THAI CHARACTER SARA II'
	assert !th.has_glyph(rune(0x0E81)), 'Thai covers no Lao'
	assert !th.has_glyph(rune(0x1780)), 'Thai covers no Khmer'
	assert !th.has_glyph(rune(0x1000)), 'Thai covers no Myanmar'
	la := seasian_font('NotoSansLao-Variable.ttf') or { return }
	assert la.has_glyph(`A`), 'Lao covers Latin'
	assert la.has_glyph(rune(0x0E81)), 'Lao covers LAO LETTER KO'
	assert la.has_glyph(rune(0x0EB5)), 'Lao covers LAO VOWEL SIGN II'
	assert !la.has_glyph(rune(0x0E01)), 'Lao covers no Thai'
	assert !la.has_glyph(rune(0x1780)), 'Lao covers no Khmer'
	assert !la.has_glyph(rune(0x1000)), 'Lao covers no Myanmar'
	kh := seasian_font('NotoSansKhmer-Variable.ttf') or { return }
	assert kh.has_glyph(`A`), 'Khmer covers Latin'
	assert kh.has_glyph(rune(0x1780)), 'Khmer covers KHMER LETTER KA'
	assert kh.has_glyph(rune(0x17B8)), 'Khmer covers KHMER VOWEL SIGN II'
	assert !kh.has_glyph(rune(0x0E01)), 'Khmer covers no Thai'
	assert !kh.has_glyph(rune(0x0E81)), 'Khmer covers no Lao'
	assert !kh.has_glyph(rune(0x1000)), 'Khmer covers no Myanmar'
	my := seasian_font('NotoSansMyanmar-Variable.ttf') or { return }
	assert my.has_glyph(`A`), 'Myanmar covers Latin'
	assert my.has_glyph(rune(0x1000)), 'Myanmar covers MYANMAR LETTER KA'
	assert my.has_glyph(rune(0x102C)), 'Myanmar covers MYANMAR VOWEL SIGN AA'
	assert !my.has_glyph(rune(0x0E01)), 'Myanmar covers no Thai'
	assert !my.has_glyph(rune(0x0E81)), 'Myanmar covers no Lao'
	assert !my.has_glyph(rune(0x1780)), 'Myanmar covers no Khmer'
}

fn seasian_line(f &shape.Font, text string) layout.Line {
	return seasian_line_in(f, text, '', '')
}

// seasian_line_in lays one line out under an explicit script/language override.
// The default is auto-detect, which is what the smoke tests use; the override
// is there for the same reason as in extra_fonts_test: to name the table the
// HarfBuzz pins were measured under when detection is not what is tested.
fn seasian_line_in(f &shape.Font, text string, script string, lang string) layout.Line {
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	mut opts := layout.LayoutOptions{}
	opts.script = script
	opts.language = lang
	return layout.layout_paragraph_with(ctx, text.runes(), .auto, fs, 32.0, &opts)
}

fn test_seasian_shape_thai() {
	// HarfBuzz shapes six glyphs in order with no substitution (cmap gids
	// equal shaped gids) and zero advance on the two above-marks. The engine
	// draws the four bases with the same gids, clusters and advances, and
	// drops the two GDEF marks (0x2d and 0x5e, hmtx advance 0): ccc=0 marks
	// draw nothing, which the engine slice owns.
	th := seasian_font('NotoSansThai-Variable.ttf') or { return }
	line := seasian_line(th, 'สวัสดี')
	assert line.glyphs.len == 4, 'thai hello draws four bases, got ${line.glyphs.len}'
	assert line.width > 0, 'a Thai word has positive width'
	want := [u16(0x6e), 0x86, 0x6e, 0x0c]
	clusters := [0, 1, 3, 4]
	for i in 0 .. clusters.len {
		g := seasian_at(line.glyphs, clusters[i]) or {
			panic('thai input ${clusters[i]} drew nothing')
		}
		assert g.gid == want[i], 'thai cluster ${clusters[i]} is ${want[i]:x}, got ${g.gid:x}'
		assert g.advance > 0, 'a Thai base moves the pen'
		assert g.gid != 0, 'no .notdef in a covered Thai line'
	}
	for dropped in [2, 5] {
		assert seasian_at(line.glyphs, dropped) == none, 'thai mark at input ${dropped} draws nothing today'
	}
}

fn test_seasian_shape_lao() {
	// HarfBuzz shapes seven glyphs in order with no substitution and zero
	// advance on the final SARA II. The engine draws the first six with the
	// same gids, clusters and advances, and drops the GDEF mark (0x45, hmtx
	// advance 0): ccc=0 marks draw nothing, which the engine slice owns.
	la := seasian_font('NotoSansLao-Variable.ttf') or { return }
	line := seasian_line(la, 'ສະບາຍດີ')
	assert line.glyphs.len == 6, 'lao hello draws six letters, got ${line.glyphs.len}'
	assert line.width > 0, 'a Lao word has positive width'
	want := [u16(0x2d), 0x3b, 0x1f, 0x3c, 0x18, 0x19]
	for i in 0 .. want.len {
		g := seasian_at(line.glyphs, i) or { panic('lao input ${i} drew nothing') }
		assert g.gid == want[i], 'lao cluster ${i} is ${want[i]:x}, got ${g.gid:x}'
		assert g.advance > 0, 'a Lao letter moves the pen'
		assert g.gid != 0, 'no .notdef in a covered Lao line'
	}
	assert seasian_at(line.glyphs, 6) == none, 'lao SARA II draws nothing today'
}

fn test_seasian_shape_khmer() {
	// HarfBuzz shapes five glyphs: the two SA bases plus SRA U, then the
	// COENG+TA subscript fusion 0xcc and SRA II, all three merged onto cluster
	// 2 with zero advance. The engine applies no coeng fusion: it draws the
	// cmap glyphs SA, SA, COENG (0x9f, a GDEF mark with hmtx advance 0) and TA
	// (0x41), and drops the two ccc=0 vowel signs. Both gaps belong to the
	// engine slice.
	kh := seasian_font('NotoSansKhmer-Variable.ttf') or { return }
	line := seasian_line(kh, 'សួស្តី')
	assert line.glyphs.len == 4, 'khmer hello draws four glyphs, got ${line.glyphs.len}'
	assert line.width > 0, 'a Khmer word has positive width'
	sa0 := seasian_at(line.glyphs, 0) or { panic('khmer SA drew nothing') }
	assert sa0.gid == 0x53, 'khmer cluster 0 is SA 0x53, got ${sa0.gid:x}'
	assert sa0.advance > 0, 'the first SA moves the pen'
	sa2 := seasian_at(line.glyphs, 2) or { panic('khmer second SA drew nothing') }
	assert sa2.gid == 0x53, 'khmer cluster 2 is SA 0x53, got ${sa2.gid:x}'
	assert sa2.advance > 0, 'the second SA moves the pen'
	coeng := seasian_at(line.glyphs, 3) or { panic('khmer COENG drew nothing') }
	assert coeng.gid == 0x9f, 'khmer COENG is the cmap glyph 0x9f, got ${coeng.gid:x}'
	assert coeng.is_mark, 'COENG is a mark, not a letter'
	assert coeng.advance == 0, 'the coeng subscript adds no advance'
	ta := seasian_at(line.glyphs, 4) or { panic('khmer TA drew nothing') }
	assert ta.gid == 0x41, 'khmer TA is the cmap glyph 0x41, got ${ta.gid:x}'
	assert ta.advance > 0, 'the unfused TA moves the pen'
	for dropped in [1, 5] {
		assert seasian_at(line.glyphs, dropped) == none, 'khmer vowel at input ${dropped} draws nothing today'
	}
}

fn test_seasian_shape_myanmar() {
	// HarfBuzz shapes five glyphs: MA, the NGA kinzi (0x06 with the asat mark
	// 0xbd), and the VIRAMA+GA stack on LA (0x20) with SRA AA (0x170), the
	// followers merged onto clusters 1 and 5. The engine applies no Myanmar
	// GSUB: it draws all seven cmap glyphs under their own clusters. Every
	// gid below is the fontTools cmap answer and every advance the hmtx one;
	// the fusion and the cluster merges belong to the engine slice.
	my := seasian_font('NotoSansMyanmar-Variable.ttf') or { return }
	line := seasian_line(my, 'မင်္ဂလာ')
	assert line.glyphs.len == 7, 'myanmar mingala draws seven cmap glyphs, got ${line.glyphs.len}'
	assert line.width > 0, 'a Myanmar word has positive width'
	ma := seasian_at(line.glyphs, 0) or { panic('myanmar MA drew nothing') }
	assert ma.gid == 0x1d, 'myanmar cluster 0 is MA 0x1d, got ${ma.gid:x}'
	assert ma.advance > 0, 'MA moves the pen'
	nga := seasian_at(line.glyphs, 1) or { panic('myanmar NGA drew nothing') }
	assert nga.gid == 0x08, 'myanmar NGA is the cmap glyph 0x08, got ${nga.gid:x}'
	assert nga.advance > 0, 'the unfolded NGA moves the pen'
	asat := seasian_at(line.glyphs, 2) or { panic('myanmar asat drew nothing') }
	assert asat.gid == 0x17d, 'myanmar asat is the cmap glyph 0x17d, got ${asat.gid:x}'
	assert asat.is_mark, 'asat is a mark, not a letter'
	assert asat.advance == 0, 'asat shares its base advance'
	virama := seasian_at(line.glyphs, 3) or { panic('myanmar virama drew nothing') }
	assert virama.is_mark, 'virama is a mark, not a letter'
	assert virama.advance == 0, 'virama shares its base advance'
	ga := seasian_at(line.glyphs, 4) or { panic('myanmar GA drew nothing') }
	assert ga.gid == 0x06, 'myanmar GA is the cmap glyph 0x06, got ${ga.gid:x}'
	assert ga.advance > 0, 'the unstacked GA moves the pen'
	la := seasian_at(line.glyphs, 5) or { panic('myanmar LA drew nothing') }
	assert la.gid == 0x20, 'myanmar cluster 5 is LA 0x20, got ${la.gid:x}'
	assert la.advance > 0, 'LA moves the pen'
	aa := seasian_at(line.glyphs, 6) or { panic('myanmar AA drew nothing') }
	assert aa.gid == 0x170, 'myanmar AA is the cmap glyph 0x170, got ${aa.gid:x}'
	assert aa.advance > 0, 'AA moves the pen'
}

fn test_seasian_draw_bases() {
	// One rasterised base consonant per script: a face that shapes but never
	// inks is a face the test cannot see.
	th := seasian_font('NotoSansThai-Variable.ttf') or { return }
	ko_kai := th.rasterize(th.glyph_index(rune(0x0E01)), 32.0, 0, 0)
	assert !ko_kai.is_empty(), 'KO KAI rasterises'
	la := seasian_font('NotoSansLao-Variable.ttf') or { return }
	ko := la.rasterize(la.glyph_index(rune(0x0E81)), 32.0, 0, 0)
	assert !ko.is_empty(), 'LAO KO rasterises'
	kh := seasian_font('NotoSansKhmer-Variable.ttf') or { return }
	ka := kh.rasterize(kh.glyph_index(rune(0x1780)), 32.0, 0, 0)
	assert !ka.is_empty(), 'KHMER KA rasterises'
	my := seasian_font('NotoSansMyanmar-Variable.ttf') or { return }
	mka := my.rasterize(my.glyph_index(rune(0x1000)), 32.0, 0, 0)
	assert !mka.is_empty(), 'MYANMAR KA rasterises'
}

fn test_seasian_pins_are_live() {
	// Break-fix control: the first Thai pin is exact, so the neighbouring gid
	// must not match. If shaping ever drifts, the smoke pins above fail; if
	// this control fails, the pins stopped discriminating.
	th := seasian_font('NotoSansThai-Variable.ttf') or { return }
	line := seasian_line(th, 'สวัสดี')
	so := seasian_at(line.glyphs, 0) or { panic('the control needs a shaped line') }
	assert so.gid == 0x6e, 'the SO SUA pin still holds'
	assert so.gid != 0x6f, 'off-by-one gid must not match: the pin is exact'
}
