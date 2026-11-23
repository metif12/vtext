module layout

// Standalone glyph iteration over a laid-out line.
//
// harfara never owns an atlas and never draws; the caller does. This is the
// generic iterator any backend can use: visual-order quads from advances
// plus the line ink box, with an explicit origin. No FONS types, no gg or
// canvas types, no hidden state.

pub enum QuadOrigin {
	top_left
	bottom_left
}

pub struct GlyphQuad {
pub:
	// cluster is the input character index shape.Glyph carries.
	cluster int
	// advance quad in pixels: x0 left, x1 pen-after, y0/y1 baseline box.
	x0 f64
	y0 f64
	x1 f64
	y1 f64
	// uv answers normalized atlas coords for an atlas of the given size.
	s0      f64
	t0      f64
	s1      f64
	t1      f64
	is_mark bool
}

// advance_quads answers one quad per glyph in visual order. The box is the
// advance box (x to x+advance, baseline +- ascent/descent), which is what a
// caller needs to place ink; ink extents come from box_only on the font.
// atlas_w/h convert pixel edges to uv; origin selects y direction.
pub fn advance_quads(line &Line, atlas_w int, atlas_h int, origin QuadOrigin) []GlyphQuad {
	if line.glyphs.len == 0 {
		return []GlyphQuad{}
	}
	mut out := []GlyphQuad{cap: line.glyphs.len}
	aw := if atlas_w > 0 { f64(atlas_w) } else { f64(1) }
	ah := if atlas_h > 0 { f64(atlas_h) } else { f64(1) }
	for g in line.glyphs {
		x0 := g.x
		x1 := g.x + g.advance
		mut y0 := -line.ascent
		mut y1 := line.descent
		if origin == .bottom_left {
			y0, y1 = -y1, -y0
		}
		out << GlyphQuad{
			cluster: g.cluster
			x0:      x0
			y0:      y0
			x1:      x1
			y1:      y1
			s0:      x0 / aw
			t0:      y0 / ah
			s1:      x1 / aw
			t1:      y1 / ah
			is_mark: g.is_mark
		}
	}
	return out
}

// line_ink_box answers the ink extent a caller measures: width from the
// line advance, height from ascent+descent. It is the generic form of
// line_bounds/vert_metrics without any backend state.
pub fn line_ink_box(line &Line) (f64, f64, f64, f64) {
	return 0, -line.ascent, line.width, line.descent
}
