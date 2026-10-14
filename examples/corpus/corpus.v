// corpus resolves which font file an example should open.
//
// The examples used to name `C:/Windows/Fonts/segoeui.ttf` in a const, which meant all nine ran on
// one operating system. The test suite has resolved the same way since 2026-10-12 — corpus first, the
// platform directory last and only on Windows — and the examples now do too, so the two halves of this
// repository agree about where a font comes from.
//
// The order is the whole of the decision:
//
//	$VTEXT_EXAMPLE_FONTS   a directory the caller names, for trying a font the corpus lacks
//	examples/../../testdata/fonts   the committed corpus, which is here on every platform
//	C:/Windows/Fonts      the platform's own, Windows only, so the output here does not change
//
// On this machine the last of those wins for the nine fonts the examples name, because the corpus has
// no Segoe, Tahoma, Consolas or Traditional Arabic. On Linux or macOS the second does, and the
// examples run. The pictures differ between the two — a different face shapes the same text — and that
// is the correct answer, not a regression: the corpus is not a copy of Windows.
//
// A font found nowhere returns none, and the example says so and stops. An example that cannot open
// its font is a broken example, and one that silently drew nothing would be worse.
module corpus

import os

// font resolves a font file, or none when no directory has it.
//
// `families` is the ordered list to try: a caller passes the fonts it would prefer, and the first one
// that exists wins. That is how `hello` keeps asking for a Latin font and an Arabic one while both
// resolving to Amiri on a Linux host — it still gets one font per role, just not the two it names.
pub fn font(families ...string) string {
	if families.len == 0 {
		return ''
	}
	mut dirs := []string{}
	for d in [os.getenv('VTEXT_EXAMPLE_FONTS'), corpus_dir(), platform_dir()] {
		if d != '' && d !in dirs {
			dirs << d
		}
	}
	for name in families {
		for dir in dirs {
			p := os.join_path(dir, name)
			if os.exists(p) {
				return p
			}
		}
	}
	return ''
}

// corpus_dir is the committed corpus, reached from this module's own location rather than from the
// working directory, because `v run .` runs from the example's directory and `v run tools/x.v` runs
// from the root, and a path that only works from one of those is a path that works by accident.
fn corpus_dir() string {
	here := os.dir(@FILE)
	return os.norm_path(os.join_path(here, '..', '..', 'testdata', 'fonts'))
}

$if windows {
	fn platform_dir() string {
		return 'C:/Windows/Fonts'
	}
} $else {
	fn platform_dir() string {
		return ''
	}
}
