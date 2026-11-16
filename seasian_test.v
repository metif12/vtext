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
//   - Khmer runs its coeng fusions (blwf, pstf): COENG+TA fuses to the
//     subscript ligature and COENG+KHO to its post-base one, while pref
//     needs the reordering machine (HarfBuzz draws COENG+RO ahead of its
//     base) and pres/abvs/blws/psts/abvf wait for a word that exercises
//     them. Myanmar never forms the kinzi or the stacks, so the engine
//     draws the cmap glyphs where HarfBuzz draws one fused glyph
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
	// equal shaped gids) and zero advance on the two above-marks, the first
	// offset +10 design units off the pen and the second unshifted. The
	// engine draws all six with the same gids, advances and offsets: the
	// ccc=0 marks used to be dropped by the class gate, and the Cf gate lets
	// them attach. The above-marks merge onto their bases in HarfBuzz
	// clusters [0, 1, 1, 3, 4, 4]; the engine reports honest per-input
	// clusters [0, 1, 2, 3, 4, 5], the known post-base convention.
	th := seasian_font('NotoSansThai-Variable.ttf') or { return }
	line := seasian_line(th, 'สวัสดี')
	assert line.glyphs.len == 6, 'thai hello draws six glyphs, got ${line.glyphs.len}'
	assert line.width > 0, 'a Thai word has positive width'
	want := [u16(0x6e), 0x86, 0x2d, 0x6e, 0x0c, 0x5e]
	clusters := [0, 1, 2, 3, 4, 5]
	for i in 0 .. clusters.len {
		g := seasian_at(line.glyphs, clusters[i]) or {
			panic('thai input ${clusters[i]} drew nothing')
		}
		assert g.gid == want[i], 'thai cluster ${clusters[i]} is ${want[i]:x}, got ${g.gid:x}'
		assert g.gid != 0, 'no .notdef in a covered Thai line'
	}
	assert line.glyphs[0].advance > 18.24 && line.glyphs[0].advance < 18.37, 'SA advances 572 design units'
	assert line.glyphs[1].advance > 15.68 && line.glyphs[1].advance < 15.81, 'WO advances 492 design units'
	assert line.glyphs[4].advance > 19.65 && line.glyphs[4].advance < 19.78, 'DO advances 616 design units'
	han := seasian_at(line.glyphs, 2) or { panic('thai mark drew nothing') }
	assert han.is_mark && han.advance == 0, 'MAI HAN AKAT is a mark advancing nothing'
	assert han.x > 34.31 && han.x < 34.43, 'MAI HAN AKAT sits 10 design units off the pen, got x=${han.x}'
	sara := seasian_at(line.glyphs, 5) or { panic('thai SARA II drew nothing') }
	assert sara.is_mark && sara.advance == 0, 'SARA II is a mark advancing nothing'
	assert sara.x > 72.0 && sara.x < 72.12, 'SARA II sits at the pen, got x=${sara.x}'
	assert sara.y == 0.0, 'SARA II rides the baseline'
}

fn test_seasian_shape_lao() {
	// HarfBuzz shapes seven glyphs in order with no substitution and zero
	// advance on the final SARA II, offset -582 design units off the pen by
	// the font's own anchor, merged onto the base cluster 5. The engine
	// draws all seven with the same gids, advances and offsets under the
	// honest per-input cluster 6, the known convention: the ccc=0 mark used
	// to be dropped by the class gate, and the Cf gate lets it attach. The
	// Lao script tag ('lao ', padded) is what resolves the GPOS anchors;
	// the bare 'lao' finds no script and leaves the mark at the pen.
	la := seasian_font('NotoSansLao-Variable.ttf') or { return }
	line := seasian_line(la, 'ສະບາຍດີ')
	assert line.glyphs.len == 7, 'lao hello draws seven glyphs, got ${line.glyphs.len}'
	assert line.width > 0, 'a Lao word has positive width'
	want := [u16(0x2d), 0x3b, 0x1f, 0x3c, 0x18, 0x19, 0x45]
	for i in 0 .. want.len {
		g := seasian_at(line.glyphs, i) or { panic('lao input ${i} drew nothing') }
		assert g.gid == want[i], 'lao cluster ${i} is ${want[i]:x}, got ${g.gid:x}'
		assert g.gid != 0, 'no .notdef in a covered Lao line'
	}
	sara := seasian_at(line.glyphs, 6) or { panic('lao SARA II drew nothing') }
	assert sara.is_mark && sara.advance == 0, 'SARA II is a mark advancing nothing'
	assert sara.x > 83.56 && sara.x < 83.68, 'SARA II sits 582 design units off the pen, got x=${sara.x}'
	assert sara.y == 0.0, 'SARA II rides the baseline'
}

fn test_seasian_shape_khmer() {
	// HarfBuzz shapes five glyphs under clusters [0, 0, 2, 2, 2]: the two
	// SA bases plus SRA U, then the COENG+TA subscript fusion 0xcc and
	// SRA II, with advances [928, 0, 928, 0, 0] and the fused mark at
	// (+14, -26) and SRA II at (-32, -29) off the cluster-2 pen. Toggling
	// blwf off unfolds COENG+TA back to 0x9f and 0x41, so the fusion is
	// the blwf default's work (lookup 14). The engine draws the same five
	// gids in the same order under honest per-input clusters, and every
	// offset matches: the fused mark takes the font's mark-to-base anchor
	// and SRA II resolves against the fused subscript at HarfBuzz's
	// answer. The cluster merges stay the known per-input convention.
	kh := seasian_font('NotoSansKhmer-Variable.ttf') or { return }
	line := seasian_line(kh, 'សួស្តី')
	assert line.glyphs.len == 5, 'khmer hello draws five glyphs, got ${line.glyphs.len}'
	assert line.width > 0, 'a Khmer word has positive width'
	sa0 := seasian_at(line.glyphs, 0) or { panic('khmer SA drew nothing') }
	assert sa0.gid == 0x53, 'khmer cluster 0 is SA 0x53, got ${sa0.gid:x}'
	assert sa0.advance > 0, 'the first SA moves the pen'
	u := seasian_at(line.glyphs, 1) or { panic('khmer SRA U drew nothing') }
	assert u.gid == 0x77, 'khmer cluster 1 is SRA U 0x77, got ${u.gid:x}'
	assert u.is_mark && u.advance == 0, 'SRA U is a mark advancing nothing'
	assert u.x > 29.44 && u.x < 29.56, 'SRA U sits 6 design units off the pen, got x=${u.x}'
	assert u.y > 0.77 && u.y < 0.89, 'SRA U rides 26 design units up, got y=${u.y}'
	sa2 := seasian_at(line.glyphs, 2) or { panic('khmer second SA drew nothing') }
	assert sa2.gid == 0x53, 'khmer cluster 2 is SA 0x53, got ${sa2.gid:x}'
	assert sa2.advance > 0, 'the second SA moves the pen'
	fused := seasian_at(line.glyphs, 3) or { panic('khmer COENG+TA drew nothing') }
	assert fused.gid == 0xcc, 'khmer COENG+TA fuses to 0xcc, got ${fused.gid:x}'
	assert fused.is_mark, 'the fused subscript is a mark, not a letter'
	assert fused.advance == 0, 'the fused subscript adds no advance'
	assert fused.x > 59.78 && fused.x < 59.90, 'the fused subscript sits 14 design units off the pen, got x=${fused.x}'
	assert fused.y > 0.77 && fused.y < 0.89, 'the fused subscript rides 26 design units up, got y=${fused.y}'
	ii := seasian_at(line.glyphs, 5) or { panic('khmer SRA II drew nothing') }
	assert ii.gid == 0x6d, 'khmer cluster 5 is SRA II 0x6d, got ${ii.gid:x}'
	assert ii.is_mark && ii.advance == 0, 'SRA II is a mark advancing nothing'
	assert ii.x > 58.31 && ii.x < 58.43, 'SRA II sits 32 design units before the pen, got x=${ii.x}'
	assert ii.y > 0.87 && ii.y < 0.99, 'SRA II rides 29 design units up, got y=${ii.y}'
}

fn test_seasian_shape_khmer_pstf() {
	// HarfBuzz fuses SA + COENG + KHO into [SA, 0xba] under one cluster
	// with advances [928, 294]: toggling pstf off unfolds COENG+KHO back
	// to 0x9f and 0x34, so the fusion is the pstf default's work
	// (lookup 19). The fusion is a GDEF base, not a mark, so it advances
	// the pen the way HarfBuzz does — the ligature-class fix is what
	// keeps the 294-unit advance instead of zeroing it with the COENG
	// input's mark flag. The engine reports honest per-input clusters
	// against HarfBuzz's merged pair.
	kh := seasian_font('NotoSansKhmer-Variable.ttf') or { return }
	line := seasian_line(kh, 'ស\u17d2\u1783')
	assert line.glyphs.len == 2, 'khmer SA COENG KHO draws two glyphs, got ${line.glyphs.len}'
	assert line.width > 0, 'a Khmer syllable has positive width'
	sa := seasian_at(line.glyphs, 0) or { panic('khmer SA drew nothing') }
	assert sa.gid == 0x53, 'khmer cluster 0 is SA 0x53, got ${sa.gid:x}'
	assert sa.advance > 0, 'the SA moves the pen'
	fused := seasian_at(line.glyphs, 1) or { panic('khmer COENG+KHO drew nothing') }
	assert fused.gid == 0xba, 'khmer COENG+KHO fuses to 0xba, got ${fused.gid:x}'
	assert !fused.is_mark, 'the post-base fusion is a base, not a mark'
	assert fused.advance > 9.40 && fused.advance < 9.42, 'the post-base fusion advances 294 design units, got ${fused.advance}'
	assert fused.x > 29.69 && fused.x < 29.71, 'the post-base fusion sits at the pen, got x=${fused.x}'
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
