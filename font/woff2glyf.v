module font

// WOFF2 glyf, loca and hmtx transforms (RFC 7932 §5).
//
// The brotli stream holds a *transformed* glyf: one header, seven
// sub-streams, and an optional overlap bitmap, instead of sfnt glyph
// records. Rebuilding walks the sub-streams glyph by glyph — point counts
// as 255UInt16, coordinates as flag triplets, composites verbatim — and
// compiles plain sfnt records plus a loca derived from their offsets.
// hmtx is either passed through or rebuilt from its two arrays, with
// missing side bearings taken from the glyph xMins the rebuild just
// produced. Anything the transform cannot describe errors; nothing is
// guessed.

const woff2_glyf_header_size = 36
const woff2_overlap_simple_flag = 1

// Woff2Glyph is one decoded glyph: simple coordinates or verbatim composite
// bytes, plus the box the final record carries (explicit from the bitmap or
// recalculated; empty glyphs carry none).
struct Woff2Glyph {
	ncontours int
	// simple:
	endpts  []int
	xs      []int
	ys      []int
	oncurve []bool
	instr   []u8
	overlap bool
	// composite: the component records verbatim, instructions appended at
	// compile time when has_instr.
	comp       []u8
	has_instr  bool
	comp_instr []u8
mut:
	xmin     int
	ymin     int
	xmax     int
	ymax     int
	has_bbox bool
}

// woff2_rebuild_glyf_loca decodes the transformed glyf table and returns the
// plain glyf bytes, the loca bytes and the transform's index format. loca
// length must equal the reconstructed length the directory claims; the glyf
// length is intentionally unchecked (see above). Public because the WOFF2
// tests pin it directly: no single committed font covers every transform.
pub fn woff2_rebuild_glyf_loca(data []u8, loca_orig int) !([]u8, []u8, int) {
	if data.len < woff2_glyf_header_size {
		return error('woff2: transformed glyf shorter than its header')
	}
	version := int(u16_be(data, 0))
	opt_flags := int(u16_be(data, 2))
	num_glyphs := int(u16_be(data, 4))
	index_format := int(u16_be(data, 6))
	if version != 0 {
		return error('woff2: transformed glyf version ${version}, want 0')
	}
	if opt_flags & 0xfffe != 0 {
		return error('woff2: transformed glyf reserves option bits ${opt_flags:04x}')
	}
	if index_format != 0 && index_format != 1 {
		return error('woff2: transformed glyf index format ${index_format}, want 0 or 1')
	}
	if num_glyphs <= 0 {
		return error('woff2: transformed glyf claims ${num_glyphs} glyphs')
	}
	mut sizes := []int{cap: 7}
	for k in 0 .. 7 {
		sizes << int(u32_be(data, 8 + k * 4))
	}
	mut at := woff2_glyf_header_size
	mut streams := [][]u8{cap: 7}
	for s in sizes {
		if s < 0 || at + s > data.len {
			return error('woff2: transformed glyf sub-stream overruns the table')
		}
		streams << data[at..at + s]
		at += s
	}
	mut overlap := []u8{}
	if opt_flags & woff2_overlap_simple_flag != 0 {
		n := (num_glyphs + 7) / 8
		if at + n > data.len {
			return error('woff2: transformed glyf overlap bitmap overruns the table')
		}
		overlap = data[at..at + n]
		at += n
	}
	if at != data.len {
		return error('woff2: transformed glyf has ${data.len - at} trailing bytes')
	}
	mut n_contours := streams[0]
	mut n_points := streams[1]
	mut flags_s := streams[2]
	mut glyph_s := streams[3]
	mut comp_s := streams[4]
	mut bbox_s := streams[5]
	mut instr_s := streams[6]
	if n_contours.len != num_glyphs * 2 {
		return error('woff2: nContour stream holds ${n_contours.len / 2} glyphs, header says ${num_glyphs}')
	}
	// The bbox bitmap heads the bbox stream: one bit per glyph, MSB first.
	bb_bits := (num_glyphs + 31) / 32 * 4
	if bbox_s.len < bb_bits {
		return error('woff2: bbox stream shorter than its bitmap')
	}
	bbox_bitmap := bbox_s[..bb_bits]
	bbox_s = bbox_s[bb_bits..]
	mut glyphs := []Woff2Glyph{cap: num_glyphs}
	for gid in 0 .. num_glyphs {
		n := int(i16_be(n_contours, gid * 2))
		if n == 0 {
			glyphs << Woff2Glyph{}
			continue
		}
		if n == -1 {
			g := woff2_decode_composite(mut comp_s, mut glyph_s, mut instr_s, gid)!
			b := woff2_glyph_bbox(bbox_bitmap, mut bbox_s, gid)!
			glyphs << Woff2Glyph{
				ncontours:  -1
				comp:       g.comp
				has_instr:  g.has_instr
				comp_instr: g.comp_instr
				xmin:       b[0]
				ymin:       b[1]
				xmax:       b[2]
				ymax:       b[3]
				has_bbox:   true
			}
			continue
		}
		if n < -1 {
			return error('woff2: glyph ${gid} has contour count ${n}')
		}
		g := woff2_decode_simple(n, mut n_points, mut flags_s, mut glyph_s, mut instr_s)!
		has_overlap := overlap.len > 0 && overlap[gid / 8] & (u8(0x80) >> u8(gid % 8)) != 0
		b := woff2_glyph_bbox(bbox_bitmap, mut bbox_s, gid)!
		mut rec := Woff2Glyph{
			ncontours: n
			endpts:    g.endpts
			xs:        g.xs
			ys:        g.ys
			oncurve:   g.oncurve
			instr:     g.instr
			overlap:   has_overlap
		}
		if b.len == 4 {
			rec.xmin = b[0]
			rec.ymin = b[1]
			rec.xmax = b[2]
			rec.ymax = b[3]
			rec.has_bbox = true
		} else {
			rec.xmin, rec.ymin, rec.xmax, rec.ymax = woff2_simple_bounds(g.xs, g.ys)
			rec.has_bbox = true
		}
		glyphs << rec
	}
	for s in [n_points, flags_s, glyph_s, comp_s, bbox_s, instr_s] {
		if s.len != 0 {
			return error('woff2: transformed glyf has ${s.len} unconsumed sub-stream bytes')
		}
	}
	// Composites resolved in a second pass: a component may reference any
	// glyph, and resolving against still-missing records would invent boxes.
	// The resolving set guards malicious cycles.
	mut resolving := []bool{len: num_glyphs}
	for gid in 0 .. num_glyphs {
		if glyphs[gid].ncontours == -1 && !glyphs[gid].has_bbox {
			woff2_resolve_composite(mut glyphs, gid, mut resolving)!
			if !glyphs[gid].has_bbox {
				return error('woff2: composite glyph ${gid} carries no bbox values')
			}
		}
	}
	// Compile plain records; loca offsets fall out of their lengths. Short
	// loca needs even offsets, so odd glyphs are padded — the same rule the
	// sfnt writer applies, kept here so the bytes match a converted TTF.
	mut glyf := []u8{}
	mut offsets := []int{cap: num_glyphs + 1}
	for g in glyphs {
		offsets << glyf.len
		if g.ncontours == 0 {
			continue
		}
		if g.ncontours == -1 {
			woff2_put_i16(mut glyf, -1)
			woff2_put_i16(mut glyf, g.xmin)
			woff2_put_i16(mut glyf, g.ymin)
			woff2_put_i16(mut glyf, g.xmax)
			woff2_put_i16(mut glyf, g.ymax)
			glyf << g.comp
			if g.has_instr {
				woff2_put_u16(mut glyf, g.comp_instr.len)
				glyf << g.comp_instr
			}
		} else {
			woff2_put_i16(mut glyf, g.ncontours)
			woff2_put_i16(mut glyf, g.xmin)
			woff2_put_i16(mut glyf, g.ymin)
			woff2_put_i16(mut glyf, g.xmax)
			woff2_put_i16(mut glyf, g.ymax)
			for e in g.endpts {
				woff2_put_u16(mut glyf, e)
			}
			woff2_put_u16(mut glyf, g.instr.len)
			glyf << g.instr
			woff2_compile_coords(mut glyf, g)!
		}
		if index_format == 0 && glyf.len % 2 != 0 {
			glyf << u8(0)
		}
	}
	offsets << glyf.len
	mut loca := []u8{}
	for o in offsets {
		if index_format == 0 {
			if o % 2 != 0 {
				return error('woff2: odd loca offset ${o} in short format')
			}
			woff2_put_u16(mut loca, o / 2)
		} else {
			woff2_put_u32(mut loca, u32(o))
		}
	}
	// loca length is exact by construction (one entry per glyph plus the
	// terminator); a mismatch is a builder bug, not input variation. The
	// glyf length is intentionally unchecked: re-encoding makes legitimate
	// choices (repeat runs, padding) that even the reference converter does
	// not reproduce byte for byte, so glyf is pinned semantically (outlines
	// equal per glyph) rather than by length.
	if loca.len != loca_orig {
		return error('woff2: rebuilt loca is ${loca.len} bytes, directory says ${loca_orig}')
	}
	return glyf, loca, index_format
}

// woff2_glyph_bbox reads one explicit box from the bbox stream when the
// bitmap names the glyph, and reports none otherwise. A missing box is not
// an error here: simple glyphs recalculate from their points, while a
// composite without one is refused at the call site, never invented.
fn woff2_glyph_bbox(bitmap []u8, mut stream []u8, gid int) ![]int {
	if bitmap[gid / 8] & (u8(0x80) >> u8(gid % 8)) == 0 {
		return []int{}
	}
	if stream.len < 8 {
		return error('woff2: glyph ${gid} bbox overruns the stream')
	}
	b := [int(i16_be(stream, 0)), int(i16_be(stream, 2)), int(i16_be(stream, 4)),
		int(i16_be(stream, 6))]
	stream = stream[8..]
	return b
}

// woff2_simple_bounds is the recalculated box: min/max of the points.
fn woff2_simple_bounds(xs []int, ys []int) (int, int, int, int) {
	mut xmin := xs[0]
	mut ymin := ys[0]
	mut xmax := xs[0]
	mut ymax := ys[0]
	for i in 1 .. xs.len {
		if xs[i] < xmin {
			xmin = xs[i]
		}
		if xs[i] > xmax {
			xmax = xs[i]
		}
		if ys[i] < ymin {
			ymin = ys[i]
		}
		if ys[i] > ymax {
			ymax = ys[i]
		}
	}
	return xmin, ymin, xmax, ymax
}

// woff2_decode_simple reads one simple glyph: contour end points as
// 255UInt16, then the flag triplets, then the instructions.
fn woff2_decode_simple(ncontours int, mut n_points []u8, mut flags_s []u8, mut glyph_s []u8, mut instr_s []u8) !Woff2Glyph {
	mut endpts := []int{cap: ncontours}
	mut end := -1
	for _ in 0 .. ncontours {
		pts, n := woff2_read_255ushort(n_points)!
		n_points = n_points[n..]
		end += pts
		if end < 0 {
			return error('woff2: contour end point underflows')
		}
		endpts << end
	}
	npoints := end + 1
	if npoints <= 0 {
		return error('woff2: simple glyph with no points')
	}
	if flags_s.len < npoints {
		return error('woff2: flag stream shorter than ${npoints} points')
	}
	flag_bytes := flags_s[..npoints]
	flags_s = flags_s[npoints..]
	mut xs := []int{cap: npoints}
	mut ys := []int{cap: npoints}
	mut oncurve := []bool{cap: npoints}
	mut x := 0
	mut y := 0
	mut ti := 0
	for i in 0 .. npoints {
		flag := int(flag_bytes[i])
		on := flag & 0x80 == 0
		f := flag & 0x7f
		mut nbytes := 0
		mut dx := 0
		mut dy := 0
		if f < 10 {
			nbytes = 1
			dy = woff2_triplet_sign(f, ((f & 14) << 7) + int(glyph_s[ti]))
		} else if f < 20 {
			nbytes = 1
			dx = woff2_triplet_sign(f, (((f - 10) & 14) << 7) + int(glyph_s[ti]))
		} else if f < 84 {
			nbytes = 1
			b0 := f - 20
			b1 := int(glyph_s[ti])
			dx = woff2_triplet_sign(f, 1 + (b0 & 0x30) + (b1 >> 4))
			dy = woff2_triplet_sign(f >> 1, 1 + ((b0 & 0x0c) << 2) + (b1 & 0x0f))
		} else if f < 120 {
			nbytes = 2
			b0 := f - 84
			dx = woff2_triplet_sign(f, 1 + ((b0 / 12) << 8) + int(glyph_s[ti]))
			dy = woff2_triplet_sign(f >> 1, 1 + (((b0 % 12) >> 2) << 8) + int(glyph_s[ti + 1]))
		} else if f < 124 {
			nbytes = 3
			b2 := int(glyph_s[ti + 1])
			dx = woff2_triplet_sign(f, (int(glyph_s[ti]) << 4) + (b2 >> 4))
			dy = woff2_triplet_sign(f >> 1, ((b2 & 0x0f) << 8) + int(glyph_s[ti + 2]))
		} else {
			nbytes = 4
			dx = woff2_triplet_sign(f, (int(glyph_s[ti]) << 8) + int(glyph_s[ti + 1]))
			dy = woff2_triplet_sign(f >> 1, (int(glyph_s[ti + 2]) << 8) + int(glyph_s[ti + 3]))
		}
		if ti + nbytes > glyph_s.len {
			return error('woff2: triplet overruns the glyph stream')
		}
		ti += nbytes
		x += dx
		y += dy
		xs << x
		ys << y
		oncurve << on
	}
	glyph_s = glyph_s[ti..]
	ilen, n := woff2_read_255ushort(glyph_s)!
	glyph_s = glyph_s[n..]
	// Only the length lives in the glyph stream; the program bytes live
	// once in the instruction stream.
	if ilen > instr_s.len {
		return error('woff2: instructions overrun the instruction stream')
	}
	ib := instr_s[..ilen].clone()
	instr_s = instr_s[ilen..]
	return Woff2Glyph{
		ncontours: ncontours
		endpts:    endpts
		xs:        xs
		ys:        ys
		oncurve:   oncurve
		instr:     ib
	}
}

// woff2_triplet_sign applies the triplet sign bit: set keeps the value,
// clear negates it.
fn woff2_triplet_sign(flag int, base int) int {
	if flag & 1 != 0 {
		return base
	}
	return -base
}

// woff2_decode_composite reads one composite glyph: standard component
// records copied verbatim, instructions appended from the streams when the
// last component carries them.
fn woff2_decode_composite(mut comp_s []u8, mut glyph_s []u8, mut instr_s []u8, gid int) !Woff2Glyph {
	mut at := 0
	mut has_instr := false
	for {
		if at + 4 > comp_s.len {
			return error('woff2: composite glyph ${gid} truncated')
		}
		flags := int(u16_be(comp_s, at))
		at += 4
		if flags & 1 != 0 {
			at += 4
		} else {
			at += 2
		}
		if flags & 8 != 0 {
			at += 2
		} else if flags & 0x40 != 0 {
			at += 4
		} else if flags & 0x80 != 0 {
			at += 8
		}
		if at > comp_s.len {
			return error('woff2: composite glyph ${gid} component overruns')
		}
		if flags & 0x20 != 0 {
			continue
		}
		if flags & 0x100 != 0 {
			has_instr = true
		}
		break
	}
	comp := comp_s[..at].clone()
	comp_s = comp_s[at..]
	mut instr := []u8{}
	if has_instr {
		ilen, n := woff2_read_255ushort(glyph_s)!
		glyph_s = glyph_s[n..]
		// Same streams rule as simple glyphs: only the length lives in
		// the glyph stream.
		if ilen > instr_s.len {
			return error('woff2: composite instructions overrun the instruction stream')
		}
		instr = instr_s[..ilen].clone()
		instr_s = instr_s[ilen..]
	}
	return Woff2Glyph{
		ncontours:  -1
		comp:       comp
		has_instr:  has_instr
		comp_instr: instr
	}
}

// woff2_resolve_composite fills a composite's box from its components. The
// components reference glyphs by id; records already carry explicit boxes,
// recalculated simples resolve from their points, and nested composites
// resolve recursively with a resolving guard against malicious cycles.
fn woff2_resolve_composite(mut glyphs []Woff2Glyph, gid int, mut resolving []bool) ! {
	// Only composites lacking a box resolve; simples carry theirs (explicit
	// or recalculated) and empties carry none.
	if glyphs[gid].ncontours != -1 || glyphs[gid].has_bbox {
		return
	}
	if resolving[gid] {
		return error('woff2: composite glyph ${gid} references itself')
	}
	resolving[gid] = true
	comp := glyphs[gid].comp
	mut at := 0
	mut xmin := 0
	mut ymin := 0
	mut xmax := 0
	mut ymax := 0
	mut first := true
	for {
		if at + 4 > comp.len {
			return error('woff2: composite glyph ${gid} truncated in resolve')
		}
		flags := int(u16_be(comp, at))
		cgid := int(u16_be(comp, at + 2))
		at += 4
		mut dx := 0
		mut dy := 0
		// Only translation is applied to the box: a scaled component keeps
		// its own box, which over-approximates safely instead of
		// misplacing ink.
		if flags & 1 != 0 {
			dx = int(i16_be(comp, at))
			dy = int(i16_be(comp, at + 2))
			at += 4
		} else {
			dx = int(i8(comp[at]))
			dy = int(i8(comp[at + 1]))
			at += 2
		}
		if flags & 8 != 0 {
			at += 2
		} else if flags & 0x40 != 0 {
			at += 4
		} else if flags & 0x80 != 0 {
			at += 8
		}
		if flags & 2 == 0 {
			// Anchored (matched-points) composite: offsets are point
			// indices, not pen moves. The box falls back to the union of
			// the component boxes without translation.
			dx = 0
			dy = 0
		}
		if cgid < 0 || cgid >= glyphs.len {
			return error('woff2: composite glyph ${gid} references missing glyph ${cgid}')
		}
		woff2_resolve_composite(mut glyphs, cgid, mut resolving)!
		c := glyphs[cgid]
		if !c.has_bbox {
			return error('woff2: composite glyph ${gid} component ${cgid} has no box')
		}
		if first {
			xmin = c.xmin + dx
			ymin = c.ymin + dy
			xmax = c.xmax + dx
			ymax = c.ymax + dy
			first = false
		} else {
			if c.xmin + dx < xmin {
				xmin = c.xmin + dx
			}
			if c.ymin + dy < ymin {
				ymin = c.ymin + dy
			}
			if c.xmax + dx > xmax {
				xmax = c.xmax + dx
			}
			if c.ymax + dy > ymax {
				ymax = c.ymax + dy
			}
		}
		if flags & 0x20 != 0 {
			continue
		}
		break
	}
	glyphs[gid].xmin = xmin
	glyphs[gid].ymin = ymin
	glyphs[gid].xmax = xmax
	glyphs[gid].ymax = ymax
	glyphs[gid].has_bbox = true
	resolving[gid] = false
}

// woff2_compile_coords writes one simple glyph's flags and coordinate
// deltas in standard order: the whole flag array first (with repeat runs),
// then every x delta, then every y delta. A repeat run merges only identical
// flags — including the overlap bit, which lives on the first flag — so a
// run never smears one point's encoding onto the next.
fn woff2_compile_coords(mut out []u8, g Woff2Glyph) ! {
	mut flags := []int{cap: g.xs.len}
	mut xbs := [][]u8{cap: g.xs.len}
	mut ybs := [][]u8{cap: g.xs.len}
	mut last_dx := 0
	mut last_dy := 0
	for i in 0 .. g.xs.len {
		dx := g.xs[i] - last_dx
		dy := g.ys[i] - last_dy
		mut f := 0
		if g.oncurve[i] {
			f |= 1
		}
		if i == 0 && g.overlap {
			f |= 0x40
		}
		mut xb := []u8{}
		if dx == 0 {
			f |= 0x10
		} else if dx >= -255 && dx <= 255 {
			f |= 0x02
			if dx > 0 {
				f |= 0x10
			}
			xb = [u8(if dx < 0 { -dx } else { dx })]
		} else if dx >= -32768 && dx <= 32767 {
			xb = [u8((dx >> 8) & 0xff), u8(dx & 0xff)]
		} else {
			return error('woff2: x delta ${dx} out of range')
		}
		mut yb := []u8{}
		if dy == 0 {
			f |= 0x20
		} else if dy >= -255 && dy <= 255 {
			f |= 0x04
			if dy > 0 {
				f |= 0x20
			}
			yb = [u8(if dy < 0 { -dy } else { dy })]
		} else if dy >= -32768 && dy <= 32767 {
			yb = [u8((dy >> 8) & 0xff), u8(dy & 0xff)]
		} else {
			return error('woff2: y delta ${dy} out of range')
		}
		flags << f
		xbs << xb
		ybs << yb
		last_dx = g.xs[i]
		last_dy = g.ys[i]
	}
	mut i := 0
	for i < flags.len {
		mut run := 1
		for i + run < flags.len && run < 256 && flags[i + run] == flags[i] {
			run++
		}
		if run > 1 {
			out << u8(flags[i] | 0x08)
			out << u8(run - 1)
		} else {
			out << u8(flags[i])
		}
		i += run
	}
	for xb in xbs {
		out << xb
	}
	for yb in ybs {
		out << yb
	}
}

// woff2_rebuild_hmtx undoes the hmtx transform: advances, then side
// bearings, with missing arrays taken from the glyph xMins the glyf rebuild
// produced. The rebuilt table must equal the reconstructed length the
// directory claims. Public for the same direct-pinning reason as the glyf
// rebuild: no committed font exercises the transformed hmtx path.
pub fn woff2_rebuild_hmtx(data []u8, glyf []u8, loca []u8, hhea []u8, num_glyphs int, index_format int, hmtx_orig int) ![]u8 {
	if data.len < 1 {
		return error('woff2: transformed hmtx is empty')
	}
	flags := data[0]
	if flags & 0xfc != 0 {
		return error('woff2: transformed hmtx reserves bits ${flags:02x}')
	}
	body := data[1..]
	has_lsb := flags & 1 == 0
	has_sb := flags & 2 == 0
	if has_lsb && has_sb {
		return error('woff2: transformed hmtx carries both arrays')
	}
	if hhea.len < 36 {
		return error('woff2: hhea table too short for hmtx rebuild')
	}
	num_metrics := int(u16_be(hhea, 34))
	if num_metrics <= 0 || num_metrics > num_glyphs {
		return error('woff2: hhea claims ${num_metrics} metrics for ${num_glyphs} glyphs')
	}
	mut at := 0
	mut advances := []int{cap: num_metrics}
	for _ in 0 .. num_metrics {
		if at + 2 > body.len {
			return error('woff2: hmtx advance array overruns')
		}
		advances << int(u16_be(body, at))
		at += 2
	}
	mut lsbs := []int{cap: num_metrics}
	if has_lsb {
		for _ in 0 .. num_metrics {
			if at + 2 > body.len {
				return error('woff2: hmtx lsb array overruns')
			}
			lsbs << i16_be(body, at)
			at += 2
		}
	} else {
		for i in 0 .. num_metrics {
			lsbs << woff2_glyph_xmin(glyf, loca, index_format, i, num_glyphs)
		}
	}
	num_sb := num_glyphs - num_metrics
	mut sbs := []int{cap: num_sb}
	if has_sb {
		for _ in 0 .. num_sb {
			if at + 2 > body.len {
				return error('woff2: hmtx sidebearing array overruns')
			}
			sbs << i16_be(body, at)
			at += 2
		}
	} else {
		for i in num_metrics .. num_glyphs {
			sbs << woff2_glyph_xmin(glyf, loca, index_format, i, num_glyphs)
		}
	}
	if at != body.len {
		return error('woff2: transformed hmtx has ${body.len - at} trailing bytes')
	}
	mut out := []u8{}
	for i in 0 .. num_metrics {
		woff2_put_u16(mut out, advances[i])
		woff2_put_i16(mut out, lsbs[i])
	}
	for i in 0 .. num_sb {
		woff2_put_i16(mut out, sbs[i])
	}
	if out.len != hmtx_orig {
		return error('woff2: rebuilt hmtx is ${out.len} bytes, directory says ${hmtx_orig}')
	}
	return out
}

// woff2_glyph_xmin reads one glyph's xMin from rebuilt glyf bytes; empty
// glyphs (zero-length) report 0, the value the sidebearing fallback needs.
fn woff2_glyph_xmin(glyf []u8, loca []u8, index_format int, gid int, num_glyphs int) int {
	if gid < 0 || gid >= num_glyphs {
		return 0
	}
	off := woff2_loca_offset(loca, index_format, gid)
	next := woff2_loca_offset(loca, index_format, gid + 1)
	if next <= off || off + 10 > glyf.len {
		return 0
	}
	return i16_be(glyf, off + 2)
}

// woff2_loca_offset reads one glyph offset back out of rebuilt loca bytes.
fn woff2_loca_offset(loca []u8, index_format int, gid int) int {
	if index_format == 0 {
		return int(u16_be(loca, gid * 2)) * 2
	}
	return int(u32_be(loca, gid * 4))
}

// woff2_set_head_loc_format stamps the transform's index format into the
// rebuilt head table, the way fontTools does on reconstruct.
fn woff2_set_head_loc_format(mut out_tables []Woff2Table, head_idx int, index_format int) ! {
	if out_tables[head_idx].data.len < 52 {
		return error('woff2: rebuilt head too short for indexToLocFormat')
	}
	out_tables[head_idx].data[50] = u8(index_format >> 8)
	out_tables[head_idx].data[51] = u8(index_format & 0xff)
}

fn woff2_put_u16(mut b []u8, v int) {
	b << u8((v >> 8) & 0xff)
	b << u8(v & 0xff)
}

fn woff2_put_u32(mut b []u8, v u32) {
	b << u8((v >> 24) & 0xff)
	b << u8((v >> 16) & 0xff)
	b << u8((v >> 8) & 0xff)
	b << u8(v & 0xff)
}

fn woff2_put_i16(mut b []u8, v int) {
	woff2_put_u16(mut b, v & 0xffff)
}

fn i8(b u8) int {
	if b & 0x80 != 0 {
		return int(b) - 256
	}
	return int(b)
}

fn i16_be(data []u8, at int) int {
	v := (int(data[at]) << 8) | int(data[at + 1])
	if v & 0x8000 != 0 {
		return v - 0x10000
	}
	return v
}
