// TrueType outline reader: the `glyf` points every stroker and debugger needs.
//
// The shaper never looks at outlines — advances and anchors are enough to
// place glyphs — but stroking (Phase 8.6) draws the outline itself, widened
// by half the stroke width. This file answers what the outline is: every
// contour's points in design units, which sit on the curve, where each
// contour ends, and the header bounding box. Composite glyphs resolve to
// their flattened points, transforms applied, so a caller never sees the
// component structure.
//
// The parsing mirrors fontTools' `getCoordinates` op for op, including the
// two orders that matter: arguments come before the transform in the byte
// stream, and the two-by-two applies as px = x*xx + y*yx,
// py = x*xy + y*yy. What differs is rounding: fontTools keeps floats and
// rounds only when asked, while this reader applies `otRound` once at the
// end, because every corpus point is an integer after a correct transform
// and the pins compare integers. A caller that needs the raw floats is out
// of luck; stroking consumes integers.
//
// What this reader deliberately does not do, each with its reason:
//   - instructions are skipped, not executed: grid-fitting moves points for
//     the rasterizer, and an outline reader that fitted would disagree with
//     the design units every other table speaks.
//   - ROUND_XY_TO_GRID is informational for the same reason: the offsets are
//     already integers, and rounding them again changes nothing.
//   - USE_MY_METRICS changes advances, not points, so it is the metrics
//     reader's business and ignored here.
//   - anchor-matched components (arguments as point numbers rather than
//     offsets) align the two named points, transform first, exactly like
//     fontTools. No corpus composite uses them — a raw-byte survey of every
//     corpus face found zero — but the path is implemented rather than
//     refused, because refusing a legal font is worse than carrying the
//     branch.
//   - nesting resolves recursively with a depth cap of sixteen: a corrupt
//     font that cycles its components is refused instead of recursed on
//     forever. Sixteen is far past the corpus maximum (two), which is what
//     makes it a corruption signal rather than a limit.
module font

// glyf_max_component_depth caps composite nesting: sixteen levels of real
// components never happen (the corpus peaks at two), so deeper means a
// corrupt cycle, which is refused rather than recursed on.
const glyf_max_component_depth = 16

// GlyfOutline is one glyph's outline in design units: every contour's
// points back to back, end_pts marking each contour's last point index,
// on_curve saying which points sit on the curve. An empty glyph (a space,
// or a zero-length loca range) has no points and no contours; its box is
// whatever the header claims, or zeros when there are no bytes at all.
pub struct GlyfOutline {
pub mut:
	xs       []int
	ys       []int
	on_curve []bool
	end_pts  []int
	x_min    int
	y_min    int
	x_max    int
	y_max    int
}

// n_points answers how many points the outline holds.
pub fn (o &GlyfOutline) n_points() int {
	return o.xs.len
}

// n_contours answers how many contours the outline holds.
pub fn (o &GlyfOutline) n_contours() int {
	return o.end_pts.len
}

// glyph_outline reads one glyph's outline: its points, curve flags, contour
// ends and header box, composites flattened and transforms applied. A font
// with no `glyf` table (a CFF font) is an error rather than an empty
// answer: nothing about the glyph is missing, the outlines live in a table
// this reader does not speak.
pub fn (f &Face) glyph_outline(gid u16) !GlyfOutline {
	if !f.sfnt.has(tag_glyf) || !f.sfnt.has(tag_loca) {
		return error('glyf: the font has no TrueType outlines (CFF fonts are read by the CFF reader)')
	}
	glyf := f.sfnt.table_data(tag_glyf)
	loca := f.sfnt.table_data(tag_loca)
	start, stop := glyf_loca_range(loca, f.loca_is_long(), int(gid), f.num_glyphs)!
	if start == stop {
		return GlyfOutline{}
	}
	return glyf_resolve(glyf, loca, f.loca_is_long(), f.num_glyphs, int(gid), 0)
}

// glyf_loca_range answers where one glyph's bytes sit inside `glyf`: the
// start and stop offsets. An empty range is a real answer (the glyph has no
// outline), while a gid past the loca entries or a range running backwards
// or past the table is corruption.
fn glyf_loca_range(loca []u8, long bool, gid int, num_glyphs int) !(int, int) {
	stride := if long { 4 } else { 2 }
	if gid < 0 || gid >= num_glyphs {
		return error('glyf: gid ${gid} is past the ${num_glyphs} glyphs')
	}
	need := (gid + 2) * stride
	if loca.len < need {
		return error('glyf: loca holds ${loca.len} bytes, no entries for gid ${gid}')
	}
	r := new_reader(loca)
	start := if long { int(r.u32_at(gid * 4)) } else { int(r.u16_at(gid * 2)) * 2 }
	stop := if long {
		int(r.u32_at((gid + 1) * 4))
	} else {
		int(r.u16_at((gid + 1) * 2)) * 2
	}
	if start > stop {
		return error('glyf: gid ${gid} range runs backwards (${start}..${stop})')
	}
	return start, stop
}

// glyf_resolve reads one glyph and answers its flattened outline: simple
// glyphs come back as stored, composites as every component resolved,
// transformed and appended. Depth counts the nesting so a cyclic font is
// refused instead of recursed on.
fn glyf_resolve(glyf []u8, loca []u8, long bool, num_glyphs int, gid int, depth int) !GlyfOutline {
	if depth > glyf_max_component_depth {
		return error('glyf: gid ${gid} nests past ${glyf_max_component_depth} components, likely a corrupt cycle')
	}
	start, stop := glyf_loca_range(loca, long, gid, num_glyphs)!
	if start == stop {
		return GlyfOutline{}
	}
	if start < 0 || stop > glyf.len {
		return error('glyf: gid ${gid} range [${start}..${stop}] is outside the ${glyf.len}-byte table')
	}
	r := new_reader(glyf)
	ncont := int(r.i16_at(start))
	if ncont == 0 {
		return GlyfOutline{
			x_min: int(r.i16_at(start + 2))
			y_min: int(r.i16_at(start + 4))
			x_max: int(r.i16_at(start + 6))
			y_max: int(r.i16_at(start + 8))
		}
	}
	if ncont > 0 {
		return glyf_read_simple(glyf, start, stop)
	}
	return glyf_read_composite(glyf, loca, long, num_glyphs, start, stop, depth)
}

// glyf_f2dot14 reads a 2.14 fixed-point transform entry: a signed sixteen
// bit value over 16384, so a unit scale comes out as exactly 1.0 rather
// than as something rounded.
fn glyf_f2dot14(v i16) f64 {
	return f64(v) / 16384.0
}

// glyf_read_simple reads one simple glyph: contour ends, the skipped
// instructions, the repeat-packed flags, then the x and y delta streams.
// The deltas accumulate from zero — each point is stored as its distance
// from the last — and the on-curve bit rides along in the flags. Bounds are
// checked at every step: a truncated glyph is refused, never half-read.
fn glyf_read_simple(glyf []u8, start int, stop int) !GlyfOutline {
	r := new_reader(glyf)
	ncont := int(r.i16_at(start))
	if ncont <= 0 {
		return error('glyf: simple glyph at ${start} claims ${ncont} contours')
	}
	if !r.has(start + 10, ncont * 2 + 2) {
		return error('glyf: glyph header overruns its ${stop - start} bytes')
	}
	mut ends := []int{len: ncont}
	for i in 0 .. ncont {
		ends[i] = int(r.u16_at(start + 10 + i * 2))
	}
	npoints := ends[ncont - 1] + 1
	if npoints <= 0 {
		return error('glyf: glyph at ${start} has no points')
	}
	for i in 1 .. ncont {
		if ends[i] < ends[i - 1] {
			return error('glyf: glyph at ${start} contour ends run backwards')
		}
	}
	ilen_at := start + 10 + ncont * 2
	ilen := int(r.u16_at(ilen_at))
	mut pos := ilen_at + 2 + ilen
	if pos < 0 || pos > stop {
		return error('glyf: glyph instructions overrun the outline')
	}
	mut flags := []u8{cap: npoints}
	for flags.len < npoints {
		if !r.has(pos, 1) {
			return error('glyf: glyph flags overrun the outline')
		}
		f := r.u8_at(pos)
		pos++
		flags << f
		if f & 0x08 != 0 {
			if !r.has(pos, 1) {
				return error('glyf: glyph flag repeat overruns the outline')
			}
			rep := int(r.u8_at(pos))
			pos++
			for _ in 0 .. rep {
				flags << f
			}
		}
	}
	if flags.len != npoints {
		return error('glyf: glyph at ${start} flags name ${flags.len} points for ${npoints} ends')
	}
	mut xs := []f64{len: npoints}
	mut x := 0.0
	for i in 0 .. npoints {
		f := flags[i]
		if f & 0x02 != 0 {
			if !r.has(pos, 1) {
				return error('glyf: glyph x deltas overrun the outline')
			}
			d := f64(r.u8_at(pos))
			pos++
			if f & 0x10 != 0 {
				x += d
			} else {
				x -= d
			}
		} else if f & 0x10 == 0 {
			if !r.has(pos, 2) {
				return error('glyf: glyph x deltas overrun the outline')
			}
			x += f64(r.i16_at(pos))
			pos += 2
		}
		xs[i] = x
	}
	mut ys := []f64{len: npoints}
	mut y := 0.0
	for i in 0 .. npoints {
		f := flags[i]
		if f & 0x04 != 0 {
			if !r.has(pos, 1) {
				return error('glyf: glyph y deltas overrun the outline')
			}
			d := f64(r.u8_at(pos))
			pos++
			if f & 0x20 != 0 {
				y += d
			} else {
				y -= d
			}
		} else if f & 0x20 == 0 {
			if !r.has(pos, 2) {
				return error('glyf: glyph y deltas overrun the outline')
			}
			y += f64(r.i16_at(pos))
			pos += 2
		}
		ys[i] = y
	}
	mut out := GlyfOutline{
		x_min:   int(r.i16_at(start + 2))
		y_min:   int(r.i16_at(start + 4))
		x_max:   int(r.i16_at(start + 6))
		y_max:   int(r.i16_at(start + 8))
		end_pts: ends
	}
	for i in 0 .. npoints {
		out.xs << var_ot_round(xs[i])
		out.ys << var_ot_round(ys[i])
		out.on_curve << flags[i] & 0x01 != 0
	}
	return out
}

// glyf_component is one parsed composite component: the referenced glyph,
// how its points move, and whether the arguments were offsets or the anchor
// point numbers the offset is derived from.
struct GlyfComponent {
pub mut:
	gid       int
	has_xform bool
	// a, b, c, d is the two-by-two in fontTools layout: a row of a, b over
	// a row of c, d, applied as px = x*a + y*c, py = x*b + y*d.
	a f64 = 1.0
	b f64
	c f64
	d f64 = 1.0
	// anchor says the arguments named points (parent first, component
	// second) rather than an offset; scaled says the offset itself rides
	// through the transform (the Apple way) rather than applying after it.
	anchor bool
	scaled bool
	dx     f64
	dy     f64
	first  int
	second int
}

// glyf_read_composite flattens one composite glyph: every component
// resolved recursively, transformed, shifted and appended, contour ends
// re-based onto the growing point list. The header box is the composite's
// own — the font states it, so it is reported, not recomputed.
fn glyf_read_composite(glyf []u8, loca []u8, long bool, num_glyphs int, start int, stop int, depth int) !GlyfOutline {
	r := new_reader(glyf)
	mut out := GlyfOutline{
		x_min: int(r.i16_at(start + 2))
		y_min: int(r.i16_at(start + 4))
		x_max: int(r.i16_at(start + 6))
		y_max: int(r.i16_at(start + 8))
	}
	mut p := start + 10
	for {
		if !r.has(p, 4) {
			return error('glyf: composite at ${start} component header overruns the outline')
		}
		flags := r.u16_at(p)
		comp := int(r.u16_at(p + 2))
		p += 4
		mut c := GlyfComponent{
			gid: comp
		}
		words := flags & 0x0001 != 0
		is_xy := flags & 0x0002 != 0
		if words && is_xy {
			if !r.has(p, 4) {
				return error('glyf: composite at ${start} arguments overrun the outline')
			}
			c.dx = f64(r.i16_at(p))
			c.dy = f64(r.i16_at(p + 2))
			p += 4
		} else if words {
			if !r.has(p, 4) {
				return error('glyf: composite at ${start} arguments overrun the outline')
			}
			c.anchor = true
			c.first = int(r.u16_at(p))
			c.second = int(r.u16_at(p + 2))
			p += 4
		} else if is_xy {
			if !r.has(p, 2) {
				return error('glyf: composite at ${start} arguments overrun the outline')
			}
			rawx := int(r.u8_at(p))
			rawy := int(r.u8_at(p + 1))
			c.dx = f64(if rawx >= 128 { rawx - 256 } else { rawx })
			c.dy = f64(if rawy >= 128 { rawy - 256 } else { rawy })
			p += 2
		} else {
			if !r.has(p, 2) {
				return error('glyf: composite at ${start} arguments overrun the outline')
			}
			c.anchor = true
			c.first = int(r.u8_at(p))
			c.second = int(r.u8_at(p + 1))
			p += 2
		}
		// The arguments come before the transform in the stream, and
		// reading the transform first shifts every component after it.
		// Exactly one transform form is present when any is.
		if flags & 0x0008 != 0 {
			if !r.has(p, 2) {
				return error('glyf: composite at ${start} scale overruns the outline')
			}
			s := glyf_f2dot14(r.i16_at(p))
			p += 2
			c.has_xform = true
			c.a = s
			c.d = s
		} else if flags & 0x0040 != 0 {
			if !r.has(p, 4) {
				return error('glyf: composite at ${start} scale overruns the outline')
			}
			c.has_xform = true
			c.a = glyf_f2dot14(r.i16_at(p))
			c.d = glyf_f2dot14(r.i16_at(p + 2))
			p += 4
		} else if flags & 0x0080 != 0 {
			if !r.has(p, 8) {
				return error('glyf: composite at ${start} transform overruns the outline')
			}
			c.has_xform = true
			c.a = glyf_f2dot14(r.i16_at(p))
			c.b = glyf_f2dot14(r.i16_at(p + 2))
			c.c = glyf_f2dot14(r.i16_at(p + 4))
			c.d = glyf_f2dot14(r.i16_at(p + 6))
			p += 8
		}
		c.scaled = flags & 0x0800 != 0
		glyf_apply_component(mut out, glyf, loca, long, num_glyphs, c, depth)!
		if flags & 0x0020 == 0 {
			break
		}
	}
	// Instructions, when the last component names them, ride at the very
	// end: a count plus that many bytes, skipped rather than executed.
	if r.has(p, 2) {
		n := int(r.u16_at(p))
		p += 2
		if p + n <= stop {
			p += n
		}
	}
	return out
}

// glyf_apply_component resolves one component and appends its points: the
// transform first, then the shift — an offset after an unscaled transform
// (the MS way every corpus font uses), the offset through the transform
// when the font asks for the Apple way, or the anchor alignment when the
// arguments named points. Anchor indices that name no point are corruption.
fn glyf_apply_component(mut out GlyfOutline, glyf []u8, loca []u8, long bool, num_glyphs int, c GlyfComponent, depth int) ! {
	sub := glyf_resolve(glyf, loca, long, num_glyphs, c.gid, depth + 1)!
	if sub.xs.len == 0 {
		return
	}
	// Floats throughout, one rounding at the end: the transform and the
	// shift compose without an intermediate quantization, the way
	// fontTools keeps doubles until it is asked to round.
	mut fx := []f64{len: sub.xs.len}
	mut fy := []f64{len: sub.xs.len}
	for i in 0 .. sub.xs.len {
		fx[i] = f64(sub.xs[i])
		fy[i] = f64(sub.ys[i])
	}
	base := out.xs.len
	mut dx := c.dx
	mut dy := c.dy
	if c.anchor {
		if c.first < 0 || c.first >= out.xs.len || c.second < 0 || c.second >= fx.len {
			return error('glyf: anchor points ${c.first}/${c.second} name no points')
		}
		if c.has_xform {
			px := fx[c.second]
			py := fy[c.second]
			fx[c.second] = px * c.a + py * c.c
			fy[c.second] = px * c.b + py * c.d
		}
		dx = f64(out.xs[c.first]) - fx[c.second]
		dy = f64(out.ys[c.first]) - fy[c.second]
	}
	if c.has_xform && (c.anchor || !c.scaled) {
		// Transform the points, shift after: the MS way, and the anchor
		// way, whose alignment is measured after the transform.
		for i in 0 .. fx.len {
			px := fx[i]
			py := fy[i]
			fx[i] = px * c.a + py * c.c + dx
			fy[i] = px * c.b + py * c.d + dy
		}
	} else if c.has_xform {
		// The Apple way: shift first, so the offset rides through the
		// transform with the points.
		for i in 0 .. fx.len {
			px := fx[i] + dx
			py := fy[i] + dy
			fx[i] = px * c.a + py * c.c
			fy[i] = px * c.b + py * c.d
		}
	} else {
		for i in 0 .. fx.len {
			fx[i] = fx[i] + dx
			fy[i] = fy[i] + dy
		}
	}
	for i in 0 .. fx.len {
		out.xs << var_ot_round(fx[i])
		out.ys << var_ot_round(fy[i])
	}
	out.on_curve << sub.on_curve
	for e in sub.end_pts {
		out.end_pts << base + e
	}
}
