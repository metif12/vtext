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
	// HarfBuzz shapes hindi's NDA region as the conjunct 0x15d at advance
	// 299, DA 0x2a at 553, the blws mark 0x144 at (-827, -24) and UU 0x3d
	// at 266: the conjunct assembly fuses na, hal, da (cjct through nested
	// ligatures, cjct before the matra-positioning group so pres sees its
	// product) and the UU tail reports its own input where HarfBuzz merges
	// it onto the base cluster. Six glyphs, every gid, advance, offset and
	// cluster HB-exact but the tail.
	hindi := bengali_line(f, bengali_word([rune(0x09B9), rune(0x09BF), rune(0x09A8), rune(0x09CD),
		rune(0x09A6), rune(0x09C0)]))
	assert hindi.glyphs.len == 6, 'hindi draws six pieces, got ${bengali_dump(hindi)}'
	assert hindi.glyphs[0].gid == 0x16a && hindi.glyphs[0].cluster == 0, 'hindi opens with the I matra on cluster 0'
	assert hindi.glyphs[1].gid == 0x38 && hindi.glyphs[1].cluster == 0, 'HA follows on cluster 0'
	assert hindi.glyphs[2].gid == 0x15d && hindi.glyphs[2].cluster == 2, 'the NDA conjunct keeps cluster 2, got ${bengali_dump(hindi)}'
	assert hindi.glyphs[2].advance > 9.51 && hindi.glyphs[2].advance < 9.63, 'the conjunct advances 299 design units'
	assert hindi.glyphs[3].gid == 0x2a && hindi.glyphs[3].cluster == 4, 'DA keeps cluster 4, got ${bengali_dump(hindi)}'
	assert hindi.glyphs[3].advance > 17.64 && hindi.glyphs[3].advance < 17.76, 'DA advances 553 design units'
	assert hindi.glyphs[4].gid == 0x144 && hindi.glyphs[4].cluster == 4, 'the mark keeps cluster 4'
	assert hindi.glyphs[4].advance == 0.0 && hindi.glyphs[4].is_mark, 'the mark advances nothing'
	assert hindi.glyphs[4].x > 26.34 && hindi.glyphs[4].x < 26.46, 'the mark sits 827 design units off the pen, got x=${hindi.glyphs[4].x}'
	assert hindi.glyphs[4].y > 0.71 && hindi.glyphs[4].y < 0.83, 'the mark rides 24 design units up, got y=${hindi.glyphs[4].y}'
	assert hindi.glyphs[5].gid == 0x3d, 'UU closes the syllable'
	nomoste := bengali_line(f, bengali_word([rune(0x09A8), rune(0x09AE), rune(0x09B8), rune(0x09CD),
		rune(0x09A4), rune(0x09C7)]))
	assert nomoste.glyphs.len == 5, 'nomoste draws five pieces, got ${bengali_dump(nomoste)}'
	assert nomoste.glyphs[0].gid == 0x2c && nomoste.glyphs[0].cluster == 0, 'NA opens, got ${bengali_dump(nomoste)}'
	assert nomoste.glyphs[1].gid == 0x31 && nomoste.glyphs[1].cluster == 1, 'MA keeps cluster 1'
	// The E-kar is pre-base but run-medial, so it keeps the isolated form
	// and draws the cmap glyph 0x42: only a run-initial pre-base matra
	// takes `init`. HarfBuzz agrees glyph for glyph.
	assert nomoste.glyphs[2].gid == 0x42 && nomoste.glyphs[2].cluster == 2, 'the E-kar draws first in its syllable as the cmap glyph, got ${bengali_dump(nomoste)}'
	assert nomoste.glyphs[3].gid == 0xfc && nomoste.glyphs[3].cluster == 2, 'the sta conjunct keeps cluster 2'
	assert nomoste.glyphs[4].gid == 0x12f && nomoste.glyphs[4].cluster == 2, 'the flag keeps cluster 2'
	for i in 2 .. 5 {
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

fn test_bengali_zero_class_marks_attach() {
	// Bengali U+09C1 is a combining mark with combining class zero and
	// transparent joining: the old class gate read it as an invisible
	// format character and the ku matra vanished. HarfBuzz draws KA gid
	// 0x19 at 807 and the U matra gid 0x3e advancing nothing, both on
	// cluster 0, the matra offset -393 design units off the pen by the
	// font's own mark anchor. The engine draws the same gids with the same
	// advances and the same anchor — at 32 px a mark at 13.25 past a 25.82
	// advance — under the honest per-input cluster: the matra keeps cluster
	// 1 where HarfBuzz reports the base cluster 0, the known post-base
	// cluster convention this slice does not change.
	f := bengali_font() or { return }
	ku := bengali_line(f, bengali_word([rune(0x0995), rune(0x09C1)]))
	assert ku.glyphs.len == 2, 'ku draws two glyphs, got ${bengali_dump(ku)}'
	assert ku.glyphs[0].gid == 0x19 && ku.glyphs[0].cluster == 0, 'KA opens on cluster 0, got ${bengali_dump(ku)}'
	assert ku.glyphs[0].advance > 25.76 && ku.glyphs[0].advance < 25.9, 'KA advances 807 design units'
	assert ku.glyphs[1].gid == 0x3e && ku.glyphs[1].cluster == 1, 'the U matra keeps its own input (HarfBuzz reports the base cluster 0), got ${bengali_dump(ku)}'
	assert ku.glyphs[1].advance == 0.0, 'the matra advances nothing'
	assert ku.glyphs[1].is_mark, 'the matra rides as a mark'
	assert ku.glyphs[1].x > 13.2 && ku.glyphs[1].x < 13.3, 'the matra sits 393 design units off the pen, got x=${ku.glyphs[1].x}'
}

fn test_bengali_conjunct_assembly() {
	// The conjunct assembly chain is cjct fusing consonant, halant,
	// consonant through nested ligatures, then the matra-positioning group
	// splitting the product: kta fuses to the noflag conjunct 0xbe at 727
	// and pres splits off the TA flag 0x14a at zero advance, offset -654
	// design units off the pen. HarfBuzz agrees glyph for glyph, advance
	// for advance, cluster for cluster — all on cluster 0.
	f := bengali_font() or { return }
	kta := bengali_line(f, bengali_word([rune(0x0995), rune(0x09CD), rune(0x099F)]))
	assert kta.glyphs.len == 2, 'kta fuses to two glyphs, got ${bengali_dump(kta)}'
	assert kta.glyphs[0].gid == 0xbe && kta.glyphs[0].cluster == 0, 'kta opens with the conjunct, got ${bengali_dump(kta)}'
	assert kta.glyphs[0].advance > 23.2 && kta.glyphs[0].advance < 23.33, 'the conjunct advances 727 design units'
	assert kta.glyphs[1].gid == 0x14a && kta.glyphs[1].cluster == 0, 'the TA flag closes on cluster 0, got ${bengali_dump(kta)}'
	assert kta.glyphs[1].advance == 0.0 && kta.glyphs[1].is_mark, 'the flag advances nothing'
	assert kta.glyphs[1].x > 2.28 && kta.glyphs[1].x < 2.4, 'the flag sits 654 design units off the pen, got x=${kta.glyphs[1].x}'
	// nta and sta fuse the same way, with the TA flag on cluster 2 and a
	// 52-unit lift: nta draws 0xe7 at 756 with the flag at (-769, +52),
	// sta draws 0xfc at 782 with the flag at (-781, +52), both HB-exact.
	nta := bengali_line(f, bengali_word([rune(0x09A8), rune(0x09CD), rune(0x09A4)]))
	assert nta.glyphs.len == 2, 'nta fuses to two glyphs, got ${bengali_dump(nta)}'
	assert nta.glyphs[0].gid == 0xe7 && nta.glyphs[0].cluster == 0, 'nta opens with the conjunct, got ${bengali_dump(nta)}'
	assert nta.glyphs[0].advance > 24.13 && nta.glyphs[0].advance < 24.26, 'nta advances 756 design units'
	assert nta.glyphs[1].gid == 0x12f && nta.glyphs[1].cluster == 2, 'the nta flag keeps cluster 2, got ${bengali_dump(nta)}'
	assert nta.glyphs[1].x > -0.48 && nta.glyphs[1].x < -0.36, 'the nta flag sits 769 design units off the pen, got x=${nta.glyphs[1].x}'
	assert nta.glyphs[1].y < -1.6 && nta.glyphs[1].y > -1.73, 'the nta flag rides 52 design units up, got y=${nta.glyphs[1].y}'
	sta := bengali_line(f, bengali_word([rune(0x09B8), rune(0x09CD), rune(0x09A4)]))
	assert sta.glyphs.len == 2, 'sta fuses to two glyphs, got ${bengali_dump(sta)}'
	assert sta.glyphs[0].gid == 0xfc && sta.glyphs[0].cluster == 0, 'sta opens with the conjunct, got ${bengali_dump(sta)}'
	assert sta.glyphs[0].advance > 24.96 && sta.glyphs[0].advance < 25.09, 'sta advances 782 design units'
	assert sta.glyphs[1].gid == 0x12f && sta.glyphs[1].cluster == 2, 'the sta flag keeps cluster 2, got ${bengali_dump(sta)}'
	assert sta.glyphs[1].x > -0.03 && sta.glyphs[1].x < 0.09, 'the sta flag sits 781 design units off the pen, got x=${sta.glyphs[1].x}'
	// ke draws the pre-base E through the `init` joining feature: the font
	// files E to uni09C7.init (lookup 57) and HarfBuzz applies it, so the
	// engine applies joining features unmasked outside the joining scripts.
	// 0x18e advances 361 on cluster 0 beside KA at 807, all HB-exact.
	ke := bengali_line(f, bengali_word([rune(0x0995), rune(0x09C7)]))
	assert ke.glyphs.len == 2, 'ke draws two glyphs, got ${bengali_dump(ke)}'
	assert ke.glyphs[0].gid == 0x18e && ke.glyphs[0].cluster == 0, 'ke opens with the init matra, got ${bengali_dump(ke)}'
	assert ke.glyphs[0].advance > 11.49 && ke.glyphs[0].advance < 11.62, 'the matra advances 361 design units'
	assert ke.glyphs[1].gid == 0x19 && ke.glyphs[1].cluster == 0, 'KA keeps cluster 0'
	// ndda fuses all three through akhn with no matra fallout: one glyph
	// 0x96 at 758, HB-exact.
	ndda := bengali_line(f, bengali_word([rune(0x09A3), rune(0x09CD), rune(0x09A1)]))
	assert ndda.glyphs.len == 1, 'ndda fuses to one glyph, got ${bengali_dump(ndda)}'
	assert ndda.glyphs[0].gid == 0x96 && ndda.glyphs[0].cluster == 0, 'ndda is gid 96 on cluster 0'
	assert ndda.glyphs[0].advance > 24.19 && ndda.glyphs[0].advance < 24.32, 'ndda advances 758 design units'
	// kri assembles the rakar through blwf and widens its base through
	// dist: KA 0x9a advances 862 (662 hmtx plus the 200-unit dist chaining
	// single), the 0x15a rakar sits 200 design units off the pen, 0x140 at
	// -370 and 0x40 at -367, all HB-exact. The two below-marks keep their
	// own inputs where HarfBuzz merges them onto the base cluster, the
	// known post-base convention.
	kri := bengali_line(f, bengali_word([rune(0x0995), rune(0x09CD), rune(0x09B0), rune(0x09C3)]))
	assert kri.glyphs.len == 4, 'kri draws four glyphs, got ${bengali_dump(kri)}'
	assert kri.glyphs[0].gid == 0x9a && kri.glyphs[0].cluster == 0, 'kri opens with the rakar base, got ${bengali_dump(kri)}'
	assert kri.glyphs[0].advance > 27.52 && kri.glyphs[0].advance < 27.65, 'the base advances 862 design units'
	assert kri.glyphs[1].gid == 0x15a && kri.glyphs[1].cluster == 0, 'the rakar keeps cluster 0'
	assert kri.glyphs[1].advance == 0.0 && kri.glyphs[1].is_mark, 'the rakar advances nothing'
	assert kri.glyphs[1].x > 21.12 && kri.glyphs[1].x < 21.24, 'the rakar sits 200 design units off the pen, got x=${kri.glyphs[1].x}'
	assert kri.glyphs[2].gid == 0x140 && kri.glyphs[2].cluster == 1, 'the vocalic head keeps its own input (HarfBuzz reports 0), got ${bengali_dump(kri)}'
	assert kri.glyphs[2].x > 15.68 && kri.glyphs[2].x < 15.81, 'the head sits 370 design units off the pen, got x=${kri.glyphs[2].x}'
	assert kri.glyphs[3].gid == 0x40 && kri.glyphs[3].cluster == 3, 'the vocalic tail keeps its own input (HarfBuzz reports 0), got ${bengali_dump(kri)}'
	assert kri.glyphs[3].x > 15.78 && kri.glyphs[3].x < 15.9, 'the tail sits 367 design units off the pen, got x=${kri.glyphs[3].x}'
	// stra fuses both conjuncts: the blwf rakar feeds the second fusion,
	// and HarfBuzz agrees glyph for glyph — 0xfd at 623, 0x108 at 260, the
	// 0x149 flag at -541 and 0x11a at (-595, -134). The 0x11a keeps its own
	// input where HarfBuzz merges it onto cluster 2, the known post-base
	// convention; everything else is exact.
	stra := bengali_line(f, bengali_word([rune(0x09B8), rune(0x09CD), rune(0x099F), rune(0x09CD),
		rune(0x09B0)]))
	assert stra.glyphs.len == 4, 'stra fuses to four glyphs, got ${bengali_dump(stra)}'
	assert stra.glyphs[0].gid == 0xfd && stra.glyphs[0].cluster == 0, 'stra opens with the ssa conjunct, got ${bengali_dump(stra)}'
	assert stra.glyphs[0].advance > 19.87 && stra.glyphs[0].advance < 20.0, 'the conjunct advances 623 design units'
	assert stra.glyphs[1].gid == 0x108 && stra.glyphs[1].cluster == 2, 'the tra keeps cluster 2'
	assert stra.glyphs[1].advance > 8.26 && stra.glyphs[1].advance < 8.39, 'the tra advances 260 design units'
	assert stra.glyphs[2].gid == 0x149 && stra.glyphs[2].cluster == 2, 'the flag keeps cluster 2'
	assert stra.glyphs[2].advance == 0.0 && stra.glyphs[2].is_mark, 'the flag advances nothing'
	assert stra.glyphs[2].x > 10.88 && stra.glyphs[2].x < 11.0, 'the flag sits 541 design units off the pen, got x=${stra.glyphs[2].x}'
	assert stra.glyphs[3].gid == 0x11a && stra.glyphs[3].cluster == 3, 'the rakar keeps its own input (HarfBuzz reports 2), got ${bengali_dump(stra)}'
	assert stra.glyphs[3].advance == 0.0, 'the rakar advances nothing'
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
