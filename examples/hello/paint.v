// The drawing half of this example: a grey canvas, glyphs, a PNG, and the two ways a V string can be
// turned into characters.
//
// It is here rather than in a shared module because a V program cannot import a module that is not on
// its module path, and making every example depend on a sibling directory to save forty lines of zlib
// is a worse trade than the forty lines. Each example has its own copy of this file, and the copies are
// kept identical on purpose.
module paint

import os
import math
import hash.crc32
import compress.zlib
import vtext

// How many subpixel units make one pixel.
//
// vtext's rasteriser counts a pixel in quarters, so a glyph's fractional x has to be scaled by this
// rather than by sixty-four. Sixty-fourths read as quarters is sixteen times too far, and every glyph
// lands up to sixteen pixels from where the layout put it.
pub const subpixel_units = 4.0

// Canvas is a plain 8-bit grey image. Text is drawn as coverage onto a light background, so one byte
// per pixel is enough and the PNG needs no colour type beyond grey.
pub struct Canvas {
pub mut:
	w      int
	h      int
	pixels []u8
}

// new_canvas makes a canvas filled with one grey level.
pub fn new_canvas(w int, h int, level u8) &Canvas {
	return &Canvas{
		w:      w
		h:      h
		pixels: []u8{len: w * h, init: level}
	}
}

// blend darkens one pixel by how much ink a glyph puts there.
//
// The arithmetic is coverage over the background rather than a set, because two glyphs can cover the
// same pixel: a mark lands on the letter under it, and drawing the letter second would erase the mark if
// drawing were a set.
pub fn (mut c Canvas) blend(x int, y int, coverage u8) {
	if x < 0 || y < 0 || x >= c.w || y >= c.h {
		return
	}
	bg := c.pixels[y * c.w + x]
	c.pixels[y * c.w + x] = bg - u8((bg * int(coverage) + 127) / 255)
}

// draw_glyph paints one laid out glyph with its pen at g.x on the given baseline.
//
// All of the positioning is the engine's: it has already chosen the glyph, decided where the pen goes,
// and placed any mark. This only asks the font for the glyph's pixels and puts them where they belong.
pub fn (mut c Canvas) draw_glyph(f &vtext.Font, g vtext.Glyph, baseline f64, em_px f64) {
	// The pen is at a fractional place and the rasteriser takes a subpixel offset in quarters of a
	// pixel, so the fractional part is handed over in those units and the whole pixel is dropped.
	sub_x := i32(math.round(f64(g.x - f64(int(g.x))) * subpixel_units))
	sub_y := i32(math.round(f64(g.y - f64(int(g.y))) * subpixel_units))
	bitmap := f.rasterize(g.gid, em_px, sub_x, sub_y)
	if bitmap.is_empty() {
		return
	}
	// The bitmap's ink box hangs off the pen by `left` and reaches `top` above the baseline, so the
	// pixel the bitmap's own (0, 0) belongs at is the pen moved left and down.
	origin_x := int(math.floor(g.x)) - bitmap.left
	origin_y := int(baseline) - bitmap.top + int(math.floor(g.y))
	for by in 0 .. bitmap.height {
		for bx in 0 .. bitmap.width {
			cov := bitmap.ink(bx, by)
			if cov > 0 {
				c.blend(origin_x + bx, origin_y + by, cov)
			}
		}
	}
}

// draw_line lays out one string and paints every glyph of it with the baseline at baseline.
pub fn (mut c Canvas) draw_line(fs &vtext.FontSet, ctx &vtext.Context, text string, baseline f64,
	em_px f64) {
	// A V string is a byte array, so iterating one yields UTF-8 bytes rather than characters: the two
	// bytes of U+0645 arrive as two runes and the text turns into Latin-1 noise. .runes() decodes.
	cps := text.runes()
	// .auto takes the direction from the first strong character, so one call lays out text of either
	// direction correctly and the caller does not have to know which is which.
	line := vtext.layout_paragraph(ctx, cps, .auto, fs, em_px)
	for g in line.glyphs {
		if f := g.font {
			c.draw_glyph(f, g, baseline, em_px)
		}
	}
}

// measure lays a string out without drawing it and reports the width, ascent and descent it needs.
//
// The engine is asked the same question twice when a caller sizes a canvas from a first layout and then
// draws it, which is a little wasteful and keeps the example to one code path.
pub fn measure(fs &vtext.FontSet, ctx &vtext.Context, text string, em_px f64) (int, f64, f64) {
	line := vtext.layout_paragraph(ctx, text.runes(), .auto, fs, em_px)
	return int(math.ceil(line.width)), line.ascent, line.descent
}

// rect draws an outline, which is what a debug view is made of.
pub fn (mut c Canvas) rect(x0 int, y0 int, x1 int, y1 int, level u8) {
	for x in min_val(x0, x1) .. max_val(x0, x1) {
		c.blend(x, y0, level)
		c.blend(x, y1, level)
	}
	for y in min_val(y0, y1) .. max_val(y0, y1) {
		c.blend(x0, y, level)
		c.blend(x1, y, level)
	}
}

// vline draws one vertical line, which is how a caret position is marked.
pub fn (mut c Canvas) vline(x int, y0 int, y1 int, level u8) {
	for y in min_val(y0, y1) .. max_val(y0, y1) {
		c.blend(x, y, level)
	}
}

// min_val is the smaller of two ints. V has no int.min in this version.
fn min_val(a int, b int) int {
	return if a < b { a } else { b }
}

// max_val is the larger of two ints.
fn max_val(a int, b int) int {
	return if a > b { a } else { b }
}

// png encodes the canvas as a PNG: signature, header, the deflated pixels, and an end marker.
//
// Written out rather than reached for, because the standard library has zlib and a checksum but no
// image format, and a file is enough to look at.
pub fn (c &Canvas) png() []u8 {
	mut out := [u8(137), 80, 78, 71, 13, 10, 26, 10] // the eight bytes every PNG starts with
	// IHDR: width, height, 8 bits, greyscale, no interlace, no transparency.
	mut ihdr := []u8{}
	ihdr << be32(u32(c.w))
	ihdr << be32(u32(c.h))
	ihdr << u8(8)
	ihdr << u8(0)
	ihdr << u8(0)
	ihdr << u8(0)
	ihdr << u8(0)
	out << png_chunk('IHDR', ihdr)
	// The pixels, each row prefixed with the filter type. Filter 0 is no filter, and every row says so,
	// which costs one byte per row and saves the arithmetic.
	mut raw := []u8{cap: c.h * (1 + c.w)}
	for y in 0 .. c.h {
		raw << u8(0)
		raw << c.pixels[y * c.w..(y + 1) * c.w]
	}
	out << png_chunk('IDAT', zlib.compress(raw) or { panic('deflate failed') })
	out << png_chunk('IEND', []u8{})
	return out
}

// write_png encodes the canvas and writes it where the program was run from, printing where it went.
pub fn (mut c Canvas) write_png(name string) {
	os.write_file(name, c.png().bytestr()) or { panic('cannot write ${name}: ${err}') }
	println('wrote ${name} (${c.w}x${c.h})')
}

// png_chunk wraps one piece of a PNG in its length, its type and its checksum.
//
// The checksum covers the type as well as the data, because that is what a reader checks: a checksum of
// the data alone accepts a chunk whose type has been corrupted.
fn png_chunk(kind string, data []u8) []u8 {
	mut out := []u8{}
	out << be32(u32(data.len))
	mut body := []u8{}
	body << kind.bytes()
	body << data
	out << body
	out << be32(crc32.sum(body))
	return out
}

// be32 writes one number the way a PNG stores it.
fn be32(v u32) []u8 {
	mut b := []u8{}
	b << u8(v >> 24)
	b << u8(v >> 16)
	b << u8(v >> 8)
	b << u8(v)
	return b
}
