module vtext

import os

// Import-direction ratchet (Phase 11 M1): the module graph from GOAL.md,
// checked rather than trusted. Dependencies run one way — layout uses
// shape and font, shape never uses layout, raster stays a leaf below
// font, and no library file imports tools. A new edge fails here first,
// which is the point: the edge lands with a reason, not by accident.
//
// The table pins the exact vtext-internal set each module may use today;
// anything else starting with `vtext` is a violation. Imports outside
// vtext are the standard library and stay free. Test files are not
// modules and are not scanned; tools/ and examples/ are programs that
// depend on the library and are scanned nowhere.
fn test_modular_import_directions() {
	allowed := {
		'shape':     ['vtext.font', 'vtext.ucd', 'vtext.raster']
		'layout':    ['vtext.shape', 'vtext.font', 'vtext.ucd']
		'font':      ['vtext.ucd', 'vtext.raster']
		'ucd':       []
		'raster':    []
		'subset':    ['vtext.font', 'vtext.shape']
		'providers': []
		'root':      ['vtext.layout', 'vtext.shape', 'vtext.font', 'vtext.subset', 'vtext.ucd',
			'vtext.raster', 'vtext.providers']
	}
	mut violations := []string{}
	mut checked := 0
	for module, _ in allowed {
		// tools/ and examples/ are programs that depend on the library;
		// testdata/ holds fonts, not code. None of them is the module
		// graph, so the walk stays out of all three. The root module is
		// capi.v and trace_api.v, flat beside the part directories.
		mut files := []string{}
		if module == 'root' {
			for entry in os.ls('.')! {
				if entry.ends_with('.v') && !os.is_dir(entry) {
					files << entry
				}
			}
		} else {
			files = v_files_in(module, ['tools', 'examples', 'testdata', '.git']) or {
				violations << 'ratchet cannot read ${module}: ${err}'
				continue
			}
		}
		for file in files {
			if file.ends_with('_test.v') {
				continue
			}
			src := os.read_file(file) or {
				violations << 'ratchet cannot read ${file}: ${err}'
				continue
			}
			checked++
			for line in src.split_into_lines() {
				imp := parse_import_line(line.trim_space()) or { continue }
				if imp == '' {
					violations << '${file} has an import the ratchet cannot parse: ${line.trim_space()}'
					continue
				}
				if imp.contains('tools') {
					violations << '${file} imports ${imp}: nothing in the library imports tools'
					continue
				}
				if imp.starts_with('vtext') && imp !in allowed[module] {
					violations << '${file} imports ${imp}: ${module} may use ${allowed[module]}'
				}
			}
		}
	}
	assert checked > 0, 'the import ratchet scanned no files'
	assert violations.len == 0, 'import direction violations:\n' + violations.join('\n')
}

// parse_import_line answers the module an `import` line names, or none
// for a line that is not an import. An empty answer with no error means
// the line does name one but in a shape this ratchet does not know, which
// fails the test at the call site rather than silently passing.
fn parse_import_line(line string) ?string {
	if !line.starts_with('import ') && line != 'import' {
		return none
	}
	rest := line['import'.len..].trim_space()
	if rest == '' || rest.starts_with('(') {
		return ''
	}
	// One module per line in this tree; a comma list answers its first
	// unparseable member the same empty string so the caller names it.
	parts := rest.split(',')
	if parts.len != 1 {
		return ''
	}
	mut name := parts[0].trim_space()
	if name.contains(' as ') {
		name = name.all_before(' as ').trim_space()
	}
	if name == '' || name.contains(' ') {
		return ''
	}
	return name
}

// v_files_in answers every .v file under dir, skipping the program and
// data trees by name, because a ratchet that lists files by hand stops
// checking the file added after it.
fn v_files_in(dir string, skip []string) ![]string {
	mut out := []string{}
	entries := os.ls(dir)!
	for entry in entries {
		if entry in skip {
			continue
		}
		path := os.join_path(dir, entry)
		if os.is_dir(path) {
			out << v_files_in(path, skip)!
		} else if entry.ends_with('.v') {
			out << path
		}
	}
	return out
}
