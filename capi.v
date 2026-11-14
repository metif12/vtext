module vtext

import vtext.layout
import vtext.shape
import vtext.font

// The C ABI of this text shaping library: opaque handles over the shaped
// objects, plain C types everywhere, and no V value that a C caller would
// have to lay out.
//
// Every function here is exported by its C name rather than by the
// `module__name` scheme, so the wrapper the compiler emits is what a C caller
// links against. That wrapper also runs the runtime initializer on entry,
// which a caller reaching the bare function would skip.
//
// On Windows the link needs every symbol exported, and the compiler only
// marks the wrappers with an ELF visibility attribute, which a PE linker
// ignores. So the flag below tells tcc to export them all. MSVC marks them
// itself and an ELF shared object exports them by default, so the flag is
// Windows-only. `vtext.def` beside this file lists the same names for callers
// whose linker wants an import library instead.
#flag windows -Wl,-export-all-symbols

// set_error copies msg into the caller's buffer, truncating to errcap - 1
// with a terminator. A null buffer or no room means the sentence is dropped
// rather than written past the end, because the caller sized the buffer.
fn set_error(errbuf &u8, errcap int, msg string) {
	if errbuf == unsafe { nil } || errcap <= 1 {
		return
	}
	unsafe {
		n := if msg.len < errcap - 1 { msg.len } else { errcap - 1 }
		C.memcpy(errbuf, msg.str, usize(n))
		errbuf[n] = 0
	}
}

fn C.memcpy(dst voidptr, src voidptr, n usize) voidptr

// c_text copies a caller-owned byte range into runes. The copy is the point:
// `tos` borrows and the caller owns the bytes, so returning the borrow would
// hand the engine a view of memory it may free while the call is still running.
fn c_text(text &u8, len int) []rune {
	if text == unsafe { nil } || len <= 0 {
		return []rune{}
	}
	unsafe {
		s := tos(text, len).clone()
		return s.runes()
	}
}

// c_bytes copies a caller-owned byte range the same way, for font files held
// in memory rather than on disk. A loop rather than a second memcpy declaration,
// because the copy only happens once per font load.
fn c_bytes(data &u8, len int) []u8 {
	mut out := []u8{cap: if len > 0 { len } else { 0 }}
	if data == unsafe { nil } || len <= 0 {
		return out
	}
	unsafe {
		for i in 0 .. len {
			out << data[i]
		}
	}
	return out
}

// c_dir reads the direction the same way the V caller passes it: 0 is
// left-to-right, 1 is right-to-left, and anything else takes the direction
// from the first strong character, which is what a caller usually wants for a
// line of unknown language.
fn c_dir(dir int) shape.Direction {
	if dir == 1 {
		return .rtl
	}
	if dir == 2 {
		return .auto
	}
	return .ltr
}

// c_options fills a layout.LayoutOptions from the C struct, or the default when the
// caller passes null. Features arrive as one comma-separated string because a
// C caller has no string array to hand over; an empty entry is skipped rather
// than looked up, so a trailing comma is harmless.
fn c_options(opts &COptions) layout.LayoutOptions {
	mut out := layout.LayoutOptions{}
	if opts == unsafe { nil } {
		return out
	}
	unsafe {
		if opts.features != nil && opts.features[0] != 0 {
			s := tos_clone(opts.features)
			for f in s.split(',') {
				t := f.trim_space()
				if t != '' {
					out.features << t
				}
			}
		}
		out.line_height = opts.line_height
		out.letter_spacing = opts.letter_spacing
		out.word_spacing = opts.word_spacing
	}
	return out
}

// c_array moves array contents into C memory, returning an unmanaged V array over it.
//
// The boxes below own their glyphs for a C caller, and the release functions free them
// with the C free — which is only exact on memory C allocated. A managed V array's
// backing carries a runtime header (and a possible slice offset) that C free must not
// touch: freeing it aborts on a checked allocator, which is what every wrap and line
// release did before this. The flags stay clear, so the copy behaves like plain memory
// on every toolchain: reads and indexing do not consult them, and nothing here appends
// after boxing. The V original is dropped with the caller's temporary, which -gc none
// never collects — the same cost every transient in this library already pays, measured
// rather than assumed, and bounded to one buffer per boxed array.
fn c_array[T](src []T) []T {
	if src.len == 0 {
		return []T{}
	}
	unsafe {
		n := u64(src.len) * u64(sizeof(T))
		dst := malloc(n)
		C.memcpy(dst, src.data, usize(n))
		mut out := []T{cap: 0}
		out.data = dst
		out.len = src.len
		out.cap = src.len
		out.flags = ArrayFlags(0)
		return out
	}
}

// box_line moves a laid-out line onto the heap, because a value return would
// copy the glyph array header and leave two owners of one backing. The glyphs
// themselves are copied by the layout pass already, and once more here into C
// memory, so the box owns them and `vtext_line_free` releases them.
fn box_line(line layout.Line) &layout.Line {
	unsafe {
		mut p := &layout.Line(malloc(sizeof(layout.Line)))
		*p = line
		p.glyphs = c_array(line.glyphs)
		return p
	}
}

// free_line_box releases the line and the glyphs on it. A glyph carries no
// heap of its own — its font is borrowed from the caller's set — so the
// backing is the only thing to free besides the shell.
fn free_line_box(p &layout.Line) {
	if p == unsafe { nil } {
		return
	}
	unsafe {
		if p.glyphs.len > 0 {
			free(p.glyphs.data)
		}
		free(p)
	}
}

// COptions is the C spelling of layout.LayoutOptions, laid out for a C struct of the
// same shape: `vtext_options_t` in vtext.h. The features string is
// comma-separated and may be null.
pub struct COptions {
pub mut:
	features       &u8
	line_height    f64
	letter_spacing f64
	word_spacing   f64
}

// CBreaks is what a break query hands back: two parallel arrays of len ints,
// starts and whether each start is mandatory. One allocation per array, freed
// together by `vtext_breaks_free`.
pub struct CBreaks {
pub mut:
	starts    &i32
	mandatory &i32
	len       i32
}

// CMetrics is the C spelling of layout.TextMetrics, by value: five doubles and no
// ownership, so there is nothing to free.
pub struct CMetrics {
pub mut:
	min_content_width f64
	max_content_width f64
	ascent            f64
	descent           f64
	line_height       f64
}

// CGlyph is one drawable glyph as plain values: the gid to rasterize, the pen
// movement, the position from the line's left edge, and the input character it
// came from. Mirrors `vtext_glyph_t` in vtext.h field for field.
pub struct CGlyph {
pub mut:
	gid     u16
	advance f64
	x       f64
	y       f64
	cluster i32
	is_mark i32
}

// vtext_version names this build. A C caller checks it once rather than
// assuming the header and the library came from the same tree.
@[export: 'vtext_version']
pub fn vtext_version() &u8 {
	return unsafe { c'0.1.0' }
}

// vtext_context_new decodes every table. It costs a few hundred microseconds,
// which is a lot compared with shaping a short string, so a caller builds one
// and keeps it for the text system rather than one per call.
@[export: 'vtext_context_new']
pub fn vtext_context_new() &shape.Context {
	return shape.new_context()
}

// vtext_context_free releases a context. Tables are decoded per context, so
// one that is still shaping must not be freed under itself.
@[export: 'vtext_context_free']
pub fn vtext_context_free(ctx &shape.Context) {
	if ctx == unsafe { nil } {
		return
	}
	unsafe {
		free(ctx)
	}
}

// vtext_font_load_file reads and parses a font from disk, or null with the
// reason in err.
@[export: 'vtext_font_load_file']
pub fn vtext_font_load_file(path &u8, errbuf &u8, errcap int) &shape.Font {
	if path == unsafe { nil } {
		set_error(errbuf, errcap, 'vtext: font path is null')
		return unsafe { nil }
	}
	unsafe {
		s := tos_clone(path)
		f := shape.load_font_file(s) or {
			set_error(errbuf, errcap, 'vtext: cannot load font "${s}": ${err}')
			return nil
		}
		return f
	}
}

// vtext_font_load_bytes parses a font already held in memory. The bytes are
// copied, so the caller owns them throughout.
@[export: 'vtext_font_load_bytes']
pub fn vtext_font_load_bytes(data &u8, len int, errbuf &u8, errcap int) &shape.Font {
	bytes := c_bytes(data, len)
	if bytes.len == 0 {
		set_error(errbuf, errcap, 'vtext: font bytes are empty')
		return unsafe { nil }
	}
	f := shape.load_font_bytes(bytes) or {
		set_error(errbuf, errcap, 'vtext: cannot parse font: ${err}')
		return unsafe { nil }
	}
	return f
}

// vtext_font_free releases a font. A set holding it borrows it, and a line
// shaped from it names it per glyph, so a font is freed after the set and the
// lines that used it rather than before.
@[export: 'vtext_font_free']
pub fn vtext_font_free(f &shape.Font) {
	if f == unsafe { nil } {
		return
	}
	unsafe {
		free(f)
	}
}

// vtext_fontset_new returns an empty fallback chain. A codepoint is drawn
// with the first font that really covers it.
@[export: 'vtext_fontset_new']
pub fn vtext_fontset_new() &shape.FontSet {
	return shape.new_font_set()
}

// vtext_fontset_new_script returns a chain that prefers a font for the script
// each character belongs to: Arabic goes to the primary face and everything
// else to the general one, which is what a flat order cannot express when both
// fonts cover both scripts.
@[export: 'vtext_fontset_new_script']
pub fn vtext_fontset_new_script(primary &shape.Font, general &shape.Font, errbuf &u8, errcap int) &shape.FontSet {
	if primary == unsafe { nil } || general == unsafe { nil } {
		set_error(errbuf, errcap, 'vtext: script font set needs two fonts')
		return unsafe { nil }
	}
	return shape.new_script_font_set(primary, general)
}

// vtext_fontset_free releases the chain, not the fonts in it: they are
// borrowed, so the caller frees them after the set.
@[export: 'vtext_fontset_free']
pub fn vtext_fontset_free(fs &shape.FontSet) {
	if fs == unsafe { nil } {
		return
	}
	unsafe {
		free(fs)
	}
}

// vtext_fontset_add appends a font as the least preferred one, returning 1 on
// success and 0 with the reason in err.
@[export: 'vtext_fontset_add']
pub fn vtext_fontset_add(fs &shape.FontSet, f &shape.Font, errbuf &u8, errcap int) int {
	if fs == unsafe { nil } || f == unsafe { nil } {
		set_error(errbuf, errcap, 'vtext: font set and font must both be non-null')
		return 0
	}
	fs.add(f)
	return 1
}

// vtext_fontset_add_file loads a font and appends it in one call, returning
// the font for the caller to free or null with the reason in err. The set
// borrows it either way.
@[export: 'vtext_fontset_add_file']
pub fn vtext_fontset_add_file(fs &shape.FontSet, path &u8, errbuf &u8, errcap int) &shape.Font {
	if fs == unsafe { nil } {
		set_error(errbuf, errcap, 'vtext: font set is null')
		return unsafe { nil }
	}
	f := vtext_font_load_file(path, errbuf, errcap)
	if f == unsafe { nil } {
		return unsafe { nil }
	}
	fs.add(f)
	return f
}

// vtext_font_units_per_em is the design grid the font is drawn on.
@[export: 'vtext_font_units_per_em']
pub fn vtext_font_units_per_em(f &shape.Font) int {
	if f == unsafe { nil } {
		return 0
	}
	return f.units_per_em()
}

// vtext_font_ascent is the distance above the baseline in pixels at em_px.
@[export: 'vtext_font_ascent']
pub fn vtext_font_ascent(f &shape.Font, em_px f64) f64 {
	if f == unsafe { nil } {
		return 0.0
	}
	return f.ascent(em_px)
}

// vtext_font_descent is the distance below the baseline in pixels, positive.
@[export: 'vtext_font_descent']
pub fn vtext_font_descent(f &shape.Font, em_px f64) f64 {
	if f == unsafe { nil } {
		return 0.0
	}
	return f.descent(em_px)
}

// vtext_font_line_height is the baseline-to-baseline distance in pixels.
@[export: 'vtext_font_line_height']
pub fn vtext_font_line_height(f &shape.Font, em_px f64) f64 {
	if f == unsafe { nil } {
		return 0.0
	}
	return f.line_height(em_px)
}

// vtext_font_is_monospace reports whether every glyph shares one advance.
@[export: 'vtext_font_is_monospace']
pub fn vtext_font_is_monospace(f &shape.Font) int {
	if f == unsafe { nil } {
		return 0
	}
	return if f.is_monospaced() { 1 } else { 0 }
}

// vtext_font_glyph_index maps a codepoint to a glyph index, or zero for
// .notdef, which for a codepoint the font does not cover is the correct answer
// rather than a miss.
@[export: 'vtext_font_glyph_index']
pub fn vtext_font_glyph_index(f &shape.Font, cp u32) u16 {
	if f == unsafe { nil } {
		return 0
	}
	return f.glyph_index(rune(cp))
}

// vtext_font_has_glyph reports whether the font really covers cp. Fallback
// needs this distinction: a font that maps cp to .notdef is not a candidate
// for it.
@[export: 'vtext_font_has_glyph']
pub fn vtext_font_has_glyph(f &shape.Font, cp u32) int {
	if f == unsafe { nil } {
		return 0
	}
	return if f.has_glyph(rune(cp)) { 1 } else { 0 }
}

// vtext_layout runs the whole pipeline for one paragraph and returns the
// glyphs left to right, ready to draw. dir is 0 for ltr, 1 for rtl, anything
// else takes the direction from the first strong character.
@[export: 'vtext_layout']
pub fn vtext_layout(ctx &shape.Context, text &u8, len int, dir int, fs &shape.FontSet, em_px f64,
	errbuf &u8, errcap int) &layout.Line {
	if ctx == unsafe { nil } || fs == unsafe { nil } {
		set_error(errbuf, errcap, 'vtext: context and font set must both be non-null')
		return unsafe { nil }
	}
	cps := c_text(text, len)
	return box_line(layout.layout_paragraph(ctx, cps, c_dir(dir), fs, em_px))
}

// vtext_layout_with is vtext_layout with the caller's options: discretionary
// features as a comma-separated string, a line height, and letter and word
// spacing. Null options are the default, which applies no features.
@[export: 'vtext_layout_with']
pub fn vtext_layout_with(ctx &shape.Context, text &u8, len int, dir int, fs &shape.FontSet, em_px f64,
	opts &COptions, errbuf &u8, errcap int) &layout.Line {
	if ctx == unsafe { nil } || fs == unsafe { nil } {
		set_error(errbuf, errcap, 'vtext: context and font set must both be non-null')
		return unsafe { nil }
	}
	cps := c_text(text, len)
	options := c_options(opts)
	return box_line(layout.layout_paragraph_with(ctx, cps, c_dir(dir), fs, em_px, &options))
}

// vtext_line_free releases a laid-out line and the glyphs on it. The fonts the
// glyphs name are borrowed from the caller's set and are not touched.
@[export: 'vtext_line_free']
pub fn vtext_line_free(line &layout.Line) {
	free_line_box(line)
}

// vtext_line_glyph_count is how many drawable glyphs are on the line. A mark
// and its base are both present and share a position, so this counts marks too.
@[export: 'vtext_line_glyph_count']
pub fn vtext_line_glyph_count(line &layout.Line) int {
	if line == unsafe { nil } {
		return 0
	}
	return line.glyphs.len
}

// vtext_line_glyph writes glyph i into out and returns 1, or 0 when i is out
// of range. The glyph's font comes from `vtext_line_glyph_font`, because the
// caller needs it to rasterize and a glyph without its font is not drawable.
@[export: 'vtext_line_glyph']
pub fn vtext_line_glyph(line &layout.Line, i int, out &CGlyph) int {
	if line == unsafe { nil } || out == unsafe { nil } {
		return 0
	}
	if i < 0 || i >= line.glyphs.len {
		return 0
	}
	g := line.glyphs[i]
	unsafe {
		out.gid = g.gid
		out.advance = g.advance
		out.x = g.x
		out.y = g.y
		out.cluster = i32(g.cluster)
		out.is_mark = if g.is_mark { 1 } else { 0 }
	}
	return 1
}

// vtext_line_glyph_font is the font glyph i was found in, borrowed from the
// caller's set. Null only when the chain was empty, which is a wiring mistake
// rather than a missing character.
@[export: 'vtext_line_glyph_font']
pub fn vtext_line_glyph_font(line &layout.Line, i int) &shape.Font {
	if line == unsafe { nil } {
		return unsafe { nil }
	}
	if i < 0 || i >= line.glyphs.len {
		return unsafe { nil }
	}
	return line.glyphs[i].font or { unsafe { nil } }
}

// vtext_line_width is the total advance of the line in pixels.
@[export: 'vtext_line_width']
pub fn vtext_line_width(line &layout.Line) f64 {
	if line == unsafe { nil } {
		return 0.0
	}
	return line.width
}

// vtext_line_ascent and vtext_line_descent are how far the ink reaches above
// and below the baseline in pixels. A mark that reaches above the font's own
// ascent makes the ascent larger, which is what stops a caller clipping it.
@[export: 'vtext_line_ascent']
pub fn vtext_line_ascent(line &layout.Line) f64 {
	if line == unsafe { nil } {
		return 0.0
	}
	return line.ascent
}

@[export: 'vtext_line_descent']
pub fn vtext_line_descent(line &layout.Line) f64 {
	if line == unsafe { nil } {
		return 0.0
	}
	return line.descent
}

// vtext_line_height is the resolved baseline-to-baseline distance: the
// caller's line height when there is one, otherwise the largest natural line
// height among the fonts that contributed a glyph.
@[export: 'vtext_line_height']
pub fn vtext_line_height(line &layout.Line) f64 {
	if line == unsafe { nil } {
		return 0.0
	}
	return line.line_height
}

// vtext_wrap lays text out into as many lines as fit max_width. The paragraph
// is shaped once and the lines are cut out of it, so trying a narrower width
// costs no extra shaping. A word wider than the width goes on a line of its
// own rather than being split.
@[export: 'vtext_wrap']
pub fn vtext_wrap(ctx &shape.Context, text &u8, len int, dir int, fs &shape.FontSet, em_px f64,
	max_width f64, errbuf &u8, errcap int) &WrapBox {
	if ctx == unsafe { nil } || fs == unsafe { nil } {
		set_error(errbuf, errcap, 'vtext: context and font set must both be non-null')
		return unsafe { nil }
	}
	cps := c_text(text, len)
	return box_wrap(layout.wrap_paragraph(ctx, cps, c_dir(dir), fs, em_px, max_width))
}

// vtext_wrap_with is vtext_wrap with the caller's options. The options must
// match the ones the line is drawn with: a paragraph wrapped without the
// features was shaped without them, and the two disagree about the width of
// the same text.
@[export: 'vtext_wrap_with']
pub fn vtext_wrap_with(ctx &shape.Context, text &u8, len int, dir int, fs &shape.FontSet, em_px f64,
	max_width f64, opts &COptions, errbuf &u8, errcap int) &WrapBox {
	if ctx == unsafe { nil } || fs == unsafe { nil } {
		set_error(errbuf, errcap, 'vtext: context and font set must both be non-null')
		return unsafe { nil }
	}
	cps := c_text(text, len)
	options := c_options(opts)
	return box_wrap(layout.wrap_paragraph_with(ctx, cps, c_dir(dir), fs, em_px, max_width, &options))
}

// WrapBox owns one wrap call: the lines and, inside each, the glyphs. A line
// handed out by `vtext_wrap_line` is borrowed from the box and dies with it,
// which is why there is no per-line free.
pub struct WrapBox {
pub mut:
	lines []layout.WrappedLine
}

// box_wrap moves a wrap result onto the heap. Each line owns its glyph array
// already — the wrap pass copies the glyphs it keeps — and each array is
// copied once more here into C memory, so the box owns them and
// `vtext_wrap_free` releases all of it.
fn box_wrap(lines []layout.WrappedLine) &WrapBox {
	unsafe {
		mut p := &WrapBox(malloc(sizeof(WrapBox)))
		p.lines = c_array(lines)
		for i in 0 .. lines.len {
			mut wl := p.lines[i]
			wl.line.glyphs = c_array(lines[i].line.glyphs)
			p.lines[i] = wl
		}
		return p
	}
}

// vtext_wrap_free releases a wrap call and every line in it.
@[export: 'vtext_wrap_free']
pub fn vtext_wrap_free(w &WrapBox) {
	if w == unsafe { nil } {
		return
	}
	unsafe {
		for i in 0 .. w.lines.len {
			if w.lines[i].line.glyphs.len > 0 {
				free(w.lines[i].line.glyphs.data)
			}
		}
		if w.lines.len > 0 {
			free(w.lines.data)
		}
		free(w)
	}
}

// vtext_wrap_line_count is how many lines the text needed.
@[export: 'vtext_wrap_line_count']
pub fn vtext_wrap_line_count(w &WrapBox) int {
	if w == unsafe { nil } {
		return 0
	}
	return w.lines.len
}

// vtext_wrap_line returns line i, borrowed from the box. Null when i is out of
// range; otherwise valid until `vtext_wrap_free`.
@[export: 'vtext_wrap_line']
pub fn vtext_wrap_line(w &WrapBox, i int) &layout.Line {
	if w == unsafe { nil } {
		return unsafe { nil }
	}
	if i < 0 || i >= w.lines.len {
		return unsafe { nil }
	}
	return &w.lines[i].line
}

// vtext_wrap_line_from and vtext_wrap_line_to are the half-open range of the
// caller's input characters the line covers, so a caller can map any glyph
// back to the text through its cluster.
@[export: 'vtext_wrap_line_from']
pub fn vtext_wrap_line_from(w &WrapBox, i int) int {
	if w == unsafe { nil } {
		return 0
	}
	if i < 0 || i >= w.lines.len {
		return 0
	}
	return w.lines[i].from
}

@[export: 'vtext_wrap_line_to']
pub fn vtext_wrap_line_to(w &WrapBox, i int) int {
	if w == unsafe { nil } {
		return 0
	}
	if i < 0 || i >= w.lines.len {
		return 0
	}
	return w.lines[i].to
}

// vtext_measure reports what a caller needs to know before it draws: the
// narrowest width without a glyph breaking out, the widest with no break
// taken, and the ink extent with the resolved line height. Both widths come
// out of one shaping. Returns 1 and fills out, or 0 with the reason in err.
@[export: 'vtext_measure']
pub fn vtext_measure(ctx &shape.Context, text &u8, len int, dir int, fs &shape.FontSet, em_px f64,
	out &CMetrics, errbuf &u8, errcap int) int {
	return vtext_measure_with(ctx, text, len, dir, fs, em_px, unsafe { nil }, out, errbuf,
		errcap)
}

// vtext_measure_with is vtext_measure with the caller's options. A measurement
// taken with different options is a measurement of a different line, so the
// box and the line are sized with the same ones.
@[export: 'vtext_measure_with']
pub fn vtext_measure_with(ctx &shape.Context, text &u8, len int, dir int, fs &shape.FontSet, em_px f64,
	opts &COptions, out &CMetrics, errbuf &u8, errcap int) int {
	if ctx == unsafe { nil } || fs == unsafe { nil } || out == unsafe { nil } {
		set_error(errbuf, errcap, 'vtext: context, font set and output must all be non-null')
		return 0
	}
	cps := c_text(text, len)
	options := c_options(opts)
	m := layout.measure_paragraph_with(ctx, cps, c_dir(dir), fs, em_px, &options)
	unsafe {
		out.min_content_width = m.min_content_width
		out.max_content_width = m.max_content_width
		out.ascent = m.ascent
		out.descent = m.descent
		out.line_height = m.line_height
	}
	return 1
}

// vtext_breaks reports where a line may end: one entry per input position,
// each with whether the break is mandatory. Returns null with the reason in
// err when the context is missing; an empty text is an empty answer, not an
// error.
@[export: 'vtext_breaks']
pub fn vtext_breaks(ctx &shape.Context, text &u8, len int, mandatory_first int, errbuf &u8,
	errcap int) &CBreaks {
	if ctx == unsafe { nil } {
		set_error(errbuf, errcap, 'vtext: context must be non-null')
		return unsafe { nil }
	}
	cps := c_text(text, len)
	ops := layout.break_opportunities(ctx, cps, mandatory_first != 0)
	unsafe {
		mut b := &CBreaks(malloc(sizeof(CBreaks)))
		b.len = i32(ops.len)
		if ops.len == 0 {
			b.starts = nil
			b.mandatory = nil
			return b
		}
		b.starts = &i32(malloc(ops.len * sizeof(i32)))
		b.mandatory = &i32(malloc(ops.len * sizeof(i32)))
		for i in 0 .. ops.len {
			b.starts[i] = i32(ops[i].start)
			b.mandatory[i] = if ops[i].is_mandatory { 1 } else { 0 }
		}
		return b
	}
}

// vtext_breaks_free releases a break query.
@[export: 'vtext_breaks_free']
pub fn vtext_breaks_free(b &CBreaks) {
	if b == unsafe { nil } {
		return
	}
	unsafe {
		if b.len > 0 {
			free(b.starts)
			free(b.mandatory)
		}
		free(b)
	}
}

// CBitmap is what a rasterize call hands back: the ink box and the coverage in
// caller-owned memory. It mirrors font.GlyphBitmap field for field, except the
// coverage is a malloc'd buffer with an explicit length rather than a V array:
// the bitmap crosses into C, and freeing V-allocated memory with the C free
// couples the caller to whatever allocator that V array came from. The box is
// read with box_only (no allocation, no fill) and the ink is rendered straight
// into the caller's buffer with render_into, so no V array exists anywhere on
// this path. vtext_bitmap_t in vtext.h stays opaque: only the accessors below
// read these fields, and an empty glyph is a null data pointer with zero size.
pub struct CBitmap {
pub mut:
	data   &u8
	len    i32
	width  i32
	height i32
	left   i32
	top    i32
}

// vtext_rasterize renders one glyph at em_px and returns its 8-bit coverage,
// with the ink box placed relative to the pen on the baseline. sub_x and
// sub_y snap the position to quarter-pixel bins: four is one whole pixel.
@[export: 'vtext_rasterize']
pub fn vtext_rasterize(f &shape.Font, gid u16, em_px f64, sub_x int, sub_y int, errbuf &u8,
	errcap int) &CBitmap {
	if f == unsafe { nil } {
		set_error(errbuf, errcap, 'vtext: font must be non-null')
		return unsafe { nil }
	}
	unsafe {
		mut p := &CBitmap(malloc(sizeof(CBitmap)))
		p.data = nil
		p.len = 0
		p.width = 0
		p.height = 0
		p.left = 0
		p.top = 0
		// Same bounds rasterize_glyph enforces: a corrupt or absurd box must
		// not turn into a huge allocation.
		box := f.face.box_only(gid, em_px)
		if box.width <= 0 || box.height <= 0 || box.width > 4096 || box.height > 4096 {
			return p
		}
		n := box.width * box.height
		data := &u8(malloc(n))
		f.face.render_into(gid, em_px, i32(sub_x), i32(sub_y), data, box.width, box.height)
		p.data = data
		p.len = i32(n)
		p.width = i32(box.width)
		p.height = i32(box.height)
		p.left = i32(box.left)
		p.top = i32(box.top)
		return p
	}
}

// vtext_bitmap_free releases a rasterized glyph. Both allocations are the
// caller's in the only sense that matters here: malloc'd on this side, freed
// on this side, with no V array in between.
@[export: 'vtext_bitmap_free']
pub fn vtext_bitmap_free(bm &CBitmap) {
	if bm == unsafe { nil } {
		return
	}
	unsafe {
		if bm.data != nil && bm.len > 0 {
			free(bm.data)
		}
		free(bm)
	}
}

// vtext_bitmap_width, height, left and top place the ink: the pixel the
// bitmap's own (0, 0) belongs at is (pen - left, baseline - top), with top
// positive upwards.
@[export: 'vtext_bitmap_width']
pub fn vtext_bitmap_width(bm &CBitmap) int {
	if bm == unsafe { nil } {
		return 0
	}
	return bm.width
}

@[export: 'vtext_bitmap_height']
pub fn vtext_bitmap_height(bm &CBitmap) int {
	if bm == unsafe { nil } {
		return 0
	}
	return bm.height
}

@[export: 'vtext_bitmap_left']
pub fn vtext_bitmap_left(bm &CBitmap) int {
	if bm == unsafe { nil } {
		return 0
	}
	return bm.left
}

@[export: 'vtext_bitmap_top']
pub fn vtext_bitmap_top(bm &CBitmap) int {
	if bm == unsafe { nil } {
		return 0
	}
	return bm.top
}

// vtext_bitmap_data is the row-major coverage, width times height bytes: 0 is
// empty and 255 is solid ink. Borrowed from the bitmap and valid until it is
// freed; null for an empty glyph.
@[export: 'vtext_bitmap_data']
pub fn vtext_bitmap_data(bm &CBitmap) &u8 {
	if bm == unsafe { nil } || bm.data == nil || bm.len == 0 {
		return unsafe { nil }
	}
	return bm.data
}
