// hello is the smallest program that proves the whole vtext pipeline: text in, positioned glyphs on a
// picture, quit.
//
// There is no window here on purpose. A window needs a graphics binding, and a binding is a dependency
// that has nothing to do with the text engine, so the part of this example that shows the engine works
// is the part that writes a file. `v run .` prints the path.
//
// Everything between the text and the file is the library: fonts are opened from disk, the paragraph is
// laid out through bidi and Arabic joining, each glyph is rasterised by the font's own outlines, and
// the result is deflated into a PNG with zlib. Nothing about the shaping is redone here, and that is
// the claim this example makes.
module main

import os
import hash.crc32
import compress.zlib
import vtext
import math

// The fonts this example asks for by role, rather than by name. Which file fills a role is this
// program's decision; what the engine does with the result is the library's.
const latin_font = 'C:/Windows/Fonts/segoeui.ttf'
const arabic_font = 'C:/Windows/Fonts/trado.ttf'

// The two lines, chosen so one command shows three things at once: left-to-right text with a
// ligature, an Arabic word with a mark on it, and a line that is mostly Latin with one Arabic word in
// the middle, which is where bidirectional reordering has to do something.
const lines = [
	'V shapes text: ffi ligature, kerning AV, and a baseline.',
	'مرحبا بالعالم',
	'The word سلام means peace, inside an English line.',
]

// The margin and the gap between lines, in pixels. The canvas size is not written down: it is measured
// from the lines the engine lays out, so changing the text or the size cannot silently crop the last
// line, which is exactly what a fixed height does.
const margin = 40
const line_gap = 26.0
const em_px = 28.0

// How many subpixel units make one pixel. vtext's rasteriser counts a pixel in quarters, so a glyph's
// fractional x has to be scaled by this rather than by sixty-four.
const subpixel_units = 4.0

// Canvas is a plain 8-bit grey image. Text is drawn as coverage onto a light background, so one byte
// per pixel is enough and the PNG needs no colour type beyond grey.
struct Canvas {
mut:
	w      int
	h      int
	pixels []u8
}

// new_canvas makes a canvas filled with one grey level.
fn new_canvas(w int, h int, level u8) &Canvas {
	mut c := &Canvas{
		w:      w
		h:      h
		pixels: []u8{len: w * h, init: level}
	}
	return c
}

// blend darkens one pixel by how much ink a glyph puts there.
//
// The arithmetic is coverage over the background rather than a set, because two glyphs can cover the
// same pixel: a mark lands on the letter under it, and drawing the letter second would erase the mark
// if drawing were a set.
fn (mut c Canvas) blend(x int, y int, coverage u8) {
	if x < 0 || y < 0 || x >= c.w || y >= c.h {
		return
	}
	bg := c.pixels[y * c.w + x]
	c.pixels[y * c.w + x] = bg - u8((bg * int(coverage) + 127) / 255)
}

// png encodes the canvas as a PNG: signature, header, the deflated pixels, and an end marker.
//
// Written out rather than reached for, because the standard library has zlib and a checksum but no
// image format, and a file is enough to look at. The chunks each carry their length, their type and a
// CRC of the type and the data, which is why the checksum is computed over the type as well: a reader
// that checks the data alone accepts a chunk whose type has been corrupted.
fn (c &Canvas) png() []u8 {
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

// png_chunk wraps one piece of a PNG in its length, its type and its checksum.
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

// draw_line lays out one string and paints its glyphs onto the canvas with the baseline at baseline_y,
// and returns the line's width, ascent and descent so the caller can size the canvas.
//
// This is the whole of the example's own drawing code. The engine has already decided the direction,
// joined the Arabic, chosen the shapes, kerned, placed the marks, and given every glyph a position, so
// all that is left is to ask each font for the glyph's pixels and put them on the canvas where the
// engine said to.
fn draw_line(c &Canvas, fs &vtext.FontSet, ctx &vtext.Context, text string, baseline f64) f64 {
	// A V string is a byte array, so iterating one yields UTF-8 bytes rather than characters: the two
	// bytes of U+0645 arrive as two runes and the text turns into Latin-1 noise. .runes() decodes.
	cps := text.runes()
	// .auto takes the direction from the first strong character, so the same call lays out all three
	// lines correctly and this example does not have to know which is which.
	line := vtext.layout_paragraph(ctx, cps, .auto, fs, em_px)
	baseline_i := int(baseline)
	for g in line.glyphs {
		f := g.font or { continue }
		// The pen is at a fractional place and the rasteriser takes a subpixel offset in quarters of a
		// pixel, so the fractional part is handed over in those units and the whole pixel is dropped.
		// Passing sixty-fourths of a pixel here, which is what the function used to suggest, shifts every
		// glyph by up to sixteen pixels and turns a line of text into overlapping ink.
		sub_x := i32(math.round(f64(g.x - f64(int(g.x))) * subpixel_units))
		sub_y := i32(math.round(f64(g.y - f64(int(g.y))) * subpixel_units))
		bitmap := f.rasterize(g.gid, em_px, sub_x, sub_y)
		if bitmap.is_empty() {
			continue
		}
		// The bitmap's ink box hangs off the pen by `left` and reaches `top` above the baseline, so the
		// pixel the bitmap's own (0, 0) belongs at is the pen moved left and down.
		origin_x := int(math.floor(g.x)) - bitmap.left
		origin_y := baseline_i - bitmap.top + int(math.floor(g.y))
		for by in 0 .. bitmap.height {
			for bx in 0 .. bitmap.width {
				cov := bitmap.ink(bx, by)
				if cov > 0 {
					c.blend(origin_x + bx, origin_y + by, cov)
				}
			}
		}
	}
	return line.width
}

// measure lays every line out once to find how much room the canvas needs. The engine is asked the same
// question twice, and the second time is the one that draws, which is a little wasteful and keeps this
// example to one code path: a caller that sizes a canvas from a first layout and then draws it does
// exactly this.
fn measure(fs &vtext.FontSet, ctx &vtext.Context, text string) (int, f64, f64) {
	// A V string is a byte array, so iterating one yields UTF-8 bytes rather than characters: the two
	// bytes of U+0645 arrive as two runes and the text turns into Latin-1 noise. .runes() decodes.
	cps := text.runes()
	line := vtext.layout_paragraph(ctx, cps, .auto, fs, em_px)
	return int(math.ceil(line.width)), line.ascent, line.descent
}

fn main() {
	ctx := vtext.new_context()
	latin := vtext.load_font_file(latin_font) or { panic('cannot open ${latin_font}: ${err}') }
	arabic := vtext.load_font_file(arabic_font) or { panic('cannot open ${arabic_font}: ${err}') }
	// One set with both fonts in it, so a character the Latin font has no glyph for is found in the
	// Arabic one rather than drawn as a box. Order is preference: the first font that covers a
	// character wins.
	fs := vtext.new_font_set_of(latin, arabic)

	// The canvas is sized from the text: the widest line sets the width, and the tallest ascent plus the
	// sum of the line heights sets the height.
	mut width := 0
	mut ascent := 0.0
	mut descent := 0.0
	for text in lines {
		w, a, d := measure(fs, ctx, text)
		if w > width {
			width = w
		}
		if a > ascent {
			ascent = a
		}
		if d > descent {
			descent = d
		}
	}
	canvas_w := width + 2 * margin
	canvas_h := int((ascent + descent + line_gap) * f64(lines.len)) + 2 * margin

	mut canvas := new_canvas(canvas_w, canvas_h, 0xff)
	mut baseline := f64(margin) + ascent
	for text in lines {
		draw_line(canvas, fs, ctx, text, baseline)
		baseline += ascent + descent + line_gap
	}

	// Written next to this file rather than to a fixed path, so two runs do not fight over one name.
	out_path := 'hello.png'
	os.write_file(out_path, canvas.png().bytestr()) or { panic('cannot write ${out_path}: ${err}') }
	println('wrote ${os.abs_path(out_path)}')
	println('shaped ${lines.len} lines at ${em_px:.0f}px into ${canvas_w}x${canvas_h}')
}
