module font

// CFF2 is the compact font format used by variable CFF fonts. It keeps the
// Type 2 charstring language of CFF1 but drops widths and the Name/String
// INDEXes, makes CID/FDArray mandatory, and adds the blend and vsindex
// operators so a charstring can interpolate its operands across variation
// regions. This file is the reader the inspection path needs: the tables the
// interpreter hangs off, and the outline a glyph draws at an instance.
//
// The raster backend lives in font/cff2raster.v: it interprets the same
// outlines and fills them in-tree, because stb_truetype parses CFF1 but not
// CFF2. Refusals here are explicit rather than best-effort wherever a
// structure is not implemented.

// Cff2Fd is one Font DICT of the FDArray: the Private DICT's byte range and
// the Local Subrs INDEX it points at. Offsets are CFF2-relative except the
// Subrs offset, which is relative to the start of the Private DICT. The
// fields are public for the subset rebuild, which carries Private and subr
// bytes verbatim and patches only the offsets that move.
struct Cff2Fd {
pub:
	private_off     int
	private_len     int
	local_subrs_at  int
	local_subrs_cnt int
}

// Cff2 is a parsed 'CFF2' table. All offsets are bounds-checked here so the
// interpreter treats them as proven. The table bytes stay borrowed.
pub struct Cff2 {
pub:
	table            []u8
	num_charstrings  int
	num_global_subrs int
	global_bias      int
	charstrings_at   int
	global_subrs_at  int
	vstore_at        int
	fdarray_at       int
	fdselect_at      int
	fds              []Cff2Fd
	fd_for_gid       []int
	region_counts    []int
	// var_store is the parsed ItemVariationStore the blend operator reads
	// region scalars from; has_var_store is false when the table carries
	// none. It shares the HVAR store shape, parsed by the same reader.
	var_store     HvarVarStore
	has_var_store bool
}

// parse_cff2_from_sfnt reads the CFF2 table of an sfnt, or refuses with CFF2
// in the message when there is no such table.
pub fn parse_cff2_from_sfnt(sfnt &Sfnt) !Cff2 {
	if !sfnt.has(tag_cff2) {
		return error('cff2: the font has no CFF2 table')
	}
	return parse_cff2(sfnt.table_data(tag_cff2))
}

// parse_cff2 parses one 'CFF2' table: the 5-byte header, the raw Top DICT,
// the Global Subrs INDEX, the FDArray and FDSelect, the CharStrings INDEX and
// the ItemVariationStore's region counts. Every offset is checked here.
pub fn parse_cff2(table []u8) !Cff2 {
	if table.len < 7 {
		return error('cff2: the CFF2 table is ${table.len} bytes, shorter than a header')
	}
	if int(table[0]) != 2 {
		return error('cff2: major version ${int(table[0])} is not CFF 2.x')
	}
	hdr_size := int(table[2])
	if hdr_size < 5 || hdr_size > table.len {
		return error('cff2: header size ${hdr_size} is outside a ${table.len}-byte table')
	}
	top_len := int(u16_be(table, 3))
	if top_len < 1 || 5 + top_len > table.len {
		return error('cff2: Top DICT length ${top_len} is outside a ${table.len}-byte table')
	}
	top := cff_parse_dict(table[5..5 + top_len]) or { return err }

	// CFF2 Top DICT offsets are measured from byte 2 (just after major and
	// minor), not from byte 0. fontTools resolves them the same way; adding
	// the two version bytes here keeps every later check CFF2-relative.
	cs_args := cff_dict_find(top, 17) or { return error('cff2: the Top DICT has no CharStrings offset') }
	charstrings_at := 2 + int(cs_args[0])
	fd_args := cff_dict_find(top, 1236) or { return error('cff2: the Top DICT has no FDArray offset') }
	fdarray_at := 2 + int(fd_args[0])
	vstore_at := if v := cff_dict_find(top, 24) { 2 + int(v[0]) } else { -1 }

	global_at := 5 + top_len
	global_cnt := cff_index_count(table, global_at) or { return err }

	// The global Subrs INDEX ends just before CharStrings in a CFF2 table,
	// but we read its count from the INDEX header rather than assume layout.
	_, _, _, global_end := cff_index_info(table, global_at) or { return err }
	_ = global_end

	if charstrings_at < 0 || charstrings_at >= table.len {
		return error('cff2: CharStrings offset ${charstrings_at} is outside a ${table.len}-byte table')
	}
	cs_count := cff_index_count(table, charstrings_at) or { return err }
	if cs_count < 1 {
		return error('cff2: the CharStrings INDEX is empty')
	}
	if fdarray_at < 0 || fdarray_at >= table.len {
		return error('cff2: FDArray offset ${fdarray_at} is outside a ${table.len}-byte table')
	}
	fd_count := cff_index_count(table, fdarray_at) or { return err }
	if fd_count < 1 {
		return error('cff2: the FDArray INDEX is empty')
	}
	mut fds := []Cff2Fd{cap: fd_count}
	for fdi in 0 .. fd_count {
		s, e := cff_index_range(table, fdarray_at, fdi) or { return err }
		fdict := cff_parse_dict(table[s..e]) or { return err }
		pv := cff_dict_find(fdict, 18) or { return error('cff2: Font DICT ${fdi} has no Private entry') }
		if pv.len != 2 {
			return error('cff2: Font DICT ${fdi} Private names ${pv.len} values, not a size and an offset')
		}
		priv_off := int(pv[1])
		priv_len := int(pv[0])
		if priv_off < 0 || priv_len < 0 || priv_off + priv_len > table.len {
			return error('cff2: Font DICT ${fdi} Private range is outside the table')
		}
		priv := cff_parse_dict(table[priv_off..priv_off + priv_len]) or { return err }
		mut sub_at := -1
		mut sub_cnt := 0
		if sv := cff_dict_find(priv, 19) {
			// CFF2 local subrs offsets are measured from the end of the
			// Private DICT plus the two version bytes of the table.
			sub_at = priv_off + int(sv[0]) + 2
			if sub_at < 0 || sub_at >= table.len {
				return error('cff2: Font DICT ${fdi} Local Subrs offset is outside the table')
			}
			sub_cnt = cff_index_count(table, sub_at) or { return err }
		}
		fds << Cff2Fd{
			private_off:     priv_off
			private_len:     priv_len
			local_subrs_at:  sub_at
			local_subrs_cnt: sub_cnt
		}
	}

	// FDSelect maps gid to FD index. With a single FD the table may omit it,
	// in which case every glyph uses FD 0. Format 0 is one byte per glyph;
	// format 3 is a sorted run of (first, fd) records and a sentinel.
	fdsel_at := if v := cff_dict_find(top, 1237) { 2 + int(v[0]) } else { -1 }
	mut fd_for := []int{len: cs_count, init: 0}
	if fdsel_at >= 0 && fdsel_at < table.len {
		fmt := int(table[fdsel_at])
		if fmt == 0 {
			if fdsel_at + 1 + cs_count > table.len {
				return error('cff2: FDSelect format 0 runs past the table')
			}
			for gid in 0 .. cs_count {
				fd_for[gid] = int(table[fdsel_at + 1 + gid])
			}
		} else if fmt == 3 {
			if fdsel_at + 3 > table.len {
				return error('cff2: FDSelect format 3 header is truncated')
			}
			n_ranges := int(u16_be(table, fdsel_at + 1))
			mut at := fdsel_at + 3
			mut gid := 0
			for r in 0 .. n_ranges {
				if at + 3 > table.len {
					return error('cff2: FDSelect format 3 range is truncated')
				}
				first := int(u16_be(table, at))
				fd := int(table[at + 2])
				last := if r + 1 < n_ranges { int(u16_be(table, at + 3)) } else { cs_count }
				if first > last || last > cs_count {
					return error('cff2: FDSelect format 3 range ${first}..${last} is outside the glyph count')
				}
				for ; gid < last; gid++ {
					fd_for[gid] = fd
				}
				at += 3
			}
		} else {
			return error('cff2: FDSelect format ${fmt} is not supported')
		}
	}
	for gid, fd in fd_for {
		if fd < 0 || fd >= fds.len {
			return error('cff2: glyph ${gid} selects FD ${fd}, outside the FDArray')
		}
	}

	// The VarStore carries the region count per ItemVariationData index;
	// blend needs that count to split its operand stack. The full store is
	// parsed by the shared HVAR reader so non-default instances can evaluate
	// region scalars; a corrupt store refuses the whole table, the same as
	// a corrupt region count would.
	mut region_counts := []int{}
	mut store := HvarVarStore{}
	mut has_store := false
	if vstore_at >= 0 && vstore_at + 8 <= table.len {
		data_count := int(u16_be(table, vstore_at + 6))
		if data_count > 4096 {
			return error('cff2: VarStore declares ${data_count} ItemVariationData entries')
		}
		// The offset array itself must be inside the table: u32_be returns 0
		// out of bounds, which would silently turn a truncated store into a
		// different (wrong) region count instead of a refusal.
		if vstore_at + 8 + data_count * 4 > table.len {
			return error('cff2: VarStore offset array runs past the table')
		}
		for d in 0 .. data_count {
			off := vstore_at + int(u32_be(table, vstore_at + 8 + d * 4))
			if off < 0 || off + 6 > table.len {
				return error('cff2: ItemVariationData ${d} is outside the table')
			}
			region_counts << int(u16_be(table, off + 4))
		}
		// The region counts above are the quick split blend needs; the store
		// below is the scalars and their regions. Both read the same bytes.
		store = hvar_parse_var_store(table, vstore_at) or { return err }
		has_store = true
	}

	return Cff2{
		table:            table
		num_charstrings:  cs_count
		num_global_subrs: global_cnt
		global_bias:      cff_subr_bias(global_cnt)
		charstrings_at:   charstrings_at
		global_subrs_at:  global_at
		vstore_at:        vstore_at
		fdarray_at:       fdarray_at
		fdselect_at:      fdsel_at
		fds:              fds
		fd_for_gid:       fd_for
		region_counts:    region_counts
		var_store:        store
		has_var_store:    has_store
	}
}

// ---------------------------------------------------------------- interpreter

// Cff2Level is one byte stream being executed: a charstring or a subroutine.
struct Cff2Level {
	data []u8
mut:
	pos   int
	depth int
}

// Cff2Run is the shared drawing state of one CFF2 outline. Unlike CFF1 there
// is no width: hmtx (or HVAR) owns advances. The stack holds 513 values, the
// CFF2 default; blend reads the region count for the current vsindex and the
// scalars from blended, the normalized coordinates the outline instances at.
struct Cff2Run {
	c  &Cff2
	fd Cff2Fd
mut:
	stack   []f64
	ops     []CffOp
	x       f64
	y       f64
	stems   int
	open    bool
	vsindex int
	blended []f64
}

fn (mut st Cff2Run) push(v f64) ! {
	if st.stack.len >= 513 {
		return error('cff2: the charstring stack holds more than 513 numbers')
	}
	st.stack << v
}

fn (mut st Cff2Run) pop() !f64 {
	if st.stack.len == 0 {
		return error('cff2: the charstring stack is empty')
	}
	v := st.stack[st.stack.len - 1]
	st.stack = st.stack[..st.stack.len - 1]
	return v
}

fn (mut st Cff2Run) take_stack() []f64 {
	v := st.stack
	st.stack = []f64{}
	return v
}

fn (mut st Cff2Run) take_stems() ! {
	if st.stack.len == 0 || st.stack.len % 2 != 0 {
		return error('cff2: a stem needs pairs of values')
	}
	st.stems += st.stack.len / 2
	st.stack = []f64{}
}

fn (mut st Cff2Run) move_to(x f64, y f64) {
	st.end_path()
	st.x = x
	st.y = y
	st.open = true
	st.ops << CffOp{ kind: CffOpKind.move_to, pts: [x, y] }
}

fn (mut st Cff2Run) line_to(x f64, y f64) {
	if !st.open {
		st.move_to(0, 0)
	}
	st.x = x
	st.y = y
	st.ops << CffOp{ kind: CffOpKind.line_to, pts: [x, y] }
}

fn (mut st Cff2Run) curve_to(dx1 f64, dy1 f64, dx2 f64, dy2 f64, dx3 f64, dy3 f64) {
	x1 := st.x + dx1
	y1 := st.y + dy1
	x2 := x1 + dx2
	y2 := y1 + dy2
	x3 := x2 + dx3
	y3 := y2 + dy3
	if !st.open {
		st.move_to(0, 0)
	}
	st.x = x3
	st.y = y3
	st.ops << CffOp{ kind: CffOpKind.curve_to, pts: [x1, y1, x2, y2, x3, y3] }
}

fn (mut st Cff2Run) end_path() {
	if st.open {
		st.open = false
		st.ops << CffOp{ kind: CffOpKind.close_path, pts: []f64{} }
	}
}

// vcurve and hcurve consume one alternation of a vhcurveto/hvcurveto run,
// the same four-or-five-value shapes the CFF1 interpreter reads.
fn (mut st Cff2Run) vcurve(args []f64) ![]f64 {
	if args.len < 4 {
		return error('cff2: a vertical curve with ${args.len} values')
	}
	mut dyc := 0.0
	mut rest := args[4..]
	if rest.len == 1 {
		dyc = rest[0]
		rest = []f64{}
	}
	st.curve_to(0, args[0], args[1], args[2], args[3], dyc)
	return rest
}

fn (mut st Cff2Run) hcurve(args []f64) ![]f64 {
	if args.len < 4 {
		return error('cff2: a horizontal curve with ${args.len} values')
	}
	mut dxc := 0.0
	mut rest := args[4..]
	if rest.len == 1 {
		dxc = rest[0]
		rest = []f64{}
	}
	st.curve_to(args[0], 0, args[1], args[2], dxc, args[3])
	return rest
}

// blend consumes n defaults, n*M deltas and the explicit n from the stack.
// Each default keeps its place and gains the scalar-weighted deltas for its
// row: result[i] = default[i] + sum over regions of scalar * delta. The
// scalars evaluate the vsindex data's regions at the outline's normalized
// blend coordinates, the supportScalar product HarfBuzz computes. At the
// default instance every scalar is zero, so the answer is the defaults,
// which already sit on top of the stack in order once the deltas and n are
// dropped. A region index outside the region list contributes nothing, the
// way HarfBuzz reads it, rather than erroring.
fn (mut st Cff2Run) blend() ! {
	n_f := st.pop() or { return err }
	n := int(n_f)
	if n < 1 || f64(n) != n_f {
		return error('cff2: blend has an invalid count ${n_f}')
	}
	if !st.c.has_var_store || st.vsindex < 0 || st.vsindex >= st.c.var_store.datas.len {
		return error('cff2: blend uses vsindex ${st.vsindex} outside the VarStore')
	}
	data := st.c.var_store.datas[st.vsindex]
	m := data.region_indexes.len
	// n was already popped, so the remaining stack must hold n defaults and
	// n*M deltas — n*(M+1) values, not one more.
	need := n * (m + 1)
	if st.stack.len < need {
		return error('cff2: blend needs ${need} values after n, the stack has ${st.stack.len}')
	}
	if st.blended.len != st.c.var_store.axis_count {
		return error('cff2: ${st.blended.len} blend coordinates for ${st.c.var_store.axis_count} store axes')
	}
	base := st.stack.len - need
	for i in 0 .. n {
		mut v := st.stack[base + i]
		for k in 0 .. m {
			ri := data.region_indexes[k]
			if ri < 0 || ri >= st.c.var_store.regions.len {
				continue
			}
			s := hvar_region_scalar(st.c.var_store.regions[ri], st.blended)
			if s == 0.0 {
				continue
			}
			d := st.stack[base + n + i * m + k]
			if d != 0.0 {
				v += s * d
			}
		}
		st.stack[base + i] = v
	}
	st.stack = st.stack[..base + n]
}

// subr_bytes reads one local or global subroutine by its biased index.
fn (st &Cff2Run) subr_bytes(local bool, n int) ![]u8 {
	if local {
		if st.fd.local_subrs_at < 0 || n < 0 || n >= st.fd.local_subrs_cnt {
			return error('cff2: local subr ${n} is outside the FDArray entry')
		}
		s, e := cff_index_range(st.c.table, st.fd.local_subrs_at, n) or { return err }
		return st.c.table[s..e]
	}
	if n < 0 || n >= st.c.num_global_subrs {
		return error('cff2: global subr ${n} is outside the INDEX')
	}
	s, e := cff_index_range(st.c.table, st.c.global_subrs_at, n) or { return err }
	return st.c.table[s..e]
}

fn (mut st Cff2Run) escape(e int) ! {
	if e == 0 {
		return
	}
	if e == 15 {
		v := st.pop() or { return err }
		if v != f64(int(v)) || v < 0 {
			return error('cff2: vsindex ${v} is not a non-negative integer')
		}
		st.vsindex = int(v)
		return
	}
	if e == 16 {
		st.blend() or { return err }
		return
	}
	if e == 34 {
		args := st.take_stack()
		if args.len != 7 {
			return error('cff2: hflex with ${args.len} values, not 7')
		}
		st.curve_to(args[0], 0, args[1], args[2], args[3], 0)
		st.curve_to(args[4], 0, args[5], -args[2], args[6], 0)
		return
	}
	if e == 35 {
		args := st.take_stack()
		if args.len != 13 {
			return error('cff2: flex with ${args.len} values, not 13')
		}
		st.curve_to(args[0], args[1], args[2], args[3], args[4], args[5])
		st.curve_to(args[6], args[7], args[8], args[9], args[10], args[11])
		return
	}
	if e == 36 {
		args := st.take_stack()
		if args.len != 9 {
			return error('cff2: hflex1 with ${args.len} values, not 9')
		}
		st.curve_to(args[0], args[1], args[2], args[3], args[4], 0)
		st.curve_to(args[5], 0, args[6], args[7], args[8], -(args[1] + args[3] + args[7]))
		return
	}
	if e == 37 {
		args := st.take_stack()
		if args.len != 11 {
			return error('cff2: flex1 with ${args.len} values, not 11')
		}
		dx := args[0] + args[2] + args[4] + args[6] + args[8]
		dy := args[1] + args[3] + args[5] + args[7] + args[9]
		mut dx6 := 0.0
		mut dy6 := 0.0
		if fabs(dx) > fabs(dy) {
			dx6 = args[10]
			dy6 = -dy
		} else {
			dx6 = -dx
			dy6 = args[10]
		}
		st.curve_to(args[0], args[1], args[2], args[3], args[4], args[5])
		st.curve_to(args[6], args[7], args[8], args[9], dx6, dy6)
		return
	}
	return error('cff2: unsupported charstring escape operator 12 ${e}')
}

// operator runs one single-byte Type 2 operator and answers whether the
// current byte stream ends here (return or endchar).
fn (mut st Cff2Run) operator(b int, data []u8, mut lv Cff2Level) !bool {
	if b == 15 {
		v := st.pop() or { return err }
		if v != f64(int(v)) || v < 0 {
			return error('cff2: vsindex ${v} is not a non-negative integer')
		}
		st.vsindex = int(v)
		return false
	}
	if b == 16 {
		st.blend() or { return err }
		return false
	}
	if b == 1 || b == 3 || b == 18 || b == 23 {
		st.take_stems() or { return err }
		return false
	}
	if b == 19 || b == 20 {
		st.take_stems() or { return err }
		mask := (st.stems + 7) / 8
		if lv.pos + mask > data.len {
			return error('cff2: a stem mask of ${mask} bytes runs past the charstring end')
		}
		lv.pos += mask
		return false
	}
	if b == 21 {
		args := st.take_stack()
		if args.len != 2 {
			return error('cff2: rmoveto with ${args.len} values, not 2')
		}
		st.move_to(st.x + args[0], st.y + args[1])
		return false
	}
	if b == 22 {
		args := st.take_stack()
		if args.len != 1 {
			return error('cff2: hmoveto with ${args.len} values, not 1')
		}
		st.move_to(st.x + args[0], st.y)
		return false
	}
	if b == 4 {
		args := st.take_stack()
		if args.len != 1 {
			return error('cff2: vmoveto with ${args.len} values, not 1')
		}
		st.move_to(st.x, st.y + args[0])
		return false
	}
	if b == 5 {
		args := st.take_stack()
		if args.len == 0 || args.len % 2 != 0 {
			return error('cff2: rlineto with ${args.len} values')
		}
		for i := 0; i + 2 <= args.len; i += 2 {
			st.line_to(st.x + args[i], st.y + args[i + 1])
		}
		return false
	}
	if b == 6 {
		args := st.take_stack()
		if args.len == 0 {
			return error('cff2: hlineto with no values')
		}
		mut horiz := true
		for v in args {
			if horiz {
				st.line_to(st.x + v, st.y)
			} else {
				st.line_to(st.x, st.y + v)
			}
			horiz = !horiz
		}
		return false
	}
	if b == 7 {
		args := st.take_stack()
		if args.len == 0 {
			return error('cff2: vlineto with no values')
		}
		mut vert := true
		for v in args {
			if vert {
				st.line_to(st.x, st.y + v)
			} else {
				st.line_to(st.x + v, st.y)
			}
			vert = !vert
		}
		return false
	}
	if b == 8 {
		args := st.take_stack()
		if args.len == 0 || args.len % 6 != 0 {
			return error('cff2: rrcurveto with ${args.len} values')
		}
		for i := 0; i + 6 <= args.len; i += 6 {
			st.curve_to(args[i], args[i + 1], args[i + 2], args[i + 3], args[i + 4],
				args[i + 5])
		}
		return false
	}
	if b == 24 {
		args := st.take_stack()
		if args.len < 8 || (args.len - 2) % 6 != 0 {
			return error('cff2: rcurveline with ${args.len} values')
		}
		for i := 0; i + 2 < args.len; i += 6 {
			st.curve_to(args[i], args[i + 1], args[i + 2], args[i + 3], args[i + 4],
				args[i + 5])
		}
		st.line_to(st.x + args[args.len - 2], st.y + args[args.len - 1])
		return false
	}
	if b == 25 {
		args := st.take_stack()
		if args.len < 8 || (args.len - 6) % 2 != 0 {
			return error('cff2: rlinecurve with ${args.len} values')
		}
		for i := 0; i + 6 < args.len; i += 2 {
			st.line_to(st.x + args[i], st.y + args[i + 1])
		}
		n := args.len
		st.curve_to(args[n - 6], args[n - 5], args[n - 4], args[n - 3], args[n - 2],
			args[n - 1])
		return false
	}
	if b == 26 {
		args := st.take_stack()
		if args.len < 4 {
			return error('cff2: vvcurveto with ${args.len} values')
		}
		mut rest := args.clone()
		mut dx1 := 0.0
		if rest.len % 2 == 1 {
			dx1 = rest[0]
			rest = rest[1..]
		}
		if rest.len % 4 != 0 {
			return error('cff2: vvcurveto with ${args.len} values')
		}
		for i := 0; i + 4 <= rest.len; i += 4 {
			st.curve_to(dx1, rest[i], rest[i + 1], rest[i + 2], 0, rest[i + 3])
			dx1 = 0
		}
		return false
	}
	if b == 27 {
		args := st.take_stack()
		if args.len < 4 {
			return error('cff2: hhcurveto with ${args.len} values')
		}
		mut rest := args.clone()
		mut dy1 := 0.0
		if rest.len % 2 == 1 {
			dy1 = rest[0]
			rest = rest[1..]
		}
		if rest.len % 4 != 0 {
			return error('cff2: hhcurveto with ${args.len} values')
		}
		for i := 0; i + 4 <= rest.len; i += 4 {
			st.curve_to(rest[i], dy1, rest[i + 1], rest[i + 2], rest[i + 3], 0)
			dy1 = 0
		}
		return false
	}
	if b == 30 || b == 31 {
		args := st.take_stack()
		if args.len < 4 {
			return error('cff2: alternating curve with ${args.len} values')
		}
		mut rest := args.clone()
		mut vertical := b == 30
		for rest.len > 0 {
			if vertical {
				rest = st.vcurve(rest) or { return err }
			} else {
				rest = st.hcurve(rest) or { return err }
			}
			if rest.len > 0 {
				if vertical {
					rest = st.hcurve(rest) or { return err }
				} else {
					rest = st.vcurve(rest) or { return err }
				}
			}
		}
		return false
	}
	if b == 10 || b == 29 {
		n := st.pop() or { return err }
		if n != f64(int(n)) {
			return error('cff2: a subr number of ${n} is not an integer')
		}
		// The depth lives on the byte stream, not the run: st.depth is never
		// advanced by a subr call, so checking it would let a self-recursive
		// subr nest forever (CFF1 checks lv.depth for the same reason).
		if lv.depth >= 10 {
			return error('cff2: charstring subr calls nest deeper than 10')
		}
		bias := if b == 10 {
			cff_subr_bias(st.fd.local_subrs_cnt)
		} else {
			st.c.global_bias
		}
		bytes := st.subr_bytes(b == 10, int(n) + bias) or { return err }
		mut sub := Cff2Level{ data: bytes, depth: lv.depth + 1 }
		st.exec(mut sub) or { return err }
		return false
	}
	if b == 11 {
		return true
	}
	if b == 14 {
		st.end_path()
		left := st.take_stack()
		if left.len != 0 {
			return error('cff2: endchar with ${left.len} leftover values')
		}
		return true
	}
	return error('cff2: reserved charstring operator ${b}')
}

fn (mut st Cff2Run) exec(mut lv Cff2Level) ! {
	for lv.pos < lv.data.len {
		b := int(lv.data[lv.pos])
		lv.pos++
		if b == 12 {
			if lv.pos >= lv.data.len {
				return error('cff2: truncated charstring escape operator')
			}
			e := int(lv.data[lv.pos])
			lv.pos++
			st.escape(e) or { return err }
			continue
		}
		if b == 28 {
			if lv.pos + 2 > lv.data.len {
				return error('cff2: truncated charstring number')
			}
			mut v := int(u16_be(lv.data, lv.pos))
			if v >= 0x8000 {
				v -= 0x10000
			}
			st.push(f64(v)) or { return err }
			lv.pos += 2
			continue
		}
		if b == 255 {
			if lv.pos + 4 > lv.data.len {
				return error('cff2: truncated charstring number')
			}
			mut v := i64(u32_be(lv.data, lv.pos))
			if v >= i64(0x80000000) {
				v -= i64(0x100000000)
			}
			st.push(f64(v) / 65536.0) or { return err }
			lv.pos += 4
			continue
		}
		if b >= 32 && b <= 246 {
			st.push(f64(b - 139)) or { return err }
			continue
		}
		if b >= 247 && b <= 250 {
			if lv.pos >= lv.data.len {
				return error('cff2: truncated charstring number')
			}
			st.push(f64((b - 247) * 256 + int(lv.data[lv.pos]) + 108)) or { return err }
			lv.pos++
			continue
		}
		if b >= 251 && b <= 254 {
			if lv.pos >= lv.data.len {
				return error('cff2: truncated charstring number')
			}
			st.push(f64(-(b - 251) * 256 - int(lv.data[lv.pos]) - 108)) or { return err }
			lv.pos++
			continue
		}
		stop := st.operator(b, lv.data, mut lv) or { return err }
		if stop {
			return
		}
	}
}

// outline reads one glyph's CharString through its FD and returns the drawn
// path at the default instance: every region scalar is zero, so blend keeps
// the default operands.
pub fn (c &Cff2) outline(gid int) !CffOutline {
	return c.outline_instanced(gid, []f64{len: c.var_store.axis_count})
}

// outline_instanced reads one glyph's CharString through its FD and returns
// the drawn path at blended, the normalized coordinates the outline
// instances at. A length that does not match the store's axis count is a
// caller error; a face that never stored coordinates blends zeros, which is
// the default instance above.
pub fn (c &Cff2) outline_instanced(gid int, blended []f64) !CffOutline {
	if gid < 0 || gid >= c.num_charstrings {
		return error('cff2: glyph ${gid} is outside the CharStrings INDEX')
	}
	fdidx := c.fd_for_gid[gid]
	if fdidx < 0 || fdidx >= c.fds.len {
		return error('cff2: glyph ${gid} selects FD ${fdidx}, outside the FDArray')
	}
	s, e := cff_index_range(c.table, c.charstrings_at, gid) or { return err }
	mut st := Cff2Run{
		c:       c
		fd:      c.fds[fdidx]
		blended: blended
	}
	mut lv := Cff2Level{ data: c.table[s..e] }
	st.exec(mut lv) or { return err }
	st.end_path()
	return CffOutline{ ops: st.ops }
}
