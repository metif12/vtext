module font

// Builder assembles a new sfnt font from in-memory tables: the 14.2 core
// that every table writer (head, maxp, hhea, hmtx, cmap in 14.2b-d) builds
// on. The caller supplies each table's bytes under its tag and build lays
// the file out; nothing is read from an existing font.
//
// The layout follows the SUBSET precedent (subset/subset.v build_font, shared
// with subset/cff.v and subset/cff2.v via assemble_sfnt_around), not the
// textfont stored-layout mode: tags are sorted, the search fields are
// recomputed from the table count, bodies are 4-aligned with zero padding,
// per-table checksums are recomputed, and head.checkSumAdjustment is patched
// so the whole file sums to 0xB1B0AFBA. A stored layout would reproduce one
// font's packing; a builder canonicalises, the way the subset rebuilds do,
// so two builders fed the same tables emit the same bytes.
//
// The head discipline is the subset one: checkSumAdjustment is zeroed while
// the head table's own checksum is taken, and patched back once the file is
// laid out. A missing head or one shorter than 12 bytes is an error rather
// than a zero checksum, because a file without a place for the adjustment
// cannot be made self-consistent.
//
// A tag must be exactly 4 text bytes (0x20..0x7e, so `CFF ` keeps its
// space); anything else is refused at set time, the way textfont_load
// refuses a non-text tag. Setting a tag twice replaces the first bytes:
// the builder holds one body per tag, and build emits each once.

// Builder holds one body per table tag plus the sfnt version for the
// header. The zero value is not usable: new_builder names the version.
pub struct Builder {
mut:
	version u32
	tables  map[string][]u8
}

// new_builder returns an empty builder for an sfnt version such as
// sfnt_version_truetype (0x00010000, glyf outlines) or 'OTTO' (CFF
// outlines). The version travels into the header untouched; the builder
// never inspects it.
pub fn new_builder(version u32) Builder {
	return Builder{
		version: version
		tables:  map[string][]u8{}
	}
}

// set stores the body for a tag, replacing any body already set. The bytes
// are cloned, so the caller may reuse its slice. An empty body is allowed:
// it checksums to zero and occupies no file bytes, the way an empty table
// in a subset rebuild does.
pub fn (mut b Builder) set(tag string, bytes []u8) ! {
	if tag.len != 4 {
		return error('builder: tag ${tag} is ${tag.len} bytes, want 4')
	}
	for ch in tag.bytes() {
		if ch < 0x20 || ch > 0x7e {
			return error('builder: tag has a non-text byte')
		}
	}
	b.tables[tag] = bytes.clone()
}

// build lays the tables out as an sfnt file: sorted directory, recomputed
// search fields, 4-aligned bodies, recomputed checksums, and the head
// adjustment patch. The result parses with parse_sfnt and sums to
// 0xB1B0AFBA; without a usable head table there is no such file, which is
// the error.
pub fn (b &Builder) build() ![]u8 {
	if 'head' !in b.tables {
		return error('builder: no head table')
	}
	if b.tables['head'].len < 12 {
		return error('builder: head table is ${b.tables['head'].len} bytes, need at least 12 for checkSumAdjustment')
	}
	mut tags := b.tables.keys()
	tags.sort()
	num := tags.len
	mut power := 1
	mut exponent := 0
	for power * 2 <= num {
		power *= 2
		exponent++
	}
	search_range := power * 16
	range_shift := num * 16 - search_range
	mut out := []u8{cap: 12 + 16 * num}
	out << u8((b.version >> 24) & 0xff)
	out << u8((b.version >> 16) & 0xff)
	out << u8((b.version >> 8) & 0xff)
	out << u8(b.version & 0xff)
	out << u8((num >> 8) & 0xff)
	out << u8(num & 0xff)
	out << u8((search_range >> 8) & 0xff)
	out << u8(search_range & 0xff)
	out << u8((exponent >> 8) & 0xff)
	out << u8(exponent & 0xff)
	out << u8((range_shift >> 8) & 0xff)
	out << u8(range_shift & 0xff)
	mut offset := 12 + 16 * num
	mut head_at := 0
	for tag in tags {
		mut body := b.tables[tag].clone()
		if tag == 'head' {
			for i in 8 .. 12 {
				body[i] = u8(0)
			}
			head_at = offset
		}
		tagbytes := tag.bytes()
		for k in 0 .. 4 {
			out << tagbytes[k]
		}
		sum := textfont_checksum(body)
		out << u8((sum >> 24) & 0xff)
		out << u8((sum >> 16) & 0xff)
		out << u8((sum >> 8) & 0xff)
		out << u8(sum & 0xff)
		out << u8((offset >> 24) & 0xff)
		out << u8((offset >> 16) & 0xff)
		out << u8((offset >> 8) & 0xff)
		out << u8(offset & 0xff)
		out << u8((body.len >> 24) & 0xff)
		out << u8((body.len >> 16) & 0xff)
		out << u8((body.len >> 8) & 0xff)
		out << u8(body.len & 0xff)
		offset += (body.len + 3) / 4 * 4
	}
	for tag in tags {
		mut body := b.tables[tag].clone()
		if tag == 'head' {
			for i in 8 .. 12 {
				body[i] = u8(0)
			}
		}
		for byte_val in body {
			out << byte_val
		}
		pad := (4 - body.len % 4) % 4
		for _ in 0 .. pad {
			out << u8(0)
		}
	}
	adjust := textfont_adjustment(out)
	out[head_at + 8] = u8((adjust >> 24) & 0xff)
	out[head_at + 9] = u8((adjust >> 16) & 0xff)
	out[head_at + 10] = u8((adjust >> 8) & 0xff)
	out[head_at + 11] = u8(adjust & 0xff)
	return out
}
