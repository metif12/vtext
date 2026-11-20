module layout

import vtext.shape
import vtext.font

// ShapedGlyphMemoEntry caches one FontSet.shaped_glyphs answer for a common
// single-codepoint, selector-free shaped glyph. shaped_glyphs is a pure lookup
// of cmap and UCD tables: for a fixed FontSet, Context and em_px its answer
// depends only on the shaped glyph's identity. The memo is built per layout
// call, so a different FontSet, a font added later, or another em size cannot
// read a stale entry.
//
// The key carries every input shaped_glyphs reads: form_cp (sg.cps[0]), base_cp
// (sg.base[0]), form, the mark flag and script. A multi-codepoint base, a
// multi-codepoint form or a variation selector takes the uncached path — a
// lam-alef split gives the second glyph a different form, and a format 14
// selector changes which glyph the cmap names.
//
// Slots are direct-mapped by base_cp so a hit costs one comparison, not a
// linear walk over every distinct glyph on the line.
struct ShapedGlyphMemoEntry {
	valid   bool
	form_cp int
	base_cp int
	form    font.JoiningForm
	is_mark bool
	script  string
	glyphs  []shape.Glyph
}

const glyph_memo_slots = 64

// shaped_glyphs_for answers the memo slot for this shaped glyph, resolving
// and storing it on the first miss. A hit returns the stored slice directly:
// the only caller iterates it by value, sets .cluster on the copy and appends
// that copy, so the backing array is never written.
fn shaped_glyphs_for(mut memo []ShapedGlyphMemoEntry, fs &shape.FontSet, ctx &shape.Context, sg shape.ShapedGlyph, em_px f64) []shape.Glyph {
	if sg.cps.len != 1 || sg.base.len != 1 || sg.selectors.len != 0 {
		return fs.shaped_glyphs(ctx, sg, em_px)
	}
	form_cp := int(sg.cps[0])
	base_cp := int(sg.base[0])
	idx := base_cp & (glyph_memo_slots - 1)
	m := memo[idx]
	if m.valid && m.form_cp == form_cp && m.base_cp == base_cp && m.form == sg.form
		&& m.is_mark == sg.is_mark && m.script == sg.script {
		return m.glyphs
	}
	glyphs := fs.shaped_glyphs(ctx, sg, em_px)
	memo[idx] = ShapedGlyphMemoEntry{
		valid:   true
		form_cp: form_cp
		base_cp: base_cp
		form:    sg.form
		is_mark: sg.is_mark
		script:  sg.script
		glyphs:  glyphs
	}
	return glyphs
}
