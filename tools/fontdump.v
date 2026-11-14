module main

// fontdump prints what a font actually contains.
//
// The tool to reach for first, because most shaping questions are answered by knowing what the font has,
// and half the bugs this library has had were a font using a structure it did not expect. When a line
// comes out wrong, the first question is not "what did the engine do" but "does this font even say so",
// and this answers that without a second reader.
//
// Everything printed here comes from the inspection API in inspect.v, so this program and the library
// cannot disagree about a font: there is one parser and one set of numbers.
//
// What it prints, and why each part is here:
//
//	tables          what is in the file, and where. A font this engine draws nothing from is a fact
//	                worth seeing early rather than at the end.
//	cmap            how the font covers characters, per subtable. Which one the engine picks is a
//	                different question, and a font with a small subtable and a large one depends on it.
//	glyphs          the count, and what GDEF says each one is. A font with no GDEF classifies nothing.
//	GSUB/GPOS       the scripts and features the tables offer, and the size of each lookup list. This
//	                is where "the font has it and this engine cannot use it" becomes visible.
//	capabilities    what this engine can actually do with the font, which is the question a caller has.
//
// The capability section is the point of the tool. A font's features are not a list of things that work;
// they are a list of things a font contains, some of which any given engine reaches and some of which it
// does not. Printing both, side by side, is the only way to see the difference instead of guessing at it.
//
// Usage:
//	v run tools/fontdump.v <font.ttf>
//	v run tools/fontdump.v <font.ttf> --verbose
//
// --verbose adds the per-feature lookup counts, which is what you want when a feature is present but
// does nothing and you need to know whether the font gave it zero lookups or the engine skipped it.

import os
import vtext
import vtext.shape
import vtext.font

// The feature tags the engine's shaping path can act on. A feature that is not in here is either used for
// something else or simply not implemented, and printing the whole list against this one is what makes
// the difference visible.
const engine_uses_gsub = ['ccmp', 'isol', 'fina', 'init', 'medi', 'rlig', 'liga', 'calt', 'locl',
	'rclt']

const engine_uses_gpos = ['kern', 'mark', 'mkmk', 'abvm', 'blwm', 'curs', 'dist']

fn arg(i int, fallback string) string {
	if i < os.args.len {
		return os.args[i]
	}
	return fallback
}

fn main() {
	path := arg(1, '')
	mut verbose := false
	for a in os.args {
		if a == '--verbose' {
			verbose = true
		}
	}
	if path == '' {
		println('usage: v run tools/fontdump.v <font.ttf> [--verbose]')
		exit(1)
	}

	loaded := shape.load_font_file(path) or {
		println('cannot open ${path}: ${err}')
		exit(1)
	}

	println('font            ${path}')
	println('glyphs          ${loaded.num_glyphs()}')
	println('units per em    ${loaded.units_per_em()}')
	println('outlines        ${if loaded.outlines() == '' { 'none' } else { loaded.outlines() }}')
	println('monospaced      ${loaded.is_monospaced()}')
	println('variable        ${loaded.is_variable()}')
	if loaded.is_variable() {
		for axis in loaded.variable_axes() {
			println('  axis ${axis.tag}  ${axis.minimum} .. ${axis.deflt} .. ${axis.maximum}')
		}
	}

	println('')
	println('tables')
	tables := loaded.tables()
	for t in tables {
		mut mark := ' '
		// Tables the engine reads are worth marking, because a font carrying thirty tables is mostly
		// carrying things no engine will ever ask about.
		if t.tag in ['head', 'hhea', 'hmtx', 'maxp', 'cmap', 'loca', 'glyf', 'CFF ', 'GSUB', 'GPOS',
			'GDEF', 'kern', 'name', 'post', 'OS/2'] {
			mark = '*'
		}
		println('  ${mark} ${t.tag}  ${t.length:>9} bytes at ${t.offset}')
	}

	println('')
	println('cmap')
	formats := loaded.cmap_formats()
	counts := loaded.cmap_counts()
	println('  subtables     ${formats.len}')
	for i, format in formats {
		println('  format ${format}  maps ${counts[i]} codepoints')
	}

	println('')
	println('glyph classes   ${loaded.glyph_class_counts()}')
	println('  by name       ${class_names(loaded)}')

	println('')
	println('GSUB  lookups ${loaded.num_lookups('GSUB')}')
	report_table(loaded, 'GSUB', engine_uses_gsub, verbose)

	println('')
	println('GPOS  lookups ${loaded.num_lookups('GPOS')}')
	report_table(loaded, 'GPOS', engine_uses_gpos, verbose)

	println('')
	println('what this engine can do with this font')
	report_capabilities(loaded)
}

// class_names renders the glyph class counts with their names rather than their indexes, because a report
// that said "4904 of class 1" is in the font's language and not the reader's.
fn class_names(f shape.Font) string {
	counts := f.glyph_class_counts()
	mut parts := []string{}
	for i, n in counts {
		if n == 0 {
			continue
		}
		parts << '${shape.glyph_class_names[i]}=${n}'
	}
	return parts.join(' ')
}

// report_table prints the scripts and features of a table, and which of them this engine can act on.
//
// The two lists are printed as a whole rather than interleaved, because the point is the difference
// between them and interleaving hides it. A feature the font offers and the engine ignores is not an
// error in either; it is the thing a caller needs to know.
fn report_table(f &shape.Font, table string, engine_uses []string, verbose bool) {
	scripts := f.scripts(table)
	println('  scripts       ${scripts.len}')
	for s in scripts {
		println('    ${s}')
	}

	features := f.features(table)
	println('  features      ${features.len}')
	mut used := []string{}
	mut unused := []string{}
	for feat in features {
		if feat in engine_uses {
			used << feat
		} else {
			unused << feat
		}
	}
	println('  engine uses   ${used.join(' ')}')
	println('  engine skips  ${unused.join(' ')}')

	if !verbose {
		return
	}
	// With --verbose, say which of the features the engine claims to use actually have lookups behind
	// them. A feature with no lookups is a font that names it and does not implement it, which is a
	// different problem from the engine skipping one.
	println('  feature lookup counts')
	for feat in features {
		if feat !in engine_uses {
			continue
		}
		// Printed per script rather than summed, because the same feature can have a different lookup
		// list under two scripts and a sum would be a number about neither.
		mut shown := false
		for s in scripts {
			n := f.feature_lookups(table, s, feat)
			if n == 0 {
				continue
			}
			println('    ${feat} under ${s}  ${n} lookups')
			shown = true
		}
		if !shown {
			println('    ${feat}  no script names it with any lookups')
		}
	}
}

// report_capabilities prints what this engine can do with this font, which is the question a caller has
// and the one the tables above cannot answer on their own.
fn report_capabilities(f &shape.Font) {
	println('  substitutes       ${yes_no(f.has_gsub())}')
	println('  kerns             ${yes_no(f.kerns('arab'))} (arab)')
	println('  kerns             ${yes_no(f.kerns('latn'))} (latn)')
	println('  context positions ${yes_no(f.contextually_positions('arab'))} (arab)')
	println('  marks on marks    ${yes_no(f.stacks_marks())}')
	println('  marks on ligs     ${yes_no(f.places_marks_on_ligatures())}')
	// A font that declares a cursive feature but gets none of it applied is the case this section exists
	// for, so the declaration and the capability are printed next to each other on purpose.
	if 'curs' in f.features('GPOS') {
		println('  curs declared     yes')
		println('  curs applied      no (not implemented)')
	}
}

// yes_no is a named function rather than a closure: this V rejects a `return if` inside a closure, and a
// two-branch formatting helper is not worth a workaround.
fn yes_no(b bool) string {
	if b {
		return 'yes'
	}
	return 'no'
}
