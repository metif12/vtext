module raster

// vtext.raster is FreeType's rendering side: box-for-gid plus fill-this-buffer.
//
// The contract is two calls and one struct. `box_only` reports a glyph's ink
// box without rendering it, which is everything a caller measuring an extent
// needs and nothing a caller drawing would want; `render_into` draws into a
// caller-owned buffer, which is everything a caller drawing needs. Both calls
// live as methods on font.Face, because this compiler defines methods only in
// the type's own module, and this module owns the data they trade in.
//
// Today the only engine behind the contract is unhinted stb_truetype. Hinting
// (a TrueType interpreter plus an auto-hinter fallback) and color (COLR/CPAL,
// CBDT/sbix) land here as engines behind the same two calls, verified per
// glyph the way the ink leg verifies stb now.

// GlyphBitmap is a rasterised glyph in 8-bit coverage, with the ink box placed
// relative to the pen position on the baseline.
pub struct GlyphBitmap {
pub mut:
	// coverage is row-major, width*height bytes: 0 is empty, 255 is solid ink.
	coverage []u8
	width    int
	height   int
	// left is how far the ink box reaches left of the pen.
	left int
	// top is how far the ink box reaches above the baseline, positive upwards.
	top int
}

// is_empty reports whether the glyph has no ink at all.
pub fn (b &GlyphBitmap) is_empty() bool {
	return b.width <= 0 || b.height <= 0
}

// ink returns the coverage at a pixel, 0 outside the box.
pub fn (b &GlyphBitmap) ink(x int, y int) u8 {
	if x < 0 || y < 0 || x >= b.width || y >= b.height {
		return 0
	}
	return b.coverage[y * b.width + x]
}
