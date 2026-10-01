module vtext

// Tests for mark-to-ligature: a mark written after a fused pair belongs to one component of that
// pair, and the font says which by giving that component the anchors and leaving the others empty.
//
// A lam and an alef are the case this exists for. They are drawn as one glyph, and a mark written
// after the pair belongs to one of the two characters rather than to the pair as a whole, so a
// mark-to-base rule would place it against the wrong origin. The font therefore keeps an anchor per
// component, and the engine has to find the one the font actually filled in.
//
// Tahoma, Arial, Dubai and Arabic Typesetting all carry these rules and all of them put the anchors
// on the first component of a lam-alef, which is why an engine that takes the last component finds
// nothing and leaves the mark at the pen.

import os

fn mtl_font(name string) &Font {
	path := os.join_path('C:\\Windows\\Fonts', name)
	return load_font_file(path) or { panic(err) }
}

// runes builds a slice of codepoints by appending.
//
// An inline []rune{...} holding values above 255 evaluates to an empty slice in this compiler,
// with no error, so a test written that way would be measuring the compiler rather than the engine
// and every line of it would quietly pass for the wrong reason.
fn runes(cps ...int) []rune {
	mut out := []rune{}
	for c in cps {
		out << c
	}
	return out
}

const mtl_lam = 0x0644
const mtl_alef = 0x0627
const mtl_fatha = 0x064E
const mtl_damma = 0x064F
const mtl_kasra = 0x0650
const mtl_beh = 0x0628

// mtl_fonts is the set of fonts whose mark feature carries a mark-to-ligature rule that covers a
// lam-alef this engine produces.
//
// It is a list rather than one font because a font either has these rules or it does not, and a
// font that does not is a font the engine is right to find nothing in. Naming the ones that do
// keeps the capability from being a constant.
const mtl_fonts = ['tahoma.ttf', 'arial.ttf', 'DUBAI-REGULAR.TTF', 'ARABTYPE.TTF', 'times.ttf']

// the_pair lays out lam and alef and returns the glyph the fusion produced, or zero when the font
// did not fuse them.
fn the_pair(font &Font) u16 {
	ctx := new_context()
	line := layout_paragraph(ctx, runes(mtl_lam, mtl_alef), .rtl, new_font_set_of(font), 64.0)
	if line.glyphs.len != 1 {
		return 0
	}
	return line.glyphs[0].gid
}

// the_line lays out lam, alef and one mark, and returns the mark glyph and where it landed.
fn the_line(font &Font, mark rune) (u16, f64, f64) {
	ctx := new_context()
	line := layout_paragraph(ctx, runes(mtl_lam, mtl_alef, mark), .rtl, new_font_set_of(font), 64.0)
	// The pair and the mark, in visual order, which in a right to left line puts the mark first.
	if line.glyphs.len != 2 {
		return 0, 0.0, 0.0
	}
	m := line.glyphs[0]
	return m.gid, m.x, m.y
}

// test_mtl_fonts_that_carry_the_rules_report_it checks the capability flag against the table.
//
// This is on its own because it is the cheapest way to tell a parser that never ran from one that
// ran and found nothing, and without it a parser that stopped reading the subtable would pass every
// placement test below, because those tests would see no rule and fall back to the pen.
fn test_mtl_fonts_that_carry_the_rules_report_it() {
	mut found := 0
	mut checked := 0
	for name in mtl_fonts {
		f := mtl_font(name)
		checked++
		if f.places_marks_on_ligatures() {
			found++
		}
	}
	// Four of the five. A lower bar would let a regression that drops one font's rules pass, and a
	// higher one would fail when Windows ships an update to a font.
	assert found >= 4, 'expected at least 4 of ${checked} fonts to place marks on ligatures, found ${found}'
}

// test_mtl_a_mark_after_a_lam_alef_is_placed checks the thing itself.
//
// The mark has to leave the pen. A mark left at the pen also has a position, so a test asserting
// only that the mark exists would pass whether the rule fired or not; what distinguishes them is
// that a placed mark is at a place the font chose and the pen is not one of them.
fn test_mtl_a_mark_after_a_lam_alef_is_placed() {
	mut placed := 0
	mut tried := 0
	for name in mtl_fonts {
		f := mtl_font(name)
		pair := the_pair(f)
		if pair == 0 {
			continue
		}
		tried++
		mark, x, y := the_line(f, mtl_fatha)
		if mark == 0 {
			continue
		}
		// A placed mark is not at the origin. Both coordinates being zero is what an unplaced mark
		// looks like, and the pair's own advance puts it there.
		if x != 0.0 || y != 0.0 {
			placed++
		}
		// And the offset the font gives has to agree with where the mark ended up, which is the whole
		// of what the rule is for.
		off := f.mark_offset(mark, pair, false) or {
			continue
		}
		scale := 64.0 / f64(f.face.units_per_em)
		assert near(f64(off.x) * scale, x), '${name}: the rule says x=${off.x} the mark is at ${x}'
		assert near(-f64(off.y) * scale, y), '${name}: the rule says y=${off.y} the mark is at ${y}'
	}
	assert tried >= 3, 'only ${tried} fonts fused the pair, so nothing much was checked'
	assert placed >= 2, 'only ${placed} of ${tried} fonts placed the mark on the pair'
}

// test_mtl_the_component_is_chosen_from_the_anchors checks the fault this milestone fixed.
//
// The engine cannot know whether a mark after a lam-alef belongs to the lam or to the alef, because
// the text does not say. The font says it by filling in one component's anchors and leaving the
// rest empty, so the component has to be the one that has an anchor rather than the first or the
// last. Tahoma puts them on the first component of a two component pair, which is what made an
// engine that took the last component find nothing.
fn test_mtl_the_component_is_chosen_from_the_anchors() {
	f := mtl_font('tahoma.ttf')
	pair := the_pair(f)
	assert pair != 0, 'tahoma should fuse lam and alef'
	mark := f.glyph_index(mtl_fatha)
	off := f.mark_offset(mark, pair, false) or {
		assert false, 'no mark-to-ligature offset for fatha on the tahoma lam-alef'
		return
	}
	// An offset that is zero on both axes would mean an anchor was found and happened to sit on the
	// origin, which for a letter is not something a font says. A non-zero one is the font choosing.
	assert off.x != 0 || off.y != 0, 'the offset should not be the origin'
}

// test_mtl_two_marks_land_in_different_places checks that the mark's class is being read.
//
// The mark's attachment class decides which anchor it gets, so two marks the font puts in different
// classes have to land in different places. Which marks those are is the font's business rather
// than this engine's: in Tahoma a kasra is a class of its own and lands lower than a fatha, while a
// damma and a fatha share a class and share an anchor, which is correct of the font and would look
// like a bug if it were not known.
fn test_mtl_two_marks_land_in_different_places() {
	f := mtl_font('tahoma.ttf')
	_, fatha_x, fatha_y := the_line(f, mtl_fatha)
	// A kasra goes below a letter and Tahoma gives it a class of its own, so it must land elsewhere.
	_, kasra_x, kasra_y := the_line(f, mtl_kasra)
	assert fatha_y != kasra_y, 'a fatha and a kasra are both at y=${fatha_y}, so the class is ignored'
	// Both are off the pen, so the difference is not one of them being unplaced.
	assert fatha_x != 0.0 || fatha_y != 0.0
	assert kasra_x != 0.0 || kasra_y != 0.0
	// And the offsets agree with the positions, which is what shows the class was read rather than
	// two different code paths happening to be tried.
	fo := f.mark_offset(f.glyph_index(mtl_fatha), the_pair(f), false) or {
		assert false, 'no offset for a fatha'
		return
	}
	ko := f.mark_offset(f.glyph_index(mtl_kasra), the_pair(f), false) or {
		assert false, 'no offset for a kasra'
		return
	}
	assert fo.x != ko.x || fo.y != ko.y, 'the two marks resolved to the same anchor (${fo.x},${fo.y})'
}

// test_mtl_a_mark_on_a_letter_still_works checks that the ligature path did not take the letter one
// away.
//
// Both paths are tried in the same lookup, and a ligature rule that answered for a plain letter, or a
// ligature rule that shadowed the mark-to-base one, would leave marks on letters in the wrong place.
// The control is the thing that already worked, so it is the thing a change here can break.
fn test_mtl_a_mark_on_a_letter_still_works() {
	f := mtl_font('tahoma.ttf')
	ctx := new_context()
	line := layout_paragraph(ctx, runes(mtl_beh, mtl_fatha), .rtl, new_font_set_of(f), 64.0)
	assert line.glyphs.len == 2, 'a letter and a mark are two glyphs, got ${line.glyphs.len}'
	mark := line.glyphs[0]
	assert mark.is_mark, 'the first glyph in a right to left line is the mark'
	assert mark.x != 0.0 || mark.y != 0.0, 'a mark on a letter should leave the pen'
}

// near is whether two positions agree to within a pixel and a half.
//
// The offset is in design units scaled to an em and the layout rounds positions as it walks the
// line, so the two are not expected to be identical. A whole pixel would be too tight and would
// fail on a rounding difference rather than on a wrong anchor.
fn near(a f64, b f64) bool {
	mut d := a - b
	if d < 0.0 {
		d = -d
	}
	return d < 1.5
}
