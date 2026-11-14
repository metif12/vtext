module vtext

import os
import vtext.providers

// The Linux fontconfig provider: family in, file path out. Linux-only: the
// lookup needs libfontconfig, so everywhere else the provider answers none and
// the file logs a skip saying so, which is also what proves the module still
// compiles where the provider does not exist.

// provider_skip logs why a provider test could not run. A skip that prints
// nothing is a failure pretending to be a pass, so every one of them names
// what it wanted; tools/run_tests.v counts them file by file.
fn provider_skip(name string) {
	line := 'SKIP provider test needs ${name}'
	path := os.getenv('VTEXT_SKIP_LOG')
	if path != '' {
		mut f := os.open_append(path) or { return }
		f.writeln(line) or { return }
		f.close()
		return
	}
	println(line)
}

// host_family is a family this host's fontconfig can match: one of the faces
// every Linux desktop ships, tried in order. The test asserts the match names
// itself, so a provider that misnames answers fails rather than skips.
fn host_family() ?providers.SystemFont {
	for fam in ['DejaVu Sans', 'DejaVu Serif', 'Ubuntu'] {
		if got := providers.system_font(fam) {
			if os.exists(got.path) {
				return got
			}
		}
	}
	return none
}

$if linux {
	// The binding works end to end: parse a family, match it, read the file
	// and the matched name back out. The family must resolve to itself —
	// anything else is the silent substitution below, and this is the test
	// that would catch it.
	fn test_fontconfig_matches_a_host_family() {
		got := host_family() or {
			provider_skip('DejaVu Sans, DejaVu Serif or Ubuntu in fontconfig')
			return
		}
		assert os.exists(got.path), 'matched path ${got.path} exists'
		assert got.family != '', 'matched family named'
		assert got.family == 'DejaVu Sans' || got.family == 'DejaVu Serif'
			|| got.family == 'Ubuntu', 'match names itself, not a fallback'
	}

	// An unknown family never errors: fontconfig falls back to whatever is
	// installed. The provider reports the matched family so the caller sees
	// the substitution instead of drawing in a font it never asked for.
	fn test_fontconfig_reports_substitution() {
		got := providers.system_font('NoSuchFamilyXYZ123') or {
			provider_skip('any matchable font in fontconfig')
			return
		}
		assert got.family != 'NoSuchFamilyXYZ123', 'substitution visible in family ${got.family}'
		assert os.exists(got.path), 'fallback path ${got.path} exists'
	}
} $else {
	fn test_provider_is_linux_only() {
		if _ := providers.system_font('DejaVu Sans') {
			panic('system_font answers off linux with no provider')
		}
		provider_skip('linux fontconfig')
	}
}
