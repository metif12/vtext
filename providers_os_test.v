module harfara

import os
import harfara.providers

// The per-OS providers: CoreText on macOS, DirectWrite on Windows. Each is
// pinned on its own OS and answers none everywhere else, the fontconfig
// pattern exactly: no vlib imports, nothing linked unless the caller imports
// providers, and a skip that prints why rather than a silent gap.
//
// This file is self-contained: `v test providers_os_test.v` compiles this
// file and not its siblings, so the skip logger is duplicated here rather
// than borrowed from another test file.

// provider_os_skip records why a provider test could not run. A skip that
// prints nothing is a failure pretending to be a pass, so it is written where
// tools/run_tests.v reads it rather than to stdout, which a passing test's
// output discards.
fn provider_os_skip(name string) {
	line := 'SKIP ${name}'
	path := os.getenv('HARFARA_SKIP_LOG')
	if path != '' {
		mut f := os.open_append(path) or { return }
		f.writeln(line) or { return }
		f.close()
		return
	}
	println(line)
}

$if macos {
	// The lookup works end to end: parse a family, match it, read the file
	// and the matched name back out. The first host family that resolves
	// proves the provider; a substitution still counts only when it names
	// itself beside an existing path.
	fn test_coretext_matches_a_host_family() {
		for fam in ['Helvetica', 'Arial', 'Times New Roman'] {
			if got := providers.coretext_font(fam) {
				assert os.exists(got.path), 'matched path ${got.path} exists'
				assert got.family != '', 'matched family named'
				return
			}
		}
		provider_os_skip('a CoreText-matchable host family (Helvetica, Arial or Times New Roman)')
	}
} $else {
	fn test_coretext_is_macos_only() {
		if _ := providers.coretext_font('Helvetica') {
			panic('coretext_font answers off macos with no provider')
		}
		provider_os_skip('macos CoreText')
	}
}

$if windows {
	// The lookup is a documented stub (7.8 open work): it answers none rather
	// than a wrong font. The shape below is what the real wiring must satisfy
	// when it lands, so this test pins the contract without pretending the
	// provider exists: none today means a skip said aloud, never a silent
	// pass.
	fn test_directwrite_is_a_documented_stub() {
		if got := providers.directwrite_font('Arial') {
			assert os.exists(got.path), 'matched path ${got.path} exists'
			assert got.family != '', 'matched family named'
			return
		}
		provider_os_skip('windows DirectWrite family lookup (documented stub answers none)')
	}
} $else {
	fn test_directwrite_is_windows_only() {
		if _ := providers.directwrite_font('Arial') {
			panic('directwrite_font answers off windows with no provider')
		}
		provider_os_skip('windows DirectWrite')
	}
}
