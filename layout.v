module vtext

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

// Line is a laid out paragraph: positioned glyphs, left to right.
pub struct Line {
pub mut:
	// glyphs are the drawable glyphs in visual order, left to right. A combining mark
	// shares the x of the letter it sits on, so a mark and its base are both present and
	// both at the same place.
	glyphs []Glyph
	// width is the total advance of the line in pixels, marks included, which for a mark is
	// nothing.
	width f64
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
// The default is the one the engine is prepared to defend: no discretionary features, so the line
// is the text. Anything that changes the width of what is drawn is a presentation decision, and a
// text engine that made it on the caller's behalf would be a text engine that could not be relied
// on to measure text.
//
// What is not here is a direction. That is the base_dir argument of layout_paragraph and its
// siblings, and adding it here as well would leave two sources for one decision with no stated
// precedence, which is the kind of thing that works until a caller sets the one that is ignored.
pub struct LayoutOptions {
pub mut:
	// features are the discretionary OpenType features to apply after the required ones, which
	// the engine always applies. liga is the one a Persian line usually wants, since several
	// letter pairs have ligature forms the text itself does not spell.
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
}

// layout_paragraph runs normalization, the bidirectional algorithm and Arabic joining over
// cps, maps the result to glyphs through fs, and positions the glyphs on one line at em_px.
//
// base_dir drives rules P2 and P3 of the bidirectional algorithm: .auto takes the
// direction from the first strong character, which is what a caller usually wants for a
// line of unknown language.
//
// No discretionary features are applied. Use layout_paragraph_with to ask for any.
pub fn layout_paragraph(ctx &Context, cps []rune, base_dir Direction, fs &FontSet,
	em_px f64) Line {
	return layout_paragraph_with(ctx, cps, base_dir, fs, em_px, &LayoutOptions{})
}

// layout_paragraph_with is layout_paragraph with the caller's options applied.
pub fn layout_paragraph_with(ctx &Context, cps []rune, base_dir Direction, fs &FontSet,
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

	bidi := resolve_paragraph(ctx.properties, decomposed, base_dir)

	// Shape each isolating run sequence on its own, then look the shaped codepoints up. The
	// result is in logical order still, tagged with the input character each glyph came
	// from, because that tag is the only thing that survives reordering.
	mut placed := []Glyph{cap: decomposed.len}
	for seq in bidi.sequences {
		mut sub := []rune{cap: seq.len}
		for i in seq {
			sub << decomposed[i]
		}
		shaped := ctx.shaper.shape_arabic(ctx.properties, sub)
		mut run := []Glyph{}
		// The script of the first letter in the run, which is what the font resolves its
		// ligature features under. A run of one script has one, and a run is never mixed, since
		// the bidi pass already split the text at every direction change.
		mut script := 'arab'
		if shaped.glyphs.len > 0 {
			script = shaped.glyphs[0].script
		}
		for g in shaped.glyphs {
			// A sequence is a list of input indices with the X9-removed characters taken
			// out, so an index in the shaped run is an offset into the sequence rather than
			// into the paragraph.
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
				mut cluster := seq[g.start]
				if offset < seq.len {
					decomposed_at := seq[offset]
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
		// it has to happen while the run is still in logical order.
		for glyph in substitute_in_fonts(run, em_px, script, options.features) {
			placed << glyph
		}
	}

	// Spacing goes onto the advances before anything is positioned, rather than onto the positions
	// afterwards. place_glyphs walks the run accumulating advances into x, and measure_line takes
	// the line's width from those same positions, so a pass that changed advances alone is picked up
	// by both with no second walk and no chance of the width and the positions disagreeing.
	apply_spacing(mut placed, ctx.properties, cps, options.letter_spacing, options.word_spacing)

	mut line := Line{
		glyphs:          place_glyphs(placed, bidi, origin)
		paragraph_level: bidi.paragraph_level
	}
	position_marks(mut line, em_px)
	measure_line(mut line, em_px, options)
	return line
}

// apply_spacing adds the caller's letter and word spacing to the run's advances.
//
// It runs on the shaped run before place_glyphs, and it edits advance rather than x. See the comment at
// the call site for why the order and the choice of field are the two that matter.
fn apply_spacing(mut glyphs []Glyph, props &Properties, cps []rune, letter_spacing f64,
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
fn is_space_at(props &Properties, cps []rune, i int) bool {
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
fn substitute_in_fonts(glyphs []Glyph, em_px f64, script string, features []string) []Glyph {
	if glyphs.len == 0 {
		return glyphs
	}
	mut out := []Glyph{cap: glyphs.len}
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
		for glyph in f.substitute_glyphs(glyphs[at..end], script, em_px, features) {
			out << glyph
		}
		at = end
	}
	return out
}

// place_glyphs positions the glyphs on the line in visual order.
//
// Rule L2 of the bidirectional algorithm gave a permutation of the input characters, not of
// the glyphs, and the two are not the same list: a lam-alef is one glyph standing for two
// characters, and a mark is a glyph for a character that a letter does not cover. So the
// permutation is walked and each character is asked for its glyph, which draws out exactly
// one glyph per character that has one and passes over the ones a glyph already drawn
// stands for.
fn place_glyphs(placed []Glyph, bidi BidiResult, origin []int) []Glyph {
	mut out := []Glyph{cap: placed.len}
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
			g.x = x
			out << g
			x += g.advance
		}
	}
	return out
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
fn measure_line(mut line Line, em_px f64, options &LayoutOptions) {
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
fn mark_indices_by_cluster(glyphs []Glyph) []int {
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
fn larger(a f64, b f64) f64 {
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
// A `mut` value receiver for the reason given on measure_line: `mut line &Line` as a
// parameter is a pair V 0.5.2 will not accept at a `position_marks(mut line, ...)` call.
fn position_marks(mut line Line, em_px f64) {
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
				if off := stack_font.mark_offset(g.gid, target.gid, true) {
					stack_scale := em_px / f64(stack_font.face.units_per_em)
					line.glyphs[i].x = target.x + f64(off.x) * stack_scale
					line.glyphs[i].y = -f64(off.y) * stack_scale
					continue
				}
			}
		}
		// The base is the letter the mark was written after, which is the nearest one with a
		// smaller input position. Searching by cluster rather than by position on the line is
		// what makes this work in both directions, and it also steps over a ligature or a
		// discarded control that sits between the two.
		//
		// The search is over the clusters that are present rather than over a fixed range, so a
		// mark whose letter was dropped from the line finds nothing and stays at the pen.
		//
		// A mark decomposed from the same original character as its base shares that base's
		// cluster — U+0622 splits to U+0627 plus U+0653, and both report cluster 47 — so the
		// comparison is <= rather than <. This is safe because bases holds only non-marks and the
		// mark being placed is a mark: it can never select itself, only the letter it came from.
		mut base_index := -1
		mut best := 0
		for cluster, bi in bases {
			if cluster <= g.cluster && (base_index < 0 || cluster > best) {
				base_index = bi
				best = cluster
			}
		}
		if base_index < 0 {
			continue
		}
		base := line.glyphs[base_index]
		f := g.font or { continue }
		base_font := base.font or { continue }
		// The glyphs have to come from the same font for an anchor in one to mean anything in
		// the other. A line that fell back mid-word has marks in a different font from their
		// base, and there is no correct answer, so the mark stays at the pen.
		if f != base_font {
			continue
		}
		mut off := f.mark_offset(g.gid, base.gid, false) or {
			// The base may be a presentation form, whose anchors the font never wrote — they
			// live on the base letter it stands for. Falling back to the base glyph's anchor
			// is what puts a kasra on a medial meem rather than leaving it at the pen.
			if base.base_gid == 0 {
				continue
			}
			f.mark_offset(g.gid, base.base_gid, false) or { continue }
		}
		// The offset is in design units and the line is in pixels, so it is scaled by the same
		// ratio the advances came from.
		scale := em_px / f64(f.face.units_per_em)
		line.glyphs[i].x = base.x + f64(off.x) * scale
		// y is positive upwards in the font's coordinates and downwards on a line, so the sign
		// is flipped here rather than leaving every caller to remember.
		line.glyphs[i].y = -f64(off.y) * scale
	}
}

// draw_order returns the glyphs in the order they should be painted: letters first, marks
// last.
//
// A mark occupies the same place as the letter it belongs to, so whichever is painted second
// ends up on top. The mark has to be that one, otherwise the letter hides its own accents.
pub fn (l &Line) draw_order() []Glyph {
	mut out := []Glyph{cap: l.glyphs.len}
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
