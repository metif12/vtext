module font

// Fixed-size table writers: the 14.2b half of the in-memory builder. Where
// 14.2a (`font/builder.v`) assembles a font from caller-supplied table
// bytes, these functions build the three tables whose content is scalar
// parameters in, spec-layout bytes out: head, maxp and hhea. The caller
// feeds the result to `Builder.set` and `Builder.build` patches the
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
// cmap, hmtx and name need per-glyph data and arrive in 14.2c-d.

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
