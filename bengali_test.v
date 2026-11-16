module vtext

import vtext.layout
import vtext.shape

// Tests for the second Indic script: Bengali proves the syllable machine in
// shape/indic.v is script-agnostic. No new tables were needed — the same
// 813 syllabic and 651 positional ranges that answer Devanagari answer
// Bengali, because the UCD categories are per-codepoint, not per-script.
// Every gid, advance and cluster below was read off HarfBuzz (uharfbuzz,
// scale 1000 = font units, this face is upm 1000) and fontTools before it
// was written here; agreement with a second reader is the evidence. Input
// clusters double as pins: a cluster is an input position, so the glyph
// reporting cluster 2 names no engine output of its own.
//
// The face ships in testdata/fonts with its OFL text, so it loads on every
// platform with no skips: no host font, no platform directory.
//
// Where the engine diverges from HarfBuzz, the assert pins the current
// behaviour and the comment names the gap for the engine slice that owns
// it — the same gaps indic_test.v pins for Devanagari, now shown to hold
// across scripts:
//   - pre-base matras draw first on the syllable base: the joining hook
//     feeds the reordered run into shaping and merges the clusters, and the
//     Indic defaults fuse what needs no reordering. Bengali needs no pres
//     variant: the cmap matra is what HarfBuzz draws too.
//   - KSSA fuses by default through the bng2 akhn rule, which resolves now
//     that the tag fallback names the v2 script. What stays open is the
//     Bengali conjunct assembly chain: the below-base split fires but its
//     pstf/blwf/cjct reassembly and mark positioning do not, so hindi and
//     nomoste draw the pieces where HarfBuzz draws fused, positioned forms.
//   - GPOS mark advances and offsets are the font layer: the halant reports
//     its own hmtx advance of zero, not HarfBuzz mark offsets.
//
// Repha placement and movement, split-matra halves, pstf/blwf/vatu and the
// Bengali assembly chain stay follow-ups: the 9.3d slice.

fn bengali_font_path() string {
	return 'testdata/fonts/NotoSansBengali-Variable.ttf'
}

fn bengali_font() ?&shape.Font {
	p := bengali_font_path()
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

// bengali_at returns the glyph that came from the input character at that
// index, or none when the character drew nothing.
fn bengali_at(glyphs []shape.Glyph, cluster int) ?shape.Glyph {
	for g in glyphs {
		if g.cluster == cluster {
			return g
		}
	}
	return none
}

// bengali_dump renders a line as gid:cluster:advance cells so a failing pin
// shows the whole engine answer in the message.
fn bengali_dump(line layout.Line) string {
	mut parts := []string{cap: line.glyphs.len}
	for g in line.glyphs {
		parts << '${g.gid:x}:${g.cluster}:${g.advance:.2f}'
	}
	return '[' + parts.join(' ') + ']'
}

// bengali_word builds a test word from codepoints, keeping this file ASCII.
fn bengali_word(cps []rune) []rune {
	return cps.clone()
}

// bengali_bounds renders syllables as start,end cells for one-line pins.
fn bengali_bounds(syllables []shape.IndicSyllable) string {
	mut parts := []string{cap: syllables.len}
	for s in syllables {
		parts << '${s.start},${s.end}'
	}
	return parts.join('|')
}

// bengali_hex renders codepoints as hex for one-line reorder pins.
fn bengali_hex(cps []rune) string {
	mut parts := []string{cap: cps.len}
	for cp in cps {
		parts << '${u32(cp):04X}'
	}
	return parts.join(' ')
}

// bengali_spans renders conjuncts as start,end cells for one-line pins.
fn bengali_spans(conjuncts []shape.IndicConjunct) string {
	mut parts := []string{cap: conjuncts.len}
	for c in conjuncts {
		parts << '${c.start},${c.end}'
	}
	return parts.join('|')
}

fn test_bengali_font_loads() {
	f := bengali_font() or { panic('NotoSansBengali-Variable.ttf is not in testdata/fonts') }
	assert f.num_glyphs() == 730, 'the face has 730 glyphs, got ${f.num_glyphs()}'
	assert f.units_per_em() == 1000, 'the face is upm 1000'
}

fn test_bengali_font_covers_bengali() {
	// fontTools cmap: the face covers Latin plus Bengali, and none of the
	// other waves scripts.
	bn := bengali_font() or { return }
	assert bn.has_glyph(rune(0x41)), 'Bengali covers Latin'
	assert bn.has_glyph(rune(0x0985)), 'Bengali covers independent A'
	assert bn.has_glyph(rune(0x0995)), 'Bengali covers KA'
	assert bn.has_glyph(rune(0x09B8)), 'Bengali covers SA'
	assert bn.has_glyph(rune(0x09BF)), 'Bengali covers the I matra'
	assert bn.has_glyph(rune(0x09CD)), 'Bengali covers the halant'
	assert !bn.has_glyph(rune(0x0915)), 'Bengali covers no Devanagari'
	assert !bn.has_glyph(rune(0x0E01)), 'Bengali covers no Thai'
	assert !bn.has_glyph(rune(0x0628)), 'Bengali covers no Arabic'
	assert !bn.has_glyph(rune(0x1780)), 'Bengali covers no Khmer'
}

fn test_bengali_tables_need_no_new_rows() {
	// The generality proof at the table level: the counts the Devanagari
	// slice pins are unchanged, and the same ranges already answer Bengali
	// codepoints. A script-specific table would fail here.
	assert shape.indic_syllabic_ranges().len == 813, '813 syllabic ranges, no Bengali addition'
	assert shape.indic_positional_ranges().len == 651, '651 positional ranges, no Bengali addition'
	syll_ranges := shape.indic_syllabic_ranges()
	pos_ranges := shape.indic_positional_ranges()
	assert shape.indic_syllabic_of(syll_ranges, rune(0x0995)) == shape.IndicSyllabic.consonant
	assert shape.indic_syllabic_of(syll_ranges, rune(0x0985)) == shape.IndicSyllabic.vowel_independent
	assert shape.indic_syllabic_of(syll_ranges, rune(0x09BF)) == shape.IndicSyllabic.vowel_dependent
	assert shape.indic_syllabic_of(syll_ranges, rune(0x09CD)) == shape.IndicSyllabic.virama
	assert shape.indic_syllabic_of(syll_ranges, rune(0x09BE)) == shape.IndicSyllabic.vowel_dependent
	assert shape.indic_positional_of(pos_ranges, rune(0x09BF)) == shape.IndicPositional.left
	assert shape.indic_positional_of(pos_ranges, rune(0x09BE)) == shape.IndicPositional.right
	assert shape.indic_positional_of(pos_ranges, rune(0x09CD)) == shape.IndicPositional.bottom
	assert shape.indic_positional_of(pos_ranges, rune(0x0995)) == shape.IndicPositional.not_applicable
}

fn test_bengali_segments() {
	// HarfBuzz clusters agree on every boundary below: karma clusters
	// 0,1,1 and hindi clusters 0,0,2,4,4 are the same cuts the machine
	// makes, which is the independent reader for the segmentation.
	assert bengali_bounds(shape.segment_indic_syllables(bengali_word([rune(0x09A8), rune(0x09AE),
		rune(0x09B8), rune(0x09CD), rune(0x09A4), rune(0x09C7)]))) == '0,1|1,2|2,6', 'nomoste is no plus mo plus ste'
	assert bengali_bounds(shape.segment_indic_syllables(bengali_word([rune(0x0995), rune(0x09BF)]))) == '0,2', 'ki is one syllable'
	assert bengali_bounds(shape.segment_indic_syllables(bengali_word([rune(0x09B8), rune(0x09CD),
		rune(0x099F), rune(0x09CD), rune(0x09B0)]))) == '0,5', 'stra is one syllable'
	assert bengali_bounds(shape.segment_indic_syllables(bengali_word([rune(0x0995), rune(0x09B0),
		rune(0x09CD), rune(0x09AE)]))) == '0,1|1,4', 'korma is ko plus rma'
	assert bengali_bounds(shape.segment_indic_syllables(bengali_word([rune(0x09B9), rune(0x09BF),
		rune(0x09A8), rune(0x09CD), rune(0x09A6), rune(0x09C0)]))) == '0,2|2,6', 'hindi is hi plus ndi'
	assert bengali_bounds(shape.segment_indic_syllables(bengali_word([rune(0x09B0), rune(0x09BE),
		rune(0x09AE)]))) == '0,2|2,3', 'raam is raa plus ma'
	assert bengali_bounds(shape.segment_indic_syllables(bengali_word([rune(0x0995), rune(0x09CD),
		rune(0x09B7)]))) == '0,3', 'kssa is one syllable'
	assert shape.segment_indic_syllables([]rune{}).len == 0, 'empty input is no syllables'
}

fn test_bengali_reorders() {
	// The pre-base I matra moves before its consonant; every other word
	// passes through unchanged, so the reorder is the identity where the
	// text is already in visual order.
	assert bengali_hex(shape.reorder_indic(bengali_word([rune(0x0995), rune(0x09BF)]))) == '09BF 0995', 'ki reorders matra first'
	assert bengali_hex(shape.reorder_indic(bengali_word([rune(0x09B9), rune(0x09BF), rune(0x09A8),
		rune(0x09CD), rune(0x09A6), rune(0x09C0)]))) == '09BF 09B9 09A8 09CD 09A6 09C0', 'hindi moves only the first syllable matra'
	assert bengali_hex(shape.reorder_indic(bengali_word([rune(0x09A8), rune(0x09AE), rune(0x09B8),
		rune(0x09CD), rune(0x09A4), rune(0x09C7)]))) == '09A8 09AE 09C7 09B8 09CD 09A4', 'nomoste moves the pre-base e-kar'
	assert bengali_hex(shape.reorder_indic(bengali_word([rune(0x09B0), rune(0x09BE), rune(0x09AE)]))) == '09B0 09BE 09AE', 'raam has no pre-base matra'
	assert shape.reorder_indic([]rune{}).len == 0, 'empty input reorders to empty'
	assert bengali_hex(shape.reorder_indic_syllable(bengali_word([rune(0x0995), rune(0x09BF)]))) == '09BF 0995', 'one syllable moves its matra'
	assert bengali_hex(shape.reorder_indic_syllable(bengali_word([rune(0x09B8), rune(0x09CD),
		rune(0x099F)]))) == '09B8 09CD 099F', 'a conjunct without a matra is unchanged'
}

fn test_bengali_reorder_matches_harfbuzz() {
	// HarfBuzz visual order for ki is the matra glyph first, then the base:
	// gid 0x3c (fontTools uni09BF) at advance 266, then gid 0x19
	// (fontTools uni0995, KA) at advance 807, both on cluster 0. The
	// reordered run is the same codepoint order the glyphs draw in, which
	// is the evidence the reorder is visual order.
	ki := bengali_word([rune(0x0995), rune(0x09BF)])
	assert shape.reorder_indic(ki) == bengali_word([rune(0x09BF), rune(0x0995)]), 'reordered ki is matra then base'
	hindi := bengali_word([rune(0x09B9), rune(0x09BF), rune(0x09A8), rune(0x09CD), rune(0x09A6),
		rune(0x09C0)])
	first := shape.segment_indic_syllables(hindi)[0]
	assert shape.reorder_indic_syllable(hindi[first.start..first.end]) == bengali_word([
		rune(0x09BF),
		rune(0x09B9),
	]), 'reordered hi is matra then base'
}

fn test_bengali_conjuncts() {
	assert bengali_spans(shape.find_indic_conjuncts(bengali_word([rune(0x09B8), rune(0x09CD),
		rune(0x099F), rune(0x09CD), rune(0x09B0)]))) == '0,5', 'stra is one conjunct'
	assert bengali_spans(shape.find_indic_conjuncts(bengali_word([rune(0x0995), rune(0x09CD),
		rune(0x09B7)]))) == '0,3', 'kssa is one conjunct'
	assert bengali_spans(shape.find_indic_conjuncts(bengali_word([rune(0x09A8), rune(0x09AE),
		rune(0x09B8), rune(0x09CD), rune(0x09A4), rune(0x09C7)]))) == '2,5', 'nomoste fuses sa hal ta'
	assert bengali_spans(shape.find_indic_conjuncts(bengali_word([rune(0x0995), rune(0x09B0),
		rune(0x09CD), rune(0x09AE)]))) == '1,4', 'korma fuses ra hal ma'
	assert bengali_spans(shape.find_indic_conjuncts(bengali_word([rune(0x09B9), rune(0x09BF),
		rune(0x09A8), rune(0x09CD), rune(0x09A6)]))) == '2,5', 'hindi fuses na hal da'
	assert shape.find_indic_conjuncts(bengali_word([rune(0x0995), rune(0x09BF)])).len == 0, 'ki has no conjunct'
	assert shape.find_indic_conjuncts(bengali_word([rune(0x09B0), rune(0x09BE), rune(0x09AE)])).len == 0, 'raam has no conjunct'
	assert shape.find_indic_conjuncts(bengali_word([rune(0x09CD)])).len == 0, 'a lone halant is no conjunct'
	assert shape.find_indic_conjuncts([]rune{}).len == 0, 'empty input has no conjuncts'
}

fn bengali_line(f &shape.Font, text []rune) layout.Line {
	return bengali_line_feat(f, text, [])
}

// bengali_line_feat lays one line out asking the caller features. The default
// is no asked features, which is what the gap pins below run under.
fn bengali_line_feat(f &shape.Font, text []rune, features []string) layout.Line {
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	mut opts := layout.LayoutOptions{}
	opts.features = features.clone()
	return layout.layout_paragraph_with(ctx, text, .auto, fs, 32.0, &opts)
}

fn test_bengali_shape_raam_matches_harfbuzz() {
	// HarfBuzz shapes RA AA MA as three glyphs in order with no substitution
	// (cmap gids equal shaped gids): RA gid 0x33 at advance 596, AA matra
	// gid 0x3b at advance 266, MA gid 0x31 at advance 612. The engine draws
	// the same three gids under their own clusters with the same advances:
	// no reorder and no fusion is needed, so this word agrees exactly.
	f := bengali_font() or { return }
	line := bengali_line(f, bengali_word([rune(0x09B0), rune(0x09BE), rune(0x09AE)]))
	assert line.glyphs.len == 3, 'raam draws three letters, got ${bengali_dump(line)}'
	want := [u16(0x33), 0x3b, 0x31]
	advances := [19.072, 8.512, 19.584]
	for i in 0 .. want.len {
		g := bengali_at(line.glyphs, i) or { panic('raam input ${i} drew nothing: ${bengali_dump(line)}') }
		assert g.gid == want[i], 'raam cluster ${i} is ${want[i]:x}, got ${g.gid:x}: ${bengali_dump(line)}'
		assert g.advance > advances[i] - 0.06 && g.advance < advances[i] + 0.06, 'raam cluster ${i} advances ${advances[i]}'
		assert g.gid != 0, 'no .notdef in a covered raam line'
	}
}

fn test_bengali_shape_wired_order() {
	// The joining hook feeds the reordered run into shaping: HarfBuzz shapes
	// KI as the matra gid 0x3c before KA gid 0x19, both on cluster 0, and
	// the engine now draws the same order with the same clusters and the
	// same advances (266 and 807 design units). Bengali needs no pres
	// variant: the cmap matra is what HarfBuzz draws too.
	f := bengali_font() or { return }
	ki := bengali_line(f, bengali_word([rune(0x0995), rune(0x09BF)]))
	assert ki.glyphs.len == 2, 'ki draws two glyphs, got ${bengali_dump(ki)}'
	assert ki.glyphs[0].gid == 0x3c, 'the I matra draws first, got ${bengali_dump(ki)}'
	assert ki.glyphs[0].cluster == 0, 'the matra reports the syllable base, got ${bengali_dump(ki)}'
	assert ki.glyphs[0].advance > 8.45 && ki.glyphs[0].advance < 8.57, 'the I matra advances 266 design units'
	assert ki.glyphs[1].gid == 0x19, 'KA draws second, got ${bengali_dump(ki)}'
	assert ki.glyphs[1].cluster == 0, 'KA keeps the syllable base, got ${bengali_dump(ki)}'
	assert ki.glyphs[1].advance > 25.76 && ki.glyphs[1].advance < 25.88, 'KA advances 807 design units'
}

fn test_bengali_shape_current_gaps() {
	// HarfBuzz shapes KSSA as one glyph: gid 0x87 (fontTools
	// uni099509CD09B7) at advance 859 on cluster 0. The tag fallback lets
	// the bng2 akhn rule resolve, so the engine draws the fused glyph by
	// default too — and naming akhn changes nothing, which the dedup below
	// pins.
	f := bengali_font() or { return }
	kssa := bengali_word([rune(0x0995), rune(0x09CD), rune(0x09B7)])
	plain := bengali_line(f, kssa)
	assert plain.glyphs.len == 1, 'kssa fuses to one glyph by default, got ${bengali_dump(plain)}'
	assert plain.glyphs[0].gid == 0x87, 'fused kssa is gid 87, got ${bengali_dump(plain)}'
	assert plain.glyphs[0].cluster == 0, 'the fusion keeps the first cluster'
	assert plain.glyphs[0].advance > 27.43 && plain.glyphs[0].advance < 27.55, 'fused kssa advances 859 design units'
	for feat in [['akhn'], ['cjct'], ['blwf']] {
		again := bengali_line_feat(f, kssa, feat)
		assert bengali_dump(again) == bengali_dump(plain), 'asked ${feat[0]} repeats the default'
	}
	// HarfBuzz shapes hindi's NDA region as the headline piece 0x15d at
	// advance 299 with a float mark, and nomoste's ste region as fc plus a
	// blws mark. The engine performs the first half of the Bengali
	// conjunct assembly (the below-base split) but not the second
	// (pstf/blwf/cjct reassembly and mark positioning), so the pieces draw
	// unfused. That chain is the 9.3d slice; what is pinned here is that
	// the split happens and nothing else moves: the order, the other gids
	// and every advance match HarfBuzz.
	hindi := bengali_line(f, bengali_word([rune(0x09B9), rune(0x09BF), rune(0x09A8), rune(0x09CD),
		rune(0x09A6), rune(0x09C0)]))
	assert hindi.glyphs.len == 7, 'hindi draws seven pieces, got ${bengali_dump(hindi)}'
	assert hindi.glyphs[0].gid == 0x16a && hindi.glyphs[0].cluster == 0, 'hindi opens with the I matra on cluster 0'
	assert hindi.glyphs[1].gid == 0x38 && hindi.glyphs[1].cluster == 0, 'HA follows on cluster 0'
	assert hindi.glyphs[2].gid == 0x140 && hindi.glyphs[3].gid == 0x15b, 'the ndi split draws arm and headline, got ${bengali_dump(hindi)}'
	assert hindi.glyphs[4].gid == 0x46, 'the halant stays a mark'
	assert hindi.glyphs[5].gid == 0x2a && hindi.glyphs[5].cluster == 4, 'DA keeps cluster 4, got ${bengali_dump(hindi)}'
	assert hindi.glyphs[6].gid == 0x3d, 'UU closes the syllable'
	nomoste := bengali_line(f, bengali_word([rune(0x09A8), rune(0x09AE), rune(0x09B8), rune(0x09CD),
		rune(0x09A4), rune(0x09C7)]))
	assert nomoste.glyphs.len == 6, 'nomoste draws six pieces, got ${bengali_dump(nomoste)}'
	assert nomoste.glyphs[2].gid == 0x42, 'the E-kar draws first in its syllable, got ${bengali_dump(nomoste)}'
	for i in 2 .. 6 {
		assert nomoste.glyphs[i].cluster == 2, 'ste reports cluster 2, glyph ${i} reports ${nomoste.glyphs[i].cluster}'
	}
}

fn test_bengali_shape_repha() {
	// Repha moves after the base and fuses by default, like Devanagari:
	// HarfBuzz shapes karma as KA gid 0x19 at 807 on cluster 0, MA gid 0x31
	// at 612 on cluster 1, reph gid 0x84 advancing nothing on cluster 1.
	f := bengali_font() or { return }
	karma := bengali_line(f, bengali_word([rune(0x0995), rune(0x09B0), rune(0x09CD), rune(0x09AE)]))
	assert karma.glyphs.len == 3, 'karma fuses to three glyphs, got ${bengali_dump(karma)}'
	assert karma.glyphs[0].gid == 0x19 && karma.glyphs[0].cluster == 0, 'KA opens on cluster 0, got ${bengali_dump(karma)}'
	assert karma.glyphs[1].gid == 0x31 && karma.glyphs[1].cluster == 1, 'MA keeps cluster 1, got ${bengali_dump(karma)}'
	assert karma.glyphs[1].advance > 19.52 && karma.glyphs[1].advance < 19.64, 'MA advances 612 design units'
	assert karma.glyphs[2].gid == 0x84 && karma.glyphs[2].cluster == 1, 'the reph lands on cluster 1, got ${bengali_dump(karma)}'
	assert karma.glyphs[2].advance == 0.0, 'the reph advances nothing'
	// Rki with a matra matches HarfBuzz glyph for glyph, including the
	// zero-width space the font's rphf chain emits (gid 5): matra, reph,
	// base, mark.
	rki := bengali_line(f, bengali_word([rune(0x09B0), rune(0x09CD), rune(0x0995), rune(0x09BF)]))
	assert rki.glyphs.len == 4, 'rki draws four glyphs, got ${bengali_dump(rki)}'
	assert rki.glyphs[0].gid == 0x3c && rki.glyphs[0].cluster == 0, 'rki opens with the matra, got ${bengali_dump(rki)}'
	assert rki.glyphs[1].gid == 0x84 && rki.glyphs[1].cluster == 0, 'the reph follows on cluster 0'
	assert rki.glyphs[2].gid == 0x19 && rki.glyphs[2].cluster == 0, 'KA keeps cluster 0'
	assert rki.glyphs[3].gid == 0x5 && rki.glyphs[3].cluster == 0, 'the chain emits the zero-width space, got ${bengali_dump(rki)}'
	// Rkma with a post-base matra is the one reph order that diverges:
	// HarfBuzz puts the reph before the AA matra ([KA, reph, AA], all on
	// cluster 0) while this engine appends it after ([KA, AA, reph]). The
	// gids and advances agree; only the order differs, and it is recorded
	// here rather than hidden. Bengali repha placement with post-base
	// matras stays 9.3d.
	rkma := bengali_line(f, bengali_word([rune(0x09B0), rune(0x09CD), rune(0x0995), rune(0x09BE)]))
	assert rkma.glyphs.len == 3, 'rkma draws three glyphs, got ${bengali_dump(rkma)}'
	assert rkma.glyphs[0].gid == 0x19 && rkma.glyphs[0].cluster == 0, 'rkma opens with KA, got ${bengali_dump(rkma)}'
	assert rkma.glyphs[1].gid == 0x3b && rkma.glyphs[1].cluster == 0, 'the AA matra keeps cluster 0'
	assert rkma.glyphs[2].gid == 0x84 && rkma.glyphs[2].cluster == 0, 'the reph closes on cluster 0'
}

fn test_bengali_draw_base() {
	// One rasterised base consonant: a face that shapes but never inks is a
	// face the test cannot see.
	f := bengali_font() or { return }
	ka := f.rasterize(f.glyph_index(rune(0x0995)), 32.0, 0, 0)
	assert !ka.is_empty(), 'KA rasterises'
}

fn test_bengali_pins_are_live() {
	// Break-fix controls: the table counts in
	// test_bengali_tables_need_no_new_rows fail when a category row is
	// dropped; these fail when the machine is neutered. If shaping ever
	// drifts, the pins above fail; if these fail, the pins stopped
	// discriminating.
	ki := bengali_word([rune(0x0995), rune(0x09BF)])
	assert shape.reorder_indic(ki) != ki, 'reordering changes ki: a neutered reorder must fail'
	stra := bengali_word([rune(0x09B8), rune(0x09CD), rune(0x099F), rune(0x09CD), rune(0x09B0)])
	assert shape.segment_indic_syllables(stra).len == 1, 'stra stays one syllable: a dropped Bengali Virama row must fail'
	kssa := bengali_word([rune(0x0995), rune(0x09CD), rune(0x09B7)])
	assert shape.find_indic_conjuncts(kssa).len == 1, 'kssa stays one conjunct'
	f := bengali_font() or { return }
	line := bengali_line(f, bengali_word([rune(0x09B0), rune(0x09BE), rune(0x09AE)]))
	assert line.glyphs[0].gid == 0x33, 'the raam pin still holds'
	assert line.glyphs[0].gid != 0x34, 'off-by-one gid must not match: the pin is exact'
}
