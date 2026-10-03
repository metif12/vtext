module main

// Builds and runs one program in this module and shows what it printed.
//
// This was run.ps1 until 2026-10-03. The build and the run are two steps and both need their exit code and
// their output, which is why it exists rather than being two commands a person types.
//
// Usage:
//	v run tools/run.v <file.v>
//	v run tools/run.v examples/hello/main.v
//	v run tools/run.v tools/fontdump.v --  C:/Windows/Fonts/segoeui.ttf
//
// Everything after a bare `--` is passed to the program. The separator is needed because the arguments a
// program takes and the options this script takes both start with a dash, and guessing which is which from
// the string is the kind of guessing that works until it does not.
//
// A -d define is also accepted, repeated, and it goes to the build rather than the program:
//
//	v run tools/run.v tools/fontdump.v -d debug

import os

// build_log and run_log are where the two steps' output is kept.
//
// Written to the temporary directory rather than beside the source: a build log next to the code it builds
// becomes a file that is accidentally committed, and the next build makes it stale in a way that reads as
// current.
const build_log_name = 'vtext_build.log'
const run_log_name = 'vtext_run.log'

struct Args {
mut:
	target  string
	defines []string
	program []string
}

fn main() {
	args := parse_args()

	os.setenv('PATH', 'C:\\Users\\MR\\scoop\\apps\\gcc\\current\\bin;' + os.getenv('PATH'), true)
	os.setenv('VMODULES', 'C:\\Users\\MR\\Projects', true)
	vexe := 'C:\\Users\\MR\\v\\v.exe'

	exe := os.join_path_single(os.temp_dir(), 'vtext_build.exe')
	build_log := os.join_path_single(os.temp_dir(), build_log_name)
	os.rm(exe) or {}
	os.rm(build_log) or {}

	if !os.exists(args.target) {
		eprintln('no such file: ${args.target}')
		exit(1)
	}

	// -o before the target, because v takes the output path as its own option and the target is the one
	// positional argument. Getting that order wrong produces "multiple input paths are not supported",
	// which reads like a compiler bug.
	mut build := [vexe, '-cc', 'gcc']
	for d in args.defines {
		build << '-d'
		build << d
	}
	build << '-o'
	build << exe
	build << args.target

	b := os.exec_opt(build) or {
		eprintln('cannot run the compiler: ${err.msg()}')
		exit(1)
	}
	os.write_file(build_log, b.output) or {}

	if b.exit_code != 0 {
		// Only the errors are shown. A build failure prints notices as well as the error, and a notice is
		// what a milestone in flight looks like, so leading with it buries the one line that matters.
		eprintln('BUILD FAILED (exit ${b.exit_code})')
		show_errors(b.output, 30)
		exit(b.exit_code)
	}

	// A build can report an error and still exit zero on some paths, so the text is checked as well. The
	// pattern is the compiler's own "path:line:column: error", which is specific enough not to match a
	// program that merely prints the word "error".
	mut lines := []string{}
	for line in b.output.split('\n') {
		if is_error_line(line) {
			lines << line
		}
	}
	if lines.len > 0 {
		eprintln('BUILD FAILED')
		for line in lines[..if lines.len > 30 {
			30
		} else {
			lines.len
		}] {
			eprintln(line)
		}
		exit(1)
	}

	run_log := os.join_path_single(os.temp_dir(), run_log_name)
	os.rm(run_log) or {}

	r := os.exec_opt([exe, ...args.program]) or {
		// The program's own failure comes back as an error carrying its output, so it is shown rather than
		// swallowed. A run that exits non-zero is not a script failure.
		os.write_file(run_log, err.msg()) or {}
		println('=== run (failed to start: ${err.msg()}) ===')
		exit(1)
	}
	os.write_file(run_log, r.output) or {}

	println('=== run (exit ${r.exit_code}) ===')
	if r.output.trim_space() != '' {
		println(strip_build_noise(r.output))
	} else {
		println('the program printed nothing; it was: ${exe} ${args.program.join(' ')}')
	}
	exit(r.exit_code)
}

// is_error_line reports whether a line of compiler output is a diagnostic rather than a notice.
fn is_error_line(line string) bool {
	if line.contains('notice:') {
		return false
	}
	return line.contains('.v:') && line.contains(': error')
}

// show_errors prints the error lines from compiler output, or the tail of it when there are none.
//
// The tail is the fallback because some compiler failures print nothing shaped like a diagnostic: an
// out-of-memory abort is three words and no error line at all.
fn show_errors(output string, limit int) {
	mut errors := []string{}
	for line in output.split('\n') {
		if is_error_line(line) {
			errors << line
		}
	}
	if errors.len == 0 {
		mut all := output.split('\n')
		mut start := if all.len > limit {
			all.len - limit
		} else {
			0
		}
		for line in all[start..] {
			eprintln(line)
		}
		return
	}
	for line in errors[..if errors.len > limit {
		limit
	} else {
		errors.len
	}] {
		eprintln(line)
	}
}

// strip_build_noise removes the compiler's notices from a program's output.
//
// The notices belong to the build step and were printed by this script already, so repeating them in the
// program's output puts a compiler diagnostic in the middle of what the program said. A program that prints
// the word "notice" in its own output is not affected, because the filter is on "notice:" with the colon.
fn strip_build_noise(output string) string {
	mut kept := []string{}
	for line in output.split('\n') {
		if line.contains('notice:') {
			continue
		}
		kept << line
	}
	return kept.join('\n')
}

// parse_args splits the command line into what the build needs and what the program needs.
//
// One pass, and a -d consumes the argument after it rather than being handled by index later. An earlier
// version looped twice and collected the defines in the second pass, which meant the two passes had to
// agree about what they had seen and there was no reason for them to. A single pass with a flag for "the
// next argument belongs to the previous option" is the whole of it.
fn parse_args() Args {
	mut args := Args{}
	mut rest_is_program := false
	mut wants_define := false
	for a in os.args[1..] {
		if rest_is_program {
			args.program << a
			continue
		}
		if wants_define {
			args.defines << a
			wants_define = false
			continue
		}
		if a == '--' {
			rest_is_program = true
			continue
		}
		if a == '-d' {
			wants_define = true
			continue
		}
		if args.target == '' {
			args.target = a
			continue
		}
		args.program << a
	}
	return args
}
