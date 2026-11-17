module raster

// Color compositing behind the box_only/render_into contract.
//
// font.Face answers one outline coverage per COLR layer through the same stb
// path it always used; this file turns those coverages into color. The split
// is deliberate and one-directional: font already imports raster, so raster
// cannot name a font type, and everything here trades in bitmaps only. A
// layer is a tinted coverage, a color glyph is layers composited bottom to
// top, and an embedded strike is nearest-neighbour scaled pixels.
//
// Alpha is straight (non-premultiplied) 8-bit throughout. Tinting multiplies
// coverage by paint alpha; compositing is source-over with round-half-up at
// every division, so the same inputs always answer the same bytes. The
// reference is the source-over definition any canvas implements (the pins
// were checked against a twin Python implementation pixel for pixel); there
// is no hidden gamma and no premultiplied shortcut.

// Rgba is one straight-alpha color pixel: red, green, blue, then alpha, each
// 0..255.
pub struct Rgba {
pub:
	r u8
	g u8
	b u8
	a u8
}

// ColorBitmap is one composited color glyph in straight RGBA, row-major
// width*height*4 bytes, in the same left/top convention GlyphBitmap uses:
// left is how far the ink reaches left of the pen, top how far above the
// baseline.
pub struct ColorBitmap {
pub mut:
	pixels []u8
	width  int
	height int
	left   int
	top    int
}

// is_empty reports whether the bitmap has no ink box at all.
pub fn (b &ColorBitmap) is_empty() bool {
	return b.width <= 0 || b.height <= 0
}

// alpha_sum totals the alpha channel: the color form of summing a gray
// bitmap's coverage, and the number the monochrome-fallback pin compares.
pub fn (b &ColorBitmap) alpha_sum() u64 {
	if b.pixels.len < b.width * b.height * 4 {
		return 0
	}
	mut acc := u64(0)
	for i := 3; i < b.pixels.len; i += 4 {
		acc += u64(b.pixels[i])
	}
	return acc
}

// pixel answers the RGBA at x/y, or zeros outside the box.
pub fn (b &ColorBitmap) pixel(x int, y int) Rgba {
	if x < 0 || y < 0 || x >= b.width || y >= b.height {
		return Rgba{}
	}
	o := (y * b.width + x) * 4
	if o + 3 >= b.pixels.len {
		return Rgba{}
	}
	return Rgba{b.pixels[o], b.pixels[o + 1], b.pixels[o + 2], b.pixels[o + 3]}
}

// qround rounds half up, the shared rule for scaling boxes: 2.5 becomes 3,
// never 2, so a strike scaled by an exact integer lands on exact pixels.
pub fn qround(x f64) int {
	if x >= 0 {
		return int(x + 0.5)
	}
	return -int(-x + 0.5)
}

// tint_bitmap paints a coverage with a solid color: rgb rides the paint and
// alpha is coverage times paint alpha over 255. An empty or coverageless
// bitmap answers an empty color bitmap.
pub fn tint_bitmap(src GlyphBitmap, c Rgba) ColorBitmap {
	if src.is_empty() || src.coverage.len < src.width * src.height {
		return ColorBitmap{}
	}
	mut out := []u8{len: src.width * src.height * 4}
	for i in 0 .. src.width * src.height {
		o := i * 4
		out[o] = c.r
		out[o + 1] = c.g
		out[o + 2] = c.b
		out[o + 3] = u8((int(src.coverage[i]) * int(c.a) + 127) / 255)
	}
	return ColorBitmap{
		pixels: out
		width:  src.width
		height: src.height
		left:   src.left
		top:    src.top
	}
}

// color_union_box answers the union box of gray coverages with no pixels,
// the color form of what box_only reports. Coverageless and empty parts are
// skipped; with no inked parts the answer is empty.
pub fn color_union_box(parts []GlyphBitmap) GlyphBitmap {
	mut x0 := 0
	mut y0 := 0
	mut x1 := 0
	mut y1 := 0
	mut any := false
	for p in parts {
		if p.is_empty() || p.coverage.len < p.width * p.height {
			continue
		}
		// Pen-relative ink runs: x from -left rightwards, y from top-height
		// upwards, because left is a distance left of the pen and top a
		// distance above the baseline.
		px0 := -p.left
		px1 := -p.left + p.width
		py0 := p.top - p.height
		py1 := p.top
		if !any {
			x0, y0, x1, y1 = px0, py0, px1, py1
			any = true
		} else {
			if px0 < x0 {
				x0 = px0
			}
			if py0 < y0 {
				y0 = py0
			}
			if px1 > x1 {
				x1 = px1
			}
			if py1 > y1 {
				y1 = py1
			}
		}
	}
	if !any {
		return GlyphBitmap{}
	}
	return GlyphBitmap{
		width:  x1 - x0
		height: y1 - y0
		left:   -x0
		top:    y1
	}
}

// composite_over paints src over dst where they overlap and answers the
// union: outside src the answer is dst, outside dst it is src, and where
// both ink the answer is source-over. Either side empty answers the other
// side unchanged.
pub fn composite_over(dst ColorBitmap, src ColorBitmap) ColorBitmap {
	return composite_layers([dst, src])
}

// composite_layers paints layers bottom to top over a transparent canvas and
// answers the union box. An empty or pixelless layer is skipped; with no
// inked layers the answer is empty.
pub fn composite_layers(layers []ColorBitmap) ColorBitmap {
	mut x0 := 0
	mut y0 := 0
	mut x1 := 0
	mut y1 := 0
	mut any := false
	for l in layers {
		if l.is_empty() || l.pixels.len < l.width * l.height * 4 {
			continue
		}
		px0 := -l.left
		px1 := -l.left + l.width
		py0 := l.top - l.height
		py1 := l.top
		if !any {
			x0, y0, x1, y1 = px0, py0, px1, py1
			any = true
		} else {
			if px0 < x0 {
				x0 = px0
			}
			if py0 < y0 {
				y0 = py0
			}
			if px1 > x1 {
				x1 = px1
			}
			if py1 > y1 {
				y1 = py1
			}
		}
	}
	if !any {
		return ColorBitmap{}
	}
	w := x1 - x0
	h := y1 - y0
	mut out := []u8{len: w * h * 4}
	for li, l in layers {
		_ = li
		if l.is_empty() || l.pixels.len < l.width * l.height * 4 {
			continue
		}
		ox := -l.left - x0
		oy := y1 - l.top
		for y in 0 .. l.height {
			for x in 0 .. l.width {
				so := (y * l.width + x) * 4
				sa := int(l.pixels[so + 3])
				if sa == 0 {
					continue
				}
				dx := ox + x
				dy := oy + y
				if dx < 0 || dy < 0 || dx >= w || dy >= h {
					continue
				}
				do := (dy * w + dx) * 4
				sr := int(l.pixels[so])
				sg := int(l.pixels[so + 1])
				sb := int(l.pixels[so + 2])
				da := int(out[do + 3])
				oa := sa + (da * (255 - sa) + 127) / 255
				if oa == 0 {
					out[do] = 0
					out[do + 1] = 0
					out[do + 2] = 0
					out[do + 3] = 0
					continue
				}
				// Source-over in straight alpha, rounded twice the way the
				// integer reference does: the dst contribution is rounded to
				// a whole premultiplied unit first, then the quotient rounds
				// half up. Two roundings rather than one is the documented
				// rule, and the pins hold it exactly.
				dr := int(out[do])
				dg := int(out[do + 1])
				db := int(out[do + 2])
				pr := sr * sa + (dr * da * (255 - sa) + 127) / 255
				pg := sg * sa + (dg * da * (255 - sa) + 127) / 255
				pb := sb * sa + (db * da * (255 - sa) + 127) / 255
				out[do] = u8((pr + oa / 2) / oa)
				out[do + 1] = u8((pg + oa / 2) / oa)
				out[do + 2] = u8((pb + oa / 2) / oa)
				out[do + 3] = u8(oa)
			}
		}
	}
	return ColorBitmap{
		pixels: out
		width:  w
		height: h
		left:   -x0
		top:    y1
	}
}

// scale_bitmap_nearest scales a coverage by an exact-ratio nearest neighbour:
// output pixel (x, y) samples input (x/scale, y/scale), floored. Strike
// pixels are authored pixels, so filtering them would invent ink the strike
// never drew; the caller that wants filtered scaling resamples itself.
// Non-positive scale, an empty bitmap, or a coverageless box answers empty.
pub fn scale_bitmap_nearest(src GlyphBitmap, scale f64) GlyphBitmap {
	if src.is_empty() || scale <= 0 {
		return GlyphBitmap{}
	}
	if src.coverage.len < src.width * src.height {
		return GlyphBitmap{}
	}
	w2 := qround(f64(src.width) * scale)
	h2 := qround(f64(src.height) * scale)
	if w2 <= 0 || h2 <= 0 || w2 > 4096 || h2 > 4096 {
		return GlyphBitmap{}
	}
	mut out := []u8{len: w2 * h2}
	for y in 0 .. h2 {
		mut sy := int(f64(y) / scale)
		if sy < 0 {
			sy = 0
		}
		if sy >= src.height {
			sy = src.height - 1
		}
		for x in 0 .. w2 {
			mut sx := int(f64(x) / scale)
			if sx < 0 {
				sx = 0
			}
			if sx >= src.width {
				sx = src.width - 1
			}
			out[y * w2 + x] = src.coverage[sy * src.width + sx]
		}
	}
	return GlyphBitmap{
		coverage: out
		width:    w2
		height:   h2
		left:     qround(f64(src.left) * scale)
		top:      qround(f64(src.top) * scale)
	}
}

// flatten_alpha answers a color bitmap's alpha channel as gray coverage in
// the same box: the color form of reading a gray bitmap back, and what the
// monochrome-fallback pin compares against the outline render.
pub fn flatten_alpha(src ColorBitmap) GlyphBitmap {
	if src.is_empty() || src.pixels.len < src.width * src.height * 4 {
		return GlyphBitmap{}
	}
	mut out := []u8{len: src.width * src.height}
	for i in 0 .. src.width * src.height {
		out[i] = src.pixels[i * 4 + 3]
	}
	return GlyphBitmap{
		coverage: out
		width:    src.width
		height:   src.height
		left:     src.left
		top:      src.top
	}
}
