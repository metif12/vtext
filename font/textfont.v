module font

// Textfont is the 14.1a roundtrip format: a canonical text rendering of an
// sfnt container, table by table, that loads back to byte-identical bytes.
//
// A dump looks like this:
//
//	harfara-roundtrip 1
//	sfnt 00010000 428032
//	search 128 3 112
//	table head 176 00... (raw table bytes as lowercase hex)
//	table glyf 1232 00...
//
// The header lines carry the physical container: the 4 sfnt version bytes,
// the file size, and the binary-search fields, all of which a rebuild must
// reproduce rather than recompute. Each table line carries the tag (4 raw
// characters, so `CFF ` keeps its space), the file offset, and the raw
// bytes as hex; the length is the hex length halved, so it cannot disagree
// with the data. The directory order is the dump order.
//
// Offsets are stored because fonts do not lay tables out in directory order:
// most of the corpus lists tables one way and stores them another. A loader
// that laid tables out in directory order would build a valid font with
// different bytes, which is exactly what this format exists to refuse to do.
//
// Checksums are recomputed on load, not stored: the directory checksums and
// head.checkSumAdjustment are derived values, and reproducing them from the
// bytes proves the checksum code rather than parroting the file. A font whose
// stored checksums disagree with its bytes dumps fine and loads to different
// bytes; every corpus font is self-consistent, so every corpus font is
// byte-symmetric.
//
// Refused with the reason: TTC collections (dumping the first member would
// silently drop the rest), WOFF1/WOFF2 (unwrap with woff_to_sfnt first),
// unknown sfnt versions, truncated directories, tables outside the file,
// overlapping tables, nonzero gap bytes (unrepresentable: the loader
// zero-fills), duplicate tags, and anything over the size cap.

pub const textfont_magic = 'harfara-roundtrip 1'

// textfont_max_bytes caps dump input and load output. The corpus peaks at
// 17MB (NotoSansSC); the cap matches the WOFF2 inflate limit.
const textfont_max_bytes = 64 << 20

// textfont_max_tables caps the table count a dump may carry. The corpus
// peaks at 23; a directory claiming hundreds of tables is corrupt.
const textfont_max_tables = 256

// textfont_dump renders the sfnt container in data as textfont text. Only
// the container is rendered: every table travels as raw bytes, parsed
// overlays arrive in later 14.1 slices.
pub fn textfont_dump(data []u8) !string {
	if data.len > textfont_max_bytes {
		return error('textfont: file is ${data.len} bytes, over the ${textfont_max_bytes} limit')
	}
	if data.len < 12 {
		return error('textfont: file too short (${data.len} bytes)')
	}
	if tag_from_bytes(data, 0) == 'ttcf' {
		return error('textfont: TTC collections are refused: dumping the first member would silently drop the rest')
	}
	if is_woff(data) {
		return error('textfont: WOFF1 containers are refused: unwrap with woff_to_sfnt first')
	}
	if is_woff2(data) {
		return error('textfont: WOFF2 containers are refused: unwrap with woff_to_sfnt first')
	}
	version := u32_be(data, 0)
	if version != sfnt_version_truetype && tag_from_bytes(data, 0) != 'OTTO'
		&& tag_from_bytes(data, 0) != 'true' {
		return error('textfont: unrecognised sfnt version 0x${version:08x}')
	}
	num_tables := int(u16_be(data, 4))
	if num_tables <= 0 || num_tables > (data.len - 12) / 16 {
		return error('textfont: implausible table count ${num_tables}')
	}
	if num_tables > textfont_max_tables {
		return error('textfont: ${num_tables} tables over the ${textfont_max_tables} limit')
	}
	search_range := int(u16_be(data, 6))
	entry_selector := int(u16_be(data, 8))
	range_shift := int(u16_be(data, 10))
	dir_end := 12 + 16 * num_tables
	mut tags := []string{cap: num_tables}
	mut offs := []int{cap: num_tables}
	mut lens := []int{cap: num_tables}
	for i in 0 .. num_tables {
		rec := 12 + i * 16
		tag := tag_from_bytes(data, rec)
		off := int(u32_be(data, rec + 8))
		length := int(u32_be(data, rec + 12))
		if off < 0 || length < 0 || off > data.len || length > data.len - off {
			return error('textfont: table ${i} (${tag}) lies outside the file')
		}
		for b in tag.bytes() {
			if b < 0x20 || b > 0x7e {
				return error('textfont: table ${i} has a non-text tag')
			}
		}
		if tag in tags {
			return error('textfont: duplicate table tag ${tag}')
		}
		tags << tag
		offs << off
		lens << length
	}
	// Gaps between tables must be zero: the loader zero-fills everything it
	// is not told, so nonzero gap bytes would not survive the round trip.
	mut slots := []TextfontSlot{cap: num_tables}
	for i in 0 .. num_tables {
		slots << TextfontSlot{ off: offs[i], idx: i }
	}
	slots.sort(a.off < b.off)
	mut cursor := dir_end
	for s in slots {
		i := s.idx
		if offs[i] < cursor {
			return error('textfont: table ${tags[i]} overlaps its neighbour')
		}
		for b in data[cursor..offs[i]] {
			if b != 0 {
				return error('textfont: nonzero gap before table ${tags[i]} is unrepresentable')
			}
		}
		cursor = offs[i] + lens[i]
	}
	for b in data[cursor..] {
		if b != 0 {
			return error('textfont: nonzero trailing bytes are unrepresentable')
		}
	}
	mut lines := []string{cap: num_tables + 3}
	lines << textfont_magic
	lines << 'sfnt ${version:08x} ${data.len}'
	lines << 'search ${search_range} ${entry_selector} ${range_shift}'
	for i in 0 .. num_tables {
		lines << 'table ${tags[i]} ${offs[i]} ${data[offs[i]..offs[i] + lens[i]].hex()}'
	}
	return lines.join('\n') + '\n'
}

// textfont_load rebuilds the sfnt file a textfont dump describes. The layout
// is the stored layout: directory in dump order, tables at stored offsets,
// everything else zero. Checksums and head.checkSumAdjustment are recomputed,
// the way subset/build_font and the WOFF writers do it.
pub fn textfont_load(text string) ![]u8 {
	lines := text.split_into_lines()
	if lines.len < 3 {
		return error('textfont: dump has ${lines.len} lines, need at least 3')
	}
	if lines[0] != textfont_magic {
		return error('textfont: bad magic line')
	}
	sfnt_fields := lines[1].split(' ')
	if sfnt_fields.len != 3 || sfnt_fields[0] != 'sfnt' {
		return error('textfont: bad sfnt line')
	}
	version := textfont_hex_u32(sfnt_fields[1]) or {
		return error('textfont: bad sfnt version: ${err}')
	}
	if version != sfnt_version_truetype && sfnt_fields[1] != '4f54544f' && sfnt_fields[1] != '74727565' {
		return error('textfont: unrecognised sfnt version ${sfnt_fields[1]}')
	}
	size := textfont_dec_int(sfnt_fields[2]) or {
		return error('textfont: bad file size: ${err}')
	}
	if size <= 0 || size > textfont_max_bytes {
		return error('textfont: file size ${size} out of range')
	}
	search_fields := lines[2].split(' ')
	if search_fields.len != 4 || search_fields[0] != 'search' {
		return error('textfont: bad search line')
	}
	search_range := textfont_dec_int(search_fields[1]) or {
		return error('textfont: bad search range: ${err}')
	}
	entry_selector := textfont_dec_int(search_fields[2]) or {
		return error('textfont: bad entry selector: ${err}')
	}
	range_shift := textfont_dec_int(search_fields[3]) or {
		return error('textfont: bad range shift: ${err}')
	}
	if search_range < 0 || search_range > 65535 || entry_selector < 0 || entry_selector > 65535
		|| range_shift < 0 || range_shift > 65535 {
		return error('textfont: search fields out of range')
	}
	table_lines := lines[3..]
	// A trailing newline leaves a last empty line, which is the dump's own
	// ending rather than a table.
	mut n_tables := table_lines.len
	if n_tables > 0 && table_lines[n_tables - 1] == '' {
		n_tables--
	}
	if n_tables <= 0 || n_tables > textfont_max_tables {
		return error('textfont: implausible table count ${n_tables}')
	}
	dir_end := 12 + 16 * n_tables
	if dir_end > size {
		return error('textfont: directory runs past the file size')
	}
	mut tags := []string{cap: n_tables}
	mut offs := []int{cap: n_tables}
	mut datas := [][]u8{cap: n_tables}
	for li in 0 .. n_tables {
		line := table_lines[li]
		if line.len < 12 || line[0..6] != 'table ' || line[10] != ` ` {
			return error('textfont: bad table line ${li}')
		}
		tag := line[6..10]
		for b in tag.bytes() {
			if b < 0x20 || b > 0x7e {
				return error('textfont: table ${li} has a non-text tag')
			}
		}
		rest := line[11..].split(' ')
		if rest.len != 2 {
			return error('textfont: bad table line ${li}')
		}
		off := textfont_dec_int(rest[0]) or {
			return error('textfont: bad offset on table line ${li}: ${err}')
		}
		raw := textfont_hex_decode(rest[1]) or {
			return error('textfont: bad hex on table line ${li}: ${err}')
		}
		if tag in tags {
			return error('textfont: duplicate table tag ${tag}')
		}
		if off < dir_end || off > size || raw.len > size - off {
			return error('textfont: table ${tag} lies outside the file')
		}
		tags << tag
		offs << off
		datas << raw
	}
	// Overlaps are found the way the dump finds them: visit tables in file
	// order and refuse one that starts before its neighbour ends.
	mut slots := []TextfontSlot{cap: n_tables}
	for i in 0 .. n_tables {
		slots << TextfontSlot{ off: offs[i], idx: i }
	}
	slots.sort(a.off < b.off)
	for a in 1 .. n_tables {
		prev := slots[a - 1].idx
		cur := slots[a].idx
		if offs[cur] < offs[prev] + datas[prev].len {
			return error('textfont: table ${tags[cur]} overlaps its neighbour')
		}
	}
	mut out := []u8{len: size}
	out[0] = u8((version >> 24) & 0xff)
	out[1] = u8((version >> 16) & 0xff)
	out[2] = u8((version >> 8) & 0xff)
	out[3] = u8(version & 0xff)
	textfont_put_u16(mut out, 4, n_tables)
	textfont_put_u16(mut out, 6, search_range)
	textfont_put_u16(mut out, 8, entry_selector)
	textfont_put_u16(mut out, 10, range_shift)
	mut head_at := -1
	for i in 0 .. n_tables {
		rec := 12 + i * 16
		for k in 0 .. 4 {
			out[rec + k] = tags[i].bytes()[k]
		}
		mut body := datas[i].clone()
		if tags[i] == 'head' {
			// checkSumAdjustment is zeroed while the table's own checksum is
			// taken, which is what the specification says it is computed
			// over. It is patched back once the file is laid out.
			if body.len < 12 {
				return error('textfont: head table too short for a checksum')
			}
			body[8] = 0
			body[9] = 0
			body[10] = 0
			body[11] = 0
			head_at = offs[i]
		}
		textfont_put_u32(mut out, rec + 4, textfont_checksum(body))
		textfont_put_u32(mut out, rec + 8, u32(offs[i]))
		textfont_put_u32(mut out, rec + 12, u32(body.len))
		// The laid-out bytes are the checksummed ones: for head that is the
		// zeroed body, so the whole-file sum below sees a zero adjustment.
		for k, b in body {
			out[offs[i] + k] = b
		}
	}
	if head_at >= 0 {
		adjust := textfont_adjustment(out)
		out[head_at + 8] = u8((adjust >> 24) & 0xff)
		out[head_at + 9] = u8((adjust >> 16) & 0xff)
		out[head_at + 10] = u8((adjust >> 8) & 0xff)
		out[head_at + 11] = u8(adjust & 0xff)
	}
	return out
}

// TextfontSlot pairs a table's offset with its directory index, so the
// gap walk can visit tables in file order. A sort comparator cannot close
// over the offset array, so the offset rides along in the element.
struct TextfontSlot {
	off int
	idx int
}

// textfont_hex_u32 parses 8 lowercase hex digits as a u32.
fn textfont_hex_u32(s string) !u32 {
	if s.len != 8 {
		return error('want 8 hex digits, have ${s.len}')
	}
	mut v := u32(0)
	for b in s.bytes() {
		v = (v << 4) | textfont_hex_val(b)!
	}
	return v
}

// textfont_hex_val parses one hex digit. Uppercase hex is refused: dumps
// emit lowercase, and a canonical format has one rendering.
fn textfont_hex_val(b u8) !u32 {
	if b >= `0` && b <= `9` {
		return u32(b - `0`)
	}
	if b >= `a` && b <= `f` {
		return u32(b - `a` + 10)
	}
	return error('bad hex digit `${b.ascii_str()}`')
}

// textfont_hex_decode decodes a lowercase hex string to bytes. The byte
// copy is hoisted out of the loop: string.bytes() clones, so calling it per
// nibble is O(n^2) memcpy and never finishes on multi-megabyte tables.
fn textfont_hex_decode(s string) ![]u8 {
	if s.len % 2 != 0 {
		return error('odd hex length ${s.len}')
	}
	sbytes := s.bytes()
	mut out := []u8{cap: s.len / 2}
	for i := 0; i < s.len; i += 2 {
		hi := textfont_hex_val(sbytes[i])!
		lo := textfont_hex_val(sbytes[i + 1])!
		out << u8((hi << 4) | lo)
	}
	return out
}

// textfont_dec_int parses a decimal int, all digits, no signs, no spaces.
fn textfont_dec_int(s string) !int {
	if s.len == 0 {
		return error('empty number')
	}
	mut v := 0
	for b in s.bytes() {
		if b < `0` || b > `9` {
			return error('bad decimal digit `${b.ascii_str()}`')
		}
		v = v * 10 + int(b - `0`)
		if v > textfont_max_bytes {
			return error('number over the size limit')
		}
	}
	return v
}

// textfont_put_u16 writes a big-endian u16 into out at off.
fn textfont_put_u16(mut out []u8, off int, v int) {
	out[off] = u8((v >> 8) & 0xff)
	out[off + 1] = u8(v & 0xff)
}

// textfont_put_u32 writes a big-endian u32 into out at off.
fn textfont_put_u32(mut out []u8, off int, v u32) {
	out[off] = u8((v >> 24) & 0xff)
	out[off + 1] = u8((v >> 16) & 0xff)
	out[off + 2] = u8((v >> 8) & 0xff)
	out[off + 3] = u8(v & 0xff)
}

// textfont_checksum sums bytes as big-endian words, padding the last word
// with zeros, the way the sfnt specification says a table is summed.
fn textfont_checksum(b []u8) u32 {
	mut sum := i64(0)
	mut i := 0
	for i + 4 <= b.len {
		sum += (i64(b[i]) << 24) | (i64(b[i + 1]) << 16) | (i64(b[i + 2]) << 8) | i64(b[i + 3])
		i += 4
	}
	mut tail := i64(0)
	mut shift := 24
	for i < b.len {
		tail |= i64(b[i]) << u32(shift)
		shift -= 8
		i++
	}
	sum += tail
	sum = ((sum % 4294967296) + 4294967296) % 4294967296
	return u32(sum)
}

// textfont_adjustment is the value head.checkSumAdjustment must hold for the
// whole file to sum to 0xB1B0AFBA. The field is still zero, which is what the
// specification says the sum is taken over. The constant stays in hex: it was
// written in decimal once and one digit out, and the result was a file every
// reader drew correctly that summed to 0xB1B180F2.
fn textfont_adjustment(whole []u8) u32 {
	mut sum := i64(0)
	for i := 0; i + 4 <= whole.len; i += 4 {
		sum += (i64(whole[i]) << 24) | (i64(whole[i + 1]) << 16) | (i64(whole[i + 2]) << 8) | i64(whole[i + 3])
	}
	sum = ((sum % 4294967296) + 4294967296) % 4294967296
	mut adjust := i64(0xB1B0AFBA) - sum
	if adjust < 0 {
		adjust += 4294967296
	}
	return u32(adjust)
}
