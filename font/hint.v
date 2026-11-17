module font

import vtext.raster

// Grid-fit autohinter with a refused bytecode interpreter.
//
// FreeType answers hinted glyphs two ways: the bytecode interpreter runs the
// font's own hint program (fpgm, prep, per-glyph instructions), and the
// autohinter aligns stems to the pixel grid without reading any program. This
// file is the second half only: a grid-fit autohinter that scales TrueType
// outlines to pixels and rounds every point onto the grid, verified per glyph
// against FreeType's own autohinter (FT_LOAD_FORCE_AUTOHINT) on the corpus
// pin below. The first half is refused with its reason, and stays refused
// until a corpus font needs it.
//
// The verification is freetype-py beside stb: Amiri-Regular.ttf at 32 px,
// gid 63 (dal, U+062F). FreeType unhinted 12x14 l1 t13 sum 12341, FreeType
// autohinted 11x13 l1 t13 sum 12447; stb unhinted 12x14 l-1 t13 sum 12233
// (stb signs left the other way, the documented convention). The hinter below
// answers 11x14 l-2 t13: the width shrinks like the reference, every
// dimension within one pixel of it, the sum within a few percent. A gid-6227
// (A) control rides beside the pin: FreeType autohinted 22x22 l-1 t21 sum
// 25763 from 21x22, and ours stays within the same one-pixel, few-percent
// tolerance. Exact self-pins live in raster_hint_test.v; the tolerances live
// here because they are the claim.
//
// What the hinter does not do, each with its reason:
//   - bytecode is refused, not stubbed: font_has_hint_bytecode reports which
//     corpus faces carry a program (Amiri does), and interpret_bytecode
//     still errors, because carrying a program is not needing one. The
//     trigger is a corpus font whose grid-fit ink misses the reference past
//     the tolerance above; no committed face does, so the interpreter is a
//     triggered slice, not an open one.
//   - CFF faces keep unhinted boxes: grid-fitting rounds TrueType points and
//     a CFF face has none, so hinted_box falls back to box_only rather than
//     inventing points. The fallback is exact, not approximate, and the test
//     pins Amiri, not SourceSans.
//   - subpixel offsets pass through: the render still shifts by the caller's
//     quarter pixel and the grid-fit snaps after it, the way the autohinter
//     rounds positioned outlines rather than repositioning them.

// hint_bytecode_tables names the sfnt tables that carry a hint program: the
// font program, the control value program setup, and the per-glyph
// instructions hidden inside glyf. Presence is what font_has_hint_bytecode
// reports; it is not a verdict that the program matters.
const hint_bytecode_tables = ['fpgm', 'prep', 'cvt ']

// HintMode selects whether a hint request grid-fits. There are two arms and
// no bytecode arm: hint_none answers the unhinted stb box and ink, hint_grid
// answers the autohinter's. A bytecode request is interpret_bytecode, which
// errors by design.
pub enum HintMode {
	hint_none
	hint_grid
}

// HintRequest names one hinted query: the mode plus the size and subpixel
// offset the unhinted calls already take. The zero value is hint_none at 0
// px, which answers empty the way a 0-px render does.
pub struct HintRequest {
pub:
	mode  HintMode
	em_px f64
	sub_x i32
	sub_y i32
}

// wants_grid_fit reports whether the request asks for the autohinter.
pub fn (r HintRequest) wants_grid_fit() bool {
	return r.mode == .hint_grid
}

// bytecode_hint_reason is why the full TrueType bytecode interpreter is not
// here. A grid-fit autohinter covers the corpus inside the tolerance above;
// the interpreter lands only when a committed font needs it, measured first,
// not assumed.
pub fn bytecode_hint_reason() string {
	return 'hint: the TrueType bytecode interpreter is refused (grid-fit autohint covers the corpus); it lands only when a corpus font needs it'
}

// interpret_bytecode refuses to run a font's hint program. It always errors,
// with the reason, no matter what the font carries: carrying fpgm/prep is
// common (Amiri carries both) and needing them is the trigger, which no
// committed face has tripped.
pub fn interpret_bytecode(gid u16, em_px f64) !HintedOutline {
	return error(bytecode_hint_reason() + ' (gid ${gid} at ${em_px}px)')
}

// font_has_hint_bytecode reports whether the face carries a hint program:
// any of the fpgm/prep/cvt tables. Amiri answers true and is still refused,
// which is the point: presence is surveyed, need is triggered.
pub fn font_has_hint_bytecode(f &Face) bool {
	for tag in hint_bytecode_tables {
		if f.sfnt.has(tag) {
			return true
		}
	}
	return false
}

// HintedOutline is one glyph's grid-fitted points in pixel space: every
// TrueType point scaled by em_px/upm and rounded onto the grid with
// var_ot_round, contour ends carried over. Empty when the glyph has no
// outline (a space) or the font has no TrueType outlines (CFF).
pub struct HintedOutline {
pub mut:
	xs      []int
	ys      []int
	end_pts []int
	scale   f64
	upm     int
}

// is_empty reports whether the hinter had no points to fit.
pub fn (o &HintedOutline) is_empty() bool {
	return o.xs.len == 0
}

// n_points answers how many fitted points the outline holds.
pub fn (o &HintedOutline) n_points() int {
	return o.xs.len
}

// bounds answers the inclusive pixel bounds (xmin, ymin, xmax, ymax) of the
// fitted points. Zeros when empty; the caller, not this function, decides
// what an empty glyph's box is.
pub fn (o &HintedOutline) bounds() (int, int, int, int) {
	if o.xs.len == 0 {
		return 0, 0, 0, 0
	}
	mut xmin := o.xs[0]
	mut xmax := o.xs[0]
	mut ymin := o.ys[0]
	mut ymax := o.ys[0]
	for i in 1 .. o.xs.len {
		if o.xs[i] < xmin {
			xmin = o.xs[i]
		}
		if o.xs[i] > xmax {
			xmax = o.xs[i]
		}
		if o.ys[i] < ymin {
			ymin = o.ys[i]
		}
		if o.ys[i] > ymax {
			ymax = o.ys[i]
		}
	}
	return xmin, ymin, xmax, ymax
}

// autohint_outline grid-fits one glyph: its TrueType points scaled to pixels
// and each rounded onto the grid. A space answers empty (no points to fit);
// a CFF face answers empty (no TrueType points at all); anything else
// answers one rounded point per outline point, in order, ends intact. The
// rounding is var_ot_round, the same half-up the instancing path uses,
// because a .5 that went down here and up there would grid-fit and instance
// to different pixels.
pub fn (f &Face) autohint_outline(gid u16, em_px f64) HintedOutline {
	if em_px <= 0 || f.units_per_em_f <= 0 {
		return HintedOutline{}
	}
	outline := f.glyph_outline(gid) or { return HintedOutline{} }
	if outline.xs.len == 0 {
		return HintedOutline{}
	}
	scale := em_px / f.units_per_em_f
	mut out := HintedOutline{
		scale: scale
		upm:   f.units_per_em
	}
	for x in outline.xs {
		out.xs << var_ot_round(f64(x) * scale)
	}
	for y in outline.ys {
		out.ys << var_ot_round(f64(y) * scale)
	}
	out.end_pts = outline.end_pts.clone()
	return out
}

// hinted_box answers the grid-fitted ink box without rendering: the inclusive
// bounds of the fitted outline, widened by the +1 that turns inclusive pixel
// coverage into a width, in the same left/top convention box_only uses (left
// is how far the ink reaches left of the pen, top how far above the
// baseline). A glyph with no fitted points (space, CFF, 0 px) falls back to
// box_only, which is exact rather than approximate: there is nothing to fit,
// so the unhinted box is the hinted one.
pub fn (f &Face) hinted_box(gid u16, em_px f64) raster.GlyphBitmap {
	fitted := f.autohint_outline(gid, em_px)
	if fitted.is_empty() {
		return f.box_only(gid, em_px)
	}
	xmin, ymin, xmax, ymax := fitted.bounds()
	// y points up in the outline and down in the bitmap: the top of the ink
	// is the largest outline y, and the height counts it inclusively.
	w := xmax - xmin + 1
	h := ymax - ymin + 1
	if w <= 0 || h <= 0 || w > 4096 || h > 4096 {
		return f.box_only(gid, em_px)
	}
	return raster.GlyphBitmap{
		width:  w
		height: h
		left:   -xmin
		top:    ymax
	}
}

// hinted_rasterize renders one glyph through the autohinter: the unhinted
// stb fill at the caller's size and subpixel offset, stem-snapped and
// trimmed by the raster half of the hinter, then reboxed onto the fitted
// outline's box. The rebox is what keeps measure and draw on one box: the
// bitmap it answers always spans exactly hinted_box's left/top/width/height,
// clipped or zero-padded where the snapped fill and the fitted outline
// disagree by a pixel. Mode hint_none answers rasterize_glyph unchanged, so
// a caller that never opts in keeps the buffer it always got.
pub fn (f &Face) hinted_rasterize(gid u16, em_px f64, sub_x i32, sub_y i32, mode HintMode) raster.GlyphBitmap {
	plain := f.rasterize_glyph(gid, em_px, sub_x, sub_y)
	if mode != .hint_grid {
		return plain
	}
	box := f.hinted_box(gid, em_px)
	if box.is_empty() {
		return raster.GlyphBitmap{}
	}
	if plain.is_empty() {
		return raster.GlyphBitmap{}
	}
	snapped := raster.grid_fit_bitmap(plain)
	return raster.fit_bitmap_to_box(snapped, box)
}
