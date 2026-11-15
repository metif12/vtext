module main

// gen_indic reads the UCD Indic syllabic and positional category files in
// ucd/ and writes the generated range tables the Indic machine looks
// categories up in.
//
// This is a separate tool from tools/gen_tables.v on purpose: that file is
// shared by every other property and an Indic change should not touch it.
// The helpers below mirror its shape (a small text accumulator, a registry
// pinning the ordinals, a fatal read) so the two stay reviewable side by
// side, but nothing here is imported from there.
//
// Usage: v run tools/gen_indic.v
//
// The UCD files under ucd/ are pinned to Unicode 18.0.0. Regenerating
// against a newer UCD means replacing those files; the emitted file records
// the version so a mismatch shows up in the diff.

import os

const ucd_dir = 'ucd'
const out_dir = 'ucd'

// unicode_version is written into the generated file.
const unicode_version = '18.0.0'

// CodeRange mirrors vtext.ucd.CodeRange. It is redeclared here because a tool
// that generates a module own data cannot import that module.
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

// syllabic_order pins the ordinals of Indic_Syllabic_Category, which is also
// what the hand written enum in shape/indic.v assumes. Ordinal 0 is the
// missing default the file declares, so an absent range reads as Other.
const syllabic_order = ['Other', 'Avagraha', 'Bindu', 'Brahmi_Joining_Number', 'Cantillation_Mark',
	'Consonant', 'Consonant_Dead', 'Consonant_Final', 'Consonant_Head_Letter',
	'Consonant_Initial_Postfixed', 'Consonant_Killer', 'Consonant_Medial', 'Consonant_Placeholder',
	'Consonant_Preceding_Repha', 'Consonant_Prefixed', 'Consonant_Subjoined',
	'Consonant_Succeeding_Repha', 'Consonant_With_Stacker', 'Gemination_Mark', 'Invisible_Stacker',
	'Joiner', 'Modifying_Letter', 'Non_Joiner', 'Number', 'Number_Joiner', 'Nukta', 'Pure_Killer',
	'Register_Shifter', 'Reordering_Killer', 'Syllable_Modifier', 'Tone_Letter', 'Tone_Mark', 'Virama',
	'Visarga', 'Vowel', 'Vowel_Dependent', 'Vowel_Independent']

// positional_order pins the ordinals of Indic_Positional_Category the same
// way. Ordinal 0 is the missing default, Not_Applicable.
const positional_order = ['Not_Applicable', 'Bottom', 'Bottom_And_Left', 'Bottom_And_Right', 'Left',
	'Left_And_Right', 'Overstruck', 'Right', 'Top', 'Top_And_Bottom', 'Top_And_Bottom_And_Left',
	'Top_And_Bottom_And_Right', 'Top_And_Left', 'Top_And_Left_And_Right', 'Top_And_Right',
	'Visual_Order_Left']

// intern_order reserves ordinals for a known list of values, in order.
fn intern_order(mut reg Registry, order []string) {
	for name in order {
		reg.intern(name)
	}
}

// ucd_ranges reads a UCD data file, skipping comments and blank lines. Lines
// hold a range, a semicolon, and a value, with the comment after a hash.
//
// A file that cannot be read, or that holds no ranges at all, is fatal
// rather than empty. Several of these files are gitignored and fetched on
// demand, so a checkout that has not fetched them still runs this generator,
// and the read failure used to arrive as a silent empty table downstream.
fn ucd_ranges(path string, value_field int) []ParsedRange {
	data := os.read_file(path) or {
		panic('cannot read ${path}: ${err.msg()}. Run tools/fetch_ucd.v first.')
	}
	mut out := []ParsedRange{}
	for line in data.split_into_lines() {
		// A value is followed by a hash comment on the same line, so the
		// comment goes before the fields are split.
		fore := line.split('#')
		s := fore[0].trim_space()
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
// must already be taken by the property default so that an absent range
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
// The sort is not optional: the UCD files are grouped by property value,
// not by codepoint, and a binary search needs them in order. The merge then
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

// ------------------------------------------------------------------- emission

// emit_header writes the banner every generated file starts with.
fn emit_header(mut t Text, source string) {
	t.w('module ucd\n\n')
	t.w('// Code generated by tools/gen_indic.v. DO NOT EDIT.\n')
	t.w('// Source: Unicode Character Database ${unicode_version}, ${source}\n\n')
}

// emit_values writes the value registry as a name table. A name table rather
// than an enum, because the ordinal is the only thing the hot path needs.
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
	t.w('// Format: one range per line, lo hi value in hex and decimal.\n')
	t.w("pub const ${name}_data = '")
	for r in ranges {
		t.w('${r.lo:04x} ${r.hi:04x} ${r.value}\n')
	}
	t.w("'\n\n")
}

// emit writes the accumulated text to out_dir/name.
//
// The body ends with exactly one newline whatever the emitters left, because
// the emitters close a const string and then leave a blank line to separate
// it from whatever comes next, and at the end of a file there is no next
// thing. That trailing blank line is what v fmt reports as a file needing
// formatting, on every generated table at once.
fn emit(name string, mut t Text) {
	path := os.join_path(out_dir, name)
	body := t.text().trim_right('\n') + '\n'
	os.write_file(path, body) or { panic('cannot write ${path}: ${err}') }
	println('wrote ${path} (${body.len} bytes)')
}

// ------------------------------------------------------------------------ main

fn main() {
	// Indic syllabic categories.
	mut sc := new_registry()
	intern_order(mut sc, syllabic_order)
	syll_ranges := coalesce(ucd_ranges(os.join_path(ucd_dir, 'IndicSyllabicCategory.txt'), 1), sc)
	if sc.values.len != syllabic_order.len {
		panic('IndicSyllabicCategory.txt holds a value outside syllabic_order.')
	}
	mut t := Text{ parts: []string{} }
	emit_header(mut t, 'IndicSyllabicCategory.txt, IndicPositionalCategory.txt')
	emit_values(mut t, 'indic_syllabic_names', 'the Indic_Syllabic_Category of every codepoint', sc)
	emit_ranges(mut t, 'indic_syllabic_ranges', 'the Indic_Syllabic_Category of every codepoint', syll_ranges)
	// Indic positional categories.
	mut pc := new_registry()
	intern_order(mut pc, positional_order)
	pos_ranges := coalesce(ucd_ranges(os.join_path(ucd_dir, 'IndicPositionalCategory.txt'), 1), pc)
	if pc.values.len != positional_order.len {
		panic('IndicPositionalCategory.txt holds a value outside positional_order.')
	}
	emit_values(mut t, 'indic_positional_names', 'the Indic_Positional_Category of every codepoint', pc)
	emit_ranges(mut t, 'indic_positional_ranges', 'the Indic_Positional_Category of every codepoint', pos_ranges)
	emit('ucd_indic.v', mut t)
	println('done')
}
