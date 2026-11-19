module layout

import vtext.shape
import vtext.font

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

// Align is where a line sits in the width it was given, in visual coordinates:
// left puts the line's left edge at the margin whatever the direction, right
// puts its right edge there, center splits the spare, and justify stretches
// the line to fill the width. Pango's LEFT/CENTER/RIGHT/FILL spell the same
// four in the same visual way, so a caller moving between the two keeps its
// numbers. The default left is what every line laid out before this control
// existed: the pen starts at zero and nothing shifts.
pub enum Align {
	left    = 0
	center  = 1
	right   = 2
	justify = 3
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
	// script overrides the detected script every run resolves its features under.
	// Empty detects per run — the first strong script, arab when none — which is
	// what every line shaped before this control existed. Naming one forces all
	// runs under it, spelt the way the font spells it ('arab', 'latn').
	script string
	// language overrides the language system every run resolves its features
	// under. Empty is the script's default language system, which is what every
	// line shaped before this control existed. Naming one asks the tagged
	// language system instead ('URD', 'FAR'), falling back to the default when
	// the font does not tag it. It is the OpenType tag the font spells, not a
	// BCP 47 code: 'urd' is not 'URD'.
	language string
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
	// align is where the line sits in the target width: the caller's
	// align_width for a single line, the wrap width for every line
	// wrap_paragraph_with cuts. left is the default and what every line laid
	// out before this control existed. center and right shift the line;
	// justify stretches it. In wrap the last line of a paragraph stays flush,
	// the way Pango leaves it; a single line answers its explicit width, so a
	// caller wanting one justified line sets align_width on it.
	align Align
	// align_width is the target width align resolves against for a single
	// line. Zero takes the line's own width, which makes every mode a no-op.
	// Wrapped lines resolve against the wrap width instead and ignore this.
	align_width f64
	// wrap_mode is where a wrapped line may end: word breaks only at the
	// policy's opportunities (the default, and what every wrap before this
	// control did), char between any two characters, word_char at word
	// breaks with overlong words split between characters. Single lines
	// ignore it: nothing wraps them.
	wrap_mode WrapMode
	// tab_stops are the visual x positions a tab advances to, in pixels.
	// A tab takes the pen to the first stop past it; past the
	// last stop the last interval repeats, and with fewer than two stops the
	// tab keeps its font advance. Empty (the default) disables the whole
	// mechanism: every tab keeps its font advance exactly as before. Only
	// horizontal lines expand tabs; vertical columns ignore this.
	tab_stops []f64
}

// indic_visual reorders a shaping run into visual order for the Indic
// syllable machine: a pre-base matra sits after its consonant in the text
// but draws before it, so the run is what GSUB sees. sub_idx maps each
// shaped position back to the decomposed text, and the reorder permutes
// positions — so the map is recomposed through the permutation and the
// cluster reads below keep naming the caller's indices. Outside Indic runs
// the reorder is the identity and the map is untouched.
//
// A reordered syllable also merges its clusters onto its base: the placing
// pass draws glyphs grouped by cluster along bidi visual order, so honest
// per-character clusters would un-draw the reorder (the matra belongs to a
// later cluster than the base it precedes). Every glyph of the syllable
// reporting the base's index draws visual order and matches HarfBuzz, which
// reports the whole reordered syllable on its first cluster.
fn indic_visual(ctx &shape.Context, sub []rune, mut sub_idx []int) []rune {
	// Split vowels grow the run: each Khmer split vowel gains its SRA E
	// half before the base, so the index map grows with it through the
	// split permutation. Without this the added halves would report the
	// wrong character, and the length guard below would discard the split
	// and draw the unsplit word. The split runs through the shaper
	// registry; a run no shaper claims keeps its identity, so every other
	// script takes exactly the old path.
	mut split := sub.clone()
	mut smap := []int{}
	if sh := shape.shaper_for_content(sub) {
		split, smap = sh.split_run(sub)
	}
	mut run := sub.clone()
	if split.len != sub.len {
		if smap.len != split.len || sub_idx.len != sub.len {
			return sub
		}
		old := sub_idx.clone()
		mut grown := []int{cap: split.len}
		for k in 0 .. smap.len {
			grown << old[smap[k]]
		}
		sub_idx = grown.clone()
		run = split.clone()
	}
	reordered, perm := shape.reorder_indic_mapped_with(ctx.indic_syl_ranges, ctx.indic_pos_ranges,
		run)
	if reordered.len != run.len || reordered.len != sub_idx.len {
		return run
	}
	// The permutation reads old positions while writing new ones, so the
	// map is recomposed through a copy: reading sub_idx in place would
	// reuse slots this same loop already overwrote.
	old := sub_idx.clone()
	for k in 0 .. sub_idx.len {
		sub_idx[k] = old[perm[k]]
	}
	// A moved syllable merges its clusters onto its base (see above). The
	// reorder already ran, so moved-ness reads off its answer: a span the
	// permutation left alone is the span the reorder left alone. Re-running
	// the reorder per syllable here re-decoded both UCD tables per
	// syllable — the F2 hot path — for an answer already in hand. The
	// equal-runes edge (identical codepoints permuted) cannot occur: every
	// move the machine makes crosses unlike codepoints (matra over
	// consonants, repha to the end, tail preposes), and the corpus pins
	// below hold the merged clusters exactly.
	for s in shape.segment_indic_syllables_with(ctx.indic_syl_ranges, run) {
		if reordered[s.start..s.end] != run[s.start..s.end] {
			base := old[s.start]
			for k in s.start .. s.end {
				sub_idx[k] = base
			}
		}
	}
	return reordered
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
	mut prof := Profiler{}
	return layout_paragraph_inner(ctx, cps, base_dir, fs, em_px, options, mut prof)
}

// layout_paragraph_profiled is layout_paragraph_with with the caller's
// profiler enabled: the returned line is identical, and prof carries the
// per-stage costs (see profiler.v for the stage map). A disabled profiler
// stays silent; this entry point is the opt-in.
pub fn layout_paragraph_profiled(ctx &shape.Context, cps []rune, base_dir shape.Direction, fs &shape.FontSet,
	em_px f64, options &LayoutOptions, mut prof Profiler) Line {
	prof.enabled = true
	return layout_paragraph_inner(ctx, cps, base_dir, fs, em_px, options, mut prof)
}

fn layout_paragraph_inner(ctx &shape.Context, cps []rune, base_dir shape.Direction, fs &shape.FontSet,
	em_px f64, options &LayoutOptions, mut prof Profiler) Line {
	seg_start := prof.begin()
	// Joining keys on joining types, and a precomposed character is a different codepoint
	// with a different one, so the text has to be decomposed before it is shaped. The
	// marks this separates are the ones the layout pass later has to place.
	//
	// The mapping comes back with the text because decomposition changes both the length and the
	// order of it: a shadda written after a fatha is moved ahead of it, because canonical ordering
	// puts the lower combining class first, and a shadda is a higher one. Without the mapping the
	// two marks would report each other's input positions, and a mark would then be looked for
	// against the wrong letter.
	decomposed_nfd, decomposed_origin := ctx.normalizer.nfd_mapped(cps)
	// Hangul conjoining Jamo compose back into syllables after NFD: the
	// decomposition the joining pass needs splits every precomposed
	// syllable into its lead, vowel and trailing parts, and HarfBuzz draws
	// the parts composed whenever the font carries the syllable. Without
	// this the parts draw as two or three glyphs with two or three
	// advances where one syllable belongs.
	decomposed, origin := shape.compose_hangul_runs(decomposed_nfd, decomposed_origin)

	bidi := shape.resolve_paragraph(ctx.properties, decomposed, base_dir)
	prof.end(.segment, seg_start, cps.len)

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
		re_start := prof.begin()
		visual := indic_visual(ctx, sub, mut sub_idx)
		prof.end(.reorder, re_start, sub.len)
		seg2_start := prof.begin()
		shaped := ctx.shaper.shape_arabic(ctx.properties, visual)
		mut run := []shape.Glyph{}
		// The script of the run, which is what the font resolves its features
		// under. It is the first script that names one rather than the first
		// glyph's: Common, Inherited and Unknown have no features of their own,
		// so a run that opens with a comma or a digit would otherwise resolve
		// none, and HarfBuzz itemizes the same run under its strong script.
		// The caller's override wins over all of it: one script for every run.
		mut script := 'arab'
		if options.script != '' {
			script = font.ot_script_tag(options.script)
		} else if shaped.glyphs.len > 0 {
			script = shaped.glyphs[0].script
			for g in shaped.glyphs {
				if g.script != 'Zyyy' && g.script != 'Zinh' && g.script != 'Zzzz' {
					script = g.script
					break
				}
			}
		}
		lang := options.language
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
		prof.end(.segment, seg2_start, run.len)
		gs_start := prof.begin()
		mut run_glyphs := substitute_gsub_in_fonts(run, em_px, script, lang, options.features,
			options.vertical)
		prof.end(.gsub, gs_start, run.len)
		// The vertical swap runs per run rather than over the whole line, because the
		// vertical kern that follows it needs the run's script and must not cross a
		// run boundary: a pair from two scripts has no single table to ask. The swap
		// is what the kern folds into, so it comes first, and the global pass below
		// must not run again and discard the fold.
		gp_start := prof.begin()
		if options.vertical {
			apply_vertical_advances(mut run_glyphs, em_px)
			vkern_pairs(mut run_glyphs, em_px, script, lang, rtl)
			single_positions(mut run_glyphs, em_px, script, lang, options.features, true)
		} else {
			apply_gpos_in_fonts(mut run_glyphs, em_px, script, lang, options.features, rtl)
		}
		prof.end(.gpos, gp_start, run_glyphs.len)
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
	pl_start := prof.begin()
	apply_spacing(mut placed, ctx.properties, cps, options.letter_spacing, options.word_spacing)

	mut line := Line{
		glyphs:          if options.vertical {
			place_glyphs_vertical(placed, bidi, origin, em_px)
		} else {
			place_glyphs(placed, bidi, origin)
		}
		paragraph_level: bidi.paragraph_level
	}
	// Tabs expand after placing and before marks anchor: the pen the stops
	// are read against is the placed one, and a mark on a letter after a tab
	// anchors from the letter's moved position rather than its unmoved one.
	if !options.vertical && options.tab_stops.len > 0 {
		expand_tabs(mut line, cps, options.tab_stops)
	}
	prof.end(.place, pl_start, placed.len)
	gp2_start := prof.begin()
	position_marks(mut line, em_px, ctx, options.vertical, cps, options.language)
	prof.end(.gpos, gp2_start, line.glyphs.len)
	pl2_start := prof.begin()
	if options.vertical {
		measure_vertical_line(mut line, em_px, options)
	} else {
		measure_line(mut line, em_px, options)
		// Alignment is horizontal: a vertical line stacks columns by width
		// and its length is the pen travel, so a target width names nothing
		// and the mode is ignored there. A single line answers its explicit
		// width (is_last false): the wrap path is where the last-line rule
		// lives, because only it lays out paragraphs.
		if options.align != .left && options.align_width > line.width {
			apply_align(ctx, mut line, cps, 0, cps.len, base_dir, fs, em_px, options,
				options.align_width, false)
		}
	}
	prof.end(.place, pl2_start, line.glyphs.len)
	return line
}
