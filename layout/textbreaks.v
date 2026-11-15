module layout

import vtext.ucd

// Word and sentence boundary engines for UAX #29.
//
// Promoted from the conformance test that proved them: the committee
// files in wordbreak_test.v run these exact functions as the floor,
// and the log-attr pass below answers editors from the same decisions.
// Break-fix knobs (WordOpts/SentenceOpts) stay on the structs: the
// score must depend on the machinery, and the test neuters each knob.

// ---------------------------------------------------------------- word engine

// WordTables carries the decoded UAX #29 word tables the engine asks.
pub struct WordTables {
pub:
	wb []ucd.CodeRange
	ep []ucd.CodeRange
}

// WordOpts are the break-fix knobs. Both default to false; setting one
// neuters the named piece and must move the conformance score, which is what
// proves the passing score actually depends on it.
pub struct WordOpts {
pub:
	// skip_wb4 neuters WB4's no-break arm: Extend, Format and ZWJ stop
	// holding to the character before them.
	skip_wb4 bool
	// drop_ri decodes the table with every Regional_Indicator range
	// removed, so an RI reads as Other.
	drop_ri bool
}

// word_tables decodes the generated tables once per run.
pub fn word_tables() WordTables {
	return WordTables{
		wb: ucd.word_break_ranges()
		ep: ucd.word_ep_ranges()
	}
}

// wb_class_of returns the word class of cp, honouring the RI control.
fn wb_class_of(t WordTables, opt WordOpts, cp rune) ucd.WordBreakClass {
	c := ucd.word_break_of(t.wb, cp)
	if opt.drop_ri && c == .regional_indicator {
		return .other
	}
	return c
}

// wb_is_extend_format_zwj reports whether c is one of the characters WB4
// ignores.
fn wb_is_extend_format_zwj(c ucd.WordBreakClass) bool {
	return c == .extend || c == .format || c == .zwj
}

// wb_is_ahletter reports the WB macro (ALetter | Hebrew_Letter).
fn wb_is_ahletter(c ucd.WordBreakClass) bool {
	return c == .aletter || c == .hebrew_letter
}

// wb_left returns the index of the nearest character at or before i that WB4
// does not ignore, or -1 when there is none: sot, or the run back hitting a
// newline the ignore rule stops at.
fn wb_left(cls []ucd.WordBreakClass, i int) int {
	mut j := i
	for j >= 0 {
		if !wb_is_extend_format_zwj(cls[j]) {
			return j
		}
		j--
	}
	return -1
}

// wb_right returns the index of the nearest character at or after i that WB4
// does not ignore, or -1 for eot.
fn wb_right(cls []ucd.WordBreakClass, i int) int {
	mut j := i
	for j < cls.len {
		if !wb_is_extend_format_zwj(cls[j]) {
			return j
		}
		j++
	}
	return -1
}

// wb_class_at returns cls[j], or `other` for a sentinel. Only sot reaches
// here as -1 on the left; eot on the right is handled by WB2 before any rule
// reads a class through it.
fn wb_class_at(cls []ucd.WordBreakClass, j int) ucd.WordBreakClass {
	if j < 0 || j >= cls.len {
		return .other
	}
	return cls[j]
}

// wb_ri_odd counts the Regional_Indicators immediately to the left of boundary
// i, skipping the characters WB4 ignores, and reports whether the count is
// odd. WB15 and WB16 both forbid the break on an odd run; they differ only in
// what precedes the run, which no × rule needs.
fn wb_ri_odd(cls []ucd.WordBreakClass, i int) bool {
	mut k := 0
	mut j := wb_left(cls, i - 1)
	for j >= 0 && cls[j] == .regional_indicator {
		k++
		j = wb_left(cls, j - 1)
	}
	return k % 2 == 1
}

// word_break_at decides the boundary before cps[i]: i == 0 is sot and i ==
// cps.len is eot. The rules run in UAX #29 order and the first one that
// answers ends the search.
fn word_break_at(cps []rune, cls []ucd.WordBreakClass, t WordTables, opt WordOpts, i int) bool {
	n := cps.len
	if i == 0 {
		return true // WB1: sot ÷
	}
	if i == n {
		return true // WB2: ÷ eot
	}
	left_raw := cls[i - 1]
	right_raw := cls[i]
	if left_raw == .cr && right_raw == .lf {
		return false // WB3: × CR × LF
	}
	if left_raw == .newline || left_raw == .cr || left_raw == .lf {
		return true // WB3a: (Newline | CR | LF) ÷
	}
	if right_raw == .newline || right_raw == .cr || right_raw == .lf {
		return true // WB3b: ÷ (Newline | CR | LF)
	}
	if left_raw == .zwj && ucd.is_word_ep(t.ep, cps[i]) {
		return false // WB3c: ZWJ × Extended_Pictographic
	}
	if left_raw == .wsegspace && right_raw == .wsegspace {
		return false // WB3d: WSegSpace × WSegSpace
	}
	if !opt.skip_wb4 && wb_is_extend_format_zwj(right_raw) {
		return false // WB4: Any × (Format | Extend | ZWJ)
	}
	// Every rule below reads through the ignored characters: the left side
	// takes the nearest kept character back, the right side's second value
	// the nearest kept one forward.
	li := wb_left(cls, i - 1)
	left := wb_class_at(cls, li)
	l1 := wb_class_at(cls, wb_left(cls, li - 1))
	right := right_raw
	r1 := wb_class_at(cls, wb_right(cls, i + 1))
	ah := wb_is_ahletter(left)
	ah_r := wb_is_ahletter(right)
	if ah && ah_r {
		return false // WB5: AHLetter × AHLetter
	}
	if ah && (right == .midletter || right == .midnumlet || right == .single_quote) && wb_is_ahletter(r1) {
		return false // WB6: AHLetter × (MidLetter | MidNumLetQ) AHLetter
	}
	if (left == .midletter || left == .midnumlet || left == .single_quote) && wb_is_ahletter(l1) && ah_r {
		return false // WB7: AHLetter (MidLetter | MidNumLetQ) × AHLetter
	}
	if left == .hebrew_letter && right == .single_quote {
		return false // WB7a: Hebrew_Letter × Single_Quote
	}
	if left == .hebrew_letter && right == .double_quote && r1 == .hebrew_letter {
		return false // WB7b: Hebrew_Letter × Double_Quote Hebrew_Letter
	}
	if left == .double_quote && l1 == .hebrew_letter && right == .hebrew_letter {
		return false // WB7c: Hebrew_Letter Double_Quote × Hebrew_Letter
	}
	if left == .numeric && right == .numeric {
		return false // WB8: Numeric × Numeric
	}
	if ah && right == .numeric {
		return false // WB9: AHLetter × Numeric
	}
	if left == .numeric && ah_r {
		return false // WB10: Numeric × AHLetter
	}
	if (left == .midnum || left == .midnumlet || left == .single_quote) && l1 == .numeric && right == .numeric {
		return false // WB11: Numeric (MidNum | MidNumLetQ) × Numeric
	}
	if left == .numeric && (right == .midnum || right == .midnumlet || right == .single_quote) && r1 == .numeric {
		return false // WB12: Numeric × (MidNum | MidNumLetQ) Numeric
	}
	if left == .katakana && right == .katakana {
		return false // WB13: Katakana × Katakana
	}
	if (ah || left == .numeric || left == .katakana || left == .extendnumlet) && right == .extendnumlet {
		return false // WB13a: (AHLetter | Numeric | Katakana | ExtendNumLet) × ExtendNumLet
	}
	if left == .extendnumlet && (ah_r || right == .numeric || right == .katakana) {
		return false // WB13b: ExtendNumLet × (AHLetter | Numeric | Katakana)
	}
	if right == .regional_indicator && left == .regional_indicator && wb_ri_odd(cls, i) {
		return false // WB15, WB16: sot/[^RI] (RI RI)* RI × RI
	}
	return true // WB999: ÷ Any
}

// word_breaks returns one decision per boundary: index i is the break before
// character i, and index cps.len is the break at the end of the text.
pub fn word_breaks(cps []rune, t WordTables, opt WordOpts) []bool {
	mut cls := []ucd.WordBreakClass{len: cps.len}
	for i, cp in cps {
		cls[i] = wb_class_of(t, opt, cp)
	}
	mut out := []bool{len: cps.len + 1}
	for i in 0 .. cps.len + 1 {
		out[i] = word_break_at(cps, cls, t, opt, i)
	}
	return out
}

// ------------------------------------------------------------ sentence engine

// SentenceTables carries the decoded UAX #29 sentence table.
pub struct SentenceTables {
pub:
	sb []ucd.CodeRange
}

// SentenceOpts are the break-fix knobs for sentences.
pub struct SentenceOpts {
pub:
	// skip_sb8a neuters SB8a: a terminator stops holding to a following
	// SContinue or SATerm.
	skip_sb8a bool
}

// sentence_tables decodes the generated table once per run.
pub fn sentence_tables() SentenceTables {
	return SentenceTables{
		sb: ucd.sentence_break_ranges()
	}
}

// sb_is_ignored reports whether c is one of the characters SB5 ignores.
fn sb_is_ignored(c ucd.SentenceBreakClass) bool {
	return c == .extend || c == .format
}

// sb_is_parasep reports the SB macro ParaSep: Sep | CR | LF.
fn sb_is_parasep(c ucd.SentenceBreakClass) bool {
	return c == .sep || c == .cr || c == .lf
}

// sb_is_saterm reports the SB macro SATerm: STerm | ATerm.
fn sb_is_saterm(c ucd.SentenceBreakClass) bool {
	return c == .sterm || c == .aterm
}

// sb_left returns the index of the nearest character at or before i that SB5
// does not ignore, or -1 for sot.
fn sb_left(cls []ucd.SentenceBreakClass, i int) int {
	mut j := i
	for j >= 0 {
		if !sb_is_ignored(cls[j]) {
			return j
		}
		j--
	}
	return -1
}

// sb_class_at returns cls[j], or `other` for sot.
fn sb_class_at(cls []ucd.SentenceBreakClass, j int) ucd.SentenceBreakClass {
	if j < 0 || j >= cls.len {
		return .other
	}
	return cls[j]
}

// sb_left_term walks the boundary's left side through the ignored characters
// and matches (SATerm | ATerm) Close* Sp*: Closes then Spaces then the
// terminator. allow_sp selects whether Spaces may appear (SB8 through SB11)
// or not (SB9), and saterm selects the terminator set: SATerm for SB8a and SB9
// through SB11, ATerm alone for SB8.
fn sb_left_term(cls []ucd.SentenceBreakClass, i int, allow_sp bool, saterm bool) bool {
	mut seen_close := false
	mut j := sb_left(cls, i - 1)
	for j >= 0 {
		k := cls[j]
		if sb_is_ignored(k) {
			j = sb_left(cls, j - 1)
			continue
		}
		if saterm && k == .sterm {
			return true
		}
		if k == .aterm {
			return true
		}
		if k == .sp {
			if !allow_sp || seen_close {
				return false
			}
			j = sb_left(cls, j - 1)
			continue
		}
		if k == .close {
			seen_close = true
			j = sb_left(cls, j - 1)
			continue
		}
		return false
	}
	return false
}

// sb_after_lower matches the right side of SB8: (¬(OLetter | Upper | Lower |
// ParaSep | SATerm))* Lower, starting at the raw character i. The negation is
// exempt from the ignore rewriting, so this walks raw characters.
fn sb_after_lower(cls []ucd.SentenceBreakClass, i int) bool {
	mut j := i
	for j < cls.len {
		k := cls[j]
		if k == .oletter || k == .upper || k == .lower || sb_is_parasep(k) || sb_is_saterm(k) {
			break
		}
		j++
	}
	return j < cls.len && cls[j] == .lower
}

// sentence_break_at decides the boundary before cps[i], in SB order.
fn sentence_break_at(cps []rune, cls []ucd.SentenceBreakClass, opt SentenceOpts, i int) bool {
	n := cps.len
	if i == 0 {
		return true // SB1: sot ÷
	}
	if i == n {
		return true // SB2: ÷ eot
	}
	left_raw := cls[i - 1]
	right_raw := cls[i]
	if left_raw == .cr && right_raw == .lf {
		return false // SB3: × CR × LF
	}
	if sb_is_parasep(left_raw) {
		return true // SB4: ParaSep ÷
	}
	if sb_is_ignored(right_raw) {
		return false // SB5: Any × (Format | Extend)
	}
	li := sb_left(cls, i - 1)
	left := sb_class_at(cls, li)
	l1 := sb_class_at(cls, sb_left(cls, li - 1))
	if left == .aterm && right_raw == .numeric {
		return false // SB6: ATerm × Numeric
	}
	if left == .aterm && (l1 == .upper || l1 == .lower) && right_raw == .upper {
		return false // SB7: (Upper | Lower) ATerm × Upper
	}
	if sb_left_term(cls, i, true, false) && sb_after_lower(cls, i) {
		return false // SB8: ATerm Close* Sp* × (¬(OLetter | Upper | Lower | ParaSep | SATerm))* Lower
	}
	if !opt.skip_sb8a && sb_left_term(cls, i, true, true) && (right_raw == .scontinue || sb_is_saterm(right_raw)) {
		return false // SB8a: SATerm Close* Sp* × (SContinue | SATerm)
	}
	if sb_left_term(cls, i, false, true) && (right_raw == .close || right_raw == .sp || sb_is_parasep(right_raw)) {
		return false // SB9: SATerm Close* × (Close | Sp | ParaSep)
	}
	if sb_left_term(cls, i, true, true) && (right_raw == .sp || sb_is_parasep(right_raw)) {
		return false // SB10: SATerm Close* Sp* × (Sp | ParaSep)
	}
	if sb_left_term(cls, i, true, true) {
		return true // SB11: SATerm Close* Sp* ParaSep? ÷
	}
	return false // SB998: × Any
}

// sentence_breaks returns one decision per boundary, the way word_breaks
// does.
pub fn sentence_breaks(cps []rune, t SentenceTables, opt SentenceOpts) []bool {
	mut cls := []ucd.SentenceBreakClass{len: cps.len}
	for i, cp in cps {
		cls[i] = ucd.sentence_break_of(t.sb, cp)
	}
	mut out := []bool{len: cps.len + 1}
	for i in 0 .. cps.len + 1 {
		out[i] = sentence_break_at(cps, cls, opt, i)
	}
	return out
}
