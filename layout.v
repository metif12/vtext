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
	// tallest font that contributed a glyph.
	ascent  f64
	descent f64
	// paragraph_level is the resolved direction as a level: even is left to right, odd is
	// right to left.
	paragraph_level u8
}

// layout_paragraph runs normalization, the bidirectional algorithm and Arabic joining over
// cps, maps the result to glyphs through fs, and positions the glyphs on one line at em_px.
//
// base_dir drives rules P2 and P3 of the bidirectional algorithm: .auto takes the
// direction from the first strong character, which is what a caller usually wants for a
// line of unknown language.
pub fn layout_paragraph(ctx &Context, cps []rune, base_dir Direction, fs &FontSet,
	em_px f64) Line {
	// Joining keys on joining types, and a precomposed character is a different codepoint
	// with a different one, so the text has to be decomposed before it is shaped. The
	// marks this separates are the ones the layout pass later has to place.
	decomposed := ctx.normalizer.nfd(cps)

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
		for g in shaped.glyphs {
			// A sequence is a list of input indices with the X9-removed characters taken
			// out, so an index in the shaped run is an offset into the sequence rather than
			// into the paragraph.
			//
			// One shaped letter can become more than one glyph, which is what happens to a
			// lam-alef in a font with no ligature form. Each of those glyphs is tagged with
			// the input character it stands for, so the two are traced back to the lam and
			// the alef separately.
			for j, mut out in fs.shaped_glyphs(g, em_px) {
				offset := g.start + j
				out.cluster = if offset < seq.len { seq[offset] } else { seq[g.start] }
				placed << out
			}
		}
	}

	mut line := Line{
		glyphs:          place_glyphs(placed, bidi)
		paragraph_level: bidi.paragraph_level
	}
	measure_line(mut line, em_px)
	return line
}

// place_glyphs positions the glyphs on the line in visual order.
//
// Rule L2 of the bidirectional algorithm gave a permutation of the input characters, not of
// the glyphs, and the two are not the same list: a lam-alef is one glyph standing for two
// characters, and a mark is a glyph for a character that a letter does not cover. So the
// permutation is walked and each character is asked for its glyph, which draws out exactly
// one glyph per character that has one and passes over the ones a glyph already drawn
// stands for.
fn place_glyphs(placed []Glyph, bidi BidiResult) []Glyph {
	mut out := []Glyph{cap: placed.len}
	mut by_cluster := map[int]int{}
	for i, g in placed {
		// The first glyph for a character wins, so a glyph covers a whole run of
		// characters rather than each of them drawing again.
		if !(g.cluster in by_cluster) {
			by_cluster[g.cluster] = i
		}
	}

	mut x := f64(0)
	for v in bidi.visual_order {
		if !bidi.visible[v] {
			continue
		}
		i := by_cluster[v] or { continue }
		mut g := placed[i]
		g.x = x
		out << g
		x += g.advance
	}
	return out
}

// measure_line fills in the line's width and vertical extent.
//
// A line can be drawn from more than one font, and the fonts need not agree on how tall they
// are, so the extent is the largest of the contributors rather than the first one's.
fn measure_line(mut line &Line, em_px f64) {
	for g in line.glyphs {
		line.width = larger(line.width, g.x + g.advance)
		if f := g.font {
			line.ascent = larger(line.ascent, f.ascent(em_px))
			line.descent = larger(line.descent, f.descent(em_px))
		}
	}
}

// larger is the larger of two pixel measurements.
fn larger(a f64, b f64) f64 {
	return if a > b { a } else { b }
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
