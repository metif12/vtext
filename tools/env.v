module main

// Sets up the environment this module builds and tests in, and prints it.
//
// This replaces env.ps1, which every other script dot-sourced. It is a V program because the thing it
// configures is a V build: keeping the settings in the same language as the thing they configure means one
// set of quoting rules and one idea of a path separator rather than two.
//
// The three settings are the ones a build here needs and none of them are V defaults:
//
//	VEXE      the compiler to build with, and it is not the one that would be found on PATH. The fork in
//	          Projects\v compiles the module fine but its `v test` fails with "exec failed
//	          (SetHandleInformation): The handle is invalid" before any test runs, so tests use the
//	          stable checkout. Both compile the module identically; only the test runner differs.
//	CC        MinGW-w64 gcc from scoop. The build needs a real C compiler because the rasteriser is C.
//	VMODULES  the directory holding this module, so `import vtext` resolves from a tool run elsewhere.
//
// Usage:
//	v run tools/env.v            print what is set
//	v run tools/env.v --apply    set the environment for the current shell, which needs dot-sourcing
//
// The --apply form only works when this is sourced rather than run: a child process cannot change its
// parent's environment, which is why the PowerShell version had to be dot-sourced. A V script cannot be
// dot-sourced at all, so the V form is a plain printer and every other V script calls `apply()` itself.
// That is the honest trade: one language, no inheritance, one call per script.

import os

// apply sets the environment a build of this module needs and returns nothing.
//
// Called by each script rather than dot-sourced, because V has no way to be sourced. Repeating it in every
// script is two lines and it cannot silently fail to apply, which is the failure a dot-sourced setup has
// when one script forgets to include it.
pub fn apply() {
	os.setenv('PATH', 'C:\\Users\\MR\\scoop\\apps\\gcc\\current\\bin;' + os.getenv('PATH'), true)
	os.setenv('VMODULES', 'C:\\Users\\MR\\Projects', true)
	os.setenv('VEXE', vexe(), true)
}

// vexe is the compiler this module is built and tested with.
pub fn vexe() string {
	return 'C:\\Users\\MR\\v\\v.exe'
}

fn main() {
	apply()
	println('VEXE     ${os.getenv('VEXE')}')
	println('VMODULES ${os.getenv('VMODULES')}')
	println('CC       gcc, expected at C:\\Users\\MR\\scoop\\apps\\gcc\\current\\bin')

	// The compiler is checked rather than assumed, because every failure downstream of a wrong VEXE looks
	// like a compiler bug: "unknown option", "multiple input paths are not supported", a test that does not
	// run. Saying the path is wrong at the point of setting it is cheaper than diagnosing it twice.
	if !os.exists(vexe()) {
		eprintln('${vexe()} does not exist; every script here will fail in a way that looks like a bug elsewhere')
		exit(1)
	}
	r := os.exec_opt([vexe(), 'version']) or {
		eprintln('cannot run ${vexe()}: ${err}')
		exit(1)
	}
	println('compiler ${r.output.trim_space()}')
}
