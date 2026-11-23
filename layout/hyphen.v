module layout

import harfara.ucd

// Hyphenation points inside a word, by Liang's algorithm.
//
// The algorithm pads the word with word edges ('.' on each side), matches
// every pattern against every position of the padded word, and overlays the
// pattern levels with a pointwise maximum. A gap whose final level is odd
// is a hyphenation point; an even level (including zero, "no pattern voted
// here") is not. Odd allows, even suppresses, and a higher level wins over
// a lower one, which is how a general rule and its exceptions share a table.
//
// The patterns table is injected, not hardcoded: hyphenate takes the rows
// as an argument, and hyphen_patterns returns the generated US-English
// subset in ucd/ucd_hyphen.v. A caller with another language's table passes
// that instead and the algorithm is unchanged.
//
// Edge rules (TeX \lefthyphenmin / \righthyphenmin, both for English):
// no break in the first hyphen_left_min characters of the word and none in
// the last hyphen_right_min, so "com-put-er" keeps its first break and the
// "-er" vote the patterns cast is hidden. Short words fall out of the same
// two comparisons with no special case: a word shorter than the two minima
// combined has no gap that satisfies both.

// hyphen_left_min is how many characters of a word a break must leave on
// its left. TeX's \lefthyphenmin for English is 2.
pub const hyphen_left_min = 2

// hyphen_right_min is how many characters of a word a break must leave on
// its right. TeX's \righthyphenmin for English is 3.
pub const hyphen_right_min = 3

// hyphen_patterns returns the generated US-English hyphenation patterns,
// one Liang row per line. It decodes ucd.hyphen_patterns_data the way the
// line breaker decodes its caller-owned tables: split on newlines, blanks
// and comment lines dropped, so the generator's exact trailing newline does
// not become a phantom empty pattern.
pub fn hyphen_patterns() []string {
	mut out := []string{}
	for line in ucd.hyphen_patterns_data.split_into_lines() {
		t := line.trim_space()
		if t == '' || t.starts_with('#') {
			continue
		}
		out << t
	}
	return out
}

// hyphen_lower folds one ASCII capital to its lowercase; anything else,
// including any non-ASCII letter, is returned unchanged. Patterns are
// lowercase ASCII, so matching folds both sides through here rather than
// through a Unicode case table the hyphenator does not otherwise need.
fn hyphen_lower(c rune) rune {
	if c >= 65 && c <= 90 {
		return c + 32
	}
	return c
}

// hyphenate returns the hyphenation points of word: the indices at which a
// break may go, each naming the word index the next line would start at, in
// increasing order. A return of [2, 6] for "hyphenation" means hy-phen-ation.
//
// word is matched lowercased, so "Hyphenation" and "hyphenation" agree; the
// returned indices are into the caller's word either way. patterns holds
// Liang rows in the form "hy3ph" (letters with interleaved levels, '.' for
// a word edge). Only ASCII letters, digits and '.' are read; a row with no
// letters is skipped, and a row longer than the padded word cannot match.
pub fn hyphenate(word []rune, patterns []string) []int {
	if word.len < hyphen_left_min + hyphen_right_min {
		return []int{}
	}
	mut padded := []rune{cap: word.len + 2}
	padded << rune(46)
	for c in word {
		padded << hyphen_lower(c)
	}
	padded << rune(46)
	mut values := []int{len: padded.len + 1}
	for pat in patterns {
		// Split the row into its letters and its levels: levels[k] is the
		// digit in front of letters[k], or 0 when there is none. "hy3ph"
		// becomes letters [h y p h] with levels [0 0 3 0 0].
		mut letters := []rune{cap: pat.len}
		mut levels := []int{cap: pat.len + 1}
		levels << 0
		for i in 0 .. pat.len {
			b := pat[i]
			if b >= 48 && b <= 57 {
				levels[levels.len - 1] = int(b - 48)
			} else {
				mut lc := rune(b)
				if lc >= 65 && lc <= 90 {
					lc += 32
				}
				letters << lc
				levels << 0
			}
		}
		if letters.len == 0 || letters.len > padded.len {
			continue
		}
		for i in 0 .. padded.len - letters.len + 1 {
			mut ok := true
			for k in 0 .. letters.len {
				if padded[i + k] != letters[k] {
					ok = false
					break
				}
			}
			if !ok {
				continue
			}
			for k in 0 .. levels.len {
				if levels[k] > values[i + k] {
					values[i + k] = levels[k]
				}
			}
		}
	}
	// Gap i of the padded word sits before padded[i]; word break j (between
	// word[j-1] and word[j]) is padded gap j+1, because padded[0] is the
	// leading edge. Only odd levels break, and only clear of both edges.
	mut out := []int{}
	for j in 1 .. word.len {
		gap := j + 1
		if values[gap] % 2 == 0 {
			continue
		}
		if j < hyphen_left_min {
			continue
		}
		if word.len - j < hyphen_right_min {
			continue
		}
		out << j
	}
	return out
}
