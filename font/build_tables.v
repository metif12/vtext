module font

// Fixed-size table writers: the 14.2b half of the in-memory builder, plus
// the 14.2c metrics and empty-outline writers. Where 14.2a
// (`font/builder.v`) assembles a font from caller-supplied table bytes,
// these functions build the tables whose content is caller parameters in,
// spec-layout bytes out: head, maxp and hhea from scalars, hmtx from the two
// per-glyph arrays, and the empty glyf/loca pair from the glyph count. The
// caller feeds the result to `Builder.set` and `Builder.build` patches the
// checkSumAdjustment, so every writer below leaves that field zeroed.
//
// Every offset below is pinned twice: against the engine's own readers
// (`Face.read_head` reads unitsPerEm at head+18 and the bbox at head+36..42,
// `Face.read_hhea_maxp` reads the vertical metrics at hhea+4..8 and the
// glyph count at maxp+4, `Face.read_hmtx` and `read_vmtx` read the metric
// count at hhea+34) and against a fontTools dump of a corpus font, because
// the readers only cover a subset of the fields. The fontTools cross-check
// (Amiri-Regular.ttf) reads, at the same offsets this file writes:
// head 54 bytes `00010000 000100c5 ... 5f0f3cf5 0003 03e8 ... fe4a fc7c 2ccb
// 0717 0000 0006 0002 0001 0000`, hhea 36 bytes `00010000 0464 fd86 0000 ...
// 1a1f` with numberOfHMetrics at +34, maxp 32 bytes `00010000 1a36 ...`.
//
// What the writers fix and what they take: version fields are always 1.0,
// flags/macStyle/created/modified are 0 (a synthetic font claims no style
// and no timestamps), head's lowestRecPPEM is 3, fontDirectionHint is 2 and
// glyphDataFormat is 0; hhea carries only the four caller parameters plus
// version 1.0, everything else 0; maxp 1.0 carries the glyph count plus
// thirteen zero maxima, the TrueType-requirement maxima the builder leaves
// for a real font to fill. A writer never invents metrics: advanceWidthMax,
// the side bearings, xMaxExtent and the caret slope stay 0 in hhea output.
// cmap and name take per-codepoint and per-string data;
// hmtx takes the per-glyph arrays and the empty glyf/loca pair takes the
// glyph count, so both land here in 14.2c. 14.2d adds the first tables with
// variable-size payloads: cmap format 4 from a sorted codepoint-to-glyph list,
// and a minimal Windows-Unicode name table from a family and a style.

// head_magic is the sfnt-specified magic number at head+12. The builder
// writes it; Face.read_head refuses a head without it.
const head_magic = u32(0x5f0f3cf5)

// build_head writes one 54-byte head table: version 1.0, fontRevision
// 0, a zeroed checkSumAdjustment for Builder.build to patch, the magic,
// flags 0, the units-per-em, zero created/modified, the bbox, macStyle 0,
// lowestRecPPEM 3, fontDirectionHint 2, the loca format flag and
// glyphDataFormat 0. units_per_em must fit a u16 and be at least 16 (the
// OpenType floor); each bbox coordinate must fit an i16.
pub fn build_head(units_per_em int, bbox [4]int, loca_is_long bool) ![]u8 {
	if units_per_em < 16 || units_per_em > 0xffff {
		return error('head: unitsPerEm ${units_per_em} is outside 16..65535')
	}
	for v in bbox {
		if v < -0x8000 || v > 0x7fff {
			return error('head: bbox coordinate ${v} is outside i16 range')
		}
	}
	mut out := []u8{len: 54}
	build_w16(mut out, 0, 1) // majorVersion
	build_w16(mut out, 2, 0) // minorVersion
	// 4: fontRevision 0; 8: checkSumAdjustment 0, patched by the builder.
	build_w32(mut out, 12, head_magic)
	// 16: flags 0.
	build_w16(mut out, 18, u16(units_per_em))
	// 20: created 0; 28: modified 0.
	build_wi16(mut out, 36, i16(bbox[0]))
	build_wi16(mut out, 38, i16(bbox[1]))
	build_wi16(mut out, 40, i16(bbox[2]))
	build_wi16(mut out, 42, i16(bbox[3]))
	// 44: macStyle 0.
	build_w16(mut out, 46, 3) // lowestRecPPEM
	build_wi16(mut out, 48, 2) // fontDirectionHint
	build_wi16(mut out, 50, if loca_is_long { i16(1) } else { i16(0) })
	// 52: glyphDataFormat 0.
	return out
}

// build_maxp writes a 32-byte version-1.0 maxp table: the version, the glyph
// count, and thirteen zero maxima. The zeros are honest about being unknown:
// maxp maxima describe outline complexity, which only the glyf writer (a
// later slice) can measure, and the engine never reads them at load.
pub fn build_maxp(num_glyphs int) ![]u8 {
	if num_glyphs < 0 || num_glyphs > 0xffff {
		return error('maxp: numGlyphs ${num_glyphs} is outside 0..65535')
	}
	mut out := []u8{len: 32}
	build_w16(mut out, 0, 1) // majorVersion
	build_w16(mut out, 2, 0) // minorVersion
	build_w16(mut out, 4, u16(num_glyphs))
	// 6..30: the thirteen maxima, all 0.
	return out
}

// build_maxp_05 writes the 6-byte version-0.5 maxp: the version and the glyph
// count, nothing else. It is the CFF form (a CFF font has no TrueType
// maxima); the TrueType form is build_maxp.
pub fn build_maxp_05(num_glyphs int) ![]u8 {
	if num_glyphs < 0 || num_glyphs > 0xffff {
		return error('maxp: numGlyphs ${num_glyphs} is outside 0..65535')
	}
	mut out := []u8{len: 6}
	build_w16(mut out, 0, 0) // majorVersion
	build_w16(mut out, 2, 0x5000) // minorVersion 0x5000
	build_w16(mut out, 4, u16(num_glyphs))
	return out
}

// build_hhea writes a 36-byte version-1.0 hhea table: the version, the
// ascender/descender/line gap, and the long-metric count. Everything else is
// 0: advanceWidthMax, the bearings, xMaxExtent and the caret slope need
// per-glyph measurement (a later slice), and metricDataFormat is 0. The
// metric count must fit a u16; whether it may exceed the glyph count is the
// hmtx writer's business, not this table's.
pub fn build_hhea(ascender int, descender int, line_gap int, num_h_metrics int) ![]u8 {
	if ascender < -0x8000 || ascender > 0x7fff {
		return error('hhea: ascender ${ascender} is outside i16 range')
	}
	if descender < -0x8000 || descender > 0x7fff {
		return error('hhea: descender ${descender} is outside i16 range')
	}
	if line_gap < -0x8000 || line_gap > 0x7fff {
		return error('hhea: lineGap ${line_gap} is outside i16 range')
	}
	if num_h_metrics < 0 || num_h_metrics > 0xffff {
		return error('hhea: numOfLongHorMetrics ${num_h_metrics} is outside 0..65535')
	}
	mut out := []u8{len: 36}
	build_w16(mut out, 0, 1) // majorVersion
	build_w16(mut out, 2, 0) // minorVersion
	build_wi16(mut out, 4, i16(ascender))
	build_wi16(mut out, 6, i16(descender))
	build_wi16(mut out, 8, i16(line_gap))
	// 10: advanceWidthMax 0; 12: minLeftSideBearing 0; 14: minRightSideBearing
	// 0; 16: xMaxExtent 0; 18: caretSlopeRise 0; 20: caretSlopeRun 0;
	// 22: caretOffset 0; 24..30: reserved 0; 32: metricDataFormat 0.
	build_w16(mut out, 34, u16(num_h_metrics))
	return out
}

// build_hmtx writes the horizontal metrics for num_glyphs glyphs:
// num_h_metrics long records (advance plus side bearing) followed by one
// short tail bearing per remaining glyph. advances and lsbs each hold one
// entry per glyph, so their lengths are the glyph count; num_h_metrics is
// the hhea count and must name a split inside the glyphs. The tail shares
// the last long advance the way `Face.read_hmtx` replays it: the format has
// no room for tail advances, so advances past the split are accepted and
// not stored, and the reader answers them with the last long advance.
//
// The reader's truncation rules are why the writer always emits the full
// table: read_hmtx stops at the first long record that is not fully present
// (leaving that glyph and every later one zero) and answers a missing tail
// bearing as 0, so a short hmtx is a corrupt file, not a short form. A
// zero metric count is refused for the same read-back reason: the reader
// treats 0 as "every glyph is long", which would misread the tail this
// writer emits.
pub fn build_hmtx(advances []u16, lsbs []i16, num_h_metrics int) ![]u8 {
	if advances.len != lsbs.len {
		return error('hmtx: ${advances.len} advances but ${lsbs.len} side bearings, want one bearing per glyph')
	}
	num := advances.len
	if num > 0xffff {
		return error('hmtx: ${num} glyphs do not fit the u16 glyph count')
	}
	if num == 0 {
		if num_h_metrics != 0 {
			return error('hmtx: numOfLongHorMetrics ${num_h_metrics} with no glyphs, want 0')
		}
		return []u8{}
	}
	if num_h_metrics < 1 || num_h_metrics > num {
		return error('hmtx: numOfLongHorMetrics ${num_h_metrics} is outside 1..${num}')
	}
	mut out := []u8{len: num_h_metrics * 4 + (num - num_h_metrics) * 2}
	for i in 0 .. num_h_metrics {
		build_w16(mut out, i * 4, advances[i])
		build_wi16(mut out, i * 4 + 2, lsbs[i])
	}
	for i in num_h_metrics .. num {
		build_wi16(mut out, num_h_metrics * 4 + (i - num_h_metrics) * 2, lsbs[i])
	}
	return out
}

// build_empty_glyf_loca writes an empty glyf table and its loca: every
// glyph's range is zero-length, so every outline reads back empty. That is
// the same convention `subset.v:rebuild_outlines` uses for dropped glyphs
// (a zero-length loca span is what an empty glyph in the original font is
// too), which keeps every gid the font declares addressable. A short loca
// stores each offset halved, so only even offsets are representable; all
// zeros are evenly at 0, and the empty glyf has no offsets to pad.
pub fn build_empty_glyf_loca(num_glyphs int, long bool) !([]u8, []u8) {
	if num_glyphs < 0 || num_glyphs > 0xffff {
		return error('glyf/loca: numGlyphs ${num_glyphs} is outside 0..65535')
	}
	stride := if long { 4 } else { 2 }
	loca := []u8{len: (num_glyphs + 1) * stride}
	return []u8{}, loca
}

// CmapMapping is one codepoint-to-glyph mapping for build_cmap4. cp must be a
// BMP codepoint below 0xFFFF (0xFFFF is reserved for the terminating segment),
// and gid is the glyph index the codepoint answers.
pub struct CmapMapping {
pub:
	cp  u32
	gid u16
}

// CmapSegment4 is one working segment before it is serialised: gid_at is the
// index of the segment's first glyph in the glyph array, or -1 when the segment
// uses the compact idDelta form and needs no array entries.
struct CmapSegment4 {
	start  u16
	end    u16
	delta  i16
	gid_at int
}

// build_cmap4 writes one 'cmap' table with a format 4 subtable for the given
// BMP mappings. Input must be strictly increasing by codepoint; an unsorted
// list, a duplicate codepoint, 0xFFFF or a codepoint past the BMP is refused.
// Refusing rather than sorting keeps the caller's order meaningful and makes a
// doubled mapping an error instead of a silently overwritten one.
//
// Segments are minimal: consecutive codepoints are merged into one segment,
// using the idDelta form when gid - cp is constant over the whole run and the
// glyphIdArray form otherwise (with idDelta 0 and the gids stored verbatim).
// A run that is not delta-mappable still takes one segment, which is never
// worse than splitting it. A trailing 0xFFFF..0xFFFF segment with idDelta 1
// terminates the arrays the way the format requires.
//
// Two encoding records, (3,1) Windows BMP and (0,3) Unicode BMP, point at the
// same subtable. The duplicate follows the specification's recommended pairing
// and the corpus convention (textfont_parsed sees the same sharing), and costs
// eight bytes. The engine ranks (3,1) above (0,3), so the choice does not change
// which subtable answers a lookup.
pub fn build_cmap4(mappings []CmapMapping) ![]u8 {
	for i, m in mappings {
		if m.cp > 0xffff {
			return error('cmap4: codepoint ${m.cp} is outside the BMP')
		}
		if m.cp == 0xffff {
			return error('cmap4: codepoint 0xFFFF is reserved for the terminator')
		}
		if i > 0 && mappings[i - 1].cp >= m.cp {
			return error('cmap4: mappings are not strictly increasing at index ${i}')
		}
	}
	mut segments := []CmapSegment4{}
	mut glyph_ids := []u16{}
	mut i := 0
	for i < mappings.len {
		first := i
		delta := i16(u16(mappings[i].gid) - u16(mappings[i].cp))
		i++
		for i < mappings.len && mappings[i].cp == mappings[i - 1].cp + 1 {
			i++
		}
		mut delta_ok := true
		for k in first + 1 .. i {
			if mappings[k].gid != u16(u32(mappings[k].cp) + u32(u16(delta))) {
				delta_ok = false
				break
			}
		}
		seg := CmapSegment4{
			start:  u16(mappings[first].cp)
			end:    u16(mappings[i - 1].cp)
			delta:  if delta_ok { delta } else { i16(0) }
			gid_at: if delta_ok { -1 } else { glyph_ids.len }
		}
		if !delta_ok {
			for k in first .. i {
				glyph_ids << mappings[k].gid
			}
		}
		segments << seg
	}
	segments << CmapSegment4{
		start:  0xffff
		end:    0xffff
		delta:  1 // (0xFFFF + 1) mod 2^16 = 0: .notdef
		gid_at: -1
	}
	seg_count := segments.len
	if seg_count > 0x8000 {
		return error('cmap4: ${seg_count} segments overflow segCountX2')
	}
	sub_len := 16 + 8 * seg_count + glyph_ids.len * 2
	if sub_len > 0xffff {
		return error('cmap4: subtable length ${sub_len} does not fit a u16')
	}
	sub_at := 4 + 8 * 2
	mut out := []u8{len: sub_at + sub_len}
	build_w16(mut out, 0, 0) // version
	build_w16(mut out, 2, 2) // numTables
	build_w16(mut out, 4, 3) // platformID: Windows
	build_w16(mut out, 6, 1) // encodingID: Unicode BMP
	build_w32(mut out, 8, u32(sub_at))
	build_w16(mut out, 12, 0) // platformID: Unicode
	build_w16(mut out, 14, 3) // encodingID: Unicode BMP
	build_w32(mut out, 16, u32(sub_at))
	// The arrays follow the 14-byte subtable header: endCode, reservedPad,
	// startCode, idDelta, idRangeOffset, then glyphIdArray.
	base := sub_at
	build_w16(mut out, base, 4)
	build_w16(mut out, base + 2, u16(sub_len))
	build_w16(mut out, base + 4, 0) // language
	build_w16(mut out, base + 6, u16(seg_count * 2))
	mut power := 1
	mut selector := 0
	for power * 2 <= seg_count {
		power *= 2
		selector++
	}
	build_w16(mut out, base + 8, u16(power * 2))
	build_w16(mut out, base + 10, u16(selector))
	build_w16(mut out, base + 12, u16(seg_count * 2 - power * 2))
	mut p := base + 14
	for seg in segments {
		build_w16(mut out, p, seg.end)
		p += 2
	}
	build_w16(mut out, p, 0) // reservedPad
	p += 2
	for seg in segments {
		build_w16(mut out, p, seg.start)
		p += 2
	}
	for seg in segments {
		build_wi16(mut out, p, seg.delta)
		p += 2
	}
	// Each idRangeOffset is a byte offset from its own slot, so a segment's
	// first glyph sits (segCount - index) glyphs past that slot.
	for s, seg in segments {
		mut range_off := u32(0)
		if seg.gid_at >= 0 {
			range_off = u32((seg_count - s + seg.gid_at) * 2)
			if range_off > 0xffff {
				return error('cmap4: glyphIdArray offset ${range_off} does not fit a u16')
			}
		}
		build_w16(mut out, p, u16(range_off))
		p += 2
	}
	for gid in glyph_ids {
		build_w16(mut out, p, gid)
		p += 2
	}
	return out
}

// build_utf16be encodes a string as UTF-16BE for a name table. Surrogates and
// codepoints past U+10FFFF are refused rather than emitted as a wrong glyph;
// supplementary characters use a surrogate pair.
fn build_utf16be(s string) ![]u8 {
	mut out := []u8{cap: s.len * 2}
	for r in s.runes() {
		if r < 0 || (r >= 0xd800 && r <= 0xdfff) || r > 0x10ffff {
			return error('name: codepoint ${r} is not encodable in UTF-16BE')
		}
		if r <= 0xffff {
			out << u8((u32(r) >> 8) & 0xff)
			out << u8(u32(r) & 0xff)
		} else {
			v := u32(r) - 0x10000
			hi := u16(0xd800 + (v >> 10))
			lo := u16(0xdc00 + (v & 0x3ff))
			out << u8((hi >> 8) & 0xff)
			out << u8(hi & 0xff)
			out << u8((lo >> 8) & 0xff)
			out << u8(lo & 0xff)
		}
	}
	return out
}

// build_name_minimal writes a format 0 'name' table with four Windows Unicode
// (platform 3, encoding 1, language 0x0409) records: family (1), style (2),
// full name (4) and PostScript name (6). The full name is family plus style,
// and the PostScript name is family and style with spaces removed, joined by a
// hyphen; an empty style leaves the family alone. Records are already sorted
// by (platform, encoding, language, name ID) because the ID rises while the
// other keys stay fixed. Strings are packed contiguously from stringOffset in
// record order, so there are no gaps for a textfont dump/load to disagree on.
pub fn build_name_minimal(family string, style string) ![]u8 {
	if family.len == 0 {
		return error('name: family is empty')
	}
	full := if style.len == 0 { family } else { '${family} ${style}' }
	ps_family := family.replace(' ', '')
	ps_style := style.replace(' ', '')
	postscript := if ps_style.len == 0 { ps_family } else { '${ps_family}-${ps_style}' }
	names := [family, style, full, postscript]
	ids := [u16(1), 2, 4, 6]
	mut storage := []u8{}
	mut offsets := []u16{cap: names.len}
	mut lengths := []u16{cap: names.len}
	for s in names {
		encoded := build_utf16be(s) or { return err }
		if storage.len > 0xffff || encoded.len > 0xffff {
			return error('name: string storage offsets do not fit a u16')
		}
		offsets << u16(storage.len)
		lengths << u16(encoded.len)
		for b in encoded {
			storage << b
		}
	}
	string_off := 6 + 12 * names.len
	if string_off + storage.len > 0xffff {
		return error('name: table length ${string_off + storage.len} does not fit a u16 stringOffset')
	}
	mut out := []u8{len: string_off + storage.len}
	build_w16(mut out, 0, 0) // format
	build_w16(mut out, 2, u16(names.len))
	build_w16(mut out, 4, u16(string_off))
	for i, id in ids {
		rec := 6 + i * 12
		build_w16(mut out, rec, 3) // platformID: Windows
		build_w16(mut out, rec + 2, 1) // encodingID: BMP
		build_w16(mut out, rec + 4, 0x0409) // languageID: English (US)
		build_w16(mut out, rec + 6, id)
		build_w16(mut out, rec + 8, lengths[i])
		build_w16(mut out, rec + 10, offsets[i])
	}
	for i, b in storage {
		out[string_off + i] = b
	}
	return out
}

// build_w16 stores v big-endian at off. The bounds are the caller's: every
// call site above writes inside its own freshly sized table.
fn build_w16(mut out []u8, off int, v u16) {
	out[off] = u8((v >> 8) & 0xff)
	out[off + 1] = u8(v & 0xff)
}

// build_wi16 stores v big-endian at off.
fn build_wi16(mut out []u8, off int, v i16) {
	build_w16(mut out, off, u16(v))
}

// build_w32 stores v big-endian at off.
fn build_w32(mut out []u8, off int, v u32) {
	out[off] = u8((v >> 24) & 0xff)
	out[off + 1] = u8((v >> 16) & 0xff)
	out[off + 2] = u8((v >> 8) & 0xff)
	out[off + 3] = u8(v & 0xff)
}
