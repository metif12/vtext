module vtext

// Conformance against the Unicode line breaking test, and a floor under the score.
//
// UAX #14 is specified by example as much as by rule: `ucd/LineBreakTest.txt` is the list of cases the
// committee wrote, and an implementation either agrees with it or does not. Without running it, "partial"
// in the roadmap was a description rather than a number.
//
// The score is a floor rather than an exact figure on purpose. The rules that are missing are listed in the
// roadmap with what each one is, and the useful property is that fixing one cannot be undone by accident.
// A test asserting the current exact count would have to be edited every time a rule lands, which is a
// chance to lower the number while making the test pass.
//
// The file is committed rather than fetched, like the other UCD conformance files here. The licence travels
// with the data and the licence notice is committed beside it.

import os

// conformance_floor is the score this engine must not fall below.
//
// Measured against UCD 18.0.0's LineBreakTest.txt. The floor was 13,402 when the test was written,
// 13,058 before ambiguous characters were resolved to letters, 13,090 after the numeric pairs and a
// run of digits, 13,402 once a line may not also end on a combining mark, and 13,453 once an aksara
// stopped being folded into one.
//
// On 2026-10-10 it became **16,004**, worth 2,551, from rules that had been missing rather than
// wrong. A space was answered at the top of the chain, before any rule about which character may not
// start a line could see it, so `× SP × CL` broke where LB13 refuses; a zero width space, a word
// joiner, glue, a hard break and a contingency break character had no rules at all in the places they
// needed them. The rules that are still missing are listed in the roadmap with what each one is.
const conformance_floor = 16004

// parse_case reads one line of the test file up to its comment and returns the codepoints and the break
// decisions.
//
// The format alternates a marker and a codepoint, with a marker before the first character and one after the
// last, so there is one more marker than characters:
//
//	÷ 0020 × 0041 ÷	#  comment
//
// '÷' is a break opportunity and '×' is a break that must not happen. Decision i is the break before
// character i, and the last one — index cps.len — is the break at the end of the string. All of them are
// returned, because the one at the end is a decision the rules reach: LB2 breaks before the end of text.
fn parse_case(line string) ([]rune, []bool) {
	mut cps := []rune{}
	mut breaks := []bool{}
	for f in line.all_before('#').fields() {
		if f == '÷' || f == '×' {
			breaks << (f == '÷')
		} else {
			cps << rune(hex_word(f))
		}
	}
	return cps, breaks
}

// hex_word reads four or more lowercase hex digits as a number, which is how the file writes a codepoint.
fn hex_word(w string) int {
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

// The score. The whole file is run, and the assertion is a floor, so a rule landing shows up as a raised
// number that somebody chooses to raise the floor to.
fn test_line_breaking_conformance_against_the_unicode_test() {
	path := os.join_path('ucd', 'LineBreakTest.txt')
	content := os.read_file(path) or {
		// A checkout without the UCD data cannot be checked, and saying so is better than reporting a
		// score of zero. The file is committed, so this only happens if it was deleted.
		println('no ${path}; the UCD data is committed, so run tools/fetch_ucd.v if it is missing')
		return
	}
	ctx := new_context()
	mut total := 0
	mut passed := 0
	mut first_failures := []string{}
	for line in content.split('\n') {
		t := line.trim_space()
		if t == '' || t.starts_with('#') {
			continue
		}
		cps, want := parse_case(t)
		if cps.len == 0 {
			continue
		}
		total++
		mut at := map[int]bool{}
		for g in break_opportunities(ctx, cps, false) {
			at[g.start] = true
		}
		mut ok := true
		for i, w in want {
			if w != at[i] {
				ok = false
				if first_failures.len < 6 {
					first_failures << '${t.all_before('#').trim_space()} at ${i}'
				}
				break
			}
		}
		if ok {
			passed++
		}
	}
	assert total > 19000, 'the whole test file was read, got ${total} cases'
	println('UAX #14 conformance: ${passed}/${total}')
	assert passed >= conformance_floor, 'conformance fell below the floor: ${passed} of ${total}, floor ${conformance_floor}. First failures: ${first_failures}'
}

// The ambiguous-width resolution, on its own, because it is a change to a class the rules never matched and
// the conformance number moved by sixteen.
//
// Two ambiguous characters must not break apart: U+2757 is the test file's own example, and the table calls
// it AI, which no pair rule matched, so it fell through to the permissive default at the end of the chain.
fn test_two_ambiguous_characters_stay_together() {
	ctx := new_context()
	// U+2757 U+2757: no break between them, and a break after the run.
	cps := [rune(0x2757), rune(0x2757)]
	mut at := map[int]bool{}
	for g in break_opportunities(ctx, cps, false) {
		at[g.start] = true
	}
	assert !at[1], 'two ambiguous characters are letters, and letters do not part'
	assert at[2], 'and the run still ends'
}
