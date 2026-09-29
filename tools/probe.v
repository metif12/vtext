module main

// probe renders a string with the font layer and prints each glyph as ASCII
// art, so the ink box convention can be checked by eye against a real baseline.
//
// Usage: v run tools/probe.v [font] [text]

import os
import strings
import vtext

const ramps = [' ', '.', ':', '-', '=', '+', '*', '#', '%', '@']

fn arg(i int, fallback string) string {
	if i < os.args.len {
		return os.args[i]
	}
	return fallback
}

fn show(bmp &vtext.GlyphBitmap) {
	// Two pixel rows per text row keeps the shapes recognisable in a terminal.
	for y in 0 .. bmp.height {
		mut sb := strings.new_builder(bmp.width + 2)
		sb.write_string('|')
		for x in 0 .. bmp.width {
			mut v := int(bmp.ink(x, y))
			if y + 1 < bmp.height {
				v = (v + int(bmp.ink(x, y + 1))) / 2
			}
			sb.write_string(ramps[v * (ramps.len - 1) / 255])
		}
		sb.write_string('|')
		println(sb.str())
	}
	println('+- baseline ' + '-'.repeat(bmp.width) + '+')
}

fn main() {
	font_path := arg(1, 'C:\\Windows\\Fonts\\segoeui.ttf')
	text := arg(2, 'Av')
	em := 32.0

	mut font := vtext.load_font_file(font_path) or { panic(err) }
	println('font=${font_path}')
	println('upem=${font.units_per_em()} glyphs=${font.num_glyphs()} cff=${font.is_cff_outlined()}')
	println('ascent=${font.ascent(em):.1} descent=${font.descent(em):.1} line=${font.line_height(em):.1}')
	println('')

	mut pen := 0.0
	for cp in text.runes() {
		gid := font.glyph_index(cp)
		adv := font.glyph_advance(gid, em)
		if gid == 0 {
			println('U+${cp:04X} -> .notdef (no coverage)')
			continue
		}
		bmp := font.rasterize(gid, em, 0, 0)
		println('U+${cp:04X} glyph=${gid} adv=${adv:.1}px  ink=${bmp.width}x${bmp.height} left=${bmp.left} top=${bmp.top}')
		show(&bmp)
		pen += adv
	}
	println('total advance=${pen:.1}px')
}
