module vtext

// The font layer: turning a shaped codepoint into something drawable.
//
// Joining produces codepoints, not glyph indices, and that is deliberate: a codepoint is
// what a font's cmap and its OpenType tables both key on. This module is where a
// codepoint finally becomes a glyph index, an advance, and a position on the line.
//
// A codepoint can also be missing from the font in front of us, which is the normal case
// rather than an error. Latin and Arabic split across several fonts, an emoji comes from
// whichever colour font is installed, and a CJK ideograph may live anywhere in a long
// fallback chain. FontSet is that chain, and Glyph carries the font it came from so the
// caller can rasterise with the right one.

// Glyph is one drawable character at one place on a line, in pixels.
//
// x is the left edge of the glyph's advance box and y the baseline offset, both relative
// to the start of the line. A mark shares the x of the letter it sits on and has no
// advance of its own, which is how two glyphs end up at the same place.
pub struct Glyph {
pub mut:
	// gid is the glyph index within font. Zero is .notdef.
	gid u16
	// advance is how far the pen moves past this glyph, in pixels. Zero for a mark.
	advance f64
	// x is the left edge of the glyph, in pixels from the start of the line.
	x f64
	// y is the offset of the baseline this glyph sits on, in pixels from the line's
	// baseline. It is zero until a later pass puts a glyph on another line.
	y f64
	// cluster is the index of the input character this glyph came from. A ligature
	// reports the first character it covers, so a caller can map a glyph back to the text
	// it came from and to a caret position. A character that a substitution split into
	// several glyphs has all of them reporting that same character, which is how a layout
	// pass knows to draw them all rather than only the first.
	cluster int
	// is_mark reports that this glyph is a combining mark: it is drawn at the position of
	// the letter before it and has no advance. Marks are drawn after the letters, so that
	// a mark lands on top of the letter it belongs to instead of under it.
	is_mark bool
	// form is the shape the joining pass chose for this letter. It is carried all the way
	// here because a font that keeps its Arabic shapes in a GSUB table is drawn from the
	// base letter, and picking the right variant of that base letter is what form decides.
	form JoiningForm
	// base_gid is the base letter's glyph when this glyph is a presentation form, and zero
	// otherwise. A mark attaches by anchor to a base letter, but anchors are written against
	// base glyphs — not against the presentation forms a cmap lookup returns. So a mark on a
	// presentation-form letter would find no anchor and stay at the pen. Recording the base
	// lets mark placement fall back to the base's anchor, which is where the font put it.
	base_gid u16
	// font is the font this glyph was found in, which is not necessarily the first in the
	// FontSet. It is none only when the chain was empty. The caller needs it to rasterise,
	// and the font carries the units the advance was scaled from.
	font ?&Font
}

// glyph_for looks a codepoint up in one font and returns it with its advance at this em
// size.
//
// A codepoint the font does not cover comes back as .notdef, which is the right answer for
// a single font and the wrong one for a whole line. That is what FontSet is for.
pub fn (f &Font) glyph_for(cp rune, em_px f64) Glyph {
	gid := f.glyph_index(cp)
	return Glyph{
		gid:     gid
		advance: f.glyph_advance(gid, em_px)
		font:    f
	}
}

// mark_glyph returns a glyph for a combining mark. It has no advance, so it lands on the
// letter before it, and it is flagged so the layout pass draws it last.
pub fn (f &Font) mark_glyph(cp rune, em_px f64) Glyph {
	mut g := f.glyph_for(cp, em_px)
	g.advance = 0
	g.is_mark = true
	return g
}

// FontSet is an ordered chain of fonts to look a codepoint up in.
//
// Order is the whole meaning of the type. The first font is the wanted one, and the rest
// are progressively less likely, so a codepoint is taken from the earliest font that
// covers it. That is what lets one line hold Latin, Arabic and an emoji at once.
pub struct FontSet {
pub mut:
	// fonts is the chain, most preferred first.
	fonts []&Font
	// primary is the font to prefer for the script it was chosen for, or none for a flat chain.
	//
	// It sits outside fonts because it is not a fallback at all. In a flat chain the first font that
	// covers a character wins, which for two fonts that both cover Arabic means the Latin one always
	// does and the Arabic one never can. primary is consulted by script instead, so a character in the
	// chosen script reaches the chosen face even though a general font would also have covered it.
	primary ?&Font
	// general is the font that covers everything else, including the script of any character primary has
	// no glyph for.
	general ?&Font
}

// new_font_set returns an empty chain.
pub fn new_font_set() &FontSet {
	return &FontSet{ fonts: []&Font{} }
}

// new_font_set_of returns a chain of the given fonts, most preferred first.
pub fn new_font_set_of(fonts ...&Font) &FontSet {
	return &FontSet{ fonts: fonts }
}

// new_script_font_set returns a chain that prefers a font for the script each character belongs to.
//
// A flat order cannot express what a mixed-script line wants. Both Segoe UI and Traditional Arabic cover
// Latin and Arabic, so a chain of (latin, arabic) draws every Arabic letter in the Latin font and the
// Arabic font is dead weight, and a chain of (arabic, latin) has the mirror problem. Neither order is
// wrong as an order; each is wrong as an answer to "draw this Persian line in a naskh face and that
// English word in a Latin one".
//
// A per-script chain answers that, and the rule it applies is the obvious one: the specialised font wins
// inside the script it was chosen for, and the general font covers everything else. That is what a caller
// means when they hand over two fonts and one string.
//
// The script comes from the pipeline's own script property rather than from a range check here, so
// Common and Inherited are not special-cased twice in two places: Common has no script of its own and
// falls to the general font, and Inherited takes the script of the character before it, which is what the
// joining pass already worked out.
//
// The cost is that a codepoint is looked up more than once, once to ask which script it is and once to
// find the font. This is a fallback chain, so it is already the slow path; a cache here would be a second
// invalidation problem to keep correct for a cost nobody has measured.
pub fn new_script_font_set(primary &Font, general &Font) &FontSet {
	return &FontSet{ primary: primary, general: general, fonts: []&Font{} }
}

// lookup_font returns the font that will be used for cp, or none when the chain cannot answer.
//
// This is the decision new_script_font_set makes, exposed so a caller can ask it instead of guessing. A
// program that wants to label a run with the face it was drawn in has no other way to find out, and
// guessing from the FontSet's order would answer "the first font" to a question about "the first font
// that has this character in this script".
//
// The script test is `Properties.is_arabic_script`, the same generated table the joining pass uses, so
// the set cannot disagree with the shaper about which characters are Arabic. A private range check here
// would be a second answer to that question and would drift from the first.
pub fn (fs &FontSet) lookup_font(ctx &Context, cp rune) ?&Font {
	return fs.pick_in(ctx, cp)
}

// add appends a font as the least preferred one, which is the usual order: the wanted font
// first, then the ones it is allowed to fall back to.
pub fn (mut fs FontSet) add(f &Font) {
	fs.fonts << f
}

// len is the number of fonts in the chain.
pub fn (fs &FontSet) len() int {
	return fs.fonts.len
}

// pick returns the first font in the chain that really covers cp.
//
// Falling back to the first font rather than reporting a miss matters: .notdef is how a
// font says "I have no letter for this", and drawing one is usually more useful than
// dropping the character, which would silently reflow the line.
//
// none means the chain itself is empty, which is a wiring mistake rather than a missing
// character, so it is kept distinct.
pub fn (fs &FontSet) pick(cp rune) ?&Font {
	for f in fs.fonts {
		if f.has_glyph(cp) {
			return f
		}
	}
	return if fs.fonts.len == 0 { none } else { fs.fonts[0] }
}

// pick_in resolves a codepoint to a font, consulting the script before the flat chain.
//
// This is the lookup a per-script set needs and `pick` cannot serve, because `pick` has no way to ask
// what script a character is. It is kept separate rather than folded into `pick` with an optional context
// so that the flat chain's meaning stays one thing: first font that covers the character, in order.
//
// For a flat set this is exactly `pick`, because a per-script set with no primary font falls through to
// the same walk. That is the property worth stating, since it is what lets a caller swap one for the
// other without changing anything else about the pipeline.
pub fn (fs &FontSet) pick_in(ctx &Context, cp rune) ?&Font {
	if fs.primary != none {
		primary := fs.primary or { unsafe { nil } }
		if ctx.properties.is_arabic_script(cp) && primary.has_glyph(cp) {
			return primary
		}
	}
	if fs.general != none {
		general := fs.general or { unsafe { nil } }
		if general.has_glyph(cp) {
			return general
		}
		// Neither font covers it. A flat chain answers with the first font rather than none, so that a
		// miss draws .notdef instead of dropping the character and silently reflowing the line, and a
		// per-script set must give the same answer for the same input. Falling through to `pick` would
		// not do it: `pick` walks `fonts`, and a per-script set keeps its two fonts in their own fields,
		// so the chain is empty and `pick` would report a miss instead.
		return general
	}
	return fs.pick(cp)
}

// glyph_in is glyph through the script-aware lookup.
pub fn (fs &FontSet) glyph_in(ctx &Context, cp rune, em_px f64) Glyph {
	return fs.glyph_variation_in(ctx, cp, []rune{}, em_px)
}

// glyph_variation_in is glyph_in with variation selectors after the codepoint.
//
// A chain has to answer a different question when there is a selector. Asking each font "do you have
// this codepoint" is not enough, because a font can cover the base and still have no opinion about
// the sequence — and then the right answer is the base's text presentation, which is a result rather
// than a miss. So a font that knows the sequence is asked first and takes it, and the chain falls
// through to the ordinary base lookup for every font that does not, including the first one.
//
// The fallback chain is unchanged in shape: the selector does not add a stage, it changes which
// question the first stage asks.
pub fn (fs &FontSet) glyph_variation_in(ctx &Context, cp rune, selectors []rune, em_px f64) Glyph {
	f := fs.pick_in(ctx, cp) or { return Glyph{} }
	return f.glyph_variation_for(cp, selectors, em_px)
}

// glyph_variation_for looks a codepoint with variation selectors up in one font.
fn (f &Font) glyph_variation_for(cp rune, selectors []rune, em_px f64) Glyph {
	gid := f.glyph_index_variation(cp, selectors)
	return Glyph{
		gid:     gid
		advance: f.glyph_advance(gid, em_px)
		font:    f
	}
}

// glyph looks cp up through the chain and returns the glyph with the font that produced it.
pub fn (fs &FontSet) glyph(cp rune, em_px f64) Glyph {
	f := fs.pick(cp) or { return Glyph{} }
	return f.glyph_for(cp, em_px)
}

// mark_glyph is glyph for a combining mark, taken through the same chain.
pub fn (fs &FontSet) mark_glyph(cp rune, em_px f64) Glyph {
	f := fs.pick(cp) or { return Glyph{} }
	return f.mark_glyph(cp, em_px)
}

// covers reports whether any font in the chain really has the codepoint. It is the
// question shaped_glyphs has to ask before it decides between a form and a base letter.
pub fn (fs &FontSet) covers(cp rune) bool {
	for f in fs.fonts {
		if f.has_glyph(cp) {
			return true
		}
	}
	return false
}

// shaped_glyphs maps one shaped letter onto the glyphs that will draw it, which is one
// glyph in the usual case.
//
// A font that carries the Unicode presentation forms answers for the form codepoint
// directly. Most modern Arabic fonts do not: they carry the base letters and put the four
// shapes in a GSUB table, so the form codepoint is .notdef in every font of the chain. Dubai
// on Windows is exactly such a font, and a line shaped against it would otherwise be nothing
// but .notdef boxes. So when no font has the form, the base letter is drawn and the font's
// own joining features pick the shaped variant of it, which happens over the whole run in
// substitute_glyphs rather than here.
//
// A ligature is the one case that produces more than one glyph, because it stood for two
// letters and both have to be drawn. The lam keeps its own joins rather than the pair's:
// it joins the alef ahead of it, so with the pair joined behind it is medial, not final.
// Giving it the pair's final form starves the medial-masked joining lookups, and in Noto
// Nastaliq that is what keeps the rlig context for the .LA pair from ever forming. The alef
// connects backwards only when the lam did, so it takes a final form whenever the ligature
// joined to anything and an isolated one when the pair stood on its own.
//
// ctx is here for one reason: a per-script FontSet has to ask which script a character is, and
// the answer comes from the pipeline's own generated tables rather than from a range check
// written a second time. A flat FontSet ignores it entirely, so this costs a flat chain
// nothing.
pub fn (fs &FontSet) shaped_glyphs(ctx &Context, sg ShapedGlyph, em_px f64) []Glyph {
	if sg.base.len == 0 {
		return []Glyph{}
	}
	form_cp := sg.cps[0]
	if fs.covers(form_cp) {
		mut g := if sg.is_mark {
			fs.mark_glyph(form_cp, em_px)
		} else {
			fs.glyph_variation_in(ctx, form_cp, sg.selectors, em_px)
		}
		g.form = sg.form
		// When the presentation form is not the base letter, remember the base glyph for mark
		// attachment. Anchors are written against base glyphs, so without this a mark on a
		// presentation-form letter finds no anchor. The lookup is a cmap query, not a shaping.
		if sg.base.len > 0 && sg.base[0] != form_cp {
			if bf := fs.pick_in(ctx, sg.base[0]) {
				g.base_gid = bf.glyph_index(sg.base[0])
			}
		}
		return [g]
	}

	mut out := []Glyph{cap: sg.base.len}
	for i, cp in sg.base {
		mut form := if i == 0 || sg.form == .isolated { sg.form } else { JoiningForm.final }
		// A lam split out of a lam-alef fusion the font cannot draw is medial when the
		// pair was joined: it joins the alef ahead of it as well as the letter behind.
		// The pair's final form on the lam would skip the medial-masked lookups below.
		if i == 0 && sg.base.len == 2 && cp == 0x0644 && sg.form == .final {
			form = .medial
		}
		// The selectors belong to the character as a whole, so every glyph it was split into gets
		// them. A format 13 subtable is exactly the case where it happens: one glyph standing for
		// two codepoints, and the selector that came after the second belongs to both.
		selectors := if i == 0 { sg.selectors } else { []rune{} }
		mut g := if sg.is_mark {
			fs.mark_glyph(cp, em_px)
		} else {
			fs.glyph_variation_in(ctx, cp, selectors, em_px)
		}
		g.form = form
		out << g
	}
	return out
}
