module main

// capicheck proves vtext.h and vtext.def match capi.v, in both directions.
//
// capi.v is the source of truth: every @[export] there appears in vtext.h and
// vtext.def, and nothing appears in either file that capi.v does not export. A
// missing symbol fails the C link, which CI would catch, but a drifted struct
// field or a stale declaration does not fail anything — so this check reads
// all three files as text and compares the names. It runs in CI before the
// shared library builds, so a drift fails fast rather than as a loader fault.

import os

fn main() {
	capi := os.read_file('capi.v') or {
		eprintln('cannot read capi.v: ${err.msg()}')
		exit(1)
	}
	header := os.read_file('vtext.h') or {
		eprintln('cannot read vtext.h: ${err.msg()}')
		exit(1)
	}
	def := os.read_file('vtext.def') or {
		eprintln('cannot read vtext.def: ${err.msg()}')
		exit(1)
	}
	exports := exported_names(capi)
	h_names := header_names(header)
	d_names := def_names(def)

	mut failed := false
	for name in exports {
		if name !in h_names {
			eprintln('missing from vtext.h: ${name}')
			failed = true
		}
		if name !in d_names {
			eprintln('missing from vtext.def: ${name}')
			failed = true
		}
	}
	for name in h_names {
		if name !in exports {
			eprintln('stale in vtext.h: ${name}')
			failed = true
		}
	}
	for name in d_names {
		if name !in exports {
			eprintln('stale in vtext.def: ${name}')
			failed = true
		}
	}
	if failed {
		exit(1)
	}
	println('capi mirror ok: ${exports.len} exports in capi.v, vtext.h and vtext.def')
}

// exported_names lists every @[export] in capi.v: the quoted name when the
// attribute carries one, otherwise the function on the next declaration line.
fn exported_names(src string) []string {
	mut out := []string{}
	lines := src.split_into_lines()
	mut i := 0
	for i < lines.len {
		line := lines[i].trim_space()
		if line.starts_with('@[export') {
			name := export_name(line)
			if name != '' {
				out << name
			} else {
				following := next_fn_name(lines, i + 1)
				if following != '' {
					out << following
				}
			}
		}
		i++
	}
	return out
}

// export_name reads the quoted name out of @[export: 'name']. A bare @[export]
// carries none, and the caller falls through to the declaration line.
fn export_name(line string) string {
	start := line.index("'") or { return '' }
	rest := line[start + 1..]
	end := rest.index("'") or { return '' }
	return rest[..end]
}

// next_fn_name is the function the next declaration line names, for a bare
// @[export] whose name is the function's own.
fn next_fn_name(lines []string, from int) string {
	for i in from .. lines.len {
		line := lines[i].trim_space()
		if line == '' || line.starts_with('//') {
			continue
		}
		if line.starts_with('pub fn ') {
			rest := line['pub fn '.len..]
			end := rest.index('(') or { return '' }
			return rest[..end]
		}
		return ''
	}
	return ''
}

// header_names lists the vtext_ functions vtext.h declares: a vtext_ word
// immediately followed by an open paren. Types carry no paren, so the structs
// and the opaque handles never match.
fn header_names(src string) []string {
	mut out := []string{}
	for line in src.split_into_lines() {
		mut rest := line
		for {
			at := rest.index('vtext_') or { break }
			after := rest[at..]
			mut end := 6
			for end < after.len && (after[end].is_letter() || after[end].is_digit() || after[end] == `_`) {
				end++
			}
			if end < after.len && after[end] == `(` {
				name := after[..end]
				if name !in out {
					out << name
				}
			}
			rest = after[end..]
		}
	}
	return out
}

// def_names lists the exports vtext.def names: every non-empty trimmed line
// after the EXPORTS header. The LIBRARY line names the binary, not a symbol.
fn def_names(src string) []string {
	mut out := []string{}
	mut in_exports := false
	for line in src.split_into_lines() {
		t := line.trim_space()
		if t == 'EXPORTS' {
			in_exports = true
			continue
		}
		if in_exports && t != '' {
			out << t
		}
	}
	return out
}
