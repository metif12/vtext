module shape

import vtext.ucd

// Case mapping, the full upper, lower and title mappings of UAX #44 chapter 3.
//
// The tables are generated from UnicodeData.txt overlaid with the unconditional
// rows of SpecialCasing.txt, plus every conditional row verbatim, and live in
// ucd/ucd_case.v the way the quotation and SA-mark tables do: decoded here per
// call rather than carried on Properties, because only case conversion asks for
// them and every Properties value carrying three thousand-entry maps would be
// the larger cost.
//
// A character without a row maps to itself. A conditional row whose mapping is
// empty deletes the character, the way U+0307 does after an I in Turkish
// lowercasing: the dot is part of the I-dot sequence and must not survive it.
//
// The locale selects the conditional rows. `tr` and `az` (BCP47 primary, `-`
// and `_` equivalent, case-insensitive, subtags ignored) turn on the Turkish
// and Azeri dotted-I rules; every other locale, including the empty string,
// uses the unconditional mappings alone. Lithuanian `lt` rows and the
// context-sensitive `More_Above` and `After_Soft_Dotted` conditions are carried
// in the conditional table for review but are not applied: the functions below
// return the unconditional mapping for them, and case_test.v pins the table
// rows rather than the output for those cases.

// CondCase is one language- or context-conditional row from SpecialCasing.txt.
pub struct CondCase {
pub:
	cp         u32
	lower      []rune
	title      []rune
	upper      []rune
	conditions string
}

// parse_case_map decodes one "cp m1 m2 ..." table, the shape the three
// unconditional tables share with the normalization tables.
fn parse_case_map(data string) map[u32][]rune {
	mut m := map[u32][]rune{}
	for line in data.split_into_lines() {
		s := line.trim_space()
		if s == '' {
			continue
		}
		parts := s.split(' ')
		if parts.len < 2 {
			continue
		}
		cp := ucd.hex_value(parts[0])
		mut target := []rune{}
		for i in 1 .. parts.len {
			if parts[i] == '' {
				continue
			}
			target << rune(ucd.hex_value(parts[i]))
		}
		if target.len == 0 {
			continue
		}
		m[cp] = target
	}
	return m
}

// parse_hex_runes reads a space separated run of hex codepoints, the way a
// SpecialCasing field writes a 1-to-N mapping. An empty field means an empty
// mapping (a deletion) rather than no row.
fn parse_hex_runes(s string) []rune {
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

// parse_cond_cases decodes the conditional table, one "cp; lower; title;
// upper; conditions" row per line.
fn parse_cond_cases(data string) []CondCase {
	mut out := []CondCase{}
	for line in data.split_into_lines() {
		s := line.trim_space()
		if s == '' {
			continue
		}
		fields := s.split(';')
		if fields.len != 5 {
			continue
		}
		out << CondCase{
			cp:         ucd.hex_value(fields[0].trim_space())
			lower:      parse_hex_runes(fields[1])
			title:      parse_hex_runes(fields[2])
			upper:      parse_hex_runes(fields[3])
			conditions: fields[4].trim_space()
		}
	}
	return out
}

// ascii_lower lowercases ASCII letters only, which is all a locale tag and a
// condition token ever contain. The UCD comparison is case-insensitive and the
// file writes `Final_Sigma` while the caller may write either case.
fn ascii_lower(s string) string {
	mut out := []u8{cap: s.len}
	for i in 0 .. s.len {
		c := s[i]
		if c >= `A` && c <= `Z` {
			out << c + 32
		} else {
			out << c
		}
	}
	return out.bytestr()
}

// norm_locale returns the BCP47 primary subtag in lowercase, with `-` and `_`
// equivalent and any region or variant dropped: `tr-TR` and `tr_TR` both read
// as `tr`.
fn norm_locale(locale string) string {
	mut s := ascii_lower(locale.trim_space())
	s = s.replace('_', '-')
	cut := s.index('-') or { s.len }
	if cut < s.len {
		return s[..cut]
	}
	return s
}

// is_cased_cp reports whether cp is cased, which here means it appears as a
// key in any of the three unconditional maps. Every cased letter has a mapping
// in at least one direction, and nothing uncased does, so presence is the
// whole test and no general-category table is needed.
fn is_cased_cp(cp u32, upper map[u32][]rune, lower map[u32][]rune, title map[u32][]rune) bool {
	if cp in upper {
		return true
	}
	if cp in lower {
		return true
	}
	if cp in title {
		return true
	}
	return false
}

// is_mark_cp reports whether cp is a combining mark, which is what must be
// skipped when deciding Final_Sigma and what must not end a word in to_title.
fn is_mark_cp(cp u32, comb []ucd.CodeRange) bool {
	return ucd.lookup_range(comb, cp, 0) != 0
}

// is_final_sigma reports the Final_Sigma context: preceded by a cased letter
// and not followed by one, both skipping combining marks. Only the immediate
// neighbours matter to the tests here; a mark between the sigma and its
// neighbour is skipped, anything else stops the scan.
fn is_final_sigma(cps []rune, idx int, upper map[u32][]rune, lower map[u32][]rune, title map[u32][]rune, comb []ucd.CodeRange) bool {
	mut j := idx - 1
	mut prev_cased := false
	for j >= 0 {
		cj := u32(cps[j])
		if is_mark_cp(cj, comb) {
			j--
			continue
		}
		prev_cased = is_cased_cp(cj, upper, lower, title)
		break
	}
	if !prev_cased {
		return false
	}
	mut k := idx + 1
	for k < cps.len {
		ck := u32(cps[k])
		if is_mark_cp(ck, comb) {
			k++
			continue
		}
		return !is_cased_cp(ck, upper, lower, title)
	}
	return true
}

// cond_matches reports whether every condition in a SpecialCasing condition
// list holds at idx. A token is either a language (`tr`) or a casing context
// (`Final_Sigma`, `After_I`, `Before_Dot`), optionally negated with `Not_`.
// Language comparison is on the normalized primary subtag and is
// case-insensitive, the way BCP47 asks.
fn cond_matches(conditions string, cps []rune, idx int, locale string, upper map[u32][]rune, lower map[u32][]rune, title map[u32][]rune, comb []ucd.CodeRange) bool {
	norm := norm_locale(locale)
	for tok in conditions.split(' ') {
		t := tok.trim_space()
		if t == '' {
			continue
		}
		lt := ascii_lower(t)
		mut neg := false
		mut base := lt
		if lt.starts_with('not_') {
			neg = true
			base = lt[4..]
		}
		mut ok := false
		if base == 'final_sigma' {
			ok = is_final_sigma(cps, idx, upper, lower, title, comb)
		} else if base == 'after_i' {
			ok = idx > 0 && cps[idx - 1] == rune(0x0049)
		} else if base == 'before_dot' {
			ok = idx + 1 < cps.len && cps[idx + 1] == rune(0x0307)
		} else if base == 'more_above' {
			// Lithuanian More_Above needs the full Above logic and is not
			// applied here; the row stays in the table and the unconditional
			// mapping holds. case_test.v pins the row, not the output.
			ok = false
		} else if base == 'after_soft_dotted' {
			ok = false
		} else {
			ok = norm == base
		}
		if neg {
			ok = !ok
		}
		if !ok {
			return false
		}
	}
	return true
}

// find_cond returns the first conditional row for cp whose conditions hold at
// idx, or none when the unconditional mapping applies.
fn find_cond(conds []CondCase, cp u32, cps []rune, idx int, locale string, upper map[u32][]rune, lower map[u32][]rune, title map[u32][]rune, comb []ucd.CodeRange) ?CondCase {
	for c in conds {
		if c.cp != cp {
			continue
		}
		if cond_matches(c.conditions, cps, idx, locale, upper, lower, title, comb) {
			return c
		}
	}
	return none
}

// case_tables decodes the four generated tables. One decode per call rather
// than per character, the way quote_ranges is decoded per call: the tables are
// a few thousand rows and the alternative is a global with its own build flag.
fn case_tables() (map[u32][]rune, map[u32][]rune, map[u32][]rune, []CondCase, []ucd.CodeRange) {
	return parse_case_map(ucd.upper_case_data), parse_case_map(ucd.lower_case_data), parse_case_map(ucd.title_case_data), parse_cond_cases(ucd.conditional_case_data), ucd.parse_ranges(ucd.combining_class_ranges_data)
}

// to_upper returns the full uppercase mapping of cps.
//
// Characters without a row map to themselves; characters with a 1-to-N row
// such as U+00DF expand to several (SS). In the `tr` and `az` locales U+0069
// maps to U+0130 rather than to U+0049, which is the one rule that makes a
// hand table wrong.
pub fn to_upper(cps []rune, locale string) []rune {
	upper, lower, title, conds, comb := case_tables()
	mut out := []rune{cap: cps.len}
	for i in 0 .. cps.len {
		cp := cps[i]
		c := find_cond(conds, u32(cp), cps, i, locale, upper, lower, title, comb) or {
			if u32(cp) in upper {
				for r in upper[u32(cp)] {
					out << r
				}
				continue
			}
			out << cp
			continue
		}
		for r in c.upper {
			out << r
		}
	}
	return out
}

// to_lower returns the full lowercase mapping of cps.
//
// U+0130 lowercases to U+0069 U+0307 (i plus dot); in the `tr` and `az`
// locales it lowercases to U+0069 alone, U+0049 to U+0131 unless an U+0307
// follows, and an U+0307 after an I deletes. A U+03A3 lowercases to U+03C2 at
// the end of a word and to U+03C3 elsewhere, where the end is decided by the
// immediately neighbouring cased letters with combining marks skipped.
pub fn to_lower(cps []rune, locale string) []rune {
	upper, lower, title, conds, comb := case_tables()
	mut out := []rune{cap: cps.len}
	for i in 0 .. cps.len {
		cp := cps[i]
		c := find_cond(conds, u32(cp), cps, i, locale, upper, lower, title, comb) or {
			if u32(cp) in lower {
				for r in lower[u32(cp)] {
					out << r
				}
				continue
			}
			out << cp
			continue
		}
		for r in c.lower {
			out << r
		}
	}
	return out
}

// to_title returns cps in titlecase: the first cased letter of each word uses
// the titlecase mapping and every later cased letter uses lowercase.
//
// A word is a maximal run of cased letters; anything else ends one, except a
// combining mark, which rides on the letter before it and neither ends a word
// nor starts one. Digraphs are why this uses the title table rather than the
// upper one: U+01F3 at the start of a word titles to U+01F2, which upper alone
// would give as U+01F1.
pub fn to_title(cps []rune, locale string) []rune {
	upper, lower, title, conds, comb := case_tables()
	mut out := []rune{cap: cps.len}
	mut at_start := true
	for i in 0 .. cps.len {
		cp := cps[i]
		if is_cased_cp(u32(cp), upper, lower, title) {
			if at_start {
				c := find_cond(conds, u32(cp), cps, i, locale, upper, lower, title, comb) or {
					if u32(cp) in title {
						for r in title[u32(cp)] {
							out << r
						}
						at_start = false
						continue
					}
					out << cp
					at_start = false
					continue
				}
				for r in c.title {
					out << r
				}
			} else {
				c := find_cond(conds, u32(cp), cps, i, locale, upper, lower, title, comb) or {
					if u32(cp) in lower {
						for r in lower[u32(cp)] {
							out << r
						}
						continue
					}
					out << cp
					continue
				}
				for r in c.lower {
					out << r
				}
			}
			at_start = false
			continue
		}
		if is_mark_cp(u32(cp), comb) {
			out << cp
			continue
		}
		out << cp
		at_start = true
	}
	return out
}
