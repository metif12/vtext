module font

import compress.zlib

// WOFF1 containers.
//
// A WOFF1 file ('wOFF', 0x774F4646) is one sfnt font with each table stored
// raw or zlib-compressed. Unwrapping it rebuilds a plain sfnt — same version,
// same tables, same table bytes — which the existing sfnt reader then parses,
// so a WOFF1 font and the TTF it was converted from load identically.
//
// WOFF metadata and private blocks are skipped: they carry author and licence
// descriptions, not shaping data, and nothing in the engine reads them.
//
// WOFF2 ('wOF2') is refused, not read: it compresses tables with brotli and
// no brotli decoder lives in this tree.
pub const woff_signature = u32(0x774F4646)
pub const woff2_signature = u32(0x774F4632)

// woff_max_table_bytes bounds one inflated table. The largest real tables are
// a few megabytes of glyf; anything past 64 MB is a corrupt origLength or a
// decompression bomb, and refusing it beats trying to hold it.
const woff_max_table_bytes = 64 << 20

// WoffTable is one unwrapped WOFF table: its directory bytes and its inflated
// data, kept together so the rebuild cannot mix up two tables' lengths.
struct WoffTable {
	tag string
	// raw is the 4 tag bytes verbatim. The display tag substitutes '.' for
	// anything unprintable, so it cannot be written back into the directory.
	raw  []u8
	off  int
	clen int
	data []u8
}

// is_woff reports whether data starts with the WOFF1 magic.
pub fn is_woff(data []u8) bool {
	return data.len >= 4 && u32_be(data, 0) == woff_signature
}

// is_woff2 reports whether data starts with the WOFF2 magic. It is a refusal
// predicate: when it is true, woff_to_sfnt errors with the reason.
pub fn is_woff2(data []u8) bool {
	return data.len >= 4 && u32_be(data, 0) == woff2_signature
}

// maybe_woff_to_sfnt unwraps data when it is a WOFF container and returns it
// unchanged otherwise, so the load path calls one function and plain sfnt
// bytes never pay for a copy.
pub fn maybe_woff_to_sfnt(data []u8) ![]u8 {
	if is_woff(data) || is_woff2(data) {
		return woff_to_sfnt(data)
	}
	return data
}

// woff_to_sfnt rebuilds the plain sfnt a WOFF1 file wraps: a 12-byte header,
// a 16-byte directory entry per table, and the inflated tables 4-byte
// aligned. Every length in the WOFF header is checked against the file before
// it is trusted, and every inflated table is checked against the origLength
// the header claims, so corrupt input errors rather than building a font out
// of the wrong bytes.
pub fn woff_to_sfnt(data []u8) ![]u8 {
	if is_woff2(data) {
		return error('woff: WOFF2 (wOF2) is not supported: it compresses tables with brotli and no brotli decoder lives in this tree')
	}
	if !is_woff(data) {
		return error('woff: not a WOFF container')
	}
	if data.len < 44 {
		return error('woff: truncated header (${data.len} bytes, need 44)')
	}
	flavor := u32_be(data, 4)
	flavor_tag := tag_from_bytes(data, 4)
	if flavor != sfnt_version_truetype && flavor_tag != 'OTTO' && flavor_tag != 'true' {
		return error('woff: unrecognised sfnt flavor 0x${flavor:08x}')
	}
	num_tables := int(u16_be(data, 12))
	// The bound is arithmetic, not aesthetic: searchRange is max_pow * 16 in a
	// u16, which stops fitting at 4096 tables, and no real font carries more
	// than a few dozen. A directory claiming more is corrupt.
	if num_tables <= 0 || num_tables > 4095 {
		return error('woff: implausible table count ${num_tables}')
	}
	dir_end := 44 + 20 * num_tables
	if dir_end > data.len {
		return error('woff: truncated table directory (need ${dir_end} bytes, have ${data.len})')
	}
	mut tables := []WoffTable{cap: num_tables}
	for i in 0 .. num_tables {
		at := 44 + i * 20
		tag := tag_from_bytes(data, at)
		comp_off := u64(u32_be(data, at + 4))
		comp_len := u64(u32_be(data, at + 8))
		orig_len := u64(u32_be(data, at + 12))
		// The origChecksum beside these fields is not reused: checksums are
		// recomputed on rebuild from the bytes actually inflated.
		if comp_len > u64(data.len) || comp_off > u64(data.len) - comp_len {
			return error('woff: table ${i} (${tag}) overruns the file (offset ${comp_off}, length ${comp_len}, file ${data.len} bytes)')
		}
		if orig_len > u64(woff_max_table_bytes) {
			return error('woff: table ${i} (${tag}) claims ${orig_len} inflated bytes, over the ${woff_max_table_bytes} limit')
		}
		co := int(comp_off)
		cl := int(comp_len)
		for prev in tables {
			if co < prev.off + prev.clen && prev.off < co + cl {
				return error('woff: table ${i} (${tag}) overlaps table (${prev.tag})')
			}
		}
		comp := data[co..co + cl]
		mut inflated := comp.clone()
		if cl != int(orig_len) {
			inflated = zlib.decompress(comp) or {
				return error('woff: table ${i} (${tag}) failed to inflate: ${err}')
			}
		}
		if u64(inflated.len) != orig_len {
			return error('woff: table ${i} (${tag}) inflated to ${inflated.len} bytes, header says ${orig_len}')
		}
		tables << WoffTable{
			tag:  tag
			raw:  data[at..at + 4].clone()
			off:  co
			clen: cl
			data: inflated.clone()
		}
	}
	// The sfnt search parameters over the rebuilt directory.
	mut max_pow := 1
	for max_pow * 2 <= num_tables {
		max_pow *= 2
	}
	mut entry_selector := 0
	mut p := max_pow
	for p > 1 {
		p /= 2
		entry_selector++
	}
	search_range := max_pow * 16
	range_shift := num_tables * 16 - search_range
	mut offsets := []int{len: num_tables}
	mut cursor := 12 + 16 * num_tables
	for i, t in tables {
		for cursor % 4 != 0 {
			cursor++
		}
		offsets[i] = cursor
		cursor += t.data.len
	}
	mut out := []u8{cap: cursor}
	woff_append_u32(mut out, flavor)
	woff_append_u16(mut out, u16(num_tables))
	woff_append_u16(mut out, u16(search_range))
	woff_append_u16(mut out, u16(entry_selector))
	woff_append_u16(mut out, u16(range_shift))
	for i, t in tables {
		for k in 0 .. 4 {
			out << t.raw[k]
		}
		woff_append_u32(mut out, woff_checksum(t.data))
		woff_append_u32(mut out, u32(offsets[i]))
		woff_append_u32(mut out, u32(t.data.len))
	}
	for i, t in tables {
		for out.len < offsets[i] {
			out << u8(0)
		}
		out << t.data
	}
	woff_fix_head_adjustment(mut out, tables, offsets)
	return out
}

// woff_head_adjustment_magic is the sfnt spec constant the whole file must sum to.
const woff_head_adjustment_magic = u32(0xB1B0AFBA)

// woff_fix_head_adjustment rewrites the head table's checkSumAdjustment for the
// rebuilt file. The adjustment binds every byte of the file — it is
// 0xB1B0AFBA minus the sum of all other words — and the rebuild moves every
// table, so the original file's value cannot survive: copying it verbatim
// produces a file no checksum-verifying reader accepts. fontTools recalculates
// it on de-woffing for the same reason, and so does this. A table too short to
// hold the field is left alone. Nothing in this engine reads the value.
fn woff_fix_head_adjustment(mut out []u8, tables []WoffTable, offsets []int) {
	for i, t in tables {
		if t.tag != 'head' || t.data.len < 12 {
			continue
		}
		at := offsets[i] + 8
		for k in 0 .. 4 {
			out[at + k] = 0
		}
		mut sum := u64(0)
		mut j := 0
		for j + 4 <= out.len {
			sum += (u64(out[j]) << 24) | (u64(out[j + 1]) << 16) | (u64(out[j + 2]) << 8) | u64(out[j + 3])
			j += 4
		}
		if j < out.len {
			mut last := u64(0)
			mut shift := u64(24)
			for j < out.len {
				last |= u64(out[j]) << shift
				shift -= 8
				j++
			}
			sum += last
		}
		adj := woff_head_adjustment_magic - u32(sum & 0xffffffff)
		out[at] = u8(adj >> 24)
		out[at + 1] = u8((adj >> 16) & 0xff)
		out[at + 2] = u8((adj >> 8) & 0xff)
		out[at + 3] = u8(adj & 0xff)
	}
}

// woff_append_u16 writes v big-endian.
fn woff_append_u16(mut b []u8, v u16) {
	b << u8(v >> 8)
	b << u8(v & 0xff)
}

// woff_append_u32 writes v big-endian.
fn woff_append_u32(mut b []u8, v u32) {
	b << u8(v >> 24)
	b << u8((v >> 16) & 0xff)
	b << u8((v >> 8) & 0xff)
	b << u8(v & 0xff)
}

// woff_checksum is the sfnt table checksum: the sum of big-endian u32 words,
// the tail padded with zeros to a full word. The sum runs in u64 and is cut
// to 32 bits at the end rather than relying on wraparound.
fn woff_checksum(data []u8) u32 {
	mut sum := u64(0)
	mut i := 0
	for i + 4 <= data.len {
		sum += (u64(data[i]) << 24) | (u64(data[i + 1]) << 16) | (u64(data[i + 2]) << 8) | u64(data[i + 3])
		i += 4
	}
	if i < data.len {
		mut last := u64(0)
		mut shift := u64(24)
		for i < data.len {
			last |= u64(data[i]) << shift
			shift -= 8
			i++
		}
		sum += last
	}
	return u32(sum & 0xffffffff)
}
