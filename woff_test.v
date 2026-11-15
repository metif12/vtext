module vtext

import vtext.shape
import vtext.font
import compress.zlib
import os

// This file is self-contained: every helper it needs is defined here with a
// woff_ prefix, so `v test woff_test.v` compiles this file alone. The prefix
// is what keeps the full suite compiling too — font_test.v already owns the
// unprefixed names.

// woff_corpus_font_path is where a named font is: the committed corpus first,
// the platform's own font directory second, and none when neither has it.
fn woff_corpus_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('VTEXT_TEST_FONTS'), 'testdata/fonts', woff_windows_font_dir()] {
		if d != '' && d !in dirs {
			dirs << d
		}
	}
	for dir in dirs {
		p := os.join_path(dir, name)
		if os.exists(p) {
			return p
		}
	}
	return none
}

fn woff_corpus_font_bytes(name string) ?[]u8 {
	p := woff_corpus_font_path(name) or { return none }
	return os.read_bytes(p) or { panic('${p} is not readable: ${err}') }
}

$if windows {
	fn woff_windows_font_dir() string {
		return 'C:\\Windows\\Fonts'
	}
} $else {
	fn woff_windows_font_dir() string {
		return ''
	}
}

// woff_skip_missing prints why a test cannot run. A skip that prints nothing
// is a failure pretending to be a pass.
fn woff_skip_missing(name string) {
	line := 'SKIP ${name} is in neither testdata/fonts nor the platform font directory'
	path := os.getenv('VTEXT_SKIP_LOG')
	if path != '' {
		mut f := os.open_append(path) or { return }
		f.writeln(line) or { return }
		f.close()
		return
	}
	println(line)
}

fn woff_put_u16(mut b []u8, v u16) {
	b << u8(v >> 8)
	b << u8(v & 0xff)
}

fn woff_put_u32(mut b []u8, v u32) {
	b << u8(v >> 24)
	b << u8((v >> 16) & 0xff)
	b << u8((v >> 8) & 0xff)
	b << u8(v & 0xff)
}

// woff_file_sum is the sfnt whole-file checksum: the sum of big-endian u32
// words, tail padded with zeros. A valid sfnt sums to 0xB1B0AFBA.
fn woff_file_sum(data []u8) u32 {
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

// woff_tiny_sfnt builds a minimal two-table sfnt: 'head' with 8 bytes and
// 'data' with 5, the odd length exercising the 4-byte padding on rebuild.
fn woff_tiny_sfnt() ([]u8, []u8, []u8) {
	head := [u8(1), 2, 3, 4, 5, 6, 7, 8]
	payload := [u8(9), 10, 11, 12, 13]
	mut sfnt := []u8{}
	woff_put_u32(mut sfnt, 0x00010000)
	woff_put_u16(mut sfnt, 2)
	woff_put_u16(mut sfnt, 32)
	woff_put_u16(mut sfnt, 1)
	woff_put_u16(mut sfnt, 0)
	sfnt << 'head'.bytes()
	// The directory checksums are the real ones: the reader recomputes them
	// from the inflated bytes (proving it against the 0xdeadbeef the WOFF
	// header carries), so a zeroed fixture would fail the byte comparison.
	// head sums to 0x01020304 + 0x05060708 = 0x06080A0C.
	woff_put_u32(mut sfnt, 0x06080A0C)
	woff_put_u32(mut sfnt, 44)
	woff_put_u32(mut sfnt, 8)
	sfnt << 'data'.bytes()
	// data sums to 0x090A0B0C + 0x0D000000 (padded tail) = 0x160A0B0C.
	woff_put_u32(mut sfnt, 0x160A0B0C)
	woff_put_u32(mut sfnt, 52)
	woff_put_u32(mut sfnt, 5)
	sfnt << head
	sfnt << payload
	return sfnt, head, payload
}

// woff_wrap packs sfnt's two tables into a WOFF1 file: 'head' compressed,
// 'data' stored raw. The stored origChecksum is deliberately wrong
// (0xdeadbeef) to prove the reader recomputes checksums instead of trusting
// the header.
fn woff_wrap(sfnt []u8, head []u8, payload []u8) []u8 {
	comp := zlib.compress(head) or { panic(err) }
	head_off := 44 + 2 * 20
	data_off := head_off + comp.len
	mut woff := []u8{}
	woff << 'wOFF'.bytes()
	woff_put_u32(mut woff, 0x00010000)
	woff_put_u32(mut woff, u32(data_off + payload.len))
	woff_put_u16(mut woff, 2)
	woff_put_u16(mut woff, 0)
	woff_put_u32(mut woff, u32(sfnt.len))
	woff_put_u16(mut woff, 1)
	woff_put_u16(mut woff, 0)
	// metaOffset, metaLength, metaOrigLength, privOffset, privLength: none
	// present. Skipped by the reader: they carry descriptions, not shaping data.
	for _ in 0 .. 5 {
		woff_put_u32(mut woff, 0)
	}
	woff << 'head'.bytes()
	woff_put_u32(mut woff, u32(head_off))
	woff_put_u32(mut woff, u32(comp.len))
	woff_put_u32(mut woff, u32(head.len))
	woff_put_u32(mut woff, 0xdeadbeef)
	woff << 'data'.bytes()
	woff_put_u32(mut woff, u32(data_off))
	woff_put_u32(mut woff, u32(payload.len))
	woff_put_u32(mut woff, u32(payload.len))
	woff_put_u32(mut woff, 0xdeadbeef)
	woff << comp
	woff << payload
	return woff
}

// The unwrap of a hand-built WOFF is the sfnt byte for byte, and the
// directory checksums are recomputed rather than copied from the header.
// The 8-byte 'head' also exercises the adjustment skip: too short to hold a
// checkSumAdjustment, it is copied verbatim.
fn test_woff_round_trip_minimal() {
	sfnt, head, payload := woff_tiny_sfnt()
	woff := woff_wrap(sfnt, head, payload)
	out := font.woff_to_sfnt(woff) or { panic(err) }
	assert out == sfnt, 'unwrapped WOFF differs from the sfnt it wraps'
	parsed := font.parse_sfnt(out) or { panic(err) }
	assert parsed.tables.len == 2
	assert parsed.table_data('head') == head
	assert parsed.table_data('data') == payload
}

// A compressed table must actually be inflated: its bytes in the rebuilt sfnt
// equal the original table, which is false when the zlib step is bypassed —
// raw deflate bytes differ in both length and content.
fn test_woff_compressed_table_is_inflated() {
	sfnt, head, _ := woff_tiny_sfnt()
	comp := zlib.compress(head) or { panic(err) }
	assert comp.len != head.len, 'fixture needs a table that actually compresses'
	woff := woff_wrap(sfnt, head, [u8(9), 10, 11, 12, 13])
	out := font.woff_to_sfnt(woff) or { panic(err) }
	parsed := font.parse_sfnt(out) or { panic(err) }
	assert parsed.table_data('head') == head, 'table holds deflate bytes: the zlib step was bypassed'
}

// Every truncation errors: short header, cut directory, cut payload.
fn test_woff_refuses_truncation() {
	sfnt, head, payload := woff_tiny_sfnt()
	woff := woff_wrap(sfnt, head, payload)
	for cut in [0, 3, 4, 43, 44, 44 + 20, 44 + 40 - 1, woff.len - 1] {
		if _ := font.woff_to_sfnt(woff[..cut]) {
			assert false, 'truncated WOFF (first ${cut} bytes) parsed without error'
		}
	}
	// A zero table count is refused, not built into an empty sfnt.
	mut zero := woff.clone()
	zero[12] = 0
	zero[13] = 0
	if _ := font.woff_to_sfnt(zero) {
		assert false, 'zero table count parsed without error'
	}
	// A count past what the u16 search parameters can hold is refused even
	// when the file is big enough to hold its directory.
	mut huge := woff.clone()
	huge << []u8{len: 100000}
	huge[12] = 16
	huge[13] = 0
	if _ := font.woff_to_sfnt(huge) {
		assert false, 'oversized table count parsed without error'
	}
	// A compLength reaching past the file end overruns it.
	mut over := woff.clone()
	mut big := []u8{}
	woff_put_u32(mut big, u32(woff.len + 100))
	for k in 0 .. 4 {
		over[44 + 4 + k] = big[k]
	}
	if _ := font.woff_to_sfnt(over) {
		assert false, 'overrunning compLength parsed without error'
	}
	// An origLength the payload cannot inflate to is refused, not padded.
	mut wrong := woff.clone()
	mut len8 := []u8{}
	woff_put_u32(mut len8, u32(head.len + 1))
	for k in 0 .. 4 {
		wrong[44 + 12 + k] = len8[k]
	}
	if _ := font.woff_to_sfnt(wrong) {
		assert false, 'mismatched origLength parsed without error'
	}
}

// Corrupting one compressed byte errors — the Adler-32 no longer matches —
// rather than decoding to silent garbage.
fn test_woff_refuses_corrupt_payload() {
	sfnt, head, payload := woff_tiny_sfnt()
	mut woff := woff_wrap(sfnt, head, payload)
	head_off := 44 + 2 * 20
	woff[head_off + 2] ^= 0xff
	if _ := font.woff_to_sfnt(woff) {
		assert false, 'corrupt deflate payload decoded without error'
	}
}

// WOFF2 is a clean refusal with the reason in the message: brotli, and no
// decoder for it lives in this tree.
fn test_woff2_refused_with_reason() {
	mut fake := []u8{len: 44}
	fake[0] = `w`
	fake[1] = `O`
	fake[2] = `F`
	fake[3] = `2`
	assert font.is_woff2(fake), 'wOF2 magic not recognised'
	assert !font.is_woff(fake), 'wOF2 misread as WOFF1'
	if _ := font.woff_to_sfnt(fake) {
		assert false, 'WOFF2 parsed without error'
	} else {
		assert err.msg().contains('brotli'), 'WOFF2 refusal names no reason: ${err}'
	}
	if _ := font.maybe_woff_to_sfnt(fake) {
		assert false, 'WOFF2 passed the load path without error'
	}
}

// Non-WOFF bytes pass through untouched, so the load path on plain TTF bytes
// is the bytes it was always given.
fn test_non_woff_passes_through() {
	sfnt, _, _ := woff_tiny_sfnt()
	assert !font.is_woff(sfnt)
	assert !font.is_woff2(sfnt)
	out := font.maybe_woff_to_sfnt(sfnt) or { panic(err) }
	assert out == sfnt, 'plain sfnt bytes were altered on the load path'
	if _ := font.woff_to_sfnt(sfnt) {
		assert false, 'plain sfnt parsed as WOFF'
	}
}

// The real font: Amiri converted to WOFF1 with fontTools
// (python -c "from fontTools.ttLib import TTFont; f = TTFont('Amiri-Regular.ttf'); f.flavor = 'woff'; f.save('Amiri-Regular.woff')").
// The OFL licence already committed as OFL-Amiri.txt covers the conversion:
// it is the same font in another container, not a new work.
fn test_woff_amiri_matches_ttf() {
	ttf := woff_corpus_font_bytes('Amiri-Regular.ttf') or {
		woff_skip_missing('Amiri-Regular.ttf')
		return
	}
	woff := woff_corpus_font_bytes('Amiri-Regular.woff') or {
		woff_skip_missing('Amiri-Regular.woff')
		return
	}
	// Positive control: the plain TTF loads on the same path, unchanged.
	tf := shape.load_font_bytes(ttf) or { panic(err) }
	wf := shape.load_font_bytes(woff) or { panic(err) }
	assert wf.face.sfnt.tables.len == tf.face.sfnt.tables.len, 'table count differs'
	assert wf.num_glyphs() == tf.num_glyphs(), 'glyph count differs'
	assert wf.units_per_em() == tf.units_per_em(), 'units per em differs'
	// Same tables, same bytes: the container changed, the font did not.
	// 'head' carries one principled exception: checkSumAdjustment binds the
	// whole file, and the rebuild moves every table, so it is recalculated
	// (as fontTools does on de-woffing) rather than copied. Bytes [8..12]
	// are therefore compared around, and the whole rebuilt file must sum to
	// the spec magic 0xB1B0AFBA below.
	for tag in ['head', 'hhea', 'maxp', 'cmap', 'hmtx', 'glyf', 'loca', 'GSUB', 'GPOS'] {
		if tag in tf.face.sfnt.tables {
			assert tag in wf.face.sfnt.tables, 'WOFF lost table ${tag}'
			if tag == 'head' {
				// checkSumAdjustment [8..12] binds the whole file and is
				// recalculated (as fontTools does on de-woffing); modified
				// [28..36] is restamped to the save time by fontTools on WOFF
				// save. Both are metadata the engine never reads; created is
				// preserved by the converter and everything else must match.
				assert wf.face.sfnt.table_data(tag)[..8] == tf.face.sfnt.table_data(tag)[..8], 'head prefix differs'
				assert wf.face.sfnt.table_data(tag)[12..28] == tf.face.sfnt.table_data(tag)[12..28], 'head middle differs'
				assert wf.face.sfnt.table_data(tag)[36..] == tf.face.sfnt.table_data(tag)[36..], 'head suffix differs'
			} else {
				assert wf.face.sfnt.table_data(tag) == tf.face.sfnt.table_data(tag), 'table ${tag} differs after unwrap'
			}
		}
	}
	assert woff_file_sum(wf.data()) == u32(0xB1B0AFBA), 'rebuilt sfnt fails the whole-file checksum'
	// Sampled cmap and advances agree.
	for cp in [`A`, `a`, ` `, `ب`, `س`, `ل`, `ا`, `م`] {
		assert wf.face.glyph_index(cp) == tf.face.glyph_index(cp), 'U+${cp:04X} maps differently'
	}
	for gid in [u16(0), u16(1), u16(2), u16(10), u16(100), u16(500), u16(6000)] {
		if int(gid) < tf.num_glyphs() {
			assert wf.face.glyph_advance_units(gid) == tf.face.glyph_advance_units(gid), 'advance of gid ${gid} differs'
		}
	}
	// The file hook reads a .woff path the way it reads a .ttf one.
	p := woff_corpus_font_path('Amiri-Regular.woff') or {
		woff_skip_missing('Amiri-Regular.woff')
		return
	}
	pf := shape.load_font_file(p) or { panic(err) }
	assert pf.num_glyphs() == tf.num_glyphs(), 'file load disagrees on glyph count'
}
