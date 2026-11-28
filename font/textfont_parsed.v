module font

// Textfont parsed overlays (14.1b wave 1): human-readable `begin TAG ... end TAG`
// sections for head, hhea, maxp, hmtx, OS/2, post, name and cmap. Glyf, CFF,
// GSUB, GPOS and everything else stay raw hex.
//
// A dump carries both: every `table TAG OFFSET HEX` line exactly as in 14.1a,
// then the parsed blocks grouped after all table lines, in directory order.
// The loader rebuilds each parsed block to bytes and ERRORS on any disagreement
// with the raw line (fail-closed: a hand edit must touch both or load refuses).
// A table with no block loads from its raw line alone, which is the backward
// compatibility: old dumps have no blocks, and a table whose layout this file
// does not know (a fifth OS/2 length, a format 13 cmap, a version 2.5 post)
// dumps raw-only with the rest still parsed.
//
// Syntax: one field per line, `word` then space-separated values. Integers are
// kebab-case decimal (`units-per-em 2048`, `weight-class 400`); 16.16 Fixed
// values are exact decimals (`italic-angle -12.5`); codepoints are `0x`
// lowercase hex (`group 0x20 0x7e 3`); raw byte runs (name payloads, glyph id
// arrays, post name strings, vendor id) are lowercase hex. The first word of a
// field line is never `table`, `sfnt`, `search`, `begin` or `end`, so a field
// line outside a block and a block line outside its place are both refused.
//
// What is stored and what is recomputed: every load-bearing byte is stored.
// Lengths, counts, offsets, checksums and head.checkSumAdjustment are
// recomputed on load the way 14.1a recomputes them, and the rebuild is compared
// against the raw line before it replaces it. Two corollaries worth knowing:
// head.check-sum-adjustment IS dumped (it is readable and it round-trips) but
// the loader still recomputes it afterwards, so editing it alone errors on the
// comparison rather than silently doing nothing; and a format 4 cmap stores
// its search parameters implicitly (they are a pure function of the segment
// count, verified standard on dump) while a format 12 stores its nonzero
// language (several corpus fonts carry a Mac language id there).
//
// The cmap section is segment-level rather than a flat codepoint map, and that
// is forced: a flat map cannot rebuild byte-identical subtables (format choice,
// segment layout, idRangeOffset sharing and the per-record tables of format 14
// are all lost), so a mapping list would error on every corpus font with a
// format 14 table. Segments, groups, per-selector records and verbatim glyph id
// blobs preserve everything the bytes hold.
//
// Refusals (dump emits no block, load falls back to raw): head/hhea lengths
// other than 54/36; maxp other than 32 bytes at 1.0 or 6 at 0.5; an hmtx whose
// length is not 4*metrics plus an even bearing tail; OS/2 lengths other than
// 78/86/96/100 or a version outside the length's class; post versions other
// than 2.0 (pascal strings exactly consuming the table) and 3.0 (exactly 32
// bytes); name format other than 0 or records outside the string storage;
// cmap subtables in formats other than 0/4/6/12/14 (the whole cmap stays raw
// then, so a covered subtable is never half kept), non-contiguous or
// trailing-padded subtable layouts, and format 14 tables that do not tile
// exactly.

// textfont_parsed_tags lists the wave 1 tables in canonical order. The dump
// walks the directory rather than this list, so order here is documentary.
const textfont_parsed_tags = ['head', 'hhea', 'maxp', 'hmtx', 'OS/2', 'post', 'name', 'cmap']

// textfont_encode_parsed renders one table's bytes as parsed block lines (the
// `begin`/`end` lines are added by the caller). It returns none when the table
// is not a wave 1 table or its layout is one this file does not represent, in
// which case the dump keeps the raw line only. `all` carries every table's
// bytes for the one cross-table read hmtx needs (num-metrics lives in hhea).
fn textfont_encode_parsed(tag string, body []u8, all map[string][]u8) ?[]string {
	if tag == 'head' {
		return textfont_head_lines(body)
	}
	if tag == 'hhea' {
		return textfont_hhea_lines(body)
	}
	if tag == 'maxp' {
		return textfont_maxp_lines(body)
	}
	if tag == 'hmtx' {
		return textfont_hmtx_lines(body, all)
	}
	if tag == 'OS/2' {
		return textfont_os2_lines(body)
	}
	if tag == 'post' {
		return textfont_post_lines(body)
	}
	if tag == 'name' {
		return textfont_name_lines(body)
	}
	if tag == 'cmap' {
		return textfont_cmap_lines(body)
	}
	return none
}

// textfont_decode_parsed rebuilds a parsed block's bytes. `fields` are the
// lines between `begin TAG` and `end TAG`. Any malformed line is an error; the
// caller compares the result against the raw line and refuses a mismatch.
fn textfont_decode_parsed(tag string, fields []string) ![]u8 {
	if tag == 'head' {
		return textfont_head_build(fields)
	}
	if tag == 'hhea' {
		return textfont_hhea_build(fields)
	}
	if tag == 'maxp' {
		return textfont_maxp_build(fields)
	}
	if tag == 'hmtx' {
		return textfont_hmtx_build(fields)
	}
	if tag == 'OS/2' {
		return textfont_os2_build(fields)
	}
	if tag == 'post' {
		return textfont_post_build(fields)
	}
	if tag == 'name' {
		return textfont_name_build(fields)
	}
	if tag == 'cmap' {
		return textfont_cmap_build(fields)
	}
	return error('textfont: unknown parsed table ${tag}')
}

// TextfontCursor is the read position inside a parsed block's field lines. A
// plain int cannot be a mutable parameter in V, so the position rides in a
// struct the take functions advance.
struct TextfontCursor {
mut:
	pos int
}

// textfont_take consumes the next field line, which must start with `word`,
// and returns the values after it. Structure is strict (order and count are
// part of the format); value spellings are canonical-strict.
fn textfont_take(lines []string, mut cur TextfontCursor, word string) ![]string {
	pos := cur.pos
	if pos >= lines.len {
		return error('textfont: `${word}` line missing')
	}
	parts := lines[pos].split(' ')
	cur.pos = pos + 1
	if parts.len == 0 || parts[0] != word {
		return error('textfont: want `${word}` line')
	}
	return parts[1..].clone()
}

// textfont_f_u64 reads parts[i] as an uncapped decimal integer. The index is
// checked first: a short line is a format error, not a panic.
fn textfont_f_u64(parts []string, i int) !u64 {
	if i < 0 || i >= parts.len {
		return error('textfont: short field line')
	}
	return textfont_dec_u64(parts[i])
}

// textfont_f_i64 reads parts[i] as a possibly-negative decimal integer.
fn textfont_f_i64(parts []string, i int) !i64 {
	if i < 0 || i >= parts.len {
		return error('textfont: short field line')
	}
	return textfont_dec_i64(parts[i])
}

// textfont_f_u16 reads parts[i] as a decimal u16.
fn textfont_f_u16(parts []string, i int) !u16 {
	v := textfont_f_u64(parts, i)!
	if v > 65535 {
		return error('textfont: value ${v} does not fit u16')
	}
	return u16(v)
}

// textfont_f_i16 reads parts[i] as a decimal i16.
fn textfont_f_i16(parts []string, i int) !i16 {
	v := textfont_f_i64(parts, i)!
	if v < -32768 || v > 32767 {
		return error('textfont: value ${v} does not fit i16')
	}
	return i16(v)
}

// textfont_f_u32 reads parts[i] as a decimal u32.
fn textfont_f_u32(parts []string, i int) !u32 {
	v := textfont_f_u64(parts, i)!
	if v > 4294967295 {
		return error('textfont: value ${v} does not fit u32')
	}
	return u32(v)
}

// textfont_f_i32 reads parts[i] as a decimal i32.
fn textfont_f_i32(parts []string, i int) !i32 {
	v := textfont_f_i64(parts, i)!
	if v < -2147483648 || v > 2147483647 {
		return error('textfont: value ${v} does not fit i32')
	}
	return i32(v)
}

// textfont_arity requires exactly n values on a field line. Trailing values
// are how a corrupt edit smuggles bytes past the reader, so they error.
fn textfont_arity(parts []string, n int) ! {
	if parts.len != n {
		return error('textfont: want ${n} values, have ${parts.len}')
	}
}

// textfont_dec_u64 parses an uncapped decimal integer, all digits, no signs.
// It caps at i64 max rather than u64 max: every field it feeds fits in an i64,
// and an exact overflow check beats a wrapping one.
fn textfont_dec_u64(s string) !u64 {
	if s.len == 0 {
		return error('textfont: empty number')
	}
	sb := s.bytes()
	mut v := u64(0)
	for b in sb {
		if b < `0` || b > `9` {
			return error('textfont: bad decimal digit')
		}
		d := u64(b - `0`)
		if v > (u64(9223372036854775807) - d) / 10 {
			return error('textfont: number too large')
		}
		v = v * 10 + d
	}
	return v
}

// textfont_dec_i64 parses a possibly-negative decimal integer.
fn textfont_dec_i64(s string) !i64 {
	sb := s.bytes()
	if sb.len > 0 && sb[0] == `-` {
		if sb.len == 1 {
			return error('textfont: bad number')
		}
		v := textfont_dec_u64(s[1..])!
		if v > u64(9223372036854775807) + 1 {
			return error('textfont: number too large')
		}
		if v == u64(9223372036854775807) + 1 {
			return i64(-9223372036854775807 - 1)
		}
		return -i64(v)
	}
	return i64(textfont_dec_u64(s)!)
}

// textfont_ri16 reads a big-endian i16.
fn textfont_ri16(b []u8, o int) i16 {
	v := int(u16_be(b, o))
	return i16(if v >= 0x8000 { v - 0x10000 } else { v })
}

// textfont_ri32 reads a big-endian i32.
fn textfont_ri32(b []u8, o int) i32 {
	v := i64(u32_be(b, o))
	return i32(if v >= 0x80000000 { v - 0x100000000 } else { v })
}

// textfont_ri64 reads a big-endian i64.
fn textfont_ri64(b []u8, o int) i64 {
	return (i64(u32_be(b, o)) << 32) | i64(u32_be(b, o + 4))
}

// textfont_w16 appends a big-endian u16.
fn textfont_w16(mut b []u8, v u16) {
	b << u8((v >> 8) & 0xff)
	b << u8(v & 0xff)
}

// textfont_wi16 appends a big-endian i16.
fn textfont_wi16(mut b []u8, v i16) {
	textfont_w16(mut b, u16(v))
}

// textfont_w32 appends a big-endian u32.
fn textfont_w32(mut b []u8, v u32) {
	b << u8((v >> 24) & 0xff)
	b << u8((v >> 16) & 0xff)
	b << u8((v >> 8) & 0xff)
	b << u8(v & 0xff)
}

// textfont_wi32 appends a big-endian i32.
fn textfont_wi32(mut b []u8, v i32) {
	textfont_w32(mut b, u32(v))
}

// textfont_wi64 appends a big-endian i64.
fn textfont_wi64(mut b []u8, v i64) {
	textfont_w32(mut b, u32((v >> 32) & 0xffffffff))
	textfont_w32(mut b, u32(v & 0xffffffff))
}

// textfont_fixed_str renders a 16.16 Fixed value as an exact decimal. The
// fraction always terminates (the denominator is 2^16) and trailing zeros are
// trimmed, so 1.0 prints as `1` and 0.5 as `0.5`. No float is involved: an f64
// cannot carry every 16.16 value and back.
fn textfont_fixed_str(v i32) string {
	mut x := i64(v)
	mut out := ''
	if x < 0 {
		out = '-'
		x = -x
	}
	out += '${x >> 16}'
	mut frac := x & 0xffff
	if frac != 0 {
		out += '.'
		mut digs := ''
		mut f := frac
		for f != 0 {
			f *= 10
			digs += u8(`0` + u8(f >> 16)).ascii_str()
			f &= 0xffff
		}
		for digs.ends_with('0') {
			digs = digs[..digs.len - 1]
		}
		out += digs
	}
	return out
}

// textfont_fixed_parse inverts textfont_fixed_str exactly, with integer math
// only. Digits are folded right to left: emitting took f = (f*10)%65536, so
// inverting takes f = (d*65536 + f)/10, and a step that does not divide by 10
// is not a Fixed expansion and errors. Trailing zeros fold to the same value,
// anything else that is not a genuine expansion is refused.
fn textfont_fixed_parse(s string) !i32 {
	mut t := s
	mut neg := false
	if t.starts_with('-') {
		neg = true
		t = t[1..]
	}
	if t.len == 0 {
		return error('textfont: bad fixed value')
	}
	tb := t.bytes()
	mut dot := -1
	for i, b in tb {
		if b == `.` {
			if dot >= 0 {
				return error('textfont: bad fixed value')
			}
			dot = i
		}
	}
	mut ip := t
	mut fp := ''
	if dot >= 0 {
		ip = t[..dot]
		fp = t[dot + 1..]
	}
	if ip.len == 0 {
		return error('textfont: bad fixed value')
	}
	ip_v := textfont_dec_u64(ip)!
	if ip_v > 32768 || (!neg && ip_v > 32767) {
		return error('textfont: fixed value out of range')
	}
	fb := fp.bytes()
	for b in fb {
		if b < `0` || b > `9` {
			return error('textfont: bad fixed value')
		}
	}
	mut f := i64(0)
	for i := fb.len - 1; i >= 0; i-- {
		f = i64(fb[i] - `0`) * 65536 + f
		if f % 10 != 0 {
			return error('textfont: bad fixed value')
		}
		f /= 10
	}
	mut v := i64(ip_v) * 65536 + f
	if neg {
		v = -v
	}
	if !neg && v > 2147483647 {
		return error('textfont: fixed value out of range')
	}
	if neg && v < -2147483648 {
		return error('textfont: fixed value out of range')
	}
	return i32(v)
}

// textfont_cp_str renders a codepoint as minimal lowercase `0x` hex.
fn textfont_cp_str(cp u32) string {
	if cp == 0 {
		return '0x0'
	}
	mut v := cp
	mut tmp := []u8{cap: 8}
	for v > 0 {
		tmp << '0123456789abcdef'[int(v & 0xf)]
		v >>= 4
	}
	mut out := []u8{cap: 10}
	out << `0`
	out << `x`
	for i := tmp.len - 1; i >= 0; i-- {
		out << tmp[i]
	}
	return out.bytestr()
}

// textfont_parse_cp reads a `0x` lowercase-hex codepoint. Leading zeros are
// accepted (the value is what matters); uppercase is refused (dumps are
// canonical) by way of the lowercase-only hex digit reader.
fn textfont_parse_cp(s string) !u32 {
	sb := s.bytes()
	if sb.len < 3 || sb[0] != `0` || sb[1] != `x` {
		return error('textfont: bad codepoint')
	}
	mut v := u64(0)
	for b in sb[2..] {
		v = v * 16 + u64(textfont_hex_val(b)!)
		if v > 0xffffffff {
			return error('textfont: codepoint out of range')
		}
	}
	return u32(v)
}

// textfont_u24 reads a big-endian uint24.
fn textfont_u24(b []u8, o int) u32 {
	return (u32(b[o]) << 16) | (u32(b[o + 1]) << 8) | u32(b[o + 2])
}

// textfont_head_lines renders a 54-byte head table. Anything else is none:
// the loader rebuilds exactly 54 bytes, and a longer head is raw-only.
fn textfont_head_lines(b []u8) ?[]string {
	if b.len != 54 {
		return none
	}
	return [
		'major-version ${u16_be(b, 0)}',
		'minor-version ${u16_be(b, 2)}',
		'font-revision ${textfont_fixed_str(textfont_ri32(b, 4))}',
		'check-sum-adjustment ${u32_be(b, 8)}',
		'magic ${u32_be(b, 12)}',
		'flags ${u16_be(b, 16)}',
		'units-per-em ${u16_be(b, 18)}',
		'created ${textfont_ri64(b, 20)}',
		'modified ${textfont_ri64(b, 28)}',
		'x-min ${textfont_ri16(b, 36)}',
		'y-min ${textfont_ri16(b, 38)}',
		'x-max ${textfont_ri16(b, 40)}',
		'y-max ${textfont_ri16(b, 42)}',
		'mac-style ${u16_be(b, 44)}',
		'lowest-rec-ppem ${u16_be(b, 46)}',
		'font-direction-hint ${textfont_ri16(b, 48)}',
		'index-to-loc-format ${textfont_ri16(b, 50)}',
		'glyph-data-format ${textfont_ri16(b, 52)}',
	]
}

// textfont_head_build rebuilds a 54-byte head table from head field lines.
fn textfont_head_build(fields []string) ![]u8 {
	mut cur := TextfontCursor{}
	mut out := []u8{cap: 54}
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'major-version')!, 0)!)
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'minor-version')!, 0)!)
	rev_parts := textfont_take(fields, mut cur, 'font-revision')!
	textfont_arity(rev_parts, 1)!
	textfont_wi32(mut out, textfont_fixed_parse(rev_parts[0])!)
	textfont_w32(mut out, textfont_f_u32(textfont_take(fields, mut cur, 'check-sum-adjustment')!,
		0)!)
	textfont_w32(mut out, textfont_f_u32(textfont_take(fields, mut cur, 'magic')!, 0)!)
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'flags')!, 0)!)
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'units-per-em')!, 0)!)
	created := textfont_f_i64(textfont_take(fields, mut cur, 'created')!, 0)!
	textfont_wi64(mut out, created)
	modified := textfont_f_i64(textfont_take(fields, mut cur, 'modified')!, 0)!
	textfont_wi64(mut out, modified)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'x-min')!, 0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'y-min')!, 0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'x-max')!, 0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'y-max')!, 0)!)
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'mac-style')!, 0)!)
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'lowest-rec-ppem')!,
		0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'font-direction-hint')!,
		0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'index-to-loc-format')!,
		0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'glyph-data-format')!,
		0)!)
	if cur.pos != fields.len {
		return error('textfont: trailing lines in head block')
	}
	return out
}

// textfont_hhea_lines renders a 36-byte hhea table.
fn textfont_hhea_lines(b []u8) ?[]string {
	if b.len != 36 {
		return none
	}
	panose_res := '${textfont_ri16(b, 24)} ${textfont_ri16(b, 26)} ${textfont_ri16(b, 28)} ${textfont_ri16(b, 30)}'
	return [
		'major-version ${u16_be(b, 0)}',
		'minor-version ${u16_be(b, 2)}',
		'ascender ${textfont_ri16(b, 4)}',
		'descender ${textfont_ri16(b, 6)}',
		'line-gap ${textfont_ri16(b, 8)}',
		'advance-width-max ${u16_be(b, 10)}',
		'min-left-side-bearing ${textfont_ri16(b, 12)}',
		'min-right-side-bearing ${textfont_ri16(b, 14)}',
		'x-max-extent ${textfont_ri16(b, 16)}',
		'caret-slope-rise ${textfont_ri16(b, 18)}',
		'caret-slope-run ${textfont_ri16(b, 20)}',
		'caret-offset ${textfont_ri16(b, 22)}',
		'reserved ${panose_res}',
		'metric-data-format ${textfont_ri16(b, 32)}',
		'num-h-metrics ${u16_be(b, 34)}',
	]
}

// textfont_hhea_build rebuilds a 36-byte hhea table.
fn textfont_hhea_build(fields []string) ![]u8 {
	mut cur := TextfontCursor{}
	mut out := []u8{cap: 36}
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'major-version')!, 0)!)
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'minor-version')!, 0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'ascender')!, 0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'descender')!, 0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'line-gap')!, 0)!)
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'advance-width-max')!,
		0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'min-left-side-bearing')!,
		0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'min-right-side-bearing')!,
		0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'x-max-extent')!, 0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'caret-slope-rise')!,
		0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'caret-slope-run')!,
		0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'caret-offset')!, 0)!)
	reserved := textfont_take(fields, mut cur, 'reserved')!
	textfont_arity(reserved, 4)!
	for v in reserved {
		textfont_wi16(mut out, textfont_f_i16([v], 0)!)
	}
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'metric-data-format')!,
		0)!)
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'num-h-metrics')!,
		0)!)
	if cur.pos != fields.len {
		return error('textfont: trailing lines in hhea block')
	}
	return out
}

// textfont_maxp_lines renders maxp: 32 bytes at version 1.0, 6 at 0.5 (CFF).
// Any other length or version pairing is none.
fn textfont_maxp_lines(b []u8) ?[]string {
	if b.len == 6 && u32_be(b, 0) == 0x00005000 {
		return [
			'major-version ${u16_be(b, 0)}',
			'minor-version ${u16_be(b, 2)}',
			'num-glyphs ${u16_be(b, 4)}',
		]
	}
	if b.len == 32 && u32_be(b, 0) == 0x00010000 {
		return [
			'major-version ${u16_be(b, 0)}',
			'minor-version ${u16_be(b, 2)}',
			'num-glyphs ${u16_be(b, 4)}',
			'max-points ${u16_be(b, 6)}',
			'max-contours ${u16_be(b, 8)}',
			'max-composite-points ${u16_be(b, 10)}',
			'max-composite-contours ${u16_be(b, 12)}',
			'max-zones ${u16_be(b, 14)}',
			'max-twilight-points ${u16_be(b, 16)}',
			'max-storage ${u16_be(b, 18)}',
			'max-function-defs ${u16_be(b, 20)}',
			'max-instruction-defs ${u16_be(b, 22)}',
			'max-stack-elements ${u16_be(b, 24)}',
			'max-size-of-instructions ${u16_be(b, 26)}',
			'max-component-elements ${u16_be(b, 28)}',
			'max-component-depth ${u16_be(b, 30)}',
		]
	}
	return none
}

// textfont_maxp_build rebuilds a maxp table. The version selects the shape:
// (1,0) carries the thirteen TrueType maxima, (0,20480) is the bare CFF form.
fn textfont_maxp_build(fields []string) ![]u8 {
	mut cur := TextfontCursor{}
	mut out := []u8{}
	major := textfont_f_u16(textfont_take(fields, mut cur, 'major-version')!, 0)!
	minor := textfont_f_u16(textfont_take(fields, mut cur, 'minor-version')!, 0)!
	textfont_w16(mut out, major)
	textfont_w16(mut out, minor)
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'num-glyphs')!, 0)!)
	if major == 1 && minor == 0 {
		for word in ['max-points', 'max-contours', 'max-composite-points', 'max-composite-contours',
			'max-zones', 'max-twilight-points', 'max-storage', 'max-function-defs',
			'max-instruction-defs', 'max-stack-elements', 'max-size-of-instructions',
			'max-component-elements', 'max-component-depth'] {
			textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, word)!,
				0)!)
		}
	} else if major != 0 || minor != 20480 {
		return error('textfont: unknown maxp version ${major}.${minor}')
	}
	if cur.pos != fields.len {
		return error('textfont: trailing lines in maxp block')
	}
	return out
}

// textfont_hmtx_lines renders hmtx given its companion: num-metrics from
// hhea. Num-glyphs is derived from the byte length (metrics plus tail), not
// read from maxp, so the block describes the hmtx bytes alone and survives a
// maxp-only edit. A length that is not 4*metrics plus an even tail is none.
fn textfont_hmtx_lines(b []u8, all map[string][]u8) ?[]string {
	hhea := all['hhea'] or { return none }
	if hhea.len < 36 {
		return none
	}
	nm := int(u16_be(hhea, 34))
	if nm < 0 || 4 * nm > b.len || (b.len - 4 * nm) % 2 != 0 {
		return none
	}
	ng := nm + (b.len - 4 * nm) / 2
	if ng > 1000000 {
		return none
	}
	mut out := []string{cap: nm + 3}
	out << 'num-glyphs ${ng}'
	out << 'num-metrics ${nm}'
	for i in 0 .. nm {
		out << 'metric ${u16_be(b, i * 4)} ${textfont_ri16(b, i * 4 + 2)}'
	}
	mut tail := 'lsb-tail'
	for i in nm .. ng {
		tail += ' ${textfont_ri16(b, nm * 4 + (i - nm) * 2)}'
	}
	out << tail
	return out
}

// textfont_hmtx_build rebuilds hmtx: num-metrics `metric` lines then one
// `lsb-tail` line carrying exactly num-glyphs minus num-metrics bearings.
fn textfont_hmtx_build(fields []string) ![]u8 {
	mut cur := TextfontCursor{}
	ng_parts := textfont_take(fields, mut cur, 'num-glyphs')!
	textfont_arity(ng_parts, 1)!
	ng := textfont_f_u64(ng_parts, 0)!
	nm_parts := textfont_take(fields, mut cur, 'num-metrics')!
	textfont_arity(nm_parts, 1)!
	nm := textfont_f_u64(nm_parts, 0)!
	if nm > ng || ng > 65535 {
		return error('textfont: bad hmtx counts')
	}
	mut out := []u8{cap: int(4 * nm + 2 * (ng - nm))}
	for _ in 0 .. nm {
		m := textfont_take(fields, mut cur, 'metric')!
		textfont_arity(m, 2)!
		textfont_w16(mut out, textfont_f_u16(m, 0)!)
		textfont_wi16(mut out, textfont_f_i16(m, 1)!)
	}
	tail := textfont_take(fields, mut cur, 'lsb-tail')!
	if u64(tail.len) != ng - nm {
		return error('textfont: lsb-tail holds ${tail.len}, want ${ng - nm}')
	}
	for v in tail {
		textfont_wi16(mut out, textfont_f_i16([v], 0)!)
	}
	if cur.pos != fields.len {
		return error('textfont: trailing lines in hmtx block')
	}
	return out
}

// textfont_os2_len_class maps an OS/2 table length to the versions it can
// hold: 78 is v0, 86 is v1, 96 is v2/v3/v4, 100 is v5. Anything else is
// unrepresentable here and dumps raw-only.
fn textfont_os2_len_class(body_len int, version int) bool {
	if body_len == 78 {
		return version == 0
	}
	if body_len == 86 {
		return version == 1
	}
	if body_len == 96 {
		return version >= 2 && version <= 4
	}
	if body_len == 100 {
		return version == 5
	}
	return false
}

// textfont_os2_lines renders OS/2. Panose travels as ten decimals, the vendor
// id as eight lowercase hex chars; both are fixed-width byte runs, so decimal
// per-byte and hex spell the same bytes and the spelling is arbitrary.
fn textfont_os2_lines(b []u8) ?[]string {
	if b.len != 78 && b.len != 86 && b.len != 96 && b.len != 100 {
		return none
	}
	ver := int(u16_be(b, 0))
	if !textfont_os2_len_class(b.len, ver) {
		return none
	}
	mut panose := ''
	for i in 0 .. 10 {
		if i > 0 {
			panose += ' '
		}
		panose += '${b[32 + i]}'
	}
	mut out := []string{cap: 40}
	out << 'version ${ver}'
	out << 'x-avg-char-width ${textfont_ri16(b, 2)}'
	out << 'weight-class ${u16_be(b, 4)}'
	out << 'width-class ${u16_be(b, 6)}'
	out << 'type ${u16_be(b, 8)}'
	out << 'y-subscript-x-size ${textfont_ri16(b, 10)}'
	out << 'y-subscript-y-size ${textfont_ri16(b, 12)}'
	out << 'y-subscript-x-offset ${textfont_ri16(b, 14)}'
	out << 'y-subscript-y-offset ${textfont_ri16(b, 16)}'
	out << 'y-superscript-x-size ${textfont_ri16(b, 18)}'
	out << 'y-superscript-y-size ${textfont_ri16(b, 20)}'
	out << 'y-superscript-x-offset ${textfont_ri16(b, 22)}'
	out << 'y-superscript-y-offset ${textfont_ri16(b, 24)}'
	out << 'y-strikeout-size ${textfont_ri16(b, 26)}'
	out << 'y-strikeout-position ${textfont_ri16(b, 28)}'
	out << 'family-class ${textfont_ri16(b, 30)}'
	out << 'panose ${panose}'
	out << 'unicode-range-1 ${u32_be(b, 42)}'
	out << 'unicode-range-2 ${u32_be(b, 46)}'
	out << 'unicode-range-3 ${u32_be(b, 50)}'
	out << 'unicode-range-4 ${u32_be(b, 54)}'
	out << 'vendor-id ${b[58..62].hex()}'
	out << 'selection ${u16_be(b, 62)}'
	out << 'first-char-index ${u16_be(b, 64)}'
	out << 'last-char-index ${u16_be(b, 66)}'
	out << 'typo-ascender ${textfont_ri16(b, 68)}'
	out << 'typo-descender ${textfont_ri16(b, 70)}'
	out << 'typo-line-gap ${textfont_ri16(b, 72)}'
	out << 'win-ascent ${u16_be(b, 74)}'
	out << 'win-descent ${u16_be(b, 76)}'
	if b.len >= 86 {
		out << 'code-page-range-1 ${u32_be(b, 78)}'
		out << 'code-page-range-2 ${u32_be(b, 82)}'
	}
	if b.len >= 96 {
		out << 'x-height ${textfont_ri16(b, 86)}'
		out << 'cap-height ${textfont_ri16(b, 88)}'
		out << 'default-char ${u16_be(b, 90)}'
		out << 'break-char ${u16_be(b, 92)}'
		out << 'max-context ${u16_be(b, 94)}'
	}
	if b.len >= 100 {
		out << 'lower-optical-point-size ${u16_be(b, 96)}'
		out << 'upper-optical-point-size ${u16_be(b, 98)}'
	}
	return out
}

// textfont_os2_build rebuilds OS/2. The version selects how many field lines
// follow win-descent; a version outside 0..5 or a length the version cannot
// hold is refused rather than half built.
fn textfont_os2_build(fields []string) ![]u8 {
	mut cur := TextfontCursor{}
	mut out := []u8{cap: 100}
	ver_parts := textfont_take(fields, mut cur, 'version')!
	textfont_arity(ver_parts, 1)!
	ver := int(textfont_f_u64(ver_parts, 0)!)
	if ver < 0 || ver > 5 {
		return error('textfont: unknown OS/2 version ${ver}')
	}
	textfont_w16(mut out, u16(ver))
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'x-avg-char-width')!,
		0)!)
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'weight-class')!, 0)!)
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'width-class')!, 0)!)
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'type')!, 0)!)
	for word in ['y-subscript-x-size', 'y-subscript-y-size', 'y-subscript-x-offset',
		'y-subscript-y-offset', 'y-superscript-x-size', 'y-superscript-y-size', 'y-superscript-x-offset',
		'y-superscript-y-offset', 'y-strikeout-size', 'y-strikeout-position'] {
		textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, word)!, 0)!)
	}
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'family-class')!,
		0)!)
	panose := textfont_take(fields, mut cur, 'panose')!
	textfont_arity(panose, 10)!
	for v in panose {
		p := textfont_f_u64([v], 0)!
		if p > 255 {
			return error('textfont: panose byte out of range')
		}
		out << u8(p)
	}
	for word in ['unicode-range-1', 'unicode-range-2', 'unicode-range-3', 'unicode-range-4'] {
		textfont_w32(mut out, textfont_f_u32(textfont_take(fields, mut cur, word)!, 0)!)
	}
	vend := textfont_take(fields, mut cur, 'vendor-id')!
	textfont_arity(vend, 1)!
	vend_bytes := textfont_hex_decode(vend[0])!
	if vend_bytes.len != 4 {
		return error('textfont: vendor-id is not 4 bytes')
	}
	out << vend_bytes
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'selection')!, 0)!)
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'first-char-index')!,
		0)!)
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'last-char-index')!,
		0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'typo-ascender')!,
		0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'typo-descender')!,
		0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'typo-line-gap')!, 0)!)
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'win-ascent')!, 0)!)
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'win-descent')!, 0)!)
	if ver >= 1 {
		textfont_w32(mut out, textfont_f_u32(textfont_take(fields, mut cur, 'code-page-range-1')!,
			0)!)
		textfont_w32(mut out, textfont_f_u32(textfont_take(fields, mut cur, 'code-page-range-2')!,
			0)!)
	}
	if ver >= 2 {
		textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'x-height')!, 0)!)
		textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'cap-height')!,
			0)!)
		textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'default-char')!,
			0)!)
		textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'break-char')!, 0)!)
		textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'max-context')!, 0)!)
	}
	if ver >= 5 {
		textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'lower-optical-point-size')!,
			0)!)
		textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'upper-optical-point-size')!,
			0)!)
	}
	if cur.pos != fields.len {
		return error('textfont: trailing lines in OS/2 block')
	}
	if !textfont_os2_len_class(out.len, ver) {
		return error('textfont: OS/2 length does not match version ${ver}')
	}
	return out
}

// textfont_post_lines renders post: 3.0 is the bare 32 bytes, 2.0 appends the
// glyph name index array and the concatenated pascal strings as one hex blob.
// The blob splits deterministically (one string per index >= 258, in order),
// and the strings must consume the table exactly, so structure beyond the
// blob is unnecessary. Anything else is none.
fn textfont_post_lines(b []u8) ?[]string {
	if b.len < 32 {
		return none
	}
	major := u16_be(b, 0)
	minor := u16_be(b, 2)
	mut out := []string{cap: 14}
	out << 'format-major ${major}'
	out << 'format-minor ${minor}'
	out << 'italic-angle ${textfont_fixed_str(textfont_ri32(b, 4))}'
	out << 'underline-position ${textfont_ri16(b, 8)}'
	out << 'underline-thickness ${textfont_ri16(b, 10)}'
	out << 'is-fixed-pitch ${u32_be(b, 12)}'
	out << 'min-mem-type42 ${u32_be(b, 16)}'
	out << 'max-mem-type42 ${u32_be(b, 20)}'
	out << 'min-mem-type1 ${u32_be(b, 24)}'
	out << 'max-mem-type1 ${u32_be(b, 28)}'
	if major == 3 && minor == 0 {
		if b.len != 32 {
			return none
		}
		return out
	}
	if major == 2 && minor == 0 {
		if b.len < 34 {
			return none
		}
		png := int(u16_be(b, 32))
		if png < 0 || png > 1000000 || 34 + 2 * png > b.len {
			return none
		}
		mut ncustom := 0
		mut indices := ''
		for g in 0 .. png {
			ix := int(u16_be(b, 34 + g * 2))
			if ix >= 258 {
				ncustom++
			}
			if g > 0 {
				indices += ' '
			}
			indices += '${ix}'
		}
		// Every custom index consumes exactly one pascal string, and the
		// strings must consume the table exactly: trailing bytes are
		// unrepresentable, so they refuse the block rather than vanish.
		mut at := 34 + 2 * png
		for _ in 0 .. ncustom {
			if at >= b.len {
				return none
			}
			at += 1 + int(b[at])
		}
		if at != b.len {
			return none
		}
		out << 'num-glyphs ${png}'
		out << 'glyph-name-index ${indices}'
		out << 'names ${b[34 + 2 * png..].hex()}'
		return out
	}
	return none
}

// textfont_post_build rebuilds post. Format (3,0) ends after the memory
// fields; (2,0) reads the index array then splits the name blob into one
// pascal string per custom index, refusing leftover or short bytes.
fn textfont_post_build(fields []string) ![]u8 {
	mut cur := TextfontCursor{}
	mut out := []u8{cap: 64}
	major := textfont_f_u16(textfont_take(fields, mut cur, 'format-major')!, 0)!
	minor := textfont_f_u16(textfont_take(fields, mut cur, 'format-minor')!, 0)!
	textfont_w16(mut out, major)
	textfont_w16(mut out, minor)
	angle := textfont_take(fields, mut cur, 'italic-angle')!
	textfont_arity(angle, 1)!
	textfont_wi32(mut out, textfont_fixed_parse(angle[0])!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'underline-position')!,
		0)!)
	textfont_wi16(mut out, textfont_f_i16(textfont_take(fields, mut cur, 'underline-thickness')!,
		0)!)
	textfont_w32(mut out, textfont_f_u32(textfont_take(fields, mut cur, 'is-fixed-pitch')!,
		0)!)
	for word in ['min-mem-type42', 'max-mem-type42', 'min-mem-type1', 'max-mem-type1'] {
		textfont_w32(mut out, textfont_f_u32(textfont_take(fields, mut cur, word)!, 0)!)
	}
	if major == 3 && minor == 0 {
		if cur.pos != fields.len {
			return error('textfont: trailing lines in post block')
		}
		return out
	}
	if major == 2 && minor == 0 {
		png_parts := textfont_take(fields, mut cur, 'num-glyphs')!
		textfont_arity(png_parts, 1)!
		png := textfont_f_u64(png_parts, 0)!
		if png > 65535 {
			return error('textfont: bad post num-glyphs')
		}
		textfont_w16(mut out, u16(png))
		idx_parts := textfont_take(fields, mut cur, 'glyph-name-index')!
		if u64(idx_parts.len) != png {
			return error('textfont: glyph-name-index holds ${idx_parts.len}, want ${png}')
		}
		mut ncustom := u64(0)
		for v in idx_parts {
			ix := textfont_f_u64([v], 0)!
			if ix > 65535 {
				return error('textfont: post name index out of range')
			}
			if ix >= 258 {
				ncustom++
			}
			textfont_w16(mut out, u16(ix))
		}
		names_parts := textfont_take(fields, mut cur, 'names')!
		textfont_arity(names_parts, 1)!
		blob := textfont_hex_decode(names_parts[0])!
		mut at := 0
		for _ in 0 .. ncustom {
			if at >= blob.len {
				return error('textfont: post names run short')
			}
			at += 1 + int(blob[at])
		}
		if at != blob.len {
			return error('textfont: post names have trailing bytes')
		}
		out << blob
		if cur.pos != fields.len {
			return error('textfont: trailing lines in post block')
		}
		return out
	}
	return error('textfont: unknown post format ${major}.${minor}')
}

// textfont_name_lines renders name format 0: records with explicit string
// offsets (sharing and ordering are preserved verbatim) plus the storage size.
// Anything else, including format 1 with its lang-tag section, is none.
fn textfont_name_lines(b []u8) ?[]string {
	if b.len < 6 {
		return none
	}
	if u16_be(b, 0) != 0 {
		return none
	}
	cnt := int(u16_be(b, 2))
	soff := int(u16_be(b, 4))
	if 6 + 12 * cnt > b.len || soff < 6 + 12 * cnt || soff > b.len {
		return none
	}
	mut out := []string{cap: cnt + 4}
	out << 'format 0'
	out << 'count ${cnt}'
	out << 'string-offset ${soff}'
	out << 'string-length ${b.len - soff}'
	for k in 0 .. cnt {
		ro := 6 + k * 12
		ln := int(u16_be(b, ro + 8))
		of := int(u16_be(b, ro + 10))
		if of < 0 || ln < 0 || of + ln > b.len - soff {
			return none
		}
		abs := soff + of
		out << 'record ${u16_be(b, ro)} ${u16_be(b, ro + 2)} ${u16_be(b, ro + 4)} ${u16_be(b, ro + 6)} ${of} ${b[abs..abs + ln].hex()}'
	}
	return out
}

// textfont_name_build rebuilds name: records in dumped order, payloads written
// at stored offsets over zeroed storage. Overlapping records always agree
// (they read the same bytes), and nonzero original gap bytes fail the caller's
// comparison, which is how unrepresentable gaps are refused.
fn textfont_name_build(fields []string) ![]u8 {
	mut cur := TextfontCursor{}
	format_parts := textfont_take(fields, mut cur, 'format')!
	textfont_arity(format_parts, 1)!
	if textfont_f_u64(format_parts, 0)! != 0 {
		return error('textfont: unknown name format')
	}
	cnt_parts := textfont_take(fields, mut cur, 'count')!
	textfont_arity(cnt_parts, 1)!
	cnt := textfont_f_u64(cnt_parts, 0)!
	if cnt > 65535 {
		return error('textfont: bad name count')
	}
	soff_parts := textfont_take(fields, mut cur, 'string-offset')!
	textfont_arity(soff_parts, 1)!
	soff := textfont_f_u64(soff_parts, 0)!
	slen_parts := textfont_take(fields, mut cur, 'string-length')!
	textfont_arity(slen_parts, 1)!
	slen := textfont_f_u64(slen_parts, 0)!
	if soff > 65535 || soff < 6 + 12 * cnt || soff + slen > 64 << 20 {
		return error('textfont: bad name string storage')
	}
	mut out := []u8{cap: int(soff + slen)}
	textfont_w16(mut out, 0)
	textfont_w16(mut out, u16(cnt))
	textfont_w16(mut out, u16(soff))
	mut storage := []u8{len: int(slen)}
	for _ in 0 .. cnt {
		r := textfont_take(fields, mut cur, 'record')!
		textfont_arity(r, 6)!
		textfont_w16(mut out, textfont_f_u16(r, 0)!)
		textfont_w16(mut out, textfont_f_u16(r, 1)!)
		textfont_w16(mut out, textfont_f_u16(r, 2)!)
		textfont_w16(mut out, textfont_f_u16(r, 3)!)
		of := textfont_f_u64(r, 4)!
		payload := textfont_hex_decode(r[5])!
		if of + u64(payload.len) > slen {
			return error('textfont: name record outside its storage')
		}
		if u64(payload.len) > 65535 || of > 65535 {
			return error('textfont: name record too large')
		}
		textfont_w16(mut out, u16(payload.len))
		textfont_w16(mut out, u16(of))
		for i, byte_val in payload {
			storage[int(of) + i] = byte_val
		}
	}
	// The record area ends at 6+12*cnt and strings start at soff: any gap is
	// zero-filled here and refused by the raw comparison if it was not zero.
	for out.len < int(soff) {
		out << u8(0)
	}
	out << storage
	if cur.pos != fields.len {
		return error('textfont: trailing lines in name block')
	}
	return out
}

// textfont_std_search returns the specification's binary-search parameters for
// a format 4 segCount. The corpus is all standard, and the encoder checks, so
// the decoder recomputes rather than stores.
fn textfont_std_search(segcount int) (int, int, int) {
	mut p := 1
	mut e := 0
	for p * 2 <= segcount {
		p *= 2
		e++
	}
	return 2 * p, e, 2 * segcount - 2 * p
}

// textfont_cmap_lines renders cmap: the header version, one `encoding` line
// per encoding record (in table order, naming a shared subtable by id), then
// one `subtable` section per unique subtable in offset order. Encoding records
// routinely share a subtable ((0,3) with (3,1) in every corpus font) and list
// them out of storage order, so ids carry the sharing and the offsets are
// recomputed on rebuild. Formats 0/4/6/12/14 are covered; a table carrying
// anything else stays raw-only as a whole, so a covered subtable is never
// half kept. The unique subtables must tile the table contiguously in offset
// order with no trailing bytes, which the corpus all does; anything else is
// none.
fn textfont_cmap_lines(b []u8) ?[]string {
	if b.len < 4 {
		return none
	}
	nt := int(u16_be(b, 2))
	if nt <= 0 || nt > 256 || 4 + 8 * nt > b.len {
		return none
	}
	mut plats := []u16{cap: nt}
	mut encs := []u16{cap: nt}
	mut offs := []int{cap: nt}
	for i in 0 .. nt {
		rec := 4 + i * 8
		off := int(u32_be(b, rec + 4))
		if off < 0 || off + 2 > b.len {
			return none
		}
		plats << u16_be(b, rec)
		encs << u16_be(b, rec + 2)
		offs << off
	}
	// Deduplicate shared subtables by offset; an offset outside the table or
	// a format this file does not represent refuses the whole table.
	mut uniq := []int{}
	for off in offs {
		if off !in uniq {
			uniq << off
		}
	}
	uniq.sort()
	mut sub_id := map[int]int{}
	for ui, off in uniq {
		sub_id[off] = ui
	}
	mut sublens := []int{cap: uniq.len}
	mut sublines := [][]string{cap: uniq.len}
	mut subfmts := []int{cap: uniq.len}
	for off in uniq {
		lines, sublen := textfont_cmap_sub_lines(b, off) or { return none }
		sublens << sublen
		sublines << lines
		subfmts << int(u16_be(b, off))
	}
	mut cursor := 4 + 8 * nt
	for ui in 0 .. uniq.len {
		if uniq[ui] != cursor {
			return none
		}
		cursor += sublens[ui]
	}
	if cursor != b.len {
		return none
	}
	mut out := []string{cap: nt * 2}
	out << 'version ${u16_be(b, 0)}'
	for i in 0 .. nt {
		out << 'encoding ${plats[i]} ${encs[i]} ${sub_id[offs[i]]}'
	}
	for ui in 0 .. uniq.len {
		out << 'subtable ${ui} ${subfmts[ui]}'
		out << sublines[ui]
	}
	return out
}

// textfont_cmap_sub_lines renders one subtable plus its declared length.
fn textfont_cmap_sub_lines(b []u8, off int) ?([]string, int) {
	f := int(u16_be(b, off))
	if f == 0 {
		return textfont_cmap_f0_lines(b, off)
	}
	if f == 4 {
		return textfont_cmap_f4_lines(b, off)
	}
	if f == 6 {
		return textfont_cmap_f6_lines(b, off)
	}
	if f == 12 {
		return textfont_cmap_f12_lines(b, off)
	}
	if f == 14 {
		return textfont_cmap_f14_lines(b, off)
	}
	return none
}

// textfont_cmap_f0_lines renders format 0: language plus 256 glyph ids.
fn textfont_cmap_f0_lines(b []u8, off int) ?([]string, int) {
	if off + 518 > b.len || int(u16_be(b, off + 2)) != 518 {
		return none
	}
	return [
		'language ${u16_be(b, off + 4)}',
		'glyph-ids ${b[off + 6..off + 518].hex()}',
	], 518
}

// textfont_cmap_f4_lines renders format 4: language, the reserved pad, one
// segment line per segment (start/end codepoints, signed delta, range offset),
// and the glyph id array as one verbatim blob. The blob is never interpreted,
// so shared and overlapping glyph runs survive byte-identically.
fn textfont_cmap_f4_lines(b []u8, off int) ?([]string, int) {
	if off + 16 > b.len {
		return none
	}
	flen := int(u16_be(b, off + 2))
	sc := int(u16_be(b, off + 6)) >> 1
	if sc <= 0 || flen < 16 + 8 * sc || off + flen > b.len {
		return none
	}
	want_sr, want_es, want_rs := textfont_std_search(sc)
	if int(u16_be(b, off + 8)) != want_sr || int(u16_be(b, off + 10)) != want_es
		|| int(u16_be(b, off + 12)) != want_rs {
		return none
	}
	if off + 16 + 8 * sc > b.len {
		return none
	}
	mut out := []string{cap: sc + 3}
	out << 'language ${u16_be(b, off + 4)}'
	out << 'reserved-pad ${u16_be(b, off + 14 + sc * 2)}'
	for s in 0 .. sc {
		start := u16_be(b, off + 16 + sc * 2 + s * 2)
		end := u16_be(b, off + 14 + s * 2)
		delta := textfont_ri16(b, off + 16 + sc * 4 + s * 2)
		range_off := u16_be(b, off + 16 + sc * 6 + s * 2)
		out << 'segment ${textfont_cp_str(u32(start))} ${textfont_cp_str(u32(end))} ${delta} ${range_off}'
	}
	out << 'glyph-ids ${b[off + 16 + 8 * sc..off + flen].hex()}'
	return out, flen
}

// textfont_cmap_f6_lines renders format 6: language, first code plus the
// glyph array.
fn textfont_cmap_f6_lines(b []u8, off int) ?([]string, int) {
	if off + 10 > b.len {
		return none
	}
	flen := int(u16_be(b, off + 2))
	cnt := int(u16_be(b, off + 8))
	if flen != 10 + 2 * cnt || off + flen > b.len {
		return none
	}
	return [
		'language ${u16_be(b, off + 4)}',
		'first-code ${textfont_cp_str(u32(u16_be(b, off + 6)))}',
		'glyph-ids ${b[off + 10..off + flen].hex()}',
	], flen
}

// textfont_cmap_f12_lines renders format 12: reserved, language plus coverage
// groups.
fn textfont_cmap_f12_lines(b []u8, off int) ?([]string, int) {
	if off + 16 > b.len {
		return none
	}
	flen := int(u32_be(b, off + 4))
	ng := int(u32_be(b, off + 12))
	if flen != 16 + 12 * ng || off + flen > b.len {
		return none
	}
	mut out := []string{cap: ng + 2}
	out << 'reserved ${u16_be(b, off + 2)}'
	out << 'language ${u32_be(b, off + 8)}'
	for g in 0 .. ng {
		at := off + 16 + g * 12
		out << 'group ${textfont_cp_str(u32_be(b, at))} ${textfont_cp_str(u32_be(b, at + 4))} ${u32_be(b, at + 8)}'
	}
	return out, flen
}

// textfont_cmap_f14_table is one deduplicated format 14 backing table.
struct TextfontCmapF14Table {
	off     int
	is_def  bool
	count   int
	tableln int
}

// textfont_cmap_f14_lines renders format 14: the record-count field, the
// unique backing tables in offset order (default ranges, non-default
// mappings), then one record line per selector naming its two tables by id or
// -1. Sharing is preserved by the ids, and the encoder requires the tables to
// tile the subtable tail exactly, which the corpus all does.
fn textfont_cmap_f14_lines(b []u8, off int) ?([]string, int) {
	if off + 10 > b.len {
		return none
	}
	olen := int(u32_be(b, off + 2))
	if olen < 10 || off + olen > b.len {
		return none
	}
	mut sels := []u32{cap: 16}
	mut doffs := []int{cap: 16}
	mut noffs := []int{cap: 16}
	for {
		at := off + 10 + sels.len * 11
		if at + 11 > b.len {
			return none
		}
		doff := int(u32_be(b, at + 3))
		noff := int(u32_be(b, at + 7))
		if doff >= olen || noff >= olen {
			break
		}
		sels << textfont_u24(b, at)
		doffs << doff
		noffs << noff
		if sels.len > 2048 {
			return none
		}
	}
	rec_end := off + 10 + sels.len * 11
	mut tables := []TextfontCmapF14Table{}
	for k in 0 .. sels.len {
		if doffs[k] != 0 {
			abs := off + doffs[k]
			if abs + 4 > b.len {
				return none
			}
			tables << TextfontCmapF14Table{
				off:     abs
				is_def:  true
				count:   int(u32_be(b, abs))
				tableln: 4 + 4 * int(u32_be(b, abs))
			}
		}
		if noffs[k] != 0 {
			abs := off + noffs[k]
			if abs + 4 > b.len {
				return none
			}
			tables << TextfontCmapF14Table{
				off:     abs
				is_def:  false
				count:   int(u32_be(b, abs))
				tableln: 4 + 5 * int(u32_be(b, abs))
			}
		}
	}
	tables.sort(a.off < b.off)
	// Deduplicate shared tables by offset; an offset serving both kinds is
	// ambiguous and refuses the block.
	mut uniq := []TextfontCmapF14Table{}
	for t in tables {
		if t.off + t.tableln > b.len || t.off < rec_end || t.off + t.tableln > off + olen {
			return none
		}
		if uniq.len > 0 && uniq[uniq.len - 1].off == t.off {
			prev := uniq[uniq.len - 1]
			if prev.is_def != t.is_def || prev.count != t.count {
				return none
			}
			continue
		}
		uniq << t
	}
	mut cursor := rec_end
	for t in uniq {
		if t.off != cursor {
			return none
		}
		cursor += t.tableln
	}
	if cursor != off + olen {
		return none
	}
	mut out := []string{}
	out << 'record-count ${u32_be(b, off + 6)}'
	for ui, t in uniq {
		if t.is_def {
			out << 'default-table ${ui}'
			for r in 0 .. t.count {
				at := t.off + 4 + r * 4
				out << 'default-range ${textfont_cp_str(textfont_u24(b, at))} ${b[at + 3]}'
			}
		} else {
			out << 'mapping-table ${ui}'
			for r in 0 .. t.count {
				at := t.off + 4 + r * 5
				out << 'mapping ${textfont_cp_str(textfont_u24(b, at))} ${u16_be(b, at + 3)}'
			}
		}
	}
	for k in 0 .. sels.len {
		mut di := -1
		mut ni := -1
		for ui, t in uniq {
			if doffs[k] != 0 && t.off == off + doffs[k] {
				di = ui
			}
			if noffs[k] != 0 && t.off == off + noffs[k] {
				ni = ui
			}
		}
		if (doffs[k] != 0 && di < 0) || (noffs[k] != 0 && ni < 0) {
			return none
		}
		out << 'record ${textfont_cp_str(sels[k])} ${di} ${ni}'
	}
	return out, olen
}

// textfont_cmap_build rebuilds cmap: stored version, encoding records in
// dumped order with recomputed offsets, unique subtables packed in id order.
fn textfont_cmap_build(fields []string) ![]u8 {
	mut cur := TextfontCursor{}
	ver_parts := textfont_take(fields, mut cur, 'version')!
	textfont_arity(ver_parts, 1)!
	ver := textfont_f_u16(ver_parts, 0)!
	mut plats := []u16{}
	mut encs := []u16{}
	mut ids := []int{}
	for cur.pos < fields.len {
		word := fields[cur.pos].split(' ')[0]
		if word != 'encoding' {
			break
		}
		head := textfont_take(fields, mut cur, 'encoding')!
		textfont_arity(head, 3)!
		plats << textfont_f_u16(head, 0)!
		encs << textfont_f_u16(head, 1)!
		id := int(textfont_f_u64(head, 2)!)
		if id < 0 {
			return error('textfont: bad cmap subtable reference')
		}
		ids << id
	}
	if plats.len == 0 {
		return error('textfont: cmap wants encodings')
	}
	mut subs := [][]u8{}
	for cur.pos < fields.len {
		head := textfont_take(fields, mut cur, 'subtable')!
		textfont_arity(head, 2)!
		if int(textfont_f_u64(head, 0)!) != subs.len {
			return error('textfont: cmap subtable out of order')
		}
		f := int(textfont_f_u64(head, 1)!)
		subs << textfont_cmap_sub_build(fields, mut cur, f)!
	}
	if subs.len == 0 {
		return error('textfont: cmap wants subtables')
	}
	for id in ids {
		if id >= subs.len {
			return error('textfont: cmap encoding points past its subtables')
		}
	}
	mut out := []u8{cap: 64}
	textfont_w16(mut out, ver)
	textfont_w16(mut out, u16(plats.len))
	mut at := 4 + 8 * plats.len
	mut sub_offs := []int{cap: subs.len}
	for s in subs {
		sub_offs << at
		at += s.len
	}
	for i in 0 .. plats.len {
		textfont_w16(mut out, plats[i])
		textfont_w16(mut out, encs[i])
		textfont_w32(mut out, u32(sub_offs[ids[i]]))
	}
	for s in subs {
		out << s
	}
	return out
}

// textfont_cmap_sub_build rebuilds one subtable; the format selects the shape.
fn textfont_cmap_sub_build(fields []string, mut cur TextfontCursor, f int) ![]u8 {
	if f == 0 {
		return textfont_cmap_f0_build(fields, mut cur)
	}
	if f == 4 {
		return textfont_cmap_f4_build(fields, mut cur)
	}
	if f == 6 {
		return textfont_cmap_f6_build(fields, mut cur)
	}
	if f == 12 {
		return textfont_cmap_f12_build(fields, mut cur)
	}
	if f == 14 {
		return textfont_cmap_f14_build(fields, mut cur)
	}
	return error('textfont: unknown cmap format ${f}')
}

// textfont_cmap_f0_build rebuilds format 0: exactly 256 glyph ids.
fn textfont_cmap_f0_build(fields []string, mut cur TextfontCursor) ![]u8 {
	mut out := []u8{cap: 518}
	textfont_w16(mut out, 0)
	textfont_w16(mut out, 518)
	textfont_w16(mut out, textfont_f_u16(textfont_take(fields, mut cur, 'language')!, 0)!)
	blob_parts := textfont_take(fields, mut cur, 'glyph-ids')!
	textfont_arity(blob_parts, 1)!
	blob := textfont_hex_decode(blob_parts[0])!
	if blob.len != 512 {
		return error('textfont: format 0 wants 256 glyph ids')
	}
	out << blob
	return out
}

// textfont_cmap_f4_build rebuilds format 4 with specification search
// parameters. The glyph blob is copied verbatim, so whatever layout the
// original packed is what comes back.
fn textfont_cmap_f4_build(fields []string, mut cur TextfontCursor) ![]u8 {
	lang_parts := textfont_take(fields, mut cur, 'language')!
	textfont_arity(lang_parts, 1)!
	lang := textfont_f_u16(lang_parts, 0)!
	pad_parts := textfont_take(fields, mut cur, 'reserved-pad')!
	textfont_arity(pad_parts, 1)!
	pad := textfont_f_u16(pad_parts, 0)!
	mut starts := []u16{}
	mut ends := []u16{}
	mut deltas := []i16{}
	mut ranges := []u16{}
	mut blob := []u8{}
	for {
		if cur.pos >= fields.len {
			return error('textfont: format 4 wants segments or glyph-ids')
		}
		word := fields[cur.pos].split(' ')[0]
		if word == 'glyph-ids' {
			blob_parts := textfont_take(fields, mut cur, 'glyph-ids')!
			textfont_arity(blob_parts, 1)!
			blob = textfont_hex_decode(blob_parts[0])!
			break
		}
		if word != 'segment' {
			return error('textfont: want `segment` line')
		}
		seg := textfont_take(fields, mut cur, 'segment')!
		textfont_arity(seg, 4)!
		start := textfont_parse_cp(seg[0])!
		end := textfont_parse_cp(seg[1])!
		if start > 0xffff || end > 0xffff {
			return error('textfont: format 4 segment out of range')
		}
		starts << u16(start)
		ends << u16(end)
		deltas << textfont_f_i16(seg, 2)!
		ranges << textfont_f_u16(seg, 3)!
		if starts.len > 100000 {
			return error('textfont: too many format 4 segments')
		}
	}
	sc := starts.len
	if sc == 0 {
		return error('textfont: format 4 wants segments')
	}
	sr, es, rs := textfont_std_search(sc)
	mut out := []u8{cap: 16 + 8 * sc + blob.len}
	textfont_w16(mut out, 4)
	textfont_w16(mut out, u16(16 + 8 * sc + blob.len))
	textfont_w16(mut out, lang)
	textfont_w16(mut out, u16(sc * 2))
	textfont_w16(mut out, u16(sr))
	textfont_w16(mut out, u16(es))
	textfont_w16(mut out, u16(rs))
	for e in ends {
		textfont_w16(mut out, e)
	}
	textfont_w16(mut out, pad)
	for s in starts {
		textfont_w16(mut out, s)
	}
	for d in deltas {
		textfont_wi16(mut out, d)
	}
	for r in ranges {
		textfont_w16(mut out, r)
	}
	out << blob
	return out
}

// textfont_cmap_f6_build rebuilds format 6.
fn textfont_cmap_f6_build(fields []string, mut cur TextfontCursor) ![]u8 {
	lang_parts := textfont_take(fields, mut cur, 'language')!
	textfont_arity(lang_parts, 1)!
	lang := textfont_f_u16(lang_parts, 0)!
	first_parts := textfont_take(fields, mut cur, 'first-code')!
	textfont_arity(first_parts, 1)!
	first := textfont_parse_cp(first_parts[0])!
	if first > 0xffff {
		return error('textfont: format 6 first code out of range')
	}
	blob_parts := textfont_take(fields, mut cur, 'glyph-ids')!
	textfont_arity(blob_parts, 1)!
	blob := textfont_hex_decode(blob_parts[0])!
	mut out := []u8{cap: 10 + blob.len}
	textfont_w16(mut out, 6)
	textfont_w16(mut out, u16(10 + blob.len))
	textfont_w16(mut out, lang)
	textfont_w16(mut out, u16(first))
	textfont_w16(mut out, u16(blob.len / 2))
	out << blob
	return out
}

// textfont_cmap_f12_build rebuilds format 12: stored reserved and language,
// recomputed length and group count.
fn textfont_cmap_f12_build(fields []string, mut cur TextfontCursor) ![]u8 {
	res_parts := textfont_take(fields, mut cur, 'reserved')!
	textfont_arity(res_parts, 1)!
	reserved := textfont_f_u16(res_parts, 0)!
	lang_parts := textfont_take(fields, mut cur, 'language')!
	textfont_arity(lang_parts, 1)!
	lang := textfont_f_u32(lang_parts, 0)!
	mut groups := [][]u32{}
	for {
		if cur.pos >= fields.len {
			break
		}
		word := fields[cur.pos].split(' ')[0]
		if word != 'group' {
			break
		}
		g := textfont_take(fields, mut cur, 'group')!
		textfont_arity(g, 3)!
		groups << [textfont_parse_cp(g[0])!, textfont_parse_cp(g[1])!, textfont_f_u32(g,
			2)!]
		if groups.len > 1000000 {
			return error('textfont: too many format 12 groups')
		}
	}
	mut out := []u8{cap: 16 + 12 * groups.len}
	textfont_w16(mut out, 12)
	textfont_w16(mut out, reserved)
	textfont_w32(mut out, u32(16 + 12 * groups.len))
	textfont_w32(mut out, lang)
	textfont_w32(mut out, u32(groups.len))
	for g in groups {
		textfont_w32(mut out, g[0])
		textfont_w32(mut out, g[1])
		textfont_w32(mut out, g[2])
	}
	return out
}

// textfont_cmap_f14_build rebuilds format 14: tables packed in dumped order
// after the records, record offsets recomputed. Table ids and the
// record-count field are stored; lengths are recomputed.
fn textfont_cmap_f14_build(fields []string, mut cur TextfontCursor) ![]u8 {
	nrec_parts := textfont_take(fields, mut cur, 'record-count')!
	textfont_arity(nrec_parts, 1)!
	nrec_field := textfont_f_u32(nrec_parts, 0)!
	// Tables are dumped in offset order with sequential ids sharing one id
	// space across both kinds, so the walk records each id's kind; the packed
	// rebuild follows id order exactly.
	mut id_is_def := []bool{}
	mut def_ranges := []u32{}
	mut def_lens := []u32{}
	mut map_bases := []u32{}
	mut map_gids := []u16{}
	mut def_counts := []int{}
	mut map_counts := []int{}
	for cur.pos < fields.len {
		word := fields[cur.pos].split(' ')[0]
		if word == 'default-table' {
			head := textfont_take(fields, mut cur, 'default-table')!
			textfont_arity(head, 1)!
			if textfont_f_u64(head, 0)! != u64(id_is_def.len) {
				return error('textfont: format 14 table out of order')
			}
			id_is_def << true
			def_counts << 0
			for cur.pos < fields.len {
				w := fields[cur.pos].split(' ')[0]
				if w != 'default-range' {
					break
				}
				g := textfont_take(fields, mut cur, 'default-range')!
				textfont_arity(g, 2)!
				def_ranges << textfont_parse_cp(g[0])!
				ln := textfont_f_u64(g, 1)!
				if ln > 255 {
					return error('textfont: default range too long')
				}
				def_lens << u32(ln)
				def_counts[def_counts.len - 1]++
			}
		} else if word == 'mapping-table' {
			head := textfont_take(fields, mut cur, 'mapping-table')!
			textfont_arity(head, 1)!
			if textfont_f_u64(head, 0)! != u64(id_is_def.len) {
				return error('textfont: format 14 table out of order')
			}
			id_is_def << false
			map_counts << 0
			for cur.pos < fields.len {
				w := fields[cur.pos].split(' ')[0]
				if w != 'mapping' {
					break
				}
				g := textfont_take(fields, mut cur, 'mapping')!
				textfont_arity(g, 2)!
				map_bases << textfont_parse_cp(g[0])!
				map_gids << textfont_f_u16(g, 1)!
				map_counts[map_counts.len - 1]++
			}
		} else {
			break
		}
	}
	mut sels := []u32{}
	mut dis := []int{}
	mut nis := []int{}
	for cur.pos < fields.len {
		w := fields[cur.pos].split(' ')[0]
		if w != 'record' {
			break
		}
		g := textfont_take(fields, mut cur, 'record')!
		textfont_arity(g, 3)!
		sel := textfont_parse_cp(g[0])!
		if sel > 0xffffff {
			return error('textfont: variation selector out of range')
		}
		di := int(textfont_f_i64(g, 1)!)
		ni := int(textfont_f_i64(g, 2)!)
		if di < -1 || ni < -1 || di >= id_is_def.len || ni >= id_is_def.len {
			return error('textfont: bad format 14 table reference')
		}
		if di >= 0 && !id_is_def[di] {
			return error('textfont: format 14 default points at a mapping table')
		}
		if ni >= 0 && id_is_def[ni] {
			return error('textfont: format 14 mapping points at a default table')
		}
		sels << sel
		dis << di
		nis << ni
	}
	// The record-count field is stored, not recomputed or cross-checked: the
	// reader scans records rather than trusting it, so a field that disagrees
	// with the scan still rebuilds to the same bytes.
	// Pack: header(10) + records, then tables in id order with recomputed
	// offsets. The encoder verified the original tiles exactly this way, so
	// the recomputed offsets reproduce the original bytes.
	mut table_offs := []int{cap: id_is_def.len}
	mut cursor := 10 + 11 * sels.len
	mut def_seen := 0
	mut map_seen := 0
	for id in 0 .. id_is_def.len {
		table_offs << cursor
		if id_is_def[id] {
			n := def_counts[def_seen]
			def_seen++
			cursor += 4 + 4 * n
		} else {
			n := map_counts[map_seen]
			map_seen++
			cursor += 4 + 5 * n
		}
	}
	mut out := []u8{cap: cursor}
	textfont_w16(mut out, 14)
	textfont_w32(mut out, u32(cursor))
	textfont_w32(mut out, nrec_field)
	mut def_rpos := 0
	mut map_rpos := 0
	for k in 0 .. sels.len {
		mut doff := 0
		mut noff := 0
		if dis[k] >= 0 {
			doff = table_offs[dis[k]]
		}
		if nis[k] >= 0 {
			noff = table_offs[nis[k]]
		}
		out << u8((sels[k] >> 16) & 0xff)
		out << u8((sels[k] >> 8) & 0xff)
		out << u8(sels[k] & 0xff)
		textfont_w32(mut out, u32(doff))
		textfont_w32(mut out, u32(noff))
	}
	def_seen = 0
	map_seen = 0
	for id in 0 .. id_is_def.len {
		if id_is_def[id] {
			n := def_counts[def_seen]
			def_seen++
			textfont_w32(mut out, u32(n))
			for r in 0 .. n {
				cp := def_ranges[def_rpos]
				ln := def_lens[def_rpos]
				def_rpos++
				out << u8((cp >> 16) & 0xff)
				out << u8((cp >> 8) & 0xff)
				out << u8(cp & 0xff)
				out << u8(ln)
			}
		} else {
			n := map_counts[map_seen]
			map_seen++
			textfont_w32(mut out, u32(n))
			for r in 0 .. n {
				base := map_bases[map_rpos]
				gid := map_gids[map_rpos]
				map_rpos++
				out << u8((base >> 16) & 0xff)
				out << u8((base >> 8) & 0xff)
				out << u8(base & 0xff)
				textfont_w16(mut out, gid)
			}
		}
	}
	return out
}
