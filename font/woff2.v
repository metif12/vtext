module font

import harfara.brotli

// WOFF2 containers.
//
// A WOFF2 file ('wOF2', 0x774F4632) holds one sfnt font as a 48-byte header,
// a table directory with UIntBase128 lengths, and a single brotli stream
// holding every table back to back (glyf and loca possibly transformed).
// Unwrapping brotli-decodes the stream, undoes the transforms, and rebuilds
// a plain sfnt — same version, same tables, same table bytes — which the
// existing sfnt reader then parses, so a WOFF2 font and the TTF it was
// converted from load identically.
//
// WOFF2 metadata and private blocks are skipped: they carry author and
// licence descriptions, not shaping data, and nothing in the engine reads
// them.
//
// The brotli decoder is pure V (`harfara.brotli`, vendored from V's
// `x/compress/brotli` with the streaming callback and the prefix-table leak
// fix): no C code, no C library. WOFF2 *write* is refused — no encoder lives
// in this tree.
pub const woff2_max_table_bytes = 64 << 20

// woff2_known_tags is the WOFF2 fixed tag table, index 0-62; flags byte
// 0x3F means the 4 tag bytes follow literally.
const woff2_known_tags = ['cmap', 'head', 'hhea', 'hmtx', 'maxp', 'name', 'OS/2', 'post', 'cvt ',
	'fpgm', 'glyf', 'loca', 'prep', 'CFF ', 'VORG', 'EBDT', 'EBLC', 'gasp', 'hdmx', 'kern', 'LTSH',
	'PCLT', 'VDMX', 'vhea', 'vmtx', 'BASE', 'GDEF', 'GPOS', 'GSUB', 'EBSC', 'JSTF', 'MATH', 'CBDT',
	'CBLC', 'COLR', 'CPAL', 'SVG ', 'sbix', 'acnt', 'avar', 'bdat', 'bloc', 'bsln', 'cvar', 'fdsc',
	'feat', 'fmtx', 'fvar', 'gvar', 'hsty', 'just', 'lcar', 'mort', 'morx', 'opbd', 'prop', 'trak',
	'Zapf', 'Silf', 'Glat', 'Gloc', 'Feat', 'Sill']

// Woff2Table is one unwrapped WOFF2 table: its directory name, the transform
// it carries, the inflated length the directory claims, and the bytes, kept
// together so the rebuild cannot mix up two tables' lengths.
struct Woff2Table {
	tag string
	// raw is the 4 tag bytes verbatim, for the rebuilt directory.
	raw []u8
	// trans is the WOFF2 transform version: 0 transformed (glyf/loca) or 1
	// (hmtx), 3 null (glyf/loca passed through), 0 null (everything else).
	trans int
	// orig_len is the reconstructed table length the directory claims; for a
	// null transform it equals the stream length. The rebuilt bytes must
	// match it exactly.
	orig_len int
	// dst_len is the stream length: the transform length for a transformed
	// table, the reconstructed length otherwise. The brotli stream splits at
	// these lengths.
	dst_len int
mut:
	data []u8
}

// woff2_read_base128 reads one UIntBase128 value (1-5 bytes, big-endian
// base-128, shortest encoding only) and returns the value plus the bytes
// consumed. Leading-zero and overlong forms are corrupt input, not numbers:
// fontTools refuses them and so does this.
fn woff2_read_base128(data []u8) !(int, int) {
	if data.len == 0 {
		return error('woff2: truncated UIntBase128')
	}
	if data[0] == 0x80 {
		return error('woff2: UIntBase128 must not start with leading zeros')
	}
	mut result := u64(0)
	for i in 0 .. 5 {
		if i >= data.len {
			return error('woff2: truncated UIntBase128')
		}
		code := data[i]
		if result & 0xfe000000 != 0 {
			return error('woff2: UIntBase128 value exceeds 32 bits')
		}
		result = (result << 7) | u64(code & 0x7f)
		if code & 0x80 == 0 {
			return int(result), i + 1
		}
	}
	return error('woff2: UIntBase128 sequence longer than 5 bytes')
}

// woff2_read_255ushort reads one 255UInt16 (the glyf point-count form) and
// returns the value plus the bytes consumed.
fn woff2_read_255ushort(data []u8) !(int, int) {
	if data.len == 0 {
		return error('woff2: truncated 255UInt16')
	}
	code := data[0]
	if code == 253 {
		if data.len < 3 {
			return error('woff2: truncated 255UInt16')
		}
		return (int(data[1]) << 8) | int(data[2]), 3
	} else if code == 254 {
		if data.len < 2 {
			return error('woff2: truncated 255UInt16')
		}
		return int(data[1]) + 506, 2
	} else if code == 255 {
		if data.len < 2 {
			return error('woff2: truncated 255UInt16')
		}
		return int(data[1]) + 253, 2
	}
	return int(code), 1
}

// woff2_to_sfnt rebuilds the plain sfnt a WOFF2 file wraps. Every length in
// the header and directory is checked against the file before it is trusted;
// the brotli stream is capped at the total the directory claims, so a
// decompression bomb errors instead of allocating; and every inflated table
// is checked against the length the directory claims, so corrupt input
// errors rather than building a font out of the wrong bytes.
pub fn woff2_to_sfnt(data []u8) ![]u8 {
	if !is_woff2(data) {
		return error('woff2: not a WOFF2 container')
	}
	if data.len < 48 {
		return error('woff2: truncated header (${data.len} bytes, need 48)')
	}
	flavor := u32_be(data, 4)
	flavor_tag := tag_from_bytes(data, 4)
	if flavor != sfnt_version_truetype && flavor_tag != 'OTTO' && flavor_tag != 'true' {
		return error('woff2: unrecognised sfnt flavor 0x${flavor:08x}')
	}
	total_len := int(u32_be(data, 8))
	if total_len != data.len {
		return error('woff2: header length ${total_len} disagrees with file size ${data.len}')
	}
	num_tables := int(u16_be(data, 12))
	if num_tables <= 0 || num_tables > 4095 {
		return error('woff2: implausible table count ${num_tables}')
	}
	// totalSFNTSize (bytes 16..20) describes the rebuilt file, not the
	// stream, so the directory sum is checked against totalCompressedSize
	// below instead; nothing here trusts it.
	total_compressed := u64(u32_be(data, 20))
	if data[14] != 0 || data[15] != 0 {
		return error('woff2: reserved header bytes are not zero')
	}
	mut at := 48
	mut tables := []Woff2Table{cap: num_tables}
	mut total_dst := u64(0)
	for i in 0 .. num_tables {
		if at >= data.len {
			return error('woff2: truncated table directory at entry ${i}')
		}
		flags := data[at]
		at++
		tag_idx := int(flags & 0x3f)
		trans := int(flags >> 6)
		mut tag := ''
		mut raw := []u8{}
		if tag_idx == 0x3f {
			if at + 4 > data.len {
				return error('woff2: truncated custom tag at entry ${i}')
			}
			raw = data[at..at + 4].clone()
			tag = tag_from_bytes(data, at)
			at += 4
		} else {
			if tag_idx >= woff2_known_tags.len {
				return error('woff2: unknown tag index ${tag_idx} at entry ${i}')
			}
			tag = woff2_known_tags[tag_idx]
			raw = tag.bytes()
		}
		orig_len, n1 := woff2_read_base128(data[at..])!
		at += n1
		mut dst_len := u64(orig_len)
		if tag == 'glyf' || tag == 'loca' {
			if trans != 0 && trans != 3 {
				return error('woff2: table ${tag} carries transform ${trans}, want 0 (transformed) or 3 (null)')
			}
			if trans == 0 {
				tlen, n2 := woff2_read_base128(data[at..])!
				at += n2
				dst_len = u64(tlen)
			}
		} else if tag == 'hmtx' {
			if trans != 0 && trans != 1 {
				return error('woff2: table hmtx carries transform ${trans}, want 0 (null) or 1')
			}
		} else if trans != 0 {
			return error('woff2: table ${tag} carries transform ${trans}, want 0 (null)')
		}
		if dst_len > woff_max_table_bytes {
			return error('woff2: table ${tag} claims ${dst_len} inflated bytes, over the limit')
		}
		if tag == 'loca' && trans == 0 && dst_len != 0 {
			return error('woff2: transformed loca must have transform length 0')
		}
		total_dst += dst_len
		tables << Woff2Table{
			tag:      tag
			raw:      raw
			trans:    trans
			orig_len: orig_len
			dst_len:  int(dst_len)
		}
	}
	if total_dst > woff_max_table_bytes {
		return error('woff2: total inflated size ${total_dst} over the limit')
	}
	// total_compressed is only the stream length; the directory sum is the
	// *decompressed* size, checked against the inflated output below.
	// The brotli stream runs from the directory end; meta/private blocks ride
	// after it and are skipped, bounds-checked.
	stream_off := at
	if total_compressed > u64(data.len) - u64(stream_off) {
		return error('woff2: brotli stream overruns the file')
	}
	stream_end := stream_off + int(total_compressed)
	meta_off := int(u32_be(data, 32))
	meta_len := int(u32_be(data, 36))
	priv_off := int(u32_be(data, 40))
	priv_len := int(u32_be(data, 44))
	if meta_len != 0 && (meta_off < stream_end || meta_len < 0 || meta_off > data.len - meta_len) {
		return error('woff2: meta block overruns the file')
	}
	if priv_len != 0 && (priv_off < stream_end || priv_len < 0 || priv_off > data.len - priv_len) {
		return error('woff2: priv block overruns the file')
	}
	inflated := woff2_inflate(data[stream_off..stream_end], total_dst)!
	if u64(inflated.len) != total_dst {
		return error('woff2: inflated ${inflated.len} bytes, directory says ${total_dst}')
	}
	// Split the stream back into tables at the inflated lengths.
	mut cursor := 0
	mut out_tables := []Woff2Table{cap: num_tables}
	for t in tables {
		if cursor + t.dst_len > inflated.len {
			return error('woff2: table ${t.tag} overruns the inflated stream')
		}
		out_tables << Woff2Table{
			tag:      t.tag
			raw:      t.raw.clone()
			trans:    t.trans
			orig_len: t.orig_len
			dst_len:  t.dst_len
			data:     inflated[cursor..cursor + t.dst_len].clone()
		}
		cursor += t.dst_len
	}
	// Undo the transforms. glyf first: loca and hmtx both read it.
	mut glyf_idx := -1
	mut loca_idx := -1
	mut hmtx_idx := -1
	mut head_idx := -1
	for i, t in out_tables {
		if t.tag == 'glyf' {
			glyf_idx = i
		} else if t.tag == 'loca' {
			loca_idx = i
		} else if t.tag == 'hmtx' {
			hmtx_idx = i
		} else if t.tag == 'head' {
			head_idx = i
		}
	}
	if glyf_idx >= 0 && out_tables[glyf_idx].trans == 0 {
		if loca_idx < 0 || hmtx_idx < 0 || head_idx < 0 {
			return error('woff2: transformed glyf needs loca, hmtx and head tables')
		}
		glyf, loca, index_format := woff2_rebuild_glyf_loca(out_tables[glyf_idx].data, out_tables[loca_idx].orig_len)!
		out_tables[glyf_idx].data = glyf
		out_tables[loca_idx].data = loca
		num_glyphs := int(u16_be(glyf, 4))
		mut hhea_idx := -1
		for i, t in out_tables {
			if t.tag == 'hhea' {
				hhea_idx = i
			}
		}
		if out_tables[hmtx_idx].trans == 1 {
			if hhea_idx < 0 {
				return error('woff2: transformed hmtx without hhea')
			}
			out_tables[hmtx_idx].data = woff2_rebuild_hmtx(out_tables[hmtx_idx].data, glyf, loca, out_tables[hhea_idx].data, num_glyphs, index_format, out_tables[hmtx_idx].orig_len)!
		}
		woff2_set_head_loc_format(mut out_tables, head_idx, index_format)!
	} else if hmtx_idx >= 0 && out_tables[hmtx_idx].trans == 1 {
		return error('woff2: transformed hmtx without transformed glyf')
	}
	// The rebuilt directory: same search parameters as the WOFF1 rebuild.
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
	mut cursor2 := 12 + 16 * num_tables
	for i, t in out_tables {
		for cursor2 % 4 != 0 {
			cursor2++
		}
		offsets[i] = cursor2
		cursor2 += t.data.len
	}
	mut out := []u8{cap: cursor2}
	woff_append_u32(mut out, flavor)
	woff_append_u16(mut out, u16(num_tables))
	woff_append_u16(mut out, u16(search_range))
	woff_append_u16(mut out, u16(entry_selector))
	woff_append_u16(mut out, u16(range_shift))
	for i, t in out_tables {
		for k in 0 .. 4 {
			out << t.raw[k]
		}
		if t.tag == 'head' {
			woff_append_u32(mut out, woff_head_dir_checksum(t.data))
		} else {
			woff_append_u32(mut out, woff_checksum(t.data))
		}
		woff_append_u32(mut out, u32(offsets[i]))
		woff_append_u32(mut out, u32(t.data.len))
	}
	for i, t in out_tables {
		for out.len < offsets[i] {
			out << u8(0)
		}
		out << t.data
	}
	// Reuse the WOFF1 head adjustment: the rebuild moves every table, so the
	// original file's value cannot survive.
	mut compat := []WoffTable{cap: num_tables}
	for t in out_tables {
		compat << WoffTable{
			tag:  t.tag
			raw:  t.raw
			data: t.data
		}
	}
	woff_fix_head_adjustment(mut out, compat, offsets)
	return out
}

// woff2_inflate brotli-decodes one stream, capped at cap+1 bytes: anything
// past the cap is a decompression bomb, refused instead of allocated. The
// cap counts whole 32 KiB callback chunks, so a valid stream whose size the
// directory states exactly decodes untouched; an overshooting one stops at
// the first chunk past the cap and the shortfall below fails the length
// check at the call site.
fn woff2_inflate(data []u8, cap u64) ![]u8 {
	if data.len == 0 {
		return error('woff2: empty brotli stream')
	}
	mut out := []u8{}
	mut ref := &out
	brotli.decompress_with_callback(data, fn [cap] (chunk []u8, ref &[]u8) int {
		unsafe {
			if u64(ref.len) + u64(chunk.len) > cap + 1 {
				return 0
			}
			*ref << chunk
			return chunk.len
		}
	}, ref)!
	return out
}
