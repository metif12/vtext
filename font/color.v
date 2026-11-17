module font

import vtext.raster

// Color glyph tables: COLR/CPAL (layered outline color), CBLC/CBDT and
// EBLC/EBDT (embedded bitmap strikes), sbix (Apple bitmap strikes).
//
// This is a standalone reader over the raw table bytes: it takes what
// sfnt.table_data returns and answers what a color glyph is made of, without
// touching Face. The per-glyph rendering behind box_only/render_into lives
// with it (color_box, render_color, render_embedded, sbix_box), because
// methods live in the type's own module and those two calls are the contract
// this file renders behind: a COLR layer is an outline glyph drawn through
// the same stb path, tinted and composited; an embedded bitmap is a strike
// slice expanded to coverage and scaled.
//
// SVG refuses with its reason: vector color documents need an SVG renderer,
// and there is none in this tree. PNG-wrapped bitmaps (CBDT/CBLC image
// formats 17/18/19, sbix 'png '/'jpg '/'tiff ') are read for their boxes and
// carried as bytes, but their pixels are refused for the same structural
// reason: no PNG decoder in the tree (the WOFF2/brotli precedent). What is
// refused says so rather than guessing.
//
// COLR v1 is parsed for its v0 prefix and reported via has_v1; the v1 paint
// graph itself is refused on lookup, because a v0 layer list and a v1 paint
// tree are different answers about the same glyph and only the first is
// implemented.

// CpalColor is one CPAL color entry: 8-bit straight red, green, blue, alpha.
// The table stores them blue-first; the struct is red-first the way callers
// name channels.
pub struct CpalColor {
pub:
	r u8
	g u8
	b u8
	a u8
}

// Cpal is a parsed CPAL table: the version plus one entry list per palette,
// each list holding num_entries colors in palette order.
pub struct Cpal {
pub:
	version  u16
	palettes [][]CpalColor
}

// num_palettes answers how many palettes the table carries.
pub fn (c &Cpal) num_palettes() int {
	return c.palettes.len
}

// num_entries answers how many colors one palette holds. Zero when the table
// carries no palette at all.
pub fn (c &Cpal) num_entries() int {
	if c.palettes.len == 0 {
		return 0
	}
	return c.palettes[0].len
}

// color answers palette p's entry i, or none when either is out of range.
// A palette index of 0xFFFF (the COLR foreground marker) is not a color in
// any palette, so it answers none here and the caller substitutes its own
// foreground.
pub fn (c &Cpal) color(palette u16, index u16) ?CpalColor {
	if index == 0xFFFF {
		return none
	}
	if int(palette) >= c.palettes.len {
		return none
	}
	if int(index) >= c.palettes[palette].len {
		return none
	}
	return c.palettes[palette][index]
}

// parse_cpal reads a CPAL table: version 0 or 1, numPaletteEntries colors per
// palette, numPalettes palettes, then the color records in BGRA order.
//
// Version 1's trailing arrays (palette type and label offsets) are not
// followed: they describe the palettes rather than recoloring any glyph, so
// ignoring them changes no layer's color. A version above 1, a first-record
// offset outside the table, or a palette window running past the records is
// corrupt, and parses as an error rather than as clamped colors.
pub fn parse_cpal(data []u8) !Cpal {
	r := new_reader(data)
	if !r.has(0, 12) {
		return error('CPAL: table shorter than the 12-byte header')
	}
	version := r.u16_at(0)
	if version > 1 {
		return error('CPAL: version ${version} is not supported')
	}
	num_entries := int(r.u16_at(2))
	num_palettes := int(r.u16_at(4))
	num_records := int(r.u16_at(6))
	first := int(r.u32_at(8))
	if num_entries < 0 || num_palettes < 0 || num_records < 0 || first < 0 {
		return error('CPAL: negative header field')
	}
	if !r.has(12, num_palettes * 2) {
		return error('CPAL: palette index array runs past the table')
	}
	if num_entries > 0 && num_palettes > 0 {
		if !r.has(first, num_records * 4) {
			return error('CPAL: color records run past the table')
		}
	}
	mut records := []CpalColor{cap: num_records}
	for i in 0 .. num_records {
		at := first + i * 4
		records << CpalColor{
			b: r.u8_at(at)
			g: r.u8_at(at + 1)
			r: r.u8_at(at + 2)
			a: r.u8_at(at + 3)
		}
	}
	mut palettes := [][]CpalColor{cap: num_palettes}
	for p in 0 .. num_palettes {
		start := int(r.u16_at(12 + p * 2))
		if start < 0 || start + num_entries > num_records {
			return error('CPAL: palette ${p} window [${start}, ${start + num_entries}) is outside ${num_records} records')
		}
		mut pal := []CpalColor{cap: num_entries}
		for e in 0 .. num_entries {
			pal << records[start + e]
		}
		palettes << pal
	}
	return Cpal{
		version:  version
		palettes: palettes
	}
}

// ColrLayer is one COLR v0 layer: the outline glyph to draw plus which color
// to draw it in. is_foreground means the palette index was 0xFFFF, so the
// caller draws with its own foreground rather than with any palette entry.
pub struct ColrLayer {
pub:
	layer_gid     u16
	palette_index u16
	is_foreground bool
}

// ColrBase is one base glyph's layer list, in bottom-to-top paint order.
pub struct ColrBase {
pub:
	base_gid u16
	layers   []ColrLayer
}

// Colr is a parsed COLR table: the version plus every v0 base record.
// has_v1 is set for version 1, which carries the same v0 arrays ahead of its
// paint graph; the graph itself is refused on lookup (see layers_for).
pub struct Colr {
pub:
	version u16
	bases   []ColrBase
	has_v1  bool
}

// layers_for answers base gid's layer list, or an empty list when the font
// names none for it. A v1-only glyph (in the paint graph but not in the v0
// arrays) is refused with its reason rather than drawn as monochrome:
// silence would paint the wrong glyph.
pub fn (c &Colr) layers_for(gid u16) ![]ColrLayer {
	for b in c.bases {
		if b.base_gid == gid {
			return b.layers.clone()
		}
	}
	if c.has_v1 {
		return error('COLR: glyph ${gid} has only a v1 paint graph, which is refused: no v1 paint renderer in tree')
	}
	return []ColrLayer{}
}

// is_color_glyph reports whether gid names a COLR base glyph.
pub fn (c &Colr) is_color_glyph(gid u16) bool {
	for b in c.bases {
		if b.base_gid == gid {
			return true
		}
	}
	return false
}

// parse_colr reads a COLR table's v0 layer records: version, base records,
// layer records. Version 0 parses whole; version 1 parses the same v0 arrays
// and sets has_v1, because v1 fonts keep them for compatibility. Anything
// above 1, an offset outside the table, or a layer window running past the
// layer list is corrupt.
pub fn parse_colr(data []u8) !Colr {
	r := new_reader(data)
	if !r.has(0, 14) {
		return error('COLR: table shorter than the 14-byte v0 header')
	}
	version := r.u16_at(0)
	if version > 1 {
		return error('COLR: version ${version} is not supported')
	}
	num_base := int(r.u16_at(2))
	base_off := int(r.u32_at(4))
	layer_off := int(r.u32_at(8))
	num_layers := int(r.u16_at(12))
	if num_base < 0 || base_off < 0 || layer_off < 0 || num_layers < 0 {
		return error('COLR: negative header field')
	}
	if !r.has(base_off, num_base * 6) {
		return error('COLR: base records run past the table')
	}
	if !r.has(layer_off, num_layers * 4) {
		return error('COLR: layer records run past the table')
	}
	mut all := []ColrLayer{cap: num_layers}
	for i in 0 .. num_layers {
		at := layer_off + i * 4
		all << ColrLayer{
			layer_gid:     r.u16_at(at)
			palette_index: r.u16_at(at + 2)
			is_foreground: r.u16_at(at + 2) == 0xFFFF
		}
	}
	mut bases := []ColrBase{cap: num_base}
	for i in 0 .. num_base {
		at := base_off + i * 6
		base := r.u16_at(at)
		first := int(r.u16_at(at + 2))
		n := int(r.u16_at(at + 4))
		if first < 0 || n < 0 || first + n > num_layers {
			return error('COLR: base glyph ${base} window [${first}, ${first + n}) is outside ${num_layers} layers')
		}
		bases << ColrBase{
			base_gid: base
			layers:   all[first..first + n].clone()
		}
	}
	return Colr{
		version: version
		bases:   bases
		has_v1:  version == 1
	}
}

// EmbeddedBitmap is one embedded strike glyph expanded to 8-bit coverage:
// row-major width*height bytes, 0 empty and 255 solid, in the same
// left/top convention GlyphBitmap uses, plus the strike it came from.
pub struct EmbeddedBitmap {
pub mut:
	coverage  []u8
	width     int
	height    int
	bearing_x int
	bearing_y int
	advance   int
	ppem      int
}

// is_empty reports whether the glyph has no ink.
pub fn (b &EmbeddedBitmap) is_empty() bool {
	return b.width <= 0 || b.height <= 0
}

// to_box answers the strike bitmap as a GlyphBitmap box with no coverage,
// the embedded form of what box_only reports: left is how far the ink
// reaches left of the pen, top how far it reaches above the baseline.
pub fn (b &EmbeddedBitmap) to_box() raster.GlyphBitmap {
	return raster.GlyphBitmap{
		width:  b.width
		height: b.height
		left:   -b.bearing_x
		top:    b.bearing_y
	}
}

// to_bitmap answers the strike bitmap as a full GlyphBitmap with coverage.
pub fn (b &EmbeddedBitmap) to_bitmap() raster.GlyphBitmap {
	if b.is_empty() {
		return raster.GlyphBitmap{}
	}
	if b.coverage.len < b.width * b.height {
		return raster.GlyphBitmap{}
	}
	return raster.GlyphBitmap{
		coverage: b.coverage.clone()
		width:    b.width
		height:   b.height
		left:     -b.bearing_x
		top:      b.bearing_y
	}
}

// eblc_subtable is one EBLC/CBLC index subtable over a glyph range: which
// index format locates the slices, which image format each slice carries, and
// where the data lives. Only format-1 offset arrays are kept; any other
// index format is refused at lookup, with its number in the message.
struct EblcSubtable {
	first             u16
	last              u16
	index_format      u16
	image_format      u16
	image_data_offset u32
mut:
	offsets    []u32
	image_size u32
}

// eblc_strike is one EBLC/CBLC strike: the ppem it was drawn for, its bit
// depth, and its subtables.
struct EblcStrike {
	ppem_x    int
	ppem_y    int
	bit_depth int
	subtables []EblcSubtable
}

// Eblc is a parsed EBLC/CBLC locator: the strikes plus where each strike's
// glyphs live. CBDT and EBDT share the shape; CBLC and EBLC share the bytes.
pub struct Eblc {
	strikes []EblcStrike
}

// num_strikes answers how many strikes the locator carries.
pub fn (e &Eblc) num_strikes() int {
	return e.strikes.len
}

// strike_for answers the strike drawn for ppem. Matching is exact: a 16-ppem
// strike never stands in for a 17-ppem request, because embedded pixels do
// not scale without the caller asking (see render_embedded).
pub fn (e &Eblc) strike_for(ppem u16) !EblcStrike {
	for s in e.strikes {
		if s.ppem_x == int(ppem) && s.ppem_y == int(ppem) {
			return s
		}
	}
	return error('EBLC: no strike for ppem ${ppem}')
}

// parse_eblc reads an EBLC/CBLC locator: version 2.0, numSizes strikes of 48
// bytes, then each strike's index-subtable array. Index format 1 (32-bit
// offset arrays) is read whole; formats 2-5 record their image size and are
// refused at glyph lookup, because their data packing is a different reader.
// A version that is not 2.x, an offset outside the table, or a subtable
// running past the end is corrupt.
pub fn parse_eblc(data []u8) !Eblc {
	r := new_reader(data)
	if !r.has(0, 8) {
		return error('EBLC: table shorter than the 8-byte header')
	}
	if r.u16_at(0) != 2 {
		return error('EBLC: major version ${r.u16_at(0)} is not supported, want 2.x')
	}
	num_sizes := int(r.u32_at(4))
	if num_sizes < 0 {
		return error('EBLC: negative strike count')
	}
	if !r.has(8, num_sizes * 48) {
		return error('EBLC: strike array runs past the table')
	}
	mut strikes := []EblcStrike{cap: num_sizes}
	for s in 0 .. num_sizes {
		base := 8 + s * 48
		if !r.has(base, 48) {
			return error('EBLC: strike ${s} runs past the table')
		}
		arr_off := int(r.u32_at(base))
		num_sub := int(r.u32_at(base + 8))
		if num_sub < 0 {
			return error('EBLC: strike ${s} has a negative subtable count')
		}
		if !r.has(arr_off, num_sub * 8) {
			return error('EBLC: strike ${s} subtable array runs past the table')
		}
		start_gid := r.u16_at(base + 40)
		end_gid := r.u16_at(base + 42)
		mut subs := []EblcSubtable{cap: num_sub}
		for k in 0 .. num_sub {
			entry := arr_off + k * 8
			first := r.u16_at(entry)
			last := r.u16_at(entry + 2)
			add := int(r.u32_at(entry + 4))
			if first > last {
				return error('EBLC: subtable ${k} range [${first}, ${last}] is empty')
			}
			if int(first) < int(start_gid) || int(last) > int(end_gid) {
				return error('EBLC: subtable ${k} range [${first}, ${last}] is outside the strike range [${start_gid}, ${end_gid}]')
			}
			head := arr_off + add
			if !r.has(head, 8) {
				return error('EBLC: subtable ${k} header runs past the table')
			}
			idx_fmt := r.u16_at(head)
			img_fmt := r.u16_at(head + 2)
			img_off := r.u32_at(head + 4)
			mut sub := EblcSubtable{
				first:             first
				last:              last
				index_format:      idx_fmt
				image_format:      img_fmt
				image_data_offset: img_off
			}
			if idx_fmt == 1 {
				n := int(last) - int(first) + 1
				if !r.has(head + 8, (n + 1) * 4) {
					return error('EBLC: subtable ${k} offset array runs past the table')
				}
				for i in 0 .. n + 1 {
					sub.offsets << r.u32_at(head + 8 + i * 4)
				}
			}
			subs << sub
		}
		strikes << EblcStrike{
			ppem_x:    int(r.u8_at(base + 44))
			ppem_y:    int(r.u8_at(base + 45))
			bit_depth: int(r.u8_at(base + 46))
			subtables: subs
		}
	}
	return Eblc{
		strikes: strikes
	}
}

// i8_of reads a signed byte: the metrics store bearings as int8, and the
// reader only answers unsigned, so 128..255 wrap below zero.
fn i8_of(v u8) int {
	return if v >= 128 { int(v) - 256 } else { int(v) }
}

// expand_row_major expands one packed 1/2/4/8-bit byte-aligned row to 8-bit
// coverage, most-significant-bit first, the way the EBDT byte-aligned formats
// pack pixels. Bit depth outside 1/2/4/8 is refused by the caller.
fn expand_row_major(packed []u8, width int, bit_depth int) ![]u8 {
	maxv := (1 << u32(bit_depth)) - 1
	mut out := []u8{len: width}
	for x in 0 .. width {
		bit := x * bit_depth
		v := (u32(packed[bit / 8]) >> u32(8 - bit % 8 - bit_depth)) & u32(maxv)
		out[x] = u8(v * 255 / u32(maxv))
	}
	return out
}

// expand_bit_aligned expands one packed 1-bit bit-aligned row, where rows are
// concatenated bit after bit with no per-row padding. Only depth 1 packs
// this way; anything else is refused by the caller.
fn expand_bit_aligned(packed []u8, bit_base int, width int) []u8 {
	mut out := []u8{len: width}
	for x in 0 .. width {
		bit := bit_base + x
		v := (u32(packed[bit / 8]) >> u32(7 - bit % 8)) & 1
		out[x] = if v == 1 { u8(255) } else { u8(0) }
	}
	return out
}

// embedded_bitmap reads one embedded glyph out of a CBDT/EBDT data table
// through a CBLC/EBLC locator: the strike drawn for ppem, the subtable
// covering gid, the slice its offsets name. Image formats 1 (small metrics,
// byte-aligned) and 6 (big metrics, byte-aligned) expand whole; formats 2
// and 7 (bit-aligned) expand at depth 1. Formats 5, 8 and 9 keep their
// metrics in the locator and are refused with their number, and PNG formats
// 17, 18 and 19 are refused with the no-decoder reason. An empty slice
// (equal offsets, or zero metrics) answers an empty bitmap the way the
// outline path answers a space: no ink, not an error.
pub fn embedded_bitmap(locator_data []u8, ebdt_data []u8, gid u16, ppem u16) !EmbeddedBitmap {
	loc := parse_eblc(locator_data) or { return err }
	strike := loc.strike_for(ppem) or { return err }
	mut sub := EblcSubtable{}
	mut found := false
	for s in strike.subtables {
		if gid >= s.first && gid <= s.last {
			sub = s
			found = true
			break
		}
	}
	if !found {
		return error('EBDT: glyph ${gid} is in no subtable at ppem ${ppem}')
	}
	if sub.index_format != 1 {
		return error('EBDT: index format ${sub.index_format} is not supported, want format 1 offset arrays')
	}
	k := int(gid) - int(sub.first)
	if k < 0 || k + 1 >= sub.offsets.len {
		return error('EBDT: glyph ${gid} offset is outside the subtable array')
	}
	base := int(sub.image_data_offset)
	start := base + int(sub.offsets[k])
	end := base + int(sub.offsets[k + 1])
	if start < 0 || end < start || end > ebdt_data.len {
		return error('EBDT: glyph ${gid} slice [${start}, ${end}) is outside ${ebdt_data.len} bytes')
	}
	if end == start {
		return EmbeddedBitmap{
			ppem: int(ppem)
		}
	}
	slice := ebdt_data[start..end]
	img := sub.image_format
	if img == 17 || img == 18 || img == 19 {
		return error('EBDT: image format ${img} is PNG-wrapped and refused: no PNG decoder in tree, box only')
	}
	if img != 1 && img != 2 && img != 6 && img != 7 {
		return error('EBDT: image format ${img} is not supported, want 1, 2, 6 or 7')
	}
	byte_aligned := img == 1 || img == 6
	mut w := 0
	mut h := 0
	mut bx := 0
	mut by := 0
	mut adv := 0
	mut rows := []u8{}
	if img == 1 || img == 2 {
		if slice.len < 5 {
			return error('EBDT: glyph ${gid} small metrics run past its slice')
		}
		w = int(slice[0])
		h = int(slice[1])
		bx = i8_of(slice[2])
		by = i8_of(slice[3])
		adv = int(slice[4])
		rows = slice[5..]
	} else {
		if slice.len < 8 {
			return error('EBDT: glyph ${gid} big metrics run past its slice')
		}
		h = int(slice[0])
		w = int(slice[1])
		bx = i8_of(slice[2])
		by = i8_of(slice[3])
		adv = int(slice[4])
		rows = slice[8..]
	}
	if w <= 0 || h <= 0 {
		return EmbeddedBitmap{
			ppem: int(ppem)
		}
	}
	if w > 512 || h > 512 {
		return error('EBDT: glyph ${gid} bitmap ${w}x${h} exceeds the 512px sanity bound')
	}
	bd := strike.bit_depth
	if byte_aligned {
		if bd != 1 && bd != 2 && bd != 4 && bd != 8 {
			return error('EBDT: bit depth ${bd} is not supported, want 1, 2, 4 or 8')
		}
		stride := (w * bd + 7) / 8
		if rows.len < stride * h {
			return error('EBDT: glyph ${gid} rows run past its slice')
		}
		mut cov := []u8{cap: w * h}
		for y in 0 .. h {
			row := expand_row_major(rows[y * stride..(y + 1) * stride], w, bd) or {
				return err
			}
			cov << row
		}
		return EmbeddedBitmap{
			coverage:  cov
			width:     w
			height:    h
			bearing_x: bx
			bearing_y: by
			advance:   adv
			ppem:      int(ppem)
		}
	}
	if bd != 1 {
		return error('EBDT: bit-aligned depth ${bd} is not supported, want 1')
	}
	need := (w * h + 7) / 8
	if rows.len < need {
		return error('EBDT: glyph ${gid} bits run past its slice')
	}
	mut cov := []u8{cap: w * h}
	for y in 0 .. h {
		cov << expand_bit_aligned(rows, y * w, w)
	}
	return EmbeddedBitmap{
		coverage:  cov
		width:     w
		height:    h
		bearing_x: bx
		bearing_y: by
		advance:   adv
		ppem:      int(ppem)
	}
}

// SbixGlyph is one sbix glyph blob: the origin the screen point sits at,
// the graphic type ('png ', 'dupe', ...), and the payload after the 8-byte
// header. A 'dupe' payload is a glyph id whose own blob should be used
// instead, which is_dupe reports and dupe_gid names.
pub struct SbixGlyph {
pub:
	origin_x     int
	origin_y     int
	graphic_type string
	data         []u8
	dupe_gid     u16
	is_dupe      bool
}

// SbixStrike is one sbix strike: the ppem it was drawn for and the glyph
// blobs indexed by glyph id. Missing glyphs (equal offsets) are absent from
// the map rather than empty blobs: a strike that never drew a glyph has
// nothing to say about it.
pub struct SbixStrike {
pub:
	ppem       u16
	resolution u16
	blobs      map[u16]SbixGlyph
}

// Sbix is a parsed sbix table: the strikes keyed by ppem in table order.
pub struct Sbix {
	strikes []SbixStrike
}

// num_strikes answers how many strikes the table carries.
pub fn (s &Sbix) num_strikes() int {
	return s.strikes.len
}

// strike_for answers the strike drawn for ppem.
pub fn (s &Sbix) strike_for(ppem u16) !SbixStrike {
	for st in s.strikes {
		if st.ppem == ppem {
			return st
		}
	}
	return error('sbix: no strike for ppem ${ppem}')
}

// parse_sbix reads an sbix table: version 1, numStrikes strike offsets, then
// each strike's ppem, resolution and num_glyphs+1 glyph offsets. Offsets are
// measured from the start of their strike; a blob shorter than the 8-byte
// glyph header, or an offset outside its strike, is corrupt. num_glyphs is
// the face's glyph count, which the table itself does not carry.
pub fn parse_sbix(data []u8, num_glyphs int) !Sbix {
	r := new_reader(data)
	if !r.has(0, 8) {
		return error('sbix: table shorter than the 8-byte header')
	}
	if r.u16_at(0) != 1 {
		return error('sbix: version ${r.u16_at(0)} is not supported, want 1')
	}
	num_strikes := int(r.u32_at(4))
	if num_strikes < 0 {
		return error('sbix: negative strike count')
	}
	if !r.has(8, (num_strikes + 1) * 4) {
		return error('sbix: strike offsets run past the table')
	}
	if num_glyphs < 0 {
		return error('sbix: negative glyph count')
	}
	mut strikes := []SbixStrike{cap: num_strikes}
	for s in 0 .. num_strikes {
		s_off := int(r.u32_at(8 + s * 4))
		s_end := int(r.u32_at(8 + (s + 1) * 4))
		if s_off < 0 || s_end < s_off || s_end > data.len {
			return error('sbix: strike ${s} range [${s_off}, ${s_end}) is outside ${data.len} bytes')
		}
		sr := new_reader(data[s_off..s_end])
		if !sr.has(0, 4 + (num_glyphs + 1) * 4) {
			return error('sbix: strike ${s} offset array runs past its range')
		}
		mut blobs := map[u16]SbixGlyph{}
		for g in 0 .. num_glyphs {
			g_start := int(sr.u32_at(4 + g * 4))
			g_end := int(sr.u32_at(4 + (g + 1) * 4))
			if g_start < 0 || g_end < g_start || g_end > s_end - s_off {
				return error('sbix: strike ${s} glyph ${g} range is outside its strike')
			}
			if g_end == g_start {
				continue
			}
			blob := sr.data[g_start..g_end]
			if blob.len < 8 {
				return error('sbix: strike ${s} glyph ${g} blob is shorter than its 8-byte header')
			}
			gtype := tag_from_bytes(blob, 4)
			if gtype == 'dupe' {
				if blob.len < 10 {
					return error('sbix: strike ${s} glyph ${g} dupe has no target')
				}
				blobs[u16(g)] = SbixGlyph{
					origin_x:     int(new_reader(blob).i16_at(0))
					origin_y:     int(new_reader(blob).i16_at(2))
					graphic_type: gtype
					dupe_gid:     new_reader(blob).u16_at(8)
					is_dupe:      true
				}
			} else {
				blobs[u16(g)] = SbixGlyph{
					origin_x:     int(new_reader(blob).i16_at(0))
					origin_y:     int(new_reader(blob).i16_at(2))
					graphic_type: gtype
					data:         blob[8..].clone()
				}
			}
		}
		strikes << SbixStrike{
			ppem:       sr.u16_at(0)
			resolution: sr.u16_at(2)
			blobs:      blobs
		}
	}
	return Sbix{
		strikes: strikes
	}
}

// sbix_glyph answers strike ppem's blob for gid, following 'dupe' chains to
// the blob they name. A loop, a dupe past the face, or a missing glyph is an
// error rather than an empty blob: the strike has nothing to say about that
// glyph, and an empty box would claim it drew blank.
pub fn (s &Sbix) sbix_glyph(ppem u16, gid u16) !SbixGlyph {
	strike := s.strike_for(ppem) or { return err }
	mut cur := gid
	for _ in 0 .. 32 {
		blob := strike.blobs[cur] or {
			return error('sbix: glyph ${cur} has no blob at ppem ${ppem}')
		}
		if !blob.is_dupe {
			return blob
		}
		if blob.dupe_gid == cur {
			return error('sbix: glyph ${cur} dupes to itself at ppem ${ppem}')
		}
		cur = blob.dupe_gid
	}
	return error('sbix: dupe chain past 32 links at ppem ${ppem}')
}

// png_box reads a PNG's IHDR width and height: the 8-byte signature, then a
// 13-byte IHDR chunk with the dimensions at bytes 16..24. Anything else is
// corrupt or not a PNG, and parses as an error rather than as a zero box.
pub fn png_box(png []u8) !(int, int) {
	if png.len < 24 {
		return error('sbix: PNG shorter than signature plus IHDR')
	}
	if png[0] != 0x89 || png[1] != 0x50 || png[2] != 0x4E || png[3] != 0x47
		|| png[4] != 0x0D || png[5] != 0x0A || png[6] != 0x1A || png[7] != 0x0A {
		return error('sbix: missing PNG signature')
	}
	if png[12] != 0x49 || png[13] != 0x48 || png[14] != 0x44 || png[15] != 0x52 {
		return error('sbix: first chunk is not IHDR')
	}
	r := new_reader(png)
	w := int(r.u32_at(16))
	h := int(r.u32_at(20))
	if w <= 0 || h <= 0 || w > 4096 || h > 4096 {
		return error('sbix: PNG box ${w}x${h} is not sane')
	}
	return w, h
}

// has_colr reports whether the face carries a COLR table.
pub fn (f &Face) has_colr() bool {
	return f.sfnt.has(tag_colr)
}

// has_cpal reports whether the face carries a CPAL table.
pub fn (f &Face) has_cpal() bool {
	return f.sfnt.has(tag_cpal)
}

// has_cblc reports whether the face carries a CBLC locator.
pub fn (f &Face) has_cblc() bool {
	return f.sfnt.has('CBLC')
}

// has_cbdt reports whether the face carries CBDT bitmap data.
pub fn (f &Face) has_cbdt() bool {
	return f.sfnt.has(tag_cbdt)
}

// has_eblc reports whether the face carries an EBLC locator.
pub fn (f &Face) has_eblc() bool {
	return f.sfnt.has('EBLC')
}

// has_ebdt reports whether the face carries EBDT bitmap data.
pub fn (f &Face) has_ebdt() bool {
	return f.sfnt.has('EBDT')
}

// has_sbix reports whether the face carries an sbix table.
pub fn (f &Face) has_sbix() bool {
	return f.sfnt.has(tag_sbix)
}

// has_svg reports whether the face carries an SVG table. Presence is the
// refusal condition (see check_svg): the engine draws nothing from it.
pub fn (f &Face) has_svg() bool {
	return f.sfnt.has(tag_svg)
}

// has_color reports whether the face carries any color table this reader
// reads: COLR with CPAL, a bitmap locator with its data, or sbix. SVG alone
// does not count: it is refused, not read.
pub fn (f &Face) has_color() bool {
	if f.sfnt.has(tag_colr) && f.sfnt.has(tag_cpal) {
		return true
	}
	if (f.sfnt.has('CBLC') && f.sfnt.has(tag_cbdt))
		|| (f.sfnt.has('EBLC') && f.sfnt.has('EBDT')) {
		return true
	}
	if f.sfnt.has(tag_sbix) {
		return true
	}
	return false
}

// colr_layers answers gid's COLR layer list, or an empty list when the face
// has no COLR table or names none for gid. A corrupt table is an error
// rather than an empty list, so a damaged font never reads as monochrome.
pub fn (f &Face) colr_layers(gid u16) ![]ColrLayer {
	if !f.sfnt.has(tag_colr) {
		return []ColrLayer{}
	}
	colr := parse_colr(f.sfnt.table_data(tag_colr)) or { return err }
	return colr.layers_for(gid) or { return err }
}

// layer_color resolves one layer's color: the palette entry for ordinary
// layers, the caller's foreground for 0xFFFF layers, opaque white when the
// font names a palette entry no palette holds. White is the documented
// fallback rather than an error because a color glyph that fails to draw
// draws less than one drawn in the wrong color, and the wrong color is
// visible where a hole is not.
pub fn (f &Face) layer_color(layer ColrLayer, palette u16, fg raster.Rgba) raster.Rgba {
	if layer.is_foreground {
		return fg
	}
	if f.sfnt.has(tag_cpal) {
		cpal := parse_cpal(f.sfnt.table_data(tag_cpal)) or {
			return raster.Rgba{255, 255, 255, 255}
		}
		color := cpal.color(palette, layer.palette_index) or {
			return raster.Rgba{255, 255, 255, 255}
		}
		return raster.Rgba{color.r, color.g, color.b, color.a}
	}
	return raster.Rgba{255, 255, 255, 255}
}

// color_box answers gid's color ink box at em_px: the union of its COLR
// layers' box_only boxes, with no coverage, the color form of what box_only
// reports. A glyph with no layers answers box_only, so callers measuring a
// mixed line need only one call.
pub fn (f &Face) color_box(gid u16, em_px f64) raster.GlyphBitmap {
	layers := f.colr_layers(gid) or { return f.box_only(gid, em_px) }
	if layers.len == 0 {
		return f.box_only(gid, em_px)
	}
	mut parts := []raster.GlyphBitmap{cap: layers.len}
	for layer in layers {
		parts << f.box_only(layer.layer_gid, em_px)
	}
	return raster.color_union_box(parts)
}

// render_color draws gid's COLR layers at em_px into one RGBA bitmap: each
// layer through render_into at the caller's subpixel shift, tinted with its
// palette color, composited bottom to top. palette selects the CPAL palette;
// fg is the caller-owned foreground for 0xFFFF layers. A glyph with no
// layers answers its outline tinted with fg, so a mixed line renders through
// one call and the corpus pin (alpha equals outline coverage at opaque fg)
// holds exactly.
pub fn (f &Face) render_color(gid u16, em_px f64, sub_x i32, sub_y i32, palette u16, fg raster.Rgba) raster.ColorBitmap {
	layers := f.colr_layers(gid) or { []ColrLayer{} }
	if layers.len == 0 {
		base := f.rasterize_glyph(gid, em_px, sub_x, sub_y)
		return raster.tint_bitmap(base, fg)
	}
	mut parts := []raster.ColorBitmap{cap: layers.len}
	for layer in layers {
		box := f.box_only(layer.layer_gid, em_px)
		if box.is_empty() {
			continue
		}
		if box.width <= 0 || box.height <= 0 || box.width > 4096 || box.height > 4096 {
			continue
		}
		mut buf := []u8{len: box.width * box.height}
		f.render_into(layer.layer_gid, em_px, sub_x, sub_y, buf[0], box.width, box.height)
		parts << raster.tint_bitmap(raster.GlyphBitmap{
			coverage: buf
			width:    box.width
			height:   box.height
			left:     box.left
			top:      box.top
		}, f.layer_color(layer, palette, fg))
	}
	return raster.composite_layers(parts)
}

// embedded_bitmap answers gid's strike bitmap at ppem through the CBLC/CBDT
// or EBLC/EBDT pair, whichever the face carries. CBLC wins when both are
// present: color strikes ride CBLC, and a font carrying both wrote its color
// there.
pub fn (f &Face) embedded_bitmap(gid u16, ppem u16) !EmbeddedBitmap {
	if f.sfnt.has('CBLC') && f.sfnt.has(tag_cbdt) {
		return embedded_bitmap(f.sfnt.table_data('CBLC'), f.sfnt.table_data(tag_cbdt), gid, ppem)
	}
	if f.sfnt.has('EBLC') && f.sfnt.has('EBDT') {
		return embedded_bitmap(f.sfnt.table_data('EBLC'), f.sfnt.table_data('EBDT'), gid, ppem)
	}
	return error('EBDT: face has no CBLC/CBDT or EBLC/EBDT pair')
}

// embedded_box answers gid's strike box scaled to em_px, with no coverage:
// the embedded form of what box_only reports. The scale is em over ppem,
// because strike pixels are device pixels at their own ppem.
pub fn (f &Face) embedded_box(gid u16, ppem u16, em_px f64) raster.GlyphBitmap {
	eb := f.embedded_bitmap(gid, ppem) or { return raster.GlyphBitmap{} }
	if eb.is_empty() || em_px <= 0 {
		return raster.GlyphBitmap{}
	}
	scaled := raster.scale_bitmap_nearest(eb.to_bitmap(), em_px / f64(ppem))
	return raster.GlyphBitmap{
		width:  scaled.width
		height: scaled.height
		left:   scaled.left
		top:    scaled.top
	}
}

// render_embedded draws gid's strike bitmap scaled to em_px: nearest
// neighbour, because strike pixels are authored pixels and filtering them
// would invent ink the strike never drew. No strike, no ink.
pub fn (f &Face) render_embedded(gid u16, ppem u16, em_px f64) raster.GlyphBitmap {
	eb := f.embedded_bitmap(gid, ppem) or { return raster.GlyphBitmap{} }
	if eb.is_empty() || em_px <= 0 {
		return raster.GlyphBitmap{}
	}
	return raster.scale_bitmap_nearest(eb.to_bitmap(), em_px / f64(ppem))
}

// sbix_glyph answers gid's sbix blob at ppem, dupe chains followed.
pub fn (f &Face) sbix_glyph(gid u16, ppem u16) !SbixGlyph {
	if !f.sfnt.has(tag_sbix) {
		return error('sbix: face has no sbix table')
	}
	sbix := parse_sbix(f.sfnt.table_data(tag_sbix), f.num_glyphs) or { return err }
	return sbix.sbix_glyph(ppem, gid) or { return err }
}

// sbix_box answers gid's sbix box scaled to em_px, with no coverage. PNG
// blobs read their box from the IHDR; 'dupe' blobs follow the chain first.
// The scale is em over the strike ppem, the same device-pixel reasoning as
// the embedded strikes.
pub fn (f &Face) sbix_box(gid u16, ppem u16, em_px f64) raster.GlyphBitmap {
	if em_px <= 0 {
		return raster.GlyphBitmap{}
	}
	blob := f.sbix_glyph(gid, ppem) or { return raster.GlyphBitmap{} }
	if blob.graphic_type != 'png ' {
		return raster.GlyphBitmap{}
	}
	w, h := png_box(blob.data) or { return raster.GlyphBitmap{} }
	scale := em_px / f64(ppem)
	return raster.GlyphBitmap{
		width:  raster.qround(f64(w) * scale)
		height: raster.qround(f64(h) * scale)
		left:   raster.qround(f64(blob.origin_x) * scale)
		top:    raster.qround(f64(h - blob.origin_y) * scale)
	}
}

// sbix_pixels is the refusal half of the sbix contract: PNG/JPG/TIFF blobs
// carry their bytes for the caller, but decoding them needs an image decoder
// and there is none in this tree. The box (see sbix_box) and the raw bytes
// (see sbix_glyph) are answered; pixels are an error with the reason.
pub fn (f &Face) sbix_pixels(gid u16, ppem u16) ![]u8 {
	blob := f.sbix_glyph(gid, ppem) or { return err }
	return error('sbix: ${blob.graphic_type} pixels are refused: no image decoder in tree, read the box and bytes instead')
}

// check_svg answers whether the face's SVG table refuses rendering: false
// when the face has none (nothing to refuse), an error naming SVG when it
// carries documents. An SVG table naming no documents answers false the way
// an empty cmap answers no coverage: present but saying nothing.
pub fn (f &Face) check_svg() !bool {
	if !f.sfnt.has(tag_svg) {
		return false
	}
	data := f.sfnt.table_data(tag_svg)
	if data.len == 0 {
		return false
	}
	r := new_reader(data)
	if !r.has(0, 8) {
		return error('SVG table is present but shorter than its 8-byte header')
	}
	if r.u16_at(0) != 1 {
		return error('SVG table version ${r.u16_at(0)} is not supported, want 1')
	}
	doc_off := int(r.u32_at(2))
	if !r.has(doc_off, 2) {
		return error('SVG document index runs past the table')
	}
	n := int(r.u16_at(doc_off))
	for i in 0 .. n {
		at := doc_off + 2 + i * 12
		if !r.has(at, 12) {
			return error('SVG document record ${i} runs past the table')
		}
		length := int(r.u32_at(at + 8))
		if length > 0 {
			return error('SVG color glyphs are refused: vector documents need an SVG renderer, drawing the monochrome outline instead')
		}
	}
	return false
}
