module raster

import math

// Flattened outline stroker with FT_Stroker parity (joins, caps, miter limit).
//
// FreeType answers stroked outlines behind FT_Stroker_Set (radius, line cap,
// line join, miter limit) plus FT_Stroker_ParseOutline over the glyph outline.
// This file is the same contract over the same inputs: radius is half the
// stroke width in the outline's own units, caps close open paths (butt,
// round, square), joins resolve every corner (miter, bevel, round) with a
// miter-length-over-radius limit that falls back to bevel, and TrueType
// quadratic curves flatten to lines at the caller's tolerance before any
// offsetting happens.
//
// A closed contour (every glyf contour) strokes to two loops: the offsets to
// either side, the second reversed so the pair answers opposite orientations
// and a nonzero fill paints the ring between them. An open polyline strokes
// to one loop closed by its caps. Output is polygons only, so on_curve is
// always true; coordinates stay f64 because offsets and arcs are fractional
// in design units. font never feeds this file its own outline struct (that
// would cycle: font already imports raster), so the stroker takes the same
// slices Face.glyph_outline answers rather than the struct itself.

// StrokeLineCap closes an open path: butt cuts flush at the endpoint, round
// draws the semicircle, square extends past the endpoint by the radius.
pub enum StrokeLineCap {
	butt
	round
	square
}

// StrokeLineJoin resolves the outer side of a corner: miter runs the offset
// edges to their intersection, bevel cuts the corner off, round draws the arc.
pub enum StrokeLineJoin {
	miter
	bevel
	round
}

// StrokeOptions selects the stroke. radius is half the stroke width in the
// outline's own units; miter_limit caps the miter length as a multiple of
// the radius (FreeType's 4.0 default); tolerance caps the flatten error per
// quadratic segment in the same units. Non-positive radius answers empty;
// non-positive miter_limit and tolerance take their defaults.
pub struct StrokeOptions {
pub:
	radius      f64
	line_cap    StrokeLineCap
	line_join   StrokeLineJoin
	miter_limit f64
	tolerance   f64
}

// StrokedOutline is one stroked outline: polygon loops back to back,
// end_pts marking each loop's last point index. on_curve is always true;
// loops carry no curves because every curve flattens before offsetting.
pub struct StrokedOutline {
pub mut:
	xs       []f64
	ys       []f64
	on_curve []bool
	end_pts  []int
}

// n_points answers how many points the stroked loops hold.
pub fn (o &StrokedOutline) n_points() int {
	return o.xs.len
}

// n_contours answers how many loops the stroke holds: two per closed input
// contour, one per open polyline.
pub fn (o &StrokedOutline) n_contours() int {
	return o.end_pts.len
}

// bbox answers the stroked loops' bounding box, or zeros when empty.
pub fn (o &StrokedOutline) bbox() (f64, f64, f64, f64) {
	if o.xs.len == 0 {
		return 0, 0, 0, 0
	}
	mut x0 := o.xs[0]
	mut y0 := o.ys[0]
	mut x1 := o.xs[0]
	mut y1 := o.ys[0]
	for i in 1 .. o.xs.len {
		if o.xs[i] < x0 {
			x0 = o.xs[i]
		}
		if o.xs[i] > x1 {
			x1 = o.xs[i]
		}
		if o.ys[i] < y0 {
			y0 = o.ys[i]
		}
		if o.ys[i] > y1 {
			y1 = o.ys[i]
		}
	}
	return x0, y0, x1, y1
}

// area answers the stroked ink: the absolute of the summed signed loop
// areas. The closed-contour loops ship with opposite orientations, so the
// inner loop cancels the outer the way a nonzero fill would and the answer
// is the ring's area rather than two stacked disks.
pub fn (o &StrokedOutline) area() f64 {
	mut total := 0.0
	mut base := 0
	for c in 0 .. o.end_pts.len {
		e := o.end_pts[c]
		if e < base || e >= o.xs.len {
			base = e + 1
			continue
		}
		mut s := 0.0
		for i in base .. e + 1 {
			j := if i == e { base } else { i + 1 }
			s += o.xs[i] * o.ys[j] - o.xs[j] * o.ys[i]
		}
		total += s
		base = e + 1
	}
	return math.abs(total) / 2.0
}

// stroke_default_miter_limit is the FT_Stroker_Set default: a miter longer
// than four radii falls back to bevel.
pub const stroke_default_miter_limit = 4.0

// stroke_default_tolerance caps the flatten error at one design unit, the
// same order as the reader's own integer rounding.
pub const stroke_default_tolerance = 1.0

// default_stroke_options answers a mitered butt-capped stroke of half-width
// radius with the default limit and tolerance.
pub fn default_stroke_options(radius f64) StrokeOptions {
	return StrokeOptions{
		radius:      radius
		line_cap:    StrokeLineCap.butt
		line_join:   StrokeLineJoin.miter
		miter_limit: stroke_default_miter_limit
		tolerance:   stroke_default_tolerance
	}
}

// stroke_limit resolves the effective miter limit.
fn stroke_limit(opt StrokeOptions) f64 {
	if opt.miter_limit > 0 {
		return opt.miter_limit
	}
	return stroke_default_miter_limit
}

// stroke_tolerance resolves the effective flatten tolerance.
fn stroke_tolerance(opt StrokeOptions) f64 {
	if opt.tolerance > 0 {
		return opt.tolerance
	}
	return stroke_default_tolerance
}

// SPoint is one flattened design-space point.
struct SPoint {
	x f64
	y f64
}

// s_len answers a vector's length.
fn s_len(a SPoint) f64 {
	return math.sqrt(a.x * a.x + a.y * a.y)
}

// s_norm answers the unit vector along a, or zero for a zero vector.
fn s_norm(a SPoint) SPoint {
	l := s_len(a)
	if l < 1e-12 {
		return SPoint{ x: 0, y: 0 }
	}
	return SPoint{ x: a.x / l, y: a.y / l }
}

// s_left_normal answers the unit normal left of a unit direction.
fn s_left_normal(d SPoint) SPoint {
	return SPoint{ x: -d.y, y: d.x }
}

// s_cross answers the 2D cross product: positive when b turns left of a.
fn s_cross(a SPoint, b SPoint) f64 {
	return a.x * b.y - a.y * b.x
}

// s_dot answers the dot product.
fn s_dot(a SPoint, b SPoint) f64 {
	return a.x * b.x + a.y * b.y
}

// line_intersect answers where the line through a along da meets the line
// through b along db, or false when they run parallel.
fn line_intersect(a SPoint, da SPoint, b SPoint, db SPoint) (SPoint, bool) {
	denom := s_cross(da, db)
	if math.abs(denom) < 1e-12 {
		return SPoint{ x: 0, y: 0 }, false
	}
	t := ((b.x - a.x) * db.y - (b.y - a.y) * db.x) / denom
	return SPoint{ x: a.x + da.x * t, y: a.y + da.y * t }, true
}

// append_arc appends the circle of radius r around c from angle a0 to a1,
// sweeping in dir's sign (+1 counter-clockwise, -1 clockwise). Steps hold
// fifteen degrees each, so a quarter arc draws six segments.
fn append_arc(mut loop []SPoint, c SPoint, r f64, a0 f64, a1 f64, dir f64) {
	two := 2.0 * math.pi
	mut sweep := a1 - a0
	if dir > 0 {
		for sweep < 0 {
			sweep += two
		}
		for sweep >= two {
			sweep -= two
		}
	} else {
		for sweep > 0 {
			sweep -= two
		}
		for sweep <= -two {
			sweep += two
		}
	}
	if math.abs(sweep) < 1e-12 {
		return
	}
	mut steps := int(math.ceil(math.abs(sweep) / (math.pi / 12.0) - 1e-9))
	if steps < 1 {
		steps = 1
	}
	if steps > 64 {
		steps = 64
	}
	for k in 0 .. steps + 1 {
		a := a0 + sweep * f64(k) / f64(steps)
		loop << SPoint{ x: c.x + r * math.cos(a), y: c.y + r * math.sin(a) }
	}
}

// append_arc_through appends the arc from a0 to a1 that passes through amid,
// which is how a round cap picks its half: the semicircle facing along the
// path rather than back over it.
fn append_arc_through(mut loop []SPoint, c SPoint, r f64, a0 f64, a1 f64, amid f64) {
	two := 2.0 * math.pi
	mut ccw := a1 - a0
	for ccw < 0 {
		ccw += two
	}
	for ccw >= two {
		ccw -= two
	}
	mut mid := amid - a0
	for mid < 0 {
		mid += two
	}
	for mid >= two {
		mid -= two
	}
	if mid <= ccw {
		append_arc(mut loop, c, r, a0, a1, 1.0)
	} else {
		append_arc(mut loop, c, r, a0, a1, -1.0)
	}
}

// flatten_quad appends p2's subdivision: one segment when the control sits
// within tol of the chord, four quarters of recursion otherwise. Depth caps
// at twelve, far past the corpus need, so hostile curves terminate.
fn flatten_quad(p0 SPoint, p1 SPoint, p2 SPoint, tol f64, depth int, mut out []SPoint) {
	dx := p2.x - p0.x
	dy := p2.y - p0.y
	denom := math.sqrt(dx * dx + dy * dy)
	mut dist := 0.0
	if denom < 1e-12 {
		dist = math.sqrt((p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y))
	} else {
		dist = math.abs((p1.x - p0.x) * dy - (p1.y - p0.y) * dx) / denom
	}
	if dist <= tol || depth >= 12 {
		out << p2
		return
	}
	q0 := SPoint{ x: (p0.x + p1.x) / 2.0, y: (p0.y + p1.y) / 2.0 }
	q1 := SPoint{ x: (p1.x + p2.x) / 2.0, y: (p1.y + p2.y) / 2.0 }
	mid := SPoint{ x: (q0.x + q1.x) / 2.0, y: (q0.y + q1.y) / 2.0 }
	flatten_quad(p0, q0, mid, tol, depth + 1, mut out)
	flatten_quad(mid, q1, p2, tol, depth + 1, mut out)
}

// flatten_closed_contour answers one TrueType contour as a line polygon:
// implied on-curve midpoints split every off-curve pair (including runs that
// are all off-curve), lines stay lines, quadratics subdivide at tol.
fn flatten_closed_contour(xs []int, ys []int, on_curve []bool, s int, e int, tol f64) []SPoint {
	n := e - s + 1
	if n <= 0 {
		return []SPoint{}
	}
	if n == 1 {
		return [SPoint{ x: f64(xs[s]), y: f64(ys[s]) }]
	}
	mut nx := []f64{cap: n + 1}
	mut ny := []f64{cap: n + 1}
	mut nn := []bool{cap: n + 1}
	for k in 0 .. n {
		idx := s + k
		nx << f64(xs[idx])
		ny << f64(ys[idx])
		nn << on_curve[idx]
	}
	mut ex := []f64{cap: nx.len * 2}
	mut ey := []f64{cap: nx.len * 2}
	mut en := []bool{cap: nx.len * 2}
	for k in 0 .. n {
		ex << nx[k]
		ey << ny[k]
		en << nn[k]
		k2 := (k + 1) % n
		if !nn[k] && !nn[k2] {
			ex << (nx[k] + nx[k2]) / 2.0
			ey << (ny[k] + ny[k2]) / 2.0
			en << true
		}
	}
	m := ex.len
	mut start := -1
	for k in 0 .. m {
		if en[k] {
			start = k
			break
		}
	}
	if start < 0 {
		return []SPoint{}
	}
	mut out := []SPoint{cap: m * 2}
	out << SPoint{ x: ex[start], y: ey[start] }
	cur_pt := SPoint{ x: ex[start], y: ey[start] }
	mut cur := start
	for _ in 0 .. m + 2 {
		nxt := (cur + 1) % m
		if en[nxt] {
			if nxt == start {
				break
			}
			next_pt := SPoint{ x: ex[nxt], y: ey[nxt] }
			out << next_pt
			cur = nxt
		} else {
			nxt2 := (cur + 2) % m
			ctrl_pt := SPoint{ x: ex[nxt], y: ey[nxt] }
			end_pt := SPoint{ x: ex[nxt2], y: ey[nxt2] }
			flatten_quad(cur_pt, ctrl_pt, end_pt, tol, 0, mut out)
			cur = nxt2
			if cur == start {
				break
			}
		}
		if cur == start {
			break
		}
	}
	return out
}

// clean_poly drops consecutive duplicates and a closing duplicate of the
// first point, which the flatten walk leaves behind.
fn clean_poly(pts []SPoint) []SPoint {
	mut out := []SPoint{cap: pts.len}
	for p in pts {
		if out.len == 0 {
			out << p
			continue
		}
		last := out[out.len - 1]
		if s_len(SPoint{ x: p.x - last.x, y: p.y - last.y }) > 1e-9 {
			out << p
		}
	}
	if out.len > 1 {
		first := out[0]
		last := out[out.len - 1]
		if s_len(SPoint{ x: last.x - first.x, y: last.y - first.y }) <= 1e-9 {
			out.delete(out.len - 1)
		}
	}
	return out
}

// append_outer_join emits the outer side's corner: the miter intersection
// while its length stays within limit radii, the bevel cut otherwise, the
// arc for round joins. turn carries the corner's sign for the arc's sweep.
fn append_outer_join(mut loop []SPoint, p SPoint, n0 SPoint, n1 SPoint, d0 SPoint, d1 SPoint, r f64, join StrokeLineJoin, limit f64, turn f64) {
	if join == StrokeLineJoin.bevel {
		loop << SPoint{ x: p.x + n0.x * r, y: p.y + n0.y * r }
		loop << SPoint{ x: p.x + n1.x * r, y: p.y + n1.y * r }
		return
	}
	if join == StrokeLineJoin.round {
		dir := if turn > 0 { 1.0 } else { -1.0 }
		append_arc(mut loop, p, r, math.atan2(n0.y, n0.x), math.atan2(n1.y, n1.x), dir)
		return
	}
	a := SPoint{ x: p.x + n0.x * r, y: p.y + n0.y * r }
	b := SPoint{ x: p.x + n1.x * r, y: p.y + n1.y * r }
	m, ok := line_intersect(a, d0, b, d1)
	if ok {
		if s_len(SPoint{ x: m.x - p.x, y: m.y - p.y }) / r <= limit {
			loop << m
			return
		}
	}
	loop << a
	loop << b
}

// inner_point answers the inner side's corner: always the offset
// intersection, trimmed rather than styled, with the averaged normal as the
// parallel-lines fallback.
fn inner_point(p SPoint, n0 SPoint, n1 SPoint, d0 SPoint, d1 SPoint, r f64) SPoint {
	a := SPoint{ x: p.x + n0.x * r, y: p.y + n0.y * r }
	b := SPoint{ x: p.x + n1.x * r, y: p.y + n1.y * r }
	m, ok := line_intersect(a, d0, b, d1)
	if ok {
		return m
	}
	return SPoint{ x: p.x + (n0.x + n1.x) * 0.5 * r, y: p.y + (n0.y + n1.y) * 0.5 * r }
}

// stroke_closed_sides answers one closed polygon's two offset loops in
// forward vertex order: left holds the left-side offsets, right the right.
// Each corner styles its outer side and trims its inner one; a left turn
// puts the outer side left, a right turn right.
fn stroke_closed_sides(poly []SPoint, opt StrokeOptions, r f64, limit f64) ([]SPoint, []SPoint) {
	n := poly.len
	mut left := []SPoint{cap: n * 2}
	mut right := []SPoint{cap: n * 2}
	for i in 0 .. n {
		cur := poly[i]
		prev := poly[(i - 1 + n) % n]
		next := poly[(i + 1) % n]
		d0 := s_norm(SPoint{ x: cur.x - prev.x, y: cur.y - prev.y })
		d1 := s_norm(SPoint{ x: next.x - cur.x, y: next.y - cur.y })
		if s_len(d0) < 0.5 || s_len(d1) < 0.5 {
			continue
		}
		n0 := s_left_normal(d0)
		n1 := s_left_normal(d1)
		turn := s_cross(d0, d1)
		along := s_dot(d0, d1)
		if math.abs(turn) < 1e-12 && along > 0 {
			left << SPoint{ x: cur.x + n0.x * r, y: cur.y + n0.y * r }
			right << SPoint{ x: cur.x - n0.x * r, y: cur.y - n0.y * r }
			continue
		}
		if math.abs(turn) < 1e-12 || along < -0.999999 {
			left << SPoint{ x: cur.x + n0.x * r, y: cur.y + n0.y * r }
			left << SPoint{ x: cur.x + n1.x * r, y: cur.y + n1.y * r }
			right << SPoint{ x: cur.x - n0.x * r, y: cur.y - n0.y * r }
			right << SPoint{ x: cur.x - n1.x * r, y: cur.y - n1.y * r }
			continue
		}
		if turn > 0 {
			append_outer_join(mut left, cur, n0, n1, d0, d1, r, opt.line_join, limit, turn)
			rn0 := SPoint{ x: -n0.x, y: -n0.y }
			rn1 := SPoint{ x: -n1.x, y: -n1.y }
			right << inner_point(cur, rn0, rn1, d0, d1, r)
		} else {
			rn0 := SPoint{ x: -n0.x, y: -n0.y }
			rn1 := SPoint{ x: -n1.x, y: -n1.y }
			append_outer_join(mut right, cur, rn0, rn1, d0, d1, r, opt.line_join, limit, turn)
			left << inner_point(cur, n0, n1, d0, d1, r)
		}
	}
	return left, right
}

// dot_loop answers a one-point contour's stroke: a square at half-width for
// the square cap, a twelve-gon circle otherwise.
fn dot_loop(p SPoint, opt StrokeOptions, r f64) []SPoint {
	mut loop := []SPoint{}
	if opt.line_cap == StrokeLineCap.square && opt.line_join != StrokeLineJoin.round {
		loop << SPoint{ x: p.x - r, y: p.y - r }
		loop << SPoint{ x: p.x + r, y: p.y - r }
		loop << SPoint{ x: p.x + r, y: p.y + r }
		loop << SPoint{ x: p.x - r, y: p.y + r }
		return loop
	}
	steps := 12
	for k in 0 .. steps {
		a := 2.0 * math.pi * f64(k) / f64(steps)
		loop << SPoint{ x: p.x + r * math.cos(a), y: p.y + r * math.sin(a) }
	}
	return loop
}

// push_loop appends one loop as a contour.
fn push_loop(mut out StrokedOutline, loop []SPoint) {
	if loop.len == 0 {
		return
	}
	for p in loop {
		out.xs << p.x
		out.ys << p.y
		out.on_curve << true
	}
	out.end_pts << out.xs.len - 1
}

// append_cap emits the cap between an open loop's sides around tip: nothing
// for butt (the straight edge is the cap), two extended corners for square,
// the facing semicircle's interior for round. Points ship in traversal
// order: from the left side to the right at the end, from the right side to
// the left at the start.
fn append_cap(mut out []SPoint, tip SPoint, d SPoint, n SPoint, r f64, cap StrokeLineCap, is_end bool) {
	if cap == StrokeLineCap.butt {
		return
	}
	lp := SPoint{ x: tip.x + n.x * r, y: tip.y + n.y * r }
	rp := SPoint{ x: tip.x - n.x * r, y: tip.y - n.y * r }
	if cap == StrokeLineCap.square {
		e := if is_end { d } else { SPoint{ x: -d.x, y: -d.y } }
		le := SPoint{ x: lp.x + e.x * r, y: lp.y + e.y * r }
		re := SPoint{ x: rp.x + e.x * r, y: rp.y + e.y * r }
		if is_end {
			out << le
			out << re
		} else {
			out << re
			out << le
		}
		return
	}
	mid := if is_end { math.atan2(d.y, d.x) } else { math.atan2(-d.y, -d.x) }
	a0 := if is_end {
		math.atan2(lp.y - tip.y, lp.x - tip.x)
	} else {
		math.atan2(rp.y - tip.y, rp.x - tip.x)
	}
	a1 := if is_end {
		math.atan2(rp.y - tip.y, rp.x - tip.x)
	} else {
		math.atan2(lp.y - tip.y, lp.x - tip.x)
	}
	two := 2.0 * math.pi
	mut ccw := a1 - a0
	for ccw < 0 {
		ccw += two
	}
	for ccw >= two {
		ccw -= two
	}
	mut rel := mid - a0
	for rel < 0 {
		rel += two
	}
	for rel >= two {
		rel -= two
	}
	sweep := if rel <= ccw { ccw } else { ccw - two }
	steps := 12
	mut k := 1
	for k < steps {
		a := a0 + sweep * f64(k) / f64(steps)
		out << SPoint{ x: tip.x + r * math.cos(a), y: tip.y + r * math.sin(a) }
		k++
	}
}

// stroke_open_points answers one open polyline's stroked loop: left offsets
// forward, the end cap, right offsets backward, the start cap.
fn stroke_open_points(pts []SPoint, opt StrokeOptions, r f64, limit f64) []SPoint {
	n := pts.len
	if n == 0 {
		return []SPoint{}
	}
	if n == 1 {
		return dot_loop(pts[0], opt, r)
	}
	mut dirs := []SPoint{cap: n - 1}
	mut norms := []SPoint{cap: n - 1}
	for i in 0 .. n - 1 {
		mut d := s_norm(SPoint{ x: pts[i + 1].x - pts[i].x, y: pts[i + 1].y - pts[i].y })
		if s_len(d) < 0.5 {
			d = if dirs.len > 0 { dirs[dirs.len - 1] } else { SPoint{ x: 1, y: 0 } }
		}
		dirs << d
		norms << s_left_normal(d)
	}
	mut left := []SPoint{cap: n * 2}
	mut right_fwd := []SPoint{cap: n * 2}
	left << SPoint{ x: pts[0].x + norms[0].x * r, y: pts[0].y + norms[0].y * r }
	right_fwd << SPoint{ x: pts[0].x - norms[0].x * r, y: pts[0].y - norms[0].y * r }
	for i in 1 .. n - 1 {
		p := pts[i]
		d0 := dirs[i - 1]
		d1 := dirs[i]
		n0 := norms[i - 1]
		n1 := norms[i]
		turn := s_cross(d0, d1)
		along := s_dot(d0, d1)
		rn0 := SPoint{ x: -n0.x, y: -n0.y }
		rn1 := SPoint{ x: -n1.x, y: -n1.y }
		if math.abs(turn) < 1e-12 && along > 0 {
			left << SPoint{ x: p.x + n0.x * r, y: p.y + n0.y * r }
			right_fwd << SPoint{ x: p.x + rn0.x * r, y: p.y + rn0.y * r }
		} else if math.abs(turn) < 1e-12 || along < -0.999999 {
			left << SPoint{ x: p.x + n0.x * r, y: p.y + n0.y * r }
			left << SPoint{ x: p.x + n1.x * r, y: p.y + n1.y * r }
			right_fwd << SPoint{ x: p.x + rn0.x * r, y: p.y + rn0.y * r }
			right_fwd << SPoint{ x: p.x + rn1.x * r, y: p.y + rn1.y * r }
		} else if turn > 0 {
			append_outer_join(mut left, p, n0, n1, d0, d1, r, opt.line_join, limit, turn)
			right_fwd << inner_point(p, rn0, rn1, d0, d1, r)
		} else {
			left << inner_point(p, n0, n1, d0, d1, r)
			append_outer_join(mut right_fwd, p, rn0, rn1, d0, d1, r, opt.line_join, limit,
				turn)
		}
	}
	left << SPoint{ x: pts[n - 1].x + norms[norms.len - 1].x * r, y: pts[n - 1].y + norms[norms.len - 1].y * r }
	right_fwd << SPoint{ x: pts[n - 1].x - norms[norms.len - 1].x * r, y: pts[n - 1].y - norms[norms.len - 1].y * r }
	mut out := []SPoint{cap: left.len + right_fwd.len + 26}
	for p in left {
		out << p
	}
	append_cap(mut out, pts[n - 1], dirs[dirs.len - 1], norms[norms.len - 1], r, opt.line_cap,
		true)
	// Reversed, so the backward side runs tip to base the way the forward
	// side ran base to tip; reversing the whole side keeps multi-point
	// joins in the order the traversal meets them.
	for k in 0 .. right_fwd.len {
		out << right_fwd[right_fwd.len - 1 - k]
	}
	append_cap(mut out, pts[0], dirs[0], norms[0], r, opt.line_cap, false)
	return out
}

// stroke_outline strokes closed glyph contours: xs, ys, on_curve and end_pts
// are the slices Face.glyph_outline answers, opt selects the stroke. Every
// input contour answers its two offset loops; empty and degenerate inputs
// answer no loops rather than an error.
pub fn stroke_outline(xs []int, ys []int, on_curve []bool, end_pts []int, opt StrokeOptions) StrokedOutline {
	mut out := StrokedOutline{}
	r := opt.radius
	if r <= 0 {
		return out
	}
	if xs.len != ys.len || xs.len != on_curve.len {
		return out
	}
	limit := stroke_limit(opt)
	tol := stroke_tolerance(opt)
	for c in 0 .. end_pts.len {
		mut s := 0
		if c > 0 {
			s = end_pts[c - 1] + 1
		}
		e := end_pts[c]
		if s < 0 || e >= xs.len || s > e {
			continue
		}
		poly := clean_poly(flatten_closed_contour(xs, ys, on_curve, s, e, tol))
		if poly.len == 0 {
			continue
		}
		if poly.len == 1 {
			push_loop(mut out, dot_loop(poly[0], opt, r))
			continue
		}
		if poly.len == 2 {
			push_loop(mut out, stroke_open_points(poly, opt, r, limit))
			continue
		}
		left, right := stroke_closed_sides(poly, opt, r, limit)
		push_loop(mut out, left)
		// Reversed, so the pair answers opposite orientations: a nonzero
		// fill paints the ring between them rather than two stacked disks.
		mut rev := []SPoint{cap: right.len}
		for k in 0 .. right.len {
			rev << right[right.len - 1 - k]
		}
		push_loop(mut out, rev)
	}
	return out
}

// stroke_open_polyline strokes one open polyline to a single loop closed by
// opt's caps. xs and ys are the spine in order; joins style its interior
// corners the way stroke_outline styles closed ones.
pub fn stroke_open_polyline(xs []f64, ys []f64, opt StrokeOptions) StrokedOutline {
	mut out := StrokedOutline{}
	r := opt.radius
	if r <= 0 || xs.len != ys.len || xs.len == 0 {
		return out
	}
	mut pts := []SPoint{cap: xs.len}
	for i in 0 .. xs.len {
		pts << SPoint{ x: xs[i], y: ys[i] }
	}
	pts = clean_poly(pts)
	if pts.len == 0 {
		return out
	}
	push_loop(mut out, stroke_open_points(pts, opt, r, stroke_limit(opt)))
	return out
}
