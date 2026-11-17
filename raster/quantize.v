module raster

import math

// Standalone coverage helpers: quantize, gamma/contrast and blur.
//
// All three run over GlyphBitmap coverage only, so any caller-owned atlas or
// strike cache can use them without pulling in fontstash, freetype or canvas
// types. The zero value is always the identity: no quantize, no gamma shift,
// no blur.

// quantize_mono thresholds coverage at 127: ink or empty.
pub fn quantize_mono(src GlyphBitmap) GlyphBitmap {
	if src.is_empty() || src.coverage.len < src.width * src.height {
		return src
	}
	mut out := []u8{len: src.coverage.len}
	for i, v in src.coverage {
		out[i] = if v >= 127 { u8(255) } else { u8(0) }
	}
	return GlyphBitmap{
		coverage: out
		width:    src.width
		height:   src.height
		left:     src.left
		top:      src.top
	}
}

// quantize_gray2 maps coverage to 0/85/170/255 (like FT_PIXEL_MODE_GRAY2).
pub fn quantize_gray2(src GlyphBitmap) GlyphBitmap {
	if src.is_empty() || src.coverage.len < src.width * src.height {
		return src
	}
	mut out := []u8{len: src.coverage.len}
	for i, v in src.coverage {
		out[i] = u8((int(v) * 3 + 127) / 255 * 85)
	}
	return GlyphBitmap{
		coverage: out
		width:    src.width
		height:   src.height
		left:     src.left
		top:      src.top
	}
}

// quantize_gray4 maps coverage to 16 gray levels (like FT_PIXEL_MODE_GRAY4).
pub fn quantize_gray4(src GlyphBitmap) GlyphBitmap {
	if src.is_empty() || src.coverage.len < src.width * src.height {
		return src
	}
	mut out := []u8{len: src.coverage.len}
	for i, v in src.coverage {
		out[i] = u8((int(v) * 15 + 127) / 255 * 17)
	}
	return GlyphBitmap{
		coverage: out
		width:    src.width
		height:   src.height
		left:     src.left
		top:      src.top
	}
}

// gamma_lut builds a 256-entry preblend table from contrast (0..1) and
// gamma (>0). Contrast 0.5 and gamma 1 answer the identity table.
pub fn gamma_lut(contrast f32, gamma f32) []u8 {
	mut table := []u8{len: 256}
	if gamma <= 0 {
		return table
	}
	for i in 0 .. 256 {
		norm := f32(i) / 255.0
		g := math.pow(f64(norm), f64(1.0 / gamma))
		mut scaled := g * f64(contrast) * 2.0
		if scaled < 0 {
			scaled = 0
		} else if scaled > 1 {
			scaled = 1
		}
		table[i] = u8(int(scaled * 255.0 + 0.5))
	}
	return table
}

// apply_lut remaps coverage through a 256-entry table.
pub fn apply_lut(src GlyphBitmap, table []u8) GlyphBitmap {
	if src.is_empty() || table.len != 256 {
		return src
	}
	if src.coverage.len < src.width * src.height {
		return src
	}
	mut out := []u8{len: src.coverage.len}
	for i, v in src.coverage {
		out[i] = table[v]
	}
	return GlyphBitmap{
		coverage: out
		width:    src.width
		height:   src.height
		left:     src.left
		top:      src.top
	}
}

// blur_bitmap runs a 3x3 box blur radius times over coverage. Radius at or
// below zero answers src unchanged; it is the generic form of the fontstash
// exponential blur without any atlas or error-callback machinery.
pub fn blur_bitmap(src GlyphBitmap, radius int) GlyphBitmap {
	if src.is_empty() || radius <= 0 {
		return src
	}
	if src.coverage.len < src.width * src.height {
		return src
	}
	mut cur := src.coverage.clone()
	mut nxt := []u8{len: cur.len}
	for _ in 0 .. radius {
		for y in 0 .. src.height {
			for x in 0 .. src.width {
				mut acc := 0
				mut n := 0
				for dy in -1 .. 2 {
					for dx in -1 .. 2 {
						sx := x + dx
						sy := y + dy
						if sx < 0 || sy < 0 || sx >= src.width || sy >= src.height {
							continue
						}
						acc += int(cur[sy * src.width + sx])
						n++
					}
				}
				nxt[y * src.width + x] = u8(acc / n)
			}
		}
		cur = nxt.clone()
	}
	return GlyphBitmap{
		coverage: cur
		width:    src.width
		height:   src.height
		left:     src.left
		top:      src.top
	}
}
