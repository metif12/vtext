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
//   - the conjunct assembly chain runs by default in the order the font
//     needs: blwf, pstf and vatu ahead of cjct, pres after them. kya fuses
//     through the bng2 pstf rule, the JA stack through vatu, kta/nta/sta
//     through cjct with the pres flag split, kri/stra through the blwf
//     rakar with the dist widening. Every gid, advance, offset and cluster
//     below is HarfBuzz-exact but the post-base tails, which keep their own
//     input where HarfBuzz merges them onto the base cluster — the known
//     post-base convention this slice does not change.
//   - GPOS marks land by anchor, by stacking, and by chain: a below-base
//     matra on a conjunct stacks on the conjunct's own mark (the under-mark
//     places first), a candrabindu over a matra-carrying base reads the
//     chain alone when no anchor names it, and the HA pair widens through
//     the dist chain the mark filter selects. Single-subst tables read
//     coverage-first with a transposed fallback the buffer fit settles, so
//     the pres singles land on their variant instead of past the font.
//   - the one reph order that diverges: rkma with a post-base matra draws
//     [KA, AA, reph] where HarfBuzz draws [KA, reph, AA]. The gids and
//     advances agree; only the order differs, and it is recorded here
//     rather than hidden.

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

fn test_bengali_shape_pstf() {
	// Post-base YA fuses through pstf by default: HarfBuzz shapes kya as KA
	// gid 0x19 at 807 and the ya-pstf gid 0x85 at 270, both on cluster 0.
	// The engine draws the same gids with the same advances; the pstf mark
	// keeps its own input where HarfBuzz merges it onto the base cluster,
	// the known post-base convention. Without pstf in the defaults the pair
	// unfolds to KA plus the halant plus YA, which is the neuter this pin
	// fails.
	f := bengali_font() or { return }
	kya := bengali_line(f, bengali_word([rune(0x0995), rune(0x09CD), rune(0x09AF)]))
	assert kya.glyphs.len == 2, 'kya fuses to two glyphs, got ${bengali_dump(kya)}'
	assert kya.glyphs[0].gid == 0x19 && kya.glyphs[0].cluster == 0, 'kya opens with KA, got ${bengali_dump(kya)}'
	assert kya.glyphs[0].advance > 25.76 && kya.glyphs[0].advance < 25.88, 'KA advances 807 design units'
	assert kya.glyphs[1].gid == 0x85 && kya.glyphs[1].cluster == 1, 'the ya-pstf keeps the halant input (HarfBuzz reports 0), got ${bengali_dump(kya)}'
	assert kya.glyphs[1].advance > 8.58 && kya.glyphs[1].advance < 8.7, 'the ya-pstf advances 270 design units'
	assert kya.glyphs[1].advance != 0.0, 'the pstf form is spacing, not a mark'
	assert kya.glyphs[1].gid != 0x86 && kya.glyphs[1].gid != 0x84, 'off-by-one gid must not match: the pin is exact'
	// The same fusion feeds the other dentals: dya draws DA 0x2a at 553
	// with the same ya-pstf at 270, both HB-exact but the tail cluster.
	dya := bengali_line(f, bengali_word([rune(0x09A6), rune(0x09CD), rune(0x09AF)]))
	assert dya.glyphs.len == 2, 'dya fuses to two glyphs, got ${bengali_dump(dya)}'
	assert dya.glyphs[0].gid == 0x2a && dya.glyphs[0].cluster == 0, 'dya opens with DA, got ${bengali_dump(dya)}'
	assert dya.glyphs[0].advance > 17.64 && dya.glyphs[0].advance < 17.76, 'DA advances 553 design units'
	assert dya.glyphs[1].gid == 0x85 && dya.glyphs[1].cluster == 1, 'the ya-pstf keeps the halant input, got ${bengali_dump(dya)}'
	// A pre-base matra reorders ahead of the fusion: kyi draws the I matra
	// 0x3c at 266, KA at 807 and the ya-pstf at 270, all on cluster 0 the
	// way HarfBuzz merges the reordered syllable.
	kyi := bengali_line(f, bengali_word([rune(0x0995), rune(0x09CD), rune(0x09AF), rune(0x09BF)]))
	assert kyi.glyphs.len == 3, 'kyi draws three glyphs, got ${bengali_dump(kyi)}'
	assert kyi.glyphs[0].gid == 0x3c && kyi.glyphs[0].cluster == 0, 'kyi opens with the I matra, got ${bengali_dump(kyi)}'
	assert kyi.glyphs[1].gid == 0x19 && kyi.glyphs[1].cluster == 0, 'KA keeps cluster 0'
	assert kyi.glyphs[2].gid == 0x85 && kyi.glyphs[2].cluster == 0, 'the ya-pstf keeps cluster 0, got ${bengali_dump(kyi)}'
	assert kyi.glyphs[2].advance > 8.58 && kyi.glyphs[2].advance < 8.7, 'the ya-pstf advances 270 design units'
}

fn test_bengali_shape_vatu() {
	// The JA stack fuses through vatu by default: HarfBuzz shapes JA hal JA
	// hal BA as the single gid 0x8e at 1169 on cluster 0. vatu runs after
	// blwf, whose baphalabeng product its ligature consumes, and before
	// cjct, which would otherwise fuse the JAs to 0x8d first and starve it.
	// A cjct-first order draws [0x8d, 0x127] where HarfBuzz draws one glyph,
	// which is the neuter this pin fails.
	f := bengali_font() or { return }
	jjb := bengali_line(f, bengali_word([rune(0x099C), rune(0x09CD), rune(0x099C), rune(0x09CD),
		rune(0x09AC)]))
	assert jjb.glyphs.len == 1, 'the JA stack fuses to one glyph, got ${bengali_dump(jjb)}'
	assert jjb.glyphs[0].gid == 0x8e && jjb.glyphs[0].cluster == 0, 'the stack is gid 8e on cluster 0, got ${bengali_dump(jjb)}'
	assert jjb.glyphs[0].advance > 37.35 && jjb.glyphs[0].advance < 37.47, 'the stack advances 1169 design units'
	assert jjb.glyphs[0].gid != 0x8d && jjb.glyphs[0].gid != 0x8f, 'off-by-one gid must not match: the pin is exact'
}

fn test_bengali_shape_tra() {
	// TTA hal RA assembles through half, blwf and pres: HarfBuzz draws the
	// half form 0xd9 at 552, the flag 0x149 at -541 and the rakar alt
	// 0x11d at (-548, -134). The flag keeps its syllable base while the
	// rakar keeps its own input where HarfBuzz merges it onto cluster 0,
	// the known post-base convention. The pres single naming the rakar alt
	// is the SingleSubst reader pin: a coverage-last reading parses its
	// count out of the coverage and turns the rakar into gid 12033, which
	// this fails.
	f := bengali_font() or { return }
	tra := bengali_line(f, bengali_word([rune(0x099F), rune(0x09CD), rune(0x09B0)]))
	assert tra.glyphs.len == 3, 'tra assembles to three glyphs, got ${bengali_dump(tra)}'
	assert tra.glyphs[0].gid == 0xd9 && tra.glyphs[0].cluster == 0, 'tra opens with the half form, got ${bengali_dump(tra)}'
	assert tra.glyphs[0].advance > 17.6 && tra.glyphs[0].advance < 17.72, 'the half form advances 552 design units'
	assert tra.glyphs[1].gid == 0x149 && tra.glyphs[1].cluster == 0, 'the flag keeps cluster 0, got ${bengali_dump(tra)}'
	assert tra.glyphs[1].advance == 0.0 && tra.glyphs[1].is_mark, 'the flag advances nothing'
	assert tra.glyphs[1].x > 0.29 && tra.glyphs[1].x < 0.41, 'the flag sits 541 design units off the pen, got x=${tra.glyphs[1].x}'
	assert tra.glyphs[2].gid == 0x11d && tra.glyphs[2].cluster == 1, 'the rakar keeps the halant input (HarfBuzz reports 0), got ${bengali_dump(tra)}'
	assert tra.glyphs[2].advance == 0.0 && tra.glyphs[2].is_mark, 'the rakar advances nothing'
	assert tra.glyphs[2].x > 0.07 && tra.glyphs[2].x < 0.19, 'the rakar sits 548 design units off the pen, got x=${tra.glyphs[2].x}'
	assert tra.glyphs[2].y > 4.23 && tra.glyphs[2].y < 4.35, 'the rakar rides 134 design units up, got y=${tra.glyphs[2].y}'
	assert tra.glyphs[2].gid != 0x11c && tra.glyphs[2].gid != 0x11e, 'off-by-one gid must not match: the pin is exact'
}

fn test_bengali_shape_marks() {
	// A below-base matra on a conjunct stacks on the conjunct's own mark:
	// HarfBuzz draws tra plus the U-matra 0x3e at (372, 110) — the pen plus
	// the blwm chain, which is also what stacking on the placed rakar
	// through mkmk sums to. The under-mark places first; a pen-measured
	// stack parks the matra at 26.11 instead of 11.90, which is the neuter
	// this pin fails.
	f := bengali_font() or { return }
	tra_u := bengali_line(f, bengali_word([rune(0x099F), rune(0x09CD), rune(0x09B0), rune(0x09C1)]))
	assert tra_u.glyphs.len == 4, 'tra plus U draws four glyphs, got ${bengali_dump(tra_u)}'
	assert tra_u.glyphs[3].gid == 0x3e && tra_u.glyphs[3].cluster == 3, 'the U matra keeps its own input (HarfBuzz reports 0), got ${bengali_dump(tra_u)}'
	assert tra_u.glyphs[3].advance == 0.0 && tra_u.glyphs[3].is_mark, 'the matra advances nothing'
	assert tra_u.glyphs[3].x > 11.84 && tra_u.glyphs[3].x < 11.96, 'the matra sits 372 design units off the pen, got x=${tra_u.glyphs[3].x}'
	assert tra_u.glyphs[3].y > 4.23 && tra_u.glyphs[3].y < 4.35, 'the matra rides 134 design units up, got y=${tra_u.glyphs[3].y}'
	// The same stack on the dva conjunct: 0xe2 at 531, the blws mark
	// 0x12b at (-434, 20) and the U-matra at (382, 110), all HB-exact but
	// the honest clusters.
	dva_u := bengali_line(f, bengali_word([rune(0x09A6), rune(0x09CD), rune(0x09AC), rune(0x09C1)]))
	assert dva_u.glyphs.len == 3, 'dva plus U draws three glyphs, got ${bengali_dump(dva_u)}'
	assert dva_u.glyphs[0].gid == 0xe2 && dva_u.glyphs[0].cluster == 0, 'dva opens with the conjunct, got ${bengali_dump(dva_u)}'
	assert dva_u.glyphs[0].advance > 16.93 && dva_u.glyphs[0].advance < 17.05, 'the conjunct advances 531 design units'
	assert dva_u.glyphs[1].gid == 0x12b && dva_u.glyphs[1].cluster == 1, 'the mark keeps cluster 1, got ${bengali_dump(dva_u)}'
	assert dva_u.glyphs[1].x > 3.04 && dva_u.glyphs[1].x < 3.16, 'the mark sits 434 design units off the pen, got x=${dva_u.glyphs[1].x}'
	assert dva_u.glyphs[1].y > -0.7 && dva_u.glyphs[1].y < -0.58, 'the mark rides 20 design units down, got y=${dva_u.glyphs[1].y}'
	assert dva_u.glyphs[2].gid == 0x3e && dva_u.glyphs[2].cluster == 3, 'the U matra keeps its own input (HarfBuzz reports 0), got ${bengali_dump(dva_u)}'
	assert dva_u.glyphs[2].x > 12.16 && dva_u.glyphs[2].x < 12.28, 'the matra sits 382 design units off the pen, got x=${dva_u.glyphs[2].x}'
	assert dva_u.glyphs[2].y > 3.46 && dva_u.glyphs[2].y < 3.58, 'the matra rides 110 design units up, got y=${dva_u.glyphs[2].y}'
	// The candrabindu over a matra-carrying base reads the abvm chain
	// alone: HarfBuzz draws KA, the I-matra 0x3c at 266, the candrabindu
	// 0x15e at (446, 35) and KA at 807, with the zero-width space the
	// chain emits. No anchor names the pair; a chain-blind engine leaves
	// the mark at the pen (8.51, 0), which is the neuter this pin fails.
	ku_candra := bengali_line(f, bengali_word([rune(0x0995), rune(0x09BF), rune(0x0981)]))
	assert ku_candra.glyphs.len == 4, 'ki plus candrabindu draws four glyphs, got ${bengali_dump(ku_candra)}'
	assert ku_candra.glyphs[0].gid == 0x3c && ku_candra.glyphs[0].cluster == 0, 'the I matra opens on cluster 0, got ${bengali_dump(ku_candra)}'
	assert ku_candra.glyphs[1].gid == 0x15e && ku_candra.glyphs[1].cluster == 0, 'the candrabindu keeps cluster 0, got ${bengali_dump(ku_candra)}'
	assert ku_candra.glyphs[1].advance == 0.0 && ku_candra.glyphs[1].is_mark, 'the candrabindu advances nothing'
	assert ku_candra.glyphs[1].x > 22.72 && ku_candra.glyphs[1].x < 22.84, 'the mark sits 446 design units off the pen, got x=${ku_candra.glyphs[1].x}'
	assert ku_candra.glyphs[1].y > -1.18 && ku_candra.glyphs[1].y < -1.06, 'the mark rides 35 design units up, got y=${ku_candra.glyphs[1].y}'
	assert ku_candra.glyphs[2].gid == 0x19 && ku_candra.glyphs[2].cluster == 0, 'KA keeps cluster 0'
	assert ku_candra.glyphs[3].gid == 0x5, 'the chain emits the zero-width space, got ${bengali_dump(ku_candra)}'
	// The candrabindu on the kta conjunct stacks on the placed flag: 0xbe
	// at 727, the flag 0x14a at -654 and 0x15f at (369, 16) off the flag,
	// HB-exact. Stacking on the nearer rakar, which has no rule for the
	// mark, parks it at 8.0 instead of 10.56, which is the neuter this pin
	// fails.
	kta_candra := bengali_line(f, bengali_word([rune(0x0995), rune(0x09CD), rune(0x099F), rune(0x0981)]))
	assert kta_candra.glyphs.len == 3, 'kta plus candrabindu draws three glyphs, got ${bengali_dump(kta_candra)}'
	assert kta_candra.glyphs[0].gid == 0xbe && kta_candra.glyphs[0].cluster == 0, 'kta opens with the conjunct, got ${bengali_dump(kta_candra)}'
	assert kta_candra.glyphs[1].gid == 0x14a && kta_candra.glyphs[1].cluster == 0, 'the flag keeps cluster 0'
	assert kta_candra.glyphs[2].gid == 0x15f && kta_candra.glyphs[2].cluster == 3, 'the candrabindu keeps its own input (HarfBuzz reports 0), got ${bengali_dump(kta_candra)}'
	assert kta_candra.glyphs[2].advance == 0.0 && kta_candra.glyphs[2].is_mark, 'the candrabindu advances nothing'
	assert kta_candra.glyphs[2].x > 14.08 && kta_candra.glyphs[2].x < 14.22, 'the mark stacks 369 design units off the flag, got x=${kta_candra.glyphs[2].x}'
	assert kta_candra.glyphs[2].y > -0.57 && kta_candra.glyphs[2].y < -0.45, 'the mark rides 16 design units up, got y=${kta_candra.glyphs[2].y}'
	// The candrabindu on the tra conjunct stacks on the placed flag, not on
	// the nearer rakar: 0xd9 at 552, the flag 0x149 at -541, the rakar
	// 0x11d at (-548, -134) and 0x15f at (330, 16) off the flag, HB-exact.
	// The rakar has no rule for the mark, so a nearest-only stack parks it
	// at 8.0 instead of 10.56, which is the neuter this pin fails.
	tra_candra := bengali_line(f, bengali_word([rune(0x099F), rune(0x09CD), rune(0x09B0), rune(0x0981)]))
	assert tra_candra.glyphs.len == 4, 'tra plus candrabindu draws four glyphs, got ${bengali_dump(tra_candra)}'
	assert tra_candra.glyphs[0].gid == 0xd9 && tra_candra.glyphs[0].cluster == 0, 'tra opens with the half form, got ${bengali_dump(tra_candra)}'
	assert tra_candra.glyphs[1].gid == 0x149 && tra_candra.glyphs[1].cluster == 0, 'the flag keeps cluster 0'
	assert tra_candra.glyphs[2].gid == 0x11d && tra_candra.glyphs[2].cluster == 1, 'the rakar keeps the halant input (HarfBuzz reports 0), got ${bengali_dump(tra_candra)}'
	assert tra_candra.glyphs[3].gid == 0x15f && tra_candra.glyphs[3].cluster == 3, 'the candrabindu keeps its own input (HarfBuzz reports 0), got ${bengali_dump(tra_candra)}'
	assert tra_candra.glyphs[3].advance == 0.0 && tra_candra.glyphs[3].is_mark, 'the candrabindu advances nothing'
	assert tra_candra.glyphs[3].x > 10.5 && tra_candra.glyphs[3].x < 10.62, 'the mark stacks 319 design units off the flag, got x=${tra_candra.glyphs[3].x}'
	assert tra_candra.glyphs[3].y > -0.57 && tra_candra.glyphs[3].y < -0.45, 'the mark rides 16 design units up, got y=${tra_candra.glyphs[3].y}'
	// The O-kar on the kta conjunct takes the tie-break base: the E-kar
	// 0x18e at 361, the conjunct at 727, the flag at 73 design units off
	// the conjunct (not off the AA after it) and the spacing AA at 266.
	// Last-base-wins hands the flag to the AA, which has no anchor for it,
	// and the flag stays at the pen, which is the neuter this pin fails.
	kta_o := bengali_line(f, bengali_word([rune(0x0995), rune(0x09CD), rune(0x099F), rune(0x09CB)]))
	assert kta_o.glyphs.len == 4, 'kta plus O draws four glyphs, got ${bengali_dump(kta_o)}'
	assert kta_o.glyphs[0].gid == 0x18e && kta_o.glyphs[0].cluster == 0, 'the E-kar opens on cluster 0, got ${bengali_dump(kta_o)}'
	assert kta_o.glyphs[0].advance > 11.49 && kta_o.glyphs[0].advance < 11.61, 'the E-kar advances 361 design units'
	assert kta_o.glyphs[1].gid == 0xbe && kta_o.glyphs[1].cluster == 0, 'the conjunct keeps cluster 0'
	assert kta_o.glyphs[2].gid == 0x14a && kta_o.glyphs[2].cluster == 0, 'the flag keeps cluster 0, got ${bengali_dump(kta_o)}'
	assert kta_o.glyphs[2].advance == 0.0 && kta_o.glyphs[2].is_mark, 'the flag advances nothing'
	assert kta_o.glyphs[2].x > 13.83 && kta_o.glyphs[2].x < 13.95, 'the flag sits 73 design units off the conjunct, got x=${kta_o.glyphs[2].x}'
	assert kta_o.glyphs[3].gid == 0x3b && kta_o.glyphs[3].cluster == 0, 'the AA matra closes on cluster 0'
	assert kta_o.glyphs[3].advance > 8.45 && kta_o.glyphs[3].advance < 8.57, 'the AA matra advances 266 design units'
	assert !kta_o.glyphs[3].is_mark, 'the AA matra is spacing, got ${bengali_dump(kta_o)}'
	// The reph takes the tie-break base too: rki with a matra draws the
	// pres matra 0x3c at 266, the reph 0x84 at (690, -3) off the matra
	// ahead of it, KA at 807 and the zero-width space, all HB-exact.
	// Last-base-wins hands the reph to KA, whose anchor reads (446, 0),
	// which is the neuter this pin fails.
	rki_chain := bengali_line(f, bengali_word([rune(0x09B0), rune(0x09CD), rune(0x0995), rune(0x09BF)]))
	assert rki_chain.glyphs.len == 4, 'rki draws four glyphs, got ${bengali_dump(rki_chain)}'
	assert rki_chain.glyphs[0].gid == 0x3c && rki_chain.glyphs[0].cluster == 0, 'the matra opens on cluster 0, got ${bengali_dump(rki_chain)}'
	assert rki_chain.glyphs[1].gid == 0x84 && rki_chain.glyphs[1].cluster == 0, 'the reph keeps cluster 0'
	assert rki_chain.glyphs[1].advance == 0.0 && rki_chain.glyphs[1].is_mark, 'the reph advances nothing'
	assert rki_chain.glyphs[1].x > 22.02 && rki_chain.glyphs[1].x < 22.14, 'the reph sits 690 design units off the matra, got x=${rki_chain.glyphs[1].x}'
	assert rki_chain.glyphs[1].y > 0.04 && rki_chain.glyphs[1].y < 0.16, 'the reph rides 3 design units down, got y=${rki_chain.glyphs[1].y}'
	assert rki_chain.glyphs[2].gid == 0x19 && rki_chain.glyphs[2].cluster == 0, 'KA keeps cluster 0'
	assert rki_chain.glyphs[3].gid == 0x5, 'the chain emits the zero-width space, got ${bengali_dump(rki_chain)}'
}

fn test_bengali_shape_spacing_marks() {
	// Some single substitutions change a mark into a spacing glyph: the
	// pres single turns the U-matra into gid 0x114, which the font
	// classifies as a base with a 194-unit advance, and HarfBuzz advances
	// it as one. A mark input staying a mark parks it at the pen with no
	// advance, which is the neuter this pin fails.
	f := bengali_font() or { return }
	ra_u := bengali_line(f, bengali_word([rune(0x09B0), rune(0x09C1)]))
	assert ra_u.glyphs.len == 2, 'ra plus U draws two glyphs, got ${bengali_dump(ra_u)}'
	assert ra_u.glyphs[0].gid == 0x33 && ra_u.glyphs[0].cluster == 0, 'RA opens on cluster 0, got ${bengali_dump(ra_u)}'
	assert ra_u.glyphs[0].advance > 19.01 && ra_u.glyphs[0].advance < 19.13, 'RA advances 596 design units'
	assert ra_u.glyphs[1].gid == 0x114 && ra_u.glyphs[1].cluster == 1, 'the variant keeps its own input (HarfBuzz reports 0), got ${bengali_dump(ra_u)}'
	assert !ra_u.glyphs[1].is_mark, 'the variant is spacing, got ${bengali_dump(ra_u)}'
	assert ra_u.glyphs[1].advance > 6.15 && ra_u.glyphs[1].advance < 6.27, 'the variant advances 194 design units'
	// The AA matra after the abvs swap is the same story: kta with AA and
	// candrabindu draws KA, the candrabindu and the spacing AA at 266, and
	// HarfBuzz agrees glyph for glyph. A mark-staying mark draws the AA at
	// the pen with no advance, which is the neuter this pin fails.
	stk := bengali_line(f, bengali_word([rune(0x0995), rune(0x09BE), rune(0x0981)]))
	assert stk.glyphs.len == 3, 'KA plus AA plus candrabindu draws three glyphs, got ${bengali_dump(stk)}'
	assert stk.glyphs[0].gid == 0x19 && stk.glyphs[0].cluster == 0, 'KA opens on cluster 0, got ${bengali_dump(stk)}'
	assert stk.glyphs[1].gid == 0xa && stk.glyphs[1].cluster == 1, 'the candrabindu keeps cluster 1 (HarfBuzz reports 0), got ${bengali_dump(stk)}'
	assert stk.glyphs[1].advance == 0.0 && stk.glyphs[1].is_mark, 'the candrabindu advances nothing'
	assert stk.glyphs[1].x > 14.21 && stk.glyphs[1].x < 14.33, 'the mark sits 446 design units off the pen, got x=${stk.glyphs[1].x}'
	assert stk.glyphs[2].gid == 0x3b && stk.glyphs[2].cluster == 2, 'the AA matra keeps its own input (HarfBuzz reports 0), got ${bengali_dump(stk)}'
	assert !stk.glyphs[2].is_mark, 'the AA matra is spacing, got ${bengali_dump(stk)}'
	assert stk.glyphs[2].advance > 8.45 && stk.glyphs[2].advance < 8.57, 'the AA matra advances 266 design units'
}

fn test_bengali_shape_dist_kern() {
	// The HA pair widens through the dist chain the mark filter selects:
	// HarfBuzz draws HA gid 0x38 at 674 (534 hmtx plus the 140-unit
	// chaining single), the vocalic mark 0x143 at (-275, 165) and the rakar
	// 0x15a at -200, with the marks on cluster 1 where the honest
	// per-input clusters keep them. A filter-blind matcher skips nothing
	// and misses the rule, leaving HA at 534, which is the neuter this pin
	// fails.
	f := bengali_font() or { return }
	ha_voc := bengali_line(f, bengali_word([rune(0x09B9), rune(0x09C3)]))
	assert ha_voc.glyphs.len == 3, 'HA plus vocalic R draws three glyphs, got ${bengali_dump(ha_voc)}'
	assert ha_voc.glyphs[0].gid == 0x38 && ha_voc.glyphs[0].cluster == 0, 'HA opens on cluster 0, got ${bengali_dump(ha_voc)}'
	assert ha_voc.glyphs[0].advance > 21.51 && ha_voc.glyphs[0].advance < 21.63, 'the dist kern leaves 674 design units'
	assert ha_voc.glyphs[1].gid == 0x143 && ha_voc.glyphs[1].cluster == 1, 'the mark keeps its own input (HarfBuzz reports 0), got ${bengali_dump(ha_voc)}'
	assert ha_voc.glyphs[1].advance == 0.0 && ha_voc.glyphs[1].is_mark, 'the mark advances nothing'
	assert ha_voc.glyphs[1].x > 12.71 && ha_voc.glyphs[1].x < 12.83, 'the mark sits 275 design units off the pen, got x=${ha_voc.glyphs[1].x}'
	assert ha_voc.glyphs[1].y > -5.34 && ha_voc.glyphs[1].y < -5.22, 'the mark rides 165 design units up, got y=${ha_voc.glyphs[1].y}'
	assert ha_voc.glyphs[2].gid == 0x15a && ha_voc.glyphs[2].cluster == 1, 'the rakar keeps cluster 1, got ${bengali_dump(ha_voc)}'
	assert ha_voc.glyphs[2].advance == 0.0 && ha_voc.glyphs[2].is_mark, 'the rakar advances nothing'
	assert ha_voc.glyphs[2].x > 15.11 && ha_voc.glyphs[2].x < 15.23, 'the rakar sits 200 design units off the pen, got x=${ha_voc.glyphs[2].x}'
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
	// The assembly chain discriminates: unfolding pstf leaves KA hal YA at
	// three glyphs, starving vatu of its blwf product leaves the JA stack
	// at two, and the coverage-last SingleSubst reading turns the tra rakar
	// into gid 12033. Each pin above fails on its neuter.
	kya := bengali_line(f, bengali_word([rune(0x0995), rune(0x09CD), rune(0x09AF)]))
	assert kya.glyphs.len == 2 && kya.glyphs[1].gid == 0x85, 'kya stays fused: a dropped pstf must fail'
	assert kya.glyphs[1].gid != 0x86, 'off-by-one gid must not match: the pin is exact'
	jjb := bengali_line(f, bengali_word([rune(0x099C), rune(0x09CD), rune(0x099C), rune(0x09CD),
		rune(0x09AC)]))
	assert jjb.glyphs.len == 1 && jjb.glyphs[0].gid == 0x8e, 'the JA stack stays fused: vatu after cjct must fail'
	tra := bengali_line(f, bengali_word([rune(0x099F), rune(0x09CD), rune(0x09B0)]))
	assert tra.glyphs.len == 3 && tra.glyphs[2].gid == 0x11d, 'tra keeps its rakar: a coverage-last single must fail'
	assert tra.glyphs[2].gid != 12033, 'the misparsed gid must not come back'
	// The placing pass discriminates: marks place under-first, so the
	// under-mark precedes the over-mark in cluster order; a last-backwards
	// order stacks the candrabindu before its flag and must fail.
	marks_line := bengali_line(f, bengali_word([rune(0x0995), rune(0x09CD), rune(0x099F), rune(0x0981)]))
	mut mark_order := []u16{}
	for mi in layout.mark_indices_by_cluster(marks_line.glyphs) {
		mark_order << marks_line.glyphs[mi].gid
	}
	assert mark_order == [u16(0x14a), u16(0x15f)], 'the flag places before the candrabindu it carries, got ${mark_order}'
}
