module vtext

// Cmap is a character-to-glyph mapping subtable, normalised across the formats
// that matter in practice (0, 4, 6 and 12).
struct Cmap {
mut:
	format   int
	platform u16
	encoding u16
	// data is the whole 'cmap' table. Format 4's glyphIdArray is addressed by a
	// byte offset from each idRangeOffset slot, so the subtable cannot be read
	// without the surrounding table.
	data []u8
	// glyph_array_off is the absolute offset of a format 4 glyphIdArray.
	glyph_array_off int
	// format 0 / 6: a flat glyph array.
	glyph_ids  []u16
	first_code u16
	// format 4: segment arrays, parallel with each other.
	start_code []u16
	end_code   []u16
	id_delta   []i16
	id_range   []u16
	// format 12: sorted coverage groups.
	groups []CmapGroup
	// score orders competing subtables. Higher wins; see cmap_preference.
	score int
}

// CmapGroup is one startCharCode..endCharCode span of a format 12 subtable.
struct CmapGroup {
	start_cp  u32
	end_cp    u32
	start_gid u32
}

// Platform and encoding identifiers, kept as raw ids to stay independent of
// any particular registry revision.
const platform_unicode = u16(0)
const platform_macintosh = u16(1)
const platform_iso = u16(2)
const platform_windows = u16(3)

// cmap_preference ranks a (platform, encoding) pair. The scores follow the
// order the OpenType specification recommends for choosing a Unicode subtable.
fn cmap_preference(platform u16, encoding u16) int {
	if platform == platform_windows {
		match encoding {
			10 {
				return 100 // UCS-4, full repertoire
			}
			1 {
				return 90 // BMP
			}
			0 {
				return 20 // Symbol
			}
			2 {
				return 21 // Symbol, BMP
			}
			else {}
		}
	}
	if platform == platform_unicode {
		match encoding {
			4 {
				return 95 // full repertoire
			}
			2 {
				return 91 // BMP
			}
			0 {
				return 15 // Symbol
			}
			3 {
				return 16 // Symbol, BMP
			}
			1 {
				return 10 // old, rarely useful
			}
			6 {
				return 17 // full, not widely used
			}
			5 {
				return 18 // variation sequences
			}
			else {}
		}
	}
	if platform == platform_iso {
		if encoding == 0 {
			return 5
		}
	}
	if platform == platform_macintosh {
		match encoding {
			0 {
				return 12 // Roman
			}
			1 {
				return 8 // Japanese
			}
			2 {
				return 9 // Traditional Chinese
			}
			3 {
				return 11 // Korean
			}
			4 {
				return 14 // Arabic
			}
			6 {
				return 13 // Greek
			}
			7 {
				return 2
			}
			else {}
		}
	}
	return 1
}

// parse_cmap reads every subtable of a font's 'cmap' table, best-scored first.
fn parse_cmap(data []u8) []Cmap {
	if data.len < 4 {
		return []Cmap{}
	}
	r := new_reader(data)
	num := int(r.u16_at(2))
	mut out := []Cmap{}
	for i in 0 .. num {
		rec := 4 + i * 8
		if !r.has(rec, 8) {
			break
		}
		platform := r.u16_at(rec)
		encoding := r.u16_at(rec + 2)
		off := int(r.u32_at(rec + 4))
		if off < 0 || off + 2 > data.len {
			continue
		}
		format := int(r.u16_at(off))
		mut sub := Cmap{
			format:   format
			platform: platform
			encoding: encoding
			data:     data
			score:    cmap_preference(platform, encoding)
		}
		match format {
			0 {
				parse_cmap_format0(mut &sub, r, off)
			}
			4 {
				parse_cmap_format4(mut &sub, r, off)
			}
			6 {
				parse_cmap_format6(mut &sub, r, off)
			}
			12 {
				parse_cmap_format12(mut &sub, r, off)
			}
			else {}
		}
		// A subtable that parsed to nothing is useless; drop it.
		if sub.glyph_ids.len == 0 && sub.start_code.len == 0 && sub.groups.len == 0 {
			continue
		}
		out << sub
	}
	// Stable sort by descending score keeps the preferred subtable first.
	out.sort_with_compare(fn (a &Cmap, b &Cmap) int {
		return b.score - a.score
	})
	return out
}

fn parse_cmap_format0(mut sub &Cmap, r Reader, off int) {
	if !r.has(off + 6, 256 * 2) {
		return
	}
	sub.glyph_ids = []u16{len: 256}
	for i in 0 .. 256 {
		sub.glyph_ids[i] = r.u16_at(off + 6 + i * 2)
	}
}

fn parse_cmap_format6(mut sub &Cmap, r Reader, off int) {
	if !r.has(off + 6, 4) {
		return
	}
	first := r.u16_at(off + 6)
	count := int(r.u16_at(off + 8))
	sub.first_code = first
	sub.glyph_ids = []u16{len: count}
	for i in 0 .. count {
		sub.glyph_ids[i] = r.u16_at(off + 10 + i * 2)
	}
}

fn parse_cmap_format4(mut sub &Cmap, r Reader, off int) {
	if !r.has(off + 14, 2) {
		return
	}
	seg_count := int(r.u16_at(off + 6)) >> 1
	if seg_count <= 0 {
		return
	}
	base := off + 14
	// endCode[seg], reservedPad, startCode[seg], idDelta[seg], idRangeOffset[seg]
	if !r.has(base, seg_count * 8 + 2) {
		return
	}
	sub.end_code = []u16{len: seg_count}
	sub.start_code = []u16{len: seg_count}
	sub.id_delta = []i16{len: seg_count}
	sub.id_range = []u16{len: seg_count}
	for i in 0 .. seg_count {
		sub.end_code[i] = r.u16_at(base + i * 2)
	}
	mut p := base + seg_count * 2 + 2
	for i in 0 .. seg_count {
		sub.start_code[i] = r.u16_at(p + i * 2)
	}
	p += seg_count * 2
	for i in 0 .. seg_count {
		sub.id_delta[i] = r.i16_at(p + i * 2)
	}
	p += seg_count * 2
	for i in 0 .. seg_count {
		sub.id_range[i] = r.u16_at(p + i * 2)
	}
	sub.glyph_array_off = p + seg_count * 2
	// start_code is populated, which is how parse_cmap recognises this
	// subtable as non-empty. glyphIdArray stays empty: format 4 is read
	// through the idRangeOffset byte offset rather than by slicing it out.
}

fn parse_cmap_format12(mut sub &Cmap, r Reader, off int) {
	if !r.has(off + 12, 4) {
		return
	}
	mut num_groups := int(r.u32_at(off + 12))
	if num_groups <= 0 {
		return
	}
	// 16 bytes per group; guard against a count that overruns the table.
	avail := (r.len() - (off + 16)) / 12
	if num_groups > avail {
		num_groups = avail
	}
	sub.groups = []CmapGroup{len: num_groups}
	for i in 0 .. num_groups {
		g := off + 16 + i * 12
		sub.groups[i] = CmapGroup{
			start_cp:  r.u32_at(g)
			end_cp:    r.u32_at(g + 4)
			start_gid: r.u32_at(g + 8)
		}
	}
}

// lookup_glyph maps a codepoint to a glyph index, or 0 when unmapped.
// A returned glyph is 0 for ".notdef"; a returned none means "this subtable
// has no opinion", so the caller can try the next one.
fn (c &Cmap) lookup_glyph(cp u32) ?u16 {
	match c.format {
		0 {
			if cp > 0xFF || cp >= c.glyph_ids.len {
				return none
			}
			return c.glyph_ids[cp]
		}
		4 {
			return c.lookup_format4(cp)
		}
		6 {
			if cp < int(c.first_code) || cp - int(c.first_code) >= c.glyph_ids.len {
				return none
			}
			return c.glyph_ids[cp - int(c.first_code)]
		}
		12 {
			// Binary search over the sorted coverage groups.
			mut lo := 0
			mut hi := c.groups.len
			for lo < hi {
				mid := (lo + hi) >> 1
				g := c.groups[mid]
				if cp < g.start_cp {
					hi = mid
				} else if cp > g.end_cp {
					lo = mid + 1
				} else {
					return u16(g.start_gid + (cp - g.start_cp))
				}
			}
			return none
		}
		else {
			return none
		}
	}
}

fn (c &Cmap) lookup_format4(cp u32) ?u16 {
	if cp > 0xFFFF {
		return none
	}
	target := u16(cp)
	// Segment arrays are sorted by endCode, so a binary search is valid.
	mut lo := 0
	mut hi := c.end_code.len
	for lo < hi {
		mid := (lo + hi) >> 1
		if c.end_code[mid] < target {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo >= c.start_code.len {
		return none
	}
	if target < c.start_code[lo] {
		return none
	}
	delta := c.id_delta[lo]
	range_off := c.id_range[lo]
	if range_off == 0 {
		return u16(u32(target) + u32(delta))
	}
	// idRangeOffset is a byte offset from its own slot into glyphIdArray.
	idx := c.glyph_array_off + lo * 2 + int(range_off) +
		int(target - c.start_code[lo]) * 2
	mut r := new_reader(c.data)
	if !r.has(idx, 2) {
		return none
	}
	gid := r.u16_at(idx)
	if gid == 0 {
		return u16(0)
	}
	return u16(u32(gid) + u32(delta))
}

// glyph_index_for maps cp through the first subtable that has an opinion.
fn glyph_index_for(cmaps []Cmap, cp u32) u16 {
	for c in cmaps {
		if g := c.lookup_glyph(cp) {
			if g != 0 {
				return g
			}
		}
	}
	// Explicitly-zero glyphs mean the font really does map cp to .notdef.
	for c in cmaps {
		if g := c.lookup_glyph(cp) {
			return g
		}
	}
	return 0
}
