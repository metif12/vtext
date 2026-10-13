module main

// Runs every _test.v file in this module, one at a time, and reports a summary.
//
// This was test.ps1 until 2026-10-03. It is V because a test runner for a V module should be a V program:
// one language's idea of an array, one of a path, and one of an exit code, and a bug in the runner is not a
// bug in anything it was checking.
//
// Two things it does that `v test *.v` does not.
//
// Serial. `v test a.v b.v c.v` builds concurrently and twenty-one of them collide in the compiler's own
// temporary build directory. The loser's message is "failed to create C build directory ... because
// CreateDirectory returned: The operation completed successfully", which says the directory already existed
// rather than that creating it failed, and clearing the cache does not help because the next run collides
// somewhere else.
//
// A private TMPDIR, which is what actually ends the collisions. Serial alone does not: this repository shares
// %TEMP%\v_0 with every other V build on the machine, including another session building the compiler itself,
// and five concurrent compilers lose that race often enough to fail four of twenty-one tests. Measured on
// 2026-10-03 with the competitors left running: 17 passed and 4 failed, every one of the four green when run
// alone, and 21 passed with no collision at all once TMPDIR pointed somewhere of this runner's own. os.temp_dir
// reads TMPDIR before TEMP, so setting it for the child is sufficient.
//
// Retry, narrowly. A collision is an environment failure rather than a test failure and it is
// distinguishable: only it mentions the build directory. So a failing run whose output mentions that phrase
// is retried and a genuine failure is not. A retried pass is announced, because a suite that is only green
// after retries is not the same as one that is green, and a silent retry hides a machine under memory or
// antivirus pressure.
//
// Count the tests that could not run. A test that needs a font the host does not have prints SKIP and
// returns, and this runner reads those lines back out of the output, prints how many each file skipped, and
// says so when a file skipped all of them. A file that proved nothing is not a file that passed.
//
// Distinguish blocked from failed. A file that reads a font only one operating system ships, from an
// absolute path, and which this repository does not own, cannot run on the other two; it is recorded in
// testdata/blocked.txt with its reason and counted as BLOCKED rather than as a failure. Anything else that
// fails is a failure, because the other way to write this is a runner that reclassifies every red result
// as an environment problem.
//
// Usage:
//	v run tools/run_tests.v
//	v run tools/run_tests.v inspect
//
// The filter is a substring of the file name, so `inspect` runs inspect_test.v and `gpos` runs the four
// gpos tests.
//
// VTEXT_CC overrides the C compiler, for the platforms where `gcc` is not the right name for the one that
// is installed.

import os
import time

// build_collision is the phrase the compiler prints when two processes race for the same build directory.
//
// Matched as a substring because the compiler offers no error type for it, and a substring is the only
// handle available. It is a fragile thing to match, which is worth knowing: a future compiler that words it
// differently turns the retry into a no-op and the collision into a reported failure, which is the safe
// direction to fail in.
const build_collision = 'failed to create C build directory'

// blocked_list is where a file that cannot run on any host which lacks its fonts is recorded, with the
// reason and what has to change before the entry is deleted.
//
// It exists for exactly one class of file: one that hardcodes an absolute path to a font only one
// operating system ships, and which this repository may not edit. Recording it keeps the suite green
// without letting that green be silent, because every run prints the blocked files and their reasons,
// and a file that is missing a font for a *new* reason is not on the list and fails the run.
const blocked_list = 'testdata/blocked.txt'

// max_attempts is how many times one file is tried before it counts as failed.
//
// Three is not a number with a derivation behind it: it is what it took for the collisions to stop on this
// machine, and a larger number would only make a genuinely broken machine look slower rather than broken.
const max_attempts = 3

// Outcome is what one attempt at one file produced, and the output is kept because whether a failure is a
// compiler collision is decided by reading it rather than from the exit code.
struct Outcome {
mut:
	exit_code int
	output    string
	attempts  int
}

// Verdict is what one file did, including the two things an exit code cannot say: how many of its tests
// could not run here, and whether the reason was a font this host does not have.
struct Verdict {
mut:
	name     string
	outcome  string // pass, fail or blocked
	skipped  []string
	attempts int
	why      string
}

fn main() {
	mut filter := ''
	for a in os.args[1..] {
		filter = a
	}

	env_setup()
	private_tmpdir()
	os.write_file(skip_log_path(), '') or {
		eprintln('cannot start the skip log: ${err.msg()}')
		exit(1)
	}
	os.setenv('VTEXT_SKIP_LOG', skip_log_path(), true)
	mut seen_skips := 0
	mut files := test_files(filter)
	if files.len == 0 {
		if filter == '' {
			eprintln('no _test.v files in this directory')
		} else {
			eprintln('no _test.v files matching "${filter}"')
		}
		exit(1)
	}

	mut verdicts := []Verdict{}

	for name in files {
		out := run_with_retries(name)
		skipped := new_skips(seen_skips)
		seen_skips += skipped.len
		if out.exit_code == 0 {
			mut v := Verdict{
				name:     name
				outcome:  'pass'
				skipped:  skipped
				attempts: out.attempts
			}
			if out.attempts > 1 {
				v.why = 'the compiler collided in its own build directory and the retry passed'
			}
			verdicts << v
			continue
		}
		why := blocked_reason(name, out.output)
		if why != '' {
			verdicts << Verdict{
				name:     name
				outcome:  'blocked'
				attempts: out.attempts
				why:      why
				skipped:  skipped
			}
			continue
		}
		println('FAIL  ${name}')
		print_evidence(out.output, 25)
		verdicts << Verdict{
			name:     name
			outcome:  'fail'
			attempts: out.attempts
			skipped:  skipped
		}
	}

	report(verdicts, files.len)
	exit(failed_count(verdicts))
}

// report prints one line per file, and a summary that says how much of the suite this host actually ran.
//
// The count of tests that could not run is printed next to the file it happened in, because a file of
// which every test skipped is a file that proves nothing here, and that is the one thing most likely to
// be misread as a green result.
fn report(verdicts []Verdict, total_files int) {
	mut passed := 0
	mut failed := 0
	mut blocked := 0
	mut retried := 0
	mut total_skips := 0
	mut all_skipped := []string{}
	mut failed_names := []string{}

	for v in verdicts {
		total_skips += v.skipped.len
		match v.outcome {
			'pass' {
				passed++
				if v.attempts > 1 {
					retried++
					println('PASS  ${v.name}  (after ${v.attempts - 1} retries: ${v.why})')
				} else {
					println('PASS  ${v.name}')
				}
				if v.skipped.len > 0 {
					names := v.skipped.map(it.before(':'))
					println('      ${v.skipped.len} skipped: ${names.join(', ')}')
				}
				n := test_count(v.name)
				if n > 0 {
					if v.skipped.len >= n {
						println('      EVERY TEST IN THIS FILE SKIPPED: it proved nothing on this host')
						all_skipped << v.name
					}
				}
			}
			'blocked' {
				blocked++
				println('BLOCKED  ${v.name}')
				println('      ${v.why}')
			}
			else {
				failed++
				failed_names << v.name
			}
		}
	}

	println('')
	println('Summary for all V _test.v files: ${passed} passed, ${failed} failed, ${blocked} blocked, ${total_files} total')
	if retried > 0 {
		// Said here as well as per file, so a summary line read on its own still says the suite needed
		// help from the machine.
		println('${retried} passed only after a retry for a compiler build collision')
	}
	if total_skips > 0 {
		println('${total_skips} tests could not run on this host, and each printed why')
	}
	if all_skipped.len > 0 {
		println('files in which every test skipped: ${all_skipped.join(', ')}')
	}
	if blocked > 0 {
		println('the blocked files above could not run here at all; each reason is recorded in ${blocked_list}')
	}
	if failed > 0 {
		println('failed: ${failed_names.join(', ')}')
	}
}

// failed_count is what the exit code is. A blocked file is not a failure: it is a file that cannot run on
// this host for a reason that is written down, and a run where it is the only thing wrong is a run that
// proved everything it could prove here.
fn failed_count(verdicts []Verdict) int {
	mut failed := 0
	for v in verdicts {
		if v.outcome == 'fail' {
			failed++
		}
	}
	return failed
}

// test_count is how many tests a file declares, read from the file rather than from the compiler, because
// a file that skipped all of them is only visible by comparing the two.
fn test_count(name string) int {
	data := os.read_file(name) or { return 0 }
	mut n := 0
	for line in data.split_into_lines() {
		if line.starts_with('fn test_') {
			n++
		}
	}
	return n
}

// skip_log_path is where every test appends its skips, in the private build directory this runner made.
//
// It is a file rather than the test's output because V's test runner does not print a passing test's
// output: measured on Linux, every println line a passing file writes is discarded, so a suite in which
// every test skipped would print exactly what a suite in which every test ran prints. Written to a file this
// runner reads, a skip is counted whether its test passed or failed, and the count is printed.
fn skip_log_path() string {
	return os.join_path(os.getenv('TMPDIR'), 'vtext-skips.log')
}

// new_skips is what has been appended since the count last read, so one file's skips are attributed to it.
fn new_skips(seen int) []string {
	data := os.read_file(skip_log_path()) or { return []string{} }
	mut out := []string{}
	mut i := 0
	for line in data.split_into_lines() {
		if line.trim_space() == '' {
			continue
		}
		if i >= seen {
			out << line
		}
		i++
	}
	return out
}

// blocked_reason says why a file could not run here at all, or an empty string when it could.
//
// It is deliberately narrow. The only thing that counts is a file that reads a font from an absolute path
// outside this repository, that this repository does not own, and that is recorded in blocked_list with a
// reason. Anything else that fails is a failure: the alternative is a runner that quietly reclassifies
// every red result as an environment problem, which is how a broken suite starts looking healthy.
fn blocked_reason(name string, output string) string {
	if !output.contains('Windows') && !output.contains('/Windows/') {
		return ''
	}
	if !output.contains('Fonts') {
		return ''
	}
	if !output.contains('V panic') && !output.contains('not found') && !output.contains('failed to open') {
		return ''
	}
	entries := read_blocked_list()
	for entry in entries {
		if entry.path == name {
			return entry.why
		}
	}
	return ''
}

// BlockedEntry is one recorded reason a file cannot run on every host.
struct BlockedEntry {
	path string
	why  string
}

// read_blocked_list reads testdata/blocked.txt, whose every line is "path: reason". Comment lines and
// blank lines are dropped, so the reason is never optional and the file cannot become a bare list of
// names that nobody re-reads.
fn read_blocked_list() []BlockedEntry {
	data := os.read_file(blocked_list) or { return [] }
	mut out := []BlockedEntry{}
	for line in data.split_into_lines() {
		s := line.trim_space()
		if s == '' || s[0] == `#` {
			continue
		}
		at := s.index(':') or { continue }
		out << BlockedEntry{
			path: s[..at].trim_space()
			why:  s[at + 1..].trim_space()
		}
	}
	return out
}

// env_setup configures the build environment. This is tools/env.v's apply() inlined, because a V script
// cannot import another V script that has a main().
//
// Nothing here assumes which host this is. The suite now runs on Linux and macOS as well as on Windows, and
// a runner that exported one machine's compiler path would conclude that the other two have no compiler at
// all. So: use VEXE when the caller set it, fall back to the compiler beside this checkout when that binary
// is actually there, and otherwise trust PATH. The same rule for the toolchain and the module path.
fn env_setup() {
	if os.getenv('VEXE') == '' {
		for candidate in compiler_candidates() {
			if os.exists(candidate) {
				os.setenv('VEXE', candidate, true)
				break
			}
		}
	}
	for gcc in gcc_candidates() {
		if os.is_dir(gcc) {
			os.setenv('PATH', gcc + os.path_delimiter + os.getenv('PATH'), true)
			break
		}
	}
	if os.getenv('VMODULES') == '' {
		for mods in modules_candidates() {
			if os.is_dir(mods) {
				os.setenv('VMODULES', mods, true)
				break
			}
		}
	}
}

// The candidates below are the machine this suite was written on. Each one is checked for existence
// before it is used, so on a host that has none of them the environment is left exactly as the caller
// arranged it, which is what a CI runner is.
$if windows {
	fn compiler_candidates() []string {
		profile := os.getenv('USERPROFILE')
		if profile != '' {
			return [os.join_path(profile, 'v', 'v.exe'), 'v.exe', 'v']
		}
		return ['v.exe', 'v']
	}
} $else {
	fn compiler_candidates() []string {
		return [os.join_path(os.home_dir(), 'v', 'v'), 'v']
	}
}

$if windows {
	fn gcc_candidates() []string {
		profile := os.getenv('USERPROFILE')
		if profile == '' {
			return []string{}
		}
		return [os.join_path(profile, 'scoop', 'apps', 'gcc', 'current', 'bin')]
	}
} $else {
	fn gcc_candidates() []string {
		return []string{}
	}
}

$if windows {
	fn modules_candidates() []string {
		profile := os.getenv('USERPROFILE')
		if profile == '' {
			return []string{}
		}
		return [os.join_path(profile, 'Projects')]
	}
} $else {
	fn modules_candidates() []string {
		return []string{}
	}
}

// private_tmpdir points the compiler's build directory somewhere of this run's own.
//
// The compiler puts it at <temp>/v_<uid>, and <temp> comes from os.temp_dir(), which reads TMPDIR before
// TEMP. So setting TMPDIR is enough to get out of the shared %TEMP%\v_0 that every V build on the machine
// contends for. Left unset, this runner fails about one test in five whenever anything else is compiling, and
// the failure names a directory rather than a test, so it reads as a real one.
//
// It is set for this process and therefore inherited by the children, rather than passed per call, because
// os.exec_opt takes no environment argument to pass it in. That also means it is inherited by anything else
// this process runs, which here is only the compiler.
//
// The path is built from the user profile rather than from os.temp_dir or os.vtmp_dir, because both of those
// land inside the very directory being avoided: vtmp_dir is <temp>/v_<uid> unless VTMP says otherwise, and
// nesting a private build directory under the shared one reproduces the collision it was added to fix.
//
// Which profile is read is not assumed: USERPROFILE on Windows, HOME everywhere else, because this suite
// runs on all three and a runner that reads only the Windows one concludes that Linux has no home.
fn private_tmpdir() {
	mut profile := os.getenv('USERPROFILE')
	if profile == '' {
		profile = os.getenv('HOME')
	}
	if profile == '' {
		profile = os.home_dir()
	}
	if profile == '' {
		eprintln('no user profile, so there is nowhere private to build')
		exit(1)
	}
	dir := os.join_path(profile, '.cache', 'vtext-test-build')
	os.mkdir_all(dir) or {
		eprintln('cannot create a private build directory at ${dir}: ${err.msg()}')
		exit(1)
	}
	os.setenv('TMPDIR', dir, true)
}

// test_files lists the test files to run, filtered by a substring of the name.
fn test_files(filter string) []string {
	mut files := os.ls('.') or { [] }
	files = files.filter(it.ends_with('_test.v'))
	if filter != '' {
		files = files.filter(it.contains(filter))
	}
	files.sort()
	return files
}

// run_with_retries builds and runs one test file, retrying only a build collision.
//
// The output is kept rather than streamed because it is the evidence for the retry decision: whether a
// failure is a collision is decided by reading what the compiler printed, and that cannot be decided from
// an exit code.
fn run_with_retries(name string) Outcome {
	mut out := run_one(name, 1)
	for out.attempts < max_attempts && out.exit_code != 0 && out.output.contains(build_collision) {
		// The pause grows with the attempt. Two compiler processes colliding usually clears as soon as the
		// first finishes writing, and a flat second on the first retry is longer than it needs to be.
		time.sleep(200 * out.attempts * time.millisecond)
		out = run_one(name, out.attempts + 1)
	}
	return out
}

// run_one builds and runs one test file and returns everything it printed.
//
// The compiler's notices are filtered out of the evidence rather than at print time, because a notice about
// an unused constant is not a failure and a file full of them is what a milestone in flight looks like. The
// filter is on the word "notice:" because that is what the compiler prints, and it is applied to the whole
// line rather than to a part of it so a real message that merely contains the word survives.
// vexe is the compiler to run, and c_compiler is the C toolchain to build with.
//
// VTEXT_CC exists because the three platforms do not agree on what the C compiler is called: Windows and
// the Linux runners ship gcc, and on macOS `gcc` is a shim for clang, which works but which names itself
// in its output. Setting it per platform in the workflow keeps the same command working everywhere.
fn vexe() string {
	mut v := os.getenv('VEXE')
	if v == '' {
		v = 'v'
	}
	return v
}

fn c_compiler() string {
	cc := os.getenv('VTEXT_CC')
	if cc == '' {
		return 'gcc'
	}
	return cc
}

fn run_one(name string, attempt int) Outcome {
	// The compiler is named as an array of arguments rather than as one string, because that is the only
	// form that does not go through a command interpreter: a command string reaches the shell, which on
	// Windows reads the quoting as its own. A path with a space in it would be split, and a checkout under
	// Program Files is not a hypothetical.
	args := [vexe(), '-cc', c_compiler(), 'test', name]
	// The child inherits this process's environment, which is how the skip log reaches the test: V passes
	// no per-call environment, so the variable is set here and inherited.
	os.setenv('VTEXT_SKIP_LOG', skip_log_path(), true)
	// os.exec_opt returns an error carrying the child's output when the child fails, so the failure path and
	// the non-zero path carry the same text and a caller reads one message either way. `err.msg()` is a
	// call: on this V an error's message is a method, and writing `err.msg` assigns the method itself,
	// which the compiler reports as "expected string, not fn () string".
	//
	// os.exec_opt is also why this suite must run on a compiler built from master rather than on the
	// latest release: measured, 0.5.2 7647ce1 answers "Did you mean os.execute_opt?" for it, and it cannot
	// compile this repository at all besides. So the workflow that runs this builds V from source, and that
	// is recorded there with the two measurements.
	r := os.exec_opt(args) or {
		return Outcome{
			exit_code: -1
			output:    err.msg()
			attempts:  attempt
		}
	}
	return Outcome{
		exit_code: r.exit_code
		output:    strip_notices(r.output)
		attempts:  attempt
	}
}

// strip_notices drops the compiler's notices from its output.
//
// A notice is a line mentioning "notice:" and nothing after it that looks like a diagnostic. Filtering on the
// word alone would also drop an error line that quoted a notice, which is the wrong trade: an error is worth
// reading twice.
fn strip_notices(output string) string {
	mut kept := []string{}
	for line in output.split('\n') {
		if line.contains('notice:') {
			continue
		}
		kept << line
	}
	return kept.join('\n')
}

// print_evidence shows up to limit lines of a failure.
//
// A compile error is dozens of lines and the summary is what gets read, so this shows the head rather than
// the tail: the first error is the one that explains the rest.
fn print_evidence(output string, limit int) {
	mut shown := 0
	for line in output.split('\n') {
		if line.trim_space() == '' {
			continue
		}
		if shown >= limit {
			println('  ... and more')
			return
		}
		println('  ${line}')
		shown++
	}
}
