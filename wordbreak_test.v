module harfara

import os
import harfara.layout
import harfara.ucd

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

// ------------------------------------------------------------------ conformance

// run_word_file runs every case in a WordBreakTest-shaped file and returns
// passed and total.
fn run_word_file(path string, t layout.WordTables, opt layout.WordOpts) (int, int) {
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
		got := layout.word_breaks(cps, t, opt)
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
fn run_sentence_file(path string, t layout.SentenceTables, opt layout.SentenceOpts) (int, int) {
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
		got := layout.sentence_breaks(cps, t, opt)
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
	t := layout.word_tables()
	passed, total := run_word_file(os.join_path('ucd', 'WordBreakTest.txt'), t, layout.WordOpts{})
	assert total == 1944, 'the whole test file was read, got ${total} cases'
	println('UAX #29 word conformance: ${passed}/${total}')
	assert passed >= word_conformance_floor, 'conformance fell below the floor: ${passed} of ${total}, floor ${word_conformance_floor}'
}

fn test_sentence_breaking_conformance_against_the_unicode_test() {
	t := layout.sentence_tables()
	passed, total := run_sentence_file(os.join_path('ucd', 'SentenceBreakTest.txt'), t,
		layout.SentenceOpts{})
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
	t := layout.word_tables()
	cps := [rune(0x0061), rune(0x0308), rune(0x0062)]
	joined := layout.word_breaks(cps, t, layout.WordOpts{})
	assert joined == [true, false, false, true], 'WB4 holds the mark to its base'
	neutered := layout.word_breaks(cps, t, layout.WordOpts{ skip_wb4: true })
	assert neutered == [true, true, false, true], 'without WB4 the mark parts from its base'
	passed, total := run_word_file(os.join_path('ucd', 'WordBreakTest.txt'), t,
		layout.WordOpts{ skip_wb4: true })
	println('UAX #29 word conformance without WB4: ${passed}/${total}')
	assert passed < word_conformance_floor, 'neutering WB4 must move the score: ${passed}/${total}'
}

// Dropping every Regional_Indicator range must break the flag pairs: two RIs
// part, and the full-file score falls under the floor.
fn test_word_conformance_needs_the_ri_ranges() {
	t := layout.word_tables()
	cps := [rune(0x1F1E6), rune(0x1F1E7)]
	joined := layout.word_breaks(cps, t, layout.WordOpts{})
	assert joined == [true, false, true], 'two RIs are one flag'
	dropped := layout.word_breaks(cps, t, layout.WordOpts{ drop_ri: true })
	assert dropped == [true, true, true], 'without the RI ranges two RIs part'
	passed, total := run_word_file(os.join_path('ucd', 'WordBreakTest.txt'), t,
		layout.WordOpts{ drop_ri: true })
	println('UAX #29 word conformance without RI ranges: ${passed}/${total}')
	assert passed < word_conformance_floor, 'dropping the RI ranges must move the score: ${passed}/${total}'
}

// Neutering SB8a must break the terminator holds: "!" parts from "!", and the
// full-file score falls under the floor.
fn test_sentence_conformance_needs_sb8a() {
	t := layout.sentence_tables()
	cps := [rune(`!`), rune(`!`)]
	joined := layout.sentence_breaks(cps, t, layout.SentenceOpts{})
	assert joined == [true, false, true], 'SB8a holds a terminator to a terminator'
	neutered := layout.sentence_breaks(cps, t, layout.SentenceOpts{ skip_sb8a: true })
	assert neutered == [true, true, true], 'without SB8a the terminators part'
	passed, total := run_sentence_file(os.join_path('ucd', 'SentenceBreakTest.txt'), t,
		layout.SentenceOpts{ skip_sb8a: true })
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
	t := layout.word_tables()
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
	t := layout.sentence_tables()
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
	t := layout.word_tables()
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
	t := layout.sentence_tables()
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
