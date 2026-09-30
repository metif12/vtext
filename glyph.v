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
	// it came from and to a caret position.
	cluster int
	// is_mark reports that this glyph is a combining mark: it is drawn at the position of
	// the letter before it and has no advance. Marks are drawn after the letters, so that
	// a mark lands on top of the letter it belongs to instead of under it.
	is_mark bool
	// form is the shape the joining pass chose for this letter. It is carried all the way
	// here because a font that keeps its Arabic shapes in a GSUB table is drawn from the
	// base letter, and picking the right variant of that base letter is what form decides.
	form JoiningForm
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
}

// new_font_set returns an empty chain.
pub fn new_font_set() &FontSet {
	return &FontSet{ fonts: []&Font{} }
}

// new_font_set_of returns a chain of the given fonts, most preferred first.
pub fn new_font_set_of(fonts ...&Font) &FontSet {
	return &FontSet{ fonts: fonts }
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
// own positional features pick the shaped variant of it.
//
// A ligature is the one case that produces more than one glyph, because it stood for two
// letters and both have to be drawn. The lam takes the shape the ligature had. The alef
// connects backwards only when the lam did, so it takes a final form whenever the ligature
// joined to anything and an isolated one when the pair stood on its own.
pub fn (fs &FontSet) shaped_glyphs(sg ShapedGlyph, em_px f64) []Glyph {
	if sg.base.len == 0 {
		return []Glyph{}
	}
	form_cp := sg.cps[0]
	if fs.covers(form_cp) {
		mut g := if sg.is_mark {
			fs.mark_glyph(form_cp, em_px)
		} else {
			fs.glyph(form_cp, em_px)
		}
		g.form = sg.form
		return [g]
	}

	mut out := []Glyph{cap: sg.base.len}
	for i, cp in sg.base {
		form := if i == 0 || sg.form == .isolated { sg.form } else { JoiningForm.final }
		mut g := if sg.is_mark {
			fs.mark_glyph(cp, em_px)
		} else {
			fs.glyph(cp, em_px)
		}
		g.form = form
		reshape(mut g, form, sg.script, em_px)
		out << g
	}
	return out
}

// reshape asks the font for the variant of a base glyph that carries a shape.
//
// The advance has to be re-read afterwards, because a shaped Arabic glyph is a different
// glyph with its own width: a final form is usually narrower than the isolated one, and using
// the base letter's advance would leave the line the wrong width. When the font has no rule
// for the shape the glyph is left as the base letter, which renders correctly but unjoined.
fn reshape(mut g Glyph, form JoiningForm, script string, em_px f64) {
	f := g.font or { return }
	shaped := f.shaped_glyph_index(g.gid, form, script)
	if shaped == g.gid {
		return
	}
	g.gid = shaped
	g.advance = f.glyph_advance(shaped, em_px)
}
