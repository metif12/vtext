module main

// Fetches the Unicode Character Database files the generators and the conformance tests read.
//
// The generated tables in ucd_*.v and ucd_names.v are committed, so a normal build never needs these files.
// Only regenerating a table (`v run tools/gen_tables.v` and its siblings) and the UCD comparison tests do,
// which is why the large conformance files are not committed either.
//
// This was fetch_ucd.ps1 until 2026-10-03. It is V because the thing it feeds is a V generator, and the
// alternative was a PowerShell script and a V program agreeing on a list of twenty-one URLs, which is a
// second place for that list to be wrong.
//
// Usage:
//	v run tools/fetch_ucd.v
//	v run tools/fetch_ucd.v 17.0.0
//
// The version is an argument and the emoji data has its own, pinned separately: emoji-data.txt is not
// versioned with the UCD, and following the UCD version for it fetches a file that does not exist there.

import os

// ucd_files are the files under ucd/ that this module's generators and tests read.
//
// Paths are relative to the ucd directory on unicode.org. They are listed rather than derived because the
// directory listing on the server is not a stable interface and the extracted/ and auxiliary/ subdirectories
// hold files whose names do not follow a pattern.
const ucd_files = [
	'ArabicShaping.txt',
	'CompositionExclusions.txt',
	'DerivedNormalizationProps.txt',
	'NormalizationTest.txt',
	'LineBreak.txt',
	'PropertyValueAliases.txt',
	'Scripts.txt',
	'UnicodeData.txt',
	'BidiTest.txt',
	'BidiCharacterTest.txt',
	'extracted/DerivedBidiClass.txt',
	'extracted/DerivedCombiningClass.txt',
	'extracted/DerivedGeneralCategory.txt',
	'extracted/DerivedJoiningGroup.txt',
	'extracted/DerivedJoiningType.txt',
	'auxiliary/GraphemeBreakProperty.txt',
	'auxiliary/GraphemeBreakTest.txt',
	'auxiliary/WordBreakProperty.txt',
	'auxiliary/LineBreakTest.txt',
]

// emoji_url is where emoji-data.txt lives, pinned to the version that was current when this was written.
//
// It is separate from the UCD version because emoji-data.txt is not published under the UCD path at all: it
// lives under its own version directory. Folding it into the version argument would produce a 404 for every
// version, which looks like a network problem and is not one.
const emoji_url = 'https://www.unicode.org/Public/16.0.0/ucd/emoji/emoji-data.txt'

fn main() {
	mut version := '18.0.0'
	for a in os.args[1..] {
		version = a
	}

	root := module_root()
	ucd := os.join_path_single(root, 'ucd')
	os.mkdir_all(ucd) or {
		eprintln('cannot create ${ucd}: ${err.msg()}')
		exit(1)
	}

	base := 'https://www.unicode.org/Public/${version}/ucd'

	mut urls := []string{}
	for f in ucd_files {
		urls << base + '/' + f
	}
	urls << emoji_url

	mut fetched := 0
	mut failed := 0

	for url in urls {
		// The destination is the last path element, so a file in extracted/ or auxiliary/ lands beside the
		// others rather than in a subdirectory that does not exist. That matches how the tests refer to
		// them: 'ucd/DerivedBidiClass.txt', not 'ucd/extracted/DerivedBidiClass.txt'.
		dest := os.join_path_single(ucd, os.file_name(url))
		code := fetch(url, dest)
		if code == '200' {
			fetched++
			// os.stat rather than a length method on the file name or on a read: this V has no
			// os.file_size, and reading twenty-one files whole to learn their sizes would be slower than the
			// fetch itself for the three that are several megabytes.
			st := os.stat(dest) or {
				eprintln('WARNING fetched but cannot stat ${dest}: ${err.msg()}')
				continue
			}
			println('${code}  ${int(st.size) / 1024:>7} KB  ${os.file_name(dest)}')
		} else {
			failed++
			// A failure is reported and the loop continues rather than aborting, because twenty-one files
			// where three are unavailable is a different situation from one where nothing is, and the
			// script should say which.
			eprintln('WARNING failed (${code}): ${url}')
		}
	}

	println('')
	println('fetched ${fetched} of ${urls.len}, failed ${failed}')
	println('Unicode ${version} data is in ${ucd}')
	if failed > 0 {
		println('')
		println('The missing files will fail the tests that read them, and the generators that need them')
		println('cannot run. Nothing else in the tree is affected, because the generated tables are')
		println('committed.')
	}
	if failed > 0 {
		exit(1)
	}
	println('')
	println('Regenerate the tables with:')
	println('  v run tools/gen_tables.v')
	println('  v run tools/gen_normalization.v')
	println('  v run tools/gen_codepoint_names.v')
}

// module_root is the directory holding this module, which is one above tools/.
//
// Derived from the executable's path rather than from the working directory, because a script that works
// from the project root and does not work from tools/ is a script that only works when the caller happens to
// be in the right place.
//
// The parent is taken by asking os.dir twice rather than by slicing the string at its last separator. This V
// has no len on a string, so a slice needs an index and getting that index means a search; asking the
// filesystem twice is a call each and is correct whatever separator the path used.
fn module_root() string {
	here := os.dir(os.executable())
	parent := os.dir(here)
	if os.file_name(parent) == os.file_name(here) {
		// os.dir returned the same directory, which is what it does for a root and for a relative path with
		// no parent. There is nothing above to go to and the caller is already where it needs to be.
		return here
	}
	return parent
}

// fetch downloads one URL to a destination with curl and returns the HTTP status as a string.
//
// curl is used rather than V's own http client because it is on this machine, it reports the status code
// without a request being written for it, and it is what the PowerShell version used, so a fetch that worked
// before still works.
//
// The status goes in the URL's write-out rather than being inferred from curl's exit code, because curl exits
// zero on a 404 when it has been told not to fail, and a 404 is the failure this needs to see.
fn fetch(url string, dest string) string {
	mut args := ['curl', '-s', '-L', '-o', dest, '-w', '%{http_code}', url]
	r := os.exec_opt(args) or { return 'error: ${err.msg()}' }
	if r.exit_code != 0 {
		return 'curl-exit-${r.exit_code}'
	}
	// The status is the whole output, but trimming makes a trailing newline impossible to pass on by
	// accident when it is compared against '200' later.
	return r.output.trim_space()
}
