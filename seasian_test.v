module harfara

import os
import harfara.shape
import harfara.layout

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
//     Lao SARA II, Khmer SRA U and SRA II) used to draw no glyph at all:
//     the joining pass only emitted glyphs for transparent characters with
//     a nonzero combining class, so a ccc=0 mark was swallowed even though
//     the font classes it as a GDEF mark with zero advance. The Cf gate
//     lets them attach now, and the Thai, Lao and Khmer pins hold their
//     HB-exact offsets.
//   - Khmer runs its coeng fusions (pref, blwf, pstf): COENG+RO fuses to
//     the preposed 0xdc, COENG+TA to the subscript ligature and COENG+KHO
//     to its post-base one, while pres/abvs/blws/psts/abvf wait for a
//     word that exercises them. Myanmar runs its kinzi and subjoined
//     fusions (abvs, blws): the reorder machine preposes GA ahead of the
//     NGA/ASAT/VIRAMA trio and lookup 52 fuses the trio into the kinzi
//     mark, while blws subjoins a virama-led stack behind the base; the
//     blwf medial dots stay caller-asked, and a dangling virama's dotted
//     circle belongs to a stacking slice.
//
// Tibetan is explicitly out of scope for this wave: stacking composition needs
// a stacking machine the engine does not have yet.

fn seasian_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('HARFARA_TEST_FONTS'), 'testdata/fonts'] {
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

fn test_seasian_shape_khmer_pref() {
	// HarfBuzz shapes SA + COENG + RO as the preposed pair [0xdc, SA]
	// under one cluster with advances [287, 928]: toggling pref off
	// unfolds the pair to COENG (0x9f) and RO (0x4e) but leaves it ahead
	// of the base, so the reorder is the shaper's work and the fusion is
	// the pref default's (lookup 12). The reorder machine moves each
	// adjacent COENG+RO pair to its syllable front, and the layout pass
	// merges the reordered syllable onto the base the way it does for a
	// moved matra. A following SRA II resolves against the fused pair
	// at HarfBuzz's (-32, -29), and a coeng TA pair in the same cluster
	// still fuses in place behind the base.
	kh := seasian_font('NotoSansKhmer-Variable.ttf') or { return }
	line := seasian_line(kh, 'ស\u17d2\u179a')
	assert line.glyphs.len == 2, 'khmer SA COENG RO draws two glyphs, got ${line.glyphs.len}'
	assert line.width > 0, 'a Khmer syllable has positive width'
	// Both glyphs merged onto cluster 0, so these read by index: the
	// first match would answer the fusion twice.
	assert line.glyphs[0].gid == 0xdc, 'khmer COENG+RO fuses to 0xdc, got ${line.glyphs[0].gid:x}'
	assert line.glyphs[0].cluster == 0, 'the preposed fusion merges onto the base cluster'
	assert !line.glyphs[0].is_mark, 'the preposed fusion is a base, not a mark'
	assert line.glyphs[0].advance > 9.18 && line.glyphs[0].advance < 9.20, 'the preposed fusion advances 287 design units, got ${line.glyphs[0].advance}'
	assert line.glyphs[0].x > -0.01 && line.glyphs[0].x < 0.01, 'the preposed fusion opens the line, got x=${line.glyphs[0].x}'
	assert line.glyphs[1].gid == 0x53, 'khmer cluster 0 is SA 0x53, got ${line.glyphs[1].gid:x}'
	assert line.glyphs[1].cluster == 0, 'the SA keeps the base cluster'
	assert line.glyphs[1].advance > 0, 'the SA moves the pen'
	vowel := seasian_line(kh, 'ស\u17d2\u179a\u17b8')
	assert vowel.glyphs.len == 3, 'khmer SA COENG RO II draws three glyphs, got ${vowel.glyphs.len}'
	// The vowel merged onto cluster 0 with the rest of its syllable, so
	// this reads by index too.
	assert vowel.glyphs[2].gid == 0x6d, 'khmer SRA II is 0x6d, got ${vowel.glyphs[2].gid:x}'
	assert vowel.glyphs[2].cluster == 0, 'SRA II merges onto the base cluster'
	assert vowel.glyphs[2].is_mark && vowel.glyphs[2].advance == 0, 'SRA II is a mark advancing nothing'
	assert vowel.glyphs[2].x > 37.85 && vowel.glyphs[2].x < 37.87, 'SRA II sits 32 design units before the pen, got x=${vowel.glyphs[2].x}'
	assert vowel.glyphs[2].y > 0.87 && vowel.glyphs[2].y < 0.99, 'SRA II rides 29 design units up, got y=${vowel.glyphs[2].y}'
	stack := seasian_line(kh, 'ស\u17d2\u178f\u17d2\u179a')
	assert stack.glyphs.len == 3, 'khmer SA COENG TA COENG RO draws three glyphs, got ${stack.glyphs.len}'
	assert stack.glyphs[0].gid == 0xdc, 'the RO pair preposes past the TA pair, got ${stack.glyphs[0].gid:x}'
	assert stack.glyphs[1].gid == 0x53, 'the SA stays behind the preposed pair, got ${stack.glyphs[1].gid:x}'
	assert stack.glyphs[2].gid == 0xcc, 'the TA pair fuses in place behind the base, got ${stack.glyphs[2].gid:x}'
	tail := seasian_line(kh, 'ស\u17d2\u179a\u178f')
	assert tail.glyphs.len == 3, 'khmer SA COENG RO TA draws three glyphs, got ${tail.glyphs.len}'
	assert tail.glyphs[0].gid == 0xdc && tail.glyphs[1].gid == 0x53, 'the RO pair preposes within its own syllable'
	ta := seasian_at(tail.glyphs, 3) or { panic('khmer TA drew nothing') }
	assert ta.gid == 0x41, 'khmer cluster 3 is TA 0x41, got ${ta.gid:x}'
	assert ta.advance > 0, 'the following syllable keeps its own cluster and advance'
}

fn test_seasian_shape_myanmar() {
	// HarfBuzz shapes five glyphs with advances [676, 668, 0, 1126, 455]:
	// MA, GA with the kinzi mark (0xbd), LA (0x20) and AA (0x170), the
	// followers merged onto clusters 1 and 5. Toggling abvs off unfolds
	// the trio back to NGA (0x08), asat (0x17d) and virama (0x17c), so
	// the fusion is the abvs default's work (lookup 52). There is no
	// stack ligature: the reorder machine preposes GA ahead of the
	// NGA/ASAT/VIRAMA trio the way HarfBuzz does with GSUB off, the
	// lookup fuses the reordered trio into the kinzi mark, and LA's cmap
	// glyph 0x20 was the stack all along. The engine draws the same five
	// gids in the same order with the same advances; the kinzi sits 4
	// design units before the pen off the font's mark anchor. AA keeps
	// its honest input cluster against HarfBuzz's merge, the recorded
	// per-input convention.
	my := seasian_font('NotoSansMyanmar-Variable.ttf') or { return }
	line := seasian_line(my, 'မင်္ဂလာ')
	assert line.glyphs.len == 5, 'myanmar mingala draws five glyphs, got ${line.glyphs.len}'
	assert line.width > 0, 'a Myanmar word has positive width'
	ma := seasian_at(line.glyphs, 0) or { panic('myanmar MA drew nothing') }
	assert ma.gid == 0x1d, 'myanmar cluster 0 is MA 0x1d, got ${ma.gid:x}'
	assert ma.advance > 21.63 && ma.advance < 21.64, 'MA advances 676 design units, got ${ma.advance}'
	// GA and the kinzi merged onto cluster 1, so these read by index:
	// the first match would answer GA twice.
	assert line.glyphs[1].gid == 0x06, 'myanmar preposed GA is 0x06, got ${line.glyphs[1].gid:x}'
	assert line.glyphs[1].cluster == 1, 'the preposed GA merges onto the trio cluster'
	assert line.glyphs[1].advance > 21.37 && line.glyphs[1].advance < 21.39, 'GA advances 668 design units, got ${line.glyphs[1].advance}'
	assert line.glyphs[2].gid == 0xbd, 'myanmar kinzi is 0xbd, got ${line.glyphs[2].gid:x}'
	assert line.glyphs[2].cluster == 1, 'the kinzi merges onto the trio cluster'
	assert line.glyphs[2].is_mark, 'kinzi is a mark, not a letter'
	assert line.glyphs[2].advance == 0, 'kinzi shares its base advance'
	assert line.glyphs[2].x > 42.87 && line.glyphs[2].x < 42.89, 'kinzi sits 4 design units before the pen, got x=${line.glyphs[2].x}'
	assert line.glyphs[2].y == 0.0, 'kinzi rides the baseline, got y=${line.glyphs[2].y}'
	la := seasian_at(line.glyphs, 5) or { panic('myanmar LA drew nothing') }
	assert la.gid == 0x20, 'myanmar cluster 5 is LA 0x20, got ${la.gid:x}'
	assert la.advance > 36.03 && la.advance < 36.05, 'LA advances 1126 design units, got ${la.advance}'
	aa := seasian_at(line.glyphs, 6) or { panic('myanmar AA drew nothing') }
	assert aa.gid == 0x170, 'myanmar cluster 6 is AA 0x170, got ${aa.gid:x}'
	assert aa.advance > 14.55 && aa.advance < 14.57, 'AA advances 455 design units, got ${aa.advance}'
}

fn test_seasian_shape_myanmar_blws() {
	// HarfBuzz fuses DA + VIRAMA + DHA into [DA, dha.sub] with advances
	// [640, 0], the subjoined mark at (-2, -24) off the DA: toggling
	// blws off unfolds the stack back to virama (0x17c) and DHA (0x17)
	// while -abvs, -blwf and -ccmp change nothing on it, so the stack
	// is the blws default's work. The engine draws the same two gids in
	// the same order with the same advance and offsets under honest
	// per-input clusters against HarfBuzz's merged pair.
	my := seasian_font('NotoSansMyanmar-Variable.ttf') or { return }
	line := seasian_line(my, 'ဒ္ဓ')
	assert line.glyphs.len == 2, 'myanmar DA VIRAMA DHA draws two glyphs, got ${line.glyphs.len}'
	assert line.width > 0, 'a Myanmar stack has positive width'
	da := seasian_at(line.glyphs, 0) or { panic('myanmar DA drew nothing') }
	assert da.gid == 0x16, 'myanmar cluster 0 is DA 0x16, got ${da.gid:x}'
	assert da.advance > 20.47 && da.advance < 20.49, 'DA advances 640 design units, got ${da.advance}'
	sub := seasian_at(line.glyphs, 1) or { panic('myanmar DHA sub drew nothing') }
	assert sub.gid == 0x104, 'myanmar DHA sub is 0x104, got ${sub.gid:x}'
	assert sub.is_mark, 'the subjoined DHA is a mark, not a letter'
	assert sub.advance == 0, 'the subjoined DHA shares its base advance'
	assert sub.x > 20.41 && sub.x < 20.43, 'the subjoined DHA sits 2 design units before the pen, got x=${sub.x}'
	assert sub.y > 0.71 && sub.y < 0.83, 'the subjoined DHA rides 24 design units up, got y=${sub.y}'
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
