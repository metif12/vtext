module font

// Sfnt is a parsed sfnt container: the table directory of one font, which may
// be the first member of a TrueType collection.
pub struct Sfnt {
pub mut:
	data []u8
	// base is the byte offset of this font inside data. It is 0 for a plain
	// font and non-zero for the n-th member of a 'ttcf' collection.
	base int
	// sfnt_version is the raw 4-byte tag: 0x00010000 for glyf outlines, 'OTTO'
	// for CFF outlines, 'true' for the classic Apple variant.
	sfnt_version u32
	tables       map[string]TableRecord
}

// TableRecord locates one table inside an Sfnt.
pub struct TableRecord {
pub:
	offset int
	length int
}

pub const sfnt_version_truetype = u32(0x00010000)

pub const tag_glyf = 'glyf'
pub const tag_loca = 'loca'
pub const tag_cmap = 'cmap'
pub const tag_head = 'head'
pub const tag_hhea = 'hhea'
pub const tag_hmtx = 'hmtx'
pub const tag_maxp = 'maxp'
pub const tag_name = 'name'
pub const tag_post = 'post'
pub const tag_os2 = 'OS/2'
pub const tag_gdef = 'GDEF'
pub const tag_gsub = 'GSUB'
pub const tag_gpos = 'GPOS'
pub const tag_base = 'BASE'
pub const tag_kern = 'kern'
pub const tag_cvar = 'cvar'
pub const tag_fvar = 'fvar'
pub const tag_gvar = 'gvar'
pub const tag_hvar = 'HVAR'
pub const tag_mvar = 'MVAR'
pub const tag_avar = 'avar'
pub const tag_stat = 'STAT'
pub const tag_colr = 'COLR'
pub const tag_cpal = 'CPAL'
pub const tag_sbix = 'sbix'
pub const tag_cbdt = 'CBDT'
pub const tag_svg = 'SVG '

// parse_sfnt parses the table directory of the first font in data.
pub fn parse_sfnt(data []u8) !Sfnt {
	if data.len < 12 {
		return error('sfnt: file too short (${data.len} bytes)')
	}
	if tag_from_bytes(data, 0) == 'ttcf' {
		// A collection: use its first member.
		if data.len < 16 {
			return error('sfnt: truncated ttc header')
		}
		first := int(u32_be(data, 12))
		return parse_sfnt_at(data, first)
	}
	return parse_sfnt_at(data, 0)
}

// parse_sfnt_at parses the table directory of the font starting at base.
pub fn parse_sfnt_at(data []u8, base int) !Sfnt {
	if base < 0 || base + 12 > data.len {
		return error('sfnt: font offset ${base} out of range')
	}
	version := u32_be(data, base)
	hdr := tag_from_bytes(data, base)
	if version != sfnt_version_truetype && hdr != 'OTTO' && hdr != 'true' {
		return error('sfnt: unrecognised sfnt version 0x${version:08x}')
	}
	num_tables := int(u16_be(data, base + 4))
	// A directory claiming more tables than could possibly fit is corrupt.
	if num_tables > (data.len - base - 12) / 16 {
		return error('sfnt: implausible table count ${num_tables}')
	}
	mut sfnt := Sfnt{
		data:         data
		base:         base
		sfnt_version: version
		tables:       map[string]TableRecord{}
	}
	for i in 0 .. num_tables {
		rec := base + 12 + i * 16
		entry := tag_from_bytes(data, rec)
		off := int(u32_be(data, rec + 8))
		mut length := int(u32_be(data, rec + 12))
		if off < 0 || length < 0 || off > data.len {
			continue
		}
		// Some fonts round the last table's length up past the file end.
		length = imin(length, data.len - off)
		sfnt.tables[entry] = TableRecord{
			offset: off
			length: length
		}
	}
	if sfnt.tables.len == 0 {
		return error('sfnt: no tables found')
	}
	return sfnt
}

// has reports whether the font carries the named table.
pub fn (s &Sfnt) has(tag string) bool {
	return tag in s.tables
}

// record returns the directory entry for a table, or none when it is absent.
// Map indexing would hand back a zero TableRecord, which would silently look
// like a real table sitting at offset 0.
pub fn (s &Sfnt) record(tag string) ?TableRecord {
	if tag !in s.tables {
		return none
	}
	return s.tables[tag]
}

// table_data returns the bytes of the named table, or an empty slice.
pub fn (s &Sfnt) table_data(tag string) []u8 {
	rec := s.record(tag) or { return []u8{} }
	return s.data[rec.offset..imin(rec.offset + rec.length, s.data.len)]
}

// table_reader returns a Reader positioned at the start of the named table.
pub fn (s &Sfnt) table_reader(tag string) ?Reader {
	rec := s.record(tag) or { return none }
	return new_reader(s.data[rec.offset..imin(rec.offset + rec.length, s.data.len)])
}

// has_magic_at reports whether the 4 bytes at off equal the big-endian value.
pub fn (s &Sfnt) has_magic_at(off int, magic u32) bool {
	return new_reader(s.data).u32_at(off) == magic
}

// has_glyf_outlines reports whether the font stores TrueType 'glyf' outlines.
// When false the font uses CFF ('OTTO') outlines, which the rasteriser handles
// but the outline-level APIs do not.
pub fn (s &Sfnt) has_glyf_outlines() bool {
	return s.has(tag_glyf) && s.has(tag_loca)
}

// is_cff reports whether the font uses CFF outlines.
pub fn (s &Sfnt) is_cff() bool {
	return tag_from_bytes(s.data, s.base) == 'OTTO'
}
