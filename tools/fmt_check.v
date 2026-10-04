module main

// Checks that every file in this module is formatted, and refuses to lie about the two that cannot be.
//
// `v fmt -verify .` is the wrong gate for this repository and not because of a setting. Two files make it
// report a failure that does not exist, and one of them makes it do something destructive if the failure is
// taken at face value:
//
//   stbtt.c.v is a false positive. `v fmt -l` lists it and `v fmt -verify` fails on it, and `v fmt -w`
//   answers "Reformatted file" while writing byte-identical content. There is no diff to read and no
//   change to keep, so the file cannot be made to pass.
//
//   ucd_names.v is destructive. It is a 1.8 MB front-coded table of 143,217 codepoint names, and
//   `v fmt -w` on it rewrites 429,652 lines. The rewrite is not a reformatting of a generated data file's
//   content, it is the formatter reflowing a file whose size defeats it, and the diff destroys the only
//   reviewable form of the table. It was reverted with `git checkout -- ucd_names.v`; the committed file
//   was intact.
//
// So this runs the compiler over each file separately, skips the two paths with the reason written down,
// and reports anything else. It is a V program rather than a shell line because a gate that has to exclude
// paths is a gate with logic in it, and logic in a shell line is logic nobody can unit test.
//
// The six other generated tables are NOT excluded. They had a real defect — one trailing blank line at end
// of file — which was fixed at the source in tools/gen_tables.v, so a regeneration produces formatted output
// and this gate keeps checking them.
//
// Usage:
//	v run tools/fmt_check.v           check every file
//	v run tools/fmt_check.v layout    check only paths containing "layout"

import os

// excluded maps a path suffix to the reason it is not checked.
//
// A map rather than a list because the reason is the part that matters. A bare skip list says "these are
// exempt" and the next person adds to it; a skip list with reasons attached says "these are exempt because
// of this, which you should go and confirm is still true".
const excluded = {
	'stbtt.c.v':   'the formatter reports it unformatted, writes identical bytes, and shows no diff'
	'ucd_names.v': 'v fmt -w rewrites 429,652 lines of a 1.8 MB generated table and is not reversible by inspection'
}

struct Checked {
mut:
	path string
	ok   bool
	note string
}

fn main() {
	mut filter := ''
	for a in os.args[1..] {
		filter = a
	}
	mut vexe := os.getenv('VEXE')
	if vexe == '' {
		vexe = 'C:\\Users\\MR\\v\\v.exe'
	}

	mut all := collect(filter)
	if all.len == 0 {
		eprintln(if filter == '' {
			'no V files found'
		} else {
			'no V files matching "${filter}"'
		})
		exit(1)
	}

	mut passed := []Checked{}
	mut failed := []Checked{}
	mut skipped := []Checked{}

	for path in all {
		// The reason is bound on its own line because this compiler will not take an Option-returning
		// call in an if initialiser, and the failure names the expression rather than the form.
		reason := exclusion(path)
		if reason != '' {
			skipped << Checked{
				path: path
				note: reason
			}
			continue
		}
		c := verify_one(vexe, path)
		if c.ok {
			passed << c
		} else {
			failed << c
		}
	}

	for c in passed {
		println('ok       ${c.path}')
	}
	for c in skipped {
		println('skipped  ${c.path}')
		println('         ${c.note}')
	}
	for c in failed {
		println('NEEDS FORMATTING  ${c.path}')
	}

	println('')
	println('${passed.len} formatted, ${failed.len} need formatting, ${skipped.len} skipped, ${all.len} total')
	if skipped.len > 0 {
		println('the skipped paths are not exempt by choice: each one is a file this formatter cannot handle,')
		println('and running `v fmt -w` over the whole directory would rewrite one of them by 429,652 lines.')
	}
	exit(failed.len)
}

// collect lists the V files to check.
//
// The walk is recursive, because a gate that reads only the top directory is a gate over half the
// repository: tools/ and examples/ hold thirty-two files between them, and an unformatted one of them
// would pass this gate silently. It prints its own count, so a walk that stopped early shows up in the
// total rather than only in the absence of complaints.
//
// Build outputs are not a concern here because there are none to confuse for sources: the examples write
// .exe and .png beside their .v files and every one of those is ignored. A hidden directory is skipped,
// which keeps the walk out of .git and out of any editor's state directory.
fn collect(filter string) []string {
	mut out := []string{}
	walk('.', filter, mut out)
	out.sort()
	return out
}

// walk adds every V file under dir to out, building paths with forward slashes so a printed name matches
// what a person would type.
fn walk(dir string, filter string, mut out []string) {
	entries := os.ls(dir) or { return }
	for e in entries {
		if e.starts_with('.') {
			continue
		}
		full := if dir == '.' { e } else { dir + '/' + e }
		if os.is_dir(full) {
			walk(full, filter, mut out)
			continue
		}
		if !e.ends_with('.v') {
			continue
		}
		if filter == '' || full.contains(filter) {
			out << full
		}
	}
}

// exclusion returns the reason this path is not checked, or an empty string when it is.
fn exclusion(path string) string {
	for suffix, reason in excluded {
		if path.ends_with(suffix) {
			return reason
		}
	}
	return ''
}

// verify_one runs the formatter's own check on one file.
//
// The compiler is asked for the file by path rather than for the directory, so one file's verdict cannot be
// affected by a sibling it cannot read, and so the exit code means this file. -verify is used rather than
// -l because -l prints "File needs formatting:" to stderr, which arrives on this V as an error record, and
// -verify prints the path it is complaining about as ordinary output.
fn verify_one(vexe string, path string) Checked {
	r := os.exec_opt([vexe, 'fmt', '-verify', path]) or {
		return Checked{
			path: path
			note: 'could not be checked: ' + err.msg()
		}
	}
	return Checked{
		path: path
		ok:   r.exit_code == 0
		note: first_line(r.output)
	}
}

// first_line reduces a compiler message to one line.
//
// The full output of a failed check names the file twice and explains the flag, and the explanation is the
// same for every failure, so printing it per file buries the one thing that differs: the path.
fn first_line(output string) string {
	for line in output.split('\n') {
		if line.trim_space() != '' {
			return line.trim_space()
		}
	}
	return ''
}
