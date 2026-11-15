module vtext

import os
import vtext.ucd

// Conformance against the Unicode word and sentence breaking tests, and a
// floor under both scores.
//
// UAX #29 is specified by example as much as by rule: `ucd/WordBreakTest.txt`
// and `ucd/SentenceBreakTest.txt` are the lists of cases the committee wrote,
// and an implementation either agrees with them or does not. Without running
// them, "tables" in the roadmap would be bytes rather than answers.
//
// The scores are floors rather than exact figures on purpose, the way
// linebreak_conformance_test.v does it: the useful property is that a rule
// landing — or a table rotting — cannot be undone by accident, not that the
// number stays still.
//
// The files are committed rather than fetched, like `ucd/LineBreakTest.txt`
// before them. The licence travels with the data and the licence notice is
// committed beside it.
//
// The rule engines below live in this test file rather than in a library
// module on purpose: the log-attribute and caret APIs that consume these
// tables are a later roadmap slice, so there is deliberately no production
// break engine yet. What is pinned here is that the tables answer every
// question the rules ask, asked the way UAX #29 asks them.

// word_conformance_floor is the word score this tree must not fall below.
//
// Measured against UCD 18.0.0's WordBreakTest.txt with the engine below: the
// rules are implemented whole (WB1 through WB16 plus WB999), so the floor is
// the whole file.
const word_conformance_floor = 1944

// sentence_conformance_floor is the sentence score this tree must not fall
// below. Measured against UCD 18.0.0's SentenceBreakTest.txt with the engine
// below: SB1 through SB11 plus SB998, the whole file.
const sentence_conformance_floor = 512

// ---------------------------------------------------------------- test parsing

// wb_parse_case reads one line of either conformance file up to its comment
// and returns the codepoints and the break decisions.
//
// The format alternates a marker and a codepoint, with a marker before the
// first character and one after the last, so there is one more marker than
// characters:
//
//	÷ 0020 × 0041 ÷	#  comment
//
// '÷' is a break opportunity and '×' is a break that must not happen.
// Decision i is the break before character i, and the last one — index
// cps.len — is the break at the end of the string. All of them are returned,
// because the one at the end is a decision the rules reach: WB2 and SB2
// break before the end of text.
fn wb_parse_case(line string) ([]rune, []bool) {
	mut cps := []rune{}
	mut breaks := []bool{}
	for f in line.all_before('#').fields() {
		if f == '÷' || f == '×' {
			breaks << (f == '÷')
		} else {
			cps << rune(wb_hex_word(f))
		}
	}
	return cps, breaks
}

// wb_hex_word reads four or more lowercase hex digits as a number, which is
// how the files write a codepoint.
fn wb_hex_word(w string) int {
	mut v := 0
	for ch in w {
		mut d := ch - `0`
		if d > 9 {
			d = ch - `a` + 10
		}
		if d > 15 {
			d = ch - `A` + 10
		}
		v = v * 16 + int(d)
	}
	return v
}

// ---------------------------------------------------------------- word engine

// WordTables carries the decoded UAX #29 word tables the engine asks.
struct WordTables {
	wb []ucd.CodeRange
	ep []ucd.CodeRange
}

// WordOpts are the break-fix knobs. Both default to false; setting one
// neuters the named piece and must move the conformance score, which is what
// proves the passing score actually depends on it.
struct WordOpts {
	// skip_wb4 neuters WB4's no-break arm: Extend, Format and ZWJ stop
	// holding to the character before them.
	skip_wb4 bool
	// drop_ri decodes the table with every Regional_Indicator range
	// removed, so an RI reads as Other.
	drop_ri bool
}

// word_tables decodes the generated tables once per run.
fn word_tables() WordTables {
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
fn word_breaks(cps []rune, t WordTables, opt WordOpts) []bool {
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
struct SentenceTables {
	sb []ucd.CodeRange
}

// SentenceOpts are the break-fix knobs for sentences.
struct SentenceOpts {
	// skip_sb8a neuters SB8a: a terminator stops holding to a following
	// SContinue or SATerm.
	skip_sb8a bool
}

// sentence_tables decodes the generated table once per run.
fn sentence_tables() SentenceTables {
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
fn sentence_breaks(cps []rune, t SentenceTables, opt SentenceOpts) []bool {
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

// ------------------------------------------------------------------ conformance

// run_word_file runs every case in a WordBreakTest-shaped file and returns
// passed and total.
fn run_word_file(path string, t WordTables, opt WordOpts) (int, int) {
	content := os.read_file(path) or { panic('cannot read ${path}: ${err.msg()}') }
	mut total := 0
	mut passed := 0
	for line in content.split_into_lines() {
		trimmed := line.trim_space()
		if trimmed == '' || trimmed.starts_with('#') {
			continue
		}
		cps, want := wb_parse_case(trimmed)
		if cps.len == 0 {
			continue
		}
		total++
		got := word_breaks(cps, t, opt)
		mut ok := got.len == want.len
		if ok {
			for i, w in want {
				if got[i] != w {
					ok = false
					break
				}
			}
		}
		if ok {
			passed++
		}
	}
	return passed, total
}

// run_sentence_file runs every case in a SentenceBreakTest-shaped file.
fn run_sentence_file(path string, t SentenceTables, opt SentenceOpts) (int, int) {
	content := os.read_file(path) or { panic('cannot read ${path}: ${err.msg()}') }
	mut total := 0
	mut passed := 0
	for line in content.split_into_lines() {
		trimmed := line.trim_space()
		if trimmed == '' || trimmed.starts_with('#') {
			continue
		}
		cps, want := wb_parse_case(trimmed)
		if cps.len == 0 {
			continue
		}
		total++
		got := sentence_breaks(cps, t, opt)
		mut ok := got.len == want.len
		if ok {
			for i, w in want {
				if got[i] != w {
					ok = false
					break
				}
			}
		}
		if ok {
			passed++
		}
	}
	return passed, total
}

// The score. The whole file is run, and the assertion is a floor, so a table
// fix shows up as a raised number that somebody chooses to raise the floor
// to.
fn test_word_breaking_conformance_against_the_unicode_test() {
	t := word_tables()
	passed, total := run_word_file(os.join_path('ucd', 'WordBreakTest.txt'), t, WordOpts{})
	assert total == 1944, 'the whole test file was read, got ${total} cases'
	println('UAX #29 word conformance: ${passed}/${total}')
	assert passed >= word_conformance_floor, 'conformance fell below the floor: ${passed} of ${total}, floor ${word_conformance_floor}'
}

fn test_sentence_breaking_conformance_against_the_unicode_test() {
	t := sentence_tables()
	passed, total := run_sentence_file(os.join_path('ucd', 'SentenceBreakTest.txt'), t,
		SentenceOpts{})
	assert total == 512, 'the whole test file was read, got ${total} cases'
	println('UAX #29 sentence conformance: ${passed}/${total}')
	assert passed >= sentence_conformance_floor, 'conformance fell below the floor: ${passed} of ${total}, floor ${sentence_conformance_floor}'
}

// ------------------------------------------------------------------ break-fix controls

// A passing conformance score proves nothing if neutering a rule still
// passes: the score has to depend on the machinery. Each control below takes
// one piece away and shows the floor moving.

// Neutering WB4 must break the Extend holds that carry most of the file: a
// combining mark parts from its base, and the full-file score falls under
// the floor.
fn test_word_conformance_needs_wb4() {
	t := word_tables()
	cps := [rune(0x0061), rune(0x0308), rune(0x0062)]
	joined := word_breaks(cps, t, WordOpts{})
	assert joined == [true, false, false, true], 'WB4 holds the mark to its base'
	neutered := word_breaks(cps, t, WordOpts{ skip_wb4: true })
	assert neutered == [true, true, false, true], 'without WB4 the mark parts from its base'
	passed, total := run_word_file(os.join_path('ucd', 'WordBreakTest.txt'), t,
		WordOpts{ skip_wb4: true })
	println('UAX #29 word conformance without WB4: ${passed}/${total}')
	assert passed < word_conformance_floor, 'neutering WB4 must move the score: ${passed}/${total}'
}

// Dropping every Regional_Indicator range must break the flag pairs: two RIs
// part, and the full-file score falls under the floor.
fn test_word_conformance_needs_the_ri_ranges() {
	t := word_tables()
	cps := [rune(0x1F1E6), rune(0x1F1E7)]
	joined := word_breaks(cps, t, WordOpts{})
	assert joined == [true, false, true], 'two RIs are one flag'
	dropped := word_breaks(cps, t, WordOpts{ drop_ri: true })
	assert dropped == [true, true, true], 'without the RI ranges two RIs part'
	passed, total := run_word_file(os.join_path('ucd', 'WordBreakTest.txt'), t,
		WordOpts{ drop_ri: true })
	println('UAX #29 word conformance without RI ranges: ${passed}/${total}')
	assert passed < word_conformance_floor, 'dropping the RI ranges must move the score: ${passed}/${total}'
}

// Neutering SB8a must break the terminator holds: "!" parts from "!", and the
// full-file score falls under the floor.
fn test_sentence_conformance_needs_sb8a() {
	t := sentence_tables()
	cps := [rune(`!`), rune(`!`)]
	joined := sentence_breaks(cps, t, SentenceOpts{})
	assert joined == [true, false, true], 'SB8a holds a terminator to a terminator'
	neutered := sentence_breaks(cps, t, SentenceOpts{ skip_sb8a: true })
	assert neutered == [true, true, true], 'without SB8a the terminators part'
	passed, total := run_sentence_file(os.join_path('ucd', 'SentenceBreakTest.txt'), t,
		SentenceOpts{ skip_sb8a: true })
	println('UAX #29 sentence conformance without SB8a: ${passed}/${total}')
	assert passed < sentence_conformance_floor, 'neutering SB8a must move the score: ${passed}/${total}'
}

// ------------------------------------------------------------------ table checks

// test_word_value_tables_match_the_enums keeps the hand written enums in step
// with the generated ordinals, the way test_value_tables_match_the_enums does
// for the older properties.
fn test_word_value_tables_match_the_enums() {
	assert ucd.word_break_ranges().len > 1000, 'word table looks truncated'
	assert ucd.sentence_break_ranges().len > 2000, 'sentence table looks truncated'
	assert ucd.word_ep_ranges().len > 50, 'extended-pictograph table looks truncated'

	assert ucd.WordBreakClass.other.str() == 'Other'
	assert ucd.WordBreakClass.cr.str() == 'CR'
	assert ucd.WordBreakClass.lf.str() == 'LF'
	assert ucd.WordBreakClass.newline.str() == 'Newline'
	assert ucd.WordBreakClass.extend.str() == 'Extend'
	assert ucd.WordBreakClass.zwj.str() == 'ZWJ'
	assert ucd.WordBreakClass.regional_indicator.str() == 'Regional_Indicator'
	assert ucd.WordBreakClass.format.str() == 'Format'
	assert ucd.WordBreakClass.katakana.str() == 'Katakana'
	assert ucd.WordBreakClass.hebrew_letter.str() == 'Hebrew_Letter'
	assert ucd.WordBreakClass.aletter.str() == 'ALetter'
	assert ucd.WordBreakClass.single_quote.str() == 'Single_Quote'
	assert ucd.WordBreakClass.double_quote.str() == 'Double_Quote'
	assert ucd.WordBreakClass.midnumlet.str() == 'MidNumLet'
	assert ucd.WordBreakClass.midletter.str() == 'MidLetter'
	assert ucd.WordBreakClass.midnum.str() == 'MidNum'
	assert ucd.WordBreakClass.numeric.str() == 'Numeric'
	assert ucd.WordBreakClass.extendnumlet.str() == 'ExtendNumLet'
	assert ucd.WordBreakClass.wsegspace.str() == 'WSegSpace'

	assert ucd.SentenceBreakClass.other.str() == 'Other'
	assert ucd.SentenceBreakClass.cr.str() == 'CR'
	assert ucd.SentenceBreakClass.lf.str() == 'LF'
	assert ucd.SentenceBreakClass.extend.str() == 'Extend'
	assert ucd.SentenceBreakClass.sep.str() == 'Sep'
	assert ucd.SentenceBreakClass.format.str() == 'Format'
	assert ucd.SentenceBreakClass.sp.str() == 'Sp'
	assert ucd.SentenceBreakClass.lower.str() == 'Lower'
	assert ucd.SentenceBreakClass.upper.str() == 'Upper'
	assert ucd.SentenceBreakClass.oletter.str() == 'OLetter'
	assert ucd.SentenceBreakClass.numeric.str() == 'Numeric'
	assert ucd.SentenceBreakClass.aterm.str() == 'ATerm'
	assert ucd.SentenceBreakClass.scontinue.str() == 'SContinue'
	assert ucd.SentenceBreakClass.sterm.str() == 'STerm'
	assert ucd.SentenceBreakClass.close.str() == 'Close'
}

// test_word_tables_name_known_codepoints pins lookups to characters the UCD
// files themselves list, so a generator reading the wrong column fails here
// rather than somewhere unrelated.
fn test_word_tables_name_known_codepoints() {
	t := word_tables()
	assert ucd.word_break_of(t.wb, rune(0x000D)) == .cr, 'CR'
	assert ucd.word_break_of(t.wb, rune(0x000A)) == .lf, 'LF'
	assert ucd.word_break_of(t.wb, rune(0x0085)) == .newline, 'NEL is Newline'
	assert ucd.word_break_of(t.wb, rune(0x0308)) == .extend, 'combining diaeresis is Extend'
	assert ucd.word_break_of(t.wb, rune(0x200D)) == .zwj, 'ZWJ'
	assert ucd.word_break_of(t.wb, rune(0x1F1E6)) == .regional_indicator, 'RI A'
	assert ucd.word_break_of(t.wb, rune(0x00AD)) == .format, 'soft hyphen is Format'
	assert ucd.word_break_of(t.wb, rune(0x3031)) == .katakana, 'kana repeat mark'
	assert ucd.word_break_of(t.wb, rune(0x05D0)) == .hebrew_letter, 'alef'
	assert ucd.word_break_of(t.wb, rune(0x0041)) == .aletter, 'A'
	assert ucd.word_break_of(t.wb, rune(0x0027)) == .single_quote, 'apostrophe'
	assert ucd.word_break_of(t.wb, rune(0x0022)) == .double_quote, 'quotation mark'
	assert ucd.word_break_of(t.wb, rune(0x002E)) == .midnumlet, 'full stop is MidNumLet'
	assert ucd.word_break_of(t.wb, rune(0x003A)) == .midletter, 'colon is MidLetter'
	assert ucd.word_break_of(t.wb, rune(0x002C)) == .midnum, 'comma is MidNum'
	assert ucd.word_break_of(t.wb, rune(0x0030)) == .numeric, 'zero'
	assert ucd.word_break_of(t.wb, rune(0x005F)) == .extendnumlet, 'low line'
	assert ucd.word_break_of(t.wb, rune(0x0020)) == .wsegspace, 'space'
	assert ucd.word_break_of(t.wb, rune(0x0021)) == .other, 'exclamation is Other for words'
	assert ucd.is_word_ep(t.ep, rune(0x1F600)), 'grinning face is pictographic'
	assert ucd.is_word_ep(t.ep, rune(0x00A9)), 'copyright sign is pictographic'
	assert !ucd.is_word_ep(t.ep, rune(`A`)), 'a letter is not a pictograph'
}

// test_sentence_tables_name_known_codepoints does the same for sentences.
fn test_sentence_tables_name_known_codepoints() {
	t := sentence_tables()
	assert ucd.sentence_break_of(t.sb, rune(0x000D)) == .cr, 'CR'
	assert ucd.sentence_break_of(t.sb, rune(0x000A)) == .lf, 'LF'
	assert ucd.sentence_break_of(t.sb, rune(0x0300)) == .extend, 'combining grave is Extend'
	assert ucd.sentence_break_of(t.sb, rune(0x0085)) == .sep, 'NEL is Sep'
	assert ucd.sentence_break_of(t.sb, rune(0x00AD)) == .format, 'soft hyphen is Format'
	assert ucd.sentence_break_of(t.sb, rune(0x0009)) == .sp, 'tab is Sp'
	assert ucd.sentence_break_of(t.sb, rune(0x0061)) == .lower, 'a'
	assert ucd.sentence_break_of(t.sb, rune(0x0041)) == .upper, 'A'
	assert ucd.sentence_break_of(t.sb, rune(0x01BB)) == .oletter, 'letter two is OLetter'
	assert ucd.sentence_break_of(t.sb, rune(0x0030)) == .numeric, 'zero'
	assert ucd.sentence_break_of(t.sb, rune(0x002E)) == .aterm, 'full stop is ATerm'
	assert ucd.sentence_break_of(t.sb, rune(0x002C)) == .scontinue, 'comma is SContinue'
	assert ucd.sentence_break_of(t.sb, rune(0x0021)) == .sterm, 'exclamation is STerm'
	assert ucd.sentence_break_of(t.sb, rune(0x0022)) == .close, 'quotation mark is Close'
	assert ucd.sentence_break_of(t.sb, rune(0x0020)) == .sp, 'space is Sp'
}

// test_generated_word_table_matches_the_ucd re-reads WordBreakProperty.txt and
// checks every range it lists, the way
// test_generated_bidi_table_matches_the_ucd does for bidi: this is the test
// that would catch the generator reading the wrong column.
fn test_generated_word_table_matches_the_ucd() {
	if !os.exists('ucd') {
		return // the UCD is not vendored here; nothing to compare against
	}
	t := word_tables()
	data := os.read_file('ucd/WordBreakProperty.txt') or { panic(err) }
	mut checked := 0
	for line in data.split_into_lines() {
		cut := line.index('#') or { line.len }
		s := line[..cut].trim_space()
		if s == '' {
			continue
		}
		fields := s.split(';')
		if fields.len < 2 {
			continue
		}
		codes := fields[0].split('..')
		lo := ucd.hex_value(codes[0])
		hi := if codes.len > 1 { ucd.hex_value(codes[1]) } else { lo }
		want := fields[1].trim_space()
		assert ucd.word_break_of(t.wb, rune(lo)).str() == want, 'word class of U+${lo:04X}'
		assert ucd.word_break_of(t.wb, rune(hi)).str() == want, 'word class of U+${hi:04X}'
		checked++
	}
	assert checked > 1000, 'expected many ranges, checked ${checked}'
}

// test_generated_sentence_table_matches_the_ucd does the same for sentences.
fn test_generated_sentence_table_matches_the_ucd() {
	if !os.exists('ucd') {
		return // the UCD is not vendored here; nothing to compare against
	}
	t := sentence_tables()
	data := os.read_file('ucd/SentenceBreakProperty.txt') or { panic(err) }
	mut checked := 0
	for line in data.split_into_lines() {
		cut := line.index('#') or { line.len }
		s := line[..cut].trim_space()
		if s == '' {
			continue
		}
		fields := s.split(';')
		if fields.len < 2 {
			continue
		}
		codes := fields[0].split('..')
		lo := ucd.hex_value(codes[0])
		hi := if codes.len > 1 { ucd.hex_value(codes[1]) } else { lo }
		want := fields[1].trim_space()
		assert ucd.sentence_break_of(t.sb, rune(lo)).str() == want, 'sentence class of U+${lo:04X}'
		assert ucd.sentence_break_of(t.sb, rune(hi)).str() == want, 'sentence class of U+${hi:04X}'
		checked++
	}
	assert checked > 1000, 'expected many ranges, checked ${checked}'
}
