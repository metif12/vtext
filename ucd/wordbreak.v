module ucd

// Word and sentence break lookups for UAX #29.
//
// The generated tables in ucd_wordbreak.v and ucd_sentence.v are decoded on
// demand by the caller, the way quote_ranges and sa_mark_ranges are, and for
// the same reason: a few hundred ranges asked about only where a boundary
// rule needs them, so a caller pays one small decode per run instead of every
// Properties value in the library carrying tables nothing outside a boundary
// test is ever asked about. The hand written enums below are kept in step
// with the generated ordinals by wordbreak_test.v, the way
// test_value_tables_match_the_enums does for the older properties.

// WordBreakClass is the UAX#29 word break class of a codepoint. The ordinals
// match word_break_names_data, which is why Other leads: it is the @missing
// default, so an absent range reads as Other.
pub enum WordBreakClass {
	other              = 0
	cr                 = 1
	lf                 = 2
	newline            = 3
	extend             = 4
	zwj                = 5
	regional_indicator = 6
	format             = 7
	katakana           = 8
	hebrew_letter      = 9
	aletter            = 10
	single_quote       = 11
	double_quote       = 12
	midnumlet          = 13
	midletter          = 14
	midnum             = 15
	numeric            = 16
	extendnumlet       = 17
	wsegspace          = 18
}

// str returns the UCD name of the class, e.g. 'ALetter'. It reads the
// generated name table, which is what keeps this enum and the ordinals
// tools/gen_wordbreak.v writes in step with each other.
pub fn (c WordBreakClass) str() string {
	return ucd_name(word_break_names_data, int(c))
}

// word_break_ranges decodes the generated word break table.
pub fn word_break_ranges() []CodeRange {
	return parse_ranges(word_break_ranges_data)
}

// word_break_of returns the UAX#29 word break class of cp. Codepoints with no
// listed range are Other, which is what the UCD's @missing line specifies.
pub fn word_break_of(ranges []CodeRange, cp rune) WordBreakClass {
	o := lookup_range(ranges, u32(cp), 0)
	return unsafe { WordBreakClass(o) }
}

// word_ep_ranges decodes the generated extended-pictograph table, the
// caller-decoded way for the caller-decoded reason: a few hundred ranges,
// asked about only next to a ZWJ, which is the one place WB3c looks.
pub fn word_ep_ranges() []CodeRange {
	return parse_ranges(word_ep_ranges_data)
}

// is_word_ep reports whether cp is an extended pictograph: the right-hand
// side WB3c holds a ZWJ to.
pub fn is_word_ep(ranges []CodeRange, cp rune) bool {
	return lookup_range(ranges, u32(cp), 0) == 1
}

// SentenceBreakClass is the UAX#29 sentence break class of a codepoint. The
// ordinals match sentence_break_names_data, with Other leading as the
// @missing default.
pub enum SentenceBreakClass {
	other     = 0
	cr        = 1
	lf        = 2
	extend    = 3
	sep       = 4
	format    = 5
	sp        = 6
	lower     = 7
	upper     = 8
	oletter   = 9
	numeric   = 10
	aterm     = 11
	scontinue = 12
	sterm     = 13
	close     = 14
}

// str returns the UCD name of the class, e.g. 'ATerm'.
pub fn (c SentenceBreakClass) str() string {
	return ucd_name(sentence_break_names_data, int(c))
}

// sentence_break_ranges decodes the generated sentence break table.
pub fn sentence_break_ranges() []CodeRange {
	return parse_ranges(sentence_break_ranges_data)
}

// sentence_break_of returns the UAX#29 sentence break class of cp.
// Codepoints with no listed range are Other.
pub fn sentence_break_of(ranges []CodeRange, cp rune) SentenceBreakClass {
	o := lookup_range(ranges, u32(cp), 0)
	return unsafe { SentenceBreakClass(o) }
}
