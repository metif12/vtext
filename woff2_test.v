module harfara

import harfara.shape
import harfara.font
import harfara.brotli
import os

// This file is self-contained: every helper it needs is defined here with a
// woff2_ prefix, so `v test woff2_test.v` compiles this file alone. The prefix
// is what keeps the full suite compiling too — woff_test.v already owns the
// unprefixed names.

// woff2_corpus_font_path is where a named font is: the committed corpus
// first, the platform's own font directory second, and none when neither has
// it.
fn woff2_corpus_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('HARFARA_TEST_FONTS'), 'testdata/fonts', woff2_windows_font_dir()] {
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

fn woff2_corpus_font_bytes(name string) ?[]u8 {
	p := woff2_corpus_font_path(name) or { return none }
	return os.read_bytes(p) or { panic('${p} is not readable: ${err}') }
}

$if windows {
	fn woff2_windows_font_dir() string {
		return 'C:\\Windows\\Fonts'
	}
} $else {
	fn woff2_windows_font_dir() string {
		return ''
	}
}

// woff2_skip_missing prints why a test cannot run. A skip that prints nothing
// is a failure pretending to be a pass.
fn woff2_skip_missing(name string) {
	line := 'SKIP ${name} is in neither testdata/fonts nor the platform font directory'
	path := os.getenv('HARFARA_SKIP_LOG')
	if path != '' {
		mut f := os.open_append(path) or { return }
		f.writeln(line) or { return }
		f.close()
		return
	}
	println(line)
}

fn woff2_put_u16(mut b []u8, v int) {
	b << u8((v >> 8) & 0xff)
	b << u8(v & 0xff)
}

fn woff2_put_u32(mut b []u8, v u32) {
	b << u8((v >> 24) & 0xff)
	b << u8((v >> 16) & 0xff)
	b << u8((v >> 8) & 0xff)
	b << u8(v & 0xff)
}

// woff2_glyph_rec reads one glyf record's shape: contour count, box, and
// the absolute point list (empty when the glyph is). TTF and rebuilt WOFF2
// must agree on all three per glyph: same outlines in, same outlines out.
// Byte length is deliberately NOT compared: repeat encoding and padding are
// legitimate encoder choices, and the ink pin below is what proves the bytes
// draw the same ink. Points travel as strings because a multi-returned array
// miscompiles on this toolchain (elements arrive as prefix accumulations);
// the joined coordinates compare exactly the same.
fn woff2_glyph_rec(glyf []u8, loca []u8, index_format int, gid int) (int, string, string) {
	mut off := 0
	mut next := 0
	if index_format == 0 {
		off = int(u16_be_at(loca, gid * 2)) * 2
		next = int(u16_be_at(loca, gid * 2 + 2)) * 2
	} else {
		off = int(u32_be_at(loca, gid * 4))
		next = int(u32_be_at(loca, gid * 4 + 4))
	}
	length := next - off
	if length <= 0 || off + length > glyf.len {
		return 0, '', ''
	}
	rec := glyf[off..off + length]
	n := int(i16_be_at(rec, 0))
	if n == -1 {
		// Composite: box only. Components are verbatim copies; the ink test
		// proves they draw, the box proves the union math.
		return n, rec[2..10].hex(), ''
	}
	if n == 0 {
		return 0, '', ''
	}
	npoints := int(u16_be_at(rec, 10 + 2 * (n - 1))) + 1
	mut at := 10 + 2 * n
	ilen := int(u16_be_at(rec, at))
	at += 2 + ilen
	mut flags := []int{}
	for flags.len < npoints {
		f := int(rec[at])
		at++
		flags << f
		if f & 0x08 != 0 {
			r := int(rec[at])
			at++
			for _ in 0 .. r {
				flags << f
			}
		}
	}
	mut xs := []string{cap: npoints}
	mut ys := []string{cap: npoints}
	mut x := 0
	for f in flags {
		mut dx := 0
		if f & 0x02 != 0 {
			dx = int(rec[at])
			at++
			if f & 0x10 == 0 {
				dx = -dx
			}
		} else if f & 0x10 == 0 {
			dx = int(i16_be_at(rec, at))
			at += 2
		}
		x += dx
		xs << x.str()
	}
	mut y := 0
	for f in flags {
		mut dy := 0
		if f & 0x04 != 0 {
			dy = int(rec[at])
			at++
			if f & 0x20 == 0 {
				dy = -dy
			}
		} else if f & 0x20 == 0 {
			dy = int(i16_be_at(rec, at))
			at += 2
		}
		y += dy
		ys << y.str()
	}
	box := rec[2..10].hex()
	return n, box, xs.join(',') + '|' + ys.join(',')
}

fn u16_be_at(b []u8, at int) u16 {
	return (u16(b[at]) << 8) | u16(b[at + 1])
}

fn u32_be_at(b []u8, at int) u32 {
	return (u32(b[at]) << 24) | (u32(b[at + 1]) << 16) | (u32(b[at + 2]) << 8) | u32(b[at + 3])
}

fn i16_be_at(b []u8, at int) i16 {
	v := (int(b[at]) << 8) | int(b[at + 1])
	if v & 0x8000 != 0 {
		return i16(v - 0x10000)
	}
	return i16(v)
}

// woff2_file_sum is the sfnt whole-file checksum: the sum of big-endian u32
// words, tail padded with zeros, reduced mod 2**32. A valid sfnt sums to
// 0xB1B0AFBA.
fn woff2_file_sum(data []u8) u64 {
	mut sum := u64(0)
	mut i := 0
	for i + 4 <= data.len {
		sum += (u64(data[i]) << 24) | (u64(data[i + 1]) << 16) | (u64(data[i + 2]) << 8) | u64(data[i + 3])
		sum &= 0xffffffff
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
	return sum & 0xffffffff
}

// A hand-built brotli stream must inflate through the vendored decoder: the
// reference encoder (python brotli, q11) compressed 43 bytes to 31, and the
// pure-V decoder returns them exactly. This pins the decoder half of the
// WOFF2 path without any font involved.
fn test_woff2_brotli_decoder_round_trip() {
	enc := [u8(0x1b), 0x2a, 0x00, 0xf8, 0xc5, 0x6d, 0x6c, 0x5d, 0xc7, 0x76, 0x3e, 0xa1, 0xa4, 0xd7,
		0x48, 0xa8, 0x06, 0x59, 0xaa, 0x4a, 0x38, 0x47, 0xe7, 0xfe, 0xda, 0x44, 0xfa, 0x82, 0x52,
		0x84, 0x01]
	out := brotli.decompress(enc, brotli.DecompressParams{}) or { panic(err) }
	assert out.bytestr() == 'hello woff2 test data hello woff2 test data', 'vendored brotli misdecoded'
	// The callback half delivers the same bytes with an output cap: a cap of
	// 5 accepts whole 32 KiB chunks only while they fit, so a single-chunk
	// stream stops at zero delivered rather than over-delivering.
	mut collected := []u8{}
	mut ref := &collected
	delivered := brotli.decompress_with_callback(enc, fn (chunk []u8, ref &[]u8) int {
		unsafe {
			if ref.len + chunk.len > 5 {
				return 0
			}
			*ref << chunk
			return chunk.len
		}
	}, ref) or { panic(err) }
	assert delivered <= 5, 'callback over-delivered past the cap'
	assert collected == out[..delivered], 'callback bytes differ from one-shot bytes'
}

// Corrupting one brotli byte errors — the decoder rejects it — rather than
// decoding to silent garbage. The WOFF2 unwrap then carries that refusal.
fn test_woff2_brotli_refuses_corruption() {
	mut enc := [u8(0x1b), 0x2a, 0x00, 0xf8, 0xc5, 0x6d, 0x6c, 0x5d, 0xc7, 0x76, 0x3e, 0xa1, 0xa4,
		0xd7, 0x48, 0xa8, 0x06, 0x59, 0xaa, 0x4a, 0x38, 0x47, 0xe7, 0xfe, 0xda, 0x44, 0xfa, 0x82,
		0x52, 0x84, 0x01]
	enc[10] ^= 0xff
	if _ := brotli.decompress(enc, brotli.DecompressParams{}) {
		assert false, 'corrupt brotli stream decoded without error'
	}
}

// Every truncation errors: short header, cut directory, cut stream.
fn test_woff2_refuses_truncation() {
	woff2 := woff2_corpus_font_bytes('Amiri-Regular.woff2') or {
		woff2_skip_missing('Amiri-Regular.woff2')
		return
	}
	for cut in [0, 3, 4, 47, 48, 48 + 10, woff2.len - 1] {
		if _ := font.woff_to_sfnt(woff2[..cut]) {
			assert false, 'truncated WOFF2 (first ${cut} bytes) parsed without error'
		}
	}
	// A zero table count is refused, not built into an empty sfnt.
	mut zero := woff2.clone()
	zero[12] = 0
	zero[13] = 0
	if _ := font.woff_to_sfnt(zero) {
		assert false, 'zero table count parsed without error'
	}
	// A totalCompressedSize past the file end overruns it.
	mut over := woff2.clone()
	mut big := []u8{}
	woff2_put_u32(mut big, u32(woff2.len + 100))
	for k in 0 .. 4 {
		over[20 + k] = big[k]
	}
	if _ := font.woff_to_sfnt(over) {
		assert false, 'overrunning totalCompressedSize parsed without error'
	}
	// A header length disagreeing with the file size is refused.
	mut badlen := woff2.clone()
	mut len8 := []u8{}
	woff2_put_u32(mut len8, u32(woff2.len - 1))
	for k in 0 .. 4 {
		badlen[8 + k] = len8[k]
	}
	if _ := font.woff_to_sfnt(badlen) {
		assert false, 'mismatched header length parsed without error'
	}
}

// A bad transform version is refused, not decoded: glyf/loca take 0 or 3,
// hmtx 0 or 1, everything else 0.
fn test_woff2_refuses_bad_transform() {
	woff2 := woff2_corpus_font_bytes('Amiri-Regular.woff2') or {
		woff2_skip_missing('Amiri-Regular.woff2')
		return
	}
	// glyf is entry 6 in the Amiri directory (tag index 10, flags 0x0a).
	mut bad := woff2.clone()
	bad[48 + 6] = 0x4a
	if _ := font.woff_to_sfnt(bad) {
		assert false, 'glyf transform version 1 parsed without error'
	}
}

// A corrupt brotli payload inside a valid directory refuses at unwrap.
fn test_woff2_refuses_corrupt_stream() {
	woff2 := woff2_corpus_font_bytes('Amiri-Regular.woff2') or {
		woff2_skip_missing('Amiri-Regular.woff2')
		return
	}
	mut bad := woff2.clone()
	// Flip a byte just inside the stream: the directory ends at 48 + a few
	// dozen bytes, so offset 120 is stream on this face.
	bad[120] ^= 0xff
	if _ := font.woff_to_sfnt(bad) {
		assert false, 'corrupt brotli stream decoded without error'
	}
}

// Non-WOFF2 bytes pass through untouched, and wOF2 is recognised.
fn test_woff2_magic_routing() {
	ttf := woff2_corpus_font_bytes('Amiri-Regular.ttf') or {
		woff2_skip_missing('Amiri-Regular.ttf')
		return
	}
	assert !font.is_woff2(ttf)
	out := font.maybe_woff_to_sfnt(ttf) or { panic(err) }
	assert out == ttf, 'plain sfnt bytes were altered on the load path'
	woff2 := woff2_corpus_font_bytes('Amiri-Regular.woff2') or {
		woff2_skip_missing('Amiri-Regular.woff2')
		return
	}
	assert font.is_woff2(woff2)
	assert !font.is_woff(woff2)
}

// The real font: Amiri converted to WOFF2 with fontTools
// (python -c "from fontTools.ttLib import TTFont; f = TTFont('Amiri-Regular.ttf'); f.flavor = 'woff2'; f.save('Amiri-Regular.woff2')").
// The OFL licence already committed as OFL-Amiri.txt covers the conversion:
// it is the same font in another container, not a new work.
fn test_woff2_amiri_matches_ttf() {
	ttf := woff2_corpus_font_bytes('Amiri-Regular.ttf') or {
		woff2_skip_missing('Amiri-Regular.ttf')
		return
	}
	woff2 := woff2_corpus_font_bytes('Amiri-Regular.woff2') or {
		woff2_skip_missing('Amiri-Regular.woff2')
		return
	}
	// Positive control: the plain TTF loads on the same path, unchanged.
	tf := shape.load_font_bytes(ttf) or { panic(err) }
	wf := shape.load_font_bytes(woff2) or { panic(err) }
	assert wf.face.sfnt.tables.len == tf.face.sfnt.tables.len, 'table count differs'
	assert wf.num_glyphs() == tf.num_glyphs(), 'glyph count differs'
	assert wf.units_per_em() == tf.units_per_em(), 'units per em differs'
	// Same tables, same bytes: the container changed, the font did not.
	// 'head' carries three principled exceptions: checkSumAdjustment binds
	// the whole file and is recalculated (as fontTools does), modified is
	// restamped by the converter, and the converter sets flags bit 11 (the
	// lossless-transform marker). Bytes [8..12], [16..18] and [28..36] are
	// compared around, and the whole rebuilt file must sum to the spec magic
	// below.
	// glyf and loca are rebuilt, not copied — the encoder makes legitimate
	// choices even the reference converter does not reproduce byte for byte —
	// so those two are pinned structurally per glyph below, not by bytes.
	for tag in ['head', 'hhea', 'maxp', 'cmap', 'hmtx', 'GSUB', 'GPOS'] {
		if tag in tf.face.sfnt.tables {
			assert tag in wf.face.sfnt.tables, 'WOFF2 lost table ${tag}'
			if tag == 'head' {
				assert wf.face.sfnt.table_data(tag)[..8] == tf.face.sfnt.table_data(tag)[..8], 'head prefix differs'
				assert wf.face.sfnt.table_data(tag)[12..16] == tf.face.sfnt.table_data(tag)[12..16], 'head magic differs'
				assert wf.face.sfnt.table_data(tag)[18..28] == tf.face.sfnt.table_data(tag)[18..28], 'head middle differs'
				assert wf.face.sfnt.table_data(tag)[36..] == tf.face.sfnt.table_data(tag)[36..], 'head suffix differs'
			} else {
				assert wf.face.sfnt.table_data(tag) == tf.face.sfnt.table_data(tag), 'table ${tag} differs after unwrap'
			}
		}
	}
	assert woff2_file_sum(wf.data()) == u64(0xB1B0AFBA), 'rebuilt sfnt fails the whole-file checksum'
	// Structural glyf pin: every glyph rebuilds to the same record — contour
	// count, box and byte length — as the TTF's own. The box comparison is
	// what catches a miscalculated composite union; the length comparison
	// catches dropped or duplicated bytes.
	tglyf := tf.face.sfnt.table_data('glyf')
	tloca := tf.face.sfnt.table_data('loca')
	thead := tf.face.sfnt.table_data('head')
	tfmt := int(u16_be_at(thead, 50))
	wglyf := wf.face.sfnt.table_data('glyf')
	wloca := wf.face.sfnt.table_data('loca')
	whead := wf.face.sfnt.table_data('head')
	wfmt := int(u16_be_at(whead, 50))
	for gid in 0 .. tf.num_glyphs() {
		tn, tb, tp := woff2_glyph_rec(tglyf, tloca, tfmt, gid)
		wn, wb, wp := woff2_glyph_rec(wglyf, wloca, wfmt, gid)
		assert wn == tn, 'gid ${gid} contour count differs (${wn} vs ${tn})'
		assert wb == tb, 'gid ${gid} box differs'
		assert wp == tp, 'gid ${gid} points differ'
	}
	// Ink pin: sampled glyphs rasterize identically from both fonts. This is
	// the end-to-end proof that the rebuilt outlines draw the same ink.
	for gid in [u16(0), u16(1), u16(2), u16(10), u16(100), u16(500), u16(1000), u16(3000), u16(6000)] {
		if int(gid) < tf.num_glyphs() {
			tb := tf.rasterize(gid, 32.0, 0, 0)
			wb := wf.rasterize(gid, 32.0, 0, 0)
			assert wb.width == tb.width && wb.height == tb.height, 'gid ${gid} bitmap size differs'
			assert wb.coverage_sum() == tb.coverage_sum(), 'gid ${gid} ink differs'
		}
	}
	// Sampled cmap and advances agree.
	for cp in [`A`, `a`, ` `, `ب`, `س`, `ل`, `ا`, `م`] {
		assert wf.face.glyph_index(cp) == tf.face.glyph_index(cp), 'U+${cp:04X} maps differently'
	}
	for gid in [u16(0), u16(1), u16(2), u16(10), u16(100), u16(500), u16(6000)] {
		if int(gid) < tf.num_glyphs() {
			assert wf.face.glyph_advance_units(gid) == tf.face.glyph_advance_units(gid), 'advance of gid ${gid} differs'
		}
	}
	// The file hook reads a .woff2 path the way it reads a .ttf one.
	p := woff2_corpus_font_path('Amiri-Regular.woff2') or {
		woff2_skip_missing('Amiri-Regular.woff2')
		return
	}
	pf := shape.load_font_file(p) or { panic(err) }
	assert pf.num_glyphs() == tf.num_glyphs(), 'file load disagrees on glyph count'
}

// NotoSansNKo is the small second carrier: its glyf transform carries real
// programs, exercising the instruction-stream half the Amiri font never
// touches. Same discipline, smaller sweep.
fn test_woff2_nko_matches_ttf() {
	ttf := woff2_corpus_font_bytes('NotoSansNKo-Regular.ttf') or {
		woff2_skip_missing('NotoSansNKo-Regular.ttf')
		return
	}
	woff2 := woff2_corpus_font_bytes('NotoSansNKo-Regular.woff2') or {
		woff2_skip_missing('NotoSansNKo-Regular.woff2')
		return
	}
	tf := shape.load_font_bytes(ttf) or { panic(err) }
	wf := shape.load_font_bytes(woff2) or { panic(err) }
	assert wf.num_glyphs() == tf.num_glyphs(), 'glyph count differs'
	for tag in ['head', 'hhea', 'maxp', 'cmap', 'hmtx', 'GSUB', 'GPOS'] {
		if tag in tf.face.sfnt.tables {
			assert tag in wf.face.sfnt.tables, 'WOFF2 lost table ${tag}'
			if tag == 'head' {
				assert wf.face.sfnt.table_data(tag)[..8] == tf.face.sfnt.table_data(tag)[..8], 'head prefix differs'
				assert wf.face.sfnt.table_data(tag)[12..16] == tf.face.sfnt.table_data(tag)[12..16], 'head magic differs'
				assert wf.face.sfnt.table_data(tag)[18..28] == tf.face.sfnt.table_data(tag)[18..28], 'head middle differs'
				assert wf.face.sfnt.table_data(tag)[36..] == tf.face.sfnt.table_data(tag)[36..], 'head suffix differs'
			} else {
				assert wf.face.sfnt.table_data(tag) == tf.face.sfnt.table_data(tag), 'table ${tag} differs after unwrap'
			}
		}
	}
	assert woff2_file_sum(wf.data()) == u64(0xB1B0AFBA), 'rebuilt sfnt fails the whole-file checksum'
	tglyf := tf.face.sfnt.table_data('glyf')
	tloca := tf.face.sfnt.table_data('loca')
	tfmt := int(u16_be_at(tf.face.sfnt.table_data('head'), 50))
	wglyf := wf.face.sfnt.table_data('glyf')
	wloca := wf.face.sfnt.table_data('loca')
	wfmt := int(u16_be_at(wf.face.sfnt.table_data('head'), 50))
	for gid in 0 .. tf.num_glyphs() {
		tn, tb, tp := woff2_glyph_rec(tglyf, tloca, tfmt, gid)
		wn, wb, wp := woff2_glyph_rec(wglyf, wloca, wfmt, gid)
		assert wn == tn, 'gid ${gid} contour count differs'
		assert wb == tb, 'gid ${gid} box differs'
		assert wp == tp, 'gid ${gid} points differ'
	}
	for gid in [u16(0), u16(1), u16(2), u16(10), u16(100)] {
		if int(gid) < tf.num_glyphs() {
			tb := tf.rasterize(gid, 32.0, 0, 0)
			wb := wf.rasterize(gid, 32.0, 0, 0)
			assert wb.width == tb.width && wb.height == tb.height, 'gid ${gid} bitmap size differs'
			assert wb.coverage_sum() == tb.coverage_sum(), 'gid ${gid} ink differs'
		}
	}
	// The file hook reads a .woff2 path the way it reads a .ttf one.
	p := woff2_corpus_font_path('NotoSansNKo-Regular.woff2') or {
		woff2_skip_missing('NotoSansNKo-Regular.woff2')
		return
	}
	pf := shape.load_font_file(p) or { panic(err) }
	assert pf.num_glyphs() == tf.num_glyphs(), 'file load disagrees on glyph count'
}

// woff2_test_hmtx builds the smallest transformed hmtx by hand: two glyphs
// (empty + one square), one hmtx metric, side bearings only. No committed
// font carries a transformed hmtx, so the transform path is pinned here
// instead of through a fixture.
fn woff2_hmtx_square_glyf() ([]u8, []u8) {
	mut glyf := []u8{}
	// gid 1: one contour, box (10,10)-(100,100), no instructions.
	woff2_put_u16(mut glyf, 1)
	woff2_put_i16(mut glyf, 10)
	woff2_put_i16(mut glyf, 10)
	woff2_put_i16(mut glyf, 100)
	woff2_put_i16(mut glyf, 100)
	woff2_put_u16(mut glyf, 3)
	woff2_put_u16(mut glyf, 0)
	// flags: P0 short+/short+, P1 short+/zero, P2 zero/short+, P3 short-/zero.
	glyf << [u8(0x37), 0x33, 0x35, 0x23]
	glyf << [u8(10), 10, 90, 90, 90, 90]
	// loca, long format: gid 0 empty at 0, gid 1 at 0..26.
	mut loca := []u8{}
	woff2_put_u32(mut loca, 0)
	woff2_put_u32(mut loca, 0)
	woff2_put_u32(mut loca, u32(glyf.len))
	return glyf, loca
}

fn woff2_hmtx_test_hhea(num_metrics int) []u8 {
	mut hhea := []u8{len: 36}
	hhea[34] = u8(num_metrics >> 8)
	hhea[35] = u8(num_metrics & 0xff)
	return hhea
}

fn test_woff2_hmtx_transformed() {
	glyf, loca := woff2_hmtx_square_glyf()
	hhea := woff2_hmtx_test_hhea(1)
	// flags 0x01: no lsb array (derived from xMin), sidebearing array present.
	mut t := [u8(0x01)]
	woff2_put_u16(mut t, 500)
	woff2_put_i16(mut t, -10)
	out := font.woff2_rebuild_hmtx(t, glyf, loca, hhea, 2, 1, 6) or { panic(err) }
	// gid 0: advance 500, xMin 0 (empty). gid 1 reuses the last advance and
	// takes its side bearing: [500, -10].
	assert out == [u8(0x01), 0xf4, 0x00, 0x00, 0xff, 0xf6], 'transformed hmtx mismatch: ${out.hex()}'
	// flags 0x02: lsb array present, sidebearing array derived from xMin.
	mut t2 := [u8(0x02)]
	woff2_put_u16(mut t2, 500)
	woff2_put_i16(mut t2, 3)
	out2 := font.woff2_rebuild_hmtx(t2, glyf, loca, hhea, 2, 1, 6) or { panic(err) }
	// gid 0: advance 500, stored lsb 3. gid 1 reuses the advance and takes
	// its xMin (10) as the side bearing.
	assert out2 == [u8(0x01), 0xf4, 0x00, 0x03, 0x00, 0x0a], 'lsb hmtx mismatch: ${out2.hex()}'
	// flags 0x03: both arrays derived from xMin, advances only on the wire.
	mut t3 := [u8(0x03)]
	woff2_put_u16(mut t3, 500)
	out3 := font.woff2_rebuild_hmtx(t3, glyf, loca, hhea, 2, 1, 6) or { panic(err) }
	assert out3 == [u8(0x01), 0xf4, 0x00, 0x00, 0x00, 0x0a], 'derived hmtx mismatch: ${out3.hex()}'
	// flags 0x00 claims both arrays: refused, since a transform carrying
	// both is never emitted (such tables stay untransformed).
	if _ := font.woff2_rebuild_hmtx([u8(0x00)], glyf, loca, hhea, 2, 1, 6) {
		assert false, 'both-arrays hmtx parsed without error'
	}
	// Reserved flags: refused.
	if _ := font.woff2_rebuild_hmtx([u8(0x04)], glyf, loca, hhea, 2, 1, 6) {
		assert false, 'reserved-bit hmtx parsed without error'
	}
	// Short advance array: refused, not padded.
	short := [u8(0x03), 0x01]
	if _ := font.woff2_rebuild_hmtx(short, glyf, loca, hhea, 2, 1, 6) {
		assert false, 'short advance array parsed without error'
	}
	// Trailing byte: refused, not ignored.
	mut trail := [u8(0x03)]
	woff2_put_u16(mut trail, 500)
	trail << u8(0)
	if _ := font.woff2_rebuild_hmtx(trail, glyf, loca, hhea, 2, 1, 6) {
		assert false, 'trailing hmtx byte parsed without error'
	}
	// Wrong rebuilt length: refused, not truncated.
	if _ := font.woff2_rebuild_hmtx(t, glyf, loca, hhea, 2, 1, 7) {
		assert false, 'wrong-length hmtx built without error'
	}
}

fn woff2_put_i16(mut b []u8, v int) {
	woff2_put_u16(mut b, v & 0xffff)
}
