module harfara

import os
import harfara.shape
import harfara.layout

// Tests for the rest of the simple alphabets: Georgian, Armenian and
// Ethiopic. Every gid, advance and cluster below was read off HarfBuzz
// (uharfbuzz, scale 1000 = font units, every face here is upm 1000) and
// fontTools before it was written here; agreement with a second reader is
// the evidence. Input clusters double as pins: a cluster is an input
// position, so the glyph reporting cluster 2 names no engine output of its
// own.
//
// The three faces ship in testdata/fonts with their OFL texts, so they load
// on every platform with no skips: no host font, no platform directory.
// Each is a variable face taken from google/fonts main; all three sit well
// under the wave ceiling.
//
// These scripts need no shaping machinery: each letter draws its cmap glyph
// with its hmtx advance, in order, with no substitution. That is the whole
// pin — a letter that ever needs more belongs to an engine slice, not to a
// corpus wave. The engine gaps of the neighbouring waves do not recur here:
// no join controls, no coeng, no transparent-class marks.
//
// The emoji survey closes 9.4 with them: no committed face carries a color
// table (COLR/CPAL/CBDT/CBLC/sbix/SVG — scanned, not assumed), and the
// monochrome smiley U+263A that FiraCode covers shapes from its cmap beside
// HarfBuzz and rasterizes. A colour table the engine cannot use stays what
// shape/inspect.v already calls it: a fact about the font, not a promise
// about the output. Colour engines are 7.7, not this slice.

fn simple_font_path(name string) ?string {
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

fn simple_font(name string) ?&shape.Font {
	p := simple_font_path(name) or { return none }
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

// simple_at returns the glyph that came from the input character at that
// index, or none when the character drew nothing.
fn simple_at(glyphs []shape.Glyph, cluster int) ?shape.Glyph {
	for g in glyphs {
		if g.cluster == cluster {
			return g
		}
	}
	return none
}

// simple_dump renders a line as gid:cluster:advance cells so a failing pin
// shows the whole engine answer in the message.
fn simple_dump(line layout.Line) string {
	mut parts := []string{cap: line.glyphs.len}
	for g in line.glyphs {
		parts << '${g.gid:x}:${g.cluster}:${g.advance:.2f}'
	}
	return '[' + parts.join(' ') + ']'
}

// simple_word builds a test word from codepoints, keeping this file ASCII.
fn simple_word(cps []rune) []rune {
	return cps.clone()
}

fn simple_line(f &shape.Font, text []rune) layout.Line {
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	mut opts := layout.LayoutOptions{}
	return layout.layout_paragraph_with(ctx, text, .auto, fs, 32.0, &opts)
}

fn test_simple_fonts_load() {
	ge := simple_font('NotoSansGeorgian-Variable.ttf') or {
		panic('NotoSansGeorgian-Variable.ttf is not in testdata/fonts')
	}
	assert ge.num_glyphs() == 554, 'Georgian has 554 glyphs, got ${ge.num_glyphs()}'
	assert ge.units_per_em() == 1000, 'Georgian is upm 1000'
	ar := simple_font('NotoSansArmenian-Variable.ttf') or {
		panic('NotoSansArmenian-Variable.ttf is not in testdata/fonts')
	}
	assert ar.num_glyphs() == 436, 'Armenian has 436 glyphs, got ${ar.num_glyphs()}'
	assert ar.units_per_em() == 1000, 'Armenian is upm 1000'
	et := simple_font('NotoSansEthiopic-Variable.ttf') or {
		panic('NotoSansEthiopic-Variable.ttf is not in testdata/fonts')
	}
	assert et.num_glyphs() == 925, 'Ethiopic has 925 glyphs, got ${et.num_glyphs()}'
	assert et.units_per_em() == 1000, 'Ethiopic is upm 1000'
}

fn test_simple_fonts_cover_what_they_claim() {
	// fontTools cmap: each face covers Latin plus its own script, and none
	// of the other two simple scripts (nor Arabic, Devanagari or Thai).
	ge := simple_font('NotoSansGeorgian-Variable.ttf') or { return }
	assert ge.has_glyph(`A`), 'Georgian covers Latin'
	assert ge.has_glyph(rune(0x10D2)), 'Georgian covers GEORGIAN LETTER BAN'
	assert ge.has_glyph(rune(0x10E8)), 'Georgian covers GEORGIAN LETTER NAR'
	assert !ge.has_glyph(rune(0x0531)), 'Georgian covers no Armenian'
	assert !ge.has_glyph(rune(0x1200)), 'Georgian covers no Ethiopic'
	assert !ge.has_glyph(rune(0x0628)), 'Georgian covers no Arabic'
	assert !ge.has_glyph(rune(0x0915)), 'Georgian covers no Devanagari'
	ar := simple_font('NotoSansArmenian-Variable.ttf') or { return }
	assert ar.has_glyph(`A`), 'Armenian covers Latin'
	assert ar.has_glyph(rune(0x0531)), 'Armenian covers ARMENIAN CAPITAL LETTER AYB'
	assert ar.has_glyph(rune(0x0587)), 'Armenian covers ARMENIAN SMALL LETTER LIGATURE ECH YIWN'
	assert !ar.has_glyph(rune(0x10D2)), 'Armenian covers no Georgian'
	assert !ar.has_glyph(rune(0x1200)), 'Armenian covers no Ethiopic'
	assert !ar.has_glyph(rune(0x0628)), 'Armenian covers no Arabic'
	et := simple_font('NotoSansEthiopic-Variable.ttf') or { return }
	assert et.has_glyph(`A`), 'Ethiopic covers Latin'
	assert et.has_glyph(rune(0x1200)), 'Ethiopic covers ETHIOPIC SYLLABLE HA'
	assert et.has_glyph(rune(0x1309)), 'Ethiopic covers ETHIOPIC SYLLABLE GU'
	assert !et.has_glyph(rune(0x0531)), 'Ethiopic covers no Armenian'
	assert !et.has_glyph(rune(0x10D2)), 'Ethiopic covers no Georgian'
	assert !et.has_glyph(rune(0x0628)), 'Ethiopic covers no Arabic'
	assert !et.has_glyph(rune(0x0E01)), 'Ethiopic covers no Thai'
}

fn test_simple_georgian_hello_matches_harfbuzz() {
	// HarfBuzz shapes "gamarjoba" as nine glyphs in order with no
	// substitution (cmap gids equal shaped gids): BAN 0x8a at advance 576,
	// AN 0x70 at 549, MAN 0xac at 605, AN at 549, NAR 0xc0 at 792, ON 0x9f
	// at 567, DIL 0xb2 at 804, LAS 0x76 at 606, AN at 549. The engine draws
	// the same nine gids under their own clusters with the same advances.
	f := simple_font('NotoSansGeorgian-Variable.ttf') or { return }
	line := simple_line(f, simple_word([rune(0x10D2), rune(0x10D0), rune(0x10DB), rune(0x10D0),
		rune(0x10E0), rune(0x10EF), rune(0x10DD), rune(0x10D1), rune(0x10D0)]))
	assert line.glyphs.len == 9, 'gamarjoba draws nine letters, got ${simple_dump(line)}'
	want := [u16(0x8a), 0x70, 0xac, 0x70, 0xc0, 0x9f, 0xb2, 0x76, 0x70]
	advances := [18.432, 17.568, 19.36, 17.568, 25.344, 18.144, 25.728, 19.392, 17.568]
	for i in 0 .. want.len {
		g := simple_at(line.glyphs, i) or { panic('gamarjoba input ${i} drew nothing: ${simple_dump(line)}') }
		assert g.gid == want[i], 'gamarjoba cluster ${i} is ${want[i]:x}, got ${g.gid:x}: ${simple_dump(line)}'
		assert g.advance > advances[i] - 0.06 && g.advance < advances[i] + 0.06, 'gamarjoba cluster ${i} advances ${advances[i]}'
		assert g.gid != 0, 'no .notdef in a covered gamarjoba line'
	}
}

fn test_simple_armenian_hello_matches_harfbuzz() {
	// HarfBuzz shapes "barev" as five glyphs in order with no
	// substitution: BEN 0x38 at 597, AYB 0x37 at 920, RA 0x57 at 597,
	// ECH 0x3b at 597, VEW 0x59 at 321. Same agreement as Georgian.
	f := simple_font('NotoSansArmenian-Variable.ttf') or { return }
	line := simple_line(f, simple_word([rune(0x0562), rune(0x0561), rune(0x0580), rune(0x0565),
		rune(0x0582)]))
	assert line.glyphs.len == 5, 'barev draws five letters, got ${simple_dump(line)}'
	want := [u16(0x38), 0x37, 0x57, 0x3b, 0x59]
	advances := [19.104, 29.44, 19.104, 19.104, 10.272]
	for i in 0 .. want.len {
		g := simple_at(line.glyphs, i) or { panic('barev input ${i} drew nothing: ${simple_dump(line)}') }
		assert g.gid == want[i], 'barev cluster ${i} is ${want[i]:x}, got ${g.gid:x}: ${simple_dump(line)}'
		assert g.advance > advances[i] - 0.06 && g.advance < advances[i] + 0.06, 'barev cluster ${i} advances ${advances[i]}'
		assert g.gid != 0, 'no .notdef in a covered barev line'
	}
}

fn test_simple_ethiopic_hello_matches_harfbuzz() {
	// HarfBuzz shapes "selam" as three glyphs in order with no
	// substitution: SE 0x3b at 618, LA 0x17 at 519, ME 0x28 at 872.
	f := simple_font('NotoSansEthiopic-Variable.ttf') or { return }
	line := simple_line(f, simple_word([rune(0x1230), rune(0x120B), rune(0x121D)]))
	assert line.glyphs.len == 3, 'selam draws three letters, got ${simple_dump(line)}'
	want := [u16(0x3b), 0x17, 0x28]
	advances := [19.776, 16.608, 27.904]
	for i in 0 .. want.len {
		g := simple_at(line.glyphs, i) or { panic('selam input ${i} drew nothing: ${simple_dump(line)}') }
		assert g.gid == want[i], 'selam cluster ${i} is ${want[i]:x}, got ${g.gid:x}: ${simple_dump(line)}'
		assert g.advance > advances[i] - 0.06 && g.advance < advances[i] + 0.06, 'selam cluster ${i} advances ${advances[i]}'
		assert g.gid != 0, 'no .notdef in a covered selam line'
	}
}

fn test_simple_draw_bases() {
	// One rasterised base letter per face: a face that shapes but never
	// inks is a face the test cannot see.
	ge := simple_font('NotoSansGeorgian-Variable.ttf') or { return }
	ban := ge.rasterize(ge.glyph_index(rune(0x10D2)), 32.0, 0, 0)
	assert !ban.is_empty(), 'BAN rasterises'
	ar := simple_font('NotoSansArmenian-Variable.ttf') or { return }
	ayb := ar.rasterize(ar.glyph_index(rune(0x0531)), 32.0, 0, 0)
	assert !ayb.is_empty(), 'AYB rasterises'
	et := simple_font('NotoSansEthiopic-Variable.ttf') or { return }
	ha := et.rasterize(et.glyph_index(rune(0x1200)), 32.0, 0, 0)
	assert !ha.is_empty(), 'HA rasterises'
}

fn test_simple_emoji_survey() {
	// The survey half of this slice. No committed face carries a colour
	// table: COLR, CPAL, CBDT, CBLC, sbix and SVG are all absent from the
	// three new faces and from the smiley face below, which is the
	// no-presence half of "colour formats refuse with the reason" — there
	// is nothing to refuse on.
	for name in ['NotoSansGeorgian-Variable.ttf', 'NotoSansArmenian-Variable.ttf',
		'NotoSansEthiopic-Variable.ttf', 'FiraCode-Variable.ttf'] {
		f := simple_font(name) or { panic('${name} is not in testdata/fonts') }
		for tag in ['COLR', 'CPAL', 'CBDT', 'CBLC', 'sbix', 'SVG '] {
			assert !f.has_table(tag), '${name} carries no ${tag}'
		}
	}
	// The monochrome half: FiraCode covers the smiley U+263A, and it shapes
	// from its cmap beside HarfBuzz — gid 0x625 at advance 600, cluster 0 —
	// and rasterizes. Cmap monochrome ships; colour is 7.7.
	fc := simple_font('FiraCode-Variable.ttf') or { return }
	assert fc.has_glyph(rune(0x263A)), 'FiraCode covers the smiley'
	line := simple_line(fc, simple_word([rune(0x263A)]))
	assert line.glyphs.len == 1, 'the smiley draws one glyph, got ${simple_dump(line)}'
	g := simple_at(line.glyphs, 0) or { panic('the smiley drew nothing') }
	assert g.gid == 0x625, 'the smiley is the cmap gid 625, got ${simple_dump(line)}'
	assert g.advance > 19.14 && g.advance < 19.26, 'the smiley advances 600 design units'
	ink := fc.rasterize(g.gid, 32.0, 0, 0)
	assert !ink.is_empty(), 'the smiley rasterises'
}

fn test_simple_pins_are_live() {
	// Break-fix control: the gamarjoba first-letter pin is exact, so the
	// neighbouring gid must not match. If shaping ever drifts, the smoke
	// pins above fail; if this fails, the pins stopped discriminating.
	f := simple_font('NotoSansGeorgian-Variable.ttf') or { return }
	line := simple_line(f, simple_word([rune(0x10D2), rune(0x10D0)]))
	ban := simple_at(line.glyphs, 0) or { panic('the control needs a shaped line') }
	assert ban.gid == 0x8a, 'the BAN pin still holds'
	assert ban.gid != 0x8b, 'off-by-one gid must not match: the pin is exact'
}
