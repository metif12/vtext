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
} $else {
	// Everywhere else there is no provider yet. A caller asking here gets no
	// font rather than a build break, and the test logs a skip saying so.
	pub fn system_font(family string) ?SystemFont {
		return none
	}
}
