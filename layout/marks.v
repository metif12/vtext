module layout

import vtext.shape
import vtext.font
import vtext.ucd

// mark_indices_by_cluster lists the line's marks, from the first cluster onwards,
// which is the order a stack is built in.
//
// The order is by ascending input position, not by position on the line, because a right to left
// line is drawn in the opposite order to the one it was written in and stacking order is a property
// of the writing. A mark on another mark is measured from where the mark under it ended up, so
// the mark underneath has to be placed first: the under-mark was written before the over-mark,
// so ascending input order places it first. Two marks of one character keep their line order
// between themselves, which is the one case where there is no writing order to go by.
//
// The sort is written out rather than handed to a comparison closure because a closure cannot reach
// the glyphs it would be comparing, and this is the only place in the module that needs an order
// defined against them.
pub fn mark_indices_by_cluster(glyphs []shape.Glyph) []int {
	mut marks := []int{}
	for i in 0 .. glyphs.len {
		if glyphs[i].is_mark {
			marks << i
		}
	}
	// An insertion sort by ascending cluster, which is the order a stack is built in.
	mut i := 1
	for i < marks.len {
		mut j := i
		for j > 0 && glyphs[marks[j]].cluster < glyphs[marks[j - 1]].cluster {
			marks[j], marks[j - 1] = marks[j - 1], marks[j]
			j--
		}
		i++
	}
	return marks
}

// draw_order returns the glyphs in the order they should be painted: letters first, marks
// last.
//
// position_marks moves each mark onto the letter it belongs to, using the font's own anchors.
//
// A mark has no advance, so before this it sits wherever the pen happened to be when it came
// round, which for a letter is at the baseline and at the letter's left edge. The font says
// where it should really be: the mark has an anchor, the base has one per mark class, and the
// mark goes wherever the two agree.
//
// The base is found by walking backwards in logical order, not visual order, because that is the
// order the mark was written in. In a right-to-left line the two are opposites, so looking
// backwards in visual order would attach the mark to the letter after it rather than the one it
// follows. A mark with no letter before it in its run, which happens at the start of a word
// carrying a stray vowel, is left at the pen position.
//
// The anchors are the font's own in both modes: a vertical base is the vert
// variant the substitution pass already chose, and anchors are written
// per glyph, so the same tables answer. What changes is the frame: in a
// horizontal line every base sits at the baseline and the mark's absolute
// offset lands on it, while in a vertical line the base hangs below the pen
// by the vertical origin and the mark has to hang with it — measured from
// the base rather than from zero. A vertical line with no marks is
// unaffected either way.
// A `mut` value receiver for the reason given on measure_line: `mut line &Line` as a
// parameter is a pair V 0.5.2 will not accept at a `position_marks(mut line, ...)` call.
pub fn position_marks(mut line Line, em_px f64, ctx &shape.Context, vertical bool, cps []rune, lang string) {
	// Two passes, and the order matters. The line is in visual order, and in a right-to-left
	// line a mark comes before the letter it belongs to, so collecting the letters and then
	// placing the marks in one pass would find the mark's base already behind it. Collecting
	// every letter first means a mark can look in any direction.
	mut bases := map[int][]int{}
	for i, g in line.glyphs {
		if !g.is_mark {
			bases[g.cluster] << i
		}
	}
	// The glyph ids in line order, which is what chaining contexts match
	// against. For left-to-right Southeast Asian lines visual order is
	// logical order, so the pattern reads the same glyphs HarfBuzz shaped;
	// right-to-left runs keep their logical order in the substitution pass
	// above, and marks there resolve the same way because the search below
	// is by cluster rather than by position.
	mut gids := []u16{cap: line.glyphs.len}
	for g in line.glyphs {
		gids << g.gid
	}
	// The chaining lookups for one font evaluated once, not once per mark:
	// apply_contextual walks the whole run, so running it for every mark is
	// quadratic in the mark count. Marks usually share one or two fonts, so
	// the memo holds that many entries and the perf gate pins the shape.
	mut chain_memo := []ChainMemo{}
	// The stacked pass below asks, per mark per candidate, for the best
	// cluster at or before the candidate's own — the same question with
	// the same map, answered once per glyph here instead of once per
	// (mark, candidate) pair there (F2c). The search reads only the
	// line's clusters, so hoisting it changes no answer: every stacked
	// decision below reads the precomputed value.
	mut cand_base := []int{len: line.glyphs.len}
	for k, c in line.glyphs {
		mut tb := -1
		for cluster, _ in bases {
			if cluster <= c.cluster && cluster > tb {
				tb = cluster
			}
		}
		cand_base[k] = tb
	}

	// The marks are placed from the first cluster onwards, which is the order a stack has to be
	// built in. A mark on another mark is measured from where the mark under it ended up, so the
	// mark underneath has to be placed first; placing a fatha before the shadda it rides on would
	// put the fatha at the shadda's position before the shadda had one, and the fatha
	// would then be carried along when the shadda moved.
	mut marks := mark_indices_by_cluster(line.glyphs)
	// Plain mark-attachment lists ride the same per-font memo as the
	// kern pass: mark_feature_lookups_for rebuilds them per mark
	// otherwise, and a paragraph can carry hundreds of marks.
	mut pair_memo := []GposPairLookupsMemo{}
	for oi in 0 .. marks.len {
		i := marks[oi]
		g := line.glyphs[i]
		f := g.font or { continue }
		// The base is the letter the mark was written after, which is the nearest one with a
		// smaller input position. Searching by cluster rather than by position on the line is
		// what makes this work in both directions, and it also steps over a ligature or a
		// discarded control that sits between the two.
		//
		// The search is over the clusters that are present rather than over a fixed range, so
		// a mark whose letter was dropped from the line finds nothing and stays at the pen.
		//
		// A mark decomposed from the same original character as its base shares that base's
		// cluster — U+0622 splits to U+0627 plus U+0653, and both report cluster 47 — so the
		// comparison is <= rather than <. This is safe because bases holds only non-marks and
		// the mark being placed is a mark: it can never select itself, only the letter it came
		// from.
		//
		// The search runs before stacking because the script comes from the letter: the font
		// writes its anchors against the base letter, and the mark rules live under the base's
		// script. A mark with no letter base keeps 'arab', which is what every mark used
		// before scripts were asked. Moving the search changes no decision here: both searches
		// only read the line.
		mut win := -1
		for cluster, _ in bases {
			if cluster <= g.cluster && (win < 0 || cluster > win) {
				win = cluster
			}
		}
		// Within the winning cluster the base is the nearest letter before
		// the mark in run order (line order within one cluster is run
		// order): a merged syllable holds several bases under one cluster,
		// and the flag after a conjunct belongs to the conjunct, not to
		// the matra after it. A mark before every letter of its cluster
		// keeps the last one, which is what every line laid out before
		// this tie-break.
		mut base_index := -1
		mut best := 0
		if win >= 0 {
			best = win
			for ci in bases[win] {
				if ci < i && (base_index < 0 || ci > base_index) {
					base_index = ci
				}
			}
			if base_index < 0 {
				cands := bases[win]
				base_index = cands[cands.len - 1]
			}
		}
		mut script := 'arab'
		if base_index >= 0 {
			cand := line.glyphs[base_index]
			if bf := cand.font {
				if bf == f {
					script = mark_script(ctx.properties, f, cand, cps)
				}
			}
		}
		// The nearest preceding mark, which is what stacking means. A shadda carrying a fatha is
		// the case: the fatha belongs to the shadda, and the font says where on the shadda in a
		// different table from the one that places marks on letters. A mark whose nearest mark the
		// font will not attach to falls through to the letter below, which is the degraded answer
		// rather than a wrong one: a font with no mark-to-mark rule places both against the
		// letter, and so did this engine before it could read that rule.
		//
		// Two glyphs of one input character are skipped rather than treated as a target for each
		// other, so a character a substitution split into several glyphs does not stack one of
		// them on another.
		//
		// A mark decomposed from the same character as its base shares that base's cluster, and
		// it belongs on that base — not stacked on a distant mark that happens to have a smaller
		// cluster. U+0622 splits to U+0627 plus U+0653, both cluster 47, and without this the madda
		// stacks on whatever earlier mark the font will attach it to, hundreds of pixels from its
		// alef. A mark whose own cluster has a letter base skips stacking.
		// A mark stacks only on a mark of its own syllable: the nearest letter
		// base at or before the target must be the mark's own base. Without
		// this the Thai SARA II (on ด) stacks on MAI HAN AKAT (on ว) through
		// a rule the font wrote for two marks on one base, landing mid-word
		// where HarfBuzz leaves it at the pen. A shadda carrying a fatha
		// passes: both answer the beh. A mark whose own cluster has a letter
		// base skips stacking as before.
		mut stacked_at := []int{}
		if base_index >= 0 && g.cluster !in bases {
			for k, c in line.glyphs {
				if k == i || !c.is_mark || c.cluster == g.cluster || c.cluster >= g.cluster {
					continue
				}
				if cand_base[k] != best {
					continue
				}
				stacked_at << k
			}
			// Highest cluster first: the mark stacks on the nearest mark
			// below it, and a farther one only when the nearer has no rule
			// for it — the tra candrabindu stacks on the flag, whose rule
			// names it, rather than on the nearer rakar, which has none
			// for it. An insertion sort, stable for equal clusters.
			for a in 1 .. stacked_at.len {
				mut b := a
				for b > 0
					&& line.glyphs[stacked_at[b]].cluster > line.glyphs[stacked_at[b - 1]].cluster {
					stacked_at[b], stacked_at[b - 1] = stacked_at[b - 1], stacked_at[b]
					b--
				}
			}
		}
		mut stacked := false
		for sk in stacked_at {
			target := line.glyphs[sk]
			// A mark and the mark under it have to come from the same font, as below.
			stack_font := g.font or { break }
			stack_target_font := target.font or { continue }
			if stack_font != stack_target_font {
				continue
			}
			if stack_gpos := stack_font.face.gpos {
				lk := gpos_pair_lookups_for(mut pair_memo, stack_font, script, lang)
				if off := stack_gpos.mark_offset_on(g.gid, target.gid, true, lk.marks) {
					// The stack rides the mark underneath in both modes: x
					// and y carry the under-mark's, then the attachment
					// moves the over-mark from there. Dropping the
					// under-mark's y parks every stacked mark at the
					// baseline instead of on its own mark.
					stack_scale := em_px / f64(stack_font.face.units_per_em)
					line.glyphs[i].x = target.x + f64(off.x) * stack_scale
					line.glyphs[i].y = target.y - f64(off.y) * stack_scale
					apply_mark_chain(mut line, i, gids, stack_font, em_px, script, lang, mut chain_memo)
					stacked = true
					break
				}
			}
		}
		if stacked {
			continue
		}
		if base_index < 0 {
			continue
		}
		base := line.glyphs[base_index]
		base_font := base.font or { continue }
		// The glyphs have to come from the same font for an anchor in one to mean anything in
		// the other. A line that fell back mid-word has marks in a different font from their
		// base, and there is no correct answer, so the mark stays at the pen.
		if f != base_font {
			continue
		}
		mut anchor := shaped_mark_offset(f, g.gid, base, script, lang, gpos_pair_lookups_for(mut pair_memo, f, script, lang).marks) or {
			continue
		}
		// The offset is in design units and the line is in pixels, so it is scaled by the same
		// ratio the advances came from.
		scale := em_px / f64(f.face.units_per_em)
		line.glyphs[i].x = base.x + f64(anchor.x) * scale
		// y is positive upwards in the font's coordinates and downwards on a line, so the sign
		// is flipped here rather than leaving every caller to remember. In a
		// vertical line the flip is measured from the base, which hangs below
		// the pen by the vertical origin: from zero the mark would land a whole
		// origin above its letter.
		if vertical {
			line.glyphs[i].y = base.y - f64(anchor.y) * scale
		} else {
			line.glyphs[i].y = -f64(anchor.y) * scale
		}
		apply_mark_chain(mut line, i, gids, f, em_px, script, lang, mut chain_memo)
	}
}

// mark_chain_offset answers the chaining SinglePos adjustment for one mark,
// which is the GPOS half beyond anchors.
//
// Anchors place the mark; chains move it further. Thai SARA U after 0331
// drops 150 design units through the dist chain, and Khmer above-marks
// shift after a subscript through the abvm/blwm chains, and HarfBuzz sums
// both. The adjustment is read off the chaining lookups the run's script
// names (mark, mkmk, abvm, blwm, kern and dist alike) through the same
// apply_contextual path the tests pin, then filtered to SinglePos records
// for this mark: a chain that names a pair lookup carries no placement for
// a lone mark and is skipped. PairPos kerns fold into advances elsewhere
// and have no meaning for a zero-advance mark. A mark with no chain rule
// answers none, which is every line laid out before this pass.
// ChainMemo holds one chaining evaluation for one font in one line: the
// full run matched once, then filtered per mark. See position_marks.
struct ChainMemo {
	font_ptr voidptr
	script   string
	lang     string
	apps     []font.ChainApplication
}

// chain_apps_for answers the chaining applications for this font, script
// and language, evaluating once and memoizing. Every mark in a run shares
// the same glyph ids, so recomputing per mark repeats the whole run walk
// once per mark; the memo keeps the first answer for the rest of the line.
fn chain_apps_for(mut memo []ChainMemo, f &shape.Font, gpos &font.Gpos, gids []u16, script string, lang string) []font.ChainApplication {
	key := voidptr(f)
	for m in memo {
		if m.font_ptr == key && m.script == script && m.lang == lang {
			return m.apps
		}
	}
	apps := gpos.apply_contextual(gids, script, lang, f.face.gdef)
	memo << ChainMemo{ font_ptr: key, script: script, lang: lang, apps: apps }
	return apps
}

fn mark_chain_offset(gpos &font.Gpos, mark_gid u16, at int, apps []font.ChainApplication) ?font.Offset2 {
	mut x := 0
	mut y := 0
	mut found := false
	for app in apps {
		if app.at != at {
			continue
		}
		if app.lookup >= gpos.lookups.len {
			continue
		}
		for single in gpos.lookups[app.lookup].singles {
			if off := single.offset_for(mark_gid) {
				x += off.x
				y += off.y
				found = true
				break
			}
		}
	}
	if !found {
		return none
	}
	return font.Offset2{ x: x, y: y }
}

// apply_mark_chain composes a chaining SinglePos adjustment over a mark's
// anchor placement: it adds the mark_chain_offset answer onto the placed
// mark, or does nothing when the run's chains name no SinglePos for it.
fn apply_mark_chain(mut line Line, at int, gids []u16, f &shape.Font, em_px f64, script string, lang string, mut memo []ChainMemo) {
	if at < 0 || at >= line.glyphs.len {
		return
	}
	gpos := f.face.gpos or { return }
	apps := chain_apps_for(mut memo, f, gpos, gids, script, lang)
	mark_gid := line.glyphs[at].gid
	off := mark_chain_offset(gpos, mark_gid, at, apps) or { return }
	scale := em_px / f64(f.face.units_per_em)
	line.glyphs[at].x += f64(off.x) * scale
	line.glyphs[at].y += -f64(off.y) * scale
}

// shaped_mark_offset finds a mark's anchor offset, resolving across the joining-route
// boundary the engine deliberately straddles: it draws presentation forms by cmap lookup,
// but anchors are written against base letters and GSUB joining outputs, never against
// presentation forms.
//
// The cascade is presentation glyph, then GSUB glyph of the same shape, then base
// letter. The middle step is the one that matters: the base letter's anchor is the
// isolated shape's number, but the drawn glyph may be initial, medial or final, whose
// anchors differ by hundreds of units — kasra on beh is 276 on the base but -133 on
// the initial form in Amiri lookup 50, and HarfBuzz reads the -133. Asking the font's
// joining tables for the glyph of the base's own shape recovers the number HarfBuzz
// reads. base_gid is only ever set on the Arabic presentation-form path, so 'arab' is
// that path's own script rather than a guess; a font with no such rule answers the
// base glyph and the last step behaves as before.
pub fn shaped_mark_offset(f &shape.Font, mark_gid u16, base shape.Glyph, script string, lang string, lookups []u16) ?font.Offset2 {
	gpos := f.face.gpos or { return none }
	if off := gpos.mark_offset_on(mark_gid, base.gid, false, lookups) {
		return off
	}
	if base.base_gid == 0 {
		return none
	}
	shaped := f.shaped_glyph_index(base.base_gid, base.form, 'arab', lang)
	if shaped != base.base_gid {
		if off := gpos.mark_offset_on(mark_gid, shaped, false, lookups) {
			return off
		}
	}
	return gpos.mark_offset_on(mark_gid, base.base_gid, false, lookups)
}

// mark_script resolves the script whose mark rules place this mark: the script of the
// letter it belongs to, read off the base glyph. A combining mark on its own is
// inherited script and answers nothing; the base letter's codepoint is what the font
// wrote its anchors against.
//
// A base with no script of its own — Common, Inherited or Unknown, the dotted circle
// a dakuten sits on — resolves to the neighbouring strong script instead of falling
// back to arab: the mark sits among that script's letters, and the font wrote the
// anchors it needs under that script. The neighbours are read in logical order,
// preceding first, because a mark follows its base. With no strong character on
// either side the answer keeps arab, which is what every mark used before scripts
// were asked, so nothing that placed before moves.
pub fn mark_script(props &ucd.Properties, f &shape.Font, base shape.Glyph, cps []rune) string {
	gid := if base.base_gid != 0 { base.base_gid } else { base.gid }
	if cp := f.codepoint_for(gid) {
		tag := props.script_tag_of(cp)
		if tag != 'Zzzz' && tag != 'Zinh' && tag != 'Zyyy' {
			return tag
		}
	}
	return neighbour_script(props, cps, base.cluster)
}

// neighbour_script is the strong script around an input position: the nearest
// character in logical order whose script is its own, preceding first, then
// following. A position with no strong neighbour keeps arab, the historical
// default, rather than inventing one.
pub fn neighbour_script(props &ucd.Properties, cps []rune, at int) string {
	for i := at - 1; i >= 0; i-- {
		tag := props.script_tag_of(cps[i])
		if tag != 'Zzzz' && tag != 'Zinh' && tag != 'Zyyy' {
			return tag
		}
	}
	for i := at + 1; i < cps.len; i++ {
		tag := props.script_tag_of(cps[i])
		if tag != 'Zzzz' && tag != 'Zinh' && tag != 'Zyyy' {
			return tag
		}
	}
	return 'arab'
}
