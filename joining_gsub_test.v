module vtext

// Tests for Arabic joining applied through the font's own GSUB features.
//
// The four joining features are `isol`, `init`, `medi` and `fina`, and until 2026-10-04 this engine
// applied none of them over a run. It shaped a letter either through the Unicode presentation form in the
// cmap or, failing that, through a per-glyph call that returns a single glyph id. Both routes are wrong for
// the fonts this file is written against, and the tests here are the ones that say so.

import os

fn corpus_font(name string) &Font {
	return load_font_file(os.join_path('testdata', 'fonts', name)) or { panic(err) }
}

// laid_out shapes a string with one font and returns the line, which is the only way to ask the pipeline
// what it actually did rather than what a lookup table says it should have.
fn laid_out(f &Font, text string) Line {
	fs := new_font_set()
	fs.add(f)
	return layout_paragraph(new_context(), text.runes(), .rtl, fs, 1000.0)
}

// The joining rules are MultipleSubst, and most of them replace one glyph with several. Nastaliq is the
// clearest case: 46 of its 68 `init` rules produce two or three glyphs. A per-glyph call returning a single
// glyph id cannot do that at all, so the count of glyphs is the direct evidence that the run-level path ran.
fn test_joining_turns_one_letter_into_the_several_glyphs_the_font_asks_for() {
	f := corpus_font('NotoNastaliqUrdu-Regular.ttf')
	line := laid_out(f, 'سلام')
	assert line.glyphs.len > 4, 'four letters produced more than four glyphs, got ${line.glyphs.len}'
	// Every glyph has to come from a real cluster, so an expansion has not lost track of where it came
	// from. This is the property a 1:N substitution is easy to get wrong: the pieces share one cluster and
	// a caller mapping a glyph back to a caret position needs all of them to report the same one.
	mut by_cluster := map[int]int{}
	for g in line.glyphs {
		by_cluster[g.cluster]++
	}
	assert by_cluster.len == 4, 'four clusters are represented, got ${by_cluster.len}'
	for cluster, n in by_cluster {
		assert n >= 1, 'cluster ${cluster} has ${n} glyphs'
	}
}

// This is what the whole change was for. A cursive rule covers particular glyphs, and the attachment can
// only happen when shaping selects one of them; before the joining features ran over the run, the letters
// came out as glyphs the rule did not cover and the attachment was unreachable on every font available.
fn test_joining_selects_glyphs_the_cursive_rule_covers() {
	f := corpus_font('NotoNastaliqUrdu-Regular.ttf')
	line := laid_out(f, 'سلام')
	mut with_anchors := 0
	for g in line.glyphs {
		if gf := g.font {
			if a := gf.cursive_anchors(g.gid, 'arab') {
				if a.entry_exists || a.exit_exists {
					with_anchors++
				}
			}
		}
	}
	assert with_anchors > 0, 'the shaped run reaches glyphs the cursive rule covers, got ${with_anchors}'
}

// A letter's shape depends on where it stands, so a test has to put **the same letter** in two positions.
// Three versions of this test got it wrong in three different ways, and each was green against a broken
// build, which is the whole reason the failures are written down here:
//
//   comparing the first and last letter of سلا proves nothing, because a different letter in the same shape
//   is still a different glyph.
//   asserting the two are merely *different* also proves nothing, because a letter left as its base glyph
//   is different from every shaped form. Removing `medi` leaves the medial letter as the base letter, which
//   is different from the initial form and so passed.
//   what has to be asserted is that each occurrence is the form the font names for that position, which
//   means checking it was substituted at all and that it is not the initial one.
//
// سسل has the letter س twice. The first joins forward and is initial; the second joins both ways and is
// medial.
fn test_joining_gives_the_same_letter_a_different_shape_in_a_different_position() {
	f := corpus_font('NotoNastaliqUrdu-Regular.ttf')
	base := f.glyph_index(`س`)
	line := laid_out(f, 'سسل')
	mut shapes := map[int][]u16{}
	for g in line.glyphs {
		shapes[g.cluster] << g.gid
	}
	assert shapes.len == 3, 'three letters, got ${shapes.len}'
	assert shapes[0].len > 0 && shapes[1].len > 0, 'both س are present'

	// Both occurrences were substituted. An unshaped base letter draws as the letter with no joining at
	// all, which is legible, so nothing about the output says it is wrong.
	assert base !in shapes[0], 'the initial س was substituted away from the base letter gid ${base}'
	assert base !in shapes[1], 'the medial س was substituted away from the base letter gid ${base}'

	// And the two are not the same form, which is the other half: the medial one is not the initial one.
	assert shapes[0] != shapes[1], 'the two س stand in different shapes: ${shapes[0]} against ${shapes[1]}'
}

// A mark takes part in every joining shape, and this is the test that says so.
//
// Noto Naskh Arabic's lookup 4 turns a dot-centred mark into a dot-below one — `dotcenterar` becomes
// `dotbelowar` and ten more like it — and `init`, `medi` and `fina` all name that one lookup. A font does
// that because a dot sits below the letter in one joining shape and above it in another, so the same mark
// has to be composed differently per shape. The feature naming a letter's shape therefore also composes its
// marks, and the two cannot be separated.
//
// Excluding marks from the mask is what broke this font's rendering: every dot stayed in the composition
// meant for a different shape, and `سلام دنیا` came out as mangled letters. The test asks `effective`
// directly rather than looking at a picture, so it fails on the cause and not on the symptom.
fn test_the_shape_mask_excludes_letters_in_other_shapes_but_not_marks() {
	f := corpus_font('NotoNastaliqUrdu-Regular.ttf')
	g := f.face.gsub or { panic('no GSUB') }
	letter := f.glyph_index(`س`)
	mark := f.glyph_index(`َ`)
	assert letter != 0 && mark != 0, 'the font covers both'

	mut run := []Ligatable{}
	run << Ligatable{
		gid:     letter
		cluster: 0
		source:  0
		form:    JoiningForm.medial
	}
	run << Ligatable{
		gid:     mark
		cluster: 1
		source:  1
		form:    JoiningForm.isolated
		is_mark: true
	}
	// The final shape is asked for. The medial letter is the wrong shape and is held back; the mark is not a
	// letter, has no shape of its own, and is let through, because a font's joining features compose its
	// marks as well as its letters.
	eff := g.effective(run, 0, 0, JoiningForm.final)
	assert eff.len == 1, 'exactly one of the two takes part, got ${eff.len}'
	assert eff[0] == 1, 'and it is the mark, not the letter'

	// Both take part when no shape is being asked for, which is what every other feature does.
	all := g.effective(run, 0, 0, none)
	assert all.len == 2, 'an unmasked run keeps everything, got ${all.len}'
}

// The dot composition has to survive to the shaped run, not merely be permitted by the mask. This is the
// end-to-end half: the letter is shaped and the mark beside it is still a mark with no advance.
fn test_marks_survive_shaping_as_marks() {
	f := corpus_font('NotoNaskhArabic-Regular.ttf')
	line := laid_out(f, 'بَ')
	mut marks := 0
	for g in line.glyphs {
		if g.is_mark {
			marks++
			assert approx_zero(g.advance), 'a mark never advances the pen, got ${g.advance}'
		}
	}
	assert marks == 1, 'the fatha is still one mark, got ${marks}'
}

// The control for the whole masking idea: a font that maps the presentation forms takes the cmap route, and
// the joining features must not disturb it.
fn test_joining_leaves_a_font_that_maps_presentation_forms_alone() {
	f := corpus_font('Amiri-Regular.ttf')
	line := laid_out(f, 'سلام')
	assert line.glyphs.len == 3, 'four letters and the lam-alef is one glyph, got ${line.glyphs.len}'
	for g in line.glyphs {
		assert g.advance > 0.0, 'every letter still advances the pen'
	}
}

// Noto Nastaliq draws its lam-alef pair through a plain context rule (type 5 format 1):
// lam-medi followed by alef-fina invokes the lookup that draws both .LA forms. Without
// the plain-context reader the lam stays lam-fina at 848 wide and HarfBuzz reports 201;
// with it the lam's share of the pair is 201. A plain number comparison would also pass
// for a dropped lam, so the count is asserted too: the pair is two glyphs, one advancing.
fn test_plain_context_selects_nastaliq_lam_alef() {
	f := corpus_font('NotoNastaliqUrdu-Regular.ttf')
	line := laid_out(f, 'سلام')
	mut lam := 0.0
	mut lam_glyphs := 0
	for g in line.glyphs {
		if g.cluster == 1 {
			lam += g.advance
			lam_glyphs++
		}
	}
	assert lam_glyphs == 2, 'the lam draws as a pair, got ${lam_glyphs} glyphs'
	assert lam > 200.0 && lam < 202.0, 'the lam-alef context fired, got ${lam}'
}

fn approx_zero(w f64) bool {
	return w > -0.001 && w < 0.001
}
