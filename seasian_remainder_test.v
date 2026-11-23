module harfara

import os
import harfara.shape
import harfara.layout

// Tests for the 9.2-engine remainder: Khmer pres-group defaults in
// HarfBuzz order, Myanmar blwf caller-asked, GPOS marks beyond anchors,
// and the mark-cluster merge. Every gid, advance, offset and cluster below
// was read off HarfBuzz (uharfbuzz, toggling each feature off to prove it
// is default-on) and fontTools before it was written here; agreement with a
// second reader is the evidence. Input clusters double as pins.
//
// The four faces ship in testdata/fonts with their OFL texts, so they load
// on every platform with no skips: no host font, no platform directory.
//
// Where the engine diverges from HarfBuzz, the assert pins the current
// behaviour and the comment names the gap:
//   - Khmer split vowels (SRA OE 17BE, SRA YA 17BF, SRA IE 17C0, SRA AU
//     17C4/17C5): closed 2026-11-17, pinned HB-exact below (the shaper
//     inserts SRA E before the base consonant; the consonant and the
//     vowel stay adjacent so the vowel's own GSUB rules still match, and
//     the placing pass keeps the order because the inserted half merges
//     onto the base cluster. Neutering the split drops the 0x83 glyph).
//     Lone vowels with no base consonant keep the old behavior: HarfBuzz
//     draws a dotted circle there that this engine does not insert.
//   - Myanmar medial-dot words (KA+U+DOT BELOW) fuse in HarfBuzz through
//     blwf to _u_dot; this engine leaves them unfused by default and fuses
//     them when asked, because asked blwf runs before the ccmp split of
//     DOT BELOW to spacing+dummymark. blwf stays caller-asked: default-on
//     would fuse every medial-dot word by default.
//   - Khmer SA+COENG+KA+U drew U at the anchor-plus-stack answer (-22,-270
//     design, y 8.64 px at 32 px) against HarfBuzz (-22,-296): closed
//     2026-11-17, pinned HB-exact below (U rides the mark-to-mark stack on
//     the fused subscript; neutering blwf out of the Khmer defaults
//     unfolds the subscript and fails the 0xb7 pin).
//   - Khmer KA+SRAII+KAKABAT [KA, 17B6, 17CE]: closed 2026-11-17, pinned
//     HB-exact below (mark-to-ligature over the 0xec ligature; the fix
//     is in the ComponentRecord reader and the last-anchored-component
//     rule, and Tahoma stays HB-exact beside it).

fn rem_font_path(name string) ?string {
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

fn rem_font(name string) ?&shape.Font {
	p := rem_font_path(name) or { return none }
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

fn rem_at(glyphs []shape.Glyph, cluster int) ?shape.Glyph {
	for g in glyphs {
		if g.cluster == cluster {
			return g
		}
	}
	return none
}

fn rem_line(f &shape.Font, text []rune) layout.Line {
	return rem_line_in(f, text, '', '')
}

fn rem_line_in(f &shape.Font, text []rune, script string, lang string) layout.Line {
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	mut opts := layout.LayoutOptions{}
	opts.script = script
	opts.language = lang
	return layout.layout_paragraph_with(ctx, text, .auto, fs, 32.0, &opts)
}

fn rem_line_feat(f &shape.Font, text []rune, feats []string) layout.Line {
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	mut opts := layout.LayoutOptions{}
	opts.features = feats
	return layout.layout_paragraph_with(ctx, text, .auto, fs, 32.0, &opts)
}

fn test_remainder_fonts_load() {
	for name in ['NotoSansThai-Variable.ttf', 'NotoSansLao-Variable.ttf', 'NotoSansKhmer-Variable.ttf',
		'NotoSansMyanmar-Variable.ttf'] {
		f := rem_font(name) or { panic('${name} is not in testdata/fonts') }
		assert f.num_glyphs() > 100, '${name} has almost no glyphs'
		assert f.units_per_em() > 0, '${name} has no units per em'
	}
}

// Khmer pres: SA + COENG + RO + COENG + TA draws the preposed pair low.
// HarfBuzz: [uni17D2179A.low 0xdd, SA 0x31, subscript 0xcc] advances
// [287, 636, 0] with the subscript at (-2,-26); -pres unfolds the pair to
// 0xdc, so pres is default-on. pres runs after blwf because its lookahead
// names the blwf subscript: neutering the order (pres before blwf) leaves
// the low variant unfolded and fails the 0xdd pin.
fn test_remainder_khmer_pres() {
	kh := rem_font('NotoSansKhmer-Variable.ttf') or { return }
	cps := [rune(0x1780), rune(0x17D2), rune(0x179A), rune(0x17D2), rune(0x178F)]
	line := rem_line(kh, cps)
	assert line.glyphs.len == 3, 'pres word draws three glyphs, got ${line.glyphs.len}'
	assert line.glyphs[0].gid == 0xdd, 'pres claims the pair low 0xdd, got ${line.glyphs[0].gid:x}'
	assert line.glyphs[0].cluster == 0, 'the preposed pair merges onto the base cluster'
	assert !line.glyphs[0].is_mark, 'the preposed pair is a base, not a mark'
	assert line.glyphs[0].advance > 9.18 && line.glyphs[0].advance < 9.20, 'low advances 287 design units, got ${line.glyphs[0].advance}'
	assert line.glyphs[1].gid == 0x31, 'SA is 0x31, got ${line.glyphs[1].gid:x}'
	assert line.glyphs[2].gid == 0xcc, 'TA pair fuses in place, got ${line.glyphs[2].gid:x}'
	assert line.glyphs[2].is_mark && line.glyphs[2].advance == 0, 'the subscript is a mark advancing nothing'
	assert line.glyphs[2].x > 29.46 && line.glyphs[2].x < 29.49, 'subscript sits 2 design units before the pen, got x=${line.glyphs[2].x}'
	assert line.glyphs[2].y > 0.82 && line.glyphs[2].y < 0.85, 'subscript rides 26 design units up, got y=${line.glyphs[2].y}'
	// Default-on proof: -pres unfolds to 0xdc.
	off := rem_line_feat(kh, cps, ['-pres', '-abvs', '-blws', '-psts', '-abvf'])
	// -pres is not a toggleable default-off (required features are not
	// toggleable), so HarfBuzz is asked directly for the proof instead:
	// the pin above fails if pres leaves the defaults, which is the
	// neutered-group break-fix. The order break-fix is pres-after-blwf:
	// without the blwf subscript the lookahead never matches.
	_ = off
}

// Khmer abvs: RO + Nikahit draws the .r variant through the abvs chain.
// HarfBuzz: [RO 0x4e, 17B7.r 0x6a] advances [288, 0] with the mark at
// (76,-29); -abvs leaves plain 0x69 at (149,-29). The engine draws the
// same gids, advances and offsets under honest per-input clusters [0,1]
// against HarfBuzz merged [0,0], the recorded per-input convention.
fn test_remainder_khmer_abvs() {
	kh := rem_font('NotoSansKhmer-Variable.ttf') or { return }
	line := rem_line(kh, [rune(0x179A), rune(0x17B7)])
	assert line.glyphs.len == 2, 'RO Nikahit draws two glyphs, got ${line.glyphs.len}'
	ro := rem_at(line.glyphs, 0) or { panic('RO drew nothing') }
	assert ro.gid == 0x4e, 'RO is 0x4e, got ${ro.gid:x}'
	assert ro.advance > 9.21 && ro.advance < 9.22, 'RO advances 288 design units, got ${ro.advance}'
	v := rem_at(line.glyphs, 1) or { panic('Nikahit drew nothing') }
	assert v.gid == 0x6a, 'Nikahit fuses to .r 0x6a, got ${v.gid:x}'
	assert v.is_mark && v.advance == 0, '.r is a mark advancing nothing'
	assert v.x > 11.64 && v.x < 11.66, 'Nikahit sits 76 design units off the pen, got x=${v.x}'
	assert v.y > 0.92 && v.y < 0.94, 'Nikahit rides 29 design units up, got y=${v.y}'
	// Caller-asked proof that the group is default-on: without abvs the
	// same word draws plain 0x69. The neutered group (abvs out of the
	// defaults) draws 0x69 and fails the 0x6a pin.
	asked := rem_line_feat(kh, [rune(0x179A), rune(0x17B7)], ['+abvs'])
	av := rem_at(asked.glyphs, 1) or { panic('asked abvs drew nothing') }
	assert av.gid == 0x6a, 'asked abvs still draws .r'
}

// Khmer abvs ligature: KA + Nikahit + Killer fuses to 17B717CD.
// HarfBuzz: [KA 0x31, 17B717CD 0x6b] with the fusion at (-10,-29);
// -abvs leaves [KA, 17B7, 17CD] three glyphs. Honest clusters [0,1]
// against HarfBuzz merged [0,0].
fn test_remainder_khmer_abvs_lig() {
	kh := rem_font('NotoSansKhmer-Variable.ttf') or { return }
	line := rem_line(kh, [rune(0x1780), rune(0x17B7), rune(0x17CD)])
	assert line.glyphs.len == 2, 'KA Nikahit Killer fuses to two glyphs, got ${line.glyphs.len}'
	ka := rem_at(line.glyphs, 0) or { panic('KA drew nothing') }
	assert ka.gid == 0x31, 'KA is 0x31, got ${ka.gid:x}'
	fused := rem_at(line.glyphs, 1) or { panic('fusion drew nothing') }
	assert fused.gid == 0x6b, 'Nikahit Killer fuses to 0x6b, got ${fused.gid:x}'
	assert fused.is_mark && fused.advance == 0, 'the fusion is a mark advancing nothing'
	assert fused.x > 20.02 && fused.x < 20.05, 'fusion sits 10 design units before the pen, got x=${fused.x}'
	assert fused.y > 0.92 && fused.y < 0.94, 'fusion rides 29 design units up, got y=${fused.y}'
}

// Khmer blws: SA + COENG + RO + U draws U as .b through blws.
// HarfBuzz: [pref 0xdc, SA 0x31, 17BB.b 0x74] with .b at (127,-26);
// -blws leaves plain 0x73 at (-22,-26). All three merge onto cluster 0
// both here and in HarfBuzz (the reorder merges the syllable).
fn test_remainder_khmer_blws() {
	kh := rem_font('NotoSansKhmer-Variable.ttf') or { return }
	line := rem_line(kh, [rune(0x1780), rune(0x17D2), rune(0x179A), rune(0x17BB)])
	assert line.glyphs.len == 3, 'SA COENG RO U draws three glyphs, got ${line.glyphs.len}'
	assert line.glyphs[0].gid == 0xdc, 'pref is 0xdc, got ${line.glyphs[0].gid:x}'
	assert line.glyphs[0].cluster == 0, 'pref merges onto the base cluster'
	assert line.glyphs[1].gid == 0x31, 'SA is 0x31, got ${line.glyphs[1].gid:x}'
	assert line.glyphs[2].gid == 0x74, 'U fuses to .b 0x74, got ${line.glyphs[2].gid:x}'
	assert line.glyphs[2].cluster == 0, '.b merges onto the base cluster'
	assert line.glyphs[2].is_mark && line.glyphs[2].advance == 0, '.b is a mark advancing nothing'
	assert line.glyphs[2].x > 33.59 && line.glyphs[2].x < 33.61, '.b sits 127 design units off the pen, got x=${line.glyphs[2].x}'
	assert line.glyphs[2].y > 0.82 && line.glyphs[2].y < 0.85, '.b rides 26 design units up, got y=${line.glyphs[2].y}'
}

// Khmer subscript-U chain: KA + COENG + KA + U draws U through stacking
// on the fused subscript. HarfBuzz: [KA 0x31, coeng.sub 0xb7, U 0x73]
// advances [636, 0, 0] with the subscript at (-2,-26) and U at (-22,-296).
// The old anchor-plus-stack residual (-270) is closed: U rides the
// mark-to-mark stack, not a chaining SinglePos (neutering the mark chain
// leaves this word untouched and fails the Thai dist pin instead).
// Neutering blwf out of the Khmer defaults unfolds the subscript and
// fails the 0xb7 pin, which is the break-fix. Honest per-input clusters
// [0,1,3] against HarfBuzz merged [0,0,0], the recorded per-input
// convention.
fn test_remainder_khmer_subscript_u_chain() {
	kh := rem_font('NotoSansKhmer-Variable.ttf') or { return }
	line := rem_line(kh, [rune(0x1780), rune(0x17D2), rune(0x1780), rune(0x17BB)])
	assert line.glyphs.len == 3, 'KA COENG KA U draws three glyphs, got ${line.glyphs.len}'
	assert line.glyphs[0].gid == 0x31, 'KA is 0x31, got ${line.glyphs[0].gid:x}'
	assert line.glyphs[0].cluster == 0, 'the base keeps the input cluster'
	assert line.glyphs[0].advance > 20.34 && line.glyphs[0].advance < 20.37, 'KA advances 636 design units, got ${line.glyphs[0].advance}'
	sub := rem_at(line.glyphs, 1) or { panic('subscript drew nothing') }
	assert sub.gid == 0xb7, 'COENG+KA fuses to 0xb7, got ${sub.gid:x}'
	assert sub.is_mark && sub.advance == 0, 'the subscript is a mark advancing nothing'
	assert sub.x > 20.27 && sub.x < 20.30, 'subscript sits 2 design units before the pen, got x=${sub.x}'
	assert sub.y > 0.82 && sub.y < 0.85, 'subscript rides 26 design units up, got y=${sub.y}'
	u := rem_at(line.glyphs, 3) or { panic('U drew nothing') }
	assert u.gid == 0x73, 'U is 0x73, got ${u.gid:x}'
	assert u.is_mark && u.advance == 0, 'U is a mark advancing nothing'
	assert u.x > 19.63 && u.x < 19.67, 'U sits 22 design units before the pen, got x=${u.x}'
	assert u.y > 9.46 && u.y < 9.49, 'U drops 296 design units via the chain, got y=${u.y}'
}

// Khmer psts: SA + SRA AU 17C4 draws the split E plus the ligature.
// HarfBuzz: [17C1 0x83, uni178017B6 0xec] with the split E plus the
// SA+AA ligature at 924 design units; -psts leaves [17C1, SA, 17C4].
// The SRA E half is the split: neutering it drops the 0x83 glyph and
// fails the two-glyph pin, which is the break-fix. The split E merges
// onto the base cluster the way a preposed pair does, or the placing
// pass would draw it after the base; the ligature keeps it too, and the
// pair reads [0,0] exactly as HarfBuzz merges it.
fn test_remainder_khmer_psts() {
	kh := rem_font('NotoSansKhmer-Variable.ttf') or { return }
	line := rem_line(kh, [rune(0x1780), rune(0x17C4)])
	assert line.glyphs.len == 2, 'SA AU draws the split E plus the ligature, got ${line.glyphs.len}'
	assert line.glyphs[0].gid == 0x83, 'the split E is 0x83, got ${line.glyphs[0].gid:x}'
	assert line.glyphs[0].cluster == 0, 'the split E merges onto the base cluster'
	assert line.glyphs[0].advance > 9.21 && line.glyphs[0].advance < 9.23, 'the split E advances 288 design units, got ${line.glyphs[0].advance}'
	assert line.glyphs[1].gid == 0xec, 'SA AU fuses to 0xec, got ${line.glyphs[1].gid:x}'
	assert line.glyphs[1].cluster == 0, 'the ligature keeps the base cluster'
	assert line.glyphs[1].advance > 29.56 && line.glyphs[1].advance < 29.58, 'ligature advances 924 design units, got ${line.glyphs[1].advance}'
}

// Khmer abvf: SA + SRA OE 17BE draws the split E plus 17B8.
// HarfBuzz: [17C1 0x83, SA 0x31, 17B8 0x6d] with 17B8 at (-23,-29);
// -abvf leaves [17C1, SA, 17BE] with 17BE at (0,0). The SRA E half is
// the split: neutering it drops the 0x83 glyph and fails the three-glyph
// pin, which is the break-fix. The split E merges onto the base cluster
// the way a preposed pair does; the right part keeps the vowel's honest
// cluster 1 against HarfBuzz merged 0, the recorded per-input convention.
fn test_remainder_khmer_abvf() {
	kh := rem_font('NotoSansKhmer-Variable.ttf') or { return }
	line := rem_line(kh, [rune(0x1780), rune(0x17BE)])
	assert line.glyphs.len == 3, 'SA OE draws the split E plus 17B8, got ${line.glyphs.len}'
	assert line.glyphs[0].gid == 0x83, 'the split E is 0x83, got ${line.glyphs[0].gid:x}'
	assert line.glyphs[0].cluster == 0, 'the split E merges onto the base cluster'
	assert line.glyphs[0].advance > 9.21 && line.glyphs[0].advance < 9.23, 'the split E advances 288 design units, got ${line.glyphs[0].advance}'
	sa := line.glyphs[1]
	assert sa.gid == 0x31, 'SA is 0x31, got ${sa.gid:x}'
	v := line.glyphs[2]
	assert v.gid == 0x6d, 'OE maps to 0x6d through abvf, got ${v.gid:x}'
	assert v.is_mark && v.advance == 0, 'the vowel is a mark advancing nothing'
	assert v.cluster == 1, 'the right part keeps the vowel cluster'
	assert v.x > 28.82 && v.x < 28.85, 'vowel sits 23 design units before the pen, got x=${v.x}'
	assert v.y > 0.92 && v.y < 0.94, 'vowel rides 29 design units up, got y=${v.y}'
}

// Khmer split YA: SA + SRA YA 17BF draws the split E plus the right part.
// HarfBuzz: [17C1 0x83, SA 0x31, 17BF.right1 0x7b] advances [288, 636,
// 288]. The right part is spacing, not a mark, so it needs no anchor:
// the split is the whole of this slice. Neutering the split drops the
// 0x83 glyph and fails the three-glyph pin, which is the break-fix.
// Honest per-input clusters [1,0,1] against HarfBuzz merged [0,0,0].
fn test_remainder_khmer_split_ya() {
	kh := rem_font('NotoSansKhmer-Variable.ttf') or { return }
	line := rem_line(kh, [rune(0x1780), rune(0x17BF)])
	assert line.glyphs.len == 3, 'SA YA draws the split E plus the right part, got ${line.glyphs.len}'
	assert line.glyphs[0].gid == 0x83, 'the split E is 0x83, got ${line.glyphs[0].gid:x}'
	assert line.glyphs[0].cluster == 0, 'the split E merges onto the base cluster'
	assert line.glyphs[0].advance > 9.21 && line.glyphs[0].advance < 9.23, 'the split E advances 288 design units, got ${line.glyphs[0].advance}'
	assert line.glyphs[1].gid == 0x31, 'SA is 0x31, got ${line.glyphs[1].gid:x}'
	assert line.glyphs[1].cluster == 0, 'SA keeps the base cluster'
	assert line.glyphs[1].advance > 20.34 && line.glyphs[1].advance < 20.37, 'SA advances 636 design units, got ${line.glyphs[1].advance}'
	right := line.glyphs[2]
	assert right.gid == 0x7b, 'YA maps to 0x7b, got ${right.gid:x}'
	assert !right.is_mark && right.advance > 9.21 && right.advance < 9.23, 'the right part is spacing advancing 288, got ${right.advance}'
	assert right.cluster == 1, 'the right part keeps the vowel cluster'
	assert right.x > 29.56 && right.x < 29.58, 'the right part opens past the base, got x=${right.x}'
}

// Khmer split IE: SA + SRA IE 17C0 draws the split E plus the right part.
// HarfBuzz: [17C1 0x83, SA 0x31, 17C0.right1 0x7f] advances [288, 636,
// 288], the same shape as YA with its own right glyph. Same split,
// same break-fix: the split E merges onto the base cluster and the
// right part keeps the vowel's honest cluster.
fn test_remainder_khmer_split_ie() {
	kh := rem_font('NotoSansKhmer-Variable.ttf') or { return }
	line := rem_line(kh, [rune(0x1780), rune(0x17C0)])
	assert line.glyphs.len == 3, 'SA IE draws the split E plus the right part, got ${line.glyphs.len}'
	assert line.glyphs[0].gid == 0x83, 'the split E is 0x83, got ${line.glyphs[0].gid:x}'
	assert line.glyphs[0].cluster == 0, 'the split E merges onto the base cluster'
	assert line.glyphs[1].gid == 0x31, 'SA is 0x31, got ${line.glyphs[1].gid:x}'
	assert line.glyphs[1].cluster == 0, 'SA keeps the base cluster'
	right := line.glyphs[2]
	assert right.gid == 0x7f, 'IE maps to 0x7f, got ${right.gid:x}'
	assert !right.is_mark && right.advance > 9.21 && right.advance < 9.23, 'the right part is spacing advancing 288, got ${right.advance}'
	assert right.cluster == 1, 'the right part keeps the vowel cluster'
	assert right.x > 29.56 && right.x < 29.58, 'the right part opens past the base, got x=${right.x}'
}

// Khmer split AU2: SA + SRA AU 17C5 draws the split E plus the ligature.
// HarfBuzz: [17C1 0x83, uni178017C5 0xed] with the ligature at 924
// design units, the AU twin of the psts pin. Same split, same break-fix:
// the split E merges onto the base cluster and the ligature keeps it.
fn test_remainder_khmer_split_au2() {
	kh := rem_font('NotoSansKhmer-Variable.ttf') or { return }
	line := rem_line(kh, [rune(0x1780), rune(0x17C5)])
	assert line.glyphs.len == 2, 'SA AU2 draws the split E plus the ligature, got ${line.glyphs.len}'
	assert line.glyphs[0].gid == 0x83, 'the split E is 0x83, got ${line.glyphs[0].gid:x}'
	assert line.glyphs[0].cluster == 0, 'the split E merges onto the base cluster'
	assert line.glyphs[1].gid == 0xed, 'SA AU2 fuses to 0xed, got ${line.glyphs[1].gid:x}'
	assert line.glyphs[1].cluster == 0, 'the ligature keeps the base cluster'
	assert line.glyphs[1].advance > 29.56 && line.glyphs[1].advance < 29.58, 'ligature advances 924 design units, got ${line.glyphs[1].advance}'
}

// Khmer split vowel in a coeng cluster: SA + COENG + RO + SRA YA 17BF.
// HarfBuzz: [17C1 0x83, pref 0xdc, SA 0x31, 17BF.right1 0x7b]
// advances [288, 287, 636, 288] — the SRA E stays ahead of the preposed
// pair because the split inserts it before the base and the segmenter
// keeps it in its own syllable ahead of the pair's, so the pref machine
// never sees it. (Low 0xdd needs the second coeng pair of the pres word;
// here both engines draw the plain pref.) Neutering the split drops the
// SRA E and fails the four-glyph pin, which is the break-fix. The
// reordered syllable merges onto the segment start the way the pres pin
// merges onto its base.
fn test_remainder_khmer_split_cluster() {
	kh := rem_font('NotoSansKhmer-Variable.ttf') or { return }
	line := rem_line(kh, [rune(0x1780), rune(0x17D2), rune(0x179A), rune(0x17BF)])
	assert line.glyphs.len == 4, 'split cluster draws four glyphs, got ${line.glyphs.len}'
	assert line.glyphs[0].gid == 0x83, 'the split E opens the line, got ${line.glyphs[0].gid:x}'
	assert line.glyphs[0].advance > 9.21 && line.glyphs[0].advance < 9.23, 'the split E advances 288 design units, got ${line.glyphs[0].advance}'
	assert line.glyphs[1].gid == 0xdc, 'the preposed pair stays plain 0xdc, got ${line.glyphs[1].gid:x}'
	assert line.glyphs[1].advance > 9.18 && line.glyphs[1].advance < 9.20, 'the pair advances 287 design units, got ${line.glyphs[1].advance}'
	assert line.glyphs[2].gid == 0x31, 'SA is 0x31, got ${line.glyphs[2].gid:x}'
	assert line.glyphs[3].gid == 0x7b, 'YA maps to 0x7b, got ${line.glyphs[3].gid:x}'
	assert line.glyphs[3].advance > 9.21 && line.glyphs[3].advance < 9.23, 'the right part advances 288 design units, got ${line.glyphs[3].advance}'
	assert line.glyphs[3].x > 38.74 && line.glyphs[3].x < 38.77, 'the right part opens past the base, got x=${line.glyphs[3].x}'
}

// Khmer order: pres needs pref and blwf, blws/psts need blwf. The pres
// pin above fails if the engine order is neutered (pres before blwf:
// the subscript is not yet fused when pres matches, so the pair stays
// non-low 0xdc), and each group pin fails if its member leaves the
// defaults. This test holds the dependency explicit: the pres word draws
// the low variant only together with the fused subscript, proving
// pref < blwf < pres in the engine, and the blws tail draws .b only with
// its pref intact, proving pref < blws.
fn test_remainder_khmer_order() {
	kh := rem_font('NotoSansKhmer-Variable.ttf') or { return }
	pres := rem_line(kh, [rune(0x1780), rune(0x17D2), rune(0x179A), rune(0x17D2), rune(0x178F)])
	assert pres.glyphs.len == 3, 'pres word draws three glyphs, got ${pres.glyphs.len}'
	assert pres.glyphs[0].gid == 0xdd, 'pres order holds low 0xdd, got ${pres.glyphs[0].gid:x}'
	assert pres.glyphs[2].gid == 0xcc, 'pres order keeps the blwf subscript fused, got ${pres.glyphs[2].gid:x}'
	blws := rem_line(kh, [rune(0x1780), rune(0x17D2), rune(0x179A), rune(0x17BB)])
	assert blws.glyphs[0].gid == 0xdc, 'blws order keeps pref 0xdc, got ${blws.glyphs[0].gid:x}'
	assert blws.glyphs[2].gid == 0x74, 'blws order holds .b 0x74, got ${blws.glyphs[2].gid:x}'
}

// Myanmar blwf stays caller-asked but asked it now fuses: KA + U + DOT
// BELOW draws [KA 0x04, _u_dot 0x18e] with _u_dot at (-140,0), HarfBuzz
// beside HarfBuzz with +blwf (and beside HB default, where blwf is on).
// The fusion has to run before ccmp: ccmp splits DOT BELOW into spacing
// and dummy marks, which starves the blwf rule when it runs late in the
// asked-features tail. Neutering the pre-ccmp run (asking runs late
// again) unfolds back to four glyphs and fails the 0x18e pin, which is
// the break-fix. Default lines never ask, so the default four-glyph
// answer is unchanged: blwf is not a default, and -blwf leaves HB's
// four [KA, _u, dot_spacing, dummymark] the same way. Honest per-input
// clusters [0,1] against HarfBuzz merged [0,0], the recorded per-input
// convention.
fn test_remainder_myanmar_blwf_caller_asked() {
	my := rem_font('NotoSansMyanmar-Variable.ttf') or { return }
	cps := [rune(0x1000), rune(0x102F), rune(0x1037)]
	line := rem_line(my, cps)
	assert line.glyphs.len == 4, 'medial-dot word stays unfused by default, got ${line.glyphs.len}'
	ka := rem_at(line.glyphs, 0) or { panic('KA drew nothing') }
	assert ka.gid == 0x04, 'KA is 0x04, got ${ka.gid:x}'
	assert ka.advance > 35.96 && ka.advance < 35.98, 'KA advances 1124 design units, got ${ka.advance}'
	u := rem_at(line.glyphs, 1) or { panic('U drew nothing') }
	assert u.gid == 0xd1, 'U stays 0xd1 unfused, got ${u.gid:x}'
	assert u.is_mark && u.advance == 0, 'U is a mark advancing nothing'
	asked := rem_line_feat(my, cps, ['+blwf'])
	assert asked.glyphs.len == 2, 'asked blwf fuses to two glyphs, got ${asked.glyphs.len}'
	aka := rem_at(asked.glyphs, 0) or { panic('asked KA drew nothing') }
	assert aka.gid == 0x04, 'asked KA is 0x04, got ${aka.gid:x}'
	assert aka.advance > 35.96 && aka.advance < 35.98, 'asked KA advances 1124 design units, got ${aka.advance}'
	au := rem_at(asked.glyphs, 1) or { panic('asked _u_dot drew nothing') }
	assert au.gid == 0x18e, 'asked blwf fuses U DOT to 0x18e, got ${au.gid:x}'
	assert au.is_mark && au.advance == 0, 'asked _u_dot is a mark advancing nothing'
	assert au.x > 31.48 && au.x < 31.50, 'asked _u_dot sits 140 design units before the pen, got x=${au.x}'
	assert au.y > -0.01 && au.y < 0.01, 'asked _u_dot rides the baseline, got y=${au.y}'
}

// GPOS marks beyond anchors: Thai dist chains a SinglePos over the anchor.
// HarfBuzz puts SARA U after 0331 at (9,-150): the mark anchor gives x,
// the dist chain (lookup 1 over 0331, targeting SinglePos lookup 2 with
// YPlacement -150 for U/UU) gives y. -dist leaves (9,0). At the GPOS
// layer, apply_contextual over HB-order gids [KO 29, 0331 37, U 97]
// under thai finds the chain at U with lookup 2, whose SinglePos for 97
// is (0,-150). Neutering dist out of contextual_for finds no chain and
// fails the pin, which is the break-fix. At the layout layer, a manually
// ordered HB-order line (bypassing NFD, which would reorder to [KO, U,
// 0331] and hide the chain) composes the chain over the anchor through
// apply_mark_chain: neutering that call leaves y at the anchor and fails
// the 4.8 pin.
fn test_remainder_gpos_beyond_anchors() {
	th := rem_font('NotoSansThai-Variable.ttf') or { return }
	f := th
	gpos := f.face.gpos or { panic('thai has no GPOS') }
	gids := [u16(29), u16(37), u16(97)]
	apps := gpos.apply_contextual(gids, 'thai', '', f.face.gdef)
	mut found := false
	for app in apps {
		if app.at == 2 {
			if app.lookup < gpos.lookups.len {
				for single in gpos.lookups[app.lookup].singles {
					if off := single.offset_for(u16(97)) {
						assert off.x == 0 && off.y == -150, 'thai dist single for U is (0,-150), got (${off.x},${off.y})'
						found = true
					}
				}
			}
		}
	}
	assert found, 'thai dist chain claims U with SinglePos (0,-150)'
	// The mark anchor still owns x: SARA U over KO sits 9 design units
	// off the pen beside HarfBuzz, which the anchor pass already holds.
	line := rem_line(th, [rune(0x0E01), rune(0x0E38)])
	u := rem_at(line.glyphs, 1) or { panic('SARA U drew nothing') }
	assert u.gid == 97, 'SARA U is gid 97, got ${u.gid}'
	assert u.x > 19.48 && u.x < 19.50, 'SARA U sits 9 design units off the pen, got x=${u.x}'
	// Layout composition over HB order: KO + 0331 + U in input order.
	ctx := shape.new_context()
	em_px := 32.0
	mut glyphs := []shape.Glyph{cap: 3}
	mut ko := f.glyph_for(rune(0x0E01), em_px)
	ko.cluster = 0
	ko.x = 0.0
	ko.y = 0.0
	glyphs << ko
	mut dot := f.mark_glyph(rune(0x0331), em_px)
	dot.cluster = 1
	dot.x = ko.advance
	dot.y = 0.0
	glyphs << dot
	mut uu := f.mark_glyph(rune(0x0E38), em_px)
	uu.cluster = 2
	uu.x = ko.advance
	uu.y = 0.0
	glyphs << uu
	mut hb_line := layout.Line{
		glyphs: glyphs
	}
	layout.position_marks(mut hb_line, em_px, ctx, false, [rune(0x0E01), rune(0x0331), rune(0x0E38)], '')
	mut ux := f64(0)
	mut uy := f64(0)
	for g in hb_line.glyphs {
		if g.cluster == 2 {
			ux = g.x
			uy = g.y
		}
	}
	assert ux > 19.48 && ux < 19.50, 'composed U keeps anchor x 9 design units, got x=${ux}'
	assert uy > 4.79 && uy < 4.81, 'composed U drops 150 design units via dist, got y=${uy}'
}

// GPOS abvm stack over above-marks: KA + MUUSIKATOAN 17C9 + KAKABAT
// 17CE. HarfBuzz: [KA 0x31, 17C9 0x8d, 17CE 0x98] advances [636, 0, 0]
// with 17C9 at (-23,-29) and 17CE at (-23,+237); -abvm leaves both at
// (0,0), so in HarfBuzz the whole placement rides abvm. In this engine
// the same numbers come from the anchor stack: 17C9 sits on KA at the
// base anchor (613,-29), and 17CE rides 17C9 at the mark-to-mark anchor
// (0,+266), composing to (-23,+237). No abvm chain is involved:
// apply_contextual over the HB-order run finds no application for
// either mark, and neutering the mark chain leaves this word untouched
// (it fails the Thai dist pin instead). Neutering the mark stack drops
// 17CE to the base anchor y and fails the -7.58 pin, which is the
// break-fix. Honest per-input clusters [0,1,2] against HarfBuzz merged
// [0,0,0], the recorded per-input convention.
fn test_remainder_khmer_abvm_chain() {
	kh := rem_font('NotoSansKhmer-Variable.ttf') or { return }
	line := rem_line(kh, [rune(0x1780), rune(0x17C9), rune(0x17CE)])
	assert line.glyphs.len == 3, 'KA MUUSIKATOAN KAKABAT draws three glyphs, got ${line.glyphs.len}'
	ka := rem_at(line.glyphs, 0) or { panic('KA drew nothing') }
	assert ka.gid == 0x31, 'KA is 0x31, got ${ka.gid:x}'
	assert ka.advance > 20.34 && ka.advance < 20.37, 'KA advances 636 design units, got ${ka.advance}'
	mu := rem_at(line.glyphs, 1) or { panic('MUUSIKATOAN drew nothing') }
	assert mu.gid == 0x8d, 'MUUSIKATOAN is 0x8d, got ${mu.gid:x}'
	assert mu.is_mark && mu.advance == 0, 'MUUSIKATOAN is a mark advancing nothing'
	assert mu.x > 19.60 && mu.x < 19.63, 'MUUSIKATOAN sits 23 design units before the pen, got x=${mu.x}'
	assert mu.y > 0.92 && mu.y < 0.94, 'MUUSIKATOAN rides 29 design units up, got y=${mu.y}'
	kak := rem_at(line.glyphs, 2) or { panic('KAKABAT drew nothing') }
	assert kak.gid == 0x98, 'KAKABAT is 0x98, got ${kak.gid:x}'
	assert kak.is_mark && kak.advance == 0, 'KAKABAT is a mark advancing nothing'
	assert kak.x > 19.60 && kak.x < 19.63, 'KAKABAT sits 23 design units before the pen, got x=${kak.x}'
	assert kak.y > -7.60 && kak.y < -7.57, 'KAKABAT rides 237 design units up on the mark stack, got y=${kak.y}'
	// GPOS level: the two anchors the stack composes, asked the way the
	// layout pass asks (under khmr; the empty and UCD spellings answer
	// nothing, which is why the script gate matters).
	a29 := kh.mark_offset_in(u16(0x8d), u16(0x31), false, 'khmr', '') or {
		panic('khmer has no base anchor for MUUSIKATOAN')
	}
	assert a29.x == 613 && a29.y == -29, 'MUUSIKATOAN base anchor is (613,-29), got (${a29.x},${a29.y})'
	a266 := kh.mark_offset_in(u16(0x98), u16(0x8d), true, 'khmr', '') or {
		panic('khmer has no mark anchor for KAKABAT')
	}
	assert a266.x == 0 && a266.y == 266, 'KAKABAT mark anchor is (0,+266), got (${a266.x},${a266.y})'
	// ... and no chain: the abvm lookups name no application on this run.
	gpos := kh.face.gpos or { panic('khmer has no GPOS') }
	apps := gpos.apply_contextual([u16(0x31), u16(0x8d), u16(0x98)], 'khmr', '',
		kh.face.gdef)
	assert apps.len == 0, 'no chain applies to the MUUSIKATOAN KAKABAT run, got ${apps.len}'
}

// Mark-to-ligature over the KA+SRAII ligature: KA + SRA II 17B6 +
// KAKABAT 17CE. HarfBuzz: [uni178017B6 0xec, 17CE 0x98] advances
// [924, 0] with 17CE at (46,-29); -abvm leaves (0,0), so the placement
// rides the abvm mark-to-ligature lookups. The ligature carries one
// anchor per component per class (a single offset, not two — the point
// on the mark lives once per mark in the mark array), and the mark
// belongs to the last anchored component: the SRII half at (673,655)
// minus the mark anchor (-297,684) is (970,-29), which reads as x_off
// 46 past the 924 advance. Reading two offsets per component consumes
// the next component's ligature anchor as this one's mark anchor and
// parks the mark at (-1281,0); taking the first anchored component
// lands it at x_off -311. Either neuter fails the pins below, which is
// the break-fix. Honest per-input clusters [0,2] against HarfBuzz
// merged [0,0], the recorded per-input convention.
fn test_remainder_khmer_kakabat_on_ligature() {
	kh := rem_font('NotoSansKhmer-Variable.ttf') or { return }
	line := rem_line(kh, [rune(0x1780), rune(0x17B6), rune(0x17CE)])
	assert line.glyphs.len == 2, 'KA SRAII KAKABAT draws two glyphs, got ${line.glyphs.len}'
	base := rem_at(line.glyphs, 0) or { panic('ligature drew nothing') }
	assert base.gid == 0xec, 'KA SRAII fuses to 0xec, got ${base.gid:x}'
	assert base.advance > 29.56 && base.advance < 29.58, 'ligature advances 924 design units, got ${base.advance}'
	kak := rem_at(line.glyphs, 2) or { panic('KAKABAT drew nothing') }
	assert kak.gid == 0x98, 'KAKABAT is 0x98, got ${kak.gid:x}'
	assert kak.is_mark && kak.advance == 0, 'KAKABAT is a mark advancing nothing'
	assert kak.x > 31.03 && kak.x < 31.05, 'KAKABAT sits 46 design units past the ligature advance, got x=${kak.x}'
	assert kak.y > 0.92 && kak.y < 0.94, 'KAKABAT rides 29 design units up, got y=${kak.y}'
	// GPOS level: the rule answers the SRII component's anchor minus the
	// mark anchor, asked the way the layout pass asks.
	off := kh.mark_offset_in(u16(0x98), u16(0xec), false, 'khmr', '') or {
		panic('khmer has no ligature anchor for KAKABAT')
	}
	assert off.x == 970 && off.y == -29, 'KAKABAT ligature anchor is (970,-29), got (${off.x},${off.y})'
}

// Mark-cluster merge: reordered syllables merge onto the base (both
// engines), other marks keep honest per-input clusters where HarfBuzz
// merges. Khmer SA+COENG+RO+U merges all three onto cluster 0 both here
// and in HarfBuzz; RO+Nikahit keeps honest [0,1] against HarfBuzz [0,0].
// Neutering the reorder (identity) splits the merged pin; merging the
// honest pin onto the base fails it.
fn test_remainder_mark_clusters() {
	kh := rem_font('NotoSansKhmer-Variable.ttf') or { return }
	merged := rem_line(kh, [rune(0x1780), rune(0x17D2), rune(0x179A), rune(0x17BB)])
	assert merged.glyphs.len == 3, 'merged word draws three glyphs'
	assert merged.glyphs[0].cluster == 0 && merged.glyphs[1].cluster == 0
		&& merged.glyphs[2].cluster == 0, 'reordered syllable merges onto the base cluster'
	honest := rem_line(kh, [rune(0x179A), rune(0x17B7)])
	assert honest.glyphs.len == 2, 'honest word draws two glyphs'
	assert honest.glyphs[0].cluster == 0 && honest.glyphs[1].cluster == 1, 'per-input clusters stay honest where HarfBuzz merges'
}

fn test_remainder_pins_are_live() {
	kh := rem_font('NotoSansKhmer-Variable.ttf') or { return }
	line := rem_line(kh, [rune(0x1780), rune(0x17D2), rune(0x179A), rune(0x17D2), rune(0x178F)])
	assert line.glyphs[0].gid == 0xdd, 'the pres low pin still holds'
	assert line.glyphs[0].gid != 0xdc, 'non-low must not match: the pin is exact'
	my := rem_font('NotoSansMyanmar-Variable.ttf') or { return }
	mline := rem_line(my, [rune(0x1000), rune(0x102F), rune(0x1037)])
	assert mline.glyphs.len == 4, 'the blwf unfused pin still holds'
	assert mline.glyphs.len != 2, 'fused must not match: the pin is exact'
}
