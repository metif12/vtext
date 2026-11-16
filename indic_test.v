module vtext

import os
import vtext.layout
import vtext.shape
import vtext.ucd

// Tests for the first Indic cut: a committed Devanagari face, the syllable
// machine beside HarfBuzz, and one conjunct fusion through the existing
// substitution path. Every gid, advance and cluster below was read off
// HarfBuzz (uharfbuzz, scale 1000 = font units, this face is upm 1000) and
// fontTools before it was written here; agreement with a second reader is
// the evidence. Input clusters double as pins: a cluster is an input
// position, so the glyph reporting cluster 2 names no engine output of its
// own.
//
// The face ships in testdata/fonts with its OFL text, so it loads on every
// platform with no skips: no host font, no platform directory.
//
// Where the engine diverges from HarfBuzz, the assert pins the current
// behaviour and the comment names the gap for the engine slice that owns
// it:
//   - pre-base matras draw first with the pres variant: the joining hook
//     feeds the reordered run into shaping, merges the syllable's clusters
//     onto its base (both on cluster 0, like HarfBuzz), and the Indic
//     default features fuse and position what needs no reordering.
//   - combining matras with joining type Transparent (E, U and friends)
//     draw nothing at all: the joining pass emits no glyph for a
//     transparent character with combining class zero, the same gap the
//     Southeast Asian and long-tail waves pin. The Mc matras (AA, I) draw
//     as spacing cmap glyphs with full advance instead.
//   - conjuncts fuse where the font fuses them without reordering: akhn
//     fuses KSSA, half fuses NDA and the STA conjunct, pres swaps the
//     matra, rphf fuses the moved reph — all by default, like HarfBuzz.
//     Pref positioning stays open: it needs a different move from repha.
//   - GPOS mark advances and offsets are the font layer: the halant reports
//     its own hmtx advance of zero and whatever offset the mark pass
//     attached, not HarfBuzz mark offsets.
//
// Khmer generality, split-matra halves, post-base and below-base assembly
// (pref, pstf, blwf, vatu), the Bengali conjunct chain and GPOS mark
// positioning stay follow-ups: Devanagari repha included, acceptance is
// this slice.

fn indic_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('VTEXT_TEST_FONTS'), 'testdata/fonts'] {
		if d != '' && d !in dirs {
			dirs << d
		}
	}
	for dir in dirs {
		p := os.join_path(dir, name)
		if os.exists(p) {
			return p
		}
	}
	return none
}

fn indic_font(name string) ?&shape.Font {
	p := indic_font_path(name) or { return none }
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

// indic_at returns the glyph that came from the input character at that
// index, or none when the character drew nothing.
fn indic_at(glyphs []shape.Glyph, cluster int) ?shape.Glyph {
	for g in glyphs {
		if g.cluster == cluster {
			return g
		}
	}
	return none
}

// indic_dump renders a line as gid:cluster:advance cells so a failing pin
// shows the whole engine answer in the message.
fn indic_dump(line layout.Line) string {
	mut parts := []string{cap: line.glyphs.len}
	for g in line.glyphs {
		parts << '${g.gid:x}:${g.cluster}:${g.advance:.2f}'
	}
	return '[' + parts.join(' ') + ']'
}

// indic_word builds a test word from codepoints, keeping this file ASCII.
fn indic_word(cps []rune) []rune {
	return cps.clone()
}

// indic_bounds renders syllables as start,end cells for one-line pins.
fn indic_bounds(syllables []shape.IndicSyllable) string {
	mut parts := []string{cap: syllables.len}
	for s in syllables {
		parts << '${s.start},${s.end}'
	}
	return parts.join('|')
}

// indic_hex renders codepoints as hex for one-line reorder pins.
fn indic_hex(cps []rune) string {
	mut parts := []string{cap: cps.len}
	for cp in cps {
		parts << '${u32(cp):04X}'
	}
	return parts.join(' ')
}

// indic_spans renders conjuncts as start,end cells for one-line pins.
fn indic_spans(conjuncts []shape.IndicConjunct) string {
	mut parts := []string{cap: conjuncts.len}
	for c in conjuncts {
		parts << '${c.start},${c.end}'
	}
	return parts.join('|')
}

fn test_indic_font_loads() {
	f := indic_font('NotoSansDevanagari-Variable.ttf') or { panic('NotoSansDevanagari-Variable.ttf is not in testdata/fonts') }
	assert f.num_glyphs() == 1117, 'the face has 1117 glyphs, got ${f.num_glyphs()}'
	assert f.units_per_em() == 1000, 'the face is upm 1000'
}

fn test_indic_font_covers_devanagari() {
	// fontTools cmap: the face covers Latin plus Devanagari, and none of
	// the other waves scripts.
	dv := indic_font('NotoSansDevanagari-Variable.ttf') or { return }
	assert dv.has_glyph(rune(0x41)), 'Devanagari covers Latin'
	assert dv.has_glyph(rune(0x0905)), 'Devanagari covers independent A'
	assert dv.has_glyph(rune(0x0915)), 'Devanagari covers KA'
	assert dv.has_glyph(rune(0x0939)), 'Devanagari covers HA'
	assert dv.has_glyph(rune(0x093F)), 'Devanagari covers the I matra'
	assert dv.has_glyph(rune(0x094D)), 'Devanagari covers the halant'
	assert !dv.has_glyph(rune(0x0E01)), 'Devanagari covers no Thai'
	assert !dv.has_glyph(rune(0x0E81)), 'Devanagari covers no Lao'
	assert !dv.has_glyph(rune(0x0628)), 'Devanagari covers no Arabic'
	assert !dv.has_glyph(rune(0x1780)), 'Devanagari covers no Khmer'
}

fn test_indic_tables_match_the_enums() {
	// The generated name tables and the hand written enums in shape/indic.v
	// are kept in step the way wordbreak_test.v does for the older tables:
	// the generator panics on a value outside its pinned order, and these
	// counts fail when a row is dropped or a value added. The lookups tie
	// representative codepoints to their categories.
	syll_names := ucd.indic_syllabic_names_data.split('\n')
	assert syll_names[syll_names.len - 1] == '', 'the names table ends on a newline'
	assert syll_names.len - 1 == 37, '37 syllabic values, got ${syll_names.len - 1}'
	assert syll_names[5] == 'Consonant', 'ordinal 5 is Consonant, got ${syll_names[5]}'
	assert syll_names[36] == 'Vowel_Independent', 'ordinal 36 is Vowel_Independent'
	pos_names := ucd.indic_positional_names_data.split('\n')
	assert pos_names[pos_names.len - 1] == '', 'the names table ends on a newline'
	assert pos_names.len - 1 == 16, '16 positional values, got ${pos_names.len - 1}'
	assert pos_names[4] == 'Left', 'ordinal 4 is Left, got ${pos_names[4]}'
	assert shape.indic_syllabic_ranges().len == 813, '813 syllabic ranges'
	assert shape.indic_positional_ranges().len == 651, '651 positional ranges'
	syll_ranges := shape.indic_syllabic_ranges()
	pos_ranges := shape.indic_positional_ranges()
	assert shape.indic_syllabic_of(syll_ranges, rune(0x0915)) == shape.IndicSyllabic.consonant
	assert shape.indic_syllabic_of(syll_ranges, rune(0x0905)) == shape.IndicSyllabic.vowel_independent
	assert shape.indic_syllabic_of(syll_ranges, rune(0x0902)) == shape.IndicSyllabic.bindu
	assert shape.indic_syllabic_of(syll_ranges, rune(0x0903)) == shape.IndicSyllabic.visarga
	assert shape.indic_syllabic_of(syll_ranges, rune(0x093E)) == shape.IndicSyllabic.vowel_dependent
	assert shape.indic_syllabic_of(syll_ranges, rune(0x094D)) == shape.IndicSyllabic.virama
	assert shape.indic_syllabic_of(syll_ranges, rune(0x200C)) == shape.IndicSyllabic.non_joiner
	assert shape.indic_syllabic_of(syll_ranges, rune(0x200D)) == shape.IndicSyllabic.joiner
	assert shape.indic_syllabic_of(syll_ranges, rune(0x0041)) == shape.IndicSyllabic.other
	assert shape.indic_positional_of(pos_ranges, rune(0x093F)) == shape.IndicPositional.left
	assert shape.indic_positional_of(pos_ranges, rune(0x093E)) == shape.IndicPositional.right
	assert shape.indic_positional_of(pos_ranges, rune(0x0941)) == shape.IndicPositional.bottom
	assert shape.indic_positional_of(pos_ranges, rune(0x094D)) == shape.IndicPositional.bottom
	assert shape.indic_positional_of(pos_ranges, rune(0x0915)) == shape.IndicPositional.not_applicable
}

fn test_indic_segments_devanagari() {
	// HarfBuzz clusters agree on every boundary below: karma clusters
	// 0,1,1 and hindi clusters 0,0,2,4,4 are the same cuts the machine
	// makes, which is the independent reader for the segmentation.
	assert indic_bounds(shape.segment_indic_syllables(indic_word([rune(0x0928), rune(0x092E),
		rune(0x0938), rune(0x094D), rune(0x0924), rune(0x0947)]))) == '0,1|1,2|2,6', 'namaste is three syllables'
	assert indic_bounds(shape.segment_indic_syllables(indic_word([rune(0x0915), rune(0x093F)]))) == '0,2', 'ki is one syllable'
	assert indic_bounds(shape.segment_indic_syllables(indic_word([rune(0x0938), rune(0x094D),
		rune(0x0924), rune(0x094D), rune(0x0930)]))) == '0,5', 'stra is one syllable'
	assert indic_bounds(shape.segment_indic_syllables(indic_word([rune(0x0915), rune(0x0930),
		rune(0x094D), rune(0x092E)]))) == '0,1|1,4', 'karma is ka plus rma'
	assert indic_bounds(shape.segment_indic_syllables(indic_word([rune(0x0939), rune(0x093F),
		rune(0x0928), rune(0x094D), rune(0x0926), rune(0x0940)]))) == '0,2|2,6', 'hindi is hi plus ndi'
	assert indic_bounds(shape.segment_indic_syllables(indic_word([rune(0x092A), rune(0x0941),
		rune(0x0938), rune(0x094D), rune(0x0924), rune(0x0915)]))) == '0,2|2,5|5,6', 'pustak is pu plus sta plus ka'
	assert indic_bounds(shape.segment_indic_syllables(indic_word([rune(0x0930), rune(0x093E),
		rune(0x092E)]))) == '0,2|2,3', 'raam is raa plus ma'
	assert indic_bounds(shape.segment_indic_syllables(indic_word([rune(0x0915), rune(0x094D),
		rune(0x0937)]))) == '0,3', 'kssa is one syllable'
	assert indic_bounds(shape.segment_indic_syllables(indic_word([rune(0x091C), rune(0x094D),
		rune(0x091E)]))) == '0,3', 'jna is one syllable'
	assert shape.segment_indic_syllables([]rune{}).len == 0, 'empty input is no syllables'
}

fn test_indic_reorders_devanagari() {
	// The pre-base I matra moves before its consonant; every other word
	// passes through unchanged, so the reorder is the identity where the
	// text is already in visual order.
	assert indic_hex(shape.reorder_indic(indic_word([rune(0x0915), rune(0x093F)]))) == '093F 0915', 'ki reorders matra first'
	assert indic_hex(shape.reorder_indic(indic_word([rune(0x0939), rune(0x093F), rune(0x0928),
		rune(0x094D), rune(0x0926), rune(0x0940)]))) == '093F 0939 0928 094D 0926 0940', 'hindi moves only the first syllable matra'
	assert indic_hex(shape.reorder_indic(indic_word([rune(0x0928), rune(0x092E), rune(0x0938),
		rune(0x094D), rune(0x0924), rune(0x0947)]))) == '0928 092E 0938 094D 0924 0947', 'namaste has no pre-base matra'
	assert indic_hex(shape.reorder_indic(indic_word([rune(0x0930), rune(0x093E), rune(0x092E)]))) == '0930 093E 092E', 'raam has no pre-base matra'
	assert indic_hex(shape.reorder_indic(indic_word([rune(0x092A), rune(0x0941), rune(0x0938),
		rune(0x094D), rune(0x0924), rune(0x0915)]))) == '092A 0941 0938 094D 0924 0915', 'pustak matras are post-base'
	assert shape.reorder_indic([]rune{}).len == 0, 'empty input reorders to empty'
	// A single syllable reorders on its own: the run version above tiles
	// this function over the segmenter cuts.
	assert indic_hex(shape.reorder_indic_syllable(indic_word([rune(0x0915), rune(0x093F)]))) == '093F 0915', 'one syllable moves its matra'
	assert indic_hex(shape.reorder_indic_syllable(indic_word([rune(0x0938), rune(0x094D), rune(0x0924)]))) == '0938 094D 0924', 'a conjunct without a matra is unchanged'
}

fn test_indic_reorder_matches_harfbuzz() {
	// HarfBuzz visual order for ki is the matra glyph first, then the base:
	// gid 545 (fontTools uni093F.04, the pres variant of the I matra) at
	// advance 259, then gid 56 (fontTools uni0915, KA) at advance 768, both
	// on cluster 0. The reordered run is the same codepoint order the
	// glyphs draw in, which is the evidence the reorder is visual order.
	ki := indic_word([rune(0x0915), rune(0x093F)])
	assert shape.reorder_indic(ki) == indic_word([rune(0x093F), rune(0x0915)]), 'reordered ki is matra then base'
	// HarfBuzz visual order for the hindi first syllable is the same shape:
	// gid 544 (fontTools uni093F.03) at advance 259, then gid 88
	// (fontTools uni0939, HA) at advance 531, both on cluster 0.
	hindi := indic_word([rune(0x0939), rune(0x093F), rune(0x0928), rune(0x094D), rune(0x0926),
		rune(0x0940)])
	first := shape.segment_indic_syllables(hindi)[0]
	assert shape.reorder_indic_syllable(hindi[first.start..first.end]) == indic_word([
		rune(0x093F),
		rune(0x0939),
	]), 'reordered hi is matra then base'
}

fn test_indic_reorder_mapped_names_sources() {
	// The layout hook shapes the reordered run but reports the caller's
	// clusters: the map answers which input index each reordered codepoint
	// came from. ki moves, so the matra names input 1 first; raam and the
	// empty run map to themselves.
	ro, m := shape.reorder_indic_mapped(indic_word([rune(0x0915), rune(0x093F)]))
	assert indic_hex(ro) == '093F 0915', 'mapped reorder still moves the matra'
	assert m == [1, 0], 'the map names the sources, got ${m}'
	plain, pm := shape.reorder_indic_mapped(indic_word([rune(0x0930), rune(0x093E), rune(0x092E)]))
	assert indic_hex(plain) == '0930 093E 092E', 'raam needs no reorder'
	assert pm == [0, 1, 2], 'the identity maps to itself, got ${pm}'
	empty_ro, empty_m := shape.reorder_indic_mapped([]rune{})
	assert empty_ro.len == 0 && empty_m.len == 0, 'empty maps to empty'
	// Repha moves after the base: karma's second syllable reorders to
	// MA, RA, halant, and the map names the sources.
	rkarma, rmap := shape.reorder_indic_mapped(indic_word([rune(0x0915), rune(0x0930), rune(0x094D),
		rune(0x092E)]))
	assert indic_hex(rkarma) == '0915 092E 0930 094D', 'karma moves its repha last, got ${indic_hex(rkarma)}'
	assert rmap == [0, 3, 1, 2], 'the map names the sources, got ${rmap}'
}

fn test_indic_conjuncts_devanagari() {
	assert indic_spans(shape.find_indic_conjuncts(indic_word([rune(0x0938), rune(0x094D), rune(0x0924),
		rune(0x094D), rune(0x0930)]))) == '0,5', 'stra is one conjunct'
	assert indic_spans(shape.find_indic_conjuncts(indic_word([rune(0x0915), rune(0x094D), rune(0x0937)]))) == '0,3', 'kssa is one conjunct'
	assert indic_spans(shape.find_indic_conjuncts(indic_word([rune(0x091C), rune(0x094D), rune(0x091E)]))) == '0,3', 'jna is one conjunct'
	assert indic_spans(shape.find_indic_conjuncts(indic_word([rune(0x0928), rune(0x092E), rune(0x0938),
		rune(0x094D), rune(0x0924), rune(0x0947)]))) == '2,5', 'namaste fuses sa hal ta'
	assert indic_spans(shape.find_indic_conjuncts(indic_word([rune(0x0915), rune(0x0930), rune(0x094D),
		rune(0x092E)]))) == '1,4', 'karma fuses ra hal ma'
	assert indic_spans(shape.find_indic_conjuncts(indic_word([rune(0x0939), rune(0x093F), rune(0x0928),
		rune(0x094D), rune(0x0926), rune(0x0940)]))) == '2,5', 'hindi fuses na hal da'
	assert indic_spans(shape.find_indic_conjuncts(indic_word([rune(0x092A), rune(0x0941), rune(0x0938),
		rune(0x094D), rune(0x0924), rune(0x0915)]))) == '2,5', 'pustak fuses sa hal ta'
	assert shape.find_indic_conjuncts(indic_word([rune(0x0915), rune(0x093F)])).len == 0, 'ki has no conjunct'
	assert shape.find_indic_conjuncts(indic_word([rune(0x0930), rune(0x093E), rune(0x092E)])).len == 0, 'raam has no conjunct'
	assert shape.find_indic_conjuncts(indic_word([rune(0x094D)])).len == 0, 'a lone halant is no conjunct'
	assert shape.find_indic_conjuncts([]rune{}).len == 0, 'empty input has no conjuncts'
}

fn indic_line(f &shape.Font, text []rune) layout.Line {
	return indic_line_feat(f, text, [])
}

// indic_line_feat lays one line out asking the caller features, the way a
// caller drives akhn. The default is no asked features, which is what the
// gap pins below run under.
fn indic_line_feat(f &shape.Font, text []rune, features []string) layout.Line {
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	mut opts := layout.LayoutOptions{}
	opts.features = features.clone()
	return layout.layout_paragraph_with(ctx, text, .auto, fs, 32.0, &opts)
}

fn test_indic_conjunct_fuses_by_default() {
	// HarfBuzz shapes KSSA as one glyph: gid 90 (fontTools uni0915094D0937)
	// at advance 717 on cluster 0. The akhn ligature is a default feature
	// now, so the engine draws the fused glyph with no features asked —
	// and naming akhn changes nothing, which the dedup below pins.
	f := indic_font('NotoSansDevanagari-Variable.ttf') or { return }
	kssa := indic_word([rune(0x0915), rune(0x094D), rune(0x0937)])
	plain := indic_line(f, kssa)
	assert plain.glyphs.len == 1, 'kssa fuses to one glyph by default, got ${indic_dump(plain)}'
	assert plain.glyphs[0].gid == 90, 'fused kssa is gid 90, got ${indic_dump(plain)}'
	assert plain.glyphs[0].cluster == 0, 'the fusion keeps the first cluster'
	assert plain.glyphs[0].advance > 22.9 && plain.glyphs[0].advance < 23.0, 'fused kssa advances 717 design units'
	fused := indic_line_feat(f, kssa, ['akhn'])
	assert indic_dump(fused) == indic_dump(plain), 'asked akhn repeats the default'
}

fn test_indic_shape_raam_matches_harfbuzz() {
	// HarfBuzz shapes RA AA MA as three glyphs in order with no substitution
	// (cmap gids equal shaped gids): RA gid 82 at advance 409, AA matra gid
	// 31 at advance 259, MA gid 80 at advance 598. The engine draws the same
	// three gids under their own clusters with the same advances: no
	// reorder and no fusion is needed, so this word agrees exactly.
	f := indic_font('NotoSansDevanagari-Variable.ttf') or { return }
	line := indic_line(f, indic_word([rune(0x0930), rune(0x093E), rune(0x092E)]))
	assert line.glyphs.len == 3, 'raam draws three letters, got ${indic_dump(line)}'
	assert line.width > 0, 'a Devanagari word has positive width'
	want := [u16(0x52), 0x1F, 0x50]
	advances := [13.088, 8.288, 19.136]
	for i in 0 .. want.len {
		g := indic_at(line.glyphs, i) or { panic('raam input ${i} drew nothing: ${indic_dump(line)}') }
		assert g.gid == want[i], 'raam cluster ${i} is ${want[i]:x}, got ${g.gid:x}: ${indic_dump(line)}'
		assert g.advance > advances[i] - 0.06 && g.advance < advances[i] + 0.06, 'raam cluster ${i} advances ${advances[i]}'
		assert g.gid != 0, 'no .notdef in a covered raam line'
	}
}

fn test_indic_shape_wired_order() {
	// The joining hook feeds the reordered run into shaping: HarfBuzz shapes
	// KI as the matra first and the base second, both on cluster 0, and the
	// engine now draws the same order with the same clusters — the cmap
	// spacing matra gid 32, then KA gid 56. The pres VARIANT stays opt-in:
	// naming pres swaps the matra for gid 0x221, which is HarfBuzz's 545 at
	// the same 259-unit advance.
	f := indic_font('NotoSansDevanagari-Variable.ttf') or { return }
	ki := indic_line(f, indic_word([rune(0x0915), rune(0x093F)]))
	assert ki.glyphs.len == 2, 'ki draws two glyphs, got ${indic_dump(ki)}'
	assert ki.glyphs[0].gid == 0x221, 'the pres matra draws first, got ${indic_dump(ki)}'
	assert ki.glyphs[0].cluster == 0, 'the matra reports the syllable base, got ${indic_dump(ki)}'
	assert ki.glyphs[0].advance > 8.2 && ki.glyphs[0].advance < 8.4, 'the pres matra advances 259 design units'
	assert ki.glyphs[1].gid == 56, 'KA draws second, got ${indic_dump(ki)}'
	assert ki.glyphs[1].cluster == 0, 'KA keeps the syllable base, got ${indic_dump(ki)}'
	assert ki.glyphs[1].advance > 24.5 && ki.glyphs[1].advance < 24.7, 'KA advances 768 design units'
	// Naming pres again changes nothing: the default already applied it,
	// and a fusing feature applied twice is not idempotent in every font,
	// so the asked run is a no-op by construction.
	asked := indic_line_feat(f, indic_word([rune(0x0915), rune(0x093F)]), ['pres'])
	assert indic_dump(asked) == indic_dump(ki), 'asked pres repeats the default'
	// HarfBuzz shapes HINDI with the I matra first and the NDA conjunct,
	// the first syllable on cluster 0; the engine draws the matra first on
	// cluster 0 with the cmap spacing glyph, then HA, and the ndi syllable
	// untouched with its own clusters. No fusion either way.
	hindi := indic_line(f, indic_word([rune(0x0939), rune(0x093F), rune(0x0928), rune(0x094D),
		rune(0x0926), rune(0x0940)]))
	assert hindi.glyphs.len == 5, 'hindi draws five pieces, got ${indic_dump(hindi)}'
	assert hindi.glyphs[0].gid == 0x220 && hindi.glyphs[0].cluster == 0, 'hindi opens with the pres I matra on cluster 0, got ${indic_dump(hindi)}'
	assert hindi.glyphs[1].gid == 88 && hindi.glyphs[1].cluster == 0, 'HA follows on cluster 0, got ${indic_dump(hindi)}'
	assert hindi.glyphs[1].advance > 16.9 && hindi.glyphs[1].advance < 17.1, 'HA advances 531 design units'
	// The NDA conjunct fuses through half by default: gid 0xf5, and the
	// dist kern folds the pair to HarfBuzz's 309 (hmtx says 358).
	nda := indic_at(hindi.glyphs, 2) or { panic('hindi NDA drew nothing') }
	assert nda.gid == 0xf5, 'unfused NDA is the half form 0xf5, got ${indic_dump(hindi)}'
	assert nda.advance > 9.83 && nda.advance < 9.95, 'the dist kern leaves 309 design units'
	// HarfBuzz reports the UU matra on cluster 4; the engine reports the
	// input index. The order, gids and advances agree; the cluster
	// convention for a post-base mark in a fused syllable is the one
	// place they differ, and it is recorded here rather than hidden.
	uu := indic_at(hindi.glyphs, 5) or { panic('hindi UU drew nothing') }
	assert uu.gid == 33, 'UU is the cmap gid 33, got ${indic_dump(hindi)}'
}

fn test_indic_shape_current_gaps() {
	// HarfBuzz shapes NAMASTE as NA 0x4b at 555, MA 0x50 at 598, fused STA
	// 0x100 at 389, the E pres variant 0x47 at 570 and its tail 0x28
	// advancing nothing, clusters [0, 1, 2, 4, 4]. The engine draws the
	// same five gids with the same advances: the E matra used to be
	// dropped by the class gate, and the Cf gate lets it attach. The tail
	// reports cluster 5 where HarfBuzz reports 4 — the same post-base
	// cluster convention the hindi UU pin records — while the order, gids
	// and advances agree.
	f := indic_font('NotoSansDevanagari-Variable.ttf') or { return }
	namaste := indic_line(f, indic_word([rune(0x0928), rune(0x092E), rune(0x0938), rune(0x094D),
		rune(0x0924), rune(0x0947)]))
	assert namaste.glyphs.len == 5, 'namaste draws five pieces, got ${indic_dump(namaste)}'
	assert namaste.glyphs[0].gid == 0x4b && namaste.glyphs[0].cluster == 0, 'NA opens on cluster 0, got ${indic_dump(namaste)}'
	assert namaste.glyphs[1].gid == 0x50 && namaste.glyphs[1].cluster == 1, 'MA keeps cluster 1'
	assert namaste.glyphs[2].gid == 0x100 && namaste.glyphs[2].cluster == 2, 'fused STA keeps cluster 2'
	assert namaste.glyphs[2].advance > 12.39 && namaste.glyphs[2].advance < 12.51, 'STA advances 389 design units'
	assert namaste.glyphs[3].gid == 0x47 && namaste.glyphs[3].cluster == 4, 'the E pres variant lands on cluster 4'
	assert namaste.glyphs[3].advance > 18.18 && namaste.glyphs[3].advance < 18.3, 'the E variant advances 570 design units'
	assert namaste.glyphs[4].gid == 0x28 && namaste.glyphs[4].cluster == 5, 'the E tail reports its own input, got ${indic_dump(namaste)}'
	assert namaste.glyphs[4].advance == 0.0, 'the tail advances nothing'
	// Zero-class marks above the base attach too: candrabindu U+0901 and
	// anusvara U+0902 are transparent with class zero, and HarfBuzz draws
	// KA 0x38 at 768 with the mark advancing nothing, both on cluster 0,
	// offset -208 and -221 design units off the pen by the font's own
	// anchors. The engine agrees to the pixel at 32 px: marks at 17.92 and
	// 17.50 under the honest per-input cluster, the known convention.
	candra := indic_line(f, indic_word([rune(0x0915), rune(0x0901)]))
	assert candra.glyphs.len == 2, 'candrabindu draws two glyphs, got ${indic_dump(candra)}'
	assert candra.glyphs[0].gid == 0x38 && candra.glyphs[0].cluster == 0, 'KA opens on cluster 0'
	assert candra.glyphs[1].gid == 0x65 && candra.glyphs[1].cluster == 1, 'candrabindu keeps its own input (HarfBuzz reports 0), got ${indic_dump(candra)}'
	assert candra.glyphs[1].advance == 0.0 && candra.glyphs[1].is_mark, 'candrabindu is a mark advancing nothing'
	assert candra.glyphs[1].x > 17.87 && candra.glyphs[1].x < 17.97, 'candrabindu sits 208 design units off the pen, got x=${candra.glyphs[1].x}'
	anusvara := indic_line(f, indic_word([rune(0x0915), rune(0x0902)]))
	assert anusvara.glyphs.len == 2, 'anusvara draws two glyphs, got ${indic_dump(anusvara)}'
	assert anusvara.glyphs[0].gid == 0x38 && anusvara.glyphs[0].cluster == 0, 'KA opens on cluster 0'
	assert anusvara.glyphs[1].gid == 0x64 && anusvara.glyphs[1].cluster == 1, 'anusvara keeps its own input (HarfBuzz reports 0), got ${indic_dump(anusvara)}'
	assert anusvara.glyphs[1].advance == 0.0 && anusvara.glyphs[1].is_mark, 'anusvara is a mark advancing nothing'
	assert anusvara.glyphs[1].x > 17.45 && anusvara.glyphs[1].x < 17.55, 'anusvara sits 221 design units off the pen, got x=${anusvara.glyphs[1].x}'
	// HarfBuzz shapes KARMA with a reph over MA: KA gid 56 at 768 on
	// cluster 0, MA gid 80 at 598 on cluster 1, reph gid 0x1fa advancing
	// nothing on cluster 1. The machine moves the syllable-initial RA+hal
	// after MA, the cluster merge reports the whole second syllable on
	// cluster 1, and the default rphf lookup fuses it there.
	karma := indic_line(f, indic_word([rune(0x0915), rune(0x0930), rune(0x094D), rune(0x092E)]))
	assert karma.glyphs.len == 3, 'karma fuses to three glyphs, got ${indic_dump(karma)}'
	assert karma.glyphs[0].gid == 56 && karma.glyphs[0].cluster == 0, 'KA opens on cluster 0, got ${indic_dump(karma)}'
	assert karma.glyphs[1].gid == 80 && karma.glyphs[1].cluster == 1, 'MA keeps cluster 1, got ${indic_dump(karma)}'
	assert karma.glyphs[1].advance > 19.08 && karma.glyphs[1].advance < 19.2, 'MA advances 598 design units'
	assert karma.glyphs[2].gid == 0x1fa && karma.glyphs[2].cluster == 1, 'the reph lands on cluster 1, got ${indic_dump(karma)}'
	assert karma.glyphs[2].advance == 0.0, 'the reph advances nothing'
}

fn test_indic_shape_repha_with_matras() {
	// Repha interacts with matras at the syllable edges HarfBuzz reports:
	// rki draws the pres matra, then KA, then the reph variant 0x311 (all
	// on cluster 0); rkma draws KA, the AA matra, then the reph 0x1fa (all
	// on cluster 0). Both orders come out of the machine's end-move plus
	// the default rphf lookup — no per-word features asked.
	f := indic_font('NotoSansDevanagari-Variable.ttf') or { return }
	rki := indic_line(f, indic_word([rune(0x0930), rune(0x094D), rune(0x0915), rune(0x093F)]))
	assert rki.glyphs.len == 3, 'rki draws three glyphs, got ${indic_dump(rki)}'
	assert rki.glyphs[0].gid == 0x24e && rki.glyphs[0].cluster == 0, 'rki opens with the pres matra, got ${indic_dump(rki)}'
	assert rki.glyphs[1].gid == 0x38 && rki.glyphs[1].cluster == 0, 'KA follows on cluster 0'
	assert rki.glyphs[2].gid == 0x311 && rki.glyphs[2].cluster == 0, 'the reph variant closes on cluster 0'
	assert rki.glyphs[2].advance == 0.0, 'the reph advances nothing'
	rkma := indic_line(f, indic_word([rune(0x0930), rune(0x094D), rune(0x0915), rune(0x093E)]))
	assert rkma.glyphs.len == 3, 'rkma draws three glyphs, got ${indic_dump(rkma)}'
	assert rkma.glyphs[0].gid == 0x38 && rkma.glyphs[0].cluster == 0, 'rkma opens with KA, got ${indic_dump(rkma)}'
	assert rkma.glyphs[1].gid == 0x1f && rkma.glyphs[1].cluster == 0, 'the AA matra keeps cluster 0'
	assert rkma.glyphs[2].gid == 0x1fa && rkma.glyphs[2].cluster == 0, 'the reph closes on cluster 0'
}

fn test_indic_draw_base() {
	// One rasterised base consonant: a face that shapes but never inks is a
	// face the test cannot see.
	f := indic_font('NotoSansDevanagari-Variable.ttf') or { return }
	ka := f.rasterize(f.glyph_index(rune(0x0915)), 32.0, 0, 0)
	assert !ka.is_empty(), 'KA rasterises'
}

fn test_indic_pins_are_live() {
	// Break-fix controls: the table counts in test_indic_tables_match_the_enums
	// fail when a category row is dropped; these fail when the machine is
	// neutered. If shaping ever drifts, the pins above fail; if these fail,
	// the pins stopped discriminating.
	ki := indic_word([rune(0x0915), rune(0x093F)])
	assert shape.reorder_indic(ki) != ki, 'reordering changes ki: a neutered reorder must fail'
	// The hook half: a wired ki draws the matra first on the base cluster.
	// A neutered hook (identity reorder) draws the spacing matra first on
	// cluster 0, so this fails the same way the order pin above does.
	f := indic_font('NotoSansDevanagari-Variable.ttf') or { return }
	wired := indic_line(f, ki)
	assert wired.glyphs.len == 2, 'the hook control needs a shaped ki'
	assert wired.glyphs[0].gid == 0x221 && wired.glyphs[0].cluster == 0, 'the hook draws the pres matra first on cluster 0: a neutered hook must fail'
	stra := indic_word([rune(0x0938), rune(0x094D), rune(0x0924), rune(0x094D), rune(0x0930)])
	assert shape.segment_indic_syllables(stra).len == 1, 'stra stays one syllable: a dropped Virama row must fail'
	kssa := indic_word([rune(0x0915), rune(0x094D), rune(0x0937)])
	fused := indic_line_feat(f, kssa, ['akhn'])
	assert fused.glyphs[0].gid == 90, 'the akhn pin still holds'
	assert fused.glyphs[0].gid != 91, 'off-by-one gid must not match: the pin is exact'
}
