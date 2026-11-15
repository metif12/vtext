module layout

import vtext.shape
import vtext.ucd

// Grapheme cluster boundaries for UAX #29.
//
// The log-attr pass answers editors from these: a cursor moves by grapheme,
// backspace deletes one, and word/sentence starts are reported at cluster
// edges. The engine reads grapheme classes off the context's Properties and
// the emoji sets off the generated word tables (GB10/GB11 need them); the
// committee file runs in grapheme_test.v as the floor.

// GraphemeOpts are the break-fix knobs. Both default to false; setting one
// neuters the named rule and must move the conformance score, which is what
// proves the passing score actually depends on it.
pub struct GraphemeOpts {
pub:
	// skip_gb9 neuters GB9's Extend/ZWJ hold: combining marks part from
	// their base, and ZWJ sequences split.
	skip_gb9 bool
}

// grapheme_breaks returns one decision per boundary: index i is the break
// before cps[i], and index cps.len is the break at the end of the text.
pub fn grapheme_breaks(ctx &shape.Context, cps []rune, opt GraphemeOpts) []bool {
	props := ctx.properties
	mut cls := []ucd.GraphemeClass{len: cps.len}
	for i, cp in cps {
		cls[i] = props.grapheme_class_of(cp)
	}
	ep := ucd.word_ep_ranges()
	emod := ucd.emoji_mod_ranges()
	ebase := ucd.emoji_base_ranges()
	ebg := ucd.ebg_ranges()
	incb := ucd.incb_ranges()
	mut out := []bool{len: cps.len + 1}
	for i in 0 .. cps.len + 1 {
		out[i] = grapheme_break_at(cps, cls, ep, emod, ebase, ebg, incb, opt, i)
	}
	return out
}

// is_gb_ep reports the GB macro ExtPict: a codepoint with the
// Extended_Pictographic property.
fn is_gb_ep(ep []ucd.CodeRange, cp rune) bool {
	return ucd.lookup_range(ep, u32(cp), 0) == 1
}

// is_gb_emod reports whether cp is an emoji modifier (a skin tone).
fn is_gb_emod(emod []ucd.CodeRange, cp rune) bool {
	return ucd.lookup_range(emod, u32(cp), 0) == 1
}

// is_gb_ebase reports whether cp is an emoji modifier base.
fn is_gb_ebase(ebase []ucd.CodeRange, cp rune) bool {
	return ucd.lookup_range(ebase, u32(cp), 0) == 1
}

// is_gb_ebg reports whether cp is EBG: emoji with a text-default
// presentation (Emoji minus Emoji_Presentation, derived once in the
// generator).
fn is_gb_ebg(ebg []ucd.CodeRange, cp rune) bool {
	return ucd.lookup_range(ebg, u32(cp), 0) == 1
}

// gb_is_extend reports the GB10/GB11 ignore class: Extend only. SpacingMark
// holds by its own rule (GB9a) and ZWJ is spelled out where it matters
// (GB9, GB11), so neither folds in here.
fn gb_is_extend(c ucd.GraphemeClass) bool {
	return c == .extend
}

// grapheme_break_at decides the boundary before cps[i]: i == 0 is sot and
// i == cps.len is eot. The rules run in UAX #29 order and the first one that
// answers ends the search.
fn grapheme_break_at(cps []rune, cls []ucd.GraphemeClass, ep []ucd.CodeRange, emod []ucd.CodeRange, ebase []ucd.CodeRange, ebg []ucd.CodeRange, incb []ucd.CodeRange, opt GraphemeOpts, i int) bool {
	n := cps.len
	if i == 0 {
		return true // GB1: sot ÷
	}
	if i == n {
		return true // GB2: ÷ eot
	}
	left := cls[i - 1]
	right := cls[i]
	if left == .cr && right == .lf {
		return false // GB3: × CR × LF
	}
	if left == .control || left == .cr || left == .lf {
		return true // GB4: (Control | CR | LF) ÷
	}
	if right == .control || right == .cr || right == .lf {
		return true // GB5: ÷ (Control | CR | LF)
	}
	if left == .l && (right == .l || right == .v || right == .lv || right == .lvt) {
		return false // GB6: L × (L | V | LV | LVT)
	}
	if (left == .lv || left == .v) && (right == .v || right == .t) {
		return false // GB7: (LV | V) × (V | T)
	}
	if (left == .lvt || left == .t) && right == .t {
		return false // GB8: (LVT | T) × T
	}
	if !opt.skip_gb9 && (right == .extend || right == .zwj) {
		return false // GB9: × (Extend | ZWJ)
	}
	if right == .spacing_mark {
		return false // GB9a: × SpacingMark
	}
	if left == .prepend {
		return false // GB9b: Prepend ×
	}
	// GB9c: InCB=Linker InCB=Extend* × InCB=Consonant (extended clusters
	// only). The InCB table comes from the InCB rows of
	// DerivedCoreProperties.txt — there is no InCB file of its own — with
	// ordinal 0 the @missing default (None). Viramas are Linkers, ZWJ is an
	// Extend, Indic consonants are Consonants, which is why the Extend* run
	// carries a virama-ZWJ tail onto its consonant.
	if ucd.is_incb_consonant(incb, cps[i]) {
		mut j := i - 1
		for j >= 0 && ucd.is_incb_extend(incb, cps[j]) {
			j--
		}
		if j >= 0 && ucd.is_incb_linker(incb, cps[j]) {
			return false
		}
	}
	// GB10: (E_Base | EBG | ExtPict) Extend* × E_Modifier. The Extend run
	// between the base and the modifier is read leftward from the boundary,
	// the same shape as the WB4 ignore walk.
	if is_gb_emod(emod, cps[i]) {
		mut j := i - 1
		for j >= 0 && gb_is_extend(cls[j]) {
			j--
		}
		if j >= 0
			&& (is_gb_ebase(ebase, cps[j]) || is_gb_ebg(ebg, cps[j]) || is_gb_ep(ep, cps[j])) {
			return false
		}
	}
	// GB11: ExtPict Extend* ZWJ × ExtPict. The ZWJ stands immediately left
	// of the boundary; the Extend run and the pictograph stand left of it.
	if is_gb_ep(ep, cps[i]) && cls[i - 1] == .zwj {
		mut j := i - 2
		for j >= 0 && gb_is_extend(cls[j]) {
			j--
		}
		if j >= 0 && is_gb_ep(ep, cps[j]) {
			return false
		}
	}
	// GB12/GB13: sot (RI RI)* RI × RI and [^RI] (RI RI)* RI × RI. Both fold
	// to one parity: a run of consecutive RIs breaks pairs from its start,
	// so the boundary holds when the count left of it is odd.
	if left == .regional_indicator && right == .regional_indicator {
		mut k := 0
		mut j := i - 1
		for j >= 0 && cls[j] == .regional_indicator {
			k++
			j--
		}
		if k % 2 == 1 {
			return false
		}
	}
	return true // GB999: ÷ Any
}
