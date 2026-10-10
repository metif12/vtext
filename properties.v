module vtext

// The property accessors return small enums whose ordinals match the generated
// value name tables exactly. The enums are hand written rather than generated
// because several UCD value names are V keywords (`in`, `as`, `is`) and could not
// be enum fields.

// BidiClass is the UAX#9 bidirectional category of a codepoint.
pub enum BidiClass {
	l          = 0
	r          = 1
	en         = 2
	es         = 3
	et         = 4
	an         = 5
	cs         = 6
	b          = 7
	s          = 8
	ws         = 9
	on         = 10
	bn         = 11
	nsm        = 12
	al         = 13
	lro        = 14
	rlo        = 15
	lre        = 16
	rle        = 17
	pdf        = 18
	lri        = 19
	rli        = 20
	fsi        = 21
	pdi        = 22
	// x9_removed and .class_none are not UCD values. They sit above every real class
	// so the generated name table, which stops at pdi, reports them as unnamed.
	//
	// x9_removed marks a character rule X9 took out of the text, and .class_none is
	// what a scan returns when it found no class at all.
	x9_removed = 254
	class_none = 255
}

// str returns the UCD name of the class, e.g. 'AL'. It reads the generated name
// table, which needs a Properties value, so callers that have one should use
// Properties.bidi_class_name instead; this exists for logging and test failures.
pub fn (c BidiClass) str() string {
	return ucd_name(bidi_class_names_data, int(c))
}

// ucd_name returns the nth line of a generated value name table.
fn ucd_name(data string, index int) string {
	if index < 0 {
		return ''
	}
	mut i := 0
	mut line_start := 0
	for pos in 0 .. data.len {
		if data[pos] == `\n` {
			if i == index {
				return data[line_start..pos]
			}
			i++
			line_start = pos + 1
		}
	}
	return ''
}

// is_rtl reports whether the class has a right-to-base direction.
pub fn (c BidiClass) is_rtl() bool {
	return c in [.r, .al]
}

// is_neutral_or_isolate reports whether the class is a neutral or an isolate,
// which UAX#9 resolves through rules N1 and N2.
pub fn (c BidiClass) is_neutral_or_isolate() bool {
	return c in [.ws, .on, .b, .s, .lri, .rli, .fsi, .pdi]
}

// is_removed_by_x9 reports whether rule X9 removes the character before any
// explicit level is applied, i.e. the embedding, override and pop controls plus
// the format characters.
pub fn (c BidiClass) is_removed_by_x9() bool {
	return c in [.rle, .lre, .rlo, .lro, .pdf, .bn]
}

// JoiningType is the Joining_Type property from ArabicShaping.txt.
pub enum JoiningType {
	u = 0 // non-joining
	c = 1 // join causing
	d = 2 // dual joining
	r = 3 // right joining
	l = 4 // left joining
	t = 5 // transparent
}

// joining_type_name is a joining type as a word rather than as a number.
//
// The specification names six of them and the letters u, c, d, r, l and t are an abbreviation the reader
// has to look up. A joining decision reported as "d connects forward, u does not" is a sentence about the
// text; the same decision reported as "2 vs 0" is a lookup, and it is the kind of lookup that gets
// remembered wrong. The words are the specification's own, so there is nothing here to translate.
pub fn (jt JoiningType) name() string {
	return match jt {
		.u { 'non-joining' }
		.c { 'join-causing' }
		.d { 'dual-joining' }
		.r { 'right-joining' }
		.l { 'left-joining' }
		.t { 'transparent' }
	}
}

// joins_to_previous reports whether a letter of this type can connect to the character
// before it in the text.
//
// The name follows the logical order, not the visual one, which is the opposite for
// right-to-left script and is the usual source of confusion here. A right joining letter
// connects to what precedes it: alef in the two letters alef and beh takes its final
// form, because the beh that follows it logically sits to its left on screen and joins
// into it.
pub fn (t JoiningType) joins_to_previous() bool {
	return t in [.d, .r, .c]
}

// joins_to_next reports whether a letter of this type can connect to the character after
// it in the text. A left joining letter is the mirror image of a right joining one.
pub fn (t JoiningType) joins_to_next() bool {
	return t in [.d, .l, .c]
}

// takes_a_shape reports whether the letter is one whose shape depends on its neighbours.
// A join causing character holds a connection open without being a letter itself, so it
// connects on both sides and still takes a shape of its own.
pub fn (t JoiningType) takes_a_shape() bool {
	return t in [.d, .r, .l, .c]
}

// is_transparent reports whether the character is a combining mark that is
// skipped when deciding joins.
pub fn (t JoiningType) is_transparent() bool {
	return t == .t
}

// GraphemeClass is the UAX#29 grapheme cluster break property.
pub enum GraphemeClass {
	other              = 0
	cr                 = 1
	lf                 = 2
	control            = 3
	extend             = 4
	zwj                = 5
	regional_indicator = 6
	prepend            = 7
	spacing_mark       = 8
	l                  = 9
	v                  = 10
	t                  = 11
	lv                 = 12
	lvt                = 13
}

// LineBreakClass is the UAX#14 line break class. The names follow LineBreak.txt;
// the ones that would collide with V keywords are spelled out.
pub enum LineBreakClass {
	xx   = 0 // unknown
	cm   = 1 // combining mark
	ba   = 2 // break after
	lf   = 3
	bk   = 4 // mandatory break
	cr   = 5
	sp   = 6 // space
	ex   = 7 // exclamation
	qu   = 8 // quotation
	al   = 9 // alphabetic
	pr   = 10 // prefix numeric
	po   = 11 // postfix numeric
	op   = 12 // open punctuation
	cp   = 13 // close punctuation
	insp = 14 // inseparable
	hy   = 15 // hyphen
	sy   = 16 // symbols allowing a break after
	nu   = 17 // numeric
	cl   = 18 // close
	nl   = 19 // newline
	gl   = 20 // glue
	ai   = 21 // ambiguous
	hh   = 22 // hard hyphen
	bb   = 23 // break before
	hl   = 24 // Hebrew letter
	sa   = 25 // complex context
	jl   = 26 // Hangul jamo L
	jv   = 27 // Hangul jamo V
	jt   = 28 // Hangul jamo T
	ns   = 29 // nonstarter
	ak   = 30 // Aksara
	vi   = 31 // virama final
	idas = 32 // ideographic
	idcj = 33 // ideographic close
	vf   = 34 // virama final, ideographic
	zw   = 35 // ZW space
	zwj  = 36 // ZWJ
	b2   = 37 // break opportunity before and after
	wj   = 39 // WJ
	eb   = 40 // emoji base
	cj   = 41 // conditional Japanese starter
	h2   = 42
	h3   = 43
	sg   = 44
	cb   = 45 // contingency break
	ap   = 46 // Aksara pre-base
	ri   = 47 // regional indicator
	em   = 48 // emoji modifier
}

// infx is the inseparable numeric infix, U+2026 ONE DOT LEADER and the ellipsis, which LB22 holds to
// what follows it. It is spelled out because `in` is a V keyword, the way `.insp` is for IS above.
//
// It is a separate member from `.insp` because the two classes are separate in the UCD and identical
// in every rule this engine applies, so folding them would have been the smaller table and the
// wrong one: a line may not begin with either, and a caller asking which class a character is gets
// a different answer for a comma than for an ellipsis.
//
// The cast is unsafe for the same reason `line_break_of`'s own is, and for the same short while:
// the ordinal comes from a generated table that `test_value_tables_match_the_enums` holds in step,
// and 38 is inside it by construction rather than by hope.
const infx = unsafe { LineBreakClass(38) }

// str returns the UCD name of the class, e.g. 'AL'.
pub fn (c LineBreakClass) str() string {
	return ucd_name(line_break_names_data, int(c))
}

// lookup_range returns the property value of cp, or default_value when cp is in
// no listed range. Every property reserves ordinal 0 for its default, so a
// missing range is indistinguishable from an explicit default - which is exactly
// what the UCD's @missing lines say.
fn lookup_range(ranges []CodeRange, cp u32, default_value u16) u16 {
	mut lo := 0
	mut hi := ranges.len
	// Find one past the last range whose lo is <= cp.
	for lo < hi {
		mid := (lo + hi) >> 1
		if ranges[mid].lo <= cp {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {
		return default_value
	}
	r := ranges[lo - 1]
	if cp > r.hi {
		return default_value
	}
	return r.value
}

// enum_ordinal bounds-checks a table ordinal before it is cast to an enum. The
// generated name table and the hand written enum are kept in step by
// test_value_tables_match_the_enums, so an out-of-range ordinal can only mean a
// stale generated file; it degrades to the default rather than becoming an
// out-of-bounds enum value.
fn enum_ordinal(ordinal u16, name_count int, default_ordinal int) int {
	return if int(ordinal) < name_count { int(ordinal) } else { default_ordinal }
}

// bidi_class_of returns the UAX#9 bidirectional category of cp. Codepoints with
// no listed range are L, which is what the UCD's @missing line specifies.
pub fn (p &Properties) bidi_class_of(cp rune) BidiClass {
	o := enum_ordinal(lookup_range(p.bidi_ranges, u32(cp), 0), p.bidi_names.len,
		int(BidiClass.l))
	return unsafe { BidiClass(o) }
}

// bidi_class_name returns the UCD name of cp's bidi class, e.g. 'AL'.
pub fn (p &Properties) bidi_class_name(cp rune) string {
	c := p.bidi_class_of(cp)
	return p.bidi_names[int(c)]
}

// joining_type_of returns the Joining_Type of cp. U (non-joining) is the default.
pub fn (p &Properties) joining_type_of(cp rune) JoiningType {
	o := enum_ordinal(lookup_range(p.joining_ranges, u32(cp), 0), p.joining_names.len,
		int(JoiningType.u))
	return unsafe { JoiningType(o) }
}

// joining_group_of returns the index of cp's Joining_Group, or 0 when it has none.
pub fn (p &Properties) joining_group_of(cp rune) int {
	return int(lookup_range(p.group_ranges, u32(cp), 0))
}

// joining_group_name returns cp's Joining_Group name, or '' when it has none.
pub fn (p &Properties) joining_group_name(cp rune) string {
	idx := p.joining_group_of(cp)
	if idx >= p.group_names.len {
		return ''
	}
	return p.group_names[idx]
}

// combining_class_of returns the canonical combining class of cp. Marks that
// combine at the same position and share a class keep their input order.
pub fn (p &Properties) combining_class_of(cp rune) int {
	return int(lookup_range(p.combining_ranges, u32(cp), 0))
}

// script_of returns the index of cp's script, or 0 for Unknown.
pub fn (p &Properties) script_of(cp rune) int {
	return int(lookup_range(p.script_ranges, u32(cp), 0))
}

// script_tag_of returns the ISO 15924 tag of cp's script. 'Zzzz' means the
// script is not one Unicode names; 'Zyyy' is Common and 'Zinh' is inherited.
pub fn (p &Properties) script_tag_of(cp rune) string {
	idx := p.script_of(cp)
	if idx >= p.script_names.len {
		return 'Zzzz'
	}
	return p.script_names[idx]
}

// grapheme_class_of returns the UAX#29 grapheme break class of cp.
pub fn (p &Properties) grapheme_class_of(cp rune) GraphemeClass {
	o := enum_ordinal(lookup_range(p.grapheme_ranges, u32(cp), 0), p.grapheme_names.len,
		int(GraphemeClass.other))
	return unsafe { GraphemeClass(o) }
}

// line_break_of returns the UAX#14 line break class of cp.
pub fn (p &Properties) line_break_of(cp rune) LineBreakClass {
	o := enum_ordinal(lookup_range(p.linebreak_ranges, u32(cp), 0), p.linebreak_names.len,
		int(LineBreakClass.xx))
	return unsafe { LineBreakClass(o) }
}

// QuoteRole is which of the three quotation classes a quotation mark belongs to.
//
// UAX #14 assigns one line break class, QU, to all of them, and then splits it back into
// three the moment a rule has to tell them apart: an opening mark is not a closing one, and
// a mark that can be either is neither. The test file writes them QU_Pi, QU_Pf and
// QUmPimPf, and the split is what makes `SP × QU` break for U+00AB and refuse to break for
// U+00BB. Unicode 18.0.0 has 39 codepoints the line break table calls QU: 12 open, 10 close
// and 17 can do either.
pub enum QuoteRole {
	none = 0 // not a quotation mark at all
	pi   = 1 // an opening mark: U+00AB, U+201C
	pf   = 2 // a closing mark: U+00BB, U+201D
	both = 3 // a mark that can be either: U+0022, U+0027
}

// str returns the ordinal's name from the generated table, which is what keeps this enum and
// the ordinals tools/gen_tables.v writes in step with each other.
pub fn (r QuoteRole) str() string {
	return ucd_name(quote_role_names_data, int(r))
}

// quote_role_of returns the quotation role of cp.
//
// The line break table cannot carry this: LineBreak.txt has one QU for all three, so the
// distinction is read from the general category by tools/gen_tables.v and written to
// ucd_quote.v, exactly as the bidi class and the joining type are.
fn quote_role_of(ranges []CodeRange, cp rune) QuoteRole {
	o := lookup_range(ranges, u32(cp), 0)
	return unsafe { QuoteRole(o) }
}

// quote_ranges decodes the generated quotation role table.
//
// It is decoded by the caller rather than held on Properties, and that is a choice about the size of
// the table: 28 ranges, read by two rules, so a caller pays one small decode per call instead of
// every Properties value in the library carrying a table whose other three values are almost never
// asked for.
fn quote_ranges() []CodeRange {
	return parse_ranges(quote_ranges_data)
}

// line_break_name returns the UCD name of cp's line break class, e.g. 'AL'.
pub fn (p &Properties) line_break_name(cp rune) string {
	c := p.line_break_of(cp)
	if int(c) >= p.linebreak_names.len {
		return ''
	}
	return p.linebreak_names[int(c)]
}

// joining_type_name is a codepoint's joining type as a word rather than as a number.
//
// The specification's own abbreviations are u, c, d, r, l and t, and a report that prints one of those is a
// report the reader has to look up. The words are the specification's names for the same six values, so
// there is nothing here to translate and nothing that can drift from the table.
pub fn (p &Properties) joining_type_name(cp rune) string {
	return p.joining_type_of(cp).name()
}

// is_arabic_script reports whether cp belongs to the Arabic script, which is what
// turns on joining behaviour and the arabic shaping features.
pub fn (p &Properties) is_arabic_script(cp rune) bool {
	return p.script_tag_of(cp) == 'Arab'
}

// is_mark reports whether cp is a combining mark for the purposes of canonical
// ordering. A nonzero combining class is the operative signal; the exact
// General_Category test lives in the OpenType engine where it matters.
pub fn (p &Properties) is_mark(cp rune) bool {
	return p.combining_class_of(cp) != 0
}

// is_variation_selector reports whether cp is a variation selector, which selects one of the glyphs a
// font offers for the character in front of it.
//
// There are 256 of them in two blocks, U+FE00 to U+FE0F and U+E0100 to U+E01EF. The ranges are
// written out rather than taken from a generated table because they have not changed since Unicode
// 4.0 and are named by the specification itself; adding a table for them would be a lookup table with
// one row that can never gain another.
//
// This exists because a selector is the one character this library's shaping used to throw away, and
// the reason it was thrown away is instructive. A selector has combining class zero and joining type
// Transparent, which is exactly the shape of an invisible format character like a ZWNJ: transparent
// so it does not break the join, and zero so it is not a mark that needs placing on the letter. So
// attach_marks discarded it without a glyph, correctly for a ZWNJ and wrongly for a selector. Nothing
// about a selector is invisible — it changes which glyph is drawn.
pub fn (p &Properties) is_variation_selector(cp rune) bool {
	return (cp >= 0xFE00 && cp <= 0xFE0F) || (cp >= 0xE0100 && cp <= 0xE01EF)
}
