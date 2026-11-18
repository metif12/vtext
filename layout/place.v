module layout

import vtext.shape
import vtext.ucd

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

// expand_tabs walks a placed line in draw order and stretches each tab so the
// pen lands on a tab stop.
//
// A stop is a visual x, so the walk is in the order the glyphs draw in with
// the pen held as an x: the tab's own left edge after every earlier tab has
// moved it. The target is the least stop past the pen; past the last stop the
// last interval repeats, and with fewer than two stops there is no interval
// to repeat and the tab keeps its font advance. A mark rides its base: it
// takes the shift and pays nothing, because it has no advance of its own.
//
// The tab keeps its font glyph — this moves ink, it does not unmap .notdef —
// and word spacing still passes tabs by, because a tab is not a space under
// is_space_at. Vertical lines never reach here: their pen runs down, where a
// horizontal stop names nothing.
fn expand_tabs(mut line Line, cps []rune, stops []f64) {
	if stops.len == 0 || line.glyphs.len == 0 {
		return
	}
	mut shift := f64(0)
	for mut g in line.glyphs {
		g.x += shift
		if g.is_mark {
			continue
		}
		if g.cluster < 0 || g.cluster >= cps.len {
			continue
		}
		if cps[g.cluster] != rune(0x0009) {
			continue
		}
		pen := g.x
		// Order-independent: the least stop past the pen, whatever order the
		// caller listed them in.
		mut best := f64(-1)
		mut mx1 := f64(-1)
		mut mx2 := f64(-1)
		for s in stops {
			if s > pen && (best < 0 || s < best) {
				best = s
			}
			if s > mx1 {
				mx2 = mx1
				mx1 = s
			} else if s > mx2 {
				mx2 = s
			}
		}
		mut target := best
		if target < 0 {
			if mx2 < 0 {
				continue
			}
			gap := mx1 - mx2
			if gap <= 0 {
				continue
			}
			mut k := int((pen - mx1) / gap) + 1
			if k < 1 {
				k = 1
			}
			target = mx1 + f64(k) * gap
		}
		old_tab_adv := g.advance
		g.advance = target - pen
		shift += g.advance - old_tab_adv
	}
}

// kashida_tatweel is the filler U+0640 ARABIC TATWEEL, the stretch Arabic
// justification is made of. No corpus font carries a `just` feature, and all
// three Arabic faces carry this glyph instead, which is what "kashida where
// the font carries it" means here: the glyph is the mechanism.
const kashida_tatweel = rune(0x0640)

// shift_line moves every glyph of the line by dx, marks included: a mark's
// position is absolute from its anchor, so leaving it behind would unseat it
// from the base that moved.
fn shift_line(mut line Line, dx f64) {
	if dx == 0 {
		return
	}
	for mut g in line.glyphs {
		g.x += dx
	}
}

// stretch_spaces widens every space of the line by the same share of the
// slack, shifting what follows each one along, and reports whether it moved
// anything. Marks ride with their bases: a mark shares no advance with
// anyone and the widening only ever grows between a space and whatever comes
// next, so a base and its mark always move as one. The caller sets the width
// afterwards; this moves the ink.
fn stretch_spaces(mut line Line, props &ucd.Properties, cps []rune, slack f64) bool {
	mut n := 0
	for g in line.glyphs {
		if !g.is_mark && is_space_at(props, cps, g.cluster) {
			n++
		}
	}
	if n == 0 || slack <= 0 {
		return false
	}
	per := slack / f64(n)
	mut carry := f64(0)
	for mut g in line.glyphs {
		g.x += carry
		if !g.is_mark && is_space_at(props, cps, g.cluster) {
			g.advance += per
			carry += per
		}
	}
	return true
}

// word_kashida_points lists the insertion indices (into the whole cps via the
// base offset) where one word takes a tatweel, ordered from the word end
// toward its start so the pre-final gap comes first: the stretch sits where
// readers expect it, ahead of the word's last letter.
//
// A point is the gap before a letter that joins to the previous one, reached
// over any marks riding on the letter before it: inserting between a letter
// and its own mark would reattach the mark to the tatweel. The gap inside a
// lam-alef pair is skipped — a tatweel there breaks the ligature both engines
// fuse — and the earlier gap in the word is taken instead. Gaps no joining
// pair holds simply never list, so a word with no joining gap gets nothing.
fn word_kashida_points(props &ucd.Properties, word []rune, base int) []int {
	mut letters := []int{}
	for i, cp in word {
		if props.combining_class_of(cp) != 0 {
			continue
		}
		letters << i
	}
	mut out := []int{}
	for k := letters.len - 1; k > 0; k-- {
		l := word[letters[k - 1]]
		r := word[letters[k]]
		if !props.joining_type_of(l).joins_to_next()
			|| !props.joining_type_of(r).joins_to_previous() {
			continue
		}
		if props.joining_group_name(l) == 'Lam' && props.joining_group_name(r) == 'Alef' {
			continue
		}
		out << base + letters[k]
	}
	return out
}

// kashida_points lists every insertion index of the text in word-end-first
// order: each word's points before the next word's, so dealing round-robin
// over the list widens one word each before any word takes a double.
fn kashida_points(props &ucd.Properties, cps []rune) []int {
	mut pts := []int{}
	mut start := 0
	for i in 0 .. cps.len + 1 {
		if i == cps.len || is_space_at(props, cps, i) {
			pts << word_kashida_points(props, cps[start..i], start)
			start = i + 1
		}
	}
	return pts
}

// kashida_count answers how many tatweels the slack buys, or zero when the
// line is not a kashida line: not uniformly Arabic (letters, spaces and
// marks — a mixed line re-laid from its slice could order differently from
// the paragraph it was cut out of), no tatweel in any font of the set, the
// slack buys less than one advance, or no word holds a joining gap.
//
// At most one per gap: stacked tatweels fuse into dedicated ligatures (Amiri
// carries double and triple forms beside HarfBuzz), which is a second shaping
// story the justification pass does not tell. The remainder past one per gap
// goes to the spaces, the way a mixed line sends all of it there.
fn kashida_count(ctx &shape.Context, cps []rune, fs &shape.FontSet, em_px f64, slack f64) int {
	if cps.len == 0 || slack <= 0 {
		return 0
	}
	for i, cp in cps {
		if ctx.properties.script_tag_of(cp) == 'Arab' {
			continue
		}
		if is_space_at(ctx.properties, cps, i) {
			continue
		}
		if ctx.properties.combining_class_of(cp) != 0 {
			continue
		}
		return 0
	}
	f := fs.pick_in(ctx, kashida_tatweel) or { fs.pick(kashida_tatweel) or { return 0 } }
	gid := f.glyph_index(kashida_tatweel)
	if gid == 0 {
		return 0
	}
	adv := f.glyph_advance(gid, em_px)
	if adv <= 0 {
		return 0
	}
	npts := kashida_points(ctx.properties, cps).len
	if npts == 0 {
		return 0
	}
	mut n := int(slack / adv)
	if n > npts {
		n = npts
	}
	return n
}

// kashida_relayout inserts n tatweels at the line's kashida points and lays
// the grown text out again, because a tatweel changes its neighbours' join
// states and editing glyphs post-hoc would draw the old forms. Points are
// dealt round-robin from the line end, so two tatweels widen two words before
// one word takes a double. The re-layout neutralizes align: the caller aligns
// the grown line, and a self-application would recurse.
//
// Clusters are re-based onto the caller's text: the grown text carries the
// inserted tatweels, so a glyph standing for grown index g names the original
// character gcps[g] instead. A tatweel names the letter it precedes — the gap
// it fills belongs to that side for carets — which is also what keeps every
// cluster inside the caller's text.
fn kashida_relayout(ctx &shape.Context, cps []rune, base_dir shape.Direction, fs &shape.FontSet, em_px f64, options &LayoutOptions, n int) ?Line {
	pts := kashida_points(ctx.properties, cps)
	if pts.len == 0 {
		return none
	}
	mut per := map[int]int{}
	for t in 0 .. n {
		p := pts[t % pts.len]
		if p in per {
			per[p]++
		} else {
			per[p] = 1
		}
	}
	mut grown := []rune{cap: cps.len + n}
	mut gcps := []int{cap: cps.len + n}
	for i, cp in cps {
		for _ in 0 .. (per[i] or { 0 }) {
			grown << kashida_tatweel
			gcps << i
		}
		grown << cp
		gcps << i
	}
	mut plain := *options
	plain.align = .left
	plain.align_width = 0
	mut line := layout_paragraph_with(ctx, grown, base_dir, fs, em_px, &plain)
	for mut g in line.glyphs {
		if g.cluster >= 0 && g.cluster < gcps.len {
			g.cluster = gcps[g.cluster]
		}
	}
	return line
}

// apply_align resolves a laid-out line against a target width: shifting for
// center and right, stretching for justify.
//
// The target is the wrap width for a wrapped line and the caller's
// align_width for a single one; [from, to) is the line's range in cps, the
// whole text for a single line. Clusters arriving here are absolute — a slice
// keeps the paragraph's — so the kashida re-layout works on the slice and
// re-bases by from, while the space stretch reads the whole text. is_last
// marks the paragraph's last line, which justification leaves flush:
// stretching a closing half-line spreads its words across the whole width,
// which is what justification refuses to do, Pango included.
//
// Kashida needs the text re-shaped, so it re-lays the line's own range out
// rather than editing glyphs, and only for a uniform Arabic line (letters,
// spaces and marks, nothing else): a mixed line re-laid from its slice can
// order differently from the paragraph it was cut out of. Everything else
// stretches its spaces, and a line with no stretchable point keeps its width:
// a short word is not an error.
pub fn apply_align(ctx &shape.Context, mut line Line, cps []rune, from int, to int, base_dir shape.Direction, fs &shape.FontSet, em_px f64, options &LayoutOptions, target f64, is_last bool) {
	mode := options.align
	if mode == .left {
		return
	}
	if mode == .justify && is_last {
		return
	}
	if line.width >= target {
		return
	}
	sub := cps[from..to]
	slack := target - line.width
	if mode == .center {
		shift_line(mut line, slack / 2.0)
		return
	}
	if mode == .right {
		shift_line(mut line, slack)
		return
	}
	kn := kashida_count(ctx, sub, fs, em_px, slack)
	if kn > 0 {
		if grown := kashida_relayout(ctx, sub, base_dir, fs, em_px, options, kn) {
			// Field by field: a whole-value assignment to a `mut` value
			// receiver does not reach the caller on this compiler, while
			// field stores do (measure_line's receiver comment notwithstanding).
			line.glyphs = grown.glyphs
			line.width = grown.width
			line.height = grown.height
			line.ascent = grown.ascent
			line.descent = grown.descent
			line.paragraph_level = grown.paragraph_level
			line.line_height = grown.line_height
			for mut g in line.glyphs {
				g.cluster += from
			}
			rest := target - line.width
			if rest > 0 && stretch_spaces(mut line, ctx.properties, cps, rest) {
				line.width = target
			}
			return
		}
	}
	if stretch_spaces(mut line, ctx.properties, cps, slack) {
		line.width = target
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

// larger is the larger of two pixel measurements.
pub fn larger(a f64, b f64) f64 {
	return if a > b { a } else { b }
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
