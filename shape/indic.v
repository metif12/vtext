module shape

import vtext.ucd

// The Indic syllable machine: segmentation, matra reordering and conjunct
// hooks for Devanagari and its relatives.
//
// This is a standalone pass over codepoint arrays: it takes what it needs
// as arguments and answers new arrays. The layout joining hook
// (indic_visual in layout/layout.v) feeds reorder_indic_mapped into shaping
// and merges reordered syllables' clusters; Khmer generality is a noted
// follow-up.
//
// The model is the orthographic syllable behind the Unicode Indic shaping
// guidance. A syllable opens on a consonant or an independent vowel and
// holds everything up to the next opener: nukta, halant, the consonants a
// halant joins on, dependent vowels, bindus and visarga. A pre-base matra,
// one whose positional category is Left or Visual_Order_Left, belongs at the
// syllable start visually while sitting after its consonant logically, so
// reordering moves it before the first consonant of its syllable. A
// consonant, halant, consonant run is a conjunct the font fuses through its
// Indic features; the machine reports the span and leaves the fusion to the
// substitution pass that owns the font tables.
//
// What this pass deliberately does not do, each with its reason:
//   - split matras (Left_And_Right, Top_And_Bottom and friends) are one
//     codepoint drawn in two places; splitting them needs glyph halves only
//     the font tables can name.
//   - mark positioning and feature application stay in layout and the font
//     layer: this pass never names a glyph.

// IndicSyllabic is the Indic_Syllabic_Category of a codepoint. The ordinals
// match indic_syllabic_names_data, which is what keeps this enum and the
// ordinals tools/gen_indic.v writes in step with each other. Ordinal 0 is
// Other, the UCD missing default, so an unlisted codepoint reads as Other.
pub enum IndicSyllabic {
	other                       = 0
	avagraha                    = 1
	bindu                       = 2
	brahmi_joining_number       = 3
	cantillation_mark           = 4
	consonant                   = 5
	consonant_dead              = 6
	consonant_final             = 7
	consonant_head_letter       = 8
	consonant_initial_postfixed = 9
	consonant_killer            = 10
	consonant_medial            = 11
	consonant_placeholder       = 12
	consonant_preceding_repha   = 13
	consonant_prefixed          = 14
	consonant_subjoined         = 15
	consonant_succeeding_repha  = 16
	consonant_with_stacker      = 17
	gemination_mark             = 18
	invisible_stacker           = 19
	joiner                      = 20
	modifying_letter            = 21
	non_joiner                  = 22
	number                      = 23
	number_joiner               = 24
	nukta                       = 25
	pure_killer                 = 26
	register_shifter            = 27
	reordering_killer           = 28
	syllable_modifier           = 29
	tone_letter                 = 30
	tone_mark                   = 31
	virama                      = 32
	visarga                     = 33
	vowel                       = 34
	vowel_dependent             = 35
	vowel_independent           = 36
}

// IndicPositional is the Indic_Positional_Category of a codepoint. The
// ordinals match indic_positional_names_data the way the syllabic ones match
// theirs. Ordinal 0 is Not_Applicable, the UCD missing default.
pub enum IndicPositional {
	not_applicable           = 0
	bottom                   = 1
	bottom_and_left          = 2
	bottom_and_right         = 3
	left                     = 4
	left_and_right           = 5
	overstruck               = 6
	right                    = 7
	top                      = 8
	top_and_bottom           = 9
	top_and_bottom_and_left  = 10
	top_and_bottom_and_right = 11
	top_and_left             = 12
	top_and_left_and_right   = 13
	top_and_right            = 14
	visual_order_left        = 15
}

// indic_syllabic_ranges decodes the generated syllabic category table.
//
// It is decoded by the caller rather than held on Properties, the way
// quote_ranges is and for the same reason: a few hundred ranges asked about
// only where an Indic run needs segmenting, so a caller pays one small
// decode per call instead of every Properties value carrying a table nothing
// outside an Indic run is ever asked about.
pub fn indic_syllabic_ranges() []ucd.CodeRange {
	return ucd.parse_ranges(ucd.indic_syllabic_ranges_data)
}

// indic_positional_ranges decodes the generated positional category table,
// for the same caller-decoded reason as the syllabic one.
pub fn indic_positional_ranges() []ucd.CodeRange {
	return ucd.parse_ranges(ucd.indic_positional_ranges_data)
}

// indic_syllabic_of returns the syllabic category of cp. Codepoints with no
// listed range are Other, which is what the UCD missing line specifies.
pub fn indic_syllabic_of(ranges []ucd.CodeRange, cp rune) IndicSyllabic {
	o := ucd.lookup_range(ranges, u32(cp), 0)
	return unsafe { IndicSyllabic(int(o)) }
}

// indic_positional_of returns the positional category of cp. Codepoints with
// no listed range are Not_Applicable, which is what the UCD missing line
// specifies.
pub fn indic_positional_of(ranges []ucd.CodeRange, cp rune) IndicPositional {
	o := ucd.lookup_range(ranges, u32(cp), 0)
	return unsafe { IndicPositional(int(o)) }
}

// is_indic_consonant_family reports whether a category is a consonant
// proper: the consonant family without the independent vowels, vowel
// signs and numbers the wider consonant-like predicate admits for
// syllable nursing. A kinzi trio hands its base to a consonant, and a
// vowel or number after the virama is unevidenced for a prepose.
fn is_indic_consonant_family(c IndicSyllabic) bool {
	return c in [.consonant, .consonant_dead, .consonant_final, .consonant_medial,
		.consonant_placeholder, .consonant_prefixed, .consonant_subjoined, .consonant_with_stacker,
		.consonant_preceding_repha, .consonant_succeeding_repha, .consonant_head_letter]
}

// is_indic_consonant_like reports whether a category can open or extend a
// syllable nucleus: the consonant family, an independent vowel standing on
// its own, a vowel sign root, or a number.
fn is_indic_consonant_like(c IndicSyllabic) bool {
	return c in [.consonant, .consonant_dead, .consonant_final, .consonant_medial,
		.consonant_placeholder, .consonant_prefixed, .consonant_subjoined, .consonant_with_stacker,
		.consonant_preceding_repha, .consonant_succeeding_repha, .consonant_head_letter,
		.vowel_independent, .vowel, .number]
}

// is_indic_filler reports whether a category sits inside a cluster without
// breaking it: a nukta qualifying a consonant, or an explicit join control.
fn is_indic_filler(c IndicSyllabic) bool {
	return c == .nukta || c == .joiner || c == .non_joiner
}

// is_indic_halant reports whether a category is a halant-like joiner: the
// virama and the two killers that behave like it in the cluster grammar.
fn is_indic_halant(c IndicSyllabic) bool {
	return c == .virama || c == .pure_killer || c == .invisible_stacker
}

// is_repha_ra reports whether a codepoint is the RA that forms a reph:
// RA plus halant at the start of a syllable. The Indic syllabic property
// does not single these out for Devanagari and Bengali (both are plain
// Consonant there), so the machine names them per script; a new script
// adds its RA here with its face.
fn is_repha_ra(cp rune) bool {
	return cp == rune(0x0930) || cp == rune(0x09B0)
}

// IndicSyllable is one orthographic syllable: a half-open span of input
// indices, so syllables tile the run with no gaps and no overlap.
pub struct IndicSyllable {
pub:
	start int
	end   int
}

// segment_indic_syllables cuts a run into orthographic syllables. A syllable
// opens on a consonant-like character unless a halant-like joiner comes
// between it and the previous consonant, in which case the consonant extends
// the cluster; everything else attaches to the current syllable. A leading
// run of attachers with nothing to attach to forms a syllable of its own,
// which is the honest answer for ill-formed input rather than an empty span.
pub fn segment_indic_syllables(cps []rune) []IndicSyllable {
	ranges := indic_syllabic_ranges()
	mut out := []IndicSyllable{}
	mut start := -1
	mut i := 0
	for i < cps.len {
		c := indic_syllabic_of(ranges, cps[i])
		if opens_indic_syllable(ranges, cps, i, c) {
			if start >= 0 {
				out << IndicSyllable{ start: start, end: i }
			}
			start = i
		} else if start < 0 {
			start = i
		}
		i++
	}
	if start >= 0 {
		out << IndicSyllable{ start: start, end: cps.len }
	}
	return out
}

// opens_indic_syllable reports whether the character at i starts a new
// syllable. A consonant-like character does, unless a halant-like joiner
// stands between it and the previous consonant, with nuktas and join
// controls skipped the way the cluster grammar reads them: a consonant that
// a halant reaches is the second half of a conjunct, not a new onset.
fn opens_indic_syllable(ranges []ucd.CodeRange, cps []rune, i int, c IndicSyllabic) bool {
	if !is_indic_consonant_like(c) {
		return false
	}
	mut k := i - 1
	for k >= 0 && is_indic_filler(indic_syllabic_of(ranges, cps[k])) {
		k--
	}
	if k >= 0 && is_indic_halant(indic_syllabic_of(ranges, cps[k])) {
		return false
	}
	return true
}

// reorder_indic_syllable moves a pre-base matra before the first consonant
// of its syllable. A matra whose positional category is Left or
// Visual_Order_Left is drawn before its consonant while sitting after it in
// the text, so visual order is the consonant run with the matra first. A
// syllable with no pre-base matra, or one where no consonant precedes the
// matra, comes back unchanged: the reorder never invents an anchor.
// reorder_indic_syllable moves a pre-base matra before the first consonant
// of its syllable and a syllable-initial reph to the end. It answers what
// reorder_indic_syllable_mapped answers without the map.
pub fn reorder_indic_syllable(syl []rune) []rune {
	reordered, _ := reorder_indic_syllable_mapped(syl)
	return reordered
}

// reorder_indic reorders every syllable of a run, tiling the run the way the
// segmenter cut it. Syllables without a pre-base matra or a syllable-initial
// reph pass through unchanged, so the reorder is the identity everywhere the
// text is already in visual order.
pub fn reorder_indic(cps []rune) []rune {
	if cps.len == 0 {
		return []rune{}
	}
	mut out := []rune{cap: cps.len}
	for s in segment_indic_syllables(cps) {
		out << reorder_indic_syllable(cps[s.start..s.end])
	}
	return out
}

// reorder_indic_mapped reorders every syllable of a run like reorder_indic
// and also answers the permutation it applied: map_[new] is the index in the
// input that the codepoint at new came from. The layout pass shapes the
// reordered run but reports clusters in the caller's order, so it needs
// both; a caller that only draws needs reorder_indic. An unchanged syllable
// maps to itself, so the map is the identity wherever the text was already
// in visual order.
pub fn reorder_indic_mapped(cps []rune) ([]rune, []int) {
	if cps.len == 0 {
		return []rune{}, []int{}
	}
	mut out := []rune{cap: cps.len}
	mut map_ := []int{cap: cps.len}
	for s in segment_indic_syllables(cps) {
		reordered, m := reorder_indic_syllable_mapped(cps[s.start..s.end])
		for k, cp in reordered {
			out << cp
			map_ << s.start + m[k]
		}
	}
	return out, map_
}

// reorder_indic_syllable_mapped moves a pre-base matra before the first
// consonant of its syllable and a syllable-initial reph to the end, with
// the permutation map. An unchanged syllable maps to itself. The repha
// half is the syllable machine's job the joining hook feeds on: RA plus a
// bare halant opens the syllable, and the pair draws after everything else
// in it (matras included), which is the context the rphf lookup consumes.
fn reorder_indic_syllable_mapped(syl []rune) ([]rune, []int) {
	if syl.len < 2 {
		mut ids := []int{cap: syl.len}
		for i in 0 .. syl.len {
			ids << i
		}
		return syl.clone(), ids
	}
	syl_ranges := indic_syllabic_ranges()
	pos_ranges := indic_positional_ranges()
	// A repha is RA plus a directly following halant-like joiner. A join
	// control or nukta between them means no repha: an explicit halant
	// shows as itself, and a ZWJ-forced form is not the default reph.
	mut repha := 0
	if is_repha_ra(syl[0]) && is_indic_halant(indic_syllabic_of(syl_ranges, syl[1])) {
		repha = 2
	}
	mut matra := -1
	for i in repha .. syl.len {
		if indic_syllabic_of(syl_ranges, syl[i]) == .vowel_dependent {
			p := indic_positional_of(pos_ranges, syl[i])
			if p == .left || p == .visual_order_left {
				matra = i
				break
			}
		}
	}
	mut anchor := -1
	if matra > 0 {
		for i in repha .. matra {
			if is_indic_consonant_like(indic_syllabic_of(syl_ranges, syl[i])) {
				anchor = i
				break
			}
		}
	}
	mut out := []rune{cap: syl.len}
	mut map_ := []int{cap: syl.len}
	if anchor >= 0 {
		for i in repha .. anchor {
			out << syl[i]
			map_ << i
		}
		out << syl[matra]
		map_ << matra
		for i in anchor .. matra {
			out << syl[i]
			map_ << i
		}
		for i in matra + 1 .. syl.len {
			out << syl[i]
			map_ << i
		}
	} else {
		for i in repha .. syl.len {
			out << syl[i]
			map_ << i
		}
	}
	// A Khmer COENG+RO pair draws before its syllable's base consonant:
	// HarfBuzz preposes the pair with or without the pref fusion behind
	// it (the fusion then claims the pair through lookup 12), the way a
	// reph moves for the Indic scripts. The codepoints gate the rule: no
	// Devanagari or Bengali syllable contains U+17D2 or U+179A, so every
	// Indic syllable passes through exactly as before. Only directly
	// adjacent pairs move; a join control between them is unevidenced,
	// and each pair keeps its order when several prepose at once.
	if out.len > 1 {
		mut at := -1
		for i in 0 .. out.len - 1 {
			if out[i] == rune(0x17D2) && out[i + 1] == rune(0x179A) {
				at = i
				break
			}
		}
		if at >= 0 {
			mut front := []rune{cap: out.len}
			mut front_map := []int{cap: out.len}
			mut rest := []rune{cap: out.len}
			mut rest_map := []int{cap: out.len}
			mut i := 0
			for i < out.len {
				if out[i] == rune(0x17D2) && i + 1 < out.len && out[i + 1] == rune(0x179A) {
					front << out[i]
					front << out[i + 1]
					front_map << map_[i]
					front_map << map_[i + 1]
					i += 2
				} else {
					rest << out[i]
					rest_map << map_[i]
					i++
				}
			}
			out = []rune{cap: front.len + rest.len}
			out << front
			out << rest
			map_ = []int{cap: front_map.len + rest_map.len}
			map_ << front_map
			map_ << rest_map
		}
	}
	// A Myanmar kinzi trio draws its base first: HarfBuzz preposes the
	// consonant after [C, ASAT, VIRAMA] ahead of the trio, and the abvs
	// lookup then fuses the trio into the kinzi mark behind it (lookup
	// 52: nga/asat/virama to kinzi). The trio opens on NGA or RA — KA
	// with the same tail draws in place with a dotted circle for the
	// dangling virama — and the preposed character has to be a
	// consonant: a vowel sign after the trio draws after it, unevidenced
	// for a prepose. The codepoints gate the rule like the Khmer one, so
	// every other script passes through exactly as before.
	if out.len > 3 {
		mut at := -1
		for i in 0 .. out.len - 3 {
			if (out[i] == rune(0x1004) || out[i] == rune(0x101B)) && out[i + 1] == rune(0x103A) && out[i + 2] == rune(0x1039) && is_indic_consonant_family(indic_syllabic_of(syl_ranges, out[i + 3])) {
				at = i
				break
			}
		}
		if at >= 0 {
			mut first := []rune{cap: out.len}
			mut first_map := []int{cap: out.len}
			mut rest := []rune{cap: out.len}
			mut rest_map := []int{cap: out.len}
			mut i := 0
			for i < out.len {
				if i + 3 < out.len && (out[i] == rune(0x1004) || out[i] == rune(0x101B)) && out[i + 1] == rune(0x103A) && out[i + 2] == rune(0x1039) && is_indic_consonant_family(indic_syllabic_of(syl_ranges, out[i + 3])) {
					first << out[i + 3]
					first_map << map_[i + 3]
					rest << out[i]
					rest << out[i + 1]
					rest << out[i + 2]
					rest_map << map_[i]
					rest_map << map_[i + 1]
					rest_map << map_[i + 2]
					i += 4
				} else {
					rest << out[i]
					rest_map << map_[i]
					i++
				}
			}
			out = []rune{cap: first.len + rest.len}
			out << first
			out << rest
			map_ = []int{cap: first_map.len + rest_map.len}
			map_ << first_map
			map_ << rest_map
		}
	}
	for i in 0 .. repha {
		out << syl[i]
		map_ << i
	}
	return out, map_
}

// IndicConjunct is a consonant, halant, consonant run: a half-open span of
// input indices the font fuses through its Indic features. The machine
// reports the span and leaves the fusion to the substitution pass.
pub struct IndicConjunct {
pub:
	start int
	end   int
}

// find_indic_conjuncts reports every consonant, halant, consonant run in a
// run of text. A halant-like joiner followed by a consonant-like character
// extends the run, with nuktas skipped before the joiner and join controls
// skipped after it; anything else ends it. A lone halant with no consonant
// after it forms no conjunct: an explicit halant showing as itself is not a
// fusion.
pub fn find_indic_conjuncts(cps []rune) []IndicConjunct {
	ranges := indic_syllabic_ranges()
	mut out := []IndicConjunct{}
	mut i := 0
	for i < cps.len {
		if !is_indic_consonant_like(indic_syllabic_of(ranges, cps[i])) {
			i++
			continue
		}
		mut j := i
		for j < cps.len {
			mut k := j + 1
			for k < cps.len && indic_syllabic_of(ranges, cps[k]) == .nukta {
				k++
			}
			if k >= cps.len {
				break
			}
			if !is_indic_halant(indic_syllabic_of(ranges, cps[k])) {
				break
			}
			mut m := k + 1
			for m < cps.len && (indic_syllabic_of(ranges, cps[m]) == .joiner || indic_syllabic_of(ranges, cps[m]) == .non_joiner) {
				m++
			}
			if m >= cps.len {
				break
			}
			if !is_indic_consonant_like(indic_syllabic_of(ranges, cps[m])) {
				break
			}
			j = m
		}
		if j > i {
			out << IndicConjunct{ start: i, end: j + 1 }
			i = j + 1
		} else {
			i++
		}
	}
	return out
}
