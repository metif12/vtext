module font

import math

// HVAR, MVAR and cvar readers: advance, metric and CVT variation.
//
// This file reads the three variation-adjustment tables that sit beside
// gvar: HVAR (glyph advance variations), MVAR (font-wide metric variations)
// and cvar (CVT variations for hinting). It is standalone by design: it
// takes raw table bytes from `Sfnt.table_data` and answers pure lookups
// over parsed tables, with no raster wiring and no shared state with
// `var.v`. The instancing path in `var.v` derives advances from the gvar
// phantom points; when a font carries HVAR that table is authoritative
// instead, and reading it is this file's job. Nothing here touches Face.
//
// The evaluation rule is the same one fontTools uses, beside which every
// pin is measured:
//
//   1. blend coordinates are the avar-warped normalized coordinates
//      (`var_blend_coords` in `var.v`), one per fvar axis;
//   2. each VarStore region contributes its per-axis tent product
//      (`supportScalar` in fontTools terms): 1 at the peak, ramping
//      linearly to 0 at the region edges, 0 outside;
//   3. each item's delta is the sum over its regions of delta * scalar,
//      rounded once half up (`otRound`).
//
// HVAR maps glyph ids to variation indexes through DeltaSetIndexMaps; a
// NULL map offset means the identity (outer 0, inner gid), the way the
// large CJK faces use it. MVAR maps four-letter metric tags to variation
// indexes directly. cvar carries gvar-style tuple variations over CVT
// indexes, with single deltas rather than x/y pairs.
//
// All offsets are from the start of the table that holds them, exactly as
// the specification writes them, and every read is bounds-checked through
// Reader: a truncated table is an error, never a plausible number.

// hvar_no_variation_idx is the varIdx that means "no adjustment": 0xFFFFFFFF
// in u32 terms, which is -1 as a signed int. HarfBuzz and fontTools both
// read it as zero delta.
pub const hvar_no_variation_idx = -1

// HvarTriple is one axis of one variation region: start, peak and end in
// normalized coordinates, decoded from F2DOT14.
pub struct HvarTriple {
pub:
	start f64
	peak  f64
	end   f64
}

// HvarVarData is one ItemVariationData subtable: the region indexes its
// items share and the deltas per item, one per region index.
pub struct HvarVarData {
pub:
	region_indexes []int
	// deltas[item][region_pos] in font units.
	deltas [][]int
}

// HvarVarStore is a parsed ItemVariationStore: the axis count its regions
// span, the regions themselves and the data subtables.
pub struct HvarVarStore {
pub:
	axis_count int
	// regions[region_idx][axis_idx].
	regions [][]HvarTriple
	datas   []HvarVarData
}

// HvarDeltaMap is a parsed DeltaSetIndexMap: glyph id to varIdx. When
// present is false the table offset was NULL and the lookup is the
// identity (outer 0, inner gid).
pub struct HvarDeltaMap {
pub:
	present  bool
	var_idxs []int
}

// HvarTable is a parsed HVAR table: the store plus the three glyph maps.
// Only the advance map is populated in the corpus; lsb/rsb stay absent
// (NULL offset) on every committed variable face.
pub struct HvarTable {
pub:
	has_store bool
	store     HvarVarStore
	adv_map   HvarDeltaMap
	lsb_map   HvarDeltaMap
	rsb_map   HvarDeltaMap
}

// MvarRecord pairs a four-letter metric tag (cpht, stro, xhgt, ...) with
// its combined variation index.
pub struct MvarRecord {
pub:
	tag     string
	var_idx int
}

// MvarTable is a parsed MVAR table: the store plus the value records.
pub struct MvarTable {
pub:
	has_store bool
	store     HvarVarStore
	records   []MvarRecord
}

// CvarTuple is one cvar tuple variation: its applicability region and
// the CVT deltas for its points.
pub struct CvarTuple {
pub:
	peak  []f64
	start []f64
	end   []f64
	// points are CVT indexes; when all_points is true the deltas cover
	// every CVT value in order and points is empty.
	points     []int
	deltas     []int
	all_points bool
}

// CvarTable is a parsed cvar table: the tuples plus the shape they were
// parsed against.
pub struct CvarTable {
pub:
	axis_count int
	cvt_count  int
	tuples     []CvarTuple
}

// hvar_f2dot14 decodes an F2DOT14 fixed-point number: a signed 16-bit value
// over 16384. Tuple peaks and region edges are stored this way, so a peak
// of exactly 1.0 comes out as exactly 1.0.
fn hvar_f2dot14(v i16) f64 {
	return f64(v) / 16384.0
}

// hvar_ot_round rounds half up, towards positive infinity. This is otRound
// from fontTools: 7.5 becomes 8, -22.5 becomes -22, which is what makes
// the mid-weight HVAR pins land where the decompiler puts them.
pub fn hvar_ot_round(x f64) int {
	return int(math.floor(x + 0.5))
}

// hvar_region_scalar evaluates one variation region at the blend
// coordinates: the product over axes of the per-axis tent factor.
//
// An axis whose peak is 0 does not participate, an invalid region (peak
// outside start..end, or a region crossing zero) does not participate, and
// a coordinate exactly at the peak contributes 1. Outside the region the
// factor is 0, which zeroes the whole product. This is supportScalar in
// fontTools terms and var_tuple_scalar in var.v terms, repeated here so
// this file stays standalone.
fn hvar_region_scalar(region []HvarTriple, blended []f64) f64 {
	mut scalar := 1.0
	for a in 0 .. region.len {
		t := region[a]
		p := t.peak
		if p == 0.0 {
			continue
		}
		if t.start > p || p > t.end {
			continue
		}
		if t.start < 0.0 && t.end > 0.0 {
			continue
		}
		v := blended[a]
		if v == p {
			continue
		}
		if v <= t.start || t.end <= v {
			return 0.0
		}
		if v < p {
			scalar *= (v - t.start) / (p - t.start)
		} else {
			scalar *= (v - t.end) / (p - t.end)
		}
	}
	return scalar
}

// hvar_parse_var_store parses an ItemVariationStore at offset at inside
// data, where data is the whole HVAR or MVAR table and at is the store
// offset from the start of that table. Every offset inside the store is
// likewise from the start of the store.
fn hvar_parse_var_store(data []u8, at int) !HvarVarStore {
	r := new_reader(data)
	if !r.has(at, 8) {
		return error('hvar: VarStore header at ${at} outside ${data.len} bytes')
	}
	if r.u16_at(at) != 1 {
		return error('hvar: unsupported VarStore format ${r.u16_at(at)}')
	}
	region_at := at + int(r.u32_at(at + 2))
	data_count := int(r.u16_at(at + 6))
	if !r.has(at + 8, data_count * 4) {
		return error('hvar: ${data_count} VarData offsets overrun the table')
	}
	if !r.has(region_at, 4) {
		return error('hvar: VarRegionList at ${region_at} outside ${data.len} bytes')
	}
	axis_count := int(r.u16_at(region_at))
	region_count := int(r.u16_at(region_at + 2))
	if !r.has(region_at + 4, region_count * axis_count * 6) {
		return error('hvar: ${region_count} regions overrun the table')
	}
	mut regions := [][]HvarTriple{len: region_count}
	for i in 0 .. region_count {
		mut reg := []HvarTriple{len: axis_count}
		base := region_at + 4 + i * axis_count * 6
		for a in 0 .. axis_count {
			reg[a] = HvarTriple{
				start: hvar_f2dot14(r.i16_at(base + a * 6))
				peak:  hvar_f2dot14(r.i16_at(base + a * 6 + 2))
				end:   hvar_f2dot14(r.i16_at(base + a * 6 + 4))
			}
		}
		regions[i] = reg
	}
	mut datas := []HvarVarData{len: data_count}
	for d in 0 .. data_count {
		doff := at + int(r.u32_at(at + 8 + d * 4))
		if !r.has(doff, 6) {
			return error('hvar: VarData ${d} at ${doff} outside ${data.len} bytes')
		}
		item_count := int(r.u16_at(doff))
		num_shorts_raw := int(r.u16_at(doff + 2))
		region_index_count := int(r.u16_at(doff + 4))
		long_words := num_shorts_raw & 0x8000 != 0
		word_count := num_shorts_raw & 0x7fff
		if !r.has(doff + 6, region_index_count * 2) {
			return error('hvar: VarData ${d} region indexes overrun the table')
		}
		mut ridx := []int{len: region_index_count}
		for k in 0 .. region_index_count {
			ridx[k] = int(r.u16_at(doff + 6 + k * 2))
		}
		mut pos := doff + 6 + region_index_count * 2
		mut items := [][]int{len: item_count}
		for it in 0 .. item_count {
			mut vals := []int{len: region_index_count}
			n1 := if region_index_count < word_count {
				region_index_count
			} else {
				word_count
			}
			n2 := if region_index_count > word_count {
				region_index_count
			} else {
				word_count
			}
			// First n1 values are wide (short or long), the rest narrow.
			for k in 0 .. n1 {
				if long_words {
					if !r.has(pos, 4) {
						return error('hvar: VarData ${d} item ${it} long overruns the table')
					}
					vals[k] = int(r.i32_at(pos))
					pos += 4
				} else {
					if !r.has(pos, 2) {
						return error('hvar: VarData ${d} item ${it} short overruns the table')
					}
					vals[k] = int(r.i16_at(pos))
					pos += 2
				}
			}
			for k in n1 .. region_index_count {
				if long_words {
					if !r.has(pos, 2) {
						return error('hvar: VarData ${d} item ${it} short tail overruns the table')
					}
					vals[k] = int(r.i16_at(pos))
					pos += 2
				} else {
					if !r.has(pos, 1) {
						return error('hvar: VarData ${d} item ${it} byte overruns the table')
					}
					vals[k] = int(i8(r.u8_at(pos)))
					pos += 1
				}
			}
			// Padding when word_count exceeds the region count: small
			// values that pad the row to the word width, discarded.
			// Small is a short when long_words holds, else a byte.
			for _ in region_index_count .. n2 {
				if long_words {
					if !r.has(pos, 2) {
						return error('hvar: VarData ${d} item ${it} padding overruns the table')
					}
					pos += 2
				} else {
					if !r.has(pos, 1) {
						return error('hvar: VarData ${d} item ${it} padding overruns the table')
					}
					pos += 1
				}
			}
			items[it] = vals
		}
		datas[d] = HvarVarData{
			region_indexes: ridx
			deltas:         items
		}
	}
	return HvarVarStore{
		axis_count: axis_count
		regions:    regions
		datas:      datas
	}
}

// hvar_parse_index_map parses one DeltaSetIndexMap at offset at inside
// data. A zero at (a NULL offset) is not parsed here; the caller turns it
// into an absent map.
fn hvar_parse_index_map(data []u8, at int) !HvarDeltaMap {
	r := new_reader(data)
	if !r.has(at, 4) {
		return error('hvar: index map at ${at} outside ${data.len} bytes')
	}
	format := int(r.u8_at(at))
	entry_format := int(r.u8_at(at + 1))
	mut mapping_count := 0
	mut header_len := 0
	if format == 0 {
		mapping_count = int(r.u16_at(at + 2))
		header_len = 4
	} else if format == 1 {
		if !r.has(at, 6) {
			return error('hvar: format-1 index map at ${at} outside ${data.len} bytes')
		}
		mapping_count = int(r.u32_at(at + 2))
		header_len = 6
	} else {
		return error('hvar: unsupported index map format ${format}')
	}
	inner_bits := 1 + (entry_format & 0x0f)
	entry_size := 1 + ((entry_format >> 4) & 3)
	if inner_bits < 1 || inner_bits > 16 {
		return error('hvar: bad index map entry format 0x${entry_format:02x}')
	}
	if entry_size < 1 || entry_size > 4 {
		return error('hvar: bad index map entry size ${entry_size}')
	}
	if !r.has(at + header_len, mapping_count * entry_size) {
		return error('hvar: ${mapping_count} index entries overrun the table')
	}
	inner_mask := u32((u64(1) << u64(inner_bits)) - 1)
	outer_mask := u32(0xffffffff) - inner_mask
	outer_shift := 16 - inner_bits
	mut out := []int{len: mapping_count}
	for i in 0 .. mapping_count {
		base := at + header_len + i * entry_size
		mut raw := u32(0)
		for b in 0 .. entry_size {
			raw = (raw << 8) | u32(r.u8_at(base + b))
		}
		// The stored value packs outer in the high bits above the
		// inner field; shifting it back out recovers the varIdx.
		vidx := ((raw & outer_mask) << u32(outer_shift)) | (raw & inner_mask)
		out[i] = int(vidx)
	}
	return HvarDeltaMap{
		present:  true
		var_idxs: out
	}
}

// hvar_parse parses a whole HVAR table: version, store and the three maps.
// A NULL map offset parses to an absent map, which reads as the identity.
pub fn hvar_parse(table []u8) !HvarTable {
	if table.len == 0 {
		return error('hvar: empty HVAR table')
	}
	r := new_reader(table)
	if !r.has(0, 20) {
		return error('hvar: HVAR table too short (${table.len} bytes)')
	}
	if r.u32_at(0) != 0x00010000 {
		return error('hvar: unsupported HVAR version 0x${r.u32_at(0):08x}')
	}
	vs_off := int(r.u32_at(4))
	adv_off := int(r.u32_at(8))
	lsb_off := int(r.u32_at(12))
	rsb_off := int(r.u32_at(16))
	mut has_store := false
	mut store := HvarVarStore{}
	if vs_off != 0 {
		store = hvar_parse_var_store(table, vs_off) or { return err }
		has_store = true
	}
	mut adv := HvarDeltaMap{
		present: false
	}
	mut lsb := HvarDeltaMap{
		present: false
	}
	mut rsb := HvarDeltaMap{
		present: false
	}
	if adv_off != 0 {
		adv = hvar_parse_index_map(table, adv_off) or { return err }
	}
	if lsb_off != 0 {
		lsb = hvar_parse_index_map(table, lsb_off) or { return err }
	}
	if rsb_off != 0 {
		rsb = hvar_parse_index_map(table, rsb_off) or { return err }
	}
	return HvarTable{
		has_store: has_store
		store:     store
		adv_map:   adv
		lsb_map:   lsb
		rsb_map:   rsb
	}
}

// hvar_map_var_idx answers the varIdx for gid through map: the mapped
// value when present, the identity (outer 0, inner gid) when the map was
// NULL, and the no-variation sentinel when gid is outside a present map.
// hvar_map_var_idx answers the varIdx for gid through m: the mapped
// value when present, the identity (outer 0, inner gid) when the map was
// NULL, and the last stored value when gid runs past a trimmed map.
//
// Trimming is how the file saves space: preWrite drops trailing duplicates,
// so a map shorter than the glyph count repeats its last value for the
// tail (fontTools pads the same way on read). gid past the font's glyph
// count is caller error; it reads the same tail value.
fn hvar_map_var_idx(m HvarDeltaMap, gid int) int {
	if !m.present {
		return gid
	}
	if m.var_idxs.len == 0 {
		return hvar_no_variation_idx
	}
	if gid < 0 {
		return hvar_no_variation_idx
	}
	if gid < m.var_idxs.len {
		return m.var_idxs[gid]
	}
	return m.var_idxs[m.var_idxs.len - 1]
}

// hvar_adv_var_idx answers the HVAR advance varIdx for gid.
pub fn hvar_adv_var_idx(table HvarTable, gid int) int {
	return hvar_map_var_idx(table.adv_map, gid)
}

// hvar_lsb_var_idx answers the HVAR LSB varIdx for gid.
pub fn hvar_lsb_var_idx(table HvarTable, gid int) int {
	return hvar_map_var_idx(table.lsb_map, gid)
}

// hvar_rsb_var_idx answers the HVAR RSB varIdx for gid.
pub fn hvar_rsb_var_idx(table HvarTable, gid int) int {
	return hvar_map_var_idx(table.rsb_map, gid)
}

// hvar_store_delta evaluates the store at var_idx for the blend
// coordinates and answers the rounded adjustment in font units.
//
// An out-of-range varIdx (outer past the data list, inner past the items,
// region index past the region list) contributes zero, the way HarfBuzz
// reads it, rather than erroring. A blend length that does not match the
// store axis count is a caller error. With no store the answer is zero.
pub fn hvar_store_delta(store HvarVarStore, has_store bool, var_idx int, blended []f64) !int {
	if !has_store {
		return 0
	}
	if var_idx == hvar_no_variation_idx {
		return 0
	}
	if blended.len != store.axis_count {
		return error('hvar: ${blended.len} blend coordinates for ${store.axis_count} store axes')
	}
	outer := u32(var_idx) >> 16
	inner := int(u32(var_idx) & 0xffff)
	if int(outer) >= store.datas.len {
		return 0
	}
	data := store.datas[outer]
	if inner >= data.deltas.len {
		return 0
	}
	row := data.deltas[inner]
	mut total := 0.0
	for k in 0 .. data.region_indexes.len {
		ri := data.region_indexes[k]
		if ri < 0 || ri >= store.regions.len {
			continue
		}
		if k >= row.len {
			break
		}
		d := row[k]
		if d == 0 {
			continue
		}
		s := hvar_region_scalar(store.regions[ri], blended)
		if s == 0.0 {
			continue
		}
		total += f64(d) * s
	}
	return hvar_ot_round(total)
}

// hvar_advance_delta answers the HVAR advance adjustment for gid at the
// blend coordinates, in font units, rounded half up.
pub fn hvar_advance_delta(table HvarTable, gid int, blended []f64) !int {
	return hvar_store_delta(table.store, table.has_store, hvar_adv_var_idx(table, gid), blended)
}

// hvar_lsb_delta answers the HVAR left side bearing adjustment.
pub fn hvar_lsb_delta(table HvarTable, gid int, blended []f64) !int {
	return hvar_store_delta(table.store, table.has_store, hvar_lsb_var_idx(table, gid), blended)
}

// hvar_rsb_delta answers the HVAR right side bearing adjustment.
pub fn hvar_rsb_delta(table HvarTable, gid int, blended []f64) !int {
	return hvar_store_delta(table.store, table.has_store, hvar_rsb_var_idx(table, gid), blended)
}

// mvar_parse parses a whole MVAR table: version, value records and store.
// The store offset is a uint16 from the start of the table; zero means no
// store, whose lookups all answer zero.
pub fn mvar_parse(table []u8) !MvarTable {
	if table.len == 0 {
		return error('mvar: empty MVAR table')
	}
	r := new_reader(table)
	if !r.has(0, 12) {
		return error('mvar: MVAR table too short (${table.len} bytes)')
	}
	if r.u32_at(0) != 0x00010000 {
		return error('mvar: unsupported MVAR version 0x${r.u32_at(0):08x}')
	}
	rec_size := int(r.u16_at(6))
	rec_count := int(r.u16_at(8))
	vs_off := int(r.u16_at(10))
	if rec_size < 8 {
		return error('mvar: value record size ${rec_size} below 8')
	}
	if !r.has(12, rec_count * rec_size) {
		return error('mvar: ${rec_count} value records overrun the table')
	}
	mut records := []MvarRecord{len: rec_count}
	for i in 0 .. rec_count {
		at := 12 + i * rec_size
		tag := r.tag_at(at)
		vidx := int(r.u32_at(at + 4))
		records[i] = MvarRecord{
			tag:     tag
			var_idx: vidx
		}
	}
	mut has_store := false
	mut store := HvarVarStore{}
	if vs_off != 0 {
		store = hvar_parse_var_store(table, vs_off) or { return err }
		has_store = true
	}
	return MvarTable{
		has_store: has_store
		store:     store
		records:   records
	}
}

// mvar_delta answers the MVAR adjustment for tag at the blend
// coordinates, in font units, rounded half up. An unknown tag is an error;
// a table with no store answers zero.
pub fn mvar_delta(table MvarTable, tag string, blended []f64) !int {
	for rec in table.records {
		if rec.tag == tag {
			return hvar_store_delta(table.store, table.has_store, rec.var_idx, blended)
		}
	}
	return error('mvar: unknown value tag `${tag}`')
}

// hvar_unpack_points decodes a packed point-number run: a count (one byte,
// or two when the high bit is set), then runs of delta-encoded numbers.
// A count of zero means every point: it answers empty with all set.
fn hvar_unpack_points(data []u8, at int, num_points int) !([]int, int, bool) {
	r := new_reader(data)
	if !r.has(at, 1) {
		return error('cvar: point count at ${at} outside ${data.len} bytes')
	}
	mut count := int(r.u8_at(at))
	mut pos := at + 1
	if count & 0x80 != 0 {
		if !r.has(pos, 1) {
			return error('cvar: two-byte point count overruns the table')
		}
		count = ((count & 0x7f) << 8) | int(r.u8_at(pos))
		pos++
	}
	if count == 0 {
		return []int{}, pos, true
	}
	mut out := []int{cap: count}
	mut cur := 0
	for out.len < count {
		if !r.has(pos, 1) {
			return error('cvar: point run header overruns the table')
		}
		h := int(r.u8_at(pos))
		pos++
		n := (h & 0x7f) + 1
		words := h & 0x80 != 0
		for _ in 0 .. n {
			if words {
				if !r.has(pos, 2) {
					return error('cvar: word point number overruns the table')
				}
				cur += int(r.u16_at(pos))
				pos += 2
			} else {
				if !r.has(pos, 1) {
					return error('cvar: byte point number overruns the table')
				}
				cur += int(r.u8_at(pos))
				pos += 1
			}
			out << cur
		}
	}
	_ = num_points
	return out, pos, false
}

// hvar_unpack_deltas decodes one packed delta run into exactly count
// values: zero-fill, byte, word or long runs, each one longer than its low
// six bits say.
fn hvar_unpack_deltas(data []u8, at int, count int) !([]int, int) {
	r := new_reader(data)
	mut out := []int{cap: count}
	mut pos := at
	for out.len < count {
		if !r.has(pos, 1) {
			return error('cvar: delta run header at ${pos} outside ${data.len} bytes')
		}
		h := int(r.u8_at(pos))
		pos++
		n := (h & 0x3f) + 1
		kind := h & 0xc0
		if kind == 0x80 {
			for _ in 0 .. n {
				out << 0
			}
		} else if kind == 0x40 {
			for _ in 0 .. n {
				if !r.has(pos, 2) {
					return error('cvar: word delta overruns the table')
				}
				out << int(r.i16_at(pos))
				pos += 2
			}
		} else if kind == 0xc0 {
			for _ in 0 .. n {
				if !r.has(pos, 4) {
					return error('cvar: long delta overruns the table')
				}
				out << int(r.i32_at(pos))
				pos += 4
			}
		} else {
			for _ in 0 .. n {
				if !r.has(pos, 1) {
					return error('cvar: byte delta overruns the table')
				}
				out << int(i8(r.u8_at(pos)))
				pos += 1
			}
		}
	}
	return out, pos
}

// cvar_parse parses a whole cvar table for axis_count axes over cvt_count
// CVT values. Peaks need the axis count to know how many F2DOT14s to read;
// deltas need the CVT count to know how many values an all-points run
// covers. Shared tuple peaks are refused: the corpus writes every peak
// embedded, and a shared index would have nothing to index.
pub fn cvar_parse(table []u8, axis_count int, cvt_count int) !CvarTable {
	if table.len == 0 {
		return error('cvar: empty cvar table')
	}
	r := new_reader(table)
	if !r.has(0, 8) {
		return error('cvar: cvar table too short (${table.len} bytes)')
	}
	if r.u16_at(0) != 1 || r.u16_at(2) != 0 {
		return error('cvar: unsupported cvar version ${r.u16_at(0)}.${r.u16_at(2)}')
	}
	raw_count := int(r.u16_at(4))
	data_off := int(r.u16_at(6))
	shared_points := raw_count & 0x8000 != 0
	tuple_count := raw_count & 0x0fff
	if axis_count < 0 || cvt_count < 0 {
		return error('cvar: negative axis or CVT count')
	}
	if !r.has(8, 0) || data_off < 8 || data_off > table.len {
		return error('cvar: data offset ${data_off} outside ${table.len} bytes')
	}
	mut pos := 8
	mut data_pos := data_off
	mut shared_pts := []int{}
	mut shared_all := false
	if shared_points {
		pts, next, all := hvar_unpack_points(table, data_pos, cvt_count) or { return err }
		data_pos = next
		shared_pts = pts.clone()
		shared_all = all
	}
	mut out := []CvarTuple{cap: tuple_count}
	for _ in 0 .. tuple_count {
		if !r.has(pos, 4) {
			return error('cvar: tuple header overruns the table')
		}
		data_size := int(r.u16_at(pos))
		flags := int(r.u16_at(pos + 2))
		pos += 4
		embedded := flags & 0x8000 != 0
		intermediate := flags & 0x4000 != 0
		private_pts := flags & 0x2000 != 0
		if !embedded {
			return error('cvar: shared tuple peaks are not supported in this slice')
		}
		tuple_size := 4 + axis_count * 2 + (if intermediate { axis_count * 4 } else { 0 })
		_ = tuple_size
		if !r.has(pos, axis_count * 2) {
			return error('cvar: embedded peak overruns the table')
		}
		mut peak := []f64{len: axis_count}
		for a in 0 .. axis_count {
			peak[a] = hvar_f2dot14(r.i16_at(pos + a * 2))
		}
		pos += axis_count * 2
		mut start := []f64{len: axis_count}
		mut end_ := []f64{len: axis_count}
		if intermediate {
			if !r.has(pos, axis_count * 4) {
				return error('cvar: intermediate region overruns the table')
			}
			for a in 0 .. axis_count {
				start[a] = hvar_f2dot14(r.i16_at(pos + a * 2))
			}
			pos += axis_count * 2
			for a in 0 .. axis_count {
				end_[a] = hvar_f2dot14(r.i16_at(pos + a * 2))
			}
			pos += axis_count * 2
		} else {
			for a in 0 .. axis_count {
				p := peak[a]
				start[a] = if p < 0.0 { p } else { 0.0 }
				end_[a] = if p > 0.0 { p } else { 0.0 }
			}
		}
		aux_at := data_pos
		aux_end := data_pos + data_size
		if aux_end < aux_at || aux_end > table.len {
			return error('cvar: tuple data [${aux_at}..${aux_end}] outside ${table.len} bytes')
		}
		mut pts := shared_pts.clone()
		mut all := shared_all
		mut apos := aux_at
		if private_pts {
			p2, n2, a2 := hvar_unpack_points(table, apos, cvt_count) or { return err }
			apos = n2
			pts = p2.clone()
			all = a2
		}
		n := if all { cvt_count } else { pts.len }
		xd, next_x := hvar_unpack_deltas(table, apos, n) or { return err }
		apos = next_x
		if apos != aux_end {
			// Trailing bytes inside the tuple data mean the point and
			// delta runs did not line up; reading on would desync every
			// tuple after this one.
			if apos > aux_end {
				return error('cvar: tuple deltas overrun their ${data_size} bytes')
			}
		}
		data_pos = aux_end
		out << CvarTuple{
			peak:       peak
			start:      start
			end:        end_
			points:     pts
			deltas:     xd
			all_points: all
		}
	}
	return CvarTable{
		axis_count: axis_count
		cvt_count:  cvt_count
		tuples:     out
	}
}

// cvar_delta answers the cvar adjustment for one CVT index at the blend
// coordinates, in font units, rounded once half up. Tuples whose scalar is
// zero contribute nothing; points the tuples do not name contribute
// nothing, the way the decompiler leaves out-of-range deltas out.
pub fn cvar_delta(table CvarTable, cvt_index int, blended []f64) !int {
	if cvt_index < 0 || cvt_index >= table.cvt_count {
		return error('cvar: CVT index ${cvt_index} outside ${table.cvt_count} values')
	}
	if blended.len != table.axis_count {
		return error('cvar: ${blended.len} blend coordinates for ${table.axis_count} axes')
	}
	mut total := 0.0
	for t in table.tuples {
		mut scalar := 1.0
		for a in 0 .. table.axis_count {
			p := t.peak[a]
			if p == 0.0 {
				continue
			}
			lo := t.start[a]
			hi := t.end[a]
			if lo > p || p > hi {
				continue
			}
			if lo < 0.0 && hi > 0.0 {
				continue
			}
			v := blended[a]
			if v == p {
				continue
			}
			if v <= lo || hi <= v {
				scalar = 0.0
				break
			}
			if v < p {
				scalar *= (v - lo) / (p - lo)
			} else {
				scalar *= (v - hi) / (p - hi)
			}
		}
		if scalar == 0.0 {
			continue
		}
		if t.all_points {
			if cvt_index < t.deltas.len {
				total += f64(t.deltas[cvt_index]) * scalar
			}
		} else {
			for k, p in t.points {
				if p == cvt_index && k < t.deltas.len {
					total += f64(t.deltas[k]) * scalar
					break
				}
			}
		}
	}
	return hvar_ot_round(total)
}
