module raster

// Subpixel LCD rendering as a raster option beside the current coverage fill.
//
// A FreeType LCD bitmap keeps the rows of the gray render and triples the
// columns: every pixel becomes three consecutive bytes, red, green and blue,
// each sampled a third of a pixel apart. LcdBitmap keeps that layout: width
// counts subpixels, so it is three times the gray width, and channel answers
// one third of a pixel. The default path does not change: to_lcd converts a
// finished gray bitmap, and render_with_options only converts when its lcd
// flag is set.

pub struct LcdBitmap {
pub mut:
	data   []u8
	width  int
	height int
	left   int
	top    int
}

// is_empty reports whether the bitmap has no ink.
pub fn (b &LcdBitmap) is_empty() bool {
	return b.width <= 0 || b.height <= 0
}

// sub answers the subpixel at column x, 0 outside the box.
pub fn (b &LcdBitmap) sub(x int, y int) u8 {
	if x < 0 || y < 0 || x >= b.width || y >= b.height {
		return 0
	}
	return b.data[y * b.width + x]
}

// channel answers one LCD third of pixel x: 0 red, 1 green, 2 blue.
pub fn (b &LcdBitmap) channel(x int, y int, ch int) u8 {
	if ch < 0 || ch > 2 {
		return 0
	}
	return b.sub(x * 3 + ch, y)
}

// channel_sum totals one channel over the bitmap.
pub fn (b &LcdBitmap) channel_sum(ch int) u64 {
	if ch < 0 || ch > 2 {
		return 0
	}
	np := b.width / 3
	mut acc := u64(0)
	for y in 0 .. b.height {
		for x in 0 .. np {
			acc += u64(b.data[y * b.width + x * 3 + ch])
		}
	}
	return acc
}

// ink_sum totals every subpixel in the bitmap.
pub fn (b &LcdBitmap) ink_sum() u64 {
	mut acc := u64(0)
	for v in b.data {
		acc += u64(v)
	}
	return acc
}

// to_lcd splits gray coverage into subpixels. Green rides the pixel center
// and repeats the gray exactly; red and blue sample a third of a pixel to
// either side by linear interpolation between neighbours, edges replicated.
// The weights telescope, so the total is three times the gray total up to
// rounding, the way the measured FreeType LCD total tracks three times its
// gray total. A coverageless box answers an empty bitmap.
pub fn to_lcd(src GlyphBitmap) LcdBitmap {
	if src.is_empty() {
		return LcdBitmap{}
	}
	if src.coverage.len < src.width * src.height {
		return LcdBitmap{}
	}
	w3 := src.width * 3
	mut data := []u8{len: w3 * src.height}
	for y in 0 .. src.height {
		for x in 0 .. src.width {
			c := u16(src.coverage[y * src.width + x])
			mut cl := c
			if x > 0 {
				cl = u16(src.coverage[y * src.width + x - 1])
			}
			mut cr := c
			if x < src.width - 1 {
				cr = u16(src.coverage[y * src.width + x + 1])
			}
			o := (y * src.width + x) * 3
			data[o] = u8((cl + 2 * c + 1) / 3)
			data[o + 1] = u8(c)
			data[o + 2] = u8((2 * c + cr + 1) / 3)
		}
	}
	return LcdBitmap{
		data:   data
		width:  w3
		height: src.height
		left:   src.left
		top:    src.top
	}
}

// RenderOptions selects the raster output beside the default gray fill. The
// zero value asks for exactly the input: apply_synth answers its input and
// no LCD buffer is built, so every existing path that never sets options
// keeps the buffer it always got.
pub struct RenderOptions {
pub:
	lcd   bool
	synth SynthOptions
}

// RenderedGlyph is one glyph in every requested form: gray always, LCD only
// when RenderOptions.lcd is set.
pub struct RenderedGlyph {
pub:
	gray    GlyphBitmap
	lcd     LcdBitmap
	has_lcd bool
}

// render_with_options styles src and converts to LCD on request.
pub fn render_with_options(src GlyphBitmap, opt RenderOptions) RenderedGlyph {
	styled := apply_synth(src, opt.synth)
	if !opt.lcd {
		return RenderedGlyph{
			gray: styled
		}
	}
	return RenderedGlyph{
		gray:    styled
		lcd:     to_lcd(styled)
		has_lcd: true
	}
}
