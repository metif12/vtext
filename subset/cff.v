module subset

import harfara.font
import harfara.shape

// CFF subsetting, standalone: a read is not a rebuild.
//
// font/cff.v reads CharStrings for inspection and verification, but a read
// is not a rebuild. This file rebuilds the CFF table around a kept-gid
// closure: a new CharStrings INDEX that keeps every kept glyph's bytes
// verbatim and replaces every dropped glyph with a single endchar, a new
// format-0 charset carrying the original SIDs, a new Top DICT with the new
// charset/CharStrings/Private offsets, and the Private and subr INDEXes
// carried through with their bytes intact.
//
// Glyph ids are preserved, the way the glyf rebuild preserves them: the
// CharStrings INDEX keeps an entry per glyph the font declares, so every id
// in cmap, hmtx, GSUB, GPOS and GDEF still addresses the glyph it addressed.
// The price is the same as the glyf rebuild's: tables that name dropped
// glyphs keep naming them, and the saving is the outline data rather than
// the whole file.
//
// CFF2 is refused with its name in the message. No committed face carries
// CFF2, so a rebuild verified only against matching tables would prove
// nothing — the fixture-matches-reader failure the corpus rule exists to
// prevent — and the subsetter refuses rather than writing an unverified
// table. CID-keyed CFF is refused the same way font/cff.v refuses it: its
// CharStrings are FD-indexed, not GID-indexed, so reading one as a GID
// would hand back the wrong glyph.

// subset_cff_font keeps the seed glyphs and everything they need, and
// rebuilds the font around them for a CFF-outlined face.
//
// .notdef is always kept, for the same reason subset_font keeps it: a
// character the font does not cover draws as it.
//
// The closure is GSUB plus MATH until neither changes anything, the same
// fixpoint subset_font runs. There is no glyf pass here because a CFF face
// has no glyf table: composites are Type 2 charstrings, not component
// records, and their sharing runs through subrs the rebuild carries.
pub fn subset_cff_font(f &shape.Font, seed []u16) !Subset {
	if f.has_table('CFF2') || f.outlines() == 'CFF2' {
		return error('cff subset: CFF2 outlines are not supported (no committed face carries CFF2 to verify a rebuild against)')
	}
	if !f.has_table('CFF ') {
		return error('cff subset: the font has no CFF table')
	}
	data := f.data()
	spans := spans_of(f)
	gsub := spans['GSUB'] or { Span{} }
	mut keep := []bool{len: f.num_glyphs()}
	for gid in seed {
		if int(gid) < keep.len {
			keep[gid] = true
		}
	}
	keep[0] = true
	mut closure := Closure{}
	mut passes := 0
	for {
		a := count_true(keep)
		close_over_gsub(mut keep, data, gsub, mut closure)
		close_over_math(mut keep, data, spans['MATH'] or { Span{} }, mut closure)
		passes++
		if count_true(keep) == a {
			break
		}
		if passes > 16 {
			eprintln('warning: the CFF glyph closure did not settle in 16 passes, stopped early')
			break
		}
	}
	built := cff_build_sfnt(f, data, keep) or { return err }
	return Subset{
		bytes:   built.bytes
		sizes:   built.sizes
		keep:    keep
		closure: closure
	}
}

// subset_cff_with_keep rebuilds the font around an explicit keep mask.
//
// This is the break-fix half of the API: subset_cff_font computes the
// closure, and this rebuilds whatever mask it is handed — including one with
// a closure entry dropped — so the test can prove a dropped entry fails the
// outline comparison rather than silently drawing. .notdef is not forced
// here; the caller owns the mask outright.
pub fn subset_cff_with_keep(f &shape.Font, keep []bool) !Subset {
	if f.has_table('CFF2') || f.outlines() == 'CFF2' {
		return error('cff subset: CFF2 outlines are not supported (no committed face carries CFF2 to verify a rebuild against)')
	}
	if !f.has_table('CFF ') {
		return error('cff subset: the font has no CFF table')
	}
	if keep.len != f.num_glyphs() {
		return error('cff subset: keep holds ${keep.len} flags for ${f.num_glyphs()} glyphs')
	}
	data := f.data()
	built := cff_build_sfnt(f, data, keep) or { return err }
	return Subset{
		bytes:   built.bytes
		sizes:   built.sizes
		keep:    keep.clone()
		closure: Closure{}
	}
}

// ---------------------------------------------------------------- building

// cff_build_sfnt assembles the subset sfnt around a rebuilt CFF table.
//
// Every table but CFF is copied byte for byte: ids are preserved, so cmap,
// hmtx, GSUB, GPOS and GDEF still address the glyph they addressed. The
// head checksum is zeroed for the sum and patched back at the end, the way
// the glyf rebuild does it. The output is a plain OTTO font.
fn cff_build_sfnt(f &shape.Font, d []u8, keep []bool) !Subset {
	spans := spans_of(f)
	cspan := spans['CFF '] or { return error('cff subset: the font has no CFF table') }
	ctable := d[cspan.offset..imin(cspan.offset + cspan.length, d.len)]
	new_cff := cff_rebuild_table(ctable, keep) or { return err }
	mut tables := []OutTable{cap: spans.len}
	for tag, span in spans {
		if tag == 'CFF ' {
			continue
		}
		raw := d[span.offset..imin(span.offset + span.length, d.len)]
		if tag == 'head' {
			mut bytes := raw.clone()
			for i in 8 .. 12 {
				bytes[i] = u8(0)
			}
			tables << OutTable{
				tag:   tag
				bytes: bytes
			}
			continue
		}
		tables << OutTable{
			tag:   tag
			bytes: raw
		}
	}
	tables << OutTable{
		tag:   'CFF '
		bytes: new_cff
	}
	tables.sort(a.tag < b.tag)
	num := tables.len
	mut power := 1
	mut exponent := 0
	for power * 2 <= num {
		power *= 2
		exponent++
	}
	search_range := power * 16
	range_shift := num * 16 - search_range
	mut out := []u8{cap: d.len}
	out << u8(0x4F)
	out << u8(0x54)
	out << u8(0x54)
	out << u8(0x4F)
	out << u8(num >> 8)
	out << u8(num)
	out << u8(search_range >> 8)
	out << u8(search_range)
	out << u8(exponent >> 8)
	out << u8(exponent)
	out << u8(range_shift >> 8)
	out << u8(range_shift)
	mut offset := 12 + 16 * num
	mut head_at := 0
	mut sizes := map[string]int{}
	for t in tables {
		for ch in t.tag {
			out << u8(ch)
		}
		put32(mut out, int(table_checksum(t.bytes)))
		put32(mut out, offset)
		put32(mut out, t.bytes.len)
		sizes[t.tag] = t.bytes.len
		if t.tag == 'head' {
			head_at = offset
		}
		offset += align_up(t.bytes.len, 4)
	}
	for t in tables {
		for b in t.bytes {
			out << b
		}
		pad := align_up(t.bytes.len, 4) - t.bytes.len
		for _ in 0 .. pad {
			out << u8(0)
		}
	}
	adjust := adjustment_checksum(out)
	out[head_at + 8] = u8((adjust >> 24) & 0xff)
	out[head_at + 9] = u8((adjust >> 16) & 0xff)
	out[head_at + 10] = u8((adjust >> 8) & 0xff)
	out[head_at + 11] = u8(adjust & 0xff)
	return Subset{
		bytes: out
		sizes: sizes
	}
}

// cff_rebuild_table rebuilds one CFF table around keep.
//
// Kept CharStrings are carried through byte for byte — including their
// callsubr and callgsubr operands, whose biases are a function of the subr
// counts the rebuild preserves — and dropped ones become a single endchar.
// The subr INDEXes are carried through with their bytes intact for the same
// reason the charstrings are: no operand is rewritten, so no bias can drift.
// What changes are the INDEX wrappers and the offsets that address them:
// a new format-0 charset with the original SIDs, a new CharStrings INDEX,
// and a new Top DICT naming the new offsets.
fn cff_rebuild_table(ctable []u8, keep []bool) ![]u8 {
	cff := font.parse_cff(ctable) or { return err }
	if keep.len != cff.num_charstrings {
		return error('cff subset: keep holds ${keep.len} flags for ${cff.num_charstrings} charstrings')
	}
	hdr_size := int(ctable[2])
	if hdr_size < 4 || hdr_size > ctable.len {
		return error('cff subset: header size ${hdr_size} is outside a ${ctable.len}-byte table')
	}
	mut header := []u8{cap: hdr_size}
	for i in 0 .. hdr_size {
		header << ctable[i]
	}
	// The four leading INDEXes are located sequentially: each starts where
	// the last one ended, which is what makes their verbatim copies place
	// without an offset in any DICT.
	name_at := hdr_size
	_, _, _, name_end := cff_index_info(ctable, name_at) or { return err }
	mut name_block := []u8{cap: name_end - name_at}
	for i in name_at .. name_end {
		name_block << ctable[i]
	}
	top_at := name_end
	top_count, _, _, top_end := cff_index_info(ctable, top_at) or { return err }
	if top_count < 1 {
		return error('cff subset: the Top DICT INDEX is empty')
	}
	top_start, top_stop := cff_index_range(ctable, top_at, 0) or { return err }
	mut top_raw := []u8{cap: top_stop - top_start}
	for i in top_start .. top_stop {
		top_raw << ctable[i]
	}
	str_at := top_end
	_, _, _, str_end := cff_index_info(ctable, str_at) or { return err }
	mut str_block := []u8{cap: str_end - str_at}
	for i in str_at .. str_end {
		str_block << ctable[i]
	}
	glob_at := str_end
	_, _, _, glob_end := cff_index_info(ctable, glob_at) or { return err }
	mut glob_block := []u8{cap: glob_end - glob_at}
	for i in glob_at .. glob_end {
		glob_block << ctable[i]
	}
	// The charset SIDs are expanded to one per gid, then written back as
	// format 0: gid 0 is .notdef and implicit, every other gid names its
	// original SID in order.
	sids := cff_charset_sids(ctable, cff.charset_at, cff.num_charstrings) or { return err }
	new_charset := cff_build_charset0(sids)
	// Kept bytes verbatim, dropped as one endchar: a charstring with no
	// width and no ops, which the reader accepts as an empty outline.
	mut entries := [][]u8{cap: cff.num_charstrings}
	for gid in 0 .. cff.num_charstrings {
		if keep[gid] {
			raw := cff.charstring_raw(gid) or { return err }
			entries << raw.clone()
		} else {
			entries << [u8(14)]
		}
	}
	new_strings := cff_build_index(entries)
	mut priv_block := []u8{cap: cff.private_len}
	for i in 0 .. cff.private_len {
		priv_block << ctable[cff.private_off + i]
	}
	mut local_block := []u8{}
	mut subrs_off := -1
	if cff.local_subrs_at >= 0 {
		subrs_off = cff.local_subrs_at - cff.private_off
		_, _, _, local_end := cff_index_info(ctable, cff.local_subrs_at) or { return err }
		local_block = []u8{cap: local_end - cff.local_subrs_at}
		for i in cff.local_subrs_at .. local_end {
			local_block << ctable[i]
		}
	}
	// The new offsets hang off the new Top size, which hangs off the new
	// offsets when an encoding grows from two bytes to five. All three new
	// offsets stay five-byte DICT numbers on this corpus, so one pass
	// settles; the loop below settles any font whose do not.
	mut top_block := []u8{}
	mut charset_at := 0
	mut strings_at := 0
	mut priv_off := 0
	base_len := header.len + name_block.len + str_block.len + glob_block.len
	for _ in 0 .. 4 {
		top_guess := if top_block.len == 0 { top_end - top_at } else { top_block.len }
		charset_at = base_len + top_guess
		strings_at = charset_at + new_charset.len
		priv_off = strings_at + new_strings.len
		top_entries := cff_parse_top(top_raw) or { return err }
		mut updated := []CffTopEntry{cap: top_entries.len}
		for e in top_entries {
			if e.op == 15 {
				updated << CffTopEntry{
					op:   15
					args: [charset_at]
				}
			} else if e.op == 17 {
				updated << CffTopEntry{
					op:   17
					args: [strings_at]
				}
			} else if e.op == 18 {
				updated << CffTopEntry{
					op:   18
					args: [cff.private_len, priv_off]
				}
			} else {
				updated << e
			}
		}
		top_dict := cff_encode_top(updated)
		candidate := cff_build_index([top_dict])
		if candidate.len == top_guess {
			top_block = candidate.clone()
			break
		}
		top_block = candidate.clone()
	}
	// A fourth pass only runs when the loop above never settled, which is
	// a DICT whose offsets keep pushing the Top size across an encoding
	// boundary. Recompute once more from the last size rather than looping
	// without end.
	if top_block.len == 0 {
		return error('cff subset: the Top DICT rebuild did not settle')
	}
	charset_at = base_len + top_block.len
	strings_at = charset_at + new_charset.len
	priv_off = strings_at + new_strings.len
	// Assemble in file order: the leading INDEXes, then the three blocks
	// the Top DICT addresses, then Private and its subrs.
	mut out := []u8{cap: charset_at + new_charset.len + new_strings.len + priv_block.len + local_block.len + 16}
	for b in header {
		out << b
	}
	for b in name_block {
		out << b
	}
	for b in top_block {
		out << b
	}
	for b in str_block {
		out << b
	}
	for b in glob_block {
		out << b
	}
	for b in new_charset {
		out << b
	}
	for b in new_strings {
		out << b
	}
	for b in priv_block {
		out << b
	}
	// The Local Subrs offset is measured from the start of Private, not
	// from the start of the table, so a Private that does not end where its
	// subrs begin leaves a gap the rebuild preserves with zeros.
	if local_block.len > 0 {
		target := priv_off + subrs_off
		for out.len < target {
			out << u8(0)
		}
		if out.len != target {
			return error('cff subset: the Local Subrs offset ${subrs_off} overlaps the Private dict')
		}
		for b in local_block {
			out << b
		}
	}
	return out
}

// ---------------------------------------------------------------- INDEX

// cff_index_info bounds-checks one INDEX header and answers its count, its
// offSize, where its data starts and where the data ends. An INDEX is a
// count, an offSize, count+1 offsets and then the bytes: the first offset
// is 1-based, so the data starts at base and entry i spans base+off[i]-1 to
// base+off[i+1]-1. A first offset other than 1 is corrupt, not empty.
fn cff_index_info(table []u8, at int) !(int, int, int, int) {
	if at < 0 || at + 2 > table.len {
		return error('cff subset: INDEX header at ${at} is outside a ${table.len}-byte table')
	}
	count := be16(table, at)
	if count == 0 {
		return count, 0, at + 2, at + 2
	}
	if at + 3 > table.len {
		return error('cff subset: INDEX at ${at} is truncated before its offSize')
	}
	off_size := int(table[at + 2])
	if off_size < 1 || off_size > 4 {
		return error('cff subset: INDEX at ${at} has offSize ${off_size}, not 1 to 4')
	}
	base := at + 3 + (count + 1) * off_size
	if base < 0 || base > table.len {
		return error('cff subset: INDEX at ${at} with ${count} entries runs past a ${table.len}-byte table')
	}
	mut first := 0
	for k in 0 .. off_size {
		first = first * 256 + int(table[at + 3 + k])
	}
	if first != 1 {
		return error('cff subset: INDEX at ${at} starts at offset ${first}, not 1')
	}
	last_at := at + 3 + count * off_size
	mut last := 0
	for k in 0 .. off_size {
		last = last * 256 + int(table[last_at + k])
	}
	if last < 1 {
		return error('cff subset: INDEX at ${at} ends at offset ${last}')
	}
	data_end := base + last - 1
	if data_end > table.len {
		return error('cff subset: INDEX at ${at} ends past a ${table.len}-byte table')
	}
	return count, off_size, base, data_end
}

// cff_index_range answers one INDEX entry's byte range.
fn cff_index_range(table []u8, at int, idx int) !(int, int) {
	count, off_size, base, data_end := cff_index_info(table, at) or { return err }
	if idx < 0 || idx >= count {
		return error('cff subset: INDEX at ${at} with ${count} entries has no entry ${idx}')
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
		return error('cff subset: INDEX at ${at} entry ${idx} spans ${a}..${b}')
	}
	start := base + a - 1
	stop := base + b - 1
	if stop > data_end {
		return error('cff subset: INDEX at ${at} entry ${idx} runs past the table')
	}
	return start, stop
}

// cff_build_index packs entries into one INDEX with the smallest offSize
// that holds them.
fn cff_build_index(entries [][]u8) []u8 {
	if entries.len == 0 {
		return [u8(0), u8(0)]
	}
	mut total := 0
	for e in entries {
		total += e.len
	}
	need := total + 1
	mut off_size := 1
	if need > 255 {
		off_size = 2
	}
	if need > 65535 {
		off_size = 3
	}
	if need > 16777215 {
		off_size = 4
	}
	mut out := []u8{cap: 3 + (entries.len + 1) * off_size + total}
	out << u8(entries.len >> 8)
	out << u8(entries.len & 0xff)
	out << u8(off_size)
	mut off := 1
	for e in entries {
		cff_put_offset(mut out, off, off_size)
		off += e.len
	}
	cff_put_offset(mut out, off, off_size)
	for e in entries {
		for b in e {
			out << b
		}
	}
	return out
}

// cff_put_offset writes one INDEX offset big-endian in off_size bytes.
fn cff_put_offset(mut out []u8, v int, off_size int) {
	if off_size == 1 {
		out << u8(v & 0xff)
	} else if off_size == 2 {
		out << u8((v >> 8) & 0xff)
		out << u8(v & 0xff)
	} else if off_size == 3 {
		out << u8((v >> 16) & 0xff)
		out << u8((v >> 8) & 0xff)
		out << u8(v & 0xff)
	} else {
		out << u8((v >> 24) & 0xff)
		out << u8((v >> 16) & 0xff)
		out << u8((v >> 8) & 0xff)
		out << u8(v & 0xff)
	}
}

// ---------------------------------------------------------------- DICT

// CffTopEntry is one Top DICT operator with the numbers that preceded it.
// Single-byte operators keep their byte; escaped ones (12, b) are stored as
// 1200+b.
struct CffTopEntry {
	op   int
	args []int
}

// cff_parse_top reads Top DICT bytes into operator entries. Only integer
// numbers are accepted — this corpus names none other in Top — and a real
// or a reserved operator is a refusal with a reason rather than a guess.
fn cff_parse_top(data []u8) ![]CffTopEntry {
	mut out := []CffTopEntry{}
	mut args := []int{}
	mut i := 0
	for i < data.len {
		b := int(data[i])
		i++
		if b == 12 {
			if i >= data.len {
				return error('cff subset: truncated Top DICT escape operator')
			}
			op := 1200 + int(data[i])
			i++
			out << CffTopEntry{
				op:   op
				args: args
			}
			args = []int{}
		} else if b >= 32 && b <= 246 {
			args << b - 139
		} else if b >= 247 && b <= 250 {
			if i >= data.len {
				return error('cff subset: truncated Top DICT number')
			}
			args << (b - 247) * 256 + int(data[i]) + 108
			i++
		} else if b >= 251 && b <= 254 {
			if i >= data.len {
				return error('cff subset: truncated Top DICT number')
			}
			args << -(b - 251) * 256 - int(data[i]) - 108
			i++
		} else if b == 28 {
			if i + 2 > data.len {
				return error('cff subset: truncated Top DICT number')
			}
			mut v := be16(data, i)
			if v >= 0x8000 {
				v -= 0x10000
			}
			args << v
			i += 2
		} else if b == 29 {
			if i + 4 > data.len {
				return error('cff subset: truncated Top DICT number')
			}
			v64 := be32(data, i)
			mut v := int(v64)
			if v64 >= i64(0x80000000) {
				v = int(v64 - i64(0x100000000))
			}
			args << v
			i += 4
		} else if b == 30 {
			return error('cff subset: a Top DICT real is not supported by this rebuild')
		} else if b <= 21 {
			out << CffTopEntry{
				op:   b
				args: args
			}
			args = []int{}
		} else {
			return error('cff subset: reserved Top DICT operator ${b}')
		}
	}
	return out
}

// cff_encode_top writes operator entries back to DICT bytes.
fn cff_encode_top(entries []CffTopEntry) []u8 {
	mut out := []u8{cap: 64}
	for e in entries {
		for v in e.args {
			for b in cff_encode_dict_int(v) {
				out << b
			}
		}
		if e.op >= 1200 {
			out << u8(12)
			out << u8(e.op - 1200)
		} else {
			out << u8(e.op)
		}
	}
	return out
}

// cff_encode_dict_int writes one DICT integer in the shortest form that
// holds it.
fn cff_encode_dict_int(v int) []u8 {
	if v >= -107 && v <= 107 {
		return [u8(v + 139)]
	}
	if v >= 108 && v <= 1131 {
		w := v - 108
		return [u8((w >> 8) + 247), u8(w & 0xff)]
	}
	if v >= -1131 && v <= -108 {
		w := -v - 108
		return [u8((w >> 8) + 251), u8(w & 0xff)]
	}
	if v >= -32768 && v <= 32767 {
		mut u := v
		if u < 0 {
			u += 65536
		}
		return [u8(28), u8((u >> 8) & 0xff), u8(u & 0xff)]
	}
	mut w := i64(v)
	if w < 0 {
		w += i64(4294967296)
	}
	return [u8(29), u8((w >> 24) & 0xff), u8((w >> 16) & 0xff), u8((w >> 8) & 0xff), u8(w & 0xff)]
}

// ---------------------------------------------------------------- charset

// cff_charset_sids expands a charset to one SID per gid. Gid 0 is .notdef
// and implicit; every other gid names its SID in order.
fn cff_charset_sids(table []u8, at int, n_glyphs int) ![]int {
	if n_glyphs < 1 {
		return error('cff subset: a charset for ${n_glyphs} glyphs')
	}
	mut sids := []int{len: n_glyphs}
	sids[0] = 0
	if n_glyphs == 1 {
		return sids
	}
	if at < 0 || at >= table.len {
		return error('cff subset: charset offset ${at} is outside a ${table.len}-byte table')
	}
	format := int(table[at])
	if format == 0 {
		for gid in 1 .. n_glyphs {
			sids[gid] = be16(table, at + 1 + (gid - 1) * 2)
		}
		return sids
	}
	if format == 1 {
		mut p := at + 1
		mut gid := 1
		for gid < n_glyphs {
			if p + 3 > table.len {
				return error('cff subset: charset format 1 runs past a ${table.len}-byte table')
			}
			first := be16(table, p)
			nleft := int(table[p + 2])
			for k in 0 .. nleft + 1 {
				if gid >= n_glyphs {
					break
				}
				sids[gid] = first + k
				gid++
			}
			p += 3
		}
		return sids
	}
	if format == 2 {
		mut p := at + 1
		mut gid := 1
		for gid < n_glyphs {
			if p + 4 > table.len {
				return error('cff subset: charset format 2 runs past a ${table.len}-byte table')
			}
			first := be16(table, p)
			nleft := be16(table, p + 2)
			for k in 0 .. nleft + 1 {
				if gid >= n_glyphs {
					break
				}
				sids[gid] = first + k
				gid++
			}
			p += 4
		}
		return sids
	}
	return error('cff subset: charset format ${format} is not 0, 1 or 2')
}

// cff_build_charset0 writes a format-0 charset for sids: the format byte
// followed by one SID per gid past .notdef.
fn cff_build_charset0(sids []int) []u8 {
	mut out := []u8{cap: 1 + (sids.len - 1) * 2}
	out << u8(0)
	for gid in 1 .. sids.len {
		out << u8((sids[gid] >> 8) & 0xff)
		out << u8(sids[gid] & 0xff)
	}
	return out
}
