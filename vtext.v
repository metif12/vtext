module vtext

// vtext is a text shaping and rendering engine written in V.
//
// The pipeline is: Unicode itemisation -> bidirectional reordering -> OpenType
// shaping -> font fallback -> line layout -> glyph atlas -> draw. Everything is
// V except the outline rasteriser, which reuses the public-domain
// stb_truetype header that already ships inside V's own thirdparty tree, so
// importing this module adds no new external dependency.

import os

// Font is a loaded font file. It is the entry point for metrics, glyph lookup
// and rasterisation.
pub struct Font {
mut:
	face &Face
	path string
}

// load_font_file reads and parses a font from disk.
pub fn load_font_file(path string) !&Font {
	data := os.read_bytes(path) or { return error('cannot read font "${path}": ${err}') }
	mut f := Font{
		face: new_face(data) or { return error('cannot parse font "${path}": ${err}') }
		path: path
	}
	return &f
}

// load_font_bytes parses a font already held in memory.
pub fn load_font_bytes(data []u8) !&Font {
	mut f := Font{
		face: new_face(data) or { return error('cannot parse font: ${err}') }
	}
	return &f
}

// path returns where the font was loaded from, or an empty string when it came
// from memory.
pub fn (f &Font) path() string {
	return f.path
}

// units_per_em is the font's design grid size.
pub fn (f &Font) units_per_em() int {
	return f.face.units_per_em
}

// num_glyphs is the number of glyphs the font contains.
pub fn (f &Font) num_glyphs() int {
	return f.face.num_glyphs
}

// is_monospaced reports whether every glyph shares one advance.
pub fn (f &Font) is_monospaced() bool {
	return f.face.is_fixed_pitch
}

// is_cff_outlined reports whether outlines are CFF rather than TrueType.
pub fn (f &Font) is_cff_outlined() bool {
	return f.face.sfnt.is_cff()
}

// ascent is the distance above the baseline, in pixels at the given em size.
pub fn (f &Font) ascent(em_px f64) f64 {
	return f.face.ascent(em_px)
}

// descent is the distance below the baseline, in pixels, always positive.
pub fn (f &Font) descent(em_px f64) f64 {
	return f.face.descent(em_px)
}

// line_height is the baseline-to-baseline distance in pixels.
pub fn (f &Font) line_height(em_px f64) f64 {
	return f.face.line_height(em_px)
}

// glyph_index maps a codepoint to a glyph index. Zero means .notdef, which for
// a codepoint the font does not cover is the correct answer.
pub fn (f &Font) glyph_index(cp rune) u16 {
	return f.face.glyph_index(cp)
}

// has_glyph reports whether the font really covers cp. Font fallback needs this
// distinction: a font that maps cp to .notdef is not a candidate for it.
pub fn (f &Font) has_glyph(cp rune) bool {
	return f.face.has_glyph(cp)
}

// glyph_advance is the horizontal advance of a glyph in pixels.
pub fn (f &Font) glyph_advance(gid u16, em_px f64) f64 {
	return f.face.glyph_advance(gid, em_px)
}

// underline_thickness is the recommended underline weight in pixels.
pub fn (f &Font) underline_thickness(em_px f64) f64 {
	return f.face.scale(f.face.underline_thickness, em_px)
}

// underline_position is the recommended underline offset from the baseline,
// in pixels, positive downwards.
pub fn (f &Font) underline_position(em_px f64) f64 {
	return f.face.scale(f.face.underline_position, em_px)
}

// rasterize renders a glyph. sub_x and sub_y select a quarter-pixel bin, so
// callers can round to 0, 0.25, 0.5 or 0.75 of a pixel.
pub fn (f &Font) rasterize(gid u16, em_px f64, sub_x i32, sub_y i32) GlyphBitmap {
	return f.face.rasterize_glyph(gid, em_px, sub_x, sub_y)
}

// num_cmap_subtables reports how many character maps the font offers. More than
// one is normal; the highest-scoring Unicode subtable is used.
pub fn (f &Font) num_cmap_subtables() int {
	return f.face.cmaps.len
}
