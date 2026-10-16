module main

// shapedump prints one shaped run as tab-separated values for the differential suite.
//
// tools/shapetrace.v prints the same pipeline for a human; this prints it for tools/difftest,
// which compares it glyph by glyph against HarfBuzz. Text goes in as hex codepoints rather than
// as a string so that no shell, editor or terminal ever has to carry right-to-left text
// correctly for the comparison to mean anything:
//
//	v run tools/shapedump.v testdata/fonts/Amiri-Regular.ttf --cps 0633 0644 0627 0645 --size 32 --dir rtl
//
// Output, one glyph per line after the header comment lines:
//
//	gid  x_adv  x_off  y_off  cluster  is_mark  font  left  top  width  height  inksum
//
// x_adv is the pen advance in design units, x_off/y_off the glyph's offset from the pen in design
// units (y positive up, HarfBuzz sign), cluster the input character index, is_mark 0/1, font the
// file that drew it. Design units rather than pixels so that a size-rounding choice in either
// engine cannot fail the comparison: both sides scale from the same units-per-em.
//
// left/top/width/height/inksum are the rasterized ink box in pixels at the requested size and the
// sum of its coverage bytes. They exist so the comparator can check the rasterizer against
// FreeType without a second program: same glyph, same size, two independent implementations of
// the same scanline fill. A mark reports the box of its own outline at its placed offset.

import os
import vtext

fn main() {
	mut font_path := ''
	mut cps_hex := []string{}
	mut size := 32.0
	mut dir := 'rtl'
	mut i := 1
	args := os.args
	for i < args.len {
		a := args[i]
		if a == '--cps' {
			i++
			for i < args.len && !args[i].starts_with('--') {
				cps_hex << args[i]
				i++
			}
		} else if a == '--size' {
			i++
			size = args[i].f64()
			i++
		} else if a == '--dir' {
			i++
			dir = args[i]
			i++
		} else if font_path == '' && !a.starts_with('--') {
			font_path = a
			i++
		} else {
			i++
		}
	}
	if font_path == '' || cps_hex.len == 0 {
		eprintln('usage: v run tools/shapedump.v <font.ttf> --cps 0633 0644 0627 0645 [--size 32] [--dir rtl]')
		exit(1)
	}
	mut cps := []rune{cap: cps_hex.len}
	for h in cps_hex {
		cps << rune(hex_word(h))
	}
	f := vtext.load_font_file(font_path) or { panic('cannot open ${font_path}: ${err}') }
	fs := vtext.new_font_set_of(f)
	ctx := vtext.new_context()
	base := if dir == 'ltr' { vtext.Direction.ltr } else if dir == 'rtl' { vtext.Direction.rtl } else { vtext.Direction.auto }
	line := vtext.layout_paragraph(ctx, cps, base, fs, size)
	upem := f64(f.units_per_em())
	mut pen := 0.0
	println('# font=${font_path} size=${size} dir=${dir} nchars=${cps.len} upem=${upem}')
	println('# gid\tx_adv\tx_off\ty_off\tcluster\tis_mark\tfont\tleft\ttop\twidth\theight\tinksum')
	for g in line.glyphs {
		x_off := (g.x - pen) / size * upem
		pen += g.advance
		x_adv := g.advance / size * upem
		// HarfBuzz sign for y: positive up. vtext stores y positive down from the baseline,
		// so the sign flips here rather than in the comparator.
		y_off := -g.y / size * upem
		mark := if g.is_mark { 1 } else { 0 }
		fname := if ff := g.font { ff.path() } else { '' }
		// The glyph's own font, not the requested one: a fallback chain draws from
		// several files and the box belongs to the outline that was read.
		bm := if gf := g.font {
			gf.rasterize(g.gid, size, 0, 0)
		} else {
			vtext.GlyphBitmap{}
		}
		mut ink := 0
		for v in bm.coverage {
			ink += int(v)
		}
		println('${g.gid}\t${x_adv:.2f}\t${x_off:.2f}\t${y_off:.2f}\t${g.cluster}\t${mark}\t${fname}\t${bm.left}\t${bm.top}\t${bm.width}\t${bm.height}\t${ink}')
	}
	println('# width_px=${line.width:.3f}')
}

fn hex_word(w string) int {
	mut v := 0
	for ch in w {
		mut d := ch - `0`
		if d > 9 {
			d = ch - `a` + 10
		}
		if d > 15 {
			d = ch - `A` + 10
		}
		v = v * 16 + int(d)
	}
	return v
}
