module shape

// Hangul conjoining-Jamo composition: the lead, vowel and trailing parts the
// NFD pass splits every precomposed syllable into, folded back into the
// syllable HarfBuzz draws.
//
// The pipeline normalizes to NFD before shaping because joining keys on
// decomposed forms, and NFD splits U+AC00 into U+1100 U+1161. HarfBuzz
// composes those parts back through its Hangul shaper whenever the font
// carries the syllable — NotoSansKR maps both the parts and every one of
// the 11172 syllables — so a line that draws the parts is a line no other
// shaper draws: two glyphs with two advances where one syllable belongs.
// Compatibility Jamo (U+3131 and friends) never compose, and neither does
// a lone lead or vowel, which is why this folds only the conjoining runs
// UAX#15 section 10.2 names: L+V, then LV+T.
//
// The mapping travels with the text the way nfd_mapped's does: a composed
// syllable reports the decomposed index it started at, so the cluster the
// layout pass reads still names the caller's character. A precomposed
// syllable's parts share one origin, and a typed Jamo run's parts report
// consecutive ones; either way the syllable takes the first, which is the
// cluster HarfBuzz reports the fusion on.
//
// This is arithmetic over the Jamo block, not a table: the ranges are the
// same ones normalize.v decomposes with, so no generator feeds this and no
// UCD input is needed for it.
pub fn compose_hangul_runs(cps []rune, origin []int) ([]rune, []int) {
	if cps.len == 0 {
		return cps.clone(), origin.clone()
	}
	// Without a mapping there is nothing to rebase the clusters onto, so
	// the text passes through unfolded rather than mis-clustered.
	if origin.len != cps.len {
		return cps.clone(), origin.clone()
	}
	mut out := []rune{cap: cps.len}
	mut map_ := []int{cap: cps.len}
	mut i := 0
	for i < cps.len {
		mut folded := false
		if i + 1 < cps.len {
			lv := compose_hangul(cps[i], cps[i + 1])
			if lv != 0 {
				if i + 2 < cps.len {
					lvt := compose_hangul(rune(lv), cps[i + 2])
					if lvt != 0 {
						out << rune(lvt)
						map_ << origin[i]
						i += 3
						folded = true
					}
				}
				if !folded {
					out << rune(lv)
					map_ << origin[i]
					i += 2
					folded = true
				}
			}
		}
		if !folded {
			out << cps[i]
			map_ << origin[i]
			i++
		}
	}
	return out, map_
}
