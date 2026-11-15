module layout

import vtext.shape
import vtext.font
import vtext.ucd

// Line layout: shaped codepoints in, positioned glyphs out.
//
// The passes before this one each know about one thing. Normalization knows about canonical
// equivalence, the bidirectional pass about direction, joining about a letter's shape. None
// of them knows about pixels, and none of them can be reordered relative to the others: the
// order a letter is shaped in is the order it was written in, and the order it is drawn in
// may be the other way round. This module is where those separate orders meet.
//
// It runs the whole pipeline for one paragraph and returns the glyphs left to right, which
// is the order a caller can draw in without knowing anything about direction.

// Line is a laid out paragraph: positioned glyphs, left to right in horizontal
// mode, top to bottom down one column in vertical mode.
//
// A vertical line is one column, not a page: breaking text across columns and
// stacking them right to left is the caller's work, and this is what it stacks
// with — width is the column's width, height its length, and line_height the
// stacking step, so columns go leftward by line_height each.
pub struct Line {
pub mut:
	// glyphs are the drawable glyphs in visual order: left to right in
	// horizontal mode, top to bottom in vertical mode. A combining mark
	// shares the position of the letter it sits on, so a mark and its base are both present and
	// both at the same place.
	glyphs []shape.Glyph
	// width is the total advance of the line in pixels, marks included, which for a mark is
	// nothing. In vertical mode it is the column's width instead: the largest
	// horizontal advance among the glyphs, which is the full em for full-width
	// CJK and what the next column steps left by.
	width f64
	// height is the column's length in pixels: the pen's final y, the sum of the
	// vertical advances. Zero in horizontal mode, where width plays this role.
	height f64
	// ascent and descent are the vertical extent of the line in pixels, taken from the
	// tallest font that contributed a glyph, with any mark that reaches above or below it.
	ascent  f64
	descent f64
	// paragraph_level is the resolved direction as a level: even is left to right, odd is
	// right to left.
	paragraph_level u8
	// line_height is the resolved baseline-to-baseline distance in pixels: the caller's
	// LayoutOptions.line_height when there is one, and otherwise the largest natural line height
	// among the fonts that contributed a glyph.
	//
	// It is a field because the caller stacks lines by it and there was no way to ask for it. The two
	// were separate numbers before, which is how every example in this repository ended up stacking by
	// `line.ascent + line.descent` and calling it line height: that is the ink's extent, not the
	// distance between two baselines, and the two differ by the font's line gap.
	//
	// It is deliberately not folded into ascent and descent. Those are the extent of the ink and of the
	// font's own metrics, and they stay that way: a caller asking for a line height below the glyphs
	// gets the smaller number here and clips the ink itself, because an engine that shrank the ascent to
	// fit a request would be reporting a box it cannot measure.
	line_height f64
}

// LayoutOptions are the choices about a line that belong to the caller rather than to the engine.
//
// The default is the one every other shaper defends: calt, liga and clig on, everything
// else off, so the line is the text as drawn everywhere. A text engine that fused nothing
// while every editor fused `=>` could not be relied on to measure code, and one that fused
// discretionary pairs on the caller's behalf could not be relied on to measure anything.
//
// What is not here is a direction. That is the base_dir argument of layout_paragraph and its
// siblings, and adding it here as well would leave two sources for one decision with no stated
// precedence, which is the kind of thing that works until a caller sets the one that is ignored.
pub struct LayoutOptions {
pub mut:
	// features are the discretionary OpenType features to apply after the required ones, which
	// the engine always applies. calt, liga and clig are already on — the code ligatures and
	// the Persian pairs — so a `-tag` entry turns one of those back off (`-calt` draws `=>`
	// as two plain glyphs) and `+tag` is the same as naming the tag.
	features []string
	// line_height is the baseline-to-baseline distance in pixels. Zero takes the font's own, which
	// is the largest natural line height among the fonts that contributed a glyph.
	//
	// A value smaller than the glyphs are tall does not shrink them. It reports the smaller box and
	// the caller decides what to clip, which is the same answer every layout engine gives and the
	// only one that can be right without knowing what the caller will draw.
	line_height f64
	// letter_spacing is added to the advance of every letter, in pixels. It can be negative, which
	// is how a caller tightens a line.
	//
	// A combining mark is not a letter and gets nothing: it shares its base's position and has no
	// advance of its own, so spacing one as well would apply the same letter spacing twice to one
	// character.
	letter_spacing f64
	// word_spacing is added to the advance of every space, in pixels, on top of letter_spacing.
	//
	// Only the line break class UAX #14 calls a space counts, which is U+0020 and the space
	// separators, not a tab or a newline. A newline ends the paragraph and a tab is rare enough in
	// running text that treating it as a word separator would be a surprise.
	word_spacing f64
	// vertical selects vertical writing: the engine collects the font's vert
	// variants for the run and places the line downward as one column. Each
	// glyph's advance box goes at x 0 with y accumulating by vertical
	// advances, so Line.width is the column width, Line.height its length, and
	// Line.line_height the step the next column stacks left by. What this is
	// not: glyphs are placed by advance box, not centered on the vertical
	// origin the way HarfBuzz offsets them, and marks keep their horizontal
	// anchors — centering and vertical mark positioning are the next slices.
	// wrap_paragraph_with cuts the column into columns of a given height the
	// way it cuts a line into lines of a given width.
	vertical bool
}

// layout_paragraph runs normalization, the bidirectional algorithm and Arabic joining over
// cps, maps the result to glyphs through fs, and positions the glyphs on one line at em_px.
//
// base_dir drives rules P2 and P3 of the bidirectional algorithm: .auto takes the
// direction from the first strong character, which is what a caller usually wants for a
// line of unknown language.
//
// No discretionary features are applied. Use layout_paragraph_with to ask for any.
pub fn layout_paragraph(ctx &shape.Context, cps []rune, base_dir shape.Direction, fs &shape.FontSet,
	em_px f64) Line {
	return layout_paragraph_with(ctx, cps, base_dir, fs, em_px, &LayoutOptions{})
}

// layout_paragraph_with is layout_paragraph with the caller's options applied.
pub fn layout_paragraph_with(ctx &shape.Context, cps []rune, base_dir shape.Direction, fs &shape.FontSet,
	em_px f64, options &LayoutOptions) Line {
	// Joining keys on joining types, and a precomposed character is a different codepoint
	// with a different one, so the text has to be decomposed before it is shaped. The
	// marks this separates are the ones the layout pass later has to place.
	//
	// The mapping comes back with the text because decomposition changes both the length and the
	// order of it: a shadda written after a fatha is moved ahead of it, because canonical ordering
	// puts the lower combining class first, and a shadda is a higher one. Without the mapping the
	// two marks would report each other's input positions, and a mark would then be looked for
	// against the wrong letter.
	decomposed, origin := ctx.normalizer.nfd_mapped(cps)

	bidi := shape.resolve_paragraph(ctx.properties, decomposed, base_dir)

	// Shape each isolating run sequence on its own, then look the shaped codepoints up. The
	// result is in logical order still, tagged with the input character each glyph came
	// from, because that tag is the only thing that survives reordering.
	mut placed := []shape.Glyph{cap: decomposed.len}
	for seq in bidi.sequences {
		// The bidi pass takes X9-shape.removed characters out of its sequences, and a zero
		// width non-joiner is one of them — its bidi class is BN. But joining has to
		// see it: it breaks the join where it sits, which is its whole purpose, and a
		// نیم‌فاصله shaped without it comes out joined. So the non-joiners shape.removed
		// between two kept characters go back in for shaping; the shaping loop drops
		// them from its output, so they never become glyphs and the line is unchanged
		// apart from the shapes on either side. sub_idx maps each shaped position back
		// to the decomposed text, which is what the cluster mapping below reads
		// instead of the sequence. A joiner is deliberately not restored: unlike the
		// non-joiner it is drawn as itself when shaped, so restoring it would add a
		// glyph the line does not have today, and its join-forcing stays a known gap.
		mut sub := []rune{cap: seq.len}
		mut sub_idx := []int{cap: seq.len}
		for k, i in seq {
			if k > 0 {
				for r in seq[k - 1] + 1 .. i {
					if decomposed[r] == shape.zero_width_non_joiner {
						sub << decomposed[r]
						sub_idx << r
					}
				}
			}
			sub << decomposed[i]
			sub_idx << i
		}
		shaped := ctx.shaper.shape_arabic(ctx.properties, sub)
		mut run := []shape.Glyph{}
		// The script of the run, which is what the font resolves its features
		// under. It is the first script that names one rather than the first
		// glyph's: Common, Inherited and Unknown have no features of their own,
		// so a run that opens with a comma or a digit would otherwise resolve
		// none, and HarfBuzz itemizes the same run under its strong script.
		mut script := 'arab'
		if shaped.glyphs.len > 0 {
			script = shaped.glyphs[0].script
			for g in shaped.glyphs {
				if g.script != 'Zyyy' && g.script != 'Zinh' && g.script != 'Zzzz' {
					script = g.script
					break
				}
			}
		}
		for g in shaped.glyphs {
			// A shaped index counts the restored non-joiners too, so it is an offset
			// into sub_idx rather than into the sequence; without a restoration the
			// two are the same list.
			//
			// One shaped letter can become more than one glyph, which is what happens to a
			// lam-alef in a font with no ligature form. Each of those glyphs is tagged with
			// the input character it stands for, so the two are traced back to the lam and
			// the alef separately.
			for j, mut out in fs.shaped_glyphs(ctx, g, em_px) {
				// The cluster is an index into the caller's text, not into the decomposed one. Going
				// through the decomposition's own mapping is what makes a mark report the character
				// it was written after rather than whichever character canonical ordering happened
				// to put next to it.
				offset := g.start + j
				mut cluster := sub_idx[g.start]
				if offset < sub_idx.len {
					decomposed_at := sub_idx[offset]
					if decomposed_at < origin.len {
						cluster = origin[decomposed_at]
					}
				}
				out.cluster = cluster
				run << out
			}
		}
		// The font's own substitutions, before anything is placed. A ligature or a mark
		// composition is a property of the text's order, not of where it ends up on the line, so
		// it has to happen while the run is still in logical order. Kerning goes through the
		// same path for the same reason, and it needs the run's direction: the kern folds
		// into the advance of the visually first glyph of the pair.
		rtl := seq.len > 0 && bidi.levels[seq[0]] & 1 == 1
		mut run_glyphs := substitute_in_fonts(run, em_px, script, options.features, options.vertical, rtl)
		// The vertical swap runs per run rather than over the whole line, because the
		// vertical kern that follows it needs the run's script and must not cross a
		// run boundary: a pair from two scripts has no single table to ask. The swap
		// is what the kern folds into, so it comes first, and the global pass below
		// must not run again and discard the fold.
		if options.vertical {
			apply_vertical_advances(mut run_glyphs, em_px)
			vkern_pairs(mut run_glyphs, em_px, script, rtl)
			single_positions(mut run_glyphs, em_px, script, options.features, true)
		}
		for glyph in run_glyphs {
			placed << glyph
		}
	}

	// Spacing goes onto the advances before anything is positioned, rather than onto the positions
	// afterwards. place_glyphs walks the run accumulating advances into x, and measure_line takes
	// the line's width from those same positions, so a pass that changed advances alone is picked up
	// by both with no second walk and no chance of the width and the positions disagreeing.
	// Spacing adds onto the advances the swap and the vertical kern settled, exactly as in
	// horizontal mode, where it adds onto the advances the horizontal kern settled.
	apply_spacing(mut placed, ctx.properties, cps, options.letter_spacing, options.word_spacing)

	mut line := Line{
		glyphs:          if options.vertical {
			place_glyphs_vertical(placed, bidi, origin, em_px)
		} else {
			place_glyphs(placed, bidi, origin)
		}
		paragraph_level: bidi.paragraph_level
	}
	position_marks(mut line, em_px, ctx, options.vertical, cps)
	if options.vertical {
		measure_vertical_line(mut line, em_px, options)
	} else {
		measure_line(mut line, em_px, options)
	}
	return line
}

// apply_spacing adds the caller's letter and word spacing to the run's advances.
//
// It runs on the shaped run before place_glyphs, and it edits advance rather than x. See the comment at
// the call site for why the order and the choice of field are the two that matter.
pub fn apply_spacing(mut glyphs []shape.Glyph, props &ucd.Properties, cps []rune, letter_spacing f64,
	word_spacing f64) {
	if letter_spacing == 0.0 && word_spacing == 0.0 {
		return
	}
	for mut g in glyphs {
		// A mark is not a letter. It sits on its base and has no advance, so adding one would not
		// move the mark and would push everything after it along by the letter spacing of a
		// character the base has already been paid for.
		if g.is_mark {
			continue
		}
		g.advance += letter_spacing
		if word_spacing != 0.0 && is_space_at(props, cps, g.cluster) {
			g.advance += word_spacing
		}
	}
}

// is_space_at reports whether the input character at index i is one word spacing applies to.
//
// The test is the pipeline's own line break class rather than a hard-coded rune, for the same reason
// pick_in uses the pipeline's script table: one answer to "which characters are spaces" is worth more
// than two that can drift. The cluster is an index into the caller's own text, not into the
// decomposed one, because layout mapped it back through the decomposition when it set it.
pub fn is_space_at(props &ucd.Properties, cps []rune, i int) bool {
	if i < 0 || i >= cps.len {
		return false
	}
	return props.line_break_of(cps[i]) == .sp
}

// substitute_in_fonts hands each stretch of the run that came from one font to that font.
//
// A substitution cannot straddle two fonts, because a glyph index in one font means nothing in
// another. A line that fell back mid-word therefore has its rules stop at the seam, and the two
// letters a ligature would have fused are drawn apart. That is the honest answer for a line whose
// characters came from different fonts: there is no single glyph to draw them as, and a mark
// composition that needs the letter before it is out of reach for the same reason.
pub fn substitute_in_fonts(glyphs []shape.Glyph, em_px f64, script string, features []string,
	vertical bool, rtl bool) []shape.Glyph {
	if glyphs.len == 0 {
		return glyphs
	}
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
		for glyph in f.substitute_glyphs(glyphs[at..end], script, em_px, features, vertical) {
			out << glyph
		}
		at = end
	}
	// Horizontal pair offsets have no meaning for a downward pen: the advance
	// they fold into is overwritten by the vertical swap, and the y they fold
	// is the horizontal baseline's. Vertical pairs apply after the swap, per
	// run at the call site, so this pass skips kerning entirely in vertical
	// mode rather than folding a number the swap is about to discard.
	if !vertical {
		kern_pairs(mut out, em_px, script, rtl)
		single_positions(mut out, em_px, script, features, false)
	}
	return out
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

// kern_pairs folds the font's pair positioning into advances, after every substitution
// has run so the pairs are the glyphs the font's rules are written against.
//
// Only plain adjacency is considered: same font on both sides, no marks in the pair.
// A mark between two letters is left to the lookups' own flags, which this does not
// second-guess, and a fallback seam has no single table to ask.
//
// The kern folds into the advance of the visually first glyph of the pair — the first
// logical glyph going left to right, the second going right to left — which is where
// HarfBuzz reports it: AV tightens A's advance, and e-f in an RTL run tightens f's.
pub fn kern_pairs(mut glyphs []shape.Glyph, em_px f64, script string, rtl bool) {
	if glyphs.len < 2 {
		return
	}
	mut gids := []u16{cap: glyphs.len}
	for g in glyphs {
		gids << g.gid
	}
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
		off := fa.context_placement(gids, i, i + 1, script) or { continue }
		scale := em_px / f64(fa.face.units_per_em)
		// y is positive upwards in the font and downwards on the line, as in
		// position_marks, so it is flipped here rather than at the callers.
		if rtl {
			glyphs[i + 1].advance += f64(off.x) * scale
			glyphs[i + 1].y -= f64(off.y) * scale
		} else {
			glyphs[i].advance += f64(off.x) * scale
			glyphs[i].y -= f64(off.y) * scale
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
pub fn vkern_pairs(mut glyphs []shape.Glyph, em_px f64, script string, rtl bool) {
	if glyphs.len < 2 {
		return
	}
	mut gids := []u16{cap: glyphs.len}
	for g in glyphs {
		gids << g.gid
	}
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
		off := fa.vkern_offset(a.gid, b.gid, script) or { continue }
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
pub fn single_positions(mut glyphs []shape.Glyph, em_px f64, script string, features []string,
	vertical bool) {
	for mut g in glyphs {
		if g.is_mark {
			continue
		}
		f := g.font or { continue }
		v := f.single_adjustment(g.gid, script, features, vertical) or { continue }
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

// place_glyphs positions the glyphs on the line in visual order.
//
// Rule L2 of the bidirectional algorithm gave a permutation of the input characters, not of
// the glyphs, and the two are not the same list: a lam-alef is one glyph standing for two
// characters, and a mark is a glyph for a character that a letter does not cover. So the
// permutation is walked and each character is asked for its glyph, which draws out exactly
// one glyph per character that has one and passes over the ones a glyph already drawn
// stands for.
pub fn place_glyphs(placed []shape.Glyph, bidi shape.BidiResult, origin []int) []shape.Glyph {
	mut out := []shape.Glyph{cap: placed.len}
	mut by_cluster := map[int][]int{}
	for i, g in placed {
		// A character can own more than one glyph, which is what a substitution that splits one
		// character into several produces, so this holds every glyph of a character rather than the
		// first. The order they were placed in is kept, because a split character is drawn in the
		// order the font wrote its replacement sequence.
		by_cluster[g.cluster] << i
	}

	// visual_order holds indices into the decomposed text, because bidi runs after NFD, but
	// by_cluster is keyed by the caller's original clusters. When NFD changes the length —
	// a precomposed character splitting into two — the two numberings drift, and looking up
	// a decomposed index as an original cluster puts every glyph after the split one position
	// off. Going through origin is what keeps them aligned: origin[v] is the original character
	// the decomposed character at v came from. Without this, the first character of a Latin run
	// after a decomposed Arabic word is drawn as if it belonged to the Arabic run on its right.
	//
	// And because two decomposed characters can come from one original, the same cluster can be
	// reached twice while walking the visual order. The first visit draws it; the second is
	// skipped, because drawing it again would stack the same glyph twice at two positions.
	mut x := f64(0)
	mut drawn := map[int]bool{}
	for v in bidi.visual_order {
		if !bidi.visible[v] {
			continue
		}
		orig := if v < origin.len { origin[v] } else { v }
		if drawn[orig] {
			continue
		}
		drawn[orig] = true
		indices := by_cluster[orig] or { continue }
		for i in indices {
			mut g := placed[i]
			// The pen accumulates rather than assigns, because a glyph may already
			// carry its single positioning shift from the pass before this one.
			// Every glyph enters with x holding only that shift (marks enter zero,
			// since the pass skips them), so adding keeps both.
			g.x += x
			out << g
			x += g.advance
		}
	}
	return out
}

// place_glyphs_vertical positions the glyphs down one column in visual order.
//
// It mirrors place_glyphs with the axes swapped: y accumulates the vertical
// advances from 0 and every glyph's advance box is centered in the column
// rather than sharing a left edge, because a half-width letter in a full-width
// column draws mid-column — HarfBuzz reports half the horizontal advance less
// of an x offset for it than for its full-width neighbours. The walk, the
// cluster mapping and the drawn-twice guard are the same, because a vertical
// line reorders the same way a horizontal one does — direction still runs
// along the line, and the line now runs down.
pub fn place_glyphs_vertical(placed []shape.Glyph, bidi shape.BidiResult, origin []int, em_px f64) []shape.Glyph {
	// The column is as wide as its widest advance box, the same width the
	// measure pass reports, and centering is against it: a full-width glyph
	// lands at 0 and a narrower one lands mid-column. It is read before
	// placing because placing is what consumes it.
	mut width := f64(0)
	for g in placed {
		if g.is_mark {
			continue
		}
		if f := g.font {
			width = larger(width, f.glyph_advance(g.gid, em_px))
		}
	}
	mut out := []shape.Glyph{cap: placed.len}
	mut by_cluster := map[int][]int{}
	for i, g in placed {
		by_cluster[g.cluster] << i
	}

	mut y := f64(0)
	mut drawn := map[int]bool{}
	for v in bidi.visual_order {
		if !bidi.visible[v] {
			continue
		}
		orig := if v < origin.len { origin[v] } else { v }
		if drawn[orig] {
			continue
		}
		drawn[orig] = true
		indices := by_cluster[orig] or { continue }
		for i in indices {
			mut g := placed[i]
			// Marks keep the column's left edge until anchors place them: they
			// have no advance box to center, and centering one would move the
			// mark the anchor math then measures from.
			//
			// The shift the pass before this one left in x and y is saved first,
			// because the assignments below would otherwise discard it: the pen
			// and the centering accumulate onto it, the way the horizontal pass
			// accumulates onto x. Marks enter zero, since that pass skips them,
			// so saving changes nothing for them.
			sx := g.x
			sy := g.y
			g.x = 0
			g.y = y
			if !g.is_mark {
				if f := g.font {
					g.x = sx + (width - f.glyph_advance(g.gid, em_px)) / 2.0
					// The vertical origin hangs the glyph below the pen, the
					// way the horizontal origin sits left of the ink: HarfBuzz
					// reports the same negative y offset for every glyph of a
					// VORG-less face, equal to the vhea ascender. A font with
					// no vertical metrics leaves y at the pen, the way it
					// keeps the horizontal advance — the fallback is unshifted.
					if f.has_vertical_metrics() {
						g.y = y + sy - f.vertical_origin_y(g.gid, em_px)
					} else {
						g.y = y + sy
					}
				}
			}
			out << g
			y += g.advance
		}
	}
	return out
}

// measure_vertical_line fills in a vertical line's column geometry: width is
// the stacking step, height the column's length.
//
// The width is the largest horizontal advance among the contributing glyphs,
// the way the horizontal line height is the largest natural one among its
// contributors: a column that fell back mid-line is spaced for the widest face
// in it rather than the first. The height is the furthest the pen reached,
// the same definition the horizontal width uses. Ascent and descent stay zero:
// the column's vertical extent is its height, and the horizontal ink metrics
// measure the wrong axis.
pub fn measure_vertical_line(mut line Line, em_px f64, options &LayoutOptions) {
	for g in line.glyphs {
		if g.is_mark {
			continue
		}
		if f := g.font {
			line.width = larger(line.width, f.glyph_advance(g.gid, em_px))
		}
		line.height = larger(line.height, g.y + g.advance)
	}
	line.line_height = if options.line_height > 0.0 { options.line_height } else { line.width }
}

// measure_line fills in the line's width and vertical extent.
//
// A line can be drawn from more than one font, and the fonts need not agree on how tall they
// are, so the extent is the largest of the contributors rather than the first one's. A mark
// that has been moved up onto its letter can reach above the font's own ascent, which is what
// makes a fatha stick out of the line box, so the marks are measured too.
//
// The line height is resolved here rather than left to the caller because it depends on which fonts
// contributed, and only this loop knows that. The caller's value wins outright when there is one; the
// natural value is the largest over the contributors, so a paragraph that fell back mid-line is
// spaced for the tallest face in it rather than the first.
// A `mut` value receiver, not `mut line &Line`. V 0.5.2 computes the argument for a
// pointer parameter as `&&Line` at a call site written `measure_line(mut line, ...)`, and
// refuses the pair outright: "cannot use `vtext.Line` as `&&vtext.Line`". A value
// receiver is what the rest of this file already uses (`fn (mut lx Lexer) next`) and it
// does propagate the mutation to the caller's `mut` local.
pub fn measure_line(mut line Line, em_px f64, options &LayoutOptions) {
	mut natural := f64(0)
	for g in line.glyphs {
		line.width = larger(line.width, g.x + g.advance)
		if f := g.font {
			line.ascent = larger(line.ascent, f.ascent(em_px))
			line.descent = larger(line.descent, f.descent(em_px))
			natural = larger(natural, f.line_height(em_px))
			// The bitmap's top is how far the ink reaches ABOVE the baseline and its height is how
			// tall the box is, so the box spans from `top` above the baseline down to
			// `top - height` — which is below it exactly when the glyph has a descender.
			//
			// This used to add the two, so the ascent was the top of the ink plus the whole height
			// of it, and the descent was the top of the ink read as though it were a depth. Measured on
			// Segoe UI at 16 pixels, "Hxbdfpq" reported 26 above the baseline and 13 below when the
			// ink is 13 above and 4 below: a line box two and a third times the size of the em it was
			// drawn at, and every example in this repository sizes its canvas from it.
			//
			// A glyph whose ink stops above the baseline gives a negative depth, which is harmless
			// because the descent starts at zero and only ever grows.
			bmp := f.face.box_only(g.gid, em_px)
			if !bmp.is_empty() {
				line.ascent = larger(line.ascent, g.y + f64(bmp.top))
				line.descent = larger(line.descent, f64(bmp.height) - g.y - f64(bmp.top))
			}
		}
	}
	line.line_height = if options.line_height > 0.0 { options.line_height } else { natural }
}

// mark_indices_by_cluster lists the line's marks, from the last cluster backwards,
// which is the order a stack is built in.
//
// The order is by descending input position, not by position on the line, because a right to left
// line is drawn in the opposite order to the one it was written in and stacking order is a property
// of the writing. Two marks of one character keep their line order between themselves, which is the
// one case where there is no writing order to go by.
//
// The sort is written out rather than handed to a comparison closure because a closure cannot reach
// the glyphs it would be comparing, and this is the only place in the module that needs an order
// defined against them.
//
// This used to carry two stacked copies of this comment, the first of which said the order was by
// ascending input position. The code sorts descending and always did, so the first copy described the
// opposite of what happened and the second copy described it correctly; two comments, one of them
// wrong, is worse than one.
pub fn mark_indices_by_cluster(glyphs []shape.Glyph) []int {
	mut marks := []int{}
	for i in 0 .. glyphs.len {
		if glyphs[i].is_mark {
			marks << i
		}
	}
	// An insertion sort by descending cluster, which is the order a stack is built in.
	mut i := 1
	for i < marks.len {
		mut j := i
		for j > 0 && glyphs[marks[j]].cluster > glyphs[marks[j - 1]].cluster {
			marks[j], marks[j - 1] = marks[j - 1], marks[j]
			j--
		}
		i++
	}
	return marks
}

// larger is the larger of two pixel measurements.
pub fn larger(a f64, b f64) f64 {
	return if a > b { a } else { b }
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
pub fn position_marks(mut line Line, em_px f64, ctx &shape.Context, vertical bool, cps []rune) {
	// Two passes, and the order matters. The line is in visual order, and in a right-to-left
	// line a mark comes before the letter it belongs to, so collecting the letters and then
	// placing the marks in one pass would find the mark's base already behind it. Collecting
	// every letter first means a mark can look in any direction.
	mut bases := map[int]int{}
	for i, g in line.glyphs {
		if !g.is_mark {
			bases[g.cluster] = i
		}
	}

	// The marks are placed from the last cluster backwards, which is the order a stack has to be
	// built in. A mark on another mark is measured from where the mark under it ended up, so the
	// mark underneath has to be placed first; placing a shadda and then a fatha on it in glyph
	// order would put the fatha at the shadda's position before the shadda had one, and the fatha
	// would then be carried along when the shadda moved.
	mut marks := mark_indices_by_cluster(line.glyphs)
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
		mut base_index := -1
		mut best := 0
		for cluster, bi in bases {
			if cluster <= g.cluster && (base_index < 0 || cluster > best) {
				base_index = bi
				best = cluster
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
		mut stacked_at := -1
		mut stacked_best := 0
		if g.cluster !in bases {
			for k, c in line.glyphs {
				if k == i || !c.is_mark || c.cluster == g.cluster || c.cluster >= g.cluster {
					continue
				}
				if stacked_at < 0 || c.cluster > stacked_best {
					stacked_at = k
					stacked_best = c.cluster
				}
			}
		}
		if stacked_at >= 0 {
			target := line.glyphs[stacked_at]
			// A mark and the mark under it have to come from the same font, as below.
			stack_font := g.font or { continue }
			stack_target_font := target.font or { continue }
			if stack_font == stack_target_font {
				if off := stack_font.mark_offset_in(g.gid, target.gid, true, script) {
					stack_scale := em_px / f64(stack_font.face.units_per_em)
					line.glyphs[i].x = target.x + f64(off.x) * stack_scale
					if vertical {
						line.glyphs[i].y = target.y - f64(off.y) * stack_scale
					} else {
						line.glyphs[i].y = -f64(off.y) * stack_scale
					}
					continue
				}
			}
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
		mut off := shaped_mark_offset(f, g.gid, base, script) or { continue }
		// The offset is in design units and the line is in pixels, so it is scaled by the same
		// ratio the advances came from.
		scale := em_px / f64(f.face.units_per_em)
		line.glyphs[i].x = base.x + f64(off.x) * scale
		// y is positive upwards in the font's coordinates and downwards on a line, so the sign
		// is flipped here rather than leaving every caller to remember. In a
		// vertical line the flip is measured from the base, which hangs below
		// the pen by the vertical origin: from zero the mark would land a whole
		// origin above its letter.
		if vertical {
			line.glyphs[i].y = base.y - f64(off.y) * scale
		} else {
			line.glyphs[i].y = -f64(off.y) * scale
		}
	}
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
pub fn shaped_mark_offset(f &shape.Font, mark_gid u16, base shape.Glyph, script string) ?font.Offset2 {
	if off := f.mark_offset_in(mark_gid, base.gid, false, script) {
		return off
	}
	if base.base_gid == 0 {
		return none
	}
	shaped := f.shaped_glyph_index(base.base_gid, base.form, 'arab')
	if shaped != base.base_gid {
		if off := f.mark_offset_in(mark_gid, shaped, false, script) {
			return off
		}
	}
	return f.mark_offset_in(mark_gid, base.base_gid, false, script)
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

// draw_order returns the glyphs in the order they should be painted: letters first, marks
// last.
//
// A mark occupies the same place as the letter it belongs to, so whichever is painted second
// ends up on top. The mark has to be that one, otherwise the letter hides its own accents.
pub fn (l &Line) draw_order() []shape.Glyph {
	mut out := []shape.Glyph{cap: l.glyphs.len}
	for g in l.glyphs {
		if !g.is_mark {
			out << g
		}
	}
	for g in l.glyphs {
		if g.is_mark {
			out << g
		}
	}
	return out
}
