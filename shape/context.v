module shape

import vtext.ucd

// Context holds the decoded Unicode tables the pipeline needs, and is built once per
// text system. The tables are immutable, so a single Context can be shared between
// threads and between faces.
//
// Building one costs a few hundred microseconds, which is a lot compared with
// shaping a short string, so this is not something to do per call.
pub struct Context {
pub:
	// properties holds the character properties: bidi class, joining type and group,
	// combining class, script, grapheme class and line break class.
	properties &ucd.Properties
	// normalizer holds the canonical decomposition and composition tables of UAX#15.
	normalizer &Normalizer
	// shaper holds the Arabic presentation forms, which the joining pass maps onto.
	shaper &Shaper
}

// new_context decodes every table. The caller owns the result and keeps it for the
// lifetime of the text system.
pub fn new_context() &Context {
	tables := ucd.new_properties()
	return &Context{
		properties: tables
		normalizer: new_normalizer(*tables)
		shaper:     new_shaper()
	}
}

// normalize_nfd is the canonical decomposition of UAX#15, which is what the pipeline runs before shaping.
//
// This is the decomposition rather than a normalized string, because the indices are what a trace needs: a
// mark written after another mark is reordered ahead of it, and a caller reading the output needs to see
// which input character each resulting codepoint came from.
pub fn (ctx &Context) normalize_nfd(cps []rune) []rune {
	decomposed, _ := ctx.normalizer.nfd_mapped(cps)
	return decomposed
}

// shape_for_trace runs the joining pass over a run in logical order, which is the stage between bidi and
// the font.
//
// The run it returns is the same one layout_paragraph gets, not a copy of it computed differently: a
// trace that reshapes to describe the pipeline would be describing itself.
pub fn (ctx &Context) shape_for_trace(cps []rune) ShapedRun {
	return ctx.shaper.shape_arabic(ctx.properties, cps)
}
