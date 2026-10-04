module vtext

// Reader is a bounds-checked big-endian view over a byte slice.
//
// Reads are positional rather than cursor-based: font tables are addressed by
// offsets from a table directory, so a cursor buys nothing and would force a
// mutable receiver on every accessor.
//
// Font data comes from untrusted files, so every read is clamped: going past
// the end yields zero rather than panicking. Use has() when a zero and an
// absent byte must be told apart.
// imin returns the smaller of two ints. V has no int.min in this version.
fn imin(a int, b int) int {
	return if a < b { a } else { b }
}

// imax returns the larger of two ints.
fn imax(a int, b int) int {
	return if a > b { a } else { b }
}

// u16_be reads a big-endian u16 at off, returning 0 when out of bounds.
fn u16_be(data []u8, off int) u16 {
	if off < 0 || off + 2 > data.len {
		return 0
	}
	return (u16(data[off]) << 8) | u16(data[off + 1])
}

// u32_be reads a big-endian u32 at off, returning 0 when out of bounds.
fn u32_be(data []u8, off int) u32 {
	if off < 0 || off + 4 > data.len {
		return 0
	}
	return (u32(u16_be(data, off)) << 16) | u32(u16_be(data, off + 2))
}

struct Reader {
	data []u8
}

fn new_reader(data []u8) Reader {
	return Reader{
		data: data
	}
}

fn (r &Reader) len() int {
	return r.data.len
}

// has reports whether off .. off+n lies fully inside the buffer.
fn (r &Reader) has(off int, n int) bool {
	return off >= 0 && n >= 0 && off + n <= r.data.len
}

fn (r &Reader) u8_at(off int) u8 {
	return if r.has(off, 1) { r.data[off] } else { 0 }
}

fn (r &Reader) u16_at(off int) u16 {
	return u16_be(r.data, off)
}

fn (r &Reader) i16_at(off int) i16 {
	v := int(r.u16_at(off))
	return i16(if v >= 0x8000 { v - 0x10000 } else { v })
}

fn (r &Reader) u32_at(off int) u32 {
	return u32_be(r.data, off)
}

// u24_at reads a big-endian 24-bit value at off.
//
// cmap formats 13 and 14 store codepoints as uint24, which is a specification quirk rather than a
// space-saving one: a codepoint fits in 21 bits and the format's own authors still wrote three bytes.
// Both formats are read through here.
//
// The width matters more than it looks. A uint24 read as a uint32 picks up the following byte as its
// low byte, so a codepoint at the end of a table reads as a different and much larger codepoint — one
// that is not in the table and therefore answers "no opinion" instead of an error. Reading it as a
// uint16 instead loses the top eight bits and collides codepoints a quarter of a million apart.
fn (r &Reader) u24_at(off int) u32 {
	if !r.has(off, 3) {
		return 0
	}
	return (u32(r.u8_at(off)) << 16) | (u32(r.u8_at(off + 1)) << 8) | u32(r.u8_at(off + 2))
}

fn (r &Reader) i32_at(off int) i32 {
	v := i64(r.u32_at(off))
	return i32(if v >= 0x80000000 { v - 0x100000000 } else { v })
}

fn (r &Reader) u64_at(off int) u64 {
	return (u64(r.u32_at(off)) << 32) | u64(r.u32_at(off + 4))
}

// tag_at reads the 4-byte table tag at off as a string. Non-printable bytes
// become '.', which keeps malformed tags visible in diagnostics.
fn (r &Reader) tag_at(off int) string {
	return tag_from_bytes(r.data, off)
}

// tag_from_bytes renders 4 bytes as an ASCII tag, substituting '.' for
// anything unprintable.
fn tag_from_bytes(data []u8, off int) string {
	mut out := []u8{len: 4}
	for i in 0 .. 4 {
		b := if off + i >= 0 && off + i < data.len { data[off + i] } else { u8(0) }
		out[i] = if b >= 0x20 && b < 0x7f { b } else { u8(`.`) }
	}
	return out.bytestr()
}
