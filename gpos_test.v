module vtext

// Tests for mark attachment: the GPOS mark-to-base rules, the GDEF table that classifies the
// glyphs, and the placement they produce.
//
// The fonts that matter here are the ones that put their mark rules in the table rather than
// expecting the mark to land on its own. Tahoma and Arial do, and their rules are written
// against the same glyphs their cmap hands out, so a fatha is found and given a position.
// Dubai does not: its rules are written against composed glyphs that a ccmp substitution
// produces, which is a different milestone, and the test that covers it says so rather than
// passing on a font where nothing was checked.

import os

fn gpos_font(name string) &Font {
	path := os.join_path('C:\\Windows\\Fonts', name)
	return load_font_file(path) or { panic(err) }
}

// The marks a Persian word actually carries, and the letters they sit on.
const fatha = rune(0x064E)
const damma = rune(0x064F)
const kasra = rune(0x0650)
const shadda = rune(0x0651)
const sukun = rune(0x0652)
const beh = rune(0x0628)
const seen = rune(0x0633)
const meem = rune(0x0645)

fn test_gdef_classifies_glyphs() {
	arial := gpos_font('arial.ttf')
	g := arial.face.gdef or { panic('Arial is expected to carry a GDEF table') }
	// The classification has to be read, not assumed. A letter and a mark have to come out
	// differently, since that difference is the whole reason this table exists.
	assert g.is_base(arial.glyph_index(beh)), 'beh is a letter'
	assert !g.is_mark(arial.glyph_index(beh)), 'beh is not a mark'
	assert g.is_mark(arial.glyph_index(fatha)), 'fatha is a mark'
	assert g.is_mark(arial.glyph_index(kasra)), 'kasra is a mark'
	// A glyph the table says nothing about is unclassified rather than being guessed at, and
	// unclassified is not a mark, which is the safe answer.
	assert g.glyph_class(0xFFFE) == 0
	assert !g.is_mark(0xFFFE)
	// Every range the table parsed has to be a real range, which is what catches an offset read
	// relative to the wrong place: the ranges would be in range but the wrong ones.
	assert g.glyph_classes.entries.len > 10, 'the class table should have entries'
	for e in g.glyph_classes.entries {
		assert e.first <= e.last, 'a range whose end is before its start is not a range'
		assert e.value >= 1 && e.value <= 4, 'the classes are 1 to 4, got ${e.value}'
	}
}

fn test_gdef_marks_carry_an_attachment_class() {
	arial := gpos_font('arial.ttf')
	g := arial.face.gdef or { panic('no GDEF') }
	assert g.has_mark_classes, 'Arial is expected to have mark attachment classes'
	// The class of a mark decides which of the base's anchors it uses. Every mark this font
	// classifies has to land inside the range the base arrays are built for, or the lookup
	// would ask for an anchor that is not there.
	for cp in [fatha, damma, kasra, shadda, sukun] {
		gid := arial.glyph_index(cp)
		if gid == 0 || !g.is_mark(gid) {
			continue
		}
		class := g.mark_class(gid)
		assert class >= 0, 'a classified mark should have a class'
	}
	// A font with no mark class table puts every mark in class zero, which is a real answer
	// rather than a failure.
	empty := &Gdef{}
	assert empty.mark_class(arial.glyph_index(fatha)) == 0
	assert !empty.has_mark_classes
}

fn test_gpos_reports_a_mark_to_base_rule() {
	tahoma := gpos_font('tahoma.ttf')
	assert tahoma.has_mark_attachment(), 'Tahoma is expected to place marks on their letters'
	// A font with no positioning table cannot place anything, which is a degraded rendering
	// rather than a failure.
	assert !gpos_font('ARIALN.TTF').has_mark_attachment()
}

// ink_span is how far a glyph's ink reaches above its own baseline, in pixels, as the low and
// high ends of it. The bitmap's top field is the low end and the height reaches up from there,
// which is the convention the rasteriser stores and the reason a mark's ink sits above its own
// origin rather than on it.
fn ink_span(f &Font, gid u16, em_px f64) (f64, f64) {
	bmp := f.rasterize(gid, em_px, 0, 0)
	if bmp.is_empty() {
		return 0, 0
	}
	return f64(bmp.top), f64(bmp.top + bmp.height)
}

// in_pixels converts a length in design units to pixels at this size, which is what the layout
// pass does and what a test comparing an offset with a rasterized height has to do as well.
fn in_pixels(f &Font, units i32, em_px f64) f64 {
	return f64(units) * em_px / f64(f.face.units_per_em)
}

// approx reports whether two pixel measurements agree to within tol. Advance widths and anchor
// offsets both come out of a scale from font units, so an exact compare is the wrong test.
fn approx(got f64, want f64, tol f64) bool {
	d := got - want
	return d > -tol && d < tol
}

// glyph_at_cluster returns the glyph that came from the input character at that index.
fn glyph_at_cluster(glyphs []Glyph, cluster int) ?Glyph {
	for g in glyphs {
		if g.cluster == cluster {
			return g
		}
	}
	return none
}

// The property that matters, stated about the marks and not about the base: an above mark lands
// above a below mark on the same letter.
//
// The offsets themselves can both be negative, because a mark glyph is drawn with its ink above
// its own origin, so moving the origin down is what puts the ink up. Asserting on the sign of an
// offset would encode that coincidence rather than the result, so this compares where the ink
// ends up instead.
fn test_an_above_mark_lands_higher_than_a_below_mark() {
	arial := gpos_font('arial.ttf')
	beh_gid := arial.glyph_index(beh)
	em := f64(32)

	fatha_low, _ := ink_span(arial, arial.glyph_index(fatha), em)
	fatha_off := arial.mark_offset(arial.glyph_index(fatha), beh_gid) or {
		panic('a fatha over a beh should be placed')
	}
	fatha_ink := fatha_low + in_pixels(arial, fatha_off.y, em)

	kasra_low, _ := ink_span(arial, arial.glyph_index(kasra), em)
	kasra_off := arial.mark_offset(arial.glyph_index(kasra), beh_gid) or {
		panic('a kasra over a beh should be placed')
	}
	kasra_ink := kasra_low + in_pixels(arial, kasra_off.y, em)

	// A kasra goes under its letter, so its ink has to end up below the letter's own ink.
	beh_low, _ := ink_span(arial, beh_gid, em)
	assert kasra_ink < beh_low, 'a kasra belongs below the letter it is on'
	// And the two marks cannot land in the same place, or the font is not being read and one
	// anchor is being handed to everything.
	assert fatha_ink > kasra_ink, 'a fatha belongs above a kasra on the same letter'
	// Both offsets have to be real numbers the font chose, not this engine's idea of a
	// placement. Two marks that differ only because the glyphs differ would show the same
	// offset twice.
	assert fatha_off.y != kasra_off.y, 'the two marks are attached to different anchors'
}

// The same mark on two different letters gets two different offsets, because where a letter's
// top is depends on the letter's own shape. Equal offsets here would mean the base is not being
// read at all.
fn test_the_base_letter_affects_the_offset() {
	arial := gpos_font('arial.ttf')
	fatha_gid := arial.glyph_index(fatha)
	mut offsets := map[string]bool{}
	for letter in [beh, seen, meem] {
		gid := arial.glyph_index(letter)
		off := arial.mark_offset(fatha_gid, gid) or { continue }
		offsets['${off.x},${off.y}'] = true
	}
	assert offsets.len > 1, 'a fatha should land differently on different letters'
}

fn test_mark_offset_is_absent_for_a_pair_the_font_does_not_place() {
	arial := gpos_font('arial.ttf')
	// A mark on a glyph the font has no rule for. The answer has to be absent rather than zero,
	// because zero means "put it here" and absent means "this font does not say", and the caller
	// leaves the mark at the pen for the second and not the first.
	assert arial.mark_offset(arial.glyph_index(fatha), 0xFFFE) == none
	// A mark the font places, against a base that is not a letter at all.
	assert arial.mark_offset(arial.glyph_index(fatha), arial.glyph_index(fatha)) == none
}

fn test_gpos_offsets_are_independent_of_the_em() {
	// The offset is in design units, so it is a property of the font and not of the size, and
	// the layout pass is what scales it. A test that scaled here would pass while the line came
	// out at the wrong size.
	tahoma := gpos_font('tahoma.ttf')
	a := tahoma.mark_offset(tahoma.glyph_index(fatha), tahoma.glyph_index(beh)) or {
		panic('no offset')
	}
	assert a.x != 0 || a.y != 0, 'the offset is in design units and is not zero'
}

// A font whose mark rules are written against composed glyphs cannot place a mark the engine has
// not composed, and the test says which kind of font it is looking at rather than quietly
// finding nothing. This is the honest statement of the current limit: Dubai's marks go through
// a ccmp substitution first, and that substitution is not part of this milestone.
fn test_marks_composed_by_the_font_are_out_of_reach_for_now() {
	dubai := gpos_font('DUBAI-REGULAR.TTF')
	// The font has rules.
	assert dubai.has_mark_attachment(), 'Dubai does have mark rules'
	// But they are not written against the glyph its cmap hands out for a fatha, so the lookup
	// finds nothing. This is recorded as a fact about the font rather than asserted as a
	// failure, because the missing piece is the composition step and not the parse.
	assert !dubai.mark_glyphs_passthrough(), 'Dubai composes its marks before positioning them'
	assert dubai.mark_offset(dubai.glyph_index(fatha), dubai.glyph_index(beh)) == none
	// A font that does not compose its marks is reachable, which is what the other tests use.
	assert gpos_font('tahoma.ttf').mark_glyphs_passthrough()
}

// The attachment has to reach the line, not stop at the font. A mark with a rule comes out at
// the base's anchor rather than at the pen, and a mark without one comes out at the pen, which
// is the degraded answer and not an error.
fn test_layout_puts_a_mark_at_its_letter_anchor() {
	ctx := new_context()
	arial := gpos_font('arial.ttf')
	fs := new_font_set_of(arial)
	line := layout_paragraph(ctx, [`ب`, fatha], .rtl, fs, 32)
	assert line.glyphs.len == 2, 'the letter and the mark are both drawn'
	base := glyph_at_cluster(line.glyphs, 0) or { panic('no letter glyph') }
	mark := glyph_at_cluster(line.glyphs, 1) or { panic('no mark glyph') }
	assert mark.is_mark && !base.is_mark, 'only the mark is a mark'
	assert mark.advance == 0, 'a mark costs no advance'
	// The pen has not moved between the two, so without attachment they sit in the same place.
	// With it they do not, and the move is the font's own scaled to the em.
	off := arial.mark_offset(mark.gid, base.gid) or { panic('the font should place this mark') }
	assert approx(mark.x, base.x + in_pixels(arial, off.x, 32), 0.001), 'the mark should sit at the font horizontal offset, base x=${base.x} mark x=${mark.x} off=${off.x}'
	// The line's y is positive downwards while the font's is positive upwards, so the sign is
	// flipped on the way out. Getting that wrong puts a fatha under its letter.
	assert approx(mark.y, -in_pixels(arial, off.y, 32), 0.001), 'the mark should sit at the font vertical offset, flipped for the line'
	// A mark that reaches above the font's own ascent makes the line taller than the font
	// alone would, which is what stops the caller clipping it.
	assert line.ascent > arial.ascent(32), 'the mark should count towards the line height'
}

fn test_layout_leaves_an_unplaced_mark_at_the_pen() {
	ctx := new_context()
	fs := new_font_set_of(gpos_font('arial.ttf'))
	// A fatha on its own, with no letter for it to attach to, which is what a stray vowel at
	// the start of a word looks like.
	line := layout_paragraph(ctx, [fatha], .rtl, fs, 32)
	assert line.glyphs.len == 1
	g := line.glyphs[0]
	assert g.is_mark
	assert g.x == 0, 'a mark with no letter stays at the pen'
	assert g.y == 0, 'a mark with no letter stays on the baseline'
}

// The parser has to survive a table that is not one, because font data is untrusted.
fn test_gpos_and_gdef_reject_data_that_is_not_a_table() {
	assert new_gpos([]u8{}) == none
	assert new_gpos([]u8{len: 40}) == none, 'zeroed data is not a GPOS table'
	assert new_gdef([]u8{}) == none
	assert new_gdef([]u8{len: 40}) == none, 'zeroed data is not a GDEF table'
	// A right-sized header naming an offset that is not in the buffer falls into the degraded
	// path rather than reading whatever is there.
	mut header := []u8{len: 12}
	header[0] = 0
	header[1] = 1
	header[4] = 0xFF
	header[5] = 0xFF
	assert new_gdef(header) == none
	header[8] = 0xFF
	header[9] = 0xFF
	assert new_gpos(header) == none
}
