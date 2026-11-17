module vtext

import os
import vtext.providers

// The Windows DirectWrite provider: family in, file path out. Windows-only:
// the lookup walks COM, so everywhere else the provider answers none and the
// file logs a skip saying so, which is also what proves the module still
// compiles where the provider does not.
//
// This file is self-contained: `v test providers_dw_test.v` compiles this
// file and not its siblings, so the skip logger is duplicated here rather
// than borrowed from another test file.

// dw_skip logs why a provider test could not run. A skip that prints nothing
// is a failure pretending to be a pass, so every one of them names what it
// wanted; tools/run_tests.v counts them file by file.
fn dw_skip(name string) {
	line := 'SKIP provider DirectWrite test needs ${name}'
	path := os.getenv('VTEXT_SKIP_LOG')
	if path != '' {
		mut f := os.open_append(path) or { return }
		f.writeln(line) or { return }
		f.close()
		return
	}
	println(line)
}

$if windows {
	// The binding works end to end: find the family, match a font, walk the
	// local-file-loader key back to a path, and read the matched name beside
	// it. Arial must resolve to itself with an existing path: anything else
	// is the silent substitution this test exists to catch.
	fn test_dw_resolves_arial() {
		got := providers.directwrite_font('Arial') or {
			dw_skip('a DirectWrite-matchable Arial on this host')
			return
		}
		assert os.exists(got.path), 'DirectWrite path ${got.path} exists'
		assert got.family != '', 'DirectWrite matched family named'
		assert got.family == 'Arial', 'match names itself, not a fallback (got ${got.family})'
	}

	// An unknown family never resolves: DirectWrite reports no match and the
	// provider answers none rather than handing back a wrong font. None here
	// is the contract, so there is nothing to skip over.
	fn test_dw_unknown_family_answers_none() {
		if got := providers.directwrite_font('NoSuchFamilyXYZ123') {
			panic('DirectWrite answered ${got.family} at ${got.path} for an unknown family')
		}
	}
} $else {
	fn test_dw_lookup_is_windows_only() {
		if _ := providers.directwrite_font('Arial') {
			panic('directwrite_font answers off windows with no provider')
		}
		dw_skip('windows DirectWrite')
	}
}
