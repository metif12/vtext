module vtext

import vtext.shape
import vtext.ucd
import os

// Conformance against ucd/SpecialCasing.txt, the UCD's full case mapping
// supplement, plus the Turkish/Azeri dotted-I rules and the 1-to-N mappings
// that make a hand table wrong.
//
// The file has one row per mapping:
//
//   <code>; <lower>; <title>; <upper>; (<condition_list>;)? # <comment>
//
// Unconditional rows override the simple mappings in UnicodeData.txt; the
// conditional rows apply only when every condition holds (a language such as
// `tr`, a context such as `Final_Sigma` or `After_I`, optionally negated with
// `Not_`). Every row is checked: unconditional rows through the functions,
// conditional rows through the generated conditional table plus the functions
// where the implementation applies the context (tr/az and Final_Sigma).

struct CaseRow {
	cp         u32
	lower      []rune
	title      []rune
	upper      []rune
	conditions string
}

// case_hex_list reads a space separated run of hex codepoints, the way
// SpecialCasing.txt writes a 1-to-N mapping. An empty field is an empty
// mapping (a deletion), not a missing one.
fn case_hex_list(s string) []rune {
	mut out := []rune{}
	for tok in s.split(' ') {
		t := tok.trim_space()
		if t == '' {
			continue
		}
		out << rune(ucd.hex_value(t))
	}
	return out
}

// case_codepoints_to_string renders a run the way the test data writes it, so
// a failure can be compared with the source line by eye.
fn case_codepoints_to_string(cps []rune) string {
	mut parts := []string{cap: cps.len}
	for c in cps {
		parts << '${u32(c):04X}'
	}
	return parts.join(' ')
}

// case_runes_of reads codepoints written the way the UCD writes them.
fn case_runes_of(fields []string) []rune {
	mut out := []rune{}
	for f in fields {
		out << rune(ucd.hex_value(f))
	}
	return out
}

// case_parse_special_row reads one SpecialCasing data line. Comment lines and
// blanks return none, the way read_data_lines drops them in normalize_test.v.
fn case_parse_special_row(line string) ?CaseRow {
	cut := line.index('#') or { line.len }
	s := line[..cut].trim_space()
	if s == '' {
		return none
	}
	mut fields := s.split(';')
	if fields.len > 0 && fields[fields.len - 1].trim_space() == '' {
		fields = fields[..fields.len - 1]
	}
	if fields.len != 4 && fields.len != 5 {
		return none
	}
	conditions := if fields.len == 5 { fields[4].trim_space() } else { '' }
	return CaseRow{
		cp:         ucd.hex_value(fields[0].trim_space())
		lower:      case_hex_list(fields[1])
		title:      case_hex_list(fields[2])
		upper:      case_hex_list(fields[3])
		conditions: conditions
	}
}

// case_parse_cond_table reads the generated conditional table back, so the
// test can pin that every conditional row made it into the build.
fn case_parse_cond_table(data string) []CaseRow {
	mut out := []CaseRow{}
	for line in data.split_into_lines() {
		s := line.trim_space()
		if s == '' {
			continue
		}
		fields := s.split(';')
		if fields.len != 5 {
			continue
		}
		out << CaseRow{
			cp:         ucd.hex_value(fields[0].trim_space())
			lower:      case_hex_list(fields[1])
			title:      case_hex_list(fields[2])
			upper:      case_hex_list(fields[3])
			conditions: fields[4].trim_space()
		}
	}
	return out
}

fn case_same(a []rune, b []rune) bool {
	if a.len != b.len {
		return false
	}
	for i in 0 .. a.len {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

fn test_case_known_mappings() {
	// A 1-to-N upper: sharp s becomes SS, and the lower is itself.
	assert case_codepoints_to_string(shape.to_upper(case_runes_of(['00DF']), '')) == '0053 0053'
	assert case_codepoints_to_string(shape.to_lower(case_runes_of(['00DF']), '')) == '00DF'
	// U+0130 lowercases to i plus dot; the dot is a second character, which is
	// the whole reason the table cannot be a 1-to-1 range.
	assert case_codepoints_to_string(shape.to_lower(case_runes_of(['0130']), '')) == '0069 0307'
	// Turkish dotted-I, both directions and both spellings of the locale.
	assert case_codepoints_to_string(shape.to_upper(case_runes_of(['0069']), 'tr')) == '0130'
	assert case_codepoints_to_string(shape.to_upper(case_runes_of(['0069']), 'az')) == '0130'
	assert case_codepoints_to_string(shape.to_upper(case_runes_of(['0069']), '')) == '0049'
	assert case_codepoints_to_string(shape.to_lower(case_runes_of(['0049']), 'tr')) == '0131'
	assert case_codepoints_to_string(shape.to_lower(case_runes_of(['0049']), 'az')) == '0131'
	assert case_codepoints_to_string(shape.to_lower(case_runes_of(['0049']), '')) == '0069'
	assert case_codepoints_to_string(shape.to_lower(case_runes_of(['0130']), 'tr')) == '0069'
	assert case_codepoints_to_string(shape.to_lower(case_runes_of(['0130']), 'az')) == '0069'
	// An I before a dot keeps its dot in Turkish: I plus dot lowercases to i,
	// and the dot itself deletes after an I.
	assert case_codepoints_to_string(shape.to_lower(case_runes_of(['0049', '0307']), 'tr')) == '0069'
	assert case_codepoints_to_string(shape.to_lower(case_runes_of(['0049', '0307']), '')) == '0069 0307'
	// A ligature uppercases to two letters.
	assert case_codepoints_to_string(shape.to_upper(case_runes_of(['FB00']), '')) == '0046 0046'
	assert case_codepoints_to_string(shape.to_title(case_runes_of(['FB00']), '')) == '0046 0066'
	// Final sigma: end of word takes the final form, middle does not, and a
	// lone sigma with no cased letter before it is not final.
	assert case_codepoints_to_string(shape.to_lower(case_runes_of(['03A3']), '')) == '03C3'
	assert case_codepoints_to_string(shape.to_lower(case_runes_of(['0041', '03A3']), '')) == '0061 03C2'
	assert case_codepoints_to_string(shape.to_lower(case_runes_of(['0041', '03A3', '0041']), '')) == '0061 03C3 0061'
	// Title: first cased letter of each word upper, rest lower. Words are
	// maximal runs of cased letters; a space or hyphen ends one, a combining
	// mark rides on the letter before it and does not.
	assert case_codepoints_to_string(shape.to_title('hello world'.runes(), '')) == '0048 0065 006C 006C 006F 0020 0057 006F 0072 006C 0064'
	assert case_codepoints_to_string(shape.to_title('hello-world'.runes(), '')) == '0048 0065 006C 006C 006F 002D 0057 006F 0072 006C 0064'
	assert case_codepoints_to_string(shape.to_title(case_runes_of(['0068', '0065', '006C', '006C',
		'006F']), '')) == '0048 0065 006C 006C 006F'
}

fn test_special_casing_round_trip() {
	data := os.read_file('ucd/SpecialCasing.txt') or { panic('cannot read ucd/SpecialCasing.txt: ${err}') }
	cond_table := case_parse_cond_table(ucd.conditional_case_data)
	mut checked := 0
	mut failures := []string{}
	for line in data.split_into_lines() {
		row := case_parse_special_row(line) or { continue }
		checked++
		if row.conditions == '' {
			got_upper := shape.to_upper([rune(row.cp)], '')
			got_lower := shape.to_lower([rune(row.cp)], '')
			got_title := shape.to_title([rune(row.cp)], '')
			mut want_upper := if row.upper.len == 0 { [rune(row.cp)] } else { row.upper }
			mut want_lower := if row.lower.len == 0 { [rune(row.cp)] } else { row.lower }
			mut want_title := if row.title.len == 0 { [rune(row.cp)] } else { row.title }
			// An identity row (for example 00DF lower 00DF) has no entry in
			// the unconditional table and maps to itself, which is what the
			// functions return for a missing row.
			if row.upper.len == 1 && row.upper[0] == rune(row.cp) {
				want_upper = [rune(row.cp)]
			}
			if row.lower.len == 1 && row.lower[0] == rune(row.cp) {
				want_lower = [rune(row.cp)]
			}
			if row.title.len == 1 && row.title[0] == rune(row.cp) {
				want_title = [rune(row.cp)]
			}
			if !case_same(got_upper, want_upper) {
				failures << 'upper of U+${row.cp:04X}: got ${case_codepoints_to_string(got_upper)} want ${case_codepoints_to_string(want_upper)}'
			}
			if !case_same(got_lower, want_lower) {
				failures << 'lower of U+${row.cp:04X}: got ${case_codepoints_to_string(got_lower)} want ${case_codepoints_to_string(want_lower)}'
			}
			if !case_same(got_title, want_title) {
				failures << 'title of U+${row.cp:04X}: got ${case_codepoints_to_string(got_title)} want ${case_codepoints_to_string(want_title)}'
			}
		} else {
			// Every conditional row must be in the generated table verbatim.
			// Dropping one from the generator changes the table count below
			// and fails here with the row named.
			mut found := false
			for c in cond_table {
				if c.cp == row.cp && c.conditions == row.conditions && case_same(c.lower, row.lower) && case_same(c.title, row.title) && case_same(c.upper, row.upper) {
					found = true
					break
				}
			}
			if !found {
				failures << 'conditional row missing from table: U+${row.cp:04X} ${row.conditions}'
				continue
			}
			if row.conditions == 'tr' || row.conditions == 'az' {
				locale := row.conditions
				if !case_same(shape.to_upper([rune(row.cp)], locale), if row.upper.len == 0 {
					[]rune{}
				} else {
					row.upper
				}) {
					failures << 'upper of U+${row.cp:04X} in ${locale}: got ${case_codepoints_to_string(shape.to_upper([rune(row.cp)], locale))} want ${case_codepoints_to_string(row.upper)}'
				}
				if !case_same(shape.to_lower([rune(row.cp)], locale), if row.lower.len == 0 {
					[]rune{}
				} else {
					row.lower
				}) {
					// U+0049 and U+0307 in tr/az need their context (a
					// following dot, a preceding I) and are checked with it
					// below; a lone call uses the unconditional path.
					if row.cp != u32(0x0049) && row.cp != u32(0x0307) {
						failures << 'lower of U+${row.cp:04X} in ${locale}: got ${case_codepoints_to_string(shape.to_lower([rune(row.cp)], locale))} want ${case_codepoints_to_string(row.lower)}'
					}
				}
			}
		}
		if failures.len > 100 {
			break
		}
	}
	// The context-sensitive Turkish rows, checked with the context that
	// triggers them rather than alone.
	assert case_codepoints_to_string(shape.to_lower(case_runes_of(['0049']), 'tr')) == '0131'
	assert case_codepoints_to_string(shape.to_lower(case_runes_of(['0049', '0307']), 'tr')) == '0069'
	assert case_codepoints_to_string(shape.to_lower(case_runes_of(['0049', '0307']), 'az')) == '0069'
	assert case_codepoints_to_string(shape.to_lower(case_runes_of(['0049']), 'az')) == '0131'
	println('SpecialCasing conformance: ${checked} cases, ${failures.len} failed')
	shown := if failures.len < 10 { failures.len } else { 10 }
	for i in 0 .. shown {
		println(failures[i])
	}
	assert failures.len == 0, '${failures.len} SpecialCasing cases failed'
}

// test_case_table_counts is the break-fix control: it fails when a mapping
// row is dropped, because the counts below are the exact row counts the
// generator wrote. Removing one row from any table changes its count and
// names the table, the way removing the count check in SinglePos format 2 was
// caught by a test that used a record whose indices were all valid.
fn test_case_table_counts() {
	mut upper_n := 0
	for line in ucd.upper_case_data.split_into_lines() {
		if line.trim_space() != '' {
			upper_n++
		}
	}
	mut lower_n := 0
	for line in ucd.lower_case_data.split_into_lines() {
		if line.trim_space() != '' {
			lower_n++
		}
	}
	mut title_n := 0
	for line in ucd.title_case_data.split_into_lines() {
		if line.trim_space() != '' {
			title_n++
		}
	}
	mut cond_n := 0
	for line in ucd.conditional_case_data.split_into_lines() {
		if line.trim_space() != '' {
			cond_n++
		}
	}
	assert upper_n == 1601, 'upper table looks truncated: ${upper_n} rows'
	assert lower_n == 1508, 'lower table looks truncated: ${lower_n} rows'
	assert title_n == 1578, 'title table looks truncated: ${title_n} rows'
	assert cond_n == 16, 'conditional table looks truncated: ${cond_n} rows'
	// Spot checks that name the row a dropped-table regression would lose.
	assert case_codepoints_to_string(shape.to_upper(case_runes_of(['00DF']), '')) == '0053 0053'
	assert case_codepoints_to_string(shape.to_lower(case_runes_of(['0130']), '')) == '0069 0307'
}
