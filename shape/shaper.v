module shape

import vtext.font

// ScriptShaper is the E1 extension seam: per-script shaping behaviour
// behind one interface, resolved through the registry below. Feature
// order, reorder and split become registry calls, so adding a script
// means implementing the three methods and registering the struct —
// not editing the pipeline in three files.
//
// Khmer is first; Myanmar follows one commit per script. The reorder
// and split hooks dispatch on content rather than on the run script
// because both run before the script resolves: reorder and split see
// the runes while substitute_glyphs sees the script. A syllable with no
// registered codepoints answers none and takes exactly the old path.
pub interface ScriptShaper {
	// claims reports whether this shaper handles content holding its
	// script's codepoints.
	claims(cps []rune) bool
	// default_features answers the shaping features that run without
	// being asked, in the order they run.
	default_features() []string
	// pre_ccmp_features answers the asked features this script runs
	// before ccmp, in order. Most scripts answer none: ccmp's mark
	// compositions have to exist before any feature reads them.
	pre_ccmp_features(extra []string) []string
	// reorder_tail applies the script's tail reorder to a syllable the
	// matra/repha moves already arranged, keeping its index map.
	reorder_tail(out []rune, map_ []int) ([]rune, []int)
	// split_run applies the script's run-level split, growing the run
	// and its index map together.
	split_run(cps []rune) ([]rune, []int)
}

// KhmerShaper carries the Khmer below/above-base machinery: the coeng
// fusions (pref, blwf, pstf) with the pres-group behind them, the
// COENG+RO prepose, and the split-vowel decomposition. Every number
// below was measured against HarfBuzz when each half landed; the
// registry only moves the code, it changes no decision.
pub struct KhmerShaper {}

// shaper_for_script resolves a run script to its shaper, or none when
// no script registered one. Scripts register one commit at a time:
// Khmer first, then Myanmar.
fn shaper_for_script(script string) ?ScriptShaper {
	tag := font.ot_script_tag(script)
	if tag == 'khmr' {
		return KhmerShaper{}
	}
	if tag == 'mymr' {
		return MyanmarShaper{}
	}
	return none
}

// shaper_default_features_for answers the registry's default list for a
// run script, or nothing when no shaper registered one.
fn shaper_default_features_for(script string) []string {
	if sh := shaper_for_script(script) {
		return sh.default_features()
	}
	return []string{}
}

// shaper_early_features_for answers the registry's before-ccmp list for
// asked features, or nothing when no shaper registered one.
fn shaper_early_features_for(script string, extra []string) []string {
	if sh := shaper_for_script(script) {
		return sh.pre_ccmp_features(extra)
	}
	return []string{}
}

// shaper_for_content resolves runes to the shaper claiming them, or
// none when no registered codepoint occurs. Reorder and split dispatch
// here because both run before the run script resolves.
pub fn shaper_for_content(cps []rune) ?ScriptShaper {
	if KhmerShaper{}.claims(cps) {
		return KhmerShaper{}
	}
	if MyanmarShaper{}.claims(cps) {
		return MyanmarShaper{}
	}
	return none
}

pub fn (s KhmerShaper) claims(cps []rune) bool {
	for cp in cps {
		if cp >= rune(0x1780) && cp <= rune(0x17FF) {
			return true
		}
	}
	return false
}

// default_features are the Khmer shaping features that run without
// being asked, for the same reason the Indic ones do: a line whose coeng
// subscripts stay unfused is not the text. Each is a HarfBuzz default-on
// feature proven by toggling it off under uharfbuzz: -pref unfolds
// COENG+RO (0xdc), -blwf unfolds COENG+TA (0xcc) and -pstf unfolds
// COENG+KHO (0xba); -pres unfolds the preposed pair's low variant
// (SA+COENG+RO+COENG+TA draws 0xdc with -pres), -abvs unfolds RO+Nikahit
// to 0x69 and KA+Nikahit+Killer to three glyphs, -blws unfolds
// SA+COENG+RO+U to plain 0x73, -psts unfolds SA+17C4 to 0x86 and
// SA+YA to plain 0x7a, -abvf unfolds SA+OE to plain 0x79. pref runs
// first so it claims the preposed pair before the blwf chains see it;
// blwf and pstf are disjoint plain ligatures, so no order is owed
// between them; pres runs after both because its lookahead names the
// blwf subscript (neutered pres-before-blwf leaves the low variant
// unfolded, which is the order break-fix). abvs, blws, psts and abvf
// follow in specification order pres/abvs/blws/psts/abvf, the same
// order the Indic pres-group keeps.
pub fn (s KhmerShaper) default_features() []string {
	return ['pref', 'blwf', 'pstf', 'pres', 'abvs', 'blws', 'psts', 'abvf']
}

// pre_ccmp_features answers nothing: every Khmer feature reads the
// ccmp compositions, so none runs ahead of them.
pub fn (s KhmerShaper) pre_ccmp_features(extra []string) []string {
	return []string{}
}

// reorder_tail preposes each adjacent COENG+RO pair to its syllable
// front: HarfBuzz preposes the pair with or without the pref fusion
// behind it (the fusion then claims the pair through lookup 12), the
// way a reph moves for the Indic scripts. Only directly adjacent pairs
// move; a join control between them is unevidenced, and each pair keeps
// its order when several prepose at once.
pub fn (s KhmerShaper) reorder_tail(out []rune, map_ []int) ([]rune, []int) {
	if out.len < 2 {
		return out.clone(), map_.clone()
	}
	mut at := -1
	for i in 0 .. out.len - 1 {
		if out[i] == rune(0x17D2) && out[i + 1] == rune(0x179A) {
			at = i
			break
		}
	}
	if at < 0 {
		return out.clone(), map_.clone()
	}
	mut front := []rune{cap: out.len}
	mut front_map := []int{cap: out.len}
	mut rest := []rune{cap: out.len}
	mut rest_map := []int{cap: out.len}
	mut i := 0
	for i < out.len {
		if out[i] == rune(0x17D2) && i + 1 < out.len && out[i + 1] == rune(0x179A) {
			front << out[i]
			front << out[i + 1]
			front_map << map_[i]
			front_map << map_[i + 1]
			i += 2
		} else {
			rest << out[i]
			rest_map << map_[i]
			i++
		}
	}
	mut moved := []rune{cap: front.len + rest.len}
	moved << front
	moved << rest
	mut moved_map := []int{cap: front_map.len + rest_map.len}
	moved_map << front_map
	moved_map << rest_map
	return moved, moved_map
}

// split_run decomposes the Khmer split vowels the way HarfBuzz shapes
// them: SRA OE 17BE, SRA YA 17BF, SRA IE 17C0 and SRA AU 17C4/17C5 draw
// as SRA E 17C1 before the base consonant plus the right part through
// the vowel's own GSUB rule, so a line without the split is missing a
// whole 288-unit glyph. The right part keeps working because the
// consonant and the vowel stay adjacent: the SRA E goes before the
// syllable's first consonant, never between the consonant and the
// vowel, which is the context the abvf and psts rules match. A syllable
// with no consonant keeps its vowel whole: with no base there is
// nowhere to anchor the halves, and HarfBuzz draws a dotted circle
// there that this engine does not insert. A run without the five vowels
// comes back identical with the identity map.
pub fn (s KhmerShaper) split_run(cps []rune) ([]rune, []int) {
	if cps.len == 0 {
		return []rune{}, []int{}
	}
	syl_ranges := indic_syllabic_ranges()
	mut out := []rune{cap: cps.len}
	mut map_ := []int{cap: cps.len}
	for sg in segment_indic_syllables(cps) {
		syl := cps[sg.start..sg.end]
		mut vowels := []int{}
		mut base := -1
		for i, cp in syl {
			if cp == rune(0x17BE) || cp == rune(0x17BF) || cp == rune(0x17C0)
				|| cp == rune(0x17C4) || cp == rune(0x17C5) {
				vowels << i
			} else if base < 0
				&& is_indic_consonant_like(indic_syllabic_of(syl_ranges, cp)) {
				base = i
			}
		}
		if vowels.len == 0 || base < 0 {
			for i, cp in syl {
				out << cp
				map_ << sg.start + i
			}
			continue
		}
		// One SRA E per split vowel, before the base, each tagged with the
		// base's index: the placing pass draws glyphs grouped by cluster
		// along bidi order, so a half reporting a later character than the
		// base it precedes would be drawn after it. Merging the halves onto
		// the base is what the reorder's own cluster merge does for a
		// preposed pair, and the right part keeps the vowel's index.
		for i, cp in syl {
			if i == base {
				for _ in vowels {
					out << rune(0x17C1)
					map_ << sg.start + base
				}
			}
			out << cp
			map_ << sg.start + i
		}
	}
	return out, map_
}

// MyanmarShaper carries the kinzi machinery: the abvs/blws defaults,
// the kinzi trio prepose, and the asked-blwf-before-ccmp carve-out. No
// run split: Myanmar has no split vowels, so split_run is the identity.
pub struct MyanmarShaper {}

pub fn (s MyanmarShaper) claims(cps []rune) bool {
	for cp in cps {
		if cp >= rune(0x1000) && cp <= rune(0x109F) {
			return true
		}
	}
	return false
}

// default_features are the Myanmar shaping features that run without
// being asked: a line whose kinzi stays unfolded is not the text. abvs
// is a HarfBuzz default-on feature proven by toggling it off under
// uharfbuzz: -abvs unfolds the kinzi trio NGA/ASAT/VIRAMA (lookup 52
// fuses it to the kinzi mark) and the asat beside it. blws is
// default-on the same way: -blws unfolds a VIRAMA+DHA stack back to
// virama and DHA while -abvs, -blwf and -ccmp change nothing on it.
// abvs runs first because HarfBuzz orders it there: with abvs off, blws
// subjoins the surviving virama, and with abvs on the kinzi consumes it
// first. blwf stays caller-asked: its medial-dot rules fire on no corpus
// word, so the order they need is unproven.
pub fn (s MyanmarShaper) default_features() []string {
	return ['abvs', 'blws']
}

// pre_ccmp_features answers the asked blwf before ccmp: the medial-dot
// fusion consumes DOT BELOW whole, and ccmp splits DOT BELOW into
// spacing and dummy marks first, which starves the rule when blwf runs
// late. Asked early it fuses the way HarfBuzz fuses with +blwf. Default
// lines never reach it: blwf is not a Myanmar default, and an unasked
// tag names nothing, so the unfused answer does not move. A `-blwf`
// spelling names nothing either: only `blwf` and `+blwf` ask.
pub fn (s MyanmarShaper) pre_ccmp_features(extra []string) []string {
	for feature in extra {
		t := if feature.starts_with('+') && feature.len > 1 { feature[1..] } else { feature }
		if t == 'blwf' {
			return ['blwf']
		}
	}
	return []string{}
}

// reorder_tail preposes the consonant after a kinzi trio ahead of it:
// HarfBuzz preposes the base before the NGA/ASAT/VIRAMA trio it
// kinzis, and the abvs lookup then fuses the trio into the kinzi mark
// behind it (lookup 52: nga/asat/virama to kinzi). The trio opens on
// NGA or RA — KA with the same tail draws in place with a dotted
// circle for the dangling virama — and the preposed character has to be
// a consonant: a vowel sign after the trio draws after it, unevidenced
// for a prepose.
pub fn (s MyanmarShaper) reorder_tail(out []rune, map_ []int) ([]rune, []int) {
	syl_ranges := indic_syllabic_ranges()
	if out.len < 4 {
		return out.clone(), map_.clone()
	}
	mut at := -1
	for i in 0 .. out.len - 3 {
		if (out[i] == rune(0x1004) || out[i] == rune(0x101B)) && out[i + 1] == rune(0x103A)
			&& out[i + 2] == rune(0x1039)
			&& is_indic_consonant_family(indic_syllabic_of(syl_ranges, out[i + 3])) {
			at = i
			break
		}
	}
	if at < 0 {
		return out.clone(), map_.clone()
	}
	mut first := []rune{cap: out.len}
	mut first_map := []int{cap: out.len}
	mut rest := []rune{cap: out.len}
	mut rest_map := []int{cap: out.len}
	mut i := 0
	for i < out.len {
		if i + 3 < out.len && (out[i] == rune(0x1004) || out[i] == rune(0x101B))
			&& out[i + 1] == rune(0x103A) && out[i + 2] == rune(0x1039)
			&& is_indic_consonant_family(indic_syllabic_of(syl_ranges, out[i + 3])) {
			first << out[i + 3]
			first_map << map_[i + 3]
			rest << out[i]
			rest << out[i + 1]
			rest << out[i + 2]
			rest_map << map_[i]
			rest_map << map_[i + 1]
			rest_map << map_[i + 2]
			i += 4
		} else {
			rest << out[i]
			rest_map << map_[i]
			i++
		}
	}
	mut moved := []rune{cap: first.len + rest.len}
	moved << first
	moved << rest
	mut moved_map := []int{cap: first_map.len + rest_map.len}
	moved_map << first_map
	moved_map << rest_map
	return moved, moved_map
}

// split_run is the identity: Myanmar has no split vowels to decompose.
pub fn (s MyanmarShaper) split_run(cps []rune) ([]rune, []int) {
	mut map_ := []int{cap: cps.len}
	for i in 0 .. cps.len {
		map_ << i
	}
	return cps.clone(), map_
}
