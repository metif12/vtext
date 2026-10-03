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
// Retry, narrowly. That collision is an environment failure rather than a test failure and it is
// distinguishable: only it mentions the build directory. So a failing run whose output mentions that phrase
// is retried and a genuine failure is not. A retried pass is announced, because a suite that is only green
// after retries is not the same as one that is green, and a silent retry hides a machine under memory or
// antivirus pressure.
//
// Usage:
//	v run tools/run_tests.v
//	v run tools/run_tests.v inspect
//
// The filter is a substring of the file name, so `inspect` runs inspect_test.v and `gpos` runs the four
// gpos tests.

import os
import time

// build_collision is the phrase the compiler prints when two processes race for the same build directory.
//
// Matched as a substring because the compiler offers no error type for it, and a substring is the only
// handle available. It is a fragile thing to match, which is worth knowing: a future compiler that words it
// differently turns the retry into a no-op and the collision into a reported failure, which is the safe
// direction to fail in.
const build_collision = 'failed to create C build directory'

// max_attempts is how many times one file is tried before it counts as failed.
//
// Three is not a number with a derivation behind it: it is what it took for the collisions to stop on this
// machine, and a larger number would only make a genuinely broken machine look slower rather than broken.
const max_attempts = 3

struct Outcome {
mut:
	exit_code int
	output    string
	attempts  int
}

fn main() {
	mut filter := ''
	for a in os.args[1..] {
		filter = a
	}

	env_setup()
	mut files := test_files(filter)
	if files.len == 0 {
		if filter == '' {
			eprintln('no _test.v files in this directory')
		} else {
			eprintln('no _test.v files matching "${filter}"')
		}
		exit(1)
	}

	mut passed := 0
	mut failed := 0
	mut retried := 0
	mut failed_names := []string{}

	for name in files {
		out := run_with_retries(name)
		if out.exit_code == 0 {
			passed++
			if out.attempts > 1 {
				retried++
				println('PASS  ${name}  (after ${out.attempts - 1} retries: the compiler collided in its own build directory)')
			} else {
				println('PASS  ${name}')
			}
			continue
		}
		failed++
		failed_names << name
		println('FAIL  ${name}')
		print_evidence(out.output, 25)
	}

	println('')
	println('Summary for all V _test.v files: ${passed} passed, ${failed} failed, ${files.len} total')
	if retried > 0 {
		// Said here as well as per file, so a summary line read on its own still says the suite needed
		// help from the machine.
		println('${retried} passed only after a retry for a compiler build collision')
	}
	if failed > 0 {
		println('failed: ${failed_names.join(', ')}')
	}
	exit(failed)
}

// env_setup configures the build environment. This is tools/env.v's apply() inlined, because a V script
// cannot import another V script that has a main().
//
// Inlined rather than duplicated-with-a-note because the alternative is three copies drifting apart, and the
// compiler is what notices when they have.
fn env_setup() {
	os.setenv('PATH', 'C:\\Users\\MR\\scoop\\apps\\gcc\\current\\bin;' + os.getenv('PATH'), true)
	os.setenv('VMODULES', 'C:\\Users\\MR\\Projects', true)
	os.setenv('VEXE', 'C:\\Users\\MR\\v\\v.exe', true)
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
fn run_one(name string, attempt int) Outcome {
	args := [os.getenv('VEXE'), '-cc', 'gcc', 'test', name]
	// os.exec_opt returns an error carrying the child's output when the child fails, so the failure path and
	// the non-zero path carry the same text and a caller reads one message either way. `err.msg()` is a
	// call: on this V an error's message is a method, and writing `err.msg` assigns the method itself,
	// which the compiler reports as "expected string, not fn () string".
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
