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
	// id_range_base is the absolute offset of a format 4 idRangeOffset array, which is the
	// base every idRangeOffset value is measured from.
	//
	// It is not the start of glyphIdArray, and the difference is the whole bug this field was
	// renamed for: the specification measures each offset from the address of its own slot, so
	// a segment's first entry lives segCount*2 bytes before glyphIdArray and every entry after
	// that lives correspondingly earlier than a base of glyphIdArray would put it. Reading a
	// font with this wrong does not fail, and does not obviously misbehave either: glyphIdArray
	// is a dense run of glyph indices, so reading segCount*2 bytes too far lands on a real but
	// wrong glyph, one that looks like a plausible neighbour. Dubai is a font that has this
	// wrong: its Arabic letters came out as the glyph three places along, which is why none of
	// its positional features matched anything.
	id_range_base int
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
	// format 14: one record per variation selector, and the two tables those records point at.
	//
	// A format 14 subtable is not a codepoint-to-glyph map. It answers "which glyph is this codepoint
	// given the selectors that follow it", and the selector is consumed by that question rather than
	// looked up on its own, so none of this is reachable from lookup_glyph.
	selectors []VsRecord
	vs_ranges []VsRange
	vs_maps   []VsMapping
	// score orders competing subtables. Higher wins; see cmap_preference.
	score int
}

// CmapGroup is one startCharCode..endCharCode span of a format 12 subtable.
struct CmapGroup {
	start_cp  u32
	end_cp    u32
	start_gid u32
}

// VsRecord is one variation selector's two offsets into a format 14 subtable's tables.
//
// Both offsets are from the start of the subtable rather than from the record, which is the
// specification's own choice and the reason a format 14 length field is a uint32 while every other
// format's is a uint16.
struct VsRecord {
	selector  u32
	def_off   int
	nodef_off int
}

// VsRange is one span of codepoints in a format 14 default table, which says "these bases have an
// emoji presentation" without naming a glyph. The glyph is the base's own, from the ordinary subtable.
struct VsRange {
	start  u32
	length u32
}

// VsMapping is one base codepoint and the glyph a selector asks for instead of the base's own.
struct VsMapping {
	base u32
	gid  u16
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
			13 {
				parse_cmap_format13(mut &sub, r, off)
			}
			14 {
				parse_cmap_format14(mut &sub, r, off)
			}
			else {}
		}
		// A subtable that parsed to nothing is useless; drop it.
		//
		// A format 14 subtable reaches this test through selectors rather than through any of the
		// three arrays above, because it answers a different question and cannot be stored in the
		// shape the others are stored in. It is therefore named here explicitly, and the reason is
		// that a font whose only non-BMP subtable is a format 14 one would otherwise be reported as
		// having no usable character map at all.
		if sub.glyph_ids.len == 0 && sub.start_code.len == 0 && sub.groups.len == 0
			&& sub.selectors.len == 0 {
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
	// The base every idRangeOffset is measured from is the address of the idRangeOffset array
	// itself, not the start of the glyphIdArray that follows it.
	sub.id_range_base = p
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

// parse_cmap_format13 reads the many-to-one range form.
//
// It is format 12 with one difference that matters: a whole range of codepoints maps to a single
// glyph, so the start glyph is not incremented as the codepoint advances. Apple writes this for the
// variant pairs in the Apple Symbols and Punctuation blocks, where a ligature glyph stands for both
// members of a pair and the text is written as either of them.
fn parse_cmap_format13(mut sub &Cmap, r Reader, off int) {
	if !r.has(off + 12, 4) {
		return
	}
	mut num_groups := int(r.u32_at(off + 12))
	if num_groups <= 0 {
		return
	}
	// 12 bytes per group, of which the codepoints are three bytes each.
	avail := (r.len() - (off + 16)) / 12
	if num_groups > avail {
		num_groups = avail
	}
	sub.groups = []CmapGroup{len: num_groups}
	for i in 0 .. num_groups {
		g := off + 16 + i * 12
		sub.groups[i] = CmapGroup{
			start_cp:  r.u24_at(g)
			end_cp:    r.u24_at(g + 3)
			start_gid: r.u32_at(g + 6)
		}
	}
}

// parse_cmap_format14 reads the variation sequence table.
//
// Three things about this format are not what the other formats are, and every one of them produces a
// table that reads as empty rather than as broken, so a font with one of them wrong still draws.
//
// The second field is a **uint32** length where every other format's is a uint16. Read as a uint16 a
// 741-byte subtable has a length under 256, which makes every offset after it look like it points
// outside the table.
//
// The records start at offset 10, immediately after the header, and **there is no count of them**. The
// header is the format, the uint32 length and the uint32 language, and then the records begin — so at
// offset 10 of Segoe UI Emoji is the selector U+FE0F itself, which is also where a reader expecting a
// uint32 count finds 0x00FE0000 and concludes there are sixteen million of them. The scan therefore
// ends on the first record whose table offsets point outside the subtable, which is the only signal
// available and is unambiguous: a real record's offsets are either zero or inside it.
//
// Each record is **11** bytes: a uint24 selector then two uint32 offsets. It is not 12, because the two
// offsets that follow the uint24 are not aligned to anything.
fn parse_cmap_format14(mut sub &Cmap, r Reader, off int) {
	if !r.has(off + 10, 4) {
		return
	}
	// A length of zero is a font claiming the subtable is empty, which is not the same as a font that
	// left the field unset. Both are handled by the bounds check rather than trusted.
	length := int(r.u32_at(off + 2))
	// A font cannot have more variation selectors than the supplementary plane holds, so this is a
	// ceiling rather than an expectation. It stops a malformed length from running the scan off the
	// end of the buffer.
	mut ceiling := 512
	if length > 10 {
		ceiling = (length - 10) / 11
		if ceiling > 512 {
			ceiling = 512
		}
	}
	sub.selectors = []VsRecord{cap: ceiling}
	mut def_ranges := 0
	mut def_maps := 0
	for i in 0 .. ceiling {
		at := off + 10 + i * 11
		if !r.has(at, 11) {
			break
		}
		def_off := int(r.u32_at(at + 3))
		nodef_off := int(r.u32_at(at + 7))
		// This is the terminator, and it has to be checked before either table is read: for a font
		// with one record, the second "record" is the default table's own bytes, and taking its
		// numbers for offsets produces a subtable that looks enormous and answers nothing.
		if def_off >= length || nodef_off >= length {
			break
		}
		sub.selectors << VsRecord{
			selector:  r.u24_at(at)
			def_off:   if def_off == 0 { 0 } else { off + def_off }
			nodef_off: if nodef_off == 0 { 0 } else { off + nodef_off }
		}
		if def_off != 0 {
			def_ranges++
		}
		if nodef_off != 0 {
			def_maps++
		}
	}
	if def_ranges > 0 {
		sub.vs_ranges = parse_vs_default(r, sub.selectors)
	}
	if def_maps > 0 {
		sub.vs_maps = parse_vs_non_default(r, sub.selectors)
	}
}

// parse_vs_default reads the default-UVS table, which is a list of spans of codepoints that have an
// emoji presentation. The offsets are all the same table, so the first record that has one is enough.
//
// The spans are **four** bytes each: a uint24 start and a uint8 count. Reading them as five, by adding
// the two fields as if they were 4-byte words, walks off the end of a table of a hundred-odd spans and
// finds nothing, and a lookup that finds nothing reports "no opinion" for every pair — which is
// indistinguishable, from the outside, from a font with no emoji support at all.
fn parse_vs_default(r Reader, records []VsRecord) []VsRange {
	mut at := -1
	for rec in records {
		if rec.def_off != 0 {
			at = rec.def_off
			break
		}
	}
	if at < 0 || !r.has(at, 4) {
		return []VsRange{}
	}
	mut count := int(r.u32_at(at))
	if count <= 0 {
		return []VsRange{}
	}
	if count > (r.len() - (at + 4)) / 4 {
		count = (r.len() - (at + 4)) / 4
	}
	mut out := []VsRange{len: count}
	for i in 0 .. count {
		g := at + 4 + i * 4
		out[i] = VsRange{
			start:  r.u24_at(g)
			length: u32(r.u8_at(g + 3))
		}
	}
	return out
}

// parse_vs_non_default reads the non-default-UVS table, which names the glyph to use instead of the
// base's own. Five bytes per entry: a uint24 codepoint and a uint16 glyph, packed.
fn parse_vs_non_default(r Reader, records []VsRecord) []VsMapping {
	mut at := -1
	for rec in records {
		if rec.nodef_off != 0 {
			at = rec.nodef_off
			break
		}
	}
	if at < 0 || !r.has(at, 4) {
		return []VsMapping{}
	}
	mut count := int(r.u32_at(at))
	if count <= 0 {
		return []VsMapping{}
	}
	if count > (r.len() - (at + 4)) / 5 {
		count = (r.len() - (at + 4)) / 5
	}
	mut out := []VsMapping{len: count}
	for i in 0 .. count {
		g := at + 4 + i * 5
		out[i] = VsMapping{
			base: r.u24_at(g)
			gid:  r.u16_at(g + 3)
		}
	}
	return out
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
		13 {
			// The same binary search over the same shape of group, and the one difference is that
			// the glyph does not advance with the codepoint: a whole span is one glyph.
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
					return u16(g.start_gid)
				}
			}
			return none
		}
		else {
			// A format 14 subtable is reached through lookup_variation, not here. Answering "no
			// opinion" for a bare codepoint is what keeps it out of the way of a base character: a
			// selector changes which glyph a base draws as, and a base on its own is still whatever
			// the font's ordinary subtables say it is.
			return none
		}
	}
}

// lookup_variation answers "which glyph is this base when these selectors follow it", or none when
// this subtable has nothing to say about the pair.
//
// It is a separate function rather than another parameter on lookup_glyph because the two questions
// are different shapes. lookup_glyph is a pure function of one codepoint and everything in this
// module, from glyph_index_for to the fallback chain, is built on that. A variation sequence is a pair,
// and the selector is consumed by the lookup rather than looked up itself: U+FE0F has no glyph of its
// own anywhere, and asking for one is the mistake this split exists to make impossible.
//
// The answer is a glyph, not a flag. For a non-default mapping it is the glyph the table names; for a
// default one it is the base's own glyph, which the caller has to look up elsewhere, so this returns
// the base's id by asking the ordinary subtables through `fallback`.
fn (c &Cmap) lookup_variation(base u32, selector u32, fallback fn (u32) ?u16) ?u16 {
	if c.format != 14 {
		return none
	}
	for rec in c.selectors {
		if rec.selector != selector {
			continue
		}
		// A non-default mapping names the glyph outright, and a hit there is the whole answer.
		// It is checked before the default table because a base can appear in both.
		if rec.nodef_off != 0 {
			mut lo := 0
			mut hi := c.vs_maps.len
			for lo < hi {
				mid := (lo + hi) >> 1
				m := c.vs_maps[mid]
				if base < m.base {
					hi = mid
				} else if base > m.base {
					lo = mid + 1
				} else {
					return m.gid
				}
			}
		}
		if rec.def_off != 0 && vs_covers(c.vs_ranges, base) {
			// The default table says this base has an emoji presentation and does not say which
			// glyph it is, because it is the base's own from the ordinary subtable. That is the
			// whole content of the emoji-presentation flag: it does not rename the glyph, it
			// releases the base from having a text presentation.
			return fallback(base)
		}
		return none
	}
	return none
}

// vs_covers reports whether a base codepoint is in the default table's spans.
fn vs_covers(ranges []VsRange, base u32) bool {
	mut lo := 0
	mut hi := ranges.len
	for lo < hi {
		mid := (lo + hi) >> 1
		span := ranges[mid]
		if base < span.start {
			hi = mid
		} else if base > span.start + span.length {
			lo = mid + 1
		} else {
			return true
		}
	}
	return false
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
	// idRangeOffset is a byte offset from its own slot into glyphIdArray, so the address is
	// the slot's address and not the start of the array after it. The two differ by
	// segCount*2 bytes, which is segCount glyph indices, and reading from the wrong one yields a
	// neighbouring glyph rather than an obvious failure.
	idx := c.id_range_base + lo * 2 + int(range_off) +
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

// glyph_index_variation_for maps a base codepoint with a variation selector after it.
//
// The two halves answer different questions and the order is the specification's. A subtable with a
// non-default mapping for the pair names the glyph outright and wins outright. Failing that, a
// subtable whose default table covers the base means the pair draws the base's own glyph — which is
// this function's whole answer for that case, and the reason it is a separate function rather than a
// flag on glyph_index_for.
//
// Nothing here is consulted for the base on its own, so a font whose format 14 table covers a base
// still draws that base as text when no selector follows it. That is the difference between a
// variation sequence and a character, and getting it wrong draws every emoji as text.
fn glyph_index_variation_for(cmaps []Cmap, base u32, selector u32) u16 {
	// The closure is a named function value rather than an inline one because it has to reach this
	// subtable list, and V will not let an untyped expression become a `fn` parameter.
	ordinary := fn [cmaps] (cp u32) ?u16 {
		return glyph_index_for(cmaps, cp)
	}
	for c in cmaps {
		if g := c.lookup_variation(base, selector, ordinary) {
			return g
		}
	}
	return 0
}

// has_variation_sequence reports whether any subtable has an opinion about this pair at all.
//
// The fallback chain needs this as a separate question from "what glyph is it", because a chain that
// asks only the second one cannot tell "this font cannot draw that sequence" from "this font draws it
// as the text presentation", and those two need different answers: the first moves on to the next
// font, the second is a result.
fn has_variation_sequence(cmaps []Cmap, base u32, selector u32) bool {
	ordinary := fn [cmaps] (cp u32) ?u16 {
		return glyph_index_for(cmaps, cp)
	}
	for c in cmaps {
		if c.lookup_variation(base, selector, ordinary) != none {
			return true
		}
	}
	return false
}
