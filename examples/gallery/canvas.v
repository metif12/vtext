// canvas.v is the drawing surface of the gallery: an RGBA framebuffer that
// HarfAra draws into directly.
//
// The window and every control belong to ui2. The stage is a HarfAra-drawn
// bitmap shown through ui2's Image widget on every parameter change — the
// interface itself demonstrates the library, since every label and every
// sample glyph is shaped and rasterised by it.
module main

import math
import os
import hash.crc32
import compress.zlib
import harfara.shape
import harfara.layout

pub struct Color {
pub:
	r u8
	g u8
	b u8
	a u8 = 255
}

pub const bg = Color{24, 28, 36, 255}
pub const panel = Color{38, 44, 56, 255}
pub const panel_hi = Color{54, 62, 78, 255}
pub const stage_bg = Color{250, 249, 246, 255}
pub const ink = Color{28, 32, 40, 255}
pub const fg = Color{232, 236, 244, 255}
pub const dim = Color{150, 160, 178, 255}
pub const accent = Color{86, 156, 244, 255}
pub const guide = Color{196, 202, 214, 255}
pub const warn = Color{232, 150, 92, 255}

pub struct Canvas {
pub mut:
	w      int
	h      int
	pixels []u8
	// The caller's glyph memo, borrowed from the app for one render: the
	// canvas blits what the cache holds and rasterizes only on a miss.
	// Bitmaps are shared read-only, the way the cache contract requires.
	cache &shape.Cache
}

// new_canvas allocates a blank RGBA framebuffer.
pub fn new_canvas(w int, h int, mut cache &shape.Cache) &Canvas {
	return &Canvas{
		w:      w
		h:      h
		pixels: []u8{len: w * h * 4, init: 0}
		cache:  cache
	}
}

// font_id_of names a font for the glyph cache: its address as an integer.
// Heap objects do not move, and installed fonts are never freed mid-session,
// so the address is stable for exactly as long as the cache needs it.
fn font_id_of(f &shape.Font) u64 {
	return u64(uint(voidptr(f)))
}

// resize reallocates the buffer when the window changes size.
pub fn (mut c Canvas) resize(w int, h int) {
	if c.w == w && c.h == h {
		return
	}
	c.w = w
	c.h = h
	c.pixels = []u8{len: w * h * 4, init: 0}
}

// clear fills every pixel with one colour.
pub fn (mut c Canvas) clear(col Color) {
	for i in 0 .. c.w * c.h {
		p := i * 4
		c.pixels[p] = col.r
		c.pixels[p + 1] = col.g
		c.pixels[p + 2] = col.b
		c.pixels[p + 3] = 255
	}
}

// blend paints coverage of one colour over a pixel. Two glyphs can cover the
// same pixel (a mark sits on its base), so this is accumulation rather than a
// set.
fn (mut c Canvas) blend(x int, y int, col Color, coverage u8) {
	if x < 0 || y < 0 || x >= c.w || y >= c.h || coverage == 0 {
		return
	}
	p := (y * c.w + x) * 4
	if coverage >= 255 {
		c.pixels[p] = col.r
		c.pixels[p + 1] = col.g
		c.pixels[p + 2] = col.b
		c.pixels[p + 3] = 255
		return
	}
	inv := 255 - int(coverage)
	c.pixels[p] = u8((int(col.r) * int(coverage) + int(c.pixels[p]) * inv) / 255)
	c.pixels[p + 1] = u8((int(col.g) * int(coverage) + int(c.pixels[p + 1]) * inv) / 255)
	c.pixels[p + 2] = u8((int(col.b) * int(coverage) + int(c.pixels[p + 2]) * inv) / 255)
	c.pixels[p + 3] = 255
}

// rect fills a clipped rectangle.
pub fn (mut c Canvas) rect(x int, y int, w int, h int, col Color) {
	x0 := if x < 0 { 0 } else { x }
	y0 := if y < 0 { 0 } else { y }
	x1 := if x + w > c.w { c.w } else { x + w }
	y1 := if y + h > c.h { c.h } else { y + h }
	for yy in y0 .. y1 {
		for xx in x0 .. x1 {
			c.blend(xx, yy, col, 255)
		}
	}
}

// transform pans and rotates the painted stage inside its frame. It maps each
// destination pixel back to a source pixel, so the result has no gaps. The
// frame itself keeps its size; the stage border is drawn after this call.
pub fn (mut c Canvas) transform(pan_x f64, pan_y f64, degrees f64, col Color) {
	if pan_x == 0 && pan_y == 0 && degrees == 0 {
		return
	}
	src := c.pixels.clone()
	mut out := []u8{len: c.w * c.h * 4, init: 0}
	rad := degrees * 0.017453292519943295
	cos_a := math.cos(rad)
	sin_a := math.sin(rad)
	cx := f64(c.w) / 2.0
	cy := f64(c.h) / 2.0
	for y in 0 .. c.h {
		for x in 0 .. c.w {
			d := (y * c.w + x) * 4
			px := f64(x) - pan_x - cx
			py := f64(y) - pan_y - cy
			sx := int(cx + px * cos_a + py * sin_a)
			sy := int(cy - px * sin_a + py * cos_a)
			if sx >= 0 && sx < c.w && sy >= 0 && sy < c.h {
				s := (sy * c.w + sx) * 4
				out[d] = src[s]
				out[d + 1] = src[s + 1]
				out[d + 2] = src[s + 2]
				out[d + 3] = src[s + 3]
			} else {
				out[d] = col.r
				out[d + 1] = col.g
				out[d + 2] = col.b
				out[d + 3] = 255
			}
		}
	}
	c.pixels = out
}

// outline draws the four edges of a rectangle.
pub fn (mut c Canvas) outline(x int, y int, w int, h int, col Color) {
	c.hline(y, x, x + w - 1, col)
	c.hline(y + h - 1, x, x + w - 1, col)
	c.vline(x, y, y + h - 1, col)
	c.vline(x + w - 1, y, y + h - 1, col)
}

// hline draws a horizontal rule between two x positions.
pub fn (mut c Canvas) hline(y int, x0 int, x1 int, col Color) {
	for x in min_i(x0, x1) .. max_i(x0, x1) + 1 {
		c.blend(x, y, col, 255)
	}
}

// vline draws a vertical rule between two y positions.
pub fn (mut c Canvas) vline(x int, y0 int, y1 int, col Color) {
	for y in min_i(y0, y1) .. max_i(y0, y1) + 1 {
		c.blend(x, y, col, 255)
	}
}

// line draws a Bresenham segment.
pub fn (mut c Canvas) line(x0 int, y0 int, x1 int, y1 int, col Color) {
	dx := abs_i(x1 - x0)
	dy := abs_i(y1 - y0)
	sx := if x0 < x1 { 1 } else { -1 }
	sy := if y0 < y1 { 1 } else { -1 }
	mut err := dx - dy
	mut x := x0
	mut y := y0
	for {
		c.blend(x, y, col, 255)
		if x == x1 && y == y1 {
			break
		}
		e2 := 2 * err
		if e2 > -dy {
			err -= dy
			x += sx
		}
		if e2 < dx {
			err += dx
			y += sy
		}
	}
}

// text shapes one string with the caller's options and paints every glyph at
// baseline, with the pen starting at x. All placement comes from the engine;
// this only puts the bitmap's ink box where the pen says.
pub fn (mut c Canvas) text(ctx &shape.Context, fs &shape.FontSet, text string, x int, baseline int,
	em f64, dir shape.Direction, opts &layout.LayoutOptions, col Color) {
	line := layout.layout_paragraph_with(ctx, text.runes(), dir, fs, em, opts)
	c.draw_line(&line, x, baseline, em, col)
}

// draw_line paints an already-shaped line. Callers that need the line's
// metrics shape once and then hand the result here rather than shaping twice.
pub fn (mut c Canvas) draw_line(line &layout.Line, x int, baseline int, em f64, col Color) {
	for g in line.glyphs {
		if f := g.font {
			c.draw_glyph(f, g, x, baseline, em, col)
		}
	}
}

// draw_glyph paints one positioned glyph with a chosen colour, which is how
// the fallback page shows which font in the chain supplied each glyph.
// Bitmaps come from the caller's cache: the first render of a session
// rasterizes, every later one blits.
pub fn (mut c Canvas) draw_glyph(f &shape.Font, g shape.Glyph, x int, baseline int, em f64,
	col Color) {
	// The rasteriser takes sub-pixel offsets in quarter pixels.
	sub_x := i32(math.round(f64(g.x - f64(int(g.x))) * 4.0))
	sub_y := i32(math.round(f64(g.y - f64(int(g.y))) * 4.0))
	bm := c.cache.get_or_rasterize(font_id_of(f), f, g.gid, em, sub_x, sub_y)
	if bm.is_empty() {
		return
	}
	ox := x + int(math.floor(g.x)) - bm.left
	oy := baseline + int(math.floor(g.y)) - bm.top
	for by in 0 .. bm.height {
		for bx in 0 .. bm.width {
			cov := bm.ink(bx, by)
			if cov > 0 {
				c.blend(ox + bx, oy + by, col, cov)
			}
		}
	}
}

// label is the simple form used by the UI: forced LTR, default options, no
// caller options to get in the way of a widget caption.
pub fn (mut c Canvas) label(ctx &shape.Context, fs &shape.FontSet, s string, x int, y int, em f64,
	col Color) {
	c.text(ctx, fs, s, x, y, em, .ltr, &layout.LayoutOptions{}, col)
}

// glyph_zoom paints one glyph's coverage bitmap enlarged by scale. It returns
// the bitmap's box so the caller can annotate it.
pub fn (mut c Canvas) glyph_zoom(f &shape.Font, gid u16, em f64, sub_x i32, sub_y i32, x int,
	y int, scale int, col Color) (int, int) {
	bm := c.cache.get_or_rasterize(font_id_of(f), f, gid, em, sub_x, sub_y)
	if bm.is_empty() {
		return 0, 0
	}
	for by in 0 .. bm.height {
		for bx in 0 .. bm.width {
			cov := bm.ink(bx, by)
			if cov > 0 {
				c.rect(x + bx * scale, y + by * scale, scale, scale, col)
			}
		}
	}
	return bm.width * scale, bm.height * scale
}

// write_bmp saves the framebuffer as a 24-bit bottom-up BMP. ui2's native
// Windows image control only loads BMP; the custom renderer takes the PNG
// that write_png saves (see render in main.v).
pub fn (c &Canvas) write_bmp(path string) {
	stride := (c.w * 3 + 3) / 4 * 4
	image_size := stride * c.h
	mut out := []u8{cap: 54 + image_size}
	// BITMAPFILEHEADER
	out << u8(0x42)
	out << u8(0x4d)
	out << u32_bytes(u32(54 + image_size))
	out << u16_bytes(0)
	out << u16_bytes(0)
	out << u32_bytes(54)
	// BITMAPINFOHEADER
	out << u32_bytes(40)
	out << i32_bytes(i32(c.w))
	out << i32_bytes(i32(c.h))
	out << u16_bytes(1)
	out << u16_bytes(24)
	out << u32_bytes(0)
	out << u32_bytes(u32(image_size))
	out << i32_bytes(0)
	out << i32_bytes(0)
	out << u32_bytes(0)
	out << u32_bytes(0)
	for y in 0 .. c.h {
		src_y := c.h - 1 - y
		for x in 0 .. c.w {
			p := (src_y * c.w + x) * 4
			out << c.pixels[p + 2]
			out << c.pixels[p + 1]
			out << c.pixels[p]
		}
		for _ in c.w * 3 .. stride {
			out << u8(0)
		}
	}
	os.write_file(path, out.bytestr()) or { eprintln('cannot write ${path}: ${err}') }
}

fn u16_bytes(v u16) []u8 {
	return [u8(v & 0xff), u8(v >> 8 & 0xff)]
}

fn u32_bytes(v u32) []u8 {
	return [u8(v & 0xff), u8(v >> 8 & 0xff), u8(v >> 16 & 0xff), u8(v >> 24 & 0xff)]
}

fn i32_bytes(v i32) []u8 {
	return u32_bytes(u32(v))
}

// write_png saves the framebuffer as a PNG for headless checks.
pub fn (c &Canvas) write_png(path string) {
	mut out := [u8(137), 80, 78, 71, 13, 10, 26, 10]
	mut ihdr := []u8{}
	ihdr << be32(u32(c.w))
	ihdr << be32(u32(c.h))
	ihdr << u8(8) // 8 bits per channel
	ihdr << u8(6) // RGBA
	ihdr << u8(0)
	ihdr << u8(0)
	ihdr << u8(0)
	out << png_chunk('IHDR', ihdr)
	mut raw := []u8{cap: c.h * (1 + c.w * 4)}
	for y in 0 .. c.h {
		raw << u8(0)
		raw << c.pixels[y * c.w * 4..(y + 1) * c.w * 4]
	}
	out << png_chunk('IDAT', zlib.compress(raw) or { panic('png deflate failed') })
	out << png_chunk('IEND', []u8{})
	os.write_file(path, out.bytestr()) or { eprintln('cannot write ${path}: ${err}') }
}

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

fn be32(v u32) []u8 {
	return [u8(v >> 24), u8(v >> 16 & 0xff), u8(v >> 8 & 0xff), u8(v & 0xff)]
}

fn min_i(a int, b int) int {
	return if a < b { a } else { b }
}

fn max_i(a int, b int) int {
	return if a > b { a } else { b }
}

fn abs_i(v int) int {
	return if v < 0 { -v } else { v }
}
