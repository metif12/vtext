module font

// CFF is the Compact Font Format: the PostScript outlines an 'OTTO' font
// carries in its 'CFF ' table, as opposed to the TrueType outlines a glyf
// font carries in glyf and loca.
//
// The rasteriser already draws these fonts — stb_truetype reads CFF itself —
// so this file is not a second rasteriser. It is the reader the rest of the
// library was missing: the header, the Top DICT, the CharStrings INDEX and
// the subroutines, and a Type 2 charstring interpreter that turns a glyph's
// bytes into the same move/line/curve outline the curve path consumes. What
// it is for is inspection and verification: counts beside fontTools, an
// outline per glyph to compare against the decompiler, and a refusal with a
// reason wherever the bytes stop being interpretable.
//
// What it does not do, and says so rather than guessing:
//
//	CID-keyed fonts (ROS, FDArray, FDSelect) — the CharStrings INDEX is not
//	GID-indexed there, so reading it as one would hand back the wrong glyph.
//	CFF2 ('CFF2' table) — a different bytecode with blend operators, refused
//	with its name in the message.
//	Type 1 charstrings (CharstringType 1) — a different operator set.
//	Seac-accented endchar — deprecated when Type 2 was written, absent from
//	the committed font, refused rather than half-built.

// Cff is a parsed 'CFF ' table: the offsets the interpreter needs, already
// bounds-checked, plus the widths the Private DICT declares. The table bytes
// stay borrowed — the face that owns them outlives every outline drawn from
// one — so a Cff never copies the table, only slices it.
pub struct Cff {
pub:
	table []u8
	// num_charstrings is the CharStrings INDEX count. For a non-CID font the
	// INDEX is GID-ordered, so this is also the number of glyphs with bytes.
	num_charstrings  int
	num_global_subrs int
	num_local_subrs  int
	// global_bias and local_bias are added to a callsubr/callgsubr operand
	// to get the real subr INDEX: 107 below 1240 subrs, 1131 below 33900,
	// 32768 above. The bias is a function of the count, not of the caller.
	global_bias int
	local_bias  int
	// The three INDEX offsets below, the charset offset and the Private
	// range are all measured from the start of the table, the way the CFF
	// specification writes them — not from the start of the file, which is
	// where the sfnt offsets point and the easy confusion to make.
	charstrings_at  int
	global_subrs_at int
	local_subrs_at  int
	charset_at      int
	private_off     int
	private_len     int
	// nominal_width and default_width are the Private DICT's nominalWidthX
	// and defaultWidthX. A charstring width is nominal plus its first value;
	// a charstring with no width takes the default. hmtx stays authoritative
	// for advances — this is what the outline consumed, kept so a reader can
	// see it rather than what the pen is moved by.
	nominal_width f64
	default_width f64
}

// CffOpKind is one path command a charstring can draw.
pub enum CffOpKind {
	move_to
	line_to
	curve_to
	close_path
}

// CffOp is one path command with its absolute design-space coordinates:
// move and line carry one point, curve carries three, close carries none.
pub struct CffOp {
pub:
	kind CffOpKind
	pts  []f64
}

// CffOutline is a glyph's drawn path: the ops in order, and the width the
// charstring declared — nominalWidthX plus its first value when it names
// one, defaultWidthX when it does not.
pub struct CffOutline {
pub mut:
	ops       []CffOp
	width     f64
	has_width bool
}

// count_kind counts the ops of one kind, which is what the pins compare:
// a move per contour, lines and curves between, a close per contour.
pub fn (o &CffOutline) count_kind(k CffOpKind) int {
	mut n := 0
	for op in o.ops {
		if op.kind == k {
			n++
		}
	}
	return n
}

// cff_subr_bias answers the subroutine bias for a count of subrs, the
// function the specification fixes: 107 below 1240, 1131 below 33900,
// 32768 above. Both the global and the local bias come from here, each from
// its own count.
pub fn cff_subr_bias(count int) int {
	if count < 1240 {
		return 107
	} else if count < 33900 {
		return 1131
	}
	return 32768
}

// parse_cff_from_sfnt reads the CFF table of an sfnt, or refuses with the
// reason when there is nothing to read: CFF2 names itself, because a CFF2
// font is a real font this reader cannot read rather than a font with no
// outlines at all.
pub fn parse_cff_from_sfnt(sfnt &Sfnt) !Cff {
	if sfnt.has(tag_cff) {
		return parse_cff(sfnt.table_data(tag_cff))
	}
	if sfnt.has(tag_cff2) {
		return error('cff: CFF2 outlines are not supported by this reader (a CFF2 table is present and no CFF table)')
	}
	return error('cff: the font has no CFF table')
}

// parse_cff parses one 'CFF ' table: the header, the Name, Top DICT, String
// and Global Subrs INDEXes, the Top DICT fields that locate the CharStrings,
// the charset and the Private dict, and the Local Subrs INDEX. Every offset
// is bounds-checked here so the interpreter can treat them as proven.
pub fn parse_cff(table []u8) !Cff {
	if table.len < 4 {
		return error('cff: the table is ${table.len} bytes, shorter than a header')
	}
	if int(table[0]) != 1 {
		return error('cff: major version ${int(table[0])} is not CFF 1.x')
	}
	hdr_size := int(table[2])
	if hdr_size < 4 || hdr_size > table.len {
		return error('cff: header size ${hdr_size} is outside a ${table.len}-byte table')
	}
	off_size := int(table[3])
	if off_size < 1 || off_size > 4 {
		return error('cff: header offSize ${off_size} is not 1 to 4')
	}
	// The Name INDEX is one name per font and carries nothing the outlines
	// need, but a table whose first INDEX does not parse is corrupt before
	// anything else is read, so it is validated and skipped.
	mut at := hdr_size
	name_count := cff_index_count(table, at) or { return err }
	if name_count < 1 {
		return error('cff: the Name INDEX names no font')
	}
	_, _, _, name_end := cff_index_info(table, at) or { return err }
	at = name_end
	// The Top DICT INDEX holds one DICT per font. This reader reads the
	// first, which is the only one a non-CID font has; a CID font is
	// refused below, once its ROS names it.
	top_count, _, _, top_end := cff_index_info(table, at) or { return err }
	if top_count < 1 {
		return error('cff: the Top DICT INDEX is empty')
	}
	top_start, top_stop := cff_index_range(table, at, 0) or { return err }
	top := cff_parse_dict(table[top_start..top_stop]) or { return err }
	at = top_end
	// The String INDEX is skipped the same way the Name INDEX is: validated,
	// because a corrupt table should fail here rather than inside a glyph.
	_, _, _, str_end := cff_index_info(table, at) or { return err }
	at = str_end
	global_at := at
	global_count := cff_index_count(table, at) or { return err }
	// The three offsets the outlines hang off. They are CFF-relative —
	// measured from the start of this table — which is the easy confusion
	// with the sfnt offsets, which are file-relative.
	cs_args := cff_dict_find(top, 17) or { return error('cff: the Top DICT has no CharStrings offset') }
	charstrings_at := int(cs_args[0])
	priv_args := cff_dict_find(top, 18) or { return error('cff: the Top DICT has no Private dict') }
	if priv_args.len != 2 {
		return error('cff: the Private entry names ${priv_args.len} values, not a size and an offset')
	}
	private_len := int(priv_args[0])
	private_off := int(priv_args[1])
	charset_args := cff_dict_find(top, 15) or { return error('cff: the Top DICT has no charset offset') }
	charset_at := int(charset_args[0])
	// CharstringType defaults to 2 when the Top DICT does not name one,
	// which is this font's case. A 1 names Type 1 charstrings, a different
	// operator set this interpreter does not implement.
	if tst := cff_dict_find(top, 1206) {
		if int(tst[0]) != 2 {
			return error('cff: CharstringType ${int(tst[0])} charstrings are not supported')
		}
	}
	// ROS, FDArray and FDSelect together name a CID-keyed font, whose
	// CharStrings are FD-indexed rather than GID-indexed. Reading one as a
	// GID would hand back the wrong glyph, so this is a refusal rather than
	// a best effort.
	if _ := cff_dict_find(top, 1230) {
		return error('cff: CID-keyed CFF fonts are not supported (ROS present)')
	}
	if _ := cff_dict_find(top, 1236) {
		return error('cff: CID-keyed CFF fonts are not supported (FDArray present)')
	}
	if _ := cff_dict_find(top, 1237) {
		return error('cff: CID-keyed CFF fonts are not supported (FDSelect present)')
	}
	if charstrings_at < 0 || charstrings_at >= table.len {
		return error('cff: CharStrings offset ${charstrings_at} is outside a ${table.len}-byte table')
	}
	charstring_count := cff_index_count(table, charstrings_at) or { return err }
	if charstring_count < 1 {
		return error('cff: the CharStrings INDEX is empty')
	}
	if charset_at < 0 || charset_at >= table.len {
		return error('cff: charset offset ${charset_at} is outside a ${table.len}-byte table')
	}
	cff_check_charset(table, charset_at, charstring_count) or { return err }
	if private_off < 0 || private_len < 0 || private_off + private_len > table.len {
		return error('cff: the Private dict at ${private_off}+${private_len} is outside a ${table.len}-byte table')
	}
	priv := cff_parse_dict(table[private_off..private_off + private_len]) or { return err }
	mut nominal := 0.0
	if nval := cff_dict_find(priv, 21) {
		nominal = nval[0]
	}
	mut deflt := nominal
	if dval := cff_dict_find(priv, 20) {
		deflt = dval[0]
	}
	// A Local Subrs INDEX exists only when the Private DICT names one, and
	// its offset is measured from the start of the Private DICT — not from
	// the start of the table, which is where every other offset here is
	// measured from and the one offset in the file that is different.
	mut local_at := -1
	mut local_count := 0
	if sval := cff_dict_find(priv, 19) {
		sub_off := int(sval[0])
		local_at = private_off + sub_off
		if local_at < 0 || local_at >= table.len {
			return error('cff: the Local Subrs offset ${sub_off} (at ${local_at}) is outside a ${table.len}-byte table')
		}
		local_count = cff_index_count(table, local_at) or { return err }
	}
	return Cff{
		table:            table
		num_charstrings:  charstring_count
		num_global_subrs: global_count
		num_local_subrs:  local_count
		global_bias:      cff_subr_bias(global_count)
		local_bias:       cff_subr_bias(local_count)
		charstrings_at:   charstrings_at
		global_subrs_at:  global_at
		local_subrs_at:   local_at
		charset_at:       charset_at
		private_off:      private_off
		private_len:      private_len
		nominal_width:    nominal
		default_width:    deflt
	}
}

// charstring_range answers where a glyph's bytes sit in the table: the
// CharStrings INDEX is GID-ordered in a non-CID font, so glyph id is the
// entry number. A CID font never reaches here — parsing refused it — which
// is what makes the identity true wherever this is called.
pub fn (c &Cff) charstring_range(gid int) !(int, int) {
	if gid < 0 || gid >= c.num_charstrings {
		return error('cff: gid ${gid} is outside 0..${c.num_charstrings}')
	}
	return cff_index_range(c.table, c.charstrings_at, gid)
}

// charstring_raw answers a glyph's raw Type 2 bytes, for the tests that pin
// lengths and corrupt one byte to prove the refusal.
pub fn (c &Cff) charstring_raw(gid int) ![]u8 {
	start, stop := c.charstring_range(gid) or { return err }
	return c.table[start..stop]
}

// global_subr_bytes answers one Global Subrs entry, bounds-checked twice:
// the index against the count, the entry against the table.
fn (c &Cff) global_subr_bytes(idx int) ![]u8 {
	if idx < 0 || idx >= c.num_global_subrs {
		return error('cff: global subr ${idx} is outside 0..${c.num_global_subrs}')
	}
	start, stop := cff_index_range(c.table, c.global_subrs_at, idx) or { return err }
	return c.table[start..stop]
}

// local_subr_bytes answers one Local Subrs entry. A font with no Local Subrs
// INDEX has no callsubr to answer, which is an error in the charstring
// rather than an empty answer here.
fn (c &Cff) local_subr_bytes(idx int) ![]u8 {
	if c.local_subrs_at < 0 {
		return error('cff: the charstring calls a local subr and the font has none')
	}
	if idx < 0 || idx >= c.num_local_subrs {
		return error('cff: local subr ${idx} is outside 0..${c.num_local_subrs}')
	}
	start, stop := cff_index_range(c.table, c.local_subrs_at, idx) or { return err }
	return c.table[start..stop]
}

// outline interprets a glyph's charstring into design-space path ops. The
// numbers are absolute — the interpreter accumulates the relative deltas —
// in the font's own y-up coordinates, the way the decompiler reports them.
pub fn (c &Cff) outline(gid int) !CffOutline {
	raw := c.charstring_raw(gid) or { return err }
	mut st := CffRun{
		nominal:   c.nominal_width
		default_w: c.default_width
	}
	mut lv := CffLevel{
		data: raw
	}
	c.exec(mut st, mut lv) or { return err }
	st.end_path()
	mut width := c.default_width
	if st.got_width {
		width = st.width
	}
	return CffOutline{
		ops:       st.ops
		width:     width
		has_width: st.got_width
	}
}

// ---------------------------------------------------------------- INDEX

// cff_index_info bounds-checks one INDEX header and answers its count, its
// offSize, where its data starts and where the data ends. An INDEX is a
// count, an offSize, count+1 offsets and then the bytes: the first offset
// is 1-based, so the data starts at base and entry i spans base+off[i]-1 to
// base+off[i+1]-1. A first offset other than 1 is corrupt, not empty.
fn cff_index_info(table []u8, at int) !(int, int, int, int) {
	if at < 0 || at + 2 > table.len {
		return error('cff: INDEX header at ${at} is outside a ${table.len}-byte table')
	}
	count := int(u16_be(table, at))
	if count == 0 {
		return count, 0, at + 2, at + 2
	}
	if at + 3 > table.len {
		return error('cff: INDEX at ${at} is truncated before its offSize')
	}
	off_size := int(table[at + 2])
	if off_size < 1 || off_size > 4 {
		return error('cff: INDEX at ${at} has offSize ${off_size}, not 1 to 4')
	}
	base := at + 3 + (count + 1) * off_size
	if base < 0 || base > table.len {
		return error('cff: INDEX at ${at} with ${count} entries runs past a ${table.len}-byte table')
	}
	mut first := 0
	for k in 0 .. off_size {
		first = first * 256 + int(table[at + 3 + k])
	}
	if first != 1 {
		return error('cff: INDEX at ${at} starts at offset ${first}, not 1')
	}
	last_at := at + 3 + count * off_size
	mut last := 0
	for k in 0 .. off_size {
		last = last * 256 + int(table[last_at + k])
	}
	if last < 1 {
		return error('cff: INDEX at ${at} ends at offset ${last}')
	}
	data_end := base + last - 1
	if data_end > table.len {
		return error('cff: INDEX at ${at} ends past a ${table.len}-byte table')
	}
	return count, off_size, base, data_end
}

// cff_index_count answers an INDEX count, which is what the header pins
// compare: charstrings, global subrs, local subrs.
fn cff_index_count(table []u8, at int) !int {
	count, _, _, _ := cff_index_info(table, at) or { return err }
	return count
}

// cff_index_range answers one INDEX entry's byte range, checking the entry
// is ordered and inside the table. The offsets are 1-based and
// non-decreasing; anything else is a corrupt table, not a short glyph.
fn cff_index_range(table []u8, at int, idx int) !(int, int) {
	count, off_size, base, data_end := cff_index_info(table, at) or { return err }
	if idx < 0 || idx >= count {
		return error('cff: INDEX at ${at} with ${count} entries has no entry ${idx}')
	}
	mut a := 0
	for k in 0 .. off_size {
		a = a * 256 + int(table[at + 3 + idx * off_size + k])
	}
	mut b := 0
	for k in 0 .. off_size {
		b = b * 256 + int(table[at + 3 + (idx + 1) * off_size + k])
	}
	if a < 1 || b < a {
		return error('cff: INDEX at ${at} entry ${idx} spans ${a}..${b}')
	}
	start := base + a - 1
	stop := base + b - 1
	if stop > data_end {
		return error('cff: INDEX at ${at} entry ${idx} runs past the table')
	}
	return start, stop
}

// ---------------------------------------------------------------- DICT

// CffDictEntry is one DICT operator with the numbers that preceded it.
// Single-byte operators keep their byte; escaped ones (12, b) are stored as
// 1200+b, which keeps the two namespaces apart without a second field.
struct CffDictEntry {
	op   int
	args []f64
}

// cff_parse_dict reads DICT bytes into operator entries. The number decoding
// is DICT's own — 28 is a short int, 29 a long int, 30 a nibble real — which
// is not the charstring's: 29 and 30 are operators there, and 255 a number
// here means reserved. Unknown operators are kept with their operands and
// ignored by the lookup, because a DICT reader does not act on what it does
// not know; a charstring reader cannot afford that, and errors instead.
fn cff_parse_dict(data []u8) ![]CffDictEntry {
	mut out := []CffDictEntry{}
	mut args := []f64{}
	mut i := 0
	for i < data.len {
		b := int(data[i])
		i++
		if b == 12 {
			if i >= data.len {
				return error('cff: truncated DICT escape operator')
			}
			op := 1200 + int(data[i])
			i++
			out << CffDictEntry{
				op:   op
				args: args
			}
			args = []f64{}
		} else if b >= 32 && b <= 246 {
			args << f64(b - 139)
		} else if b >= 247 && b <= 250 {
			if i >= data.len {
				return error('cff: truncated DICT number')
			}
			args << f64((b - 247) * 256 + int(data[i]) + 108)
			i++
		} else if b >= 251 && b <= 254 {
			if i >= data.len {
				return error('cff: truncated DICT number')
			}
			args << f64(-(b - 251) * 256 - int(data[i]) - 108)
			i++
		} else if b == 28 {
			if i + 2 > data.len {
				return error('cff: truncated DICT number')
			}
			mut v := int(u16_be(data, i))
			if v >= 0x8000 {
				v -= 0x10000
			}
			args << f64(v)
			i += 2
		} else if b == 29 {
			if i + 4 > data.len {
				return error('cff: truncated DICT number')
			}
			mut v := i64(u32_be(data, i))
			if v >= i64(0x80000000) {
				v -= i64(0x100000000)
			}
			args << f64(v)
			i += 4
		} else if b == 30 {
			v, ni := cff_dict_real(data, i) or { return err }
			args << v
			i = ni
		} else if b <= 27 {
			// CFF2 uses 24 (vstore) and extends the small-operator space in
			// its Private DICTs. A DICT reader keeps unknown operators with
			// their operands rather than guessing, so accepting these harms
			// neither reader: the CFF1 caller only looks up the ops it knows.
			out << CffDictEntry{
				op:   b
				args: args
			}
			args = []f64{}
		} else {
			return error('cff: reserved DICT operator ${b}')
		}
	}
	return out
}

// cff_dict_real decodes one nibble real starting at at, answering the value
// and the offset past it. The digits are decimal with an optional point and
// exponent: 0xa is the point, 0xb E, 0xc E-, 0xe minus, 0xf ends. A 0xd is
// reserved, and a real with no digit is corrupt rather than zero.
fn cff_dict_real(data []u8, at int) !(f64, int) {
	mut s := ''
	mut digits := 0
	mut i := at
	mut done := false
	for !done {
		if i >= data.len {
			return error('cff: truncated DICT real')
		}
		b := int(data[i])
		i++
		for n in 0 .. 2 {
			nib := if n == 0 { (b >> 4) & 0xf } else { b & 0xf }
			if nib <= 9 {
				s += '${nib}'
				digits++
			} else if nib == 0xa {
				s += '.'
			} else if nib == 0xb {
				s += 'E'
			} else if nib == 0xc {
				s += 'E-'
			} else if nib == 0xe {
				s += '-'
			} else if nib == 0xf {
				done = true
				break
			} else {
				return error('cff: reserved nibble 0xd in a DICT real')
			}
		}
	}
	if digits == 0 {
		return error('cff: a DICT real with no digits')
	}
	return s.f64(), i
}

// cff_dict_find answers one operator's operands, or none when the DICT does
// not name it. Absent and empty are told apart by the caller: CharStrings
// with no offset is corrupt, CharstringType with none is the default 2.
fn cff_dict_find(entries []CffDictEntry, op int) ?[]f64 {
	for e in entries {
		if e.op == op {
			return e.args
		}
	}
	return none
}

// ---------------------------------------------------------------- charset

// cff_check_charset walks a charset the way its format says and proves every
// byte it touches is inside the table. The SIDs themselves are not
// interpreted — glyph names are String INDEX lookups the outlines never need
// — but a charset that runs past the table is corrupt, and this is where
// that fails rather than inside a glyph. Format 0 is nGlyphs-1 two-byte
// SIDs; formats 1 and 2 are ranges to the same total.
fn cff_check_charset(table []u8, at int, n_glyphs int) ! {
	if n_glyphs < 1 {
		return error('cff: a charset for ${n_glyphs} glyphs')
	}
	format := int(table[at])
	if format == 0 {
		stop := at + 1 + (n_glyphs - 1) * 2
		if stop > table.len {
			return error('cff: charset format 0 runs past a ${table.len}-byte table')
		}
	} else if format == 1 {
		mut p := at + 1
		mut covered := 1
		for covered < n_glyphs {
			if p + 3 > table.len {
				return error('cff: charset format 1 runs past a ${table.len}-byte table')
			}
			covered += int(table[p + 2]) + 1
			p += 3
		}
	} else if format == 2 {
		mut p := at + 1
		mut covered := 1
		for covered < n_glyphs {
			if p + 4 > table.len {
				return error('cff: charset format 2 runs past a ${table.len}-byte table')
			}
			covered += int(u16_be(table, p + 2)) + 1
			p += 4
		}
	} else {
		return error('cff: charset format ${format} is not 0, 1 or 2')
	}
}

// ---------------------------------------------------------------- charstrings

// CffLevel is one execution level of the interpreter: the bytes being run
// and how far into them it is, plus the subr depth that level sits at. The
// drawing state lives in CffRun and is shared across levels, the way stems,
// the width and the current point survive a callsubr.
struct CffLevel {
	data []u8
mut:
	pos   int
	depth int
}

// CffRun is the shared drawing state of one outline: the operand stack, the
// emitted ops, the current point, the stems declared so far, and the width.
// nominal and default_w are the Private DICT's, read once per glyph.
struct CffRun {
	nominal   f64
	default_w f64
mut:
	stack     []f64
	ops       []CffOp
	x         f64
	y         f64
	stems     int
	got_width bool
	width     f64
	open      bool
}

// exec runs one level's bytes to its end, a return or an endchar. A subr
// call recurses with a fresh level over the subr's bytes and the same run,
// so the caller's bytes continue where the call left them.
fn (c &Cff) exec(mut st CffRun, mut lv CffLevel) ! {
	for lv.pos < lv.data.len {
		b := int(lv.data[lv.pos])
		lv.pos++
		if b == 12 {
			if lv.pos >= lv.data.len {
				return error('cff: truncated charstring escape operator')
			}
			e := int(lv.data[lv.pos])
			lv.pos++
			st.escape(c, e) or { return err }
			continue
		}
		if b == 28 {
			if lv.pos + 2 > lv.data.len {
				return error('cff: truncated charstring number')
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
				return error('cff: truncated charstring number')
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
				return error('cff: truncated charstring number')
			}
			st.push(f64((b - 247) * 256 + int(lv.data[lv.pos]) + 108)) or { return err }
			lv.pos++
			continue
		}
		if b >= 251 && b <= 254 {
			if lv.pos >= lv.data.len {
				return error('cff: truncated charstring number')
			}
			st.push(f64(-(b - 251) * 256 - int(lv.data[lv.pos]) - 108)) or { return err }
			lv.pos++
			continue
		}
		stop := st.operator(c, b, lv.data, mut lv) or { return err }
		if stop {
			return
		}
	}
}

// push adds an operand, refusing past 64. Type 2 allows 48; the margin is
// for a corrupt stack to fail on the limit rather than on the allocator.
fn (mut st CffRun) push(v f64) ! {
	if st.stack.len >= 64 {
		return error('cff: the charstring stack holds more than 64 numbers')
	}
	st.stack << v
}

// pop takes the top operand, or fails when the operator needed more than the
// charstring gave it — the shape of every truncated-glyph refusal.
fn (mut st CffRun) pop() !f64 {
	if st.stack.len == 0 {
		return error('cff: charstring stack underflow')
	}
	v := st.stack[st.stack.len - 1]
	st.stack.delete_last()
	return v
}

// take_stack empties the operand stack into the caller, for the operators
// that consume the whole thing at once.
fn (mut st CffRun) take_stack() []f64 {
	out := st.stack.clone()
	st.stack.clear()
	return out
}

// take_width applies the width rule and answers the remaining operands. An
// even-expected operator (stems, rmoveto, endchar: even_odd 0) with an odd
// count, or an odd-expected one (hmoveto, vmoveto: even_odd 1) with an even
// count, carries the width first: nominalWidthX plus that value. Otherwise
// the width is the default. The rule runs once per glyph — got_width stays
// set across subr calls — because the width belongs to the glyph, not to
// the subroutine that happens to declare it.
fn (mut st CffRun) take_width(even_odd int) ![]f64 {
	mut args := st.take_stack()
	if !st.got_width {
		if even_odd == 0 && args.len % 2 == 1 {
			st.width = st.nominal + args[0]
			st.got_width = true
			args = args[1..]
		} else if even_odd == 1 && args.len % 2 == 0 {
			if args.len == 0 {
				st.width = st.default_w
				st.got_width = true
			} else {
				st.width = st.nominal + args[0]
				st.got_width = true
				args = args[1..]
			}
		} else {
			st.width = st.default_w
			st.got_width = true
		}
	}
	return args
}

// take_stems consumes stem pairs the way every stem operator does, width
// first and then an even run of pairs, and counts them toward the mask size.
fn (mut st CffRun) take_stems() ! {
	args := st.take_width(0) or { return err }
	if args.len % 2 != 0 {
		return error('cff: a stem operator with ${args.len} unpaired values')
	}
	st.stems += args.len / 2
}

// move_to closes the open contour, if any, and starts the next at x/y. A
// moveto always starts a new contour in Type 2 — there is no closepath
// operator — so the close is here rather than in the bytes.
fn (mut st CffRun) move_to(x f64, y f64) {
	st.end_path()
	st.x = x
	st.y = y
	st.open = true
	st.ops << CffOp{
		kind: CffOpKind.move_to
		pts:  [x, y]
	}
}

// line_to draws to x/y, opening at the origin when the charstring never
// moved — invalid per the specification, tolerated the way the reference
// decompiler tolerates it, with the same (0, 0) it would emit.
fn (mut st CffRun) line_to(x f64, y f64) {
	if !st.open {
		st.move_to(0, 0)
	}
	st.x = x
	st.y = y
	st.ops << CffOp{
		kind: CffOpKind.line_to
		pts:  [x, y]
	}
}

// curve_to draws the cubic through the three relative offsets, opening at
// the origin under the same tolerance line_to allows.
fn (mut st CffRun) curve_to(dx1 f64, dy1 f64, dx2 f64, dy2 f64, dx3 f64, dy3 f64) {
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
	st.ops << CffOp{
		kind: CffOpKind.curve_to
		pts:  [x1, y1, x2, y2, x3, y3]
	}
}

// end_path closes the open contour, if any. Contours are closed by position
// — a moveto, an endchar, the end of the bytes — never by an operator, so
// a missing close is a caller that forgot to ask, not a corrupt glyph.
fn (mut st CffRun) end_path() {
	if st.open {
		st.open = false
		st.ops << CffOp{
			kind: CffOpKind.close_path
			pts:  []f64{}
		}
	}
}

// escape runs a two-byte (12, e) operator. Of the whole escaped set only the
// flex family draws and dotsection is ignorable history; the arithmetic and
// storage operators are a different language this reader does not implement,
// and blend with vsindex belong to CFF2 variable charstrings — refused with
// the format's name rather than misread as something else.
fn (mut st CffRun) escape(c &Cff, e int) ! {
	if e == 0 {
		return
	}
	if e == 15 || e == 16 {
		return error('cff: blend and vsindex need CFF2 variable-subroutine support')
	}
	if e == 34 {
		args := st.take_stack()
		if args.len != 7 {
			return error('cff: hflex with ${args.len} values, not 7')
		}
		st.curve_to(args[0], 0, args[1], args[2], args[3], 0)
		st.curve_to(args[4], 0, args[5], -args[2], args[6], 0)
		return
	}
	if e == 35 {
		args := st.take_stack()
		if args.len != 13 {
			return error('cff: flex with ${args.len} values, not 13')
		}
		st.curve_to(args[0], args[1], args[2], args[3], args[4], args[5])
		st.curve_to(args[6], args[7], args[8], args[9], args[10], args[11])
		return
	}
	if e == 36 {
		args := st.take_stack()
		if args.len != 9 {
			return error('cff: hflex1 with ${args.len} values, not 9')
		}
		dy6 := -(args[1] + args[3] + args[7])
		st.curve_to(args[0], args[1], args[2], args[3], args[4], 0)
		st.curve_to(args[5], 0, args[6], args[7], args[8], dy6)
		return
	}
	if e == 37 {
		args := st.take_stack()
		if args.len != 11 {
			return error('cff: flex1 with ${args.len} values, not 11')
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
	return error('cff: unsupported charstring escape operator 12 ${e}')
}

// operator runs one single-byte operator, answering whether the level ends
// here (return, endchar) or continues. Reserved bytes — 0, 2, 9, 13, 17 and
// the rest no operator was ever assigned — fail rather than drawing
// nothing, which is what turns a corrupt charstring into a refusal instead
// of silent garbage.
fn (mut st CffRun) operator(c &Cff, b int, data []u8, mut lv CffLevel) !bool {
	if b == 1 || b == 3 || b == 18 || b == 23 {
		st.take_stems() or { return err }
		return false
	}
	if b == 19 || b == 20 {
		st.take_stems() or { return err }
		// The mask that follows names one bit per stem declared so far.
		// All of this font's stems precede its first mask, which is what
		// makes "so far" and "in total" the same number here; a font that
		// declares stems after a mask would need the running total anyway,
		// so the running total is what is read.
		mask := (st.stems + 7) / 8
		if lv.pos + mask > data.len {
			return error('cff: a stem mask of ${mask} bytes runs past the charstring end')
		}
		lv.pos += mask
		return false
	}
	if b == 21 {
		args := st.take_width(0) or { return err }
		if args.len != 2 {
			return error('cff: rmoveto with ${args.len} values, not 2')
		}
		st.move_to(st.x + args[0], st.y + args[1])
		return false
	}
	if b == 22 {
		args := st.take_width(1) or { return err }
		if args.len != 1 {
			return error('cff: hmoveto with ${args.len} values, not 1')
		}
		st.move_to(st.x + args[0], st.y)
		return false
	}
	if b == 4 {
		args := st.take_width(1) or { return err }
		if args.len != 1 {
			return error('cff: vmoveto with ${args.len} values, not 1')
		}
		st.move_to(st.x, st.y + args[0])
		return false
	}
	if b == 5 {
		args := st.take_stack()
		if args.len == 0 || args.len % 2 != 0 {
			return error('cff: rlineto with ${args.len} values')
		}
		for i := 0; i + 2 <= args.len; i += 2 {
			st.line_to(st.x + args[i], st.y + args[i + 1])
		}
		return false
	}
	if b == 6 {
		args := st.take_stack()
		if args.len == 0 {
			return error('cff: hlineto with no values')
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
			return error('cff: vlineto with no values')
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
			return error('cff: rrcurveto with ${args.len} values')
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
			return error('cff: rcurveline with ${args.len} values')
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
			return error('cff: rlinecurve with ${args.len} values')
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
			return error('cff: vvcurveto with ${args.len} values')
		}
		mut rest := args.clone()
		mut dx1 := 0.0
		if rest.len % 2 == 1 {
			dx1 = rest[0]
			rest = rest[1..]
		}
		if rest.len % 4 != 0 {
			return error('cff: vvcurveto with ${args.len} values')
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
			return error('cff: hhcurveto with ${args.len} values')
		}
		mut rest := args.clone()
		mut dy1 := 0.0
		if rest.len % 2 == 1 {
			dy1 = rest[0]
			rest = rest[1..]
		}
		if rest.len % 4 != 0 {
			return error('cff: hhcurveto with ${args.len} values')
		}
		for i := 0; i + 4 <= rest.len; i += 4 {
			st.curve_to(rest[i], dy1, rest[i + 1], rest[i + 2], rest[i + 3], 0)
			dy1 = 0
		}
		return false
	}
	if b == 30 {
		args := st.take_stack()
		if args.len < 4 {
			return error('cff: vhcurveto with ${args.len} values')
		}
		mut rest := args.clone()
		for rest.len > 0 {
			rest = st.vcurve(rest) or { return err }
			if rest.len > 0 {
				rest = st.hcurve(rest) or { return err }
			}
		}
		return false
	}
	if b == 31 {
		args := st.take_stack()
		if args.len < 4 {
			return error('cff: hvcurveto with ${args.len} values')
		}
		mut rest := args.clone()
		for rest.len > 0 {
			rest = st.hcurve(rest) or { return err }
			if rest.len > 0 {
				rest = st.vcurve(rest) or { return err }
			}
		}
		return false
	}
	if b == 10 || b == 29 {
		n := st.pop() or { return err }
		if n != f64(int(n)) {
			return error('cff: a subr number of ${n} is not an integer')
		}
		if lv.depth >= 10 {
			return error('cff: charstring subr calls nest deeper than 10')
		}
		if b == 10 {
			bytes := c.local_subr_bytes(int(n) + c.local_bias) or { return err }
			mut sub := CffLevel{
				data:  bytes
				depth: lv.depth + 1
			}
			c.exec(mut st, mut sub) or { return err }
		} else {
			bytes := c.global_subr_bytes(int(n) + c.global_bias) or { return err }
			mut sub := CffLevel{
				data:  bytes
				depth: lv.depth + 1
			}
			c.exec(mut st, mut sub) or { return err }
		}
		return false
	}
	if b == 11 {
		// A return ends the subroutine it is in; the caller continues past
		// the call. Falling off the end of a subr does the same, so this
		// and the loop bound are one behaviour written twice.
		return true
	}
	if b == 14 {
		st.end_path()
		args := st.take_width(0) or { return err }
		if args.len == 4 {
			// Seac builds an accented glyph out of two components. Type 2
			// deprecated it, this font has none, and composing one would
			// need a charset lookup the outline does not do — refused.
			return error('cff: seac-accented endchar is not supported')
		}
		if args.len != 0 {
			return error('cff: endchar with ${args.len} leftover values')
		}
		return true
	}
	if b == 15 || b == 16 {
		return error('cff: vsindex and blend need CFF2 variable-subroutine support')
	}
	return error('cff: reserved charstring operator ${b}')
}

// vcurve consumes one vertical curve of a vhcurveto/hvcurveto run: four
// values, plus a fifth when it is the last one in the run. What is left is
// answered back, so the caller alternates until nothing remains.
fn (mut st CffRun) vcurve(args []f64) ![]f64 {
	if args.len < 4 {
		return error('cff: a vertical curve with ${args.len} values')
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

// hcurve consumes one horizontal curve of a vhcurveto/hvcurveto run, the
// mirror of vcurve with the free value on x instead of y.
fn (mut st CffRun) hcurve(args []f64) ![]f64 {
	if args.len < 4 {
		return error('cff: a horizontal curve with ${args.len} values')
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

// fabs is the float absolute value, written out because this file otherwise
// needs no imports and the one call site does not justify one.
fn fabs(v f64) f64 {
	if v < 0 {
		return -v
	}
	return v
}
