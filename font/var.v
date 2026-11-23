// Variable instancing: applying `fvar`/`gvar` at caller-chosen coordinates.
//
// Reading the store was always in (`Face.read_variable_axes`,
// `Font.variable_instances`); this file is the other half, applying it.
// The entry point is `var_instance_glyph`, which takes table bytes plus design
// coordinates and answers instanced outline points, and `Face.set_var_coords`
// plus `Face.instanced_glyph_points` keep the chosen coordinates on the face,
// the way `FT_Set_Var_Design_Coordinates` keeps them on an FT_Face.
//
// The pipeline mirrors what FreeType does when a caller sets design
// coordinates and loads a glyph, in the same order:
//
//  1. clamp the design coordinates to the `fvar` range and normalize them to
//     -1..1 around the default (`var_blend_coords`);
//  2. warp the normalized coordinates through `avar` when the font carries
//     one, piecewise-linearly between its mappings (both corpus variable
//     faces do, and the warp is load-bearing: FiraCode maps 0.5 to 0.5208);
//  3. read each `gvar` tuple peak and, when present, its intermediate
//     start/end range, and scale its deltas by the tent product
//     (`supportScalar` in fontTools terms);
//  4. infer the untouched points of each contour by IUP interpolation over
//     the touched ones in 16.16 fixed point, op for op with tt_delta_interpolate
//     (simple glyphs; composites name components, so their deltas apply
//     directly to offsets and phantoms with no IUP);
//  5. sum the scaled deltas across tuples in 16.16 and round the total half up, which
//     is `otRound` and what the rasterizer integer points need.
//  6. composites flatten by instancing each component recursively and
//     re-hanging on the adjusted offsets; the raster wiring below draws the
//     instanced points through the same stb fill the default instance uses,
//     via flattened line polygons, so instanced composites rasterize and
//     CBDT/sbix/COLR strikes keep their own paths.
//
// Only simple `glyf` outlines instance here. A composite names other glyphs
// rather than points: each component instances recursively at the same
// blend, the composite's own `gvar` entry adjusts the component offsets
// (first N points) and the four phantom points, and the flattened points
// re-hang on the adjusted offsets. Advances come out of the four phantom
// points the way `_setCoordinates` derives them (right minus left,
// rounded); when the font carries `HVAR` that table is authoritative
// instead (see `Face.instanced_glyph_points`, which prefers it). On both
// corpus faces the phantom derivation agrees with the rasterizer exactly,
// which the tests pin.
module font

import math
import harfara.raster

// InstancedOutline is one glyph outline at one point in the design space.
pub struct InstancedOutline {
pub mut:
	// xs and ys are the instanced point coordinates in design units, in `glyf`
	// order, contours running back to back the way the outline stores them.
	xs []int
	ys []int
	// end_pts are the contour end indices, the same numbers the `glyf` reader
	// reports for the uninterpolated outline: instancing moves points, it
	// never adds or removes them.
	end_pts []int
	// advance_dx is how much wider the glyph got, in design units, derived
	// from the two horizontal phantom points (right minus left, rounded).
	// The instanced advance is the base `hmtx` advance plus this. When the
	// font carries `HVAR` that table overrides it; see the module comment.
	advance_dx int
}

// AvarSegment is one `avar` mapping: normalized `from` becomes `to`.
pub struct AvarSegment {
pub:
	from f64
	to   f64
}

// var_ot_round rounds half up, towards positive infinity.
//
// This is `otRound` from fontTools and the rounding the OpenType specification
// requires when converting variation scalars to fixed point: fractional
// values of 0.5 and higher take the next higher integer, everything else
// truncates. In particular -43.5 rounds to -43, not -44, which is what makes
// the mid-weight pins land where FreeType puts them.
pub fn var_ot_round(x f64) int {
	return int(math.floor(x + 0.5))
}

// var_f2dot14 reads an F2DOT14 fixed-point number: a signed 16-bit value over
// 16384. Tuple peaks and `avar` mappings are stored this way, so a peak of
// exactly 1.0 comes out as exactly 1.0 rather than as something rounded.
fn var_f2dot14(v i16) f64 {
	return f64(v) / 16384.0
}

// var_normalize_coords clamps design coordinates to the `fvar` range and
// normalizes them to -1..1 around the default.
//
// A coordinate below the minimum or above the maximum is clamped, the way
// `normalizeValue` clamps without extrapolation: asking past the end of an
// axis holds the end rather than inventing deltas beyond it. A coordinate at
// the default normalizes to exactly 0.0, which is what makes the default
// instance come out uninterpolated.
pub fn var_normalize_coords(axes []VariableAxis, coords []f64) ![]f64 {
	if coords.len != axes.len {
		return error('var: ${coords.len} coordinates for ${axes.len} fvar axes')
	}
	mut out := []f64{len: axes.len}
	for i, axis in axes {
		v := coords[i]
		c := if v < axis.minimum {
			axis.minimum
		} else if v > axis.maximum {
			axis.maximum
		} else {
			v
		}
		if c == axis.deflt || axis.minimum == axis.maximum {
			out[i] = 0.0
		} else if c < axis.deflt {
			out[i] = (c - axis.deflt) / (axis.deflt - axis.minimum)
		} else {
			out[i] = (c - axis.deflt) / (axis.maximum - axis.deflt)
		}
	}
	return out
}

// var_read_avar reads the `avar` segment mappings, one list per axis in `fvar`
// order. An empty table answers empty, which `var_apply_avar` reads as the
// identity warp. A table whose axis count disagrees with `fvar` is refused
// rather than zipped: pairing one axis warp with another axis coordinates
// reads the wrong warp for every coordinate.
pub fn var_read_avar(avar []u8, axis_count int) ![][]AvarSegment {
	if avar.len == 0 {
		return [][]AvarSegment{}
	}
	r := new_reader(avar)
	if !r.has(0, 8) {
		return error('var: avar table too short (${avar.len} bytes)')
	}
	if r.u32_at(0) != 0x00010000 {
		return error('var: unsupported avar version ${r.u32_at(0)}')
	}
	n := int(r.u16_at(6))
	if n != axis_count {
		return error('var: avar covers ${n} axes, fvar has ${axis_count}')
	}
	mut pos := 8
	mut out := [][]AvarSegment{len: n}
	for a in 0 .. n {
		if !r.has(pos, 2) {
			return error('var: avar axis ${a} truncated')
		}
		m := int(r.u16_at(pos))
		pos += 2
		if !r.has(pos, m * 4) {
			return error('var: avar axis ${a} mappings overrun the table')
		}
		mut segs := []AvarSegment{len: m}
		for k in 0 .. m {
			segs[k] = AvarSegment{
				from: var_f2dot14(r.i16_at(pos))
				to:   var_f2dot14(r.i16_at(pos + 2))
			}
			pos += 4
		}
		out[a] = segs
	}
	return out
}

// var_apply_avar warps normalized coordinates through `avar` segments.
//
// Each axis is handled on its own: an exact mapping hit answers directly,
// otherwise the two mappings bracketing the value interpolate linearly
// between their outputs (`piecewiseLinearMap` in fontTools). Values outside
// the mapped range hold the nearest end; after normalization the input is
// already clamped to -1..1, and every `avar` spans that range, so the hold
// is unreachable on real fonts and exists only so a short table cannot send
// a coordinate somewhere unmapped. An empty segment list is the identity:
// a font with no `avar` warps nothing.
pub fn var_apply_avar(segments [][]AvarSegment, normalized []f64) []f64 {
	mut out := normalized.clone()
	for a in 0 .. out.len {
		if a >= segments.len {
			break
		}
		segs := segments[a]
		if segs.len == 0 {
			continue
		}
		v := out[a]
		if v <= segs[0].from {
			out[a] = segs[0].to
			continue
		}
		if v >= segs[segs.len - 1].from {
			out[a] = segs[segs.len - 1].to
			continue
		}
		for k in 0 .. segs.len {
			if segs[k].from == v {
				out[a] = segs[k].to
				break
			}
			if segs[k].from > v {
				p := segs[k - 1]
				q := segs[k]
				out[a] = p.to + (q.to - p.to) * (v - p.from) / (q.from - p.from)
				break
			}
		}
	}
	return out
}

// var_blend_coords runs the whole design-to-blend mapping: normalize, then
// warp. The result is what each `gvar` tuple tent is evaluated at, the
// blend coordinates to FreeType design ones.
pub fn var_blend_coords(axes []VariableAxis, avar []u8, coords []f64) ![]f64 {
	normalized := var_normalize_coords(axes, coords) or { return err }
	if avar.len == 0 {
		return normalized
	}
	segments := var_read_avar(avar, axes.len) or { return err }
	return var_apply_avar(segments, normalized)
}

// var_loca_range answers the `glyf` byte range of one glyph from `loca`.
// Short `loca` stores half offsets; long stores full ones. A glyph id the
// table does not cover, or a range reaching past the outlines, is an error
// rather than a slice the caller cannot trust.
pub fn var_loca_range(loca []u8, glyf_len int, gid int, long_loca bool) !(int, int) {
	stride := if long_loca { 4 } else { 2 }
	if gid < 0 || !new_reader(loca).has(gid * stride, 2 * stride) {
		return error('var: gid ${gid} outside loca table (${loca.len} bytes)')
	}
	r := new_reader(loca)
	mut start := 0
	mut stop := 0
	if long_loca {
		start = int(r.u32_at(gid * 4))
		stop = int(r.u32_at(gid * 4 + 4))
	} else {
		start = int(r.u16_at(gid * 2)) * 2
		stop = int(r.u16_at(gid * 2 + 2)) * 2
	}
	if start > stop || stop > glyf_len {
		return error('var: gid ${gid} glyf range [${start}..${stop}] outside ${glyf_len} bytes')
	}
	return start, stop
}

// var_read_glyph_points reads one simple glyph outline points and contour ends.
//
// The flags unpack the way TrueType packs them: short-vector bits give one
// byte per coordinate (adding when the same-bit is set, subtracting when it
// is not), otherwise the coordinate repeats the last one or arrives as a
// full int16, and the repeat bit fans one flag byte out over several points.
// Only the coordinates come back; the on-curve bits do not matter here
// because instancing moves every point the same way regardless of kind.
//
// A composite is refused: it names other glyphs rather than points, and
// instancing it means instancing each component and re-hanging the offsets,
// which is a follow-up. An empty glyph (zero-length range, or zero contours)
// answers empty, which instances to empty.
pub fn var_read_glyph_points(glyf []u8, start int, stop int) !([]int, []int, []int) {
	if start == stop {
		return []int{}, []int{}, []int{}
	}
	r := new_reader(glyf)
	if start < 0 || start + 10 > stop || stop > glyf.len {
		return error('var: glyph bytes [${start}..${stop}] outside glyf table (${glyf.len} bytes)')
	}
	ncont := int(r.i16_at(start))
	if ncont < 0 {
		return error('var: composite glyphs are not instanced in this slice (offset ${start})')
	}
	if ncont == 0 {
		return []int{}, []int{}, []int{}
	}
	if !r.has(start + 10, ncont * 2 + 2) {
		return error('var: glyph header overruns its ${stop - start} bytes')
	}
	mut ends := []int{len: ncont}
	for i in 0 .. ncont {
		ends[i] = int(r.u16_at(start + 10 + i * 2))
	}
	npoints := ends[ncont - 1] + 1
	if npoints <= 0 {
		return error('var: glyph has no points')
	}
	ilen_at := start + 10 + ncont * 2
	ilen := int(r.u16_at(ilen_at))
	mut pos := ilen_at + 2 + ilen
	mut flags := []u8{cap: npoints}
	for flags.len < npoints {
		if !r.has(pos, 1) {
			return error('var: glyph flags overrun the outline')
		}
		f := r.u8_at(pos)
		pos++
		flags << f
		if f & 0x08 != 0 {
			if !r.has(pos, 1) {
				return error('var: glyph flag repeat overruns the outline')
			}
			rep := int(r.u8_at(pos))
			pos++
			for _ in 0 .. rep {
				flags << f
			}
		}
	}
	mut xs := []int{len: npoints}
	mut ys := []int{len: npoints}
	mut x := 0
	for i in 0 .. npoints {
		f := flags[i]
		if f & 0x02 != 0 {
			if !r.has(pos, 1) {
				return error('var: glyph x deltas overrun the outline')
			}
			d := int(r.u8_at(pos))
			pos++
			if f & 0x10 != 0 {
				x += d
			} else {
				x -= d
			}
		} else if f & 0x10 == 0 {
			if !r.has(pos, 2) {
				return error('var: glyph x deltas overrun the outline')
			}
			x += int(r.i16_at(pos))
			pos += 2
		}
		xs[i] = x
	}
	mut y := 0
	for i in 0 .. npoints {
		f := flags[i]
		if f & 0x04 != 0 {
			if !r.has(pos, 1) {
				return error('var: glyph y deltas overrun the outline')
			}
			d := int(r.u8_at(pos))
			pos++
			if f & 0x20 != 0 {
				y += d
			} else {
				y -= d
			}
		} else if f & 0x20 == 0 {
			if !r.has(pos, 2) {
				return error('var: glyph y deltas overrun the outline')
			}
			y += int(r.i16_at(pos))
			pos += 2
		}
		ys[i] = y
	}
	return xs, ys, ends
}

// var_unpack_points decodes a packed point-number run: a count (one byte, or
// two when the high bit is set), then runs of delta-encoded point numbers,
// each run one byte longer than its header says, one byte per delta or two
// when the run header says words. The numbers accumulate from zero.
//
// A count of zero is the shared encoding for "every point": it answers
// empty with `all` set, and the caller fills in the full range. Callers
// treat the answer as indices into the glyph points plus its four phantom
// points; numbers outside that range are skipped where they are applied,
// the way the decompiler leaves out-of-range deltas out.
fn var_unpack_points(data []u8, at int, num_points int) !([]int, int, bool) {
	r := new_reader(data)
	if !r.has(at, 1) {
		return error('var: point count at ${at} outside table (${data.len} bytes)')
	}
	mut count := int(r.u8_at(at))
	mut pos := at + 1
	if count & 0x80 != 0 {
		if !r.has(pos, 1) {
			return error('var: two-byte point count overruns the table')
		}
		count = ((count & 0x7f) << 8) | int(r.u8_at(pos))
		pos++
	}
	if count == 0 {
		return []int{}, pos, true
	}
	mut out := []int{cap: count}
	mut cur := 0
	for out.len < count {
		if !r.has(pos, 1) {
			return error('var: point run header overruns the table')
		}
		h := int(r.u8_at(pos))
		pos++
		n := (h & 0x7f) + 1
		words := h & 0x80 != 0
		for _ in 0 .. n {
			if words {
				if !r.has(pos, 2) {
					return error('var: word point number overruns the table')
				}
				cur += int(r.u16_at(pos))
				pos += 2
			} else {
				if !r.has(pos, 1) {
					return error('var: byte point number overruns the table')
				}
				cur += int(r.u8_at(pos))
				pos++
			}
			out << cur
		}
	}
	return out, pos, false
}

// var_skip_points advances past one packed point-number stream without
// decoding it. Point runs use 7-bit counts and a 0x80 word flag (not the
// delta stream's 6-bit count and 0x40/0xc0 width flags), so this is a
// separate walk; it mirrors var_unpack_points run for run.
fn var_skip_points(data []u8, at int, count int) !int {
	if count == 0 {
		return at
	}
	r := new_reader(data)
	mut pos := at
	mut left := count
	for left > 0 {
		if !r.has(pos, 1) {
			return error('var: point run header overruns the table')
		}
		h := int(r.u8_at(pos))
		pos++
		n := (h & 0x7f) + 1
		step := if h & 0x80 != 0 { 2 } else { 1 }
		if !r.has(pos, step * n) {
			return error('var: point number run overruns the table')
		}
		pos += step * n
		left -= n
	}
	return pos
}

// var_unpack_deltas decodes one packed delta run: runs of zero fill (0x80),
// signed bytes, signed words (0x40) or signed longs (0xC0), each run one
// longer than its low six bits say. Exactly `count` values come back, which
// is how the x run, the y run and the point list stay lined up.
fn var_unpack_deltas(data []u8, at int, count int) !([]int, int) {
	r := new_reader(data)
	mut out := []int{cap: count}
	mut pos := at
	for out.len < count {
		if !r.has(pos, 1) {
			return error('var: delta run header at ${pos} outside table (${data.len} bytes)')
		}
		h := int(r.u8_at(pos))
		pos++
		n := (h & 0x3f) + 1
		kind := h & 0xc0
		if kind == 0x80 {
			for _ in 0 .. n {
				out << 0
			}
		} else if kind == 0x40 {
			for _ in 0 .. n {
				if !r.has(pos, 2) {
					return error('var: word delta overruns the table')
				}
				out << int(r.i16_at(pos))
				pos += 2
			}
		} else if kind == 0xc0 {
			for _ in 0 .. n {
				if !r.has(pos, 4) {
					return error('var: long delta overruns the table')
				}
				out << int(r.i32_at(pos))
				pos += 4
			}
		} else {
			for _ in 0 .. n {
				if !r.has(pos, 1) {
					return error('var: byte delta overruns the table')
				}
				out << int(i8(r.u8_at(pos)))
				pos++
			}
		}
	}
	return out, pos
}

// var_tuple_scalar evaluates one tuple tent at the blend coordinates: the
// product over axes of the per-axis factor, which is 1 at the peak, ramps
// linearly to 0 at the region edges, and is 0 outside.
//
// An axis whose peak is 0 does not participate, an invalid region (peak
// outside start..end, or a region crossing zero) does not participate, and a
// coordinate exactly at the peak contributes 1, the OpenType-specific cases
// in `supportScalar`. No extrapolation happens: normalization already
// clamped the coordinates into the axis range.
fn var_tuple_scalar(peak []f64, start_r []f64, end_r []f64, blended []f64) f64 {
	mut scalar := 1.0
	for a in 0 .. peak.len {
		p := peak[a]
		if p == 0.0 {
			continue
		}
		lo := start_r[a]
		hi := end_r[a]
		if lo > p || p > hi {
			continue
		}
		if lo < 0.0 && hi > 0.0 {
			continue
		}
		v := blended[a]
		if v == p {
			continue
		}
		if v <= lo || hi <= v {
			return 0.0
		}
		if v < p {
			scalar *= (v - lo) / (p - lo)
		} else {
			scalar *= (v - hi) / (p - hi)
		}
	}
	return scalar
}

// var_mulfix multiplies two 16.16 fixed-point numbers the way FT_MulFix
// does: sign-symmetric, rounding half away from zero on the magnitude.
// Every scaled gvar delta goes through it, so each tuple product is exact
// to the rasterizer bit rather than exact in floating point and rounded
// later, which differ once the IUP divides them again.
pub fn var_mulfix(a i64, b i64) i64 {
	mut aa := a
	mut bb := b
	mut s := i64(1)
	if aa < 0 {
		aa = -aa
		s = -s
	}
	if bb < 0 {
		bb = -bb
		s = -s
	}
	c := (aa * bb + i64(0x8000)) >> 16
	return if s > 0 { c } else { -c }
}

// var_divfix divides two 16.16 fixed-point numbers the way FT_DivFix does:
// the quotient rounds half away from zero on the magnitude. It is the slope
// of the IUP ramp, and the rounding is load-bearing: truncating instead
// lands interpolated points a unit below FreeType, which the sweep pins.
pub fn var_divfix(a i64, b i64) i64 {
	if b == 0 {
		return if a >= 0 { i64(0x7fffffff) } else { -i64(0x7fffffff) }
	}
	mut aa := a
	mut bb := b
	mut s := i64(1)
	if aa < 0 {
		aa = -aa
		s = -s
	}
	if bb < 0 {
		bb = -bb
		s = -s
	}
	q := ((aa << 16) + (bb >> 1)) / bb
	return if s > 0 { q } else { -q }
}

// var_fixed_to_int rounds a 16.16 delta to integer units the way
// FT_fixedToInt does: half up, towards positive infinity. This is the last
// step of instancing, applied once to the summed total, and it is what the
// rasterizer integer points need.
pub fn var_fixed_to_int(x i64) int {
	return int((x + i64(0x8000)) >> 16)
}

// var_scalar_fixed converts a tent scalar to the 16.16 factor FreeType
// multiplies with: rounded half away from zero, the way the chained
// FT_MulDiv scaling factors come out on single-axis fonts. A zero scalar
// stays zero, which is what skips inactive tuples. Multi-axis products
// chain their rounding per axis inside FreeType and round once here, which
// can differ by one last-place unit; the corpus faces are single-axis, so
// no committed pin can tell them apart.
pub fn var_scalar_fixed(scalar f64) i64 {
	if scalar >= 0.0 {
		return i64(scalar * 65536.0 + 0.5)
	}
	return -i64(-scalar * 65536.0 + 0.5)
}

// var_ft_interpolate fills one axis of untouched points between two touched
// references, the integer twin of the IUP ramp. It mirrors
// `tt_delta_interpolate` op for op: the references are ordered by base
// coordinate, equal coordinates carry the shared delta when the two agree
// and stay uninterpolated when they do not, and inside the interval the
// point takes the lower reference plus the fixed-point product of its
// distance and the fixed-point slope. `base` and `out` are 16.16 full
// coordinates, not deltas: interpolating positions is what makes the
// fixed-point truncation land where FreeType lands it.
fn var_ft_interpolate(p1 int, p2 int, r1 int, r2 int, base []i64, mut out []i64) {
	if p1 > p2 {
		return
	}
	mut ra := r1
	mut rb := r2
	if base[ra] > base[rb] {
		ra = r2
		rb = r1
	}
	in1 := base[ra]
	in2 := base[rb]
	out1 := out[ra]
	out2 := out[rb]
	d1 := out1 - in1
	d2 := out2 - in2
	if in1 != in2 || out1 == out2 {
		scale := if in1 != in2 { var_divfix(out2 - out1, in2 - in1) } else { i64(0) }
		for p in p1 .. p2 + 1 {
			o := base[p]
			if o <= in1 {
				out[p] = o + d1
			} else if o >= in2 {
				out[p] = o + d2
			} else {
				out[p] = out1 + var_mulfix(o - in1, scale)
			}
		}
	}
}

// var_ft_shift moves every other point of a contour by the one touched
// point delta, the way `tt_delta_shift` does when a contour names a single
// reference. Interpolating from one point to itself would divide by zero,
// so the single delta is shared instead.
fn var_ft_shift(p1 int, p2 int, r int, base []i64, mut out []i64) {
	d := out[r] - base[r]
	if d == 0 {
		return
	}
	for p in p1 .. r {
		out[p] += d
	}
	for p in r + 1 .. p2 + 1 {
		out[p] += d
	}
}

// var_ft_iup_contour fills the untouched points of one contour the way
// `tt_interpolate_deltas` does: runs between touched points interpolate,
// the ends wrap round from the last touched point to the first, and a lone
// touched point shifts the whole contour. A contour with no touched points
// keeps its base coordinates, which is a zero delta. The `first > c0`
// guard reads oddly and matches FreeType op for op: with the contour own
// start there is no leading run to fill either way.
fn var_ft_iup_contour(mut ox []i64, mut oy []i64, touched []bool, bxs []i64, bys []i64, c0 int, c1 int) {
	mut point := c0
	for point <= c1 && !touched[point] {
		point++
	}
	if point > c1 {
		return
	}
	first := point
	mut cur := point
	point++
	for point <= c1 {
		if touched[point] {
			var_ft_interpolate(cur + 1, point - 1, cur, point, bxs, mut ox)
			var_ft_interpolate(cur + 1, point - 1, cur, point, bys, mut oy)
			cur = point
		}
		point++
	}
	if cur == first {
		var_ft_shift(c0, c1, cur, bxs, mut ox)
		var_ft_shift(c0, c1, cur, bys, mut oy)
	} else {
		var_ft_interpolate(cur + 1, c1, cur, first, bxs, mut ox)
		var_ft_interpolate(cur + 1, c1, cur, first, bys, mut oy)
		if first > c0 {
			var_ft_interpolate(c0, first - 1, cur, first, bxs, mut ox)
			var_ft_interpolate(c0, first - 1, cur, first, bys, mut oy)
		}
	}
}

// var_ft_iup_fill runs the fixed-point IUP over one tuple scaled
// coordinates: every real contour interpolates its untouched points from
// its touched ones, and each phantom point is outside every contour, so an
// untouched phantom keeps its scaled delta rather than borrowing a real
// point one, the way solitary points skip interpolation in FreeType.
fn var_ft_iup_fill(mut ox []i64, mut oy []i64, touched []bool, bxs []i64, bys []i64, end_pts []int, point_count int) {
	mut start := 0
	for e in end_pts {
		if e >= start && e < point_count {
			var_ft_iup_contour(mut ox, mut oy, touched, bxs, bys, start, e)
			start = e + 1
		}
	}
}

// var_gvar_deltas applies every `gvar` tuple for one glyph at the blend
// coordinates and answers the total x and y delta per point in 16.16 fixed point, plus the four
// phantom points appended after the real ones.
//
// Each tuple scales its deltas by its tent scalar, fills untouched points by
// fixed-point IUP over the scaled positions, and adds the deltas into the
// running 16.16 total; the caller rounds once. A tuple with scalar zero
// contributes nothing, points outside the glyph (a corrupt run idea of a
// point number) are skipped, and a glyph the table does not cover answers
// zeros. `base_xs`, `base_ys` and `end_pts` are the uninterpolated outline,
// which IUP interpolates over.
// var_skip_deltas advances past one packed delta stream without decoding or
// allocating it. It mirrors var_unpack_deltas's run headers exactly: an
// inactive tuple still has to step over its x and y streams so the next
// tuple starts at the same byte, but no value is ever read.
fn var_skip_deltas(data []u8, at int, count int) !int {
	r := new_reader(data)
	mut pos := at
	mut left := count
	for left > 0 {
		if !r.has(pos, 1) {
			return error('var: delta run header at ${pos} outside table (${data.len} bytes)')
		}
		h := int(r.u8_at(pos))
		pos++
		n := (h & 0x3f) + 1
		kind := h & 0xc0
		step := if kind == 0x80 {
			0
		} else if kind == 0x40 {
			2
		} else if kind == 0xc0 {
			4
		} else {
			1
		}
		if step > 0 && !r.has(pos, step * n) {
			return error('var: delta run overruns the table')
		}
		pos += step * n
		left -= n
	}
	return pos
}

pub fn var_gvar_deltas(gvar []u8, axis_tags []string, gid int, blended []f64, base_xs []int, base_ys []int, end_pts []int) !([]i64, []i64) {
	point_count := base_xs.len
	if base_ys.len != point_count {
		return error('var: ${point_count} x coordinates with ${base_ys.len} y coordinates')
	}
	if blended.len != axis_tags.len {
		return error('var: ${blended.len} blend coordinates for ${axis_tags.len} axes')
	}
	total := point_count + 4
	mut dx := []i64{len: total}
	mut dy := []i64{len: total}
	mut bxs := []i64{len: total}
	mut bys := []i64{len: total}
	for i in 0 .. point_count {
		bxs[i] = i64(base_xs[i]) << 16
		bys[i] = i64(base_ys[i]) << 16
	}
	if gvar.len == 0 {
		return dx, dy
	}
	r := new_reader(gvar)
	if !r.has(0, 20) {
		return error('var: gvar table too short (${gvar.len} bytes)')
	}
	if r.u16_at(0) != 1 {
		return error('var: unsupported gvar version ${r.u16_at(0)}')
	}
	axis_count := int(r.u16_at(4))
	if axis_count != axis_tags.len {
		return error('var: gvar covers ${axis_count} axes, asked with ${axis_tags.len}')
	}
	shared_count := int(r.u16_at(6))
	shared_off := int(r.u32_at(8))
	glyph_count := int(r.u16_at(12))
	long_offsets := int(r.u16_at(14)) & 1 == 1
	data_base := int(r.u32_at(16))
	if gid < 0 || gid >= glyph_count {
		return dx, dy
	}
	off_size := if long_offsets { 4 } else { 2 }
	off_at := 20 + gid * off_size
	if !r.has(off_at, 2 * off_size) {
		return error('var: gvar offsets for gid ${gid} overrun the table')
	}
	mut start := 0
	mut stop := 0
	if long_offsets {
		start = int(r.u32_at(off_at))
		stop = int(r.u32_at(off_at + 4))
	} else {
		start = int(r.u16_at(off_at)) * 2
		stop = int(r.u16_at(off_at + 2)) * 2
	}
	if start == stop {
		return dx, dy
	}
	gbase := data_base + start
	gend := data_base + stop
	if gbase < 0 || gend > gvar.len || gbase + 4 > gend {
		return error('var: gid ${gid} variation data outside gvar table')
	}
	whole := int(r.u16_at(gbase))
	tuple_count := whole & 0x0fff
	shares_points := whole & 0x8000 != 0
	mut apos := gbase + int(r.u16_at(gbase + 2))
	if apos < gbase || apos > gend {
		return error('var: gid ${gid} aux data outside its variation data')
	}
	mut tuple_pos := gbase + 4
	mut shared_peaks := [][]f64{len: shared_count}
	for s in 0 .. shared_count {
		at := shared_off + s * axis_count * 2
		if !r.has(at, axis_count * 2) {
			return error('var: shared tuple ${s} outside gvar table')
		}
		mut peak := []f64{len: axis_count}
		for a in 0 .. axis_count {
			peak[a] = var_f2dot14(r.i16_at(at + a * 2))
		}
		shared_peaks[s] = peak
	}
	mut shared_points := []int{}
	mut shared_all := false
	if shares_points {
		pts, next, all := var_unpack_points(gvar, apos, total) or { return err }
		apos = next
		shared_points = pts.clone()
		shared_all = all
	}
	for _ in 0 .. tuple_count {
		if !r.has(tuple_pos, 4) {
			return error('var: gid ${gid} tuple header overruns its variation data')
		}
		tuple_index := int(r.u16_at(tuple_pos + 2))
		tuple_pos += 4
		embedded := tuple_index & 0x8000 != 0
		intermediate := tuple_index & 0x4000 != 0
		private_pts := tuple_index & 0x2000 != 0
		mut peak := []f64{len: axis_count}
		if embedded {
			if !r.has(tuple_pos, axis_count * 2) {
				return error('var: gid ${gid} embedded peak overruns its variation data')
			}
			for a in 0 .. axis_count {
				peak[a] = var_f2dot14(r.i16_at(tuple_pos + a * 2))
			}
			tuple_pos += axis_count * 2
		} else {
			idx := tuple_index & 0x0fff
			if idx >= shared_peaks.len {
				return error('var: gid ${gid} names shared tuple ${idx} of ${shared_peaks.len}')
			}
			peak = shared_peaks[idx].clone()
		}
		mut start_r := []f64{len: axis_count}
		mut end_r := []f64{len: axis_count}
		if intermediate {
			if !r.has(tuple_pos, axis_count * 4) {
				return error('var: gid ${gid} intermediate range overruns its variation data')
			}
			for a in 0 .. axis_count {
				start_r[a] = var_f2dot14(r.i16_at(tuple_pos + a * 2))
			}
			tuple_pos += axis_count * 2
			for a in 0 .. axis_count {
				end_r[a] = var_f2dot14(r.i16_at(tuple_pos + a * 2))
			}
			tuple_pos += axis_count * 2
		} else {
			for a in 0 .. axis_count {
				p := peak[a]
				start_r[a] = if p < 0.0 { p } else { 0.0 }
				end_r[a] = if p > 0.0 { p } else { 0.0 }
			}
		}
		scalar := var_tuple_scalar(peak, start_r, end_r, blended)
		apply := if scalar == 0.0 { 0 } else { var_scalar_fixed(scalar) }
		if apply == 0 {
			// Still step over this tuple's point set and both delta streams:
			// the next tuple's offsets are relative to apos. A private point
			// set is decoded with count=total, so it carries total numbers and
			// total deltas; a shared one follows shared_all.
			n_skip := if private_pts {
				apos = var_skip_points(gvar, apos, total) or { return err }
				total
			} else if shared_all {
				total
			} else {
				shared_points.len
			}
			apos = var_skip_deltas(gvar, apos, n_skip) or { return err }
			apos = var_skip_deltas(gvar, apos, n_skip) or { return err }
			continue
		}
		mut pts := shared_points.clone()
		mut all := shared_all
		if private_pts {
			p2, n2, a2 := var_unpack_points(gvar, apos, total) or { return err }
			apos = n2
			pts = p2.clone()
			all = a2
		}
		n := if all { total } else { pts.len }
		xd, next_x := var_unpack_deltas(gvar, apos, n) or { return err }
		apos = next_x
		yd, next_y := var_unpack_deltas(gvar, apos, n) or { return err }
		apos = next_y
		if all {
			for k in 0 .. n {
				dx[k] += var_mulfix(i64(xd[k]) << 16, apply)
				dy[k] += var_mulfix(i64(yd[k]) << 16, apply)
			}
			continue
		}
		mut ox := []i64{len: total}
		mut oy := []i64{len: total}
		for i in 0 .. total {
			ox[i] = bxs[i]
			oy[i] = bys[i]
		}
		mut touched := []bool{len: total}
		for k, p in pts {
			if p < 0 || p >= total {
				continue
			}
			ox[p] += var_mulfix(i64(xd[k]) << 16, apply)
			oy[p] += var_mulfix(i64(yd[k]) << 16, apply)
			touched[p] = true
		}
		var_ft_iup_fill(mut ox, mut oy, touched, bxs, bys, end_pts, point_count)
		for i in 0 .. total {
			dx[i] += ox[i] - bxs[i]
			dy[i] += oy[i] - bys[i]
		}
	}
	return dx, dy
}

// var_apply_deltas adds rounded total deltas onto a base outline: each point
// moves by its total rounded half up, and the advance shift is the rounded
// difference of the two horizontal phantom totals, the way `_setCoordinates`
// derives the advance from right minus left (the bases already differ by the
// base advance, so only the delta difference remains).
pub fn var_apply_deltas(xs []int, ys []int, dx []i64, dy []i64) ([]int, []int, int) {
	total := xs.len + 4
	mut ox := []int{len: xs.len}
	mut oy := []int{len: xs.len}
	for i in 0 .. xs.len {
		ox[i] = xs[i] + if i < dx.len { var_fixed_to_int(dx[i]) } else { 0 }
		oy[i] = ys[i] + if i < dy.len { var_fixed_to_int(dy[i]) } else { 0 }
	}
	mut adv := 0
	if dx.len >= total {
		adv = var_fixed_to_int(dx[xs.len + 1] - dx[xs.len])
	}
	return ox, oy, adv
}

// var_instance_glyph instances one glyph at design coordinates: read its
// uninterpolated points, blend the coordinates, apply `gvar`, round once.
//
// The coordinates run in `fvar` axis order and are design units, the numbers
// a caller passes to `FT_Set_Var_Design_Coordinates`. `long_loca` says the
// `loca` format (head indexToLocFormat of 1), and an empty `gvar` answers
// the uninterpolated outline, which is what a caller that only wants points
// gets for a static font. Composites instance through
// `var_instance_recursive`: each component at the same blend, offsets
// adjusted by the composite's own `gvar` deltas, phantom points honored.
pub fn var_instance_glyph(glyf []u8, loca []u8, gvar []u8, avar []u8, axes []VariableAxis, gid int, coords []f64, long_loca bool) !InstancedOutline {
	if axes.len == 0 {
		return error('var: no fvar axes, nothing to instance')
	}
	blended := var_blend_coords(axes, avar, coords) or { return err }
	return var_instance_glyph_blended(glyf, loca, gvar, axes, gid, blended, long_loca)
}

// var_instance_glyph_blended is the same instancing with the avar-warped
// blend already computed. The caller that holds prepared per-face state can
// pass it directly instead of re-parsing avar and re-normalizing per glyph.
pub fn var_instance_glyph_blended(glyf []u8, loca []u8, gvar []u8, axes []VariableAxis, gid int, blended []f64, long_loca bool) !InstancedOutline {
	if axes.len == 0 {
		return error('var: no fvar axes, nothing to instance')
	}
	mut tags := []string{len: axes.len}
	for i, a in axes {
		tags[i] = a.tag
	}
	ox, oy, ends, adv := var_instance_recursive(glyf, loca, gvar, tags, blended, gid, long_loca, 0) or {
		return err
	}
	return InstancedOutline{
		xs:         ox
		ys:         oy
		end_pts:    ends
		advance_dx: adv
	}
}

// var_parse_composite answers one composite's components in order, without
// resolving them. The parsing mirrors `glyf_read_composite` op for op:
// arguments before the transform, one transform form at most, scaled flag
// carried. Instructions are not components and are not returned.
fn var_parse_composite(glyf []u8, start int, stop int) ![]GlyfComponent {
	r := new_reader(glyf)
	mut out := []GlyfComponent{}
	mut p := start + 10
	for {
		if !r.has(p, 4) {
			return error('var: composite at ${start} component header overruns the outline')
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
				return error('var: composite at ${start} arguments overrun the outline')
			}
			c.dx = f64(r.i16_at(p))
			c.dy = f64(r.i16_at(p + 2))
			p += 4
		} else if words {
			if !r.has(p, 4) {
				return error('var: composite at ${start} arguments overrun the outline')
			}
			c.anchor = true
			c.first = int(r.u16_at(p))
			c.second = int(r.u16_at(p + 2))
			p += 4
		} else if is_xy {
			if !r.has(p, 2) {
				return error('var: composite at ${start} arguments overrun the outline')
			}
			rawx := int(r.u8_at(p))
			rawy := int(r.u8_at(p + 1))
			c.dx = f64(if rawx >= 128 { rawx - 256 } else { rawx })
			c.dy = f64(if rawy >= 128 { rawy - 256 } else { rawy })
			p += 2
		} else {
			if !r.has(p, 2) {
				return error('var: composite at ${start} arguments overrun the outline')
			}
			c.anchor = true
			c.first = int(r.u8_at(p))
			c.second = int(r.u8_at(p + 1))
			p += 2
		}
		if flags & 0x0008 != 0 {
			if !r.has(p, 2) {
				return error('var: composite at ${start} scale overruns the outline')
			}
			s := glyf_f2dot14(r.i16_at(p))
			p += 2
			c.has_xform = true
			c.a = s
			c.d = s
		} else if flags & 0x0040 != 0 {
			if !r.has(p, 4) {
				return error('var: composite at ${start} scale overruns the outline')
			}
			c.has_xform = true
			c.a = glyf_f2dot14(r.i16_at(p))
			c.d = glyf_f2dot14(r.i16_at(p + 2))
			p += 4
		} else if flags & 0x0080 != 0 {
			if !r.has(p, 8) {
				return error('var: composite at ${start} transform overruns the outline')
			}
			c.has_xform = true
			c.a = glyf_f2dot14(r.i16_at(p))
			c.b = glyf_f2dot14(r.i16_at(p + 2))
			c.c = glyf_f2dot14(r.i16_at(p + 4))
			c.d = glyf_f2dot14(r.i16_at(p + 6))
			p += 8
		}
		c.scaled = flags & 0x0800 != 0
		out << c
		if flags & 0x0020 == 0 {
			break
		}
		if out.len > glyf_max_component_depth * 4 + 4 {
			return error('var: composite at ${start} names too many components')
		}
	}
	return out
}

// var_instance_recursive instances one glyph at already-blended coordinates,
// returning flattened points, contour ends and the phantom-derived advance.
// Simple glyphs go through `var_gvar_deltas` plus `var_apply_deltas`;
// composites instance each component recursively, adjust the offsets by the
// composite's own `gvar` deltas (first N points, rounded once via otRound)
// and honor the four phantom points for the advance. Depth caps nesting the
// way `glyf_resolve` does, so a cyclic font is refused, not recursed on.
fn var_instance_recursive(glyf []u8, loca []u8, gvar []u8, tags []string, blended []f64, gid int, long_loca bool, depth int) !([]int, []int, []int, int) {
	if depth > glyf_max_component_depth {
		return error('var: gid ${gid} nests past ${glyf_max_component_depth} components, likely a corrupt cycle')
	}
	start, stop := var_loca_range(loca, glyf.len, gid, long_loca) or { return err }
	if start == stop {
		return []int{}, []int{}, []int{}, 0
	}
	r := new_reader(glyf)
	if start < 0 || start + 10 > stop || stop > glyf.len {
		return error('var: glyph bytes [${start}..${stop}] outside glyf table (${glyf.len} bytes)')
	}
	ncont := int(r.i16_at(start))
	if ncont == 0 {
		return []int{}, []int{}, []int{}, 0
	}
	if ncont > 0 {
		xs, ys, ends := var_read_glyph_points(glyf, start, stop) or { return err }
		dx, dy := var_gvar_deltas(gvar, tags, gid, blended, xs, ys, ends) or { return err }
		ox, oy, adv := var_apply_deltas(xs, ys, dx, dy)
		return ox, oy, ends, adv
	}
	comps := var_parse_composite(glyf, start, stop) or { return err }
	ncomp := comps.len
	mut zeros := []int{len: ncomp}
	dx, dy := var_gvar_deltas(gvar, tags, gid, blended, zeros, zeros, []int{}) or {
		return err
	}
	mut off_dx := []int{len: ncomp}
	mut off_dy := []int{len: ncomp}
	for i in 0 .. ncomp {
		off_dx[i] = if i < dx.len { var_fixed_to_int(dx[i]) } else { 0 }
		off_dy[i] = if i < dy.len { var_fixed_to_int(dy[i]) } else { 0 }
	}
	mut adv := 0
	if dx.len >= ncomp + 2 && dy.len >= ncomp + 2 {
		adv = var_fixed_to_int(dx[ncomp + 1] - dx[ncomp])
	}
	mut out_xs := []int{}
	mut out_ys := []int{}
	mut out_ends := []int{}
	for idx, c in comps {
		cx, cy, cends, _ := var_instance_recursive(glyf, loca, gvar, tags, blended, c.gid, long_loca, depth + 1) or {
			return err
		}
		if cx.len == 0 {
			continue
		}
		mut fx := []f64{len: cx.len}
		mut fy := []f64{len: cx.len}
		for i in 0 .. cx.len {
			fx[i] = f64(cx[i])
			fy[i] = f64(cy[i])
		}
		base := out_xs.len
		if c.anchor {
			if c.first < 0 || c.first >= out_xs.len || c.second < 0 || c.second >= fx.len {
				return error('var: anchor points ${c.first}/${c.second} name no points')
			}
			mut px := fx[c.second]
			mut py := fy[c.second]
			if c.has_xform {
				px = fx[c.second] * c.a + fy[c.second] * c.c
				py = fx[c.second] * c.b + fy[c.second] * c.d
			}
			mut shx := f64(out_xs[c.first]) - px + f64(off_dx[idx])
			mut shy := f64(out_ys[c.first]) - py + f64(off_dy[idx])
			if c.has_xform {
				for i in 0 .. fx.len {
					ox := fx[i]
					oy := fy[i]
					fx[i] = ox * c.a + oy * c.c + shx
					fy[i] = ox * c.b + oy * c.d + shy
				}
			} else {
				for i in 0 .. fx.len {
					fx[i] = fx[i] + shx
					fy[i] = fy[i] + shy
				}
			}
		} else {
			ndx := c.dx + f64(off_dx[idx])
			ndy := c.dy + f64(off_dy[idx])
			if c.has_xform && !c.scaled {
				for i in 0 .. fx.len {
					ox := fx[i]
					oy := fy[i]
					fx[i] = ox * c.a + oy * c.c + ndx
					fy[i] = ox * c.b + oy * c.d + ndy
				}
			} else if c.has_xform {
				for i in 0 .. fx.len {
					ox := fx[i] + ndx
					oy := fy[i] + ndy
					fx[i] = ox * c.a + oy * c.c
					fy[i] = ox * c.b + oy * c.d
				}
			} else {
				for i in 0 .. fx.len {
					fx[i] = fx[i] + ndx
					fy[i] = fy[i] + ndy
				}
			}
		}
		// Component contour ends re-base onto the growing list: instancing
		// moves points but never adds or removes them, so the recursive
		// ends number the same contours as the base outline.
		for e in cends {
			out_ends << base + e
		}
		for i in 0 .. fx.len {
			out_xs << var_ot_round(fx[i])
			out_ys << var_ot_round(fy[i])
		}
	}
	return out_xs, out_ys, out_ends, adv
}

// var_wants_instanced reports whether the face carries a non-default
// variation instance: an fvar with a gvar beside it, and stored coordinates
// that differ from the defaults. At the default (or on a static font) the
// stb path already draws the right ink, so the raster wiring stays out of
// the way; off the default the instanced outline is authoritative.
fn (f &Face) var_wants_instanced() bool {
	axes := f.read_variable_axes()
	if axes.len == 0 {
		return false
	}
	if f.sfnt.table_data(tag_gvar).len == 0 {
		return false
	}
	coords := f.var_coords()
	if coords.len != axes.len {
		return false
	}
	for i, a in axes {
		if coords[i] != a.deflt {
			return true
		}
	}
	return false
}

// VarPoint is one flattened design-space point for the instanced raster.
struct VarPoint {
	x f64
	y f64
}

// var_flatten_quad appends p2's subdivision: one segment when the control
// sits within tol of the chord, four quarters of recursion otherwise. Depth
// caps at twelve, far past the corpus need, so hostile curves terminate.
fn var_flatten_quad(p0 VarPoint, p1 VarPoint, p2 VarPoint, tol f64, depth int, mut out []VarPoint) {
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
	q0 := VarPoint{ x: (p0.x + p1.x) / 2.0, y: (p0.y + p1.y) / 2.0 }
	q1 := VarPoint{ x: (p1.x + p2.x) / 2.0, y: (p1.y + p2.y) / 2.0 }
	mid := VarPoint{ x: (q0.x + q1.x) / 2.0, y: (q0.y + q1.y) / 2.0 }
	var_flatten_quad(p0, q0, mid, tol, depth + 1, mut out)
	var_flatten_quad(mid, q1, p2, tol, depth + 1, mut out)
}

// var_flatten_contour answers one TrueType contour as a line polygon:
// implied on-curve midpoints split every off-curve pair (including runs that
// are all off-curve), lines stay lines, quadratics subdivide at tol.
fn var_flatten_contour(xs []int, ys []int, on_curve []bool, s int, e int, tol f64) []VarPoint {
	n := e - s + 1
	if n <= 0 {
		return []VarPoint{}
	}
	if n == 1 {
		return [VarPoint{ x: f64(xs[s]), y: f64(ys[s]) }]
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
		return []VarPoint{}
	}
	mut out := []VarPoint{cap: m * 2}
	out << VarPoint{ x: ex[start], y: ey[start] }
	cur_pt := VarPoint{ x: ex[start], y: ey[start] }
	mut cur := start
	for _ in 0 .. m + 2 {
		nxt := (cur + 1) % m
		if en[nxt] {
			if nxt == start {
				break
			}
			next_pt := VarPoint{ x: ex[nxt], y: ey[nxt] }
			out << next_pt
			cur = nxt
		} else {
			nxt2 := (cur + 2) % m
			ctrl_pt := VarPoint{ x: ex[nxt], y: ey[nxt] }
			end_pt := VarPoint{ x: ex[nxt2], y: ey[nxt2] }
			var_flatten_quad(cur_pt, ctrl_pt, end_pt, tol, 0, mut out)
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

// var_even_odd answers whether (x, y) sits inside the flattened polygons,
// even-odd across every contour. One ray to +inf in x counts edge crossings;
// an odd count is ink.
fn var_even_odd(x f64, y f64, polys [][]VarPoint) bool {
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
			if (yi > y) != (yj > y) {
				xint := (xj - xi) * (y - yi) / (yj - yi) + xi
				if x < xint {
					inside = !inside
				}
			}
			j = i
		}
	}
	return inside
}

// var_instanced_polys flattens the instanced outline of gid into pixel-space
// polygons (y down, pen at the origin, subpixel shift applied). Design units
// scale by em_px/upm; off-curves flatten at one design unit, the same order
// as the reader's own integer rounding. Empty when the glyph has no ink, no
// TrueType outlines (CFF), or the outlines disagree.
fn (f &Face) var_instanced_polys(gid u16, em_px f64, sub_x i32, sub_y i32) [][]VarPoint {
	if em_px <= 0 || f.units_per_em_f <= 0 {
		return [][]VarPoint{}
	}
	inst := f.instanced_glyph_points(gid) or { return [][]VarPoint{} }
	if inst.xs.len == 0 {
		return [][]VarPoint{}
	}
	base := f.glyph_outline(gid) or { return [][]VarPoint{} }
	if base.xs.len != inst.xs.len || base.end_pts.len != inst.end_pts.len {
		return [][]VarPoint{}
	}
	for i, e in base.end_pts {
		if e != inst.end_pts[i] {
			return [][]VarPoint{}
		}
	}
	scale := em_px / f.units_per_em_f
	fx := f64(sub_x) * 0.25
	fy := f64(sub_y) * 0.25
	mut polys := [][]VarPoint{cap: base.end_pts.len}
	mut s := 0
	for _, e in base.end_pts {
		flat := var_flatten_contour(inst.xs, inst.ys, base.on_curve, s, e, 1.0)
		mut poly := []VarPoint{cap: flat.len}
		for p in flat {
			poly << VarPoint{
				x: p.x * scale + fx
				y: -p.y * scale + fy
			}
		}
		// Drop degenerate polygons; they contribute no crossings.
		if poly.len >= 3 {
			polys << poly
		}
		s = e + 1
	}
	return polys
}

// var_instanced_box answers the instanced ink box without rendering: the
// floor/ceil of the scaled instanced points, in the same left/top convention
// `box_only` uses. Coverageless, like `box_only`: measuring needs no fill.
pub fn (f &Face) var_instanced_box(gid u16, em_px f64, sub_x i32, sub_y i32) raster.GlyphBitmap {
	mut out := raster.GlyphBitmap{}
	if em_px <= 0 || f.units_per_em_f <= 0 {
		return out
	}
	inst := f.instanced_glyph_points(gid) or { return out }
	if inst.xs.len == 0 {
		return out
	}
	scale := em_px / f.units_per_em_f
	fx := f64(sub_x) * 0.25
	fy := f64(sub_y) * 0.25
	mut xmin := f64(inst.xs[0])
	mut xmax := f64(inst.xs[0])
	mut ymin := f64(inst.ys[0])
	mut ymax := f64(inst.ys[0])
	for i in 1 .. inst.xs.len {
		x := f64(inst.xs[i])
		y := f64(inst.ys[i])
		if x < xmin {
			xmin = x
		}
		if x > xmax {
			xmax = x
		}
		if y < ymin {
			ymin = y
		}
		if y > ymax {
			ymax = y
		}
	}
	ix0 := int(math.floor(xmin * scale + fx))
	ix1 := int(math.ceil(xmax * scale + fx))
	iy0 := int(math.floor(-ymax * scale + fy))
	iy1 := int(math.ceil(-ymin * scale + fy))
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

// var_instanced_bitmap renders the instanced outline at em_px and the
// caller's subpixel shift: the box from `var_instanced_box` with the same
// left/top/width/height, coverage from a 4x4 supersampled even-odd fill of
// the flattened polygons. Empty when the box is empty or the outlines
// disagree.
pub fn (f &Face) var_instanced_bitmap(gid u16, em_px f64, sub_x i32, sub_y i32) raster.GlyphBitmap {
	box := f.var_instanced_box(gid, em_px, sub_x, sub_y)
	if box.is_empty() {
		return raster.GlyphBitmap{}
	}
	polys := f.var_instanced_polys(gid, em_px, sub_x, sub_y)
	if polys.len == 0 {
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
					if var_even_odd(px, py, polys) {
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

// var_render_into fills the caller's w*h buffer with the instanced outline at
// the caller's shift, positioned the way `render_into` positions stb ink:
// buffer pixel (dx, dy) covers the square at the shifted origin plus (dx,
// dy). A glyph with no instanced ink leaves the buffer zeros.
pub fn (f &Face) var_render_into(gid u16, em_px f64, sub_x i32, sub_y i32, out &u8, w int, h int) {
	if w <= 0 || h <= 0 || em_px <= 0 || f.units_per_em_f <= 0 {
		return
	}
	polys := f.var_instanced_polys(gid, em_px, sub_x, sub_y)
	if polys.len == 0 {
		return
	}
	inst := f.instanced_glyph_points(gid) or { return }
	if inst.xs.len == 0 {
		return
	}
	scale := em_px / f.units_per_em_f
	fx := f64(sub_x) * 0.25
	fy := f64(sub_y) * 0.25
	mut xmin := f64(inst.xs[0])
	mut xmax := f64(inst.xs[0])
	mut ymin := f64(inst.ys[0])
	mut ymax := f64(inst.ys[0])
	for i in 1 .. inst.xs.len {
		x := f64(inst.xs[i])
		y := f64(inst.ys[i])
		if x < xmin {
			xmin = x
		}
		if x > xmax {
			xmax = x
		}
		if y < ymin {
			ymin = y
		}
		if y > ymax {
			ymax = y
		}
	}
	ix0 := int(math.floor(xmin * scale + fx))
	iy0 := int(math.floor(-ymax * scale + fy))
	unsafe {
		for dy in 0 .. h {
			for dx in 0 .. w {
				mut hit := 0
				for sy in 0 .. 4 {
					for sx in 0 .. 4 {
						px := f64(ix0 + dx) + (f64(sx) + 0.5) / 4.0
						py := f64(iy0 + dy) + (f64(sy) + 0.5) / 4.0
						if var_even_odd(px, py, polys) {
							hit++
						}
					}
				}
				out[dy * w + dx] = u8((hit * 255 + 8) / 16)
			}
		}
	}
}
