module font

import math
import harfara.raster

// CFF2 raster backend: default-instance outlines through the interpreter,
// flattened and filled in-tree. stb_truetype parses CFF1 but not CFF2, so a
// CFF2 face has no stb path; this file is that path.
//
// A glyph draws its CharString at the default instance (non-default
// instancing blends the same outline against the VarStore and is a separate
// slice), scales it to pixels with the caller's subpixel shift, flattens the
// cubics, and fills with the same 4x4-supersampled even-odd rule the
// instanced gvar raster uses. Even-odd rather than nonzero: every corpus
// contour agrees under both rules, and the pins below would catch a glyph
// that does not. The box is the floor/ceil of the flattened polygons in the
// same left/top convention box_only uses, so measuring and drawing agree.

// Cff2Point is one flattened pixel-space point of a CFF2 outline.
struct Cff2Point {
	x f64
	y f64
}

// cff2_flatten_tol is the pixel-space flatness bound: a cubic is subdivided
// until both controls sit within this of the chord. 0.05 keeps the box error
// an order of magnitude below the floor/ceil boundary on every corpus pin,
// and depth 12 terminates hostile curves.
const cff2_flatten_tol = 0.05

// cff2_flatten_cubic appends p3's subdivision: one segment when the controls
// sit within tol of the chord, two halves of recursion otherwise. The same
// adaptive shape as the quad flatteners, one degree up; endpoints land
// exactly on the curve, so the polyline never overshoots it.
fn cff2_flatten_cubic(p0 Cff2Point, p1 Cff2Point, p2 Cff2Point, p3 Cff2Point, tol f64, depth int, mut out []Cff2Point) {
	dx := p3.x - p0.x
	dy := p3.y - p0.y
	len2 := dx * dx + dy * dy
	mut d := 0.0
	if len2 == 0.0 {
		dx1 := p1.x - p0.x
		dy1 := p1.y - p0.y
		dx2 := p2.x - p0.x
		dy2 := p2.y - p0.y
		d = math.sqrt(math.max(dx1 * dx1 + dy1 * dy1, dx2 * dx2 + dy2 * dy2))
	} else {
		len := math.sqrt(len2)
		// Distance of each control from the chord, abs of the cross product
		// over the chord length.
		c1 := math.abs((p1.x - p0.x) * dy - (p1.y - p0.y) * dx) / len
		c2 := math.abs((p2.x - p0.x) * dy - (p2.y - p0.y) * dx) / len
		d = if c1 > c2 { c1 } else { c2 }
	}
	if depth >= 12 || d <= tol {
		out << p3
		return
	}
	// De Casteljau at one half.
	mx1 := (p0.x + p1.x) / 2.0
	my1 := (p0.y + p1.y) / 2.0
	mx2 := (p1.x + p2.x) / 2.0
	my2 := (p1.y + p2.y) / 2.0
	mx3 := (p2.x + p3.x) / 2.0
	my3 := (p2.y + p3.y) / 2.0
	ax := (mx1 + mx2) / 2.0
	ay := (my1 + my2) / 2.0
	bx := (mx2 + mx3) / 2.0
	by := (my2 + my3) / 2.0
	cx := (ax + bx) / 2.0
	cy := (ay + by) / 2.0
	cff2_flatten_cubic(p0, Cff2Point{mx1, my1}, Cff2Point{ax, ay}, Cff2Point{cx, cy},
		tol, depth + 1, mut out)
	cff2_flatten_cubic(Cff2Point{cx, cy}, Cff2Point{bx, by}, Cff2Point{mx3, my3}, p3,
		tol, depth + 1, mut out)
}

// cff2_outline_polys interprets gid's CharString and answers its contours in
// pixel space: scaled by em_px over the face's units, y flipped to point
// down, shifted by the caller's quarter-pixel bins. Curves are flattened;
// lines pass through. Every contour the interpreter closes is one polygon.
fn (c &Cff2) cff2_outline_polys(gid int, scale f64, fx f64, fy f64) ![][]Cff2Point {
	o := c.outline(gid) or { return err }
	mut polys := [][]Cff2Point{}
	mut cur := []Cff2Point{}
	shift := fn (x f64, y f64, s f64, ox f64, oy f64) Cff2Point {
		return Cff2Point{x * s + ox, -y * s + oy}
	}
	for op in o.ops {
		match op.kind {
			.move_to {
				if cur.len > 0 {
					polys << cur
				}
				cur = [shift(op.pts[0], op.pts[1], scale, fx, fy)]
			}
			.line_to {
				if cur.len == 0 {
					cur << Cff2Point{fx, fy}
				}
				cur << shift(op.pts[0], op.pts[1], scale, fx, fy)
			}
			.curve_to {
				if cur.len == 0 {
					cur << Cff2Point{fx, fy}
				}
				p0 := cur[cur.len - 1]
				p3 := shift(op.pts[4], op.pts[5], scale, fx, fy)
				cff2_flatten_cubic(p0, shift(op.pts[0], op.pts[1], scale, fx, fy),
					shift(op.pts[2], op.pts[3], scale, fx, fy), p3, cff2_flatten_tol,
					0, mut cur)
			}
			.close_path {
				if cur.len > 0 {
					polys << cur
					cur = []Cff2Point{}
				}
			}
		}
	}
	if cur.len > 0 {
		polys << cur
	}
	return polys
}

// cff2_even_odd answers whether a sample sits inside the flattened outline:
// a ray to the right crosses an odd number of edges. The same rule the
// instanced gvar fill uses, repeated for Cff2Point so the fill stays beside
// the flattening it fills.
fn cff2_even_odd(x f64, y f64, polys [][]Cff2Point) bool {
	mut inside := false
	for poly in polys {
		if poly.len < 3 {
			continue
		}
		mut j := poly.len - 1
		for i in 0 .. poly.len {
			xi := poly[i].x
			yi := poly[i].y
			xj := poly[j].x
			yj := poly[j].y
			if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi {
				inside = !inside
			}
			j = i
		}
	}
	return inside
}

// cff2_box_of answers the ink box of flattened polygons: floor/ceil in the
// same left/top convention box_only uses. Coverageless, like box_only.
fn cff2_box_of(polys [][]Cff2Point) raster.GlyphBitmap {
	mut first := true
	mut xmin := 0.0
	mut xmax := 0.0
	mut ymin := 0.0
	mut ymax := 0.0
	for poly in polys {
		for p in poly {
			if first {
				xmin = p.x
				xmax = p.x
				ymin = p.y
				ymax = p.y
				first = false
				continue
			}
			if p.x < xmin {
				xmin = p.x
			}
			if p.x > xmax {
				xmax = p.x
			}
			if p.y < ymin {
				ymin = p.y
			}
			if p.y > ymax {
				ymax = p.y
			}
		}
	}
	if first {
		return raster.GlyphBitmap{}
	}
	ix0 := int(math.floor(xmin))
	ix1 := int(math.ceil(xmax))
	iy0 := int(math.floor(ymin))
	iy1 := int(math.ceil(ymax))
	w := ix1 - ix0
	h := iy1 - iy0
	if w <= 0 || h <= 0 || w > 4096 || h > 4096 {
		return raster.GlyphBitmap{}
	}
	return raster.GlyphBitmap{
		width:  w
		height: h
		left:   -ix0
		top:    -iy0
	}
}

// cff2_fill_bitmap fills the box with the 4x4-supersampled even-odd cover,
// the same sample grid the instanced fill uses so the two agree pixel for
// pixel on the same polygons.
fn cff2_fill_bitmap(box raster.GlyphBitmap, polys [][]Cff2Point) raster.GlyphBitmap {
	if box.is_empty() || polys.len == 0 {
		return raster.GlyphBitmap{}
	}
	ix0 := -box.left
	iy0 := -box.top
	mut cov := []u8{len: box.width * box.height}
	for dy in 0 .. box.height {
		for dx in 0 .. box.width {
			mut hit := 0
			for sy in 0 .. 4 {
				for sx in 0 .. 4 {
					px := f64(ix0 + dx) + (f64(sx) + 0.5) / 4.0
					py := f64(iy0 + dy) + (f64(sy) + 0.5) / 4.0
					if cff2_even_odd(px, py, polys) {
						hit++
					}
				}
			}
			cov[dy * box.width + dx] = u8((hit * 255 + 8) / 16)
		}
	}
	return raster.GlyphBitmap{
		coverage: cov
		width:    box.width
		height:   box.height
		left:     box.left
		top:      box.top
	}
}

// cff2_box answers gid's ink box without rendering, through the interpreter
// and the flattener. Empty when the glyph has no ink or the face has no
// usable CFF2 table.
pub fn (f &Face) cff2_box(gid u16, em_px f64, sub_x i32, sub_y i32) raster.GlyphBitmap {
	c := f.cff2 or { return raster.GlyphBitmap{} }
	if em_px <= 0 || f.units_per_em_f <= 0 {
		return raster.GlyphBitmap{}
	}
	scale := em_px / f.units_per_em_f
	polys := c.cff2_outline_polys(int(gid), scale, f64(sub_x) * 0.25, f64(sub_y) * 0.25) or {
		return raster.GlyphBitmap{}
	}
	return cff2_box_of(polys)
}

// cff2_bitmap renders gid's default-instance outline at em_px and the
// caller's shift: the box from cff2_box with coverage from the same
// polygons, so measuring and drawing agree.
pub fn (f &Face) cff2_bitmap(gid u16, em_px f64, sub_x i32, sub_y i32) raster.GlyphBitmap {
	c := f.cff2 or { return raster.GlyphBitmap{} }
	if em_px <= 0 || f.units_per_em_f <= 0 {
		return raster.GlyphBitmap{}
	}
	scale := em_px / f.units_per_em_f
	polys := c.cff2_outline_polys(int(gid), scale, f64(sub_x) * 0.25, f64(sub_y) * 0.25) or {
		return raster.GlyphBitmap{}
	}
	return cff2_fill_bitmap(cff2_box_of(polys), polys)
}

// cff2_render_into fills the caller's w*h buffer with gid's outline at the
// caller's shift, positioned the way render_into positions stb ink: buffer
// pixel (dx, dy) covers the square at the shifted origin plus (dx, dy).
pub fn (f &Face) cff2_render_into(gid u16, em_px f64, sub_x i32, sub_y i32, out &u8, w int, h int) {
	c := f.cff2 or { return }
	if w <= 0 || h <= 0 || em_px <= 0 || f.units_per_em_f <= 0 {
		return
	}
	scale := em_px / f.units_per_em_f
	polys := c.cff2_outline_polys(int(gid), scale, f64(sub_x) * 0.25, f64(sub_y) * 0.25) or {
		return
	}
	box := cff2_box_of(polys)
	if box.is_empty() {
		return
	}
	ix0 := -box.left
	iy0 := -box.top
	unsafe {
		for dy in 0 .. h {
			for dx in 0 .. w {
				mut hit := 0
				for sy in 0 .. 4 {
					for sx in 0 .. 4 {
						px := f64(ix0 + dx) + (f64(sx) + 0.5) / 4.0
						py := f64(iy0 + dy) + (f64(sy) + 0.5) / 4.0
						if cff2_even_odd(px, py, polys) {
							hit++
						}
					}
				}
				out[dy * w + dx] = u8((hit * 255 + 8) / 16)
			}
		}
	}
}
