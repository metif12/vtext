module raster

import math

// Synthetic styles at the glyph level: embolden and oblique.
//
// FreeType answers false bold and slanted faces behind
// FT_GlyphSlot_Embolden and FT_GlyphSlot_Oblique: the first thickens the
// outline by about one twenty-fourth of the em on every side, the second
// shears it about the baseline. Both run here as bitmap transforms over the
// coverage this module already trades in, so any engine that fills a
// GlyphBitmap can offer them without touching its rasteriser. The defaults
// follow the FreeType geometry: the embolden default is the em over
// twenty-four rule, and the oblique default is the shear FreeType applies,
// measured at 0.2126 by regressing outline-point shifts over Amiri and
// SourceSans with freetype-py. Explicit strengths override the defaults.
// Zero embolden strength and zero slant are the identity, which is what the
// break-fix control in synth_test.v leans on.

pub const default_oblique_slant = 0.2126

// default_embolden_strength_px answers the FreeType embolden strength for an
// em size: the units per em times the scale over twenty-four, which is the em
// over twenty-four pixels. At 32 px that is 1.333 px.
pub fn default_embolden_strength_px(em_px f64) f64 {
	if em_px <= 0 {
		return 0
	}
	return em_px / 24.0
}

// SynthOptions selects synthetic styling for apply_synth. The zero value is
// the identity: no embolden, no oblique, and apply_synth answers its input
// unchanged. strength_px at or below zero asks for the em over twenty-four
// default derived from em_px; slant of zero asks for default_oblique_slant.
pub struct SynthOptions {
pub:
	embolden    bool
	oblique     bool
	strength_px f64
	slant       f64
	em_px       f64
}

// effective_strength resolves the embolden radius in pixels.
pub fn (o SynthOptions) effective_strength() f64 {
	if o.strength_px > 0 {
		return o.strength_px
	}
	return default_embolden_strength_px(o.em_px)
}

// effective_slant resolves the oblique shear.
pub fn (o SynthOptions) effective_slant() f64 {
	if o.slant != 0 {
		return o.slant
	}
	return default_oblique_slant
}

// apply_synth styles a bitmap, embolden first then oblique. With both flags
// off it answers src unchanged, so callers that never set options keep the
// buffer they always got.
pub fn apply_synth(src GlyphBitmap, opt SynthOptions) GlyphBitmap {
	mut cur := src
	if opt.embolden {
		cur = embolden_bitmap(cur, opt.effective_strength())
	}
	if opt.oblique {
		cur = oblique_bitmap(cur, opt.effective_slant())
	}
	return cur
}

// embolden_bitmap thickens ink by max-filter dilation of radius
// round(strength_px): every output pixel takes the strongest coverage in a
// square window around it, which is the bitmap form of OR-ing the shifted
// copies FreeType ORs. The box grows by the radius on every side, the way the
// FreeType outline embolden pushes every edge outward. Strength at or below
// zero, an empty bitmap, or a coverageless box answers src unchanged.
pub fn embolden_bitmap(src GlyphBitmap, strength_px f64) GlyphBitmap {
	if src.is_empty() || strength_px <= 0 {
		return src
	}
	if src.coverage.len < src.width * src.height {
		return src
	}
	mut r := int(strength_px + 0.5)
	if r < 1 {
		r = 1
	}
	w2 := src.width + 2 * r
	h2 := src.height + 2 * r
	mut out := []u8{len: w2 * h2}
	side := 2 * r + 1
	for y in 0 .. h2 {
		for x in 0 .. w2 {
			mut m := u8(0)
			for wy in 0 .. side {
				sy := y - r + wy - r
				if sy < 0 || sy >= src.height {
					continue
				}
				for wx in 0 .. side {
					sx := x - r + wx - r
					if sx < 0 || sx >= src.width {
						continue
					}
					v := src.coverage[sy * src.width + sx]
					if v > m {
						m = v
					}
				}
			}
			out[y * w2 + x] = m
		}
	}
	return GlyphBitmap{
		coverage: out
		width:    w2
		height:   h2
		left:     src.left + r
		top:      src.top + r
	}
}

// oblique_bitmap shears ink about the baseline: row y shifts right by
// slant * (top - y) pixels, so caps lean right while parts below the
// baseline lean left, the way the FreeType matrix leans the outline.
// Coverage resamples linearly, samples past the row edges fade to zero
// rather than smearing the edge, the canvas grows to hold every shifted
// row, and the box trims back to the ink, which is why the box barely moves
// on glyphs whose extremes sit near the baseline. Slant of zero, an empty
// bitmap, or a coverageless box answers src unchanged.
pub fn oblique_bitmap(src GlyphBitmap, slant f64) GlyphBitmap {
	if src.is_empty() || slant == 0 {
		return src
	}
	if src.coverage.len < src.width * src.height {
		return src
	}
	mut omin := 0
	mut omax := 0
	for y in 0 .. src.height {
		s := slant * f64(src.top - y)
		lo := int(math.floor(s))
		hi := int(math.ceil(s))
		if y == 0 {
			omin = lo
			omax = hi
		} else {
			if lo < omin {
				omin = lo
			}
			if hi > omax {
				omax = hi
			}
		}
	}
	w2 := src.width + omax - omin
	mut canvas := []u8{len: w2 * src.height}
	for y in 0 .. src.height {
		s := slant * f64(src.top - y)
		for x in 0 .. w2 {
			u := f64(x + omin) - s
			i0 := int(math.floor(u))
			f := u - f64(i0)
			mut a := 0.0
			if i0 >= 0 && i0 < src.width {
				a = f64(src.coverage[y * src.width + i0])
			}
			mut b := 0.0
			if i0 + 1 >= 0 && i0 + 1 < src.width {
				b = f64(src.coverage[y * src.width + i0 + 1])
			}
			canvas[y * w2 + x] = u8(int(a * (1.0 - f) + b * f + 0.5))
		}
	}
	mut x0 := w2
	mut x1 := -1
	mut y0 := src.height
	mut y1 := -1
	for y in 0 .. src.height {
		for x in 0 .. w2 {
			if canvas[y * w2 + x] != 0 {
				if x < x0 {
					x0 = x
				}
				if x > x1 {
					x1 = x
				}
				if y < y0 {
					y0 = y
				}
				if y > y1 {
					y1 = y
				}
			}
		}
	}
	if x1 < x0 || y1 < y0 {
		return GlyphBitmap{}
	}
	tw := x1 - x0 + 1
	th := y1 - y0 + 1
	mut cov := []u8{len: tw * th}
	for y in 0 .. th {
		for x in 0 .. tw {
			cov[y * tw + x] = canvas[(y0 + y) * w2 + x0 + x]
		}
	}
	return GlyphBitmap{
		coverage: cov
		width:    tw
		height:   th
		left:     src.left - omin - x0
		top:      src.top - y0
	}
}
