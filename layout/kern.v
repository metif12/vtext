module layout

import harfara.shape
import harfara.font

// substitute_in_fonts hands each stretch of the run that came from one font to that font.
//
// A substitution cannot straddle two fonts, because a glyph index in one font means nothing in
// another. A line that fell back mid-word therefore has its rules stop at the seam, and the two
// letters a ligature would have fused are drawn apart. That is the honest answer for a line whose
// characters came from different fonts: there is no single glyph to draw them as, and a mark
// composition that needs the letter before it is out of reach for the same reason.
pub fn substitute_in_fonts(glyphs []shape.Glyph, em_px f64, script string, lang string, features []string,
	vertical bool, rtl bool) []shape.Glyph {
	if glyphs.len == 0 {
		return glyphs
	}
	mut out := substitute_gsub_in_fonts(glyphs, em_px, script, lang, features, vertical)
	// Horizontal pair offsets have no meaning for a downward pen: the advance
	// they fold into is overwritten by the vertical swap, and the y they fold
	// is the horizontal baseline's. Vertical pairs apply after the swap, per
	// run at the call site, so this pass skips kerning entirely in vertical
	// mode rather than folding a number the swap is about to discard.
	if !vertical {
		apply_gpos_in_fonts(mut out, em_px, script, lang, features, rtl)
	}
	return out
}

// substitute_gsub_in_fonts runs the font's own substitutions over each
// same-font run: the GSUB half of substitute_in_fonts, timed on its own
// by the F1 profiler. The font loop is what the kern that follows reads,
// so it stays ahead of it exactly as before.
fn substitute_gsub_in_fonts(glyphs []shape.Glyph, em_px f64, script string, lang string, features []string,
	vertical bool) []shape.Glyph {
	mut out := []shape.Glyph{cap: glyphs.len}
	mut at := 0
	for at < glyphs.len {
		f := glyphs[at].font or {
			out << glyphs[at]
			at++
			continue
		}
		mut end := at + 1
		for end < glyphs.len {
			other := glyphs[end].font or { break }
			if other != f {
				break
			}
			end++
		}
		for glyph in f.substitute_glyphs(glyphs[at..end], script, lang, em_px, features, vertical) {
			out << glyph
		}
		at = end
	}
	return out
}

// apply_gpos_in_fonts folds the font's horizontal pair positioning into
// advances: the GPOS half of substitute_in_fonts, timed on its own by the
// F1 profiler. It reads the substituted run, so it stays after the GSUB
// half exactly as before.
fn apply_gpos_in_fonts(mut glyphs []shape.Glyph, em_px f64, script string, lang string, features []string,
	rtl bool) {
	kern_pairs(mut glyphs, em_px, script, lang, rtl)
	single_positions(mut glyphs, em_px, script, lang, features, false)
}

// apply_vertical_advances swaps each glyph's advance for its vertical one, so
// the downward pass accumulates vmtx steps. It runs after substitution because
// substitution and horizontal kerning both settle horizontal advances, which a
// vertical pen has no use for, and before spacing because spacing adds onto
// whatever advance the pen accumulates.
//
// A glyph from a font with no vertical metrics keeps the horizontal advance it
// was shaped with: a zero step would pile every fallback glyph at one y, and a
// missing vmtx is the common case for a Latin fallback face, not an error.
pub fn apply_vertical_advances(mut glyphs []shape.Glyph, em_px f64) {
	for mut g in glyphs {
		if g.is_mark {
			continue
		}
		if f := g.font {
			if f.has_vertical_metrics() {
				g.advance = f.vertical_advance(g.gid, em_px)
			}
		}
	}
}

// GposPairLookupsMemo holds one run's script-keyed GPOS lookup lists for
// one font: the pair kerns, the vertical kerns and the mark attachments.
// Every list is resolved once, the first time the run asks, and every
// later pair or mark in the same font reads the same lists. Resolving
// per glyph rebuilds them thousands of times a paragraph; the memo keeps
// one copy per font, the way KernChainMemo keeps one chaining evaluation.
// None of the three lists reads the caller's extras or direction, so the
// key is just font, script and language.
struct GposPairLookupsMemo {
	font_ptr voidptr
	script   string
	lang     string
	kern     []u16
	vkrn     []u16
	marks    []u16
}

// gpos_pair_lookups_for answers the memo entry for this font and script,
// resolving and storing it on the first miss. A font without a GPOS
// table answers three empty lists, which decide nothing, the same as
// resolving them one by one would.
fn gpos_pair_lookups_for(mut memo []GposPairLookupsMemo, f &shape.Font, script string, lang string) GposPairLookupsMemo {
	key := voidptr(f)
	for m in memo {
		if m.font_ptr == key && m.script == script && m.lang == lang {
			return m
		}
	}
	mut kern := []u16{}
	mut vkrn := []u16{}
	mut marks := []u16{}
	if gpos := f.face.gpos {
		kern = gpos.kerning_for(script, lang)
		vkrn = gpos.vkerning_for(script, lang)
		marks = gpos.mark_feature_lookups_for(script, lang)
	}
	m := GposPairLookupsMemo{
		font_ptr: key
		script:   script
		lang:     lang
		kern:     kern
		vkrn:     vkrn
		marks:    marks
	}
	memo << m
	return m
}

// GposSinglesLookupsMemo holds one run's single-adjustment lookup lists
// for one font: the same idea as the pair memo, but the singles list
// reads the caller's extras and direction, so those join the key. Two
// runs asking different features must not share a list.
struct GposSinglesLookupsMemo {
	font_ptr voidptr
	script   string
	lang     string
	extra    []string
	vertical bool
	lookups  []u16
}

// gpos_singles_lookups_for answers the memo entry for this font, script,
// language, asked extras and direction, resolving and storing it on the
// first miss.
fn gpos_singles_lookups_for(mut memo []GposSinglesLookupsMemo, f &shape.Font, script string, lang string, extra []string, vertical bool) []u16 {
	key := voidptr(f)
	for m in memo {
		if m.font_ptr == key && m.script == script && m.lang == lang && m.extra == extra
			&& m.vertical == vertical {
			return m.lookups
		}
	}
	mut lookups := []u16{}
	if gpos := f.face.gpos {
		lookups = gpos.single_lookups(script, lang, extra, vertical)
	}
	memo << GposSinglesLookupsMemo{
		font_ptr: key
		script:   script
		lang:     lang
		extra:    extra
		vertical: vertical
		lookups:  lookups
	}
	return lookups
}

// kern_pairs folds the font's pair positioning into advances, after every substitution
// has run so the pairs are the glyphs the font's rules are written against.
//
// Only plain adjacency is considered: same font on both sides, no marks in the pair.
// A mark between two letters is left to the lookups' own flags, which this does not
// second-guess, and a fallback seam has no single table to ask.
//
// KernChainMemo holds one run's chaining kern adjustments per font: the
// full run is walked once, not once per pair, the way ChainMemo holds the
// mark chains (see position_marks).
struct KernChainMemo {
	font_ptr voidptr
	script   string
	lang     string
	pairs    []font.KernChainPair
}

// kern_chain_for answers the run's chaining kern adjustments for one font,
// evaluating once and memoizing for the rest of the line.
fn kern_chain_for(mut memo []KernChainMemo, f &shape.Font, gpos &font.Gpos, gids []u16, script string, lang string) []font.KernChainPair {
	key := voidptr(f)
	for m in memo {
		if m.font_ptr == key && m.script == script && m.lang == lang {
			return m.pairs
		}
	}
	pairs := gpos.kern_chain_offsets(gids, script, lang, f.face.gdef)
	memo << KernChainMemo{ font_ptr: key, script: script, lang: lang, pairs: pairs }
	return pairs
}

// The kern folds into the advance of the visually first glyph of the pair — the first
// logical glyph going left to right, the second going right to left — which is where
// HarfBuzz reports it: AV tightens A's advance, and e-f in an RTL run tightens f's.
pub fn kern_pairs(mut glyphs []shape.Glyph, em_px f64, script string, lang string, rtl bool) {
	if glyphs.len < 2 {
		return
	}
	mut gids := []u16{cap: glyphs.len}
	for g in glyphs {
		gids << g.gid
	}
	// The chaining kern lookups are evaluated once per font for the whole
	// run (see kern_chain_offsets): per pair they would walk the run again
	// for every pair, which is quadratic in the line length. The plain
	// pair lists ride the same memo for the same reason: kerning_for
	// rebuilds them per pair, and a paragraph has as many pairs as glyphs.
	mut chain_memo := []KernChainMemo{}
	mut pair_memo := []GposPairLookupsMemo{}
	for i in 0 .. glyphs.len - 1 {
		a := glyphs[i]
		b := glyphs[i + 1]
		// Marks take part in contextual kerning: a chaining rule that widens
		// a base before its mark (Bengali kri +200 through dist) kerns the
		// pair, and skipping it leaves the base narrow. A pair of two marks
		// still has nowhere to go — neither advances — so only a base on at
		// least one side applies.
		if a.is_mark && b.is_mark {
			continue
		}
		fa := a.font or { continue }
		fb := b.font or { continue }
		if fa != fb {
			continue
		}
		gpos := fa.face.gpos or { continue }
		lk := gpos_pair_lookups_for(mut pair_memo, fa, script, lang)
		mut x := 0
		mut y := 0
		mut found := false
		if k := gpos.kern_offset_in(gids[i], gids[i + 1], lk.kern) {
			x += k.x
			y += k.y
			found = true
		}
		chain := kern_chain_for(mut chain_memo, fa, gpos, gids, script, lang)
		if i < chain.len && chain[i].found {
			x += chain[i].x
			y += chain[i].y
			found = true
		}
		if !found {
			continue
		}
		scale := em_px / f64(fa.face.units_per_em)
		// y is positive upwards in the font and downwards on the line, as in
		// position_marks, so it is flipped here rather than at the callers.
		if rtl {
			glyphs[i + 1].advance += f64(x) * scale
			glyphs[i + 1].y -= f64(y) * scale
		} else {
			glyphs[i].advance += f64(x) * scale
			glyphs[i].y -= f64(y) * scale
		}
	}
}

// vkern_pairs folds the font's vertical pair adjustments into advances, after the vertical swap
// has run so the advances it folds into are the downward steps. Substitution comes first for the
// same reason as in kern_pairs: the pairs are the glyphs the font's rules are written against,
// which in a vertical line means the vert variants, and asking before vert would pair the wrong
// glyphs — リィ kerns by -123 as drawn, not by the -82 its horizontal glyphs would kern by.
//
// It mirrors kern_pairs with the axes agreed: a vkrn record carries a y advance, which is a step
// along the downward pen in the same units the vertical advances are read in, so it adds to the
// advance directly rather than being flipped the way a y offset is. Only plain adjacency is
// considered — same font on both sides, no marks in the pair — and the kern folds into the advance
// of the visually first glyph of the pair, the first logical glyph going down the column and the
// second in the rare right-to-left vertical run.
pub fn vkern_pairs(mut glyphs []shape.Glyph, em_px f64, script string, lang string, rtl bool) {
	if glyphs.len < 2 {
		return
	}
	mut gids := []u16{cap: glyphs.len}
	for g in glyphs {
		gids << g.gid
	}
	mut pair_memo := []GposPairLookupsMemo{}
	for i in 0 .. glyphs.len - 1 {
		a := glyphs[i]
		b := glyphs[i + 1]
		if a.is_mark || b.is_mark {
			continue
		}
		fa := a.font or { continue }
		fb := b.font or { continue }
		if fa != fb {
			continue
		}
		gpos := fa.face.gpos or { continue }
		lk := gpos_pair_lookups_for(mut pair_memo, fa, script, lang)
		off := gpos.vkern_offset_in(a.gid, b.gid, lk.vkrn) or { continue }
		scale := em_px / f64(fa.face.units_per_em)
		if rtl {
			glyphs[i + 1].advance += f64(off.y) * scale
		} else {
			glyphs[i].advance += f64(off.y) * scale
		}
	}
}

// single_positions folds one glyph's single positioning into its advance and placement, after
// every substitution has run so the glyphs are the ones the font's rules are written against.
//
// An advance adjustment moves the pen and everything after it, so it folds into the advance
// the placing pass accumulates from, the way kern_pairs folds pair kerns. A placement moves
// only its own glyph, so it rides in x and y, which the placing pass accumulates from rather
// than overwrites: every glyph enters the placing pass with x and y holding only what this
// pass put there, and place_glyphs adds the pen rather than assigning it.
//
// Only non-marks are considered. Marks are placed by position_marks from the font's anchors,
// and a shift from here would move an anchored mark twice; an unanchored mark keeps today's
// answer rather than a new one. No rule at all leaves the glyph alone, which is the common
// case: most fonts carry no single positioning under the features a line applies.
pub fn single_positions(mut glyphs []shape.Glyph, em_px f64, script string, lang string, features []string,
	vertical bool) {
	// The lookup lists are resolved once per font, not once per glyph:
	// single_lookups rebuilds the asked list, the lookup list and a
	// seen-set map, and a paragraph has as many glyphs as pairs.
	mut singles_memo := []GposSinglesLookupsMemo{}
	for mut g in glyphs {
		if g.is_mark {
			continue
		}
		f := g.font or { continue }
		gpos := f.face.gpos or { continue }
		lookups := gpos_singles_lookups_for(mut singles_memo, f, script, lang, features, vertical)
		v := gpos.single_offset_on(g.gid, lookups) or { continue }
		scale := em_px / f64(f.face.units_per_em)
		if vertical {
			if v.has_y_advance() {
				g.advance += f64(v.y_advance) * scale
			}
		} else {
			if v.has_x_advance() {
				g.advance += f64(v.x_advance) * scale
			}
		}
		// y is positive upwards in the font and downwards on the line, as in
		// kern_pairs, so it is flipped here rather than at the callers.
		if v.format & 0x0001 != 0 {
			g.x += f64(v.x_placement) * scale
		}
		if v.format & 0x0002 != 0 {
			g.y -= f64(v.y_placement) * scale
		}
	}
}
