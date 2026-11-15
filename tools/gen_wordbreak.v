module main

// gen_wordbreak reads the UAX #29 word and sentence break property files in
// `ucd/` and writes the generated range tables the segmenter looks
// properties up in.
//
// This is a separate tool from tools/gen_tables.v on purpose: that file is
// shared by every other property and a word-break change should not touch
// it. The helpers below mirror its shape (a small text accumulator, a
// registry pinning the ordinals, a fatal read) so the two stay reviewable
// side by side, but nothing here is imported from there.
//
// Usage: v run tools/gen_wordbreak.v
//
// The UCD files under ucd/ are pinned to Unicode 18.0.0. Regenerating against
// a newer UCD means replacing those files; every emitted file records the
// version so a mismatch shows up in the diff.
//
// emoji-data.txt is pinned separately at 18.0.0 to match the UCD, and is
// committed under a versioned name because the copy tools/fetch_ucd.v fetches
// is 16.0.0: Extended_Pictographic narrowed substantially between the two
// (the whole dingbat block left it), so the 16.0.0 file answers WB3c wrong
// for U+2701 and its neighbours.

import os

const ucd_dir = 'ucd'
const out_dir = 'ucd'

// unicode_version is written into every generated file.
const unicode_version = '18.0.0'

// CodeRange mirrors vtext.ucd.CodeRange. It is redeclared here because a tool
// that generates a module's own data cannot import that module.
struct CodeRange {
mut:
	lo    u32
	hi    u32
	value u16
	pad   u16
}

// PropertyValue is one named value of a property, plus the ordinal used in
// the emitted tables.
struct PropertyValue {
	name string
	code string
}

// ParsedRange is a range read from a UCD file, before names are resolved.
struct ParsedRange {
	lo    u32
	hi    u32
	value string
}

// Text accumulates generated source. It holds an array rather than a
// strings.Builder because appending to an array is visible through every copy
// of the struct, whereas a builder passed by reference loses its writes.
struct Text {
mut:
	parts []string
}

// w appends a fragment.
fn (mut t Text) w(s string) {
	t.parts << s
}

// text returns the accumulated source.
fn (t &Text) text() string {
	mut sb := []u8{}
	for p in t.parts {
		sb << p.bytes()
	}
	return sb.bytestr()
}

// ---------------------------------------------------------------- UCD parsing

// parse_hex parses a hexadecimal number with no prefix. UCD files mix upper
// and lower case freely. It returns u32 because V does not allow casting a
// string to an integer.
fn parse_hex(s string) u32 {
	mut out := u32(0)
	for i in 0 .. s.len {
		c := s[i]
		if c >= `0` && c <= `9` {
			out = out * 16 + u32(c - `0`)
		} else if c >= `a` && c <= `f` {
			out = out * 16 + u32(c - `a`) + 10
		} else if c >= `A` && c <= `F` {
			out = out * 16 + u32(c - `A`) + 10
		}
	}
	return out
}

// canonical orders of the property values. The UCD's auxiliary files are
// grouped by value, but coalesce sorts by codepoint, so the ordinals cannot be
// taken from file order: they are pinned here, which is also what the hand
// written enums in ucd/wordbreak.v assume. Ordinal 0 is the @missing default
// both files declare, so an absent range means the default.
const word_break_order = ['Other', 'CR', 'LF', 'Newline', 'Extend', 'ZWJ', 'Regional_Indicator',
	'Format', 'Katakana', 'Hebrew_Letter', 'ALetter', 'Single_Quote', 'Double_Quote', 'MidNumLet',
	'MidLetter', 'MidNum', 'Numeric', 'ExtendNumLet', 'WSegSpace']

const sentence_break_order = ['Other', 'CR', 'LF', 'Extend', 'Sep', 'Format', 'Sp', 'Lower', 'Upper',
	'OLetter', 'Numeric', 'ATerm', 'SContinue', 'STerm', 'Close']

// intern_order reserves ordinals for a known list of values, in order.
fn intern_order(mut reg Registry, order []string) {
	for name in order {
		reg.intern(name)
	}
}

// ucd_ranges reads a UCD data file, skipping comments and blank lines. Lines
// look like `0022; Double_Quote # Po QUOTATION MARK`.
//
// A file that cannot be read, or that holds no ranges at all, is fatal rather
// than empty. Several of these files are gitignored and fetched on demand, so
// a checkout that has not run tools/fetch_ucd.v still runs this generator,
// and the read failure used to arrive as a silent empty table downstream.
fn ucd_ranges(path string, value_field int) []ParsedRange {
	data := os.read_file(path) or {
		panic('cannot read ${path}: ${err.msg()}. Run tools/fetch_ucd.v first.')
	}
	mut out := []ParsedRange{}
	for line in data.split_into_lines() {
		// A value is followed by " # comment" on the same line, so the comment
		// has to go before the fields are split.
		cut := line.index('#') or { line.len }
		s := line[..cut].trim_space()
		if s == '' {
			continue
		}
		fields := s.split(';')
		if fields.len <= value_field {
			continue
		}
		codes := fields[0].split('..')
		lo_cp := parse_hex(codes[0])
		hi_cp := if codes.len > 1 {
			parse_hex(codes[1])
		} else {
			lo_cp
		}
		name := fields[value_field].trim_space()
		out << ParsedRange{ lo: lo_cp, hi: hi_cp, value: name }
	}
	if out.len == 0 {
		panic('${path} held no data lines. Run tools/fetch_ucd.v first.')
	}
	return out
}

// ------------------------------------------------------------- value registries

// Registry assigns a stable ordinal to every distinct property value, keeping
// the ordinals in the order the UCD file lists them so diffs stay readable.
struct Registry {
mut:
	values []PropertyValue
	index  map[string]int
}

fn new_registry() &Registry {
	return &Registry{
		values: []PropertyValue{}
		index:  map[string]int{}
	}
}

// intern returns the ordinal for name, allocating one on first use. Ordinal 0
// must already be taken by the property's default so that an absent range
// means the default.
fn (mut r Registry) intern(name string) int {
	if name in r.index {
		return r.index[name]!
	}
	idx := r.values.len
	r.values << PropertyValue{ name: name, code: name }
	r.index[name] = idx
	return idx
}

// coalesce sorts by codepoint and merges adjacent ranges that share a value.
// The sort is not optional: the UCD files are grouped by property value, not
// by codepoint, and a binary search needs them in order. The merge then
// collapses the boundaries the UCD adds purely for readability.
fn coalesce(ranges []ParsedRange, reg &Registry) []CodeRange {
	mut sorted := ranges.clone()
	sorted.sort_with_compare(fn (a &ParsedRange, b &ParsedRange) int {
		if a.lo < b.lo {
			return -1
		}
		if a.lo > b.lo {
			return 1
		}
		return 0
	})
	mut out := []CodeRange{}
	for r in sorted {
		v := u16(reg.intern(r.value))
		if out.len > 0 {
			mut tail := out[out.len - 1]
			if tail.value == v && tail.hi + 1 == r.lo {
				tail.hi = r.hi
				out[out.len - 1] = tail
				continue
			}
		}
		out << CodeRange{ lo: r.lo, hi: r.hi, value: v, pad: 0 }
	}
	return out
}

// subtract_ranges answers base minus cut as a sorted range list. Both inputs
// are UCD range soup (grouped by property, overlapping freely); the output
// is sorted by codepoint and non-overlapping, ready for coalesce. Only
// bounds are compared — values never are — so this is set difference on
// codepoint sets, which is what EBG needs.
fn subtract_ranges(base []ParsedRange, cut []ParsedRange) []ParsedRange {
	mut bs := base.clone()
	bs.sort_with_compare(fn (a &ParsedRange, b &ParsedRange) int {
		if a.lo < b.lo {
			return -1
		}
		if a.lo > b.lo {
			return 1
		}
		return 0
	})
	mut cs := cut.clone()
	cs.sort_with_compare(fn (a &ParsedRange, b &ParsedRange) int {
		if a.lo < b.lo {
			return -1
		}
		if a.lo > b.lo {
			return 1
		}
		return 0
	})
	mut out := []ParsedRange{}
	mut j := 0
	for b in bs {
		mut lo := b.lo
		for j < cs.len && cs[j].hi < lo {
			j++
		}
		mut k := j
		for k < cs.len && cs[k].lo <= b.hi {
			if cs[k].lo > lo {
				out << ParsedRange{ lo: lo, hi: cs[k].lo - 1, value: b.value }
			}
			if cs[k].hi + 1 > lo {
				lo = cs[k].hi + 1
			}
			k++
		}
		if lo <= b.hi {
			out << ParsedRange{ lo: lo, hi: b.hi, value: b.value }
		}
	}
	return out
}

// ------------------------------------------------------------------- emission

// emit_header writes the banner every generated file starts with.
fn emit_header(mut t Text, source string) {
	t.w('module ucd\n\n')
	t.w('// Code generated by tools/gen_wordbreak.v. DO NOT EDIT.\n')
	t.w('// Source: Unicode Character Database ${unicode_version}, ${source}\n\n')
}

// emit_values writes the value registry as a name table. A name table rather
// than an enum, because several UCD value names are V keywords (`in`, `as`)
// and enum fields would then have to be escaped; the ordinal is the only
// thing the hot path needs.
fn emit_values(mut t Text, name string, comment string, reg &Registry) {
	t.w('// ${name} lists the values of ${comment}, in ordinal order.\n')
	t.w('// Format: one value per line.\n')
	t.w("pub const ${name}_data = '")
	for v in reg.values {
		t.w('${v.code}\n')
	}
	t.w("'\n\n")
}

// emit_ranges writes a sorted range table as a const string, one range per
// line. A string rather than an array of structs because a V const array
// written out element by element silently materialises as empty in this
// compiler. The text form is also easier to review and to diff.
fn emit_ranges(mut t Text, name string, comment string, ranges []CodeRange) {
	t.w('// ${name} gives the ${comment}.\n')
	t.w('// Format: one range per line, "lo hi value" in hex and decimal.\n')
	t.w("pub const ${name}_data = '")
	for r in ranges {
		t.w('${r.lo:04x} ${r.hi:04x} ${r.value}\n')
	}
	t.w("'\n\n")
}

// emit writes the accumulated text to out_dir/name.
//
// The body ends with exactly one newline whatever the emitters left, because
// the emitters close a const string with `'` followed by a blank line to
// separate it from whatever comes next, and at the end of a file there is no
// next thing. That trailing blank line is what `v fmt` reports as a file
// needing formatting, on every generated table at once.
fn emit(name string, mut t Text) {
	path := os.join_path(out_dir, name)
	body := t.text().trim_right('\n') + '\n'
	os.write_file(path, body) or { panic('cannot write ${path}: ${err}') }
	println('wrote ${path} (${body.len} bytes)')
}

// ------------------------------------------------------------------------ main

fn main() {
	// UAX #29 word break property.
	mut wb := new_registry()
	intern_order(mut wb, word_break_order)
	ranges := coalesce(ucd_ranges(os.join_path(ucd_dir, 'WordBreakProperty.txt'), 1), wb)
	if wb.values.len != word_break_order.len {
		panic('WordBreakProperty.txt holds a value outside word_break_order: ${wb.values}')
	}
	mut t := Text{ parts: []string{} }
	emit_header(mut t, 'auxiliary/WordBreakProperty.txt, emoji/emoji-data.txt 18.0.0')
	emit_values(mut t, 'word_break_names', 'UAX#29 word break class of every codepoint',
		wb)
	emit_ranges(mut t, 'word_break_ranges', 'UAX#29 word break class of every codepoint',
		ranges)

	// The extended pictographs, which are the right-hand side of WB3c: a ZWJ
	// holds to one. ucd/emoji-data-18.0.0.txt lists the pictographs, and only the
	// ranges marked Extended_Pictographic are emitted, the way the word table
	// above carries the classes the rules can tell apart.
	mut ep := []ParsedRange{}
	for r in ucd_ranges(os.join_path(ucd_dir, 'emoji-data-18.0.0.txt'), 1) {
		if r.value == 'Extended_Pictographic' {
			ep << ParsedRange{ lo: r.lo, hi: r.hi, value: 'word_ep' }
		}
	}
	mut er := new_registry()
	// Ordinal 0 is reserved for "not in any range", the way the quotation
	// roles reserve their first entry: a lookup that finds nothing reads as
	// absent rather than as a match.
	er.intern('_')
	er.intern('word_ep')
	ep_ranges := coalesce(ep, er)
	emit_values(mut t, 'word_ep_names', 'whether a codepoint is an extended pictograph',
		er)
	emit_ranges(mut t, 'word_ep_ranges', 'whether a codepoint is an extended pictograph',
		ep_ranges)

	// GB10 needs two more emoji sets from the same file: E_Modifier (a
	// combining skin tone holds to what precedes it) and EBG, the emoji that
	// take a modifier without being bases or pictographs themselves. EBG is
	// derived, not listed: Emoji ranges minus Emoji_Presentation ranges, per
	// UAX #29 (EBG = Emoji AND NOT Emoji_Presentation). The derivation runs
	// once here; the committed artifact is data like every other table.
	mut emoji_all := []ParsedRange{}
	mut emoji_pres := []ParsedRange{}
	mut emoji_mod := []ParsedRange{}
	mut emoji_base := []ParsedRange{}
	for r in ucd_ranges(os.join_path(ucd_dir, 'emoji-data-18.0.0.txt'), 1) {
		if r.value == 'Emoji' {
			emoji_all << r
		} else if r.value == 'Emoji_Presentation' {
			emoji_pres << r
		} else if r.value == 'Emoji_Modifier' {
			emoji_mod << ParsedRange{ lo: r.lo, hi: r.hi, value: 'emoji_mod' }
		} else if r.value == 'Emoji_Modifier_Base' {
			emoji_base << ParsedRange{ lo: r.lo, hi: r.hi, value: 'emoji_base' }
		}
	}
	ebg_parts := subtract_ranges(emoji_all, emoji_pres)
	mut ebg := []ParsedRange{}
	for r in ebg_parts {
		ebg << ParsedRange{ lo: r.lo, hi: r.hi, value: 'ebg' }
	}
	mut mr := new_registry()
	mr.intern('_')
	mr.intern('emoji_mod')
	mod_ranges := coalesce(emoji_mod, mr)
	emit_values(mut t, 'emoji_mod_names', 'whether a codepoint is an emoji modifier',
		mr)
	emit_ranges(mut t, 'emoji_mod_ranges', 'whether a codepoint is an emoji modifier',
		mod_ranges)
	mut ar := new_registry()
	ar.intern('_')
	ar.intern('emoji_base')
	base_ranges := coalesce(emoji_base, ar)
	emit_values(mut t, 'emoji_base_names', 'whether a codepoint is an emoji modifier base',
		ar)
	emit_ranges(mut t, 'emoji_base_ranges', 'whether a codepoint is an emoji modifier base',
		base_ranges)
	mut br := new_registry()
	br.intern('_')
	br.intern('ebg')
	ebg_ranges := coalesce(ebg, br)
	emit_values(mut t, 'ebg_names', 'whether a codepoint is emoji with a text-default presentation',
		br)
	emit_ranges(mut t, 'ebg_ranges', 'whether a codepoint is emoji with a text-default presentation',
		ebg_ranges)

	// GB9c reads Indic_Conjunct_Break: a Linker holding through Extends to a
	// Consonant never breaks. The InCB rows live in DerivedCoreProperties.txt
	// (format `CP ; InCB; Value`), not in an InCB file of their own — the UCD
	// root carries no such file, and the property aliases confirm the three
	// values. Ordinal 0 is the @missing default the file states (None), so
	// an absent range reads as no conjunct role.
	mut incb_all := []ParsedRange{}
	incb_src := os.read_file(os.join_path(ucd_dir, 'DerivedCoreProperties.txt')) or {
		panic('cannot read DerivedCoreProperties.txt: ${err.msg()}. Run tools/fetch_ucd.v first.')
	}
	for line in incb_src.split_into_lines() {
		cut := line.index('#') or { line.len }
		body := line[..cut].trim_space()
		if body == '' {
			continue
		}
		fields := body.split(';')
		if fields.len != 3 || fields[1].trim_space() != 'InCB' {
			continue
		}
		codes := fields[0].split('..')
		lo_cp := parse_hex(codes[0])
		hi_cp := if codes.len > 1 {
			parse_hex(codes[1])
		} else {
			lo_cp
		}
		incb_all << ParsedRange{ lo: lo_cp, hi: hi_cp, value: fields[2].trim_space() }
	}
	if incb_all.len == 0 {
		panic('DerivedCoreProperties.txt held no InCB rows')
	}
	mut ir := new_registry()
	ir.intern('_')
	ir.intern('Linker')
	ir.intern('Extend')
	ir.intern('Consonant')
	incb_ranges := coalesce(incb_all, ir)
	if ir.values.len != 4 {
		panic('DerivedCoreProperties.txt held an InCB value outside _, Linker, Extend, Consonant: ${ir.values}')
	}
	emit_values(mut t, 'incb_names', 'the Indic_Conjunct_Break value of every codepoint',
		ir)
	emit_ranges(mut t, 'incb_ranges', 'the Indic_Conjunct_Break value of every codepoint',
		incb_ranges)
	emit('ucd_wordbreak.v', mut t)

	// UAX #29 sentence break property.
	mut sb := new_registry()
	intern_order(mut sb, sentence_break_order)
	sb_ranges := coalesce(ucd_ranges(os.join_path(ucd_dir, 'SentenceBreakProperty.txt'), 1), sb)
	if sb.values.len != sentence_break_order.len {
		panic('SentenceBreakProperty.txt holds a value outside sentence_break_order: ${sb.values}')
	}
	mut ts := Text{ parts: []string{} }
	emit_header(mut ts, 'auxiliary/SentenceBreakProperty.txt')
	emit_values(mut ts, 'sentence_break_names',
		'UAX#29 sentence break class of every codepoint', sb)
	emit_ranges(mut ts, 'sentence_break_ranges',
		'UAX#29 sentence break class of every codepoint', sb_ranges)
	emit('ucd_sentence.v', mut ts)

	println('done')
}
