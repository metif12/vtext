module vtext

import os

// Conformance against ucd/NormalizationTest.txt, the UCD's own test data for UAX#15.
//
// The file has five columns per case, and each line asserts a full round trip:
//
//   source; NFC; NFD; NFKC; NFKD
//
// Only the canonical columns apply here. What matters is that both directions agree:
// NFC(NFD(source)) must be NFC, and NFD(NFC(source)) must be NFD. Checking both
// catches an implementation that is idempotent but not truly canonical, which is the
// failure mode a one-direction test misses.

struct NormCase {
	source []rune
	nfc    []rune
	nfd    []rune
	// line is the source line, for a failure message.
	line string
}

// read_data_lines returns the data lines of a UCD file: comments, blank lines and the
// @Part section headers are all dropped.
fn read_data_lines(path string) []string {
	data := os.read_file(path) or { panic('cannot read ${path}: ${err}') }
	mut out := []string{}
	for line in data.split_into_lines() {
		s := line.trim_space()
		if s == '' || s[0] == `#` || s[0] == `@` {
			continue
		}
		out << s
	}
	return out
}

// parse_norm_case reads one @Part section. Columns are numbered from 1, since that is
// how the file labels them.
fn parse_norm_case(line string) ?NormCase {
	// The trailing comment has to go before the fields are split, and a codepoint
	// never contains a semicolon so cutting at the first one is safe.
	cut := line.index('#') or { line.len }
	s := line[..cut].trim_space()
	if s == '' {
		return none
	}
	fields := s.split(';')
	if fields.len < 3 {
		return none
	}
	source := parse_codepoint_column(fields[0])
	nfc := parse_codepoint_column(fields[1])
	nfd := parse_codepoint_column(fields[2])
	if source.len == 0 {
		return none
	}
	return NormCase{ source: source, nfc: nfc, nfd: nfd, line: s }
}

// parse_codepoint_column reads a whitespace separated column of hex codepoints.
fn parse_codepoint_column(field string) []rune {
	mut out := []rune{}
	for tok in field.trim_space().split(' ') {
		if tok != '' {
			out << rune(hex_value(tok))
		}
	}
	return out
}

// codepoints_to_string renders a codepoint sequence the way the test data writes it,
// so a failure message can be compared with the source line by eye.
fn codepoints_to_string(cps []rune) string {
	mut parts := []string{cap: cps.len}
	for c in cps {
		parts << '${u32(c):04X}'
	}
	return parts.join(' ')
}

fn test_ucd_normalization_conformance() {
	props := new_properties()
	n := new_normalizer(props)
	problem := n.check_tables()
	assert problem == '', 'normalization tables are malformed: ${problem}'

	// The quick check is the first thing nfd consults, so a set that answers Yes for
	// a character that actually needs decomposing would short-circuit the whole
	// pipeline. Check a few directly against the data.
	assert !n.is_nfd_qc_yes(rune(0x00E9)), 'U+00E9 must not pass the NFD quick check'
	assert n.is_nfd_qc_yes(rune(0x0065)), 'U+0065 should pass the NFD quick check'
	// A plain ASCII letter has no composition of its own, but the quick check reports
	// on the character rather than on any pair it takes part in, so U+0065 is Yes for
	// NFC: "e" on its own is already in composed form.
	assert n.is_nfc_qc_yes(rune(0x0065)), 'U+0065 should pass the NFC quick check'
	assert n.is_nfc_qc_yes(rune(0x00E9)), 'U+00E9 should pass the NFC quick check'
	// The NFC quick check is about the character, not about the pair it forms: a mark
	// that has no precomposed counterpart of its own is already in composed form. Only
	// the marks that do compose, and the characters excluded from composing, report No.
	assert n.is_nfc_qc_yes(rune(0x0301)), 'U+0301 has no precomposed form of its own'
	assert !n.is_nfc_qc_yes(rune(0x0340)), 'U+0340 has no precomposed form and reports No'

	// And the table itself has to answer for a character the data says decomposes.
	d := n.find_decomposition(0x00E9) or { panic('U+00E9 is missing from the table') }
	assert d.to.len == 2, 'U+00E9 should decompose to two codepoints'
	assert d.to[0] == 0x0065 && d.to[1] == 0x0301, 'U+00E9 decomposes to e + acute'

	lines := read_data_lines('ucd/NormalizationTest.txt')
	assert lines.len > 19000, 'normalization test data looks truncated: ${lines.len} lines'

	mut checked := 0
	mut failures := []string{}

	for line in lines {
		c := parse_norm_case(line) or { continue }
		checked++

		// The source must normalize to each form from the data.
		got_nfc := n.nfc(c.source)
		got_nfd := n.nfd(c.source)
		if codepoints_to_string(got_nfc) != codepoints_to_string(c.nfc) {
			failures << 'NFC of ${codepoints_to_string(c.source)}: got ${codepoints_to_string(got_nfc)} want ${codepoints_to_string(c.nfc)}'
		}
		if codepoints_to_string(got_nfd) != codepoints_to_string(c.nfd) {
			failures << 'NFD of ${codepoints_to_string(c.source)}: got ${codepoints_to_string(got_nfd)} want ${codepoints_to_string(c.nfd)}'
			continue
		}

		// Each form has to be a fixed point of itself, and of the other.
		if codepoints_to_string(n.nfc(got_nfc)) != codepoints_to_string(got_nfc) {
			failures << 'NFC is not idempotent for ${codepoints_to_string(c.source)}'
		}
		if codepoints_to_string(n.nfd(got_nfd)) != codepoints_to_string(got_nfd) {
			failures << 'NFD is not idempotent for ${codepoints_to_string(c.source)}'
		}
		// Decomposing a composed form has to give the same characters back.
		if codepoints_to_string(n.nfd(got_nfc)) != codepoints_to_string(got_nfd) {
			failures << 'NFD(NFC(x)) != NFD(x) for ${codepoints_to_string(c.source)}'
		}
		if codepoints_to_string(n.nfc(got_nfd)) != codepoints_to_string(got_nfc) {
			failures << 'NFC(NFD(x)) != NFC(x) for ${codepoints_to_string(c.source)}'
		}

		// Stop collecting once there are enough to see the pattern; a thousand
		// messages buries the interesting one.
		if failures.len > 1000 {
			break
		}
	}

	println('UAX#15 conformance: ${checked} cases, ${failures.len} failed')
	shown := if failures.len < 10 { failures.len } else { 10 }
	for i in 0 .. shown {
		println(failures[i])
	}
	assert failures.len == 0, '${failures.len} normalization cases failed'
}

// The two forms have to agree on a handful of cases worth reading, so that a
// regression in the tables shows up as a specific character rather than as a count.
fn test_normalize_known_cases() {
	props := new_properties()
	n := new_normalizer(props)

	// A precomposed character with a grave: NFD splits it, NFC puts it back. e with
	// combining acute, and the precomposed form of the same.
	e_acute := runes_of(['00E9'])
	assert codepoints_to_string(n.nfd(e_acute)) == '0065 0301'
	assert codepoints_to_string(n.nfc(runes_of(['0065', '0301']))) == '00E9'

	// A capital D with dot above and dot below composes in one step, which is the case
	// UAX#15 uses to show a decomposition that is more than a pair.
	src := runes_of(['0044', '0307', '0323'])
	// DOT ABOVE is class 230 and DOT BELOW is 220, so NFD has to swap them: the
	// decomposition is only canonical if the marks are in combining class order.
	assert codepoints_to_string(n.nfd(src)) == '0044 0323 0307'
	// Only one composition is available, and it takes the mark that sorts first. The
	// second mark has no precomposed counterpart, so it stays.
	assert codepoints_to_string(n.nfc(src)) == '1E0C 0307'
	assert codepoints_to_string(n.nfc(runes_of(['0044', '0323', '0307']))) == '1E0C 0307'

	// A leading mark has nothing to reorder against and stays put.
	assert codepoints_to_string(n.nfd(runes_of(['0301', '0041']))) == '0301 0041'

	// Built from codepoints rather than literals: a non-ASCII character in this file
	// makes the C backend emit a broken initialiser for a []rune.
	ga := runes_of(['AC00'])
	ga_with_t := runes_of(['AC01'])

	// Hangul composes and decomposes arithmetically rather than from a table. The
	// decomposition is L+V for a syllable with no trailing consonant and L+V+T for one
	// with it, and the consonants are read out of the syllable's own index, so a
	// different L gives a different syllable rather than an offset guess.
	//
	// AC00 is the first syllable, L+V. AC01 is the same with a trailing consonant, so
	// the pair of them separates the two branches.
	assert codepoints_to_string(n.nfd(ga)) == '1100 1161'
	assert codepoints_to_string(n.nfd(ga_with_t)) == '1100 1161 11A8'
	// B2E4 sits far enough into the block that its L is U+1103, HANGUL CHOSEONG IEUNG,
	// which is what makes it a check on the arithmetic rather than on a constant.
	assert codepoints_to_string(n.nfd(runes_of(['B2E4']))) == '1103 1161'
	assert codepoints_to_string(n.nfc(runes_of(['1100', '1161']))) == 'AC00'
	assert codepoints_to_string(n.nfc(runes_of(['1100', '1161', '11A8']))) == 'AC01'
	assert codepoints_to_string(n.nfc(ga)) == 'AC00'
	assert codepoints_to_string(n.nfc(ga_with_t)) == 'AC01'
	// The L+V step has to run before the T step, or a trailing consonant would be lost.
	assert codepoints_to_string(n.nfc(runes_of(['1103', '1161', '11A8']))) == 'B2E5'

	// A character that does not decompose is passed through untouched.
	assert codepoints_to_string(n.nfd('hello'.runes())) == '0068 0065 006C 006C 006F'
	assert codepoints_to_string(n.nfc('hello'.runes())) == '0068 0065 006C 006C 006F'
}

// The decomposition's mapping, which is what keeps a mark attached to the character it was written
// after once canonical ordering has moved it somewhere else.
fn test_nfd_mapped_reports_the_character_a_mark_came_from() {
	n := new_normalizer(new_properties())

	// The case the layout pass depends on. A shadda is class 33 and a fatha class 30, so NFD puts
	// the fatha first even though it was written second, and an index into the decomposed text is
	// not the index the reader's text has.
	src := runes_of(['0628', '0651', '064E'])
	mut got, mut source := n.nfd_mapped(src)
	assert codepoints_to_string(got) == '0628 064E 0651'
	assert source == [0, 2, 1]

	// A character that decomposes into several gives all of them its own index, and they stay
	// together, because the marks and the base they belong to come from one written character.
	// U+00C1 is A-ACUTE, a base and a mark, and it is precomposed, so it is exactly this case.
	got, source = n.nfd_mapped(runes_of(['00C1', '0041']))
	assert codepoints_to_string(got) == '0041 0301 0041'
	assert source == [0, 0, 1]

	// Decomposition can introduce a mark that was never in the input, as a Hangul syllable does
	// when it breaks into jamo. Every one of the jamo belongs to the one syllable.
	got, source = n.nfd_mapped(runes_of(['AC01', '0041']))
	assert codepoints_to_string(got) == '1100 1161 11A8 0041'
	assert source == [0, 0, 0, 1]

	// Text that is already decomposed and in order maps every character to itself, which is the
	// path the layout pass takes for most strings.
	got, source = n.nfd_mapped(runes_of(['0041', '0301']))
	assert codepoints_to_string(got) == '0041 0301'
	assert source == [0, 1]

	// A single character is its own case, and an empty string maps to nothing.
	_, source = n.nfd_mapped(runes_of(['0651']))
	assert source == [0]
	_, source = n.nfd_mapped([])
	assert source.len == 0
}

// runes_of is a test helper that reads a column written the way the UCD writes one.
fn runes_of(fields []string) []rune {
	mut out := []rune{}
	for f in fields {
		out << rune(hex_value(f))
	}
	return out
}
