module main

import os
import vtext.shape
import vtext.raster

// Synthetic styles and LCD: box growth, pixel parity, triple-width shape.
//
// The pins below are this engine's own outputs, exact, so any change in the
// transforms fails loudly. The FreeType numbers beside them were measured
// with freetype-py at 32 px without hinting: plain render, then
// FT_GlyphSlot_Embolden or FT_GlyphSlot_Oblique, then a normal render, and
// for LCD a target-LCD load with an LCD render. FreeType bitmap_left uses
// the opposite sign to this module's left: its -1 is our +1, the ink sitting
// one pixel left of the pen either way. Widths and heights below are pixels,
// sums are total 8-bit coverage.
//
// Amiri at 32 px, plain then emboldened then oblique, FreeType says:
// A: 21x22 l-1 t21 s25009 then 23x24 l-1 t23 s42903 then 21x22 l-1 t21 s25019
// e: 12x15 l1 t14 s15907 then 13x17 l1 t16 s27815 then 13x15 l2 t14 s15922
// m: 25x15 l0 t14 s32757 then 26x17 l0 t16 s55675 then 25x15 l0 t14 s32735
// SourceSans e: 14x17 l1 t16 s25665 then 15x19 l1 t18 s39862 then 16x17 l2 t16 s25729
// LCD Amiri A: 66 wide with 22 rows, l-1 t21, sum 75004 against 75027.

const em_px = 32.0

// corpus_font_path finds a test font: the caller's override first, the
// committed corpus second, the platform directory last.
fn corpus_font_path(name string) string {
	mut dirs := []string{}
	e := os.getenv('VTEXT_TEST_FONTS')
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

// load_corpus_font loads a corpus font, or none when no directory has it.
fn load_corpus_font(name string) ?&shape.Font {
	p := corpus_font_path(name)
	if p == '' {
		return none
	}
	return shape.load_font_file(p) or { panic('unreadable font file ' + p) }
}

// ink_sum totals the coverage of a gray bitmap.
fn ink_sum(b raster.GlyphBitmap) u64 {
	mut acc := u64(0)
	for v in b.coverage {
		acc += u64(v)
	}
	return acc
}

// bitmaps_equal reports whether two gray bitmaps match pixel for pixel.
fn bitmaps_equal(a raster.GlyphBitmap, b raster.GlyphBitmap) bool {
	if a.width != b.width || a.height != b.height || a.left != b.left || a.top != b.top {
		return false
	}
	if a.coverage.len != b.coverage.len {
		return false
	}
	for i in 0 .. a.coverage.len {
		if a.coverage[i] != b.coverage[i] {
			return false
		}
	}
	return true
}

// The zero options are the identity: the same input with options unset is the
// current output, pixel for pixel, with no LCD buffer built.
fn test_synth_defaults_off_is_identity() {
	f := load_corpus_font('Amiri-Regular.ttf') or { return }
	for code in [u8(65), u8(101), u8(109)] {
		gid := f.glyph_index(rune(code))
		plain := f.rasterize(gid, em_px, 0, 0)
		assert !plain.is_empty()
		assert bitmaps_equal(raster.apply_synth(plain, raster.SynthOptions{}), plain)
		out := raster.render_with_options(plain, raster.RenderOptions{})
		assert bitmaps_equal(out.gray, plain)
		assert !out.has_lcd
		assert out.lcd.is_empty()
		box := f.face.box_only(gid, em_px)
		assert box.coverage.len == 0
		styled_box := raster.apply_synth(box, raster.SynthOptions{})
		assert styled_box.coverage.len == 0
		assert styled_box.width == box.width
		assert styled_box.height == box.height
		assert styled_box.left == box.left
		assert styled_box.top == box.top
		assert raster.to_lcd(box).is_empty()
	}
}

// Embolden grows the box by the strength radius on every side. Heights land
// exactly on the FreeType heights; widths land on the FreeType width or one
// column past it, symmetric bitmap growth against outline rounding.
fn test_embolden_grows_box() {
	f := load_corpus_font('Amiri-Regular.ttf') or { return }
	g := load_corpus_font('SourceSans3-Regular.otf') or { return }
	opt := raster.SynthOptions{ embolden: true, em_px: em_px }
	fonts := [f, f, f, g]
	codes := [u8(65), u8(101), u8(109), u8(101)]
	want_w := [23, 14, 27, 16]
	want_h := [24, 17, 17, 19]
	want_l := [2, 0, 1, 0]
	want_t := [22, 15, 15, 17]
	ft_w := [23, 13, 26, 15]
	ft_h := [24, 17, 17, 19]
	for i in 0 .. 4 {
		gid := fonts[i].glyph_index(rune(codes[i]))
		emb := raster.apply_synth(fonts[i].rasterize(gid, em_px, 0, 0), opt)
		assert emb.width == want_w[i]
		assert emb.height == want_h[i]
		assert emb.left == want_l[i]
		assert emb.top == want_t[i]
		assert emb.height == ft_h[i]
		assert emb.width == ft_w[i] || emb.width == ft_w[i] + 1
	}
}

// Embolden roughly doubles the ink here, the way FreeType's own embolden
// lifts these glyphs by 1.55 to 1.75: the same direction, the same order,
// the bitmap dilation overshooting the outline expansion by under half.
fn test_embolden_pixel_parity() {
	f := load_corpus_font('Amiri-Regular.ttf') or { return }
	g := load_corpus_font('SourceSans3-Regular.otf') or { return }
	opt := raster.SynthOptions{ embolden: true, em_px: em_px }
	fonts := [f, f, f, g]
	codes := [u8(65), u8(101), u8(109), u8(101)]
	want_plain := [u64(25051), u64(15629), u64(32659), u64(25947)]
	want_emb := [u64(57150), u64(36909), u64(69831), u64(52360)]
	for i in 0 .. 4 {
		gid := fonts[i].glyph_index(rune(codes[i]))
		plain := fonts[i].rasterize(gid, em_px, 0, 0)
		assert ink_sum(plain) == want_plain[i]
		emb := raster.apply_synth(plain, opt)
		assert ink_sum(emb) == want_emb[i]
		ratio := f64(ink_sum(emb)) / f64(ink_sum(plain))
		assert ratio >= 1.5 && ratio <= 2.5
	}
}

// Oblique shears about the baseline and keeps the ink: rows stay, heights
// match FreeType exactly, widths land within two columns of its
// sheared-outline box, and the total moves by a fraction of a percent the
// way its totals move by a quarter of a percent at most.
fn test_oblique_box_and_parity() {
	f := load_corpus_font('Amiri-Regular.ttf') or { return }
	g := load_corpus_font('SourceSans3-Regular.otf') or { return }
	opt := raster.SynthOptions{ oblique: true, em_px: em_px }
	fonts := [f, f, f, g]
	codes := [u8(65), u8(101), u8(109), u8(101)]
	want_w := [22, 15, 25, 16]
	want_h := [22, 15, 15, 17]
	want_l := [1, -1, -1, -2]
	want_t := [21, 14, 14, 16]
	want_sum := [u64(25048), u64(15629), u64(32657), u64(25943)]
	ft_w := [21, 13, 25, 16]
	ft_h := [22, 15, 15, 17]
	for i in 0 .. 4 {
		gid := fonts[i].glyph_index(rune(codes[i]))
		plain := fonts[i].rasterize(gid, em_px, 0, 0)
		obl := raster.apply_synth(plain, opt)
		assert obl.width == want_w[i]
		assert obl.height == want_h[i]
		assert obl.left == want_l[i]
		assert obl.top == want_t[i]
		assert obl.top == plain.top
		assert obl.height == ft_h[i]
		assert obl.width >= ft_w[i] && obl.width <= ft_w[i] + 2
		assert ink_sum(obl) == want_sum[i]
		ps := ink_sum(plain)
		d := if ink_sum(obl) > ps { ink_sum(obl) - ps } else { ps - ink_sum(obl) }
		assert d * 100 <= ps
	}
}

// LCD triples the columns and keeps the energy: green repeats the gray, the
// total is three times the gray total, and FreeType's own LCD total tracks
// three times its gray total the same way (75004 against 3x25009). Its box
// is one spill column wider than ours, the FIR filter's doing, documented
// as a follow-up rather than copied here.
fn test_lcd_triple_width_and_energy() {
	f := load_corpus_font('Amiri-Regular.ttf') or { return }
	gid := f.glyph_index(rune(u8(65)))
	plain := f.rasterize(gid, em_px, 0, 0)
	assert ink_sum(plain) == 25051
	lcd := raster.to_lcd(plain)
	assert lcd.width == plain.width * 3
	assert lcd.width == 63
	assert lcd.height == plain.height
	assert lcd.left == plain.left
	assert lcd.top == plain.top
	assert lcd.ink_sum() == 75153
	assert lcd.channel_sum(0) == 25024
	assert lcd.channel_sum(1) == 25051
	assert lcd.channel_sum(2) == 25078
	assert lcd.channel_sum(1) == ink_sum(plain)
	assert lcd.channel_sum(0) != lcd.channel_sum(1)
	assert lcd.channel(3, 5, 1) == plain.ink(3, 5)
	total := lcd.ink_sum()
	ps := ink_sum(plain)
	assert total * 100 >= ps * 299
	assert total * 100 <= ps * 301
	styled := raster.apply_synth(plain, raster.SynthOptions{ embolden: true, em_px: em_px })
	out := raster.render_with_options(plain, raster.RenderOptions{ lcd: true, synth: raster.SynthOptions{ embolden: true, em_px: em_px } })
	assert out.has_lcd
	assert bitmaps_equal(out.gray, styled)
	assert out.lcd.width == out.gray.width * 3
	assert out.lcd.height == out.gray.height
}

// The break-fix control: with the strength zeroed the embolden collapses to
// the plain bitmap, and with the slant dropped the shear never happens, so
// every pin above fails on these outputs. If this stops failing, the pins
// no longer prove the strengths do anything.
fn test_synth_zeroed_strength_fails_parity() {
	f := load_corpus_font('Amiri-Regular.ttf') or { return }
	gid_a := f.glyph_index(rune(u8(65)))
	pa := f.rasterize(gid_a, em_px, 0, 0)
	weak := raster.embolden_bitmap(pa, 0)
	assert bitmaps_equal(weak, pa)
	assert weak.width != 23
	assert weak.height != 24
	assert ink_sum(weak) * 10 < ink_sum(pa) * 15
	weak2 := raster.apply_synth(pa, raster.SynthOptions{ embolden: true, em_px: 0 })
	assert bitmaps_equal(weak2, pa)
	gid_e := f.glyph_index(rune(u8(101)))
	pe := f.rasterize(gid_e, em_px, 0, 0)
	flat := raster.oblique_bitmap(pe, 0)
	assert bitmaps_equal(flat, pe)
	assert flat.width != 15
	emb_only := raster.apply_synth(pe, raster.SynthOptions{ embolden: true, em_px: em_px })
	assert emb_only.width != 15
}
