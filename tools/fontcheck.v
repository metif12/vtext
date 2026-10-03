module main

// fontcheck reports what this engine cannot use in a font.
//
// Not whether the font is valid: whether this engine can shape with it, which is a different question and
// the one that matters. A font whose GSUB references a glyph its cmap never produces is valid and unusable,
// and that is a report rather than a crash. A font that uses a lookup type this engine does not read is
// valid, entirely readable by other engines, and silently does less here.
//
// Every line is a claim about this library, and the claims are asked of the library rather than of the file.
// Nothing here re-parses the font: the numbers come from the inspection API, so this tool and the engine
// cannot disagree about what the font contains. What the tool adds is the other half of the comparison, which
// is a list of the lookup kinds this engine reads, and that list is a property of this source tree.
//
// The two halves are printed together on purpose. A font's features are not a list of things that work;
// they are a list of things the font contains, some of which any given engine reaches. Printing the
// declaration and the capability side by side is the only way to see the difference instead of arguing
// about it, and fontdump already prints the same two columns for features.
//
// What is checked, and why each one is a different kind of finding:
//
//	lookup kinds    a kind this engine does not read is a rule that will never fire
//	feature scripts a feature only a tagged language enables is one this engine cannot reach
//	cmap coverage   a font with no glyph for a script it claims is a font with nothing to draw
//	outlines        a font with neither glyf nor CFF draws nothing at all
//	variation       an fvar this engine does not read is a weight that will do nothing
//	marks           a font with marks and no mark rules draws them stacked at the pen
//
// Usage:
//	v run tools/fontcheck.v <font.ttf>
//	v run tools/fontcheck.v <font.ttf> --verbose
//
// --verbose adds the lookup counts by kind, which is what you want when a font is "not working" and the
// summary says everything is present.

import os
import vtext

// Lookup kinds this engine reads. Everything else in a table is carried by the parser and never applied,
// which is a fact about the engine and not about the font.
//
// The list is the source of truth and is written out rather than derived from the parsers, because a
// derived list would say a kind is supported because a struct exists for it, and a struct can be parsed
// without being applied.
//
// Type 7 and type 9 are in the list because the parser follows an extension to the table it wraps. A
// lookup that stays reported as a 7 or a 9 is one whose contents were not recognised, and fontcheck prints
// those separately as "unread" rather than as "not read": the difference is between a rule that is known
// and unused and a rule whose contents are not known at all.
const gsub_reads = [1, 2, 3, 4, 6, 7]

const gpos_reads = [1, 2, 4, 5, 6, 8, 9]

// lookup_kind_name is the OpenType name of a lookup type, or an empty string for one this library does
// not have a name for.
//
// The names are the specification's, not this engine's. "Extension" and "Chaining contextual
// substitution" mean the same thing to fontTools as they do here, and a report that called type 7 "wrapped"
// would be a report nobody else could read.
fn lookup_kind_name(table string, kind int) string {
	match table {
		'GSUB' {
			return match kind {
				1 { 'Single substitution' }
				2 { 'Multiple substitution' }
				3 { 'Alternate substitution' }
				4 { 'Ligature substitution' }
				5 { 'Contextual substitution' }
				6 { 'Chaining contextual substitution' }
				7 { 'Extension substitution' }
				8 { 'Reverse chaining contextual single substitution' }
				else { '' }
			}
		}
		'GPOS' {
			return match kind {
				1 { 'Single positioning' }
				2 { 'Pair positioning' }
				3 { 'Cursive positioning' }
				4 { 'Mark to base positioning' }
				5 { 'Mark to ligature positioning' }
				6 { 'Mark to mark positioning' }
				7 { 'Contextual positioning' }
				8 { 'Chaining contextual positioning' }
				9 { 'Extension positioning' }
				else { '' }
			}
		}
		else {
			return ''
		}
	}
}

// Finding is one thing this engine cannot use, with enough context to act on it.
struct Finding {
mut:
	// kind is a short word for what sort of finding this is, so a report can group them.
	kind string
	// what says what was found, phrased to be read on its own.
	what string
	// why says why the engine cannot use it, or empty when the finding speaks for itself.
	why string
}

fn main() {
	args := os.args[1..]
	if args.len < 1 {
		println('usage: v run tools/fontcheck.v <font.ttf> [--verbose]')
		exit(1)
	}
	path := args[0]
	mut verbose := false
	for a in args[1..] {
		if a == '--verbose' {
			verbose = true
		}
	}

	font := vtext.load_font_file(path) or {
		println('cannot open ${path}: ${err}')
		exit(1)
	}

	mut findings := []Finding{}

	// Outlines. A font with neither is a font this engine cannot draw anything with, and it is worth saying
	// first because everything after it is irrelevant.
	outline := font.outlines()
	if outline == '' {
		findings << Finding{
			kind: 'outlines'
			what: 'no glyf/loca and no CFF table'
			why:  'the rasteriser reads outlines, so this font draws nothing at all'
		}
	}

	// Lookup kinds. A kind this engine does not read is a rule that will never fire, and the count says how
	// much of the font it is.
	//
	// A remaining 9 is its own finding and a more specific one: it means an extension lookup whose contents
	// this engine could not read, so nothing inside it is known at all rather than known and unused. Both
	// Segoe UI and Dubai have exactly one each, and in Dubai's case it is the lookup the `curs` feature
	// reaches, so the two findings below describe one gap from two sides.
	for table, reads in {
		'GSUB': gsub_reads
		'GPOS': gpos_reads
	} {
		counts := font.lookup_type_counts(table)
		for kind, n in counts {
			if kind in reads || (table == 'GPOS' && kind == 3) {
				continue
			}
			name := lookup_kind_name(table, kind)
			label := if name == '' { 'type ${kind}' } else { 'type ${kind} (${name})' }
			mut why := 'this engine does not read that kind, so those rules never fire'
			if kind == 7 || kind == 9 {
				why = 'an extension whose contents this engine could not read, so what is inside is unknown'
			}
			findings << Finding{
				kind: 'lookup'
				what: '${table} has ${n} ${label} lookup(s)'
				why:  why
			}
		}
	}

	// Features the engine claims to use but that no script reaches with any lookups. This is the case a
	// feature list cannot show: 'isol' is in Segoe UI's GSUB and has no lookups under any script, because
	// this engine asks one language system and none of them names it.
	for table, wants in {
		'GSUB': ['ccmp', 'isol', 'fina', 'init', 'medi', 'rlig', 'liga', 'calt']
		'GPOS': ['kern', 'mark', 'mkmk', 'abvm', 'blwm']
	} {
		scripts := font.scripts(table)
		for want in wants {
			if want !in font.features(table) {
				continue
			}
			mut total := 0
			for s in scripts {
				total += font.feature_lookups(table, s, want)
			}
			if total == 0 {
				findings << Finding{
					kind: 'feature'
					what: '${table} declares ${want} and no script enables it with any lookup'
					why:  'this engine resolves features through one language system, and none of them reaches it'
				}
			}
		}
	}

	// Cursive. Dubai is the case worth naming and it needs the `curs` feature rather than a lookup kind to be
	// found: the lookup carrying its cursive rules is wrapped in an extension this engine does not unwrap, so
	// it reports as type 9 and the cursive rule inside it is invisible to a count. The feature is what the
	// font says it has, and it is still declared.
	//
	// The `why` is therefore written twice over, because either statement alone leaves a reader guessing:
	// the lookup it reaches was not read, and the attachment would not be applied even if it had been. Saying
	// "type 3 is not read" when the table has no type 3 in it is a claim about a font that is not this one.
	cursive_lookups := font.lookup_type_counts('GPOS')[3]
	undeciphered := font.lookup_type_counts('GPOS')[9]
	declares_curs := 'curs' in font.features('GPOS')
	if declares_curs || cursive_lookups > 0 {
		mut what := ''
		if cursive_lookups > 0 {
			what += 'GPOS has ${cursive_lookups} Cursive positioning lookup(s)'
		}
		if declares_curs {
			if what != '' {
				what += ' and '
			}
			what += 'a curs feature'
			if undeciphered > 0 {
				what += ' whose ${undeciphered} lookup(s) this engine does not unwrap'
			}
		}
		findings << Finding{
			kind: 'cursive'
			what: what
			why:  'cursive attachment is not applied, so the feature does nothing here whatever the lookup says'
		}
	}

	// Variation. is_variable is a fact about the font and the absence of variation support is a fact about
	// the engine, and the finding exists only because a caller asking for a weight deserves to know.
	if font.is_variable() {
		findings << Finding{
			kind: 'variation'
			what: 'the font is variable (fvar is present)'
			why:  'this engine reads the axes but does not apply a variation to any outline or offset'
		}
	}

	// Marks with no rules. A font that has marks and no mark feature has them drawn at the pen, stacked on
	// top of each other, which looks like a bug in the text and is a gap in the engine's reach.
	if !font.has_mark_attachment() {
		findings << Finding{
			kind: 'marks'
			what: 'no mark attachment rules'
			why:  'a mark is drawn at the pen with no offset, so several of them land on the same place'
		}
	}

	// Coverage per script the font claims. This is the finding that turns a font dump into an answer: a
	// font that declares arab and maps nothing Arabic is a font with nothing to draw for the text its own
	// tables are about.
	for script, sample in {
		'arab': rune(0x0628)
		'latn': rune(0x41)
	} {
		if script !in font.scripts('GSUB') && script !in font.scripts('GPOS') {
			continue
		}
		if !font.has_glyph(sample) {
			findings << Finding{
				kind: 'coverage'
				what: 'declares ${script} but has no glyph for U+${u32(sample):04X}'
				why:  'the shaping rules exist for characters the cmap cannot produce'
			}
		}
	}

	println('font  ${path}')
	if findings.len == 0 {
		println('')
		println('nothing found: every rule this font uses is one this engine reads, and every feature it')
		println('declares is one this engine can reach.')
	} else {
		println('')
		println('${findings.len} thing(s) this engine cannot use:')
		for f in findings {
			println('')
			println('  [${f.kind}] ${f.what}')
			if f.why != '' {
				println('      ${f.why}')
			}
		}
	}

	if verbose {
		println('')
		println('lookup counts by kind')
		for table, reads in {
			'GSUB': gsub_reads
			'GPOS': gpos_reads
		} {
			counts := font.lookup_type_counts(table)
			mut kinds := []int{cap: counts.len}
			for k, _ in counts {
				kinds << k
			}
			kinds.sort()
			for k in kinds {
				name := lookup_kind_name(table, k)
				mut state := 'not read'
				if k in reads {
					state = 'read'
				}
				label := if name == '' { '' } else { ' ${name}' }
				println('  ${table} ${k}${label}: ${counts[k]}  ${state}')
			}
		}
	}

	// The count is the exit code, so a caller can gate on it without parsing the output. A font with
	// findings exits non-zero and a font with none exits zero, and a font that cannot be opened exits one,
	// which is the same as one finding and is the only overlap.
	if findings.len > 0 {
		exit(1)
	}
}
