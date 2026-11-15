module providers

// providers holds the per-OS font lookup: family and style in, a file path
// out, which the caller loads the same way it loads any other path.
//
// Linux (fontconfig) is first, because CI can verify it. Core Text and
// DirectWrite are named in GOAL.md but unwritten, and everywhere else this
// module answers no font rather than failing to build: nothing imports this
// module by default, so nothing links fontconfig unless a caller asks.

$if linux {
	#include <fontconfig/fontconfig.h>
}

#flag linux -lfontconfig

// SystemFont is what the provider found: the file to load, and the family the
// match actually named. The two are reported together because fontconfig falls
// back rather than failing: asking for a family that is not installed answers
// the closest installed one, and a caller that does not compare the two draws
// in a font it never asked for.
pub struct SystemFont {
pub:
	path   string
	family string
}

$if linux {
	fn C.FcInitLoadConfigAndFonts() voidptr
	fn C.FcNameParse(&u8) voidptr
	fn C.FcConfigSubstitute(voidptr, voidptr, int) int
	fn C.FcDefaultSubstitute(voidptr)
	fn C.FcFontMatch(voidptr, voidptr, &int) voidptr
	fn C.FcPatternGetString(voidptr, &u8, int, &&u8) int
	fn C.FcPatternDestroy(voidptr)
	fn C.FcConfigDestroy(voidptr)

	// FcMatchPattern is the FcMatchKind for matching: substitute the pattern
	// for a query rather than for editing. FcResultMatch is the FcResult for a
	// match, which FcFontMatch answers with a fallback font rather than a miss.
	const fc_match_pattern = 0
	const fc_result_match = 0

	// C_FcFontSet mirrors fontconfig's FcFontSet: the ranked matches FcFontSort
	// answers, best first. Only nfont and the font pointers are read; sfont is
	// fontconfig's own allocation size. fonts is a pointer to pointer so that
	// indexing strides one pointer (8 bytes on every runner here): a single
	// voidptr level leaves the stride to the compiler's void arithmetic.
	struct C_FcFontSet {
		nfont int
		sfont int
		fonts &&voidptr
	}

	fn C.FcFontSort(voidptr, voidptr, int, voidptr, &int) &C_FcFontSet
	fn C.FcFontSetDestroy(voidptr)
	fn C.FcPatternGetCharSet(voidptr, &u8, int, &voidptr) int
	fn C.FcPatternGetLangSet(voidptr, &u8, int, &voidptr) int
	fn C.FcCharSetHasChar(voidptr, u32) int
	fn C.FcLangSetHasLang(voidptr, &u8) int

	// match_first_pattern runs the match half every query here needs: parse,
	// substitute and match a family, answering the config and the match. The
	// caller destroys both. Either half unusable answers (nil, nil).
	fn match_first_pattern(family string) (voidptr, voidptr) {
		if family == '' {
			return unsafe { nil }, unsafe { nil }
		}
		config := C.FcInitLoadConfigAndFonts()
		if config == 0 {
			return unsafe { nil }, unsafe { nil }
		}
		pat := C.FcNameParse(family.str)
		if pat == 0 {
			C.FcConfigDestroy(config)
			return unsafe { nil }, unsafe { nil }
		}
		C.FcConfigSubstitute(config, pat, fc_match_pattern)
		C.FcDefaultSubstitute(pat)
		mut res := 0
		m := C.FcFontMatch(config, pat, &res)
		C.FcPatternDestroy(pat)
		if m == 0 || res != fc_result_match {
			C.FcConfigDestroy(config)
			return unsafe { nil }, unsafe { nil }
		}
		return config, m
	}

	// system_font resolves a family name through fontconfig. It answers none
	// when fontconfig itself is unusable — no config, no parse, no match —
	// and a SystemFont otherwise, whose family the caller compares against
	// what it asked for to detect a fallback.
	pub fn system_font(family string) ?SystemFont {
		if family == '' {
			return none
		}
		config := C.FcInitLoadConfigAndFonts()
		if config == 0 {
			return none
		}
		defer {
			C.FcConfigDestroy(config)
		}
		pat := C.FcNameParse(family.str)
		if pat == 0 {
			return none
		}
		defer {
			C.FcPatternDestroy(pat)
		}
		C.FcConfigSubstitute(config, pat, fc_match_pattern)
		C.FcDefaultSubstitute(pat)
		mut res := 0
		m := C.FcFontMatch(config, pat, &res)
		if m == 0 || res != fc_result_match {
			return none
		}
		defer {
			C.FcPatternDestroy(m)
		}
		mut file := &u8(unsafe { nil })
		if C.FcPatternGetString(m, c'file', 0, &file) != fc_result_match || file == unsafe { nil } {
			return none
		}
		mut fam := &u8(unsafe { nil })
		if C.FcPatternGetString(m, c'family', 0, &fam) != fc_result_match || fam == unsafe { nil } {
			return none
		}
		// The strings belong to the match, which the defers destroy on the way
		// out, so they are cloned into caller memory before returning.
		path := unsafe { file.vstring() }.clone()
		name := unsafe { fam.vstring() }.clone()
		return SystemFont{
			path:   path
			family: name
		}
	}

	// system_fonts_sorted answers the ranked list FcFontSort reports for a
	// family, best match first, capped at limit entries. Each entry carries its
	// own matched family beside its path, so a substitution is visible at
	// every rank rather than only at the first: asking for a family that is not
	// installed answers the closest installed families in order. It answers
	// none when fontconfig itself is unusable, the limit names nothing, or no
	// entry survives.
	pub fn system_fonts_sorted(family string, limit int) ?[]SystemFont {
		if family == '' || limit <= 0 {
			return none
		}
		config := C.FcInitLoadConfigAndFonts()
		if config == 0 {
			return none
		}
		defer {
			C.FcConfigDestroy(config)
		}
		pat := C.FcNameParse(family.str)
		if pat == 0 {
			return none
		}
		defer {
			C.FcPatternDestroy(pat)
		}
		C.FcConfigSubstitute(config, pat, fc_match_pattern)
		C.FcDefaultSubstitute(pat)
		mut res := 0
		// A nil charset vector: the per-font charsets stay inside fontconfig,
		// and the coverage questions below ask the matched patterns instead.
		set := C.FcFontSort(config, pat, 0, unsafe { nil }, &res)
		if isnil(set) || res != fc_result_match {
			return none
		}
		defer {
			C.FcFontSetDestroy(set)
		}
		mut n := set.nfont
		if n > limit {
			n = limit
		}
		mut out := []SystemFont{cap: n}
		// Each ranked pattern is read with explicit address arithmetic: the
		// set packs one pointer per entry, and a computed address leaves the
		// stride to construction (one pointer) rather than to however any
		// compiler version shapes a double-pointer index — which segfaulted
		// in FcPatternGetString on CI while the same index read fine on the
		// local toolchain. A nil entry is skipped; anything else answers.
		base := usize(set.fonts)
		stride := usize(sizeof(voidptr))
		for i in 0 .. n {
			m := unsafe { *&voidptr(base + usize(i) * stride) }
			if isnil(m) {
				continue
			}
			mut file := &u8(unsafe { nil })
			if C.FcPatternGetString(m, c'file', 0, &file) != fc_result_match
				|| file == unsafe { nil } {
				continue
			}
			mut fam := &u8(unsafe { nil })
			if C.FcPatternGetString(m, c'family', 0, &fam) != fc_result_match
				|| fam == unsafe { nil } {
				continue
			}
			out << SystemFont{
				path:   unsafe { file.vstring() }.clone()
				family: unsafe { fam.vstring() }.clone()
			}
		}
		if out.len == 0 {
			return none
		}
		return out
	}

	// system_font_covers_char reports whether the pattern a family matches to
	// covers cp, asked of the match's own charset rather than of any font file.
	// A caller deciding whether a family can draw a codepoint asks here before
	// it draws; anything unusable on the way there answers false.
	pub fn system_font_covers_char(family string, cp rune) bool {
		if family == '' || cp < 0 {
			return false
		}
		config, m := match_first_pattern(family)
		if config == 0 || m == 0 {
			return false
		}
		defer {
			C.FcPatternDestroy(m)
		}
		defer {
			C.FcConfigDestroy(config)
		}
		mut cs := voidptr(unsafe { nil })
		if C.FcPatternGetCharSet(m, c'charset', 0, &cs) != fc_result_match || cs == 0 {
			return false
		}
		// The charset belongs to the match, which the defers destroy, so there
		// is nothing to free here beyond answering.
		return C.FcCharSetHasChar(cs, u32(cp)) != 0
	}

	// FcLangResult answers coverage backwards from a boolean, so the
	// comparison is against the refusal rather than for equality: exact
	// (the language itself) is 0 and the same language in another
	// territory is 1, and only a different language refuses with 2.
	// Measured against Ubuntu Mono here ('en' in its set answers 0,
	// 'en-us' answers 1, 'xx' answers 2) and read off the installed
	// fontconfig.h, where equal is 0, different-territory is 1 and
	// different-language is 2. A font carrying 'en-us' still renders
	// English, so both 0 and 1 count as coverage.
	const fc_lang_different_lang = 2

	// system_font_covers_lang reports whether the pattern a family matches to
	// claims the language, asked of the match's own lang set. The name is a
	// BCP 47 tag the way fontconfig spells it ('en', 'fa', 'ar'). Anything
	// unusable on the way there answers false.
	pub fn system_font_covers_lang(family string, lang string) bool {
		if family == '' || lang == '' {
			return false
		}
		config, m := match_first_pattern(family)
		if config == 0 || m == 0 {
			return false
		}
		defer {
			C.FcPatternDestroy(m)
		}
		defer {
			C.FcConfigDestroy(config)
		}
		mut ls := voidptr(unsafe { nil })
		if C.FcPatternGetLangSet(m, c'lang', 0, &ls) != fc_result_match || ls == 0 {
			return false
		}
		return C.FcLangSetHasLang(ls, lang.str) != fc_lang_different_lang
	}
} $else {
	// Everywhere else there is no provider yet. A caller asking here gets no
	// font rather than a build break, and the test logs a skip saying so.
	pub fn system_font(family string) ?SystemFont {
		return none
	}

	// Off Linux there is nothing to sort: no provider, so no ranked list, and
	// the reason is printed where the answer would have been.
	pub fn system_fonts_sorted(family string, limit int) ?[]SystemFont {
		println('providers: fontconfig sort is linux-only; no provider on this platform')
		return none
	}

	// Off Linux there is no match whose charset could be asked: the coverage is
	// reported as absent, with the reason printed.
	pub fn system_font_covers_char(family string, cp rune) bool {
		println('providers: fontconfig charset coverage is linux-only; no provider on this platform')
		return false
	}

	// Off Linux there is no match whose language set could be asked: the
	// coverage is reported as absent, with the reason printed.
	pub fn system_font_covers_lang(family string, lang string) bool {
		println('providers: fontconfig language coverage is linux-only; no provider on this platform')
		return false
	}
}
