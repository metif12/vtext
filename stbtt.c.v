module vtext

// stb_truetype is the rasteriser. It is the same public-domain header that
// vlib/fontstash already compiles, vendored in V's own thirdparty directory,
// so using it adds no new dependency to the tree. It is declared STATIC here so
// that a program linking both this module and gg's fontstash does not end up
// with two copies of every stbtt symbol.
//
// Everything above this file - cmap, shaping, bidi, layout, fallback - is plain
// V and does not call into C.

// The header is included from V's own thirdparty tree, so no extra vendoring is
// needed and the version always matches the one gg uses.
//
// V's copy of the header is patched to route allocations through
// FONTSTASH_MALLOC/FONTSTASH_FREE, macros that only fontstash.h defines. We do
// not use fontstash, so we take stb_truetype's own supported override instead.
#include <stdlib.h>
#define STBTT_malloc(x, u) ((void)(u), malloc(x))
#define STBTT_free(x, u) ((void)(u), free(x))
#define STB_TRUETYPE_IMPLEMENTATION
#define STBTT_STATIC
#include "@VEXEROOT/thirdparty/fontstash/stb_truetype.h"

// stbtt_fontinfo is opaque: the real definition lives inside the C header, so
// V cannot mirror its layout without duplicating a union-heavy struct that
// could drift between stb_truetype versions. Instead the Face reserves a raw
// buffer and hands its address to C. The real struct is ~168 bytes on LP64; the
// reservation is deliberately generous so a header upgrade cannot overflow it.
const stbtt_fontinfo_bytes = 512

fn C.stbtt_InitFont(voidptr, &u8, int) int

fn C.stbtt_GetFontOffsetForIndex(&u8, int) int

fn C.stbtt_GetGlyphBitmapBox(voidptr, int, f32, f32, &i32, &i32, &i32, &i32)

fn C.stbtt_GetGlyphBitmapBoxSubpixel(voidptr, int, f32, f32, f32, f32, &i32, &i32, &i32, &i32)

fn C.stbtt_MakeGlyphBitmapSubpixel(voidptr, &u8, int, int, int, f32, f32, f32, f32, int)

// stbtt_get_font_offset_for_index resolves the sfnt offset of a face, handling
// font collections. It returns a negative value on failure.
fn stbtt_get_font_offset_for_index(data []u8, index int) int {
	if data.len == 0 {
		return -1
	}
	return C.stbtt_GetFontOffsetForIndex(data[0], index)
}

// stbtt_init_font prepares a rasteriser handle. It returns non-zero on success.
fn stbtt_init_font(info voidptr, data []u8, offset int) int {
	if data.len == 0 {
		return 0
	}
	return C.stbtt_InitFont(info, data[0], offset)
}

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

// px_scale returns the stb_truetype scale factor for an em size: pixels per
// design unit. This is the factor stb expects, and it is the reciprocal of what
// Face.scale does, which converts the other way round.
fn (f &Face) px_scale(em_px f64) f32 {
	if f.units_per_em_f <= 0 {
		return 0
	}
	return f32(em_px / f.units_per_em_f)
}

// render_into draws gid into a caller-owned buffer of exactly w*h bytes, at the
// same scale and subpixel shift rasterize_glyph would use. The buffer is the
// caller's so that a C caller can own it outright: a V array dropped across
// the C boundary would have to be freed with the C free, which couples the
// caller to the allocator the V array came from. The C call below is the same
// one rasterize_glyph makes, with the same arguments, so the two agree pixel
// for pixel; stbtt_test.v pins rasterize_glyph and through it this path.
fn (f &Face) render_into(gid u16, em_px f64, sub_x i32, sub_y i32, out &u8, w int, h int) {
	if !f.stb_ok {
		return
	}
	scale := f.px_scale(em_px)
	if scale <= 0 {
		return
	}
	quant := f32(1.0) / 4.0
	fx := f32(sub_x) * quant
	fy := f32(sub_y) * quant
	C.stbtt_MakeGlyphBitmapSubpixel(f.stb_ptr(), out, w, h, w, scale, scale, fx, fy,
		int(gid))
}

// rasterize_glyph renders one glyph at an integer pixel size.
//
// sub_x and sub_y snap the position to quarter-pixel bins, which is what stops
// animated text from shimmering as the pen lands on fractional coordinates.
fn (f &Face) rasterize_glyph(gid u16, em_px f64, sub_x i32, sub_y i32) GlyphBitmap {
	mut out := GlyphBitmap{}
	if !f.stb_ok {
		return out
	}
	scale := f.px_scale(em_px)
	if scale <= 0 {
		return out
	}
	quant := f32(1.0) / 4.0
	fx := f32(sub_x) * quant
	fy := f32(sub_y) * quant
	// i32, not int: these are out-parameters to a C function taking int*, and
	// V int is 64 bits wide. A 32-bit write into a 64-bit slot reads back
	// correctly on little-endian only by accident of the upper half staying
	// zero; naming the width removes the accident.
	mut x0 := i32(0)
	mut y0 := i32(0)
	mut x1 := i32(0)
	mut y1 := i32(0)
	C.stbtt_GetGlyphBitmapBoxSubpixel(f.stb_ptr(), int(gid), scale, scale, fx, fy, &x0, &y0,
		&x1, &y1)
	w := int(x1 - x0)
	h := int(y1 - y0)
	// A corrupt or absurd box must not turn into a huge allocation.
	if w <= 0 || h <= 0 || w > 4096 || h > 4096 {
		return out
	}
	mut buf := []u8{len: w * h}
	f.render_into(gid, em_px, sub_x, sub_y, buf[0], w, h)
	out.coverage = buf
	out.width = w
	out.height = h
	// stb returns the box baseline-relative with y pointing up, so the top of
	// the ink is the negated y0. Flip it so callers only deal with one
	// convention: positive values are distances above the baseline. The same
	// holds for x: stb's x0 is the pen-relative offset of the ink's left
	// edge, so negating it turns it into how far the ink reaches left of
	// the pen, which is what `left` promises and what `pen - left` draws.
	out.left = -x0
	out.top = -y0
	return out
}

// box_only reports a glyph's ink box without rendering it.
//
// The bitmap it returns carries left, top, width and height and no coverage, which is everything a caller
// measuring an extent needs and nothing a caller drawing would want. This is the difference between
// measuring a line and drawing one: rasterize_glyph runs a scanline fill over the whole box and allocates
// a width*height buffer to do it, and a layout pass that wants to know how tall a line is throws all of
// that away. Asking for the box instead skips the fill, skips the allocation, and is what makes measuring
// a paragraph cheap enough to do for every candidate width.
//
// The numbers are the same ones rasterize_glyph would report, and provably so rather than approximately:
// stbtt_GetGlyphBitmapBox is defined in the header as a call to the subpixel form with a shift of zero
// (stb_truetype.h:2739), which is the shift this engine's own no-subpixel path passes.
fn (f &Face) box_only(gid u16, em_px f64) GlyphBitmap {
	mut out := GlyphBitmap{}
	if !f.stb_ok {
		return out
	}
	scale := f.px_scale(em_px)
	if scale <= 0 {
		return out
	}
	mut x0 := i32(0)
	mut y0 := i32(0)
	mut x1 := i32(0)
	mut y1 := i32(0)
	C.stbtt_GetGlyphBitmapBox(f.stb_ptr(), int(gid), scale, scale, &x0, &y0, &x1, &y1)
	out.width = int(x1 - x0)
	out.height = int(y1 - y0)
	// Negated like rasterize_glyph: the box's left edge is a pen-relative
	// offset and `left` is a distance left of the pen.
	out.left = -x0
	// The same sign flip as rasterize_glyph: stb's y points up and this struct's top is a distance
	// above the baseline, so a caller only ever deals with the second convention.
	out.top = -y0
	return out
}
