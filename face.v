module vtext

// Face is a loaded font: its sfnt directory, parsed metrics tables and a
// rasteriser handle. Everything the shaper needs to place a glyph comes from
// here; outlines stay inside stb_truetype.
//
// Fields are mutable because they are filled in once during construction; the
// accessors below are the intended read path.
struct Face {
mut:
	sfnt         &Sfnt
	cmaps        []Cmap
	glyphs       []GlyphMetrics
	units_per_em int
	num_glyphs   int
	// stb_buf is raw storage for stb_truetype's opaque font handle. It must
	// stay alive for as long as stb_ok is true, so it lives inside Face rather
	// than on the stack.
	stb_buf [stbtt_fontinfo_bytes]u8
	// Vertical metrics, in design units.
	ascender  f64
	descender f64
	line_gap  f64
	// Typographic metrics from OS/2, preferred over hhea when present.
	typo_ascender  f64
	typo_descender f64
	typo_line_gap  f64
	has_typo       bool
	// Windows metrics: a fallback, and the box that clips the ink.
	win_ascent  f64
	win_descent f64
	// Global bounding box of the font, in design units.
	x_min f64
	y_min f64
	x_max f64
	y_max f64
	// post table: underline placement, italic angle, monospaced flag.
	underline_position  f64
	underline_thickness f64
	italic_angle        f64
	is_fixed_pitch      bool
	// OS/2 typographic extras.
	cap_height f64
	x_height   f64
	weight     int
	width      int
	// name table, filled in lazily.
	family_name    string
	style_name     string
	advances       []u16
	lsbs           []i16
	stb_ok         bool
	units_per_em_f f64
}

// GlyphMetrics is the per-glyph part of 'hmtx'.
struct GlyphMetrics {
	advance u16
	lsb     i16
}

// VMetrics is a face's vertical metrics, in design units.
struct VMetrics {
	ascent   f64
	descent  f64
	line_gap f64
}

// new_face parses data as a font face.
fn new_face(data []u8) !&Face {
	mut sfnt := parse_sfnt(data) or { return err }
	mut face := &Face{
		sfnt: &sfnt
	}
	face.read_head()
	face.read_hhea_maxp()
	face.read_hmtx()
	face.read_os2()
	face.read_post()
	face.cmaps = parse_cmap(sfnt.table_data(tag_cmap))
	face.units_per_em_f = if face.units_per_em > 0 {
		f64(face.units_per_em)
	} else {
		1000.0
	}
	face.init_stb(data)
	return face
}

fn (mut f Face) read_head() {
	rec := f.sfnt.record(tag_head) or { return }
	if !f.sfnt.has_magic_at(rec.offset + 12, 0x5F0F3CF5) {
		return // bad magic; keep defaults
	}
	r := new_reader(f.sfnt.data)
	f.units_per_em = int(r.u16_at(rec.offset + 18))
	f.x_min = f64(r.i16_at(rec.offset + 36))
	f.y_min = f64(r.i16_at(rec.offset + 38))
	f.x_max = f64(r.i16_at(rec.offset + 40))
	f.y_max = f64(r.i16_at(rec.offset + 42))
}

fn (mut f Face) read_hhea_maxp() {
	if rec := f.sfnt.record(tag_hhea) {
		r := new_reader(f.sfnt.data)
		f.ascender = f64(r.i16_at(rec.offset + 4))
		f.descender = f64(r.i16_at(rec.offset + 6))
		f.line_gap = f64(r.i16_at(rec.offset + 8))
	}
	if rec := f.sfnt.record(tag_maxp) {
		r := new_reader(f.sfnt.data)
		f.num_glyphs = int(r.u16_at(rec.offset + 4))
	}
	// Guarantee a usable line height even if hhea is missing.
	if f.ascender == 0 && f.descender == 0 {
		upem := if f.units_per_em > 0 { f64(f.units_per_em) } else { 1000.0 }
		f.ascender = upem * 0.8
		f.descender = upem * -0.2
	}
}

fn (mut f Face) read_hmtx() {
	hhea := f.sfnt.record(tag_hhea) or { return }
	hmtx := f.sfnt.record(tag_hmtx) or { return }
	r := new_reader(f.sfnt.data)
	mut num_h := int(r.u16_at(hhea.offset + 34))
	if num_h <= 0 {
		num_h = if f.num_glyphs > 0 { f.num_glyphs } else { 1 }
	}
	if f.num_glyphs <= 0 {
		f.num_glyphs = num_h
	}
	f.glyphs = []GlyphMetrics{len: f.num_glyphs}
	f.advances = []u16{len: f.num_glyphs}
	f.lsbs = []i16{len: f.num_glyphs}
	mut last_advance := u16(0)
	for i in 0 .. f.num_glyphs {
		if i < num_h {
			off := hmtx.offset + i * 4
			if !r.has(off, 4) {
				break
			}
			last_advance = r.u16_at(off)
			f.glyphs[i] = GlyphMetrics{
				advance: last_advance
				lsb:     r.i16_at(off + 2)
			}
		} else {
			// Monospaced tail: the advance repeats, lsb is a separate array.
			off := hmtx.offset + num_h * 4 + (i - num_h) * 2
			f.glyphs[i] = GlyphMetrics{
				advance: last_advance
				lsb:     if r.has(off, 2) { r.i16_at(off) } else { 0 }
			}
		}
		f.advances[i] = f.glyphs[i].advance
		f.lsbs[i] = f.glyphs[i].lsb
	}
}

fn (mut f Face) read_os2() {
	rec := f.sfnt.record(tag_os2) or { return }
	r := new_reader(f.sfnt.data)
	version := int(r.u16_at(rec.offset))
	f.weight = int(r.u16_at(rec.offset + 4))
	f.width = int(r.u16_at(rec.offset + 6))
	f.typo_ascender = f64(r.i16_at(rec.offset + 68))
	f.typo_descender = f64(r.i16_at(rec.offset + 70))
	f.typo_line_gap = f64(r.i16_at(rec.offset + 72))
	f.win_ascent = f64(r.u16_at(rec.offset + 74))
	f.win_descent = f64(r.u16_at(rec.offset + 76))
	// sTypoAscender/Descender of 0 mean "unset" in older OS/2 revisions.
	f.has_typo = f.typo_ascender != 0 || f.typo_descender != 0
	if version >= 2 {
		f.x_height = f64(r.i16_at(rec.offset + 86))
		f.cap_height = f64(r.i16_at(rec.offset + 88))
	}
}

fn (mut f Face) read_post() {
	rec := f.sfnt.record(tag_post) or { return }
	r := new_reader(f.sfnt.data)
	f.italic_angle = f64(r.i32_at(rec.offset + 4)) / 65536.0
	f.underline_position = f64(r.i16_at(rec.offset + 8))
	f.underline_thickness = f64(r.i16_at(rec.offset + 10))
	f.is_fixed_pitch = r.u32_at(rec.offset + 12) != 0
}

// stb_ptr returns the address of the rasteriser handle.
fn (f &Face) stb_ptr() voidptr {
	return voidptr(&f.stb_buf[0])
}

// init_stb creates the rasteriser handle over the same bytes.
fn (mut f Face) init_stb(data []u8) {
	offset := stbtt_get_font_offset_for_index(data, 0)
	if offset < 0 {
		return
	}
	if stbtt_init_font(f.stb_ptr(), data, offset) == 0 {
		return
	}
	f.stb_ok = true
}

// glyph_index maps a codepoint to a glyph index via 'cmap'.
fn (f &Face) glyph_index(cp rune) u16 {
	return glyph_index_for(f.cmaps, u32(cp))
}

// has_glyph reports whether the font maps cp to something other than .notdef.
fn (f &Face) has_glyph(cp rune) bool {
	return f.glyph_index(cp) != 0
}

// glyph_advance_units returns the horizontal advance in design units.
fn (f &Face) glyph_advance_units(gid u16) u16 {
	if int(gid) < f.advances.len {
		return f.advances[gid]
	}
	return 0
}

// glyph_lsb returns the left side bearing in design units.
fn (f &Face) glyph_lsb(gid u16) i16 {
	if int(gid) < f.lsbs.len {
		return f.lsbs[gid]
	}
	return 0
}

// scale converts design units to pixels at the given em size.
fn (f &Face) scale(units f64, em_px f64) f64 {
	return units / f.units_per_em_f * em_px
}

// glyph_advance returns the horizontal advance in pixels.
fn (f &Face) glyph_advance(gid u16, em_px f64) f64 {
	return f.scale(f64(f.glyph_advance_units(gid)), em_px)
}

// vmetrics returns vertical metrics in design units. Typographic metrics win
// when the font provides them; hhea is the fallback.
fn (f &Face) vmetrics() VMetrics {
	if f.has_typo {
		return VMetrics{
			ascent:   f.typo_ascender
			descent:  f.typo_descender
			line_gap: f.typo_line_gap
		}
	}
	return VMetrics{
		ascent:   f.ascender
		descent:  f.descender
		line_gap: f.line_gap
	}
}

// line_height returns the distance between successive baselines in pixels.
fn (f &Face) line_height(em_px f64) f64 {
	m := f.vmetrics()
	return f.scale(m.ascent - m.descent + m.line_gap, em_px)
}

// ascent returns the ascent above the baseline, in pixels.
fn (f &Face) ascent(em_px f64) f64 {
	return f.scale(f.vmetrics().ascent, em_px)
}

// descent returns the positive distance below the baseline, in pixels.
fn (f &Face) descent(em_px f64) f64 {
	return f.scale(-f.vmetrics().descent, em_px)
}
