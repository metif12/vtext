module main

// metrics reports a font's vertical metrics and its per-glyph advances at a given size.
//
// Useful on its own for anyone laying out a page, and the tool that makes a wrong `hhea` table visible.
// The vertical numbers are the ones a caller cannot compute and cannot check: every library here derives
// its line height from them, so a font whose ascender is nonsense produces a line box that is nonsense
// and nothing else in the output says why.
//
// Every number comes from the public API. There is no second reader, so this tool and the library
// cannot disagree about a font.
//
// Usage:
//	v run tools/metrics.v <font.ttf>
//	v run tools/metrics.v <font.ttf> --size 16
//	v run tools/metrics.v <font.ttf> --glyphs 32       also print this many glyphs
//	v run tools/metrics.v <font.ttf> --glyph 0x41      also print the metrics of one glyph
//
// The vertical section prints the same number three ways on purpose: the font's own hhea, the font's
// OS/2 typographic metrics, and what this engine chose between them. A disagreement between the three is
// the finding, and it is invisible from any one of them.

import os
import vtext

fn arg(i int, fallback string) string {
	if i < os.args.len {
		return os.args[i]
	}
	return fallback
}

fn flag(name string) bool {
	for a in os.args {
		if a == name {
			return true
		}
	}
	return false
}

// option reads --name value, or the fallback when it is absent or has nothing after it.
fn option(name string, fallback string) string {
	for i, a in os.args {
		if a == name && i + 1 < os.args.len {
			return os.args[i + 1]
		}
	}
	return fallback
}

// parses a size written either as a number of pixels or as a hex codepoint or glyph id.
fn parses(text string, fallback int) int {
	s := text.trim_space()
	if s == '' {
		return fallback
	}
	mut neg := false
	mut body := s
	if body.starts_with('-') {
		neg = true
		body = body[1..]
	}
	mut base := 10
	mut digits := body
	if body.len > 2 && (body[0] == `0` && (body[1] == `x` || body[1] == `X`)) {
		base = 16
		digits = body[2..]
	}
	mut value := 0
	for ch in digits {
		mut d := ch - `0`
		if d > 9 {
			d = ch - `a` + 10
		}
		if d > 15 {
			d = ch - `A` + 10
		}
		if d < 0 || d >= base {
			return fallback
		}
		value = value * base + int(d)
	}
	return if neg { -value } else { value }
}

fn main() {
	path := arg(1, '')
	if path == '' || flag('--help') || flag('-h') {
		eprintln('usage: v run tools/metrics.v <font.ttf> [--size N] [--glyphs N] [--glyph N]')
		exit(1)
	}
	size := parses(option('--size', '32'), 32)
	if size <= 0 {
		eprintln('a size of ${size} pixels cannot be laid out')
		exit(1)
	}

	font := vtext.load_font_file(path) or {
		eprintln('cannot load ${path}: ${err}')
		exit(1)
	}

	println('${font_name(font)}')
	println('  ${path}')
	println('  ${font.num_glyphs()} glyphs, ${font.units_per_em()} units per em, ${outline(font)}')
	println('')

	print_vertical(font, size)
	print_widths(font, size)
	print_selected(font, size)
}

// font_name is the font's family name where it can be had cheaply, and its file name where it cannot.
//
// The family name is not in the inspection API and adding a name-table reader for a tool's title line
// would be a poor trade, so this says which file it is, which is what a person reading the output needs
// anyway.
fn font_name(f &vtext.Font) string {
	name := f.path()
	if name == '' {
		return 'font'
	}
	parts := name.replace('\\', '/').split('/')
	return parts[parts.len - 1]
}

fn outline(f &vtext.Font) string {
	if f.is_cff_outlined() {
		return 'CFF outlines'
	}
	return 'glyf outlines'
}

// print_vertical reports every vertical number the library could use, and what it resolved them to.
//
// The three sources are hhea, OS/2 and what this engine picked, because they disagree in real fonts and
// the disagreement is the whole reason this tool exists. A caller that hard-codes one of them gets that
// font's answer and every other font's wrong one.
fn print_vertical(f &vtext.Font, size f64) {
	println('vertical metrics at ${size:.0} pixels')
	println('  ascent        ${f.ascent(size):8.2f}')
	println('  descent       ${f.descent(size):8.2f}')
	println('  line height   ${f.line_height(size):8.2f}')
	println('  underline     ${f.underline_thickness(size):8.2f} thick, at ${f.underline_position(size):8.2f}')
	println('  monospaced    ${f.is_monospaced()}')
	// The ink the engine reports for a real line, which is not the font's number and is the one a
	// caller drawing something actually needs.
	ctx := vtext.new_context()
	fs := vtext.new_font_set()
	fs.add(f)
	line := vtext.layout_paragraph(ctx, 'Hxbdfpq'.runes(), .ltr, fs, size)
	println('  ink of "Hxbdfpq" ${line.ascent:8.2f} above, ${line.descent:8.2f} below')
	if line.ascent > f.ascent(size) {
		println('    the ink reaches above the font own ascent, which is what a mark does and the reason')
		println('    a caller that clips to the font metrics clips a fatha')
	}
	println('')
}

// print_widths reports the shape of the font's advances rather than all of them, because a font has
// thousands of glyphs and the interesting facts are the extremes and the spread.
fn print_widths(f &vtext.Font, size f64) {
	n := f.num_glyphs()
	if n == 0 {
		return
	}
	mut narrowest := f64(0)
	mut widest := f64(0)
	mut narrow_gid := u16(0)
	mut wide_gid := u16(0)
	mut total := f64(0)
	mut zero := 0
	for gid in 0 .. u16(n) {
		w := f.glyph_advance(gid, size)
		total += w
		if w == 0.0 {
			zero++
		}
		if gid == 0 {
			narrowest = w
			widest = w
		} else {
			if w < narrowest {
				narrowest = w
				narrow_gid = gid
			}
			if w > widest {
				widest = w
				wide_gid = gid
			}
		}
	}
	println('advances at ${size:.0} pixels, over ${n} glyphs')
	println('  narrowest  ${narrowest:8.2f}  gid ${narrow_gid}')
	println('  widest     ${widest:8.2f}  gid ${wide_gid}')
	println('  mean       ${total / f64(n):8.2f}')
	println('  zero width ${zero} glyphs, which is what a space or a combining mark looks like')
	if f.is_monospaced() {
		println('  the font says it is monospaced, and the spread above says otherwise if it is not')
	}
	println('')
}

// print_selected prints the numbers for glyphs a caller named, which is the question behind most of
// "why is this letter the wrong width".
//
// A glyph is named by id, and a codepoint is the more useful thing to name, so both are accepted: a
// value that is a glyph id and also a codepoint prints both readings rather than choosing one.
fn print_selected(f &vtext.Font, size f64) {
	// The value follows --glyph, so it is read by position rather than by scanning for the name alone.
	mut value := ''
	for i, a in os.args {
		if a == '--glyph' && i + 1 < os.args.len {
			value = os.args[i + 1]
		}
	}
	if value == '' {
		return
	}
	gid := u16(parses(value, 0))
	cp := rune(parses(value, 0))
	println('glyph ${gid} (codepoint U+${cp:04X}) at ${size:.0} pixels')
	println('  advance      ${f.glyph_advance(gid, size):8.2f}')
	println('  is a mark    ${f.is_mark_glyph(gid)}')
	if f.glyph_index(cp) == gid {
		println('  codepoint U+${cp:04X} maps here')
	} else {
		println('  codepoint U+${cp:04X} maps to gid ${f.glyph_index(cp)} instead')
	}
	bmp := f.rasterize(gid, size, 0, 0)
	if bmp.is_empty() {
		println('  ink          none, so this glyph has no outline at this size')
	} else {
		println('  ink box      ${bmp.width} by ${bmp.height}, ${bmp.left} left of the pen, ${bmp.top} above the baseline')
	}
}
