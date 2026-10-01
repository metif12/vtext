module vtext

// vtext is a text shaping and rendering engine written in V.
//
// The pipeline is: normalization -> Unicode itemisation -> bidirectional
// reordering -> OpenType shaping -> font fallback -> line layout -> glyph atlas ->
// draw. Everything is V except the outline rasteriser, which reuses the
// public-domain stb_truetype header that already ships inside V's own thirdparty
// tree, so importing this module adds no new external dependency.

import os

// Context holds the decoded Unicode tables the pipeline needs, and is built once per
// text system. The tables are immutable, so a single Context can be shared between
// threads and between faces.
//
// Building one costs a few hundred microseconds, which is a lot compared with
// shaping a short string, so this is not something to do per call.
pub struct Context {
pub:
	// properties holds the character properties: bidi class, joining type and group,
	// combining class, script, grapheme class and line break class.
	properties &Properties
	// normalizer holds the canonical decomposition and composition tables of UAX#15.
	normalizer &Normalizer
	// shaper holds the Arabic presentation forms, which the joining pass maps onto.
	shaper &Shaper
}

// new_context decodes every table. The caller owns the result and keeps it for the
// lifetime of the text system.
pub fn new_context() &Context {
	tables := new_properties()
	return &Context{
		properties: tables
		normalizer: new_normalizer(*tables)
		shaper:     new_shaper()
	}
}

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

// substitute_glyphs applies the font's substitution features to a run of glyphs.
//
// This is what the joining pass cannot do on its own. It knows that a lam and an alef are one
// shape, and it says so with a presentation form codepoint, but whether the font has a glyph for
// that form, and how wide it is, are questions only the font can answer. A lam-alef drawn as
// two letters is legible and wrong: the pair is narrower fused than apart, so a line built that
// way is the wrong length.
//
// The features applied by default are ccmp and rlig, in the order the specification gives them, so
// that a mark which composes into a single glyph is not then swallowed by a rule written for the
// pair. Those two are on for every line because a line missing its mark composition is not the
// text, and neither of them is a presentation choice.
//
// Discretionary features are not applied here. liga is the one that matters for Persian, where
// several letter pairs have codepoint reachable ligature forms, and turning it on changes the width
// of the text, so it belongs to whoever asked for the line rather than to the engine. A caller
// that wants one names it in extra, and it is applied after the required features, which is the
// order the specification gives discretionary features.
pub fn (f &Font) substitute_glyphs(glyphs []Glyph, script string, em_px f64,
	extra []string) []Glyph {
	g := f.face.gsub or { return glyphs }
	mut out := []Ligatable{cap: glyphs.len}
	for i, glyph in glyphs {
		out << Ligatable{
			gid:     glyph.gid
			cluster: glyph.cluster
			source:  i
		}
	}
	for feature in ['ccmp', 'rlig'] {
		out = g.substitute(g.lookups_for(script, feature), out)
	}
	for feature in extra {
		out = g.substitute(g.lookups_for(script, feature), out)
	}
	// Every advance is read again, not just the fused ones, so the advance always belongs to the
	// glyph it is on. A ligature is usually narrower than the glyphs it replaced, and carrying
	// the first letter's advance over would leave the line the wrong length in exactly the way
	// the ligature was meant to fix.
	mut result := []Glyph{cap: out.len}
	for item in out {
		mut glyph := glyphs[item.source]
		glyph.gid = item.gid
		glyph.cluster = item.cluster
		// A mark never advances the pen, whatever glyph it ended up as, so its zero advance is
		// kept rather than measured. Measuring it would give a mark the width of its outline and
		// push everything after it along the line.
		if !glyph.is_mark {
			glyph.advance = f.glyph_advance(item.gid, em_px)
		}
		result << glyph
	}
	return result
}

// has_gsub reports whether the font carries glyph substitution, which is what decides whether
// it can draw a letter in anything but its base shape.
pub fn (f &Font) has_gsub() bool {
	return f.face.gsub != none
}

// has_mark_attachment reports whether the font says where a mark goes on the letter it
// belongs to. A font without it draws the mark at the pen position, which for an Arabic letter
// is beside the letter rather than on it.
pub fn (f &Font) has_mark_attachment() bool {
	g := f.face.gpos or { return false }
	return g.has_mark_attachment()
}

// is_mark_glyph reports whether the font classifies this glyph as a combining mark. The
// classification comes from the font rather than from Unicode, because the font is what decides
// how its own glyphs are used.
pub fn (f &Font) is_mark_glyph(gid u16) bool {
	g := f.face.gdef or { return false }
	return g.is_mark(gid)
}

// mark_offset returns where to draw a mark relative to the origin of the glyph it belongs to, in
// design units, with y positive upwards as the font's own coordinates run.
//
// base_is_mark says what the second glyph is, because the three rules a mark can be placed by are
// three different tables: over a letter is mark-to-base, over another mark is mark-to-mark, and
// over a ligature is mark-to-ligature. A font that uses one of them for a pair has nothing to say
// about the pair in the others, so the caller has to say which situation it is in.
//
// found is false when the font has no rule for this pair, or has none for this mark's class on
// this glyph. That is not an error: it is a font that does not say, and the caller is expected to
// leave the mark where the pen is rather than invent a position.
pub fn (f &Font) mark_offset(mark_gid u16, base_gid u16, base_is_mark bool) ?Offset2 {
	gpos := f.face.gpos or { return none }
	return gpos.mark_offset(mark_gid, base_gid, base_is_mark)
}

// kern_offset returns how far to move one glyph when another follows it, in design units, with y
// positive upwards as the font's own coordinates run.
//
// The two glyphs are given in the order the text reads them, which for a right-to-left script means
// the rightmost glyph first. That is the order the font's rules are written in, and the reverse
// order finds nothing: a font that kerns a pair tightly has a rule for that pair in reading order
// and none for it backwards, so the line comes out slightly too wide rather than visibly wrong.
//
// script is the script the pair is in, because a font may kern one script differently from another
// and applying the wrong script's rules is worse than applying none.
//
// A pair the font says nothing about returns none, and so does a pair it says is already correct as
// far as this position is concerned, because a zero adjustment and no adjustment cannot be told
// apart by the number alone and neither one moves the pen.
pub fn (f &Font) kern_offset(left_gid u16, right_gid u16, script string) ?Offset2 {
	gpos := f.face.gpos or { return none }
	return gpos.kern_offset(left_gid, right_gid, script)
}

// kerns reports whether the font has any pair adjustment for a script.
pub fn (f &Font) kerns(script string) bool {
	gpos := f.face.gpos or { return false }
	return gpos.has_kerning(script)
}

// places_marks_on_ligatures reports whether the font can position a mark on a fused pair, which
// decides whether a mark after a lam-alef has a chance of landing anywhere useful.
pub fn (f &Font) places_marks_on_ligatures() bool {
	gpos := f.face.gpos or { return false }
	return gpos.has_mark_to_ligature()
}

// stacks_marks reports whether the font can position one mark on another, which is what a shadda
// carrying a fatha needs.
pub fn (f &Font) stacks_marks() bool {
	gpos := f.face.gpos or { return false }
	return gpos.has_mark_to_mark()
}

// shaped_glyph_index applies the font's positional features to a base glyph and returns the
// glyph that carries the shape.
//
// This is the step a font needs when it keeps its Arabic shapes in GSUB rather than in the
// cmap. A font with no such table, or no rule for this letter, returns the base glyph, which
// renders the letter correctly but unjoined.
//
// script is the script of the letter, so a font offering the same feature tag for several
// scripts resolves the right rule.
pub fn (f &Font) shaped_glyph_index(gid u16, form JoiningForm, script string) u16 {
	g := f.face.gsub or { return gid }
	return g.shaped_glyph(gid, form, script)
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
