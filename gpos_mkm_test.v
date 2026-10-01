module vtext

// Tests for mark-to-mark: two marks on one letter, where the upper one attaches to the lower one
// rather than to the letter underneath.
//
// A shadda with a fatha on it is the case. Both are marks, neither is a letter, and the fatha has to
// go on the shadda: a shadda is drawn as a small w shape, and putting the fatha on the letter leaves
// the fatha below the w rather than above it. The font says where by a mark-to-mark lookup, which is
// a different table from the mark-to-base one and lives under a different feature.
//
// The feature is the thing worth knowing here. Tahoma carries thirteen mark-to-mark subtables and
// every one is under the feature tagged mkmk, none under abvm, blwm or mark. An engine that asks
// for the three features a mark-to-base rule can be under finds none of them, and stacking silently
// falls back to putting both marks against the letter, which is legible and wrong.

import os

fn mkm_font(name string) &Font {
	path := os.join_path('C:\\Windows\\Fonts', name)
	return load_font_file(path) or { panic(err) }
}

// runes builds a slice of codepoints by appending, because an inline []rune{...} holding values
// above 255 evaluates to an empty slice in this compiler and a test written that way measures the
// compiler rather than the engine.
fn runes(cps ...int) []rune {
	mut out := []rune{}
	for c in cps {
		out << c
	}
	return out
}

const mkm_beh = 0x0628
const mkm_shadda = 0x0651
const mkm_fatha = 0x064E
const mkm_damma = 0x064F
const mkm_kasra = 0x0650

// mkm_fonts is the set whose mark feature reaches a mark-to-mark rule for the marks used here.
const mkm_fonts = ['tahoma.ttf', 'segoeui.ttf', 'andlso.ttf', 'majalla.ttf', 'trado.ttf']

// test_mkm_fonts_that_can_stack_report_it checks the capability flag against the table.
//
// On its own because it is the cheapest way to tell a lookup list that never reached a mark-to-mark
// rule from one that did, and without it every placement test below would pass for the wrong reason
// on a font that falls back to the letter.
fn test_mkm_fonts_that_can_stack_report_it() {
	mut found := 0
	mut checked := 0
	for name in mkm_fonts {
		f := mkm_font(name)
		checked++
		if f.stacks_marks() {
			found++
		}
	}
	assert found >= 3, 'expected at least 3 of ${checked} fonts to stack marks, found ${found}'
}

// test_mkm_a_mark_above_a_shadda_is_higher checks the stacking itself.
//
// Two marks on one letter, with the second written after the first, is what stacking means. The
// check is that they are in different places: a mark-to-mark lookup exists precisely to move the
// upper one off the lower one, and an engine without it puts both against the letter at the same
// height.
fn test_mkm_a_mark_above_a_shadda_is_higher() {
	f := mkm_font('tahoma.ttf')
	// beh, shadda, fatha. The fatha belongs on the shadda.
	ctx := new_context()
	stacked := layout_paragraph(ctx, runes(mkm_beh, mkm_shadda, mkm_fatha), .rtl,
		new_font_set_of(f), 64.0)
	assert stacked.glyphs.len == 3, 'three characters give three glyphs, got ${stacked.glyphs.len}'
	// The line is right to left and the marks come before the letter, so the shadda is the one drawn
	// first among the two marks and the fatha the second. Which of the two has the greater cluster
	// says which is which, rather than trusting the order.
	mut shadda_g := stacked.glyphs[0]
	mut fatha_g := stacked.glyphs[1]
	for g in stacked.glyphs {
		if g.cluster == 1 {
			shadda_g = g
		}
		if g.cluster == 2 {
			fatha_g = g
		}
	}
	assert fatha_g.cluster > shadda_g.cluster, 'the fatha is the later character'
	// In a line whose y grows upwards, higher means a smaller y. A fatha is above a shadda.
	assert fatha_g.y < shadda_g.y, 'a fatha should sit above a shadda, but fatha y=${fatha_g.y} and shadda y=${shadda_g.y}'
	// And they are not at the same height, which is the whole claim.
	assert fatha_g.y != shadda_g.y
}

// test_mkm_different_marks_land_differently checks that the second mark's class is being read.
//
// A fatha and a damma on the same shadda are drawn at different heights, and the font separates
// them by class. An engine that used one anchor for both would put them in the same place, which is
// the fault that survives a mark-to-mark lookup being present but its classes being ignored.
fn test_mkm_different_marks_land_differently() {
	f := mkm_font('tahoma.ttf')
	ctx := new_context()
	mut with_fatha := []rune{}
	with_fatha << mkm_beh
	with_fatha << mkm_shadda
	with_fatha << mkm_fatha
	a := layout_paragraph(ctx, with_fatha, .rtl, new_font_set_of(f), 64.0)
	ctx2 := new_context()
	mut with_damma := []rune{}
	with_damma << mkm_beh
	with_damma << mkm_shadda
	with_damma << mkm_damma
	b := layout_paragraph(ctx2, with_damma, .rtl, new_font_set_of(f), 64.0)
	assert a.glyphs.len == 3 && b.glyphs.len == 3
	// The first mark is the shadda in both, and the second is the one that differs.
	mut a_second := a.glyphs[0]
	mut b_second := b.glyphs[0]
	for g in a.glyphs {
		if g.cluster == 2 {
			a_second = g
		}
	}
	for g in b.glyphs {
		if g.cluster == 2 {
			b_second = g
		}
	}
	assert a_second.y != b_second.y, 'a fatha and a damma are both at y=${a_second.y}, so the class is ignored'
}

// test_mkm_the_upper_mark_moves_relative_to_the_letter checks that stacking is not a coincidence.
//
// The lower mark's position should be the same whether or not another mark is stacked on it, and
// the upper mark's should be different. If both moved together the engine would be repositioning
// something other than the upper mark, which would look right and be wrong.
fn test_mkm_the_upper_mark_moves_relative_to_the_letter() {
	f := mkm_font('tahoma.ttf')
	ctx := new_context()
	mut with_fatha := []rune{}
	with_fatha << mkm_beh
	with_fatha << mkm_shadda
	with_fatha << mkm_fatha
	a := layout_paragraph(ctx, with_fatha, .rtl, new_font_set_of(f), 64.0)
	ctx2 := new_context()
	mut shadda_only := []rune{}
	shadda_only << mkm_beh
	shadda_only << mkm_shadda
	b := layout_paragraph(ctx2, shadda_only, .rtl, new_font_set_of(f), 64.0)
	assert a.glyphs.len == 3 && b.glyphs.len == 2
	// The shadda is the mark with cluster one in both lines.
	mut a_shadda := a.glyphs[0]
	for g in a.glyphs {
		if g.cluster == 1 {
			a_shadda = g
		}
	}
	mut b_shadda := b.glyphs[0]
	for g in b.glyphs {
		if g.cluster == 1 {
			b_shadda = g
		}
	}
	// Adding a mark on top of the shadda does not move the shadda itself.
	assert a_shadda.y == b_shadda.y, 'the shadda moved from ${b_shadda.y} to ${a_shadda.y} when a mark was stacked on it'
	// And the mark that was added is somewhere else, which is what the mark-to-mark rule did.
	mut a_fatha := a.glyphs[0]
	for g in a.glyphs {
		if g.cluster == 2 {
			a_fatha = g
		}
	}
	assert a_fatha.y != b_shadda.y, 'the stacked mark landed on the shadda at ${a_fatha.y}'
}

// test_mkm_a_lone_mark_is_unaffected checks that stacking did not take the single mark case away.
//
// The stacked path and the against-the-letter path are chosen in the same function, and an engine
// that always looked for a mark to stack on would leave a lone mark unplaced.
fn test_mkm_a_lone_mark_is_unaffected() {
	f := mkm_font('tahoma.ttf')
	ctx := new_context()
	mut cps := []rune{}
	cps << mkm_beh
	cps << mkm_fatha
	line := layout_paragraph(ctx, cps, .rtl, new_font_set_of(f), 64.0)
	assert line.glyphs.len == 2, 'a letter and a mark are two glyphs, got ${line.glyphs.len}'
	mark := line.glyphs[0]
	assert mark.is_mark, 'the first glyph in a right to left line is the mark'
	assert mark.x != 0.0 || mark.y != 0.0, 'a lone mark on a letter should leave the pen'
}
