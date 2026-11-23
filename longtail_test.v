module harfara

import os
import harfara.shape
import harfara.layout

// Tests for the fourth corpus wave: long-tail faces (Syriac, Thaana, NKo).
// Every gid, advance and cluster below was read off HarfBuzz (uharfbuzz,
// scale 1000 = font units, every face here is upm 1000) and fontTools before
// it was written here; agreement with a second reader is the evidence. Input
// clusters double as pins: a cluster is an input position, so "the glyph
// reporting cluster 2" names no engine output of its own.
//
// The three faces ship in testdata/fonts with their OFL texts, so they load
// on every platform with no skips: no host font, no platform directory.
//
// Where the engine diverges from HarfBuzz, the assert pins the current
// behaviour and the comment names the gap for the engine slice that owns it.
// Two such gaps closed in 9.3e: Thaana fili and the NKo tag fold now draw
// beside HarfBuzz, pinned below; the Khmer coeng fusion and the Yi tag (no
// corpus word exercises it yet) stay open.
//   - Tibetan stacking composition and Indic conjunct fusion stay follow-ups:
//     neither this wave's faces nor its asserts go there.
//
// Syriac joining is the named acceptance of this wave: SHIN takes its init
// form word-initially (0x65) and its cmap/isol form in isolation (0x62), the
// two medial letters take medi forms, and ALAPH takes the rlig fina.wideX
// form (0x104). NKo joins the same way (init/medi/fina), so it carries the
// same form check through the table override; Thaana does not join and
// carries none.

fn longtail_font_path(name string) ?string {
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

fn longtail_font(name string) ?&shape.Font {
	p := longtail_font_path(name) or { return none }
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

// longtail_at returns the glyph that came from the input character at that
// index, or none when the character drew nothing.
fn longtail_at(glyphs []shape.Glyph, cluster int) ?shape.Glyph {
	for g in glyphs {
		if g.cluster == cluster {
			return g
		}
	}
	return none
}

// longtail_dump renders a line as gid:cluster:advance cells so a failing pin
// shows the whole engine answer in the message.
fn longtail_dump(line layout.Line) string {
	mut parts := []string{cap: line.glyphs.len}
	for g in line.glyphs {
		parts << '${g.gid:x}:${g.cluster}:${g.advance:.2f}'
	}
	return '[' + parts.join(' ') + ']'
}

// longtail_word builds a test word from codepoints, keeping this file ASCII.
fn longtail_word(cps []rune) string {
	mut parts := []string{cap: cps.len}
	for cp in cps {
		parts << cp.str()
	}
	return parts.join('')
}

fn test_longtail_fonts_load() {
	for name in ['NotoSansSyriac-Variable.ttf', 'NotoSansThaana-Variable.ttf', 'NotoSansNKo-Regular.ttf'] {
		f := longtail_font(name) or { panic('${name} is not in testdata/fonts') }
		assert f.num_glyphs() > 100, '${name} has almost no glyphs'
		assert f.units_per_em() > 0, '${name} has no units per em'
	}
}

fn test_longtail_fonts_cover_what_they_claim() {
	// fontTools cmap: each face covers Latin plus its own script, and none
	// of the other two long-tail scripts (nor Arabic or Thai).
	sy := longtail_font('NotoSansSyriac-Variable.ttf') or { return }
	assert sy.has_glyph(`A`), 'Syriac covers Latin'
	assert sy.has_glyph(rune(0x0710)), 'Syriac covers SYRIAC LETTER ALAPH'
	assert sy.has_glyph(rune(0x072B)), 'Syriac covers SYRIAC LETTER SHIN'
	assert !sy.has_glyph(rune(0x0780)), 'Syriac covers no Thaana'
	assert !sy.has_glyph(rune(0x07C0)), 'Syriac covers no NKo'
	assert !sy.has_glyph(rune(0x0628)), 'Syriac covers no Arabic'
	assert !sy.has_glyph(rune(0x0E01)), 'Syriac covers no Thai'
	th := longtail_font('NotoSansThaana-Variable.ttf') or { return }
	assert th.has_glyph(`A`), 'Thaana covers Latin'
	assert th.has_glyph(rune(0x0780)), 'Thaana covers THAANA LETTER HAA'
	assert th.has_glyph(rune(0x07A8)), 'Thaana covers THAANA IBIFILI'
	assert !th.has_glyph(rune(0x0710)), 'Thaana covers no Syriac'
	assert !th.has_glyph(rune(0x07C0)), 'Thaana covers no NKo'
	assert !th.has_glyph(rune(0x0628)), 'Thaana covers no Arabic'
	nk := longtail_font('NotoSansNKo-Regular.ttf') or { return }
	assert nk.has_glyph(`A`), 'NKo covers Latin'
	assert nk.has_glyph(rune(0x07C0)), 'NKo covers NKO LETTER A'
	assert nk.has_glyph(rune(0x07CF)), 'NKo covers NKO LETTER OO'
	assert !nk.has_glyph(rune(0x0710)), 'NKo covers no Syriac'
	assert !nk.has_glyph(rune(0x0780)), 'NKo covers no Thaana'
	assert !nk.has_glyph(rune(0x0628)), 'NKo covers no Arabic'
}

fn longtail_line(f &shape.Font, text string) layout.Line {
	return longtail_line_in(f, text, '', '')
}

// longtail_line_in lays one line out under an explicit script/language
// override. The default is auto-detect, which is what the smoke tests use;
// the override is there for the same reason as in seasian_test.v: to name
// the table the HarfBuzz pins were measured under when detection is not
// what is tested.
fn longtail_line_in(f &shape.Font, text string, script string, lang string) layout.Line {
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	mut opts := layout.LayoutOptions{}
	opts.script = script
	opts.language = lang
	return layout.layout_paragraph_with(ctx, text.runes(), .auto, fs, 32.0, &opts)
}

fn test_longtail_shape_syriac() {
	// HarfBuzz shapes SHIN LAMADH MIM ALAPH ("peace") as four glyphs in
	// visual order: ALAPH fina.wideX 0x104 at advance 986, MIM medi 0x40 at
	// 836, LAMADH medi 0x3c at 338, SHIN init 0x65 at 739. The engine draws
	// the same four gids under their own clusters with positive advances;
	// the wideX fina and the medi forms pick the joining lookups, which is
	// the acceptance of this wave.
	sy := longtail_font('NotoSansSyriac-Variable.ttf') or { return }
	shlama := longtail_word([rune(0x072B), rune(0x0720), rune(0x0721), rune(0x0710)])
	line := longtail_line(sy, shlama)
	assert line.glyphs.len == 4, 'peace draws four letters, got ${longtail_dump(line)}'
	assert line.width > 0, 'a Syriac word has positive width'
	want := [u16(0x65), 0x3c, 0x40, 0x104]
	for i in 0 .. want.len {
		g := longtail_at(line.glyphs, i) or {
			panic('syriac input ${i} drew nothing: ${longtail_dump(line)}')
		}
		assert g.gid == want[i], 'syriac cluster ${i} is ${want[i]:x}, got ${g.gid:x}: ${longtail_dump(line)}'
		assert g.advance > 0, 'a Syriac letter moves the pen'
		assert g.gid != 0, 'no .notdef in a covered Syriac line'
	}
	// The joining-form check beside HarfBuzz: SHIN alone is isolated (the
	// cmap gid 0x62, which HarfBuzz also reports for a lone SHIN), while
	// word-initial SHIN is 0x65. Same letter, different position,
	// different glyph: the join ran.
	alone := longtail_line(sy, longtail_word([rune(0x072B)]))
	assert alone.glyphs.len == 1, 'a lone SHIN is one glyph, got ${longtail_dump(alone)}'
	assert alone.glyphs[0].gid == 0x62, 'lone SHIN is isolated 0x62, got ${alone.glyphs[0].gid:x}'
	assert alone.glyphs[0].gid != 0x65, 'lone SHIN is not the initial form'
}

fn test_longtail_shape_thaana() {
	// HarfBuzz shapes the "Dhivehi" word (DHAALU IBIFILI VAAVU EBEFILI HAA
	// IBIFILI) as six glyphs: the three consonant bases (dhaalu 0x0d at
	// 517, vaavu 0x0a at 424, haa 0x02 at 312) each paired with its fili
	// mark (ibifili 0x63, ebefil 0x67) at zero advance with a GPOS mark
	// offset, the marks merged onto their bases clusters. The engine draws
	// the same six gids with the same advances and offsets under honest
	// per-input clusters, the known post-base convention: the fili are
	// ccc=0 marks the class gate used to swallow, and the Cf gate lets
	// them attach. At 32 px the marks sit
	// at -2.62, +14.78 and +24.70 past bases at 0, 9.98 and 23.55 — HB's
	// -82, +150 and +36 design units, y exact too.
	th := longtail_font('NotoSansThaana-Variable.ttf') or { return }
	dhivehi := longtail_word([rune(0x078B), rune(0x07A8), rune(0x0788), rune(0x07AC), rune(0x0780),
		rune(0x07A8)])
	line := longtail_line(th, dhivehi)
	assert line.glyphs.len == 6, 'dhivehi draws three bases and three fili, got ${longtail_dump(line)}'
	assert line.width > 0, 'a Thaana word has positive width'
	want := [u16(0x63), 0x02, 0x67, 0x0a, 0x63, 0x0d]
	clusters := [5, 4, 3, 2, 1, 0]
	for i in 0 .. clusters.len {
		g := longtail_at(line.glyphs, clusters[i]) or {
			panic('thaana input ${clusters[i]} drew nothing: ${longtail_dump(line)}')
		}
		assert g.gid == want[i], 'thaana cluster ${clusters[i]} is ${want[i]:x}, got ${g.gid:x}: ${longtail_dump(line)}'
		assert g.gid != 0, 'no .notdef in a covered Thaana line'
	}
	fili5 := longtail_at(line.glyphs, 5) or { panic('thaana fili drew nothing') }
	assert fili5.is_mark && fili5.advance == 0, 'ibifili is a mark advancing nothing'
	assert fili5.x > -2.68 && fili5.x < -2.56, 'ibifili sits 82 design units off its base, got x=${fili5.x}'
	fili3 := longtail_at(line.glyphs, 3) or { panic('thaana ebefil drew nothing') }
	assert fili3.is_mark && fili3.advance == 0, 'ebefili is a mark advancing nothing'
	assert fili3.x > 14.72 && fili3.x < 14.84, 'ebefili sits 150 design units off its base, got x=${fili3.x}'
	fili1 := longtail_at(line.glyphs, 1) or { panic('thaana second ibifili drew nothing') }
	assert fili1.is_mark && fili1.advance == 0, 'the second ibifili is a mark advancing nothing'
	assert fili1.x > 24.64 && fili1.x < 24.76, 'ibifili sits 36 design units off its base, got x=${fili1.x}'
}

fn test_longtail_shape_nko() {
	// HarfBuzz shapes N KA OO ("I say") as three glyphs in visual order: OO
	// fina 0x52 at 551, KA medi 0x80 at 544, N init 0x5d at 685. NKo letters
	// are dual joining (UCD joining type D), so the joining pass assigns
	// the same initial/medial/final forms the font's lookups are masked on;
	// the run used to resolve under the Unicode script tag 'Nkoo', which
	// lowercases to 'nkoo', while the font files its NKo rules under the
	// OpenType tag 'nko ' (trailing space) — so the script lookup missed,
	// no joining lookup ran, and the engine drew the three unfolded cmap
	// glyphs. The tag fold is fixed: the default line now draws exactly
	// HarfBuzz's three fused glyphs, and the explicit 'nko ' override draws
	// the same three, proving the fold rather than the override.
	nk := longtail_font('NotoSansNKo-Regular.ttf') or { return }
	nko := longtail_word([rune(0x07D2), rune(0x07DE), rune(0x07CF)])
	line := longtail_line(nk, nko)
	assert line.glyphs.len == 3, 'the NKo word draws three fused letters, got ${longtail_dump(line)}'
	assert line.width > 0, 'an NKo word has positive width'
	want := [u16(0x5d), 0x80, 0x52]
	for i in 0 .. want.len {
		g := longtail_at(line.glyphs, i) or {
			panic('nko input ${i} drew nothing: ${longtail_dump(line)}')
		}
		assert g.gid == want[i], 'nko cluster ${i} is ${want[i]:x}, got ${g.gid:x}: ${longtail_dump(line)}'
		assert g.advance > 0, 'a fused NKo letter moves the pen'
		assert g.gid != 0, 'no .notdef in a covered NKo line'
	}
	fused := longtail_line_in(nk, nko, 'nko ', '')
	assert fused.glyphs.len == 3, 'the NKo word under its own table is three glyphs, got ${longtail_dump(fused)}'
	fused_want := [u16(0x5d), 0x80, 0x52]
	for i in 0 .. fused_want.len {
		g := longtail_at(fused.glyphs, i) or {
			panic('nko table input ${i} drew nothing: ${longtail_dump(fused)}')
		}
		assert g.gid == fused_want[i], 'nko table cluster ${i} is ${fused_want[i]:x}, got ${g.gid:x}: ${longtail_dump(fused)}'
		assert g.advance > 0, 'a fused NKo letter moves the pen'
	}
	alone := longtail_line(nk, longtail_word([rune(0x07D2)]))
	assert alone.glyphs.len == 1, 'a lone NKo N is one glyph, got ${longtail_dump(alone)}'
	assert alone.glyphs[0].gid == 0x1a, 'lone N is isolated 0x1a, got ${alone.glyphs[0].gid:x}'
	assert alone.glyphs[0].gid != 0x5d, 'lone N is not the initial form'
}

fn test_longtail_draw_bases() {
	// One rasterised base consonant per script: a face that shapes but never
	// inks is a face the test cannot see.
	sy := longtail_font('NotoSansSyriac-Variable.ttf') or { return }
	shin := sy.rasterize(sy.glyph_index(rune(0x072B)), 32.0, 0, 0)
	assert !shin.is_empty(), 'SHIN rasterises'
	th := longtail_font('NotoSansThaana-Variable.ttf') or { return }
	haa := th.rasterize(th.glyph_index(rune(0x0780)), 32.0, 0, 0)
	assert !haa.is_empty(), 'HAA rasterises'
	nk := longtail_font('NotoSansNKo-Regular.ttf') or { return }
	na := nk.rasterize(nk.glyph_index(rune(0x07C0)), 32.0, 0, 0)
	assert !na.is_empty(), 'NKO A rasterises'
}

fn test_longtail_pins_are_live() {
	// Break-fix control: the SHIN init pin is exact, so the neighbouring
	// gid must not match. If shaping ever drifts, the smoke pins above fail;
	// if this control fails, the pins stopped discriminating.
	sy := longtail_font('NotoSansSyriac-Variable.ttf') or { return }
	shlama := longtail_word([rune(0x072B), rune(0x0720), rune(0x0721), rune(0x0710)])
	line := longtail_line(sy, shlama)
	shin := longtail_at(line.glyphs, 0) or { panic('the control needs a shaped line') }
	assert shin.gid == 0x65, 'the SHIN init pin still holds'
	assert shin.gid != 0x66, 'off-by-one gid must not match: the pin is exact'
}
