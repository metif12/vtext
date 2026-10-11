module main

// gen_tables reads the Unicode Character Database files in `ucd/` and writes the
// generated range tables that the shaper looks properties up in.
//
// Everything it emits is plain data: a sorted array of CodeRange per property,
// searched with a binary search at run time. Keeping the tables in Unicode's own
// order is what lets the lookup be a single bisect instead of a hash map.
//
// Usage: v run tools/gen_tables.v
//
// The UCD files under ucd/ are pinned to Unicode 18.0.0. Regenerating against a
// newer UCD means replacing those files; every emitted file records the version
// so a mismatch shows up in the diff.

import os

const ucd_dir = 'ucd'
const out_dir = '.'

// unicode_version is written into every generated file.
const unicode_version = '18.0.0'

// CodeRange mirrors vtext.CodeRange. It is redeclared here because a tool that
// generates a module's own data cannot import that module.
struct CodeRange {
mut:
	lo    u32
	hi    u32
	value u16
	pad   u16
}

// PropertyValue is one named value of a property, plus the ordinal used in the
// emitted tables.
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

// parse_hex parses a hexadecimal string with no prefix. UCD files mix upper and
// lower case freely. It returns u32 because V does not allow casting a string to
// an integer.
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

// coalesce_numeric sorts and merges ranges whose value is already a number. The
// canonical combining class is such a property, so there is no name registry to
// intern into.
fn coalesce_numeric(mut ranges []CodeRange) []CodeRange {
	ranges.sort_with_compare(fn (a &CodeRange, b &CodeRange) int {
		if a.lo < b.lo {
			return -1
		}
		if a.lo > b.lo {
			return 1
		}
		return 0
	})
	mut out := []CodeRange{}
	for r in ranges {
		if out.len > 0 {
			mut tail := out[out.len - 1]
			if tail.value == r.value && tail.hi + 1 == r.lo {
				tail.hi = r.hi
				out[out.len - 1] = tail
				continue
			}
		}
		out << r
	}
	return out
}

// dec_u16 parses a decimal number, used where the UCD stores a numeric property
// directly (the canonical combining class).
fn dec_u16(s string) u16 {
	mut out := u16(0)
	for i in 0 .. s.len {
		c := s[i]
		if c >= `0` && c <= `9` {
			out = out * 10 + u16(c - `0`)
		}
	}
	return out
}

// canonical orders of the property values. The UCD's derived files are grouped by
// value, but coalesce sorts by codepoint, so the ordinals cannot be taken from
// file order: they are pinned here, which is also what the hand written enums in
// properties.v assume.
const bidi_class_order = ['L', 'R', 'EN', 'ES', 'ET', 'AN', 'CS', 'B', 'S', 'WS', 'ON', 'BN', 'NSM',
	'AL', 'LRO', 'RLO', 'LRE', 'RLE', 'PDF', 'LRI', 'RLI', 'FSI', 'PDI']

const joining_type_order = ['U', 'C', 'D', 'R', 'L', 'T']

const grapheme_class_order = ['Other', 'CR', 'LF', 'Control', 'Extend', 'ZWJ', 'Regional_Indicator',
	'Prepend', 'SpacingMark', 'L', 'V', 'T', 'LV', 'LVT']

const line_break_order = ['XX', 'CM', 'BA', 'LF', 'BK', 'CR', 'SP', 'EX', 'QU', 'AL', 'PR', 'PO',
	'OP', 'CP', 'IS', 'HY', 'SY', 'NU', 'CL', 'NL', 'GL', 'AI', 'HH', 'BB', 'HL', 'SA', 'JL', 'JV',
	'JT', 'NS', 'AK', 'VI', 'ID', 'ID_CJ', 'VF', 'ZW', 'ZWJ', 'B2', 'IN', 'WJ', 'EB', 'CJ', 'H2',
	'H3', 'SG', 'CB', 'AP', 'RI', 'EM']

// quote_role_order reserves one ordinal per quotation role the rules can tell apart.
//
// The first entry is never written into any range, and that is the point: a codepoint the
// line break table does not call QU falls in no range at all, so the lookup returns 0 and
// reads as "not a quotation mark". Reserving the default explicitly rather than inferring
// it keeps that legible in the generated file, the way bidi_class_order's leading L is.
const quote_role_order = ['qu_none', 'pi', 'pf', 'both']

// sa_mark_order reserves one ordinal per resolution LB1 can give a complex-context character.
//
// The first entry is never written into any range, for the same reason quote_role_order's is: a
// codepoint that is neither SA nor a general-category mark falls in no range, so the lookup returns 0
// and reads as "the letter resolution". The ordinal is then the whole answer, and there is no second
// table to consult to learn whether a 0 meant "not asked" or "not a mark".
const sa_mark_order = ['sa_none', 'sa_mark']

// BracketPair is one entry of the BidiBrackets table: a codepoint, the
// codepoint it pairs with, and whether it opens or closes the pair.
struct BracketPair {
	cp     u32
	paired u32
	kind   u8 // 0 = open, 1 = close
	// canonical is the codepoint this one canonically decomposes to, or 0 when it has
	// no canonical decomposition. Rule BD16 pairs brackets through their canonical
	// equivalents, and U+2329 plus U+232A are the only angle brackets that need it.
	canonical u32
}

// parse_brackets reads BidiBrackets.txt into bracket pairs.
//
// An unread file is fatal for the reason ucd_ranges documents: returning an empty list wrote three
// empty tables without saying so.
fn parse_brackets(path string) []BracketPair {
	data := os.read_file(path) or {
		panic('cannot read ${path}: ${err.msg()}. Run tools/fetch_ucd.v first.')
	}
	mut out := []BracketPair{}
	for line in data.split_into_lines() {
		// The value is followed by " # name", so the comment goes first.
		cut := line.index('#') or { line.len }
		s := line[..cut].trim_space()
		if s == '' {
			continue
		}
		fields := s.split(';')
		if fields.len < 3 {
			continue
		}
		kind := if fields[2].trim_space() == 'o' { u8(0) } else { u8(1) }
		cp := parse_hex(fields[0])
		out << BracketPair{
			cp:        cp
			paired:    parse_hex(fields[1])
			kind:      kind
			canonical: canonical_equivalent(cp)
		}
	}
	// Sorted by codepoint so a lookup is a binary search.
	out.sort_with_compare(fn (a &BracketPair, b &BracketPair) int {
		if a.cp < b.cp {
			return -1
		}
		if a.cp > b.cp {
			return 1
		}
		return 0
	})
	return out
}

// canonical_equivalent returns the single codepoint cp canonically decomposes to, or
// 0 when it has no canonical decomposition, when the decomposition is more than one
// codepoint, or when it is only a compatibility one such as "<wide> 0028".
fn canonical_equivalent(cp u32) u32 {
	data := os.read_file(os.join_path(ucd_dir, 'UnicodeData.txt')) or { return 0 }
	key := '${cp:04X};'
	for line in data.split_into_lines() {
		if !line.starts_with(key) {
			continue
		}
		fields := line.split(';')
		if fields.len < 6 {
			return 0
		}
		decomp := fields[5].trim_space()
		if decomp == '' || decomp.starts_with('<') {
			return 0
		}
		parts := decomp.split(' ')
		if parts.len != 1 {
			return 0
		}
		return parse_hex(parts[0])
	}
	return 0
}

// intern_order reserves ordinals for a known list of values, in order.
fn intern_order(mut reg Registry, order []string) {
	for name in order {
		reg.intern(name)
	}
}

// script_codes maps a Scripts.txt long script name to its ISO 15924 code, read
// from PropertyValueAliases.txt. Shaping features are keyed on the short code,
// so the long name is not enough.
fn script_codes() map[string]string {
	mut out := map[string]string{}
	data := os.read_file(os.join_path(ucd_dir, 'PropertyValueAliases.txt')) or { return out }
	for line in data.split_into_lines() {
		s := line.trim_space()
		if s == '' || s[0] == `#` {
			continue
		}
		fields := s.split(';')
		if fields.len < 3 {
			continue
		}
		prop := fields[0].trim_space()
		if prop != 'sc' {
			continue
		}
		code := fields[1].trim_space()
		long := fields[2].trim_space()
		out[long.replace('_', ' ')] = code
	}
	return out
}

// ucd_ranges reads a UCD data file, skipping comments and blank lines. Lines
// look like `0621; ARABIC LETTER HAMZA; D; BEH` or `0041..005A; Lu`.
//
// A file that cannot be read, or that holds no ranges at all, is fatal rather than empty. Several of
// these files are gitignored and fetched on demand, so a checkout that has not run
// tools/fetch_ucd.v still runs this generator, and the read failure used to arrive as a silent
// `pub const ... = ''`: combining class, joining group and the bracket pairs all came out empty and
// the tables were written that way, because an unread file and a property with no ranges are the
// same empty array to the caller. Nothing downstream can tell them apart, and a build against them
// fails somewhere unrelated.
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
// must already be taken by the property's default so that an absent range means
// the default.
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
// The sort is not optional: the derived UCD files are grouped by property value,
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
	t.w('module vtext\n\n')
	t.w('// Code generated by tools/gen_tables.v. DO NOT EDIT.\n')
	t.w('// Source: Unicode Character Database ${unicode_version}, ${source}\n\n')
}

// emit_values writes the value registry as a name table. A name table rather
// than an enum, because several UCD value names are V keywords (`in`, `as`) and
// enum fields would then have to be escaped; the ordinal is the only thing the
// hot path needs.
fn emit_values(mut t Text, name string, comment string, reg &Registry) {
	t.w('// ${name} lists the values of ${comment}, in ordinal order.\n')
	t.w('// Format: one value per line.\n')
	t.w("pub const ${name}_data = '")
	for v in reg.values {
		t.w('${v.code}\n')
	}
	t.w("'\n\n")
}

// emit_ranges writes a sorted range table as a const string, one range per line:
//
//	const bidi_class_data = '
//		0041 005A 0
//		0061 007A 0
//		...'
//
// A string rather than an array of structs because a V const array written out
// element by element silently materialises as empty in this compiler. The text
// form is also easier to review and to diff than a few thousand struct literals.
fn emit_ranges(mut t Text, name string, comment string, ranges []CodeRange) {
	t.w('// ${name} gives the ${comment}.\n')
	t.w('// Format: one range per line, "lo hi value" in hex and decimal.\n')
	t.w("pub const ${name}_data = '")
	for r in ranges {
		t.w('${r.lo:04x} ${r.hi:04x} ${r.value}\n')
	}
	t.w("'\n\n")
}

// emit_writes writes the accumulated text to out_dir/name.
//
// The body ends with exactly one newline whatever the emitters left, because the emitters close a const
// string with `'` followed by a blank line to separate it from whatever comes next, and at the end of a
// file there is no next thing. That trailing blank line is what `v fmt` reports as a file needing
// formatting, on all seven generated tables at once, and a generated file that cannot pass the formatter
// is a file whose formatting nobody can check.
fn emit_writes(name string, mut t Text) {
	path := os.join_path(out_dir, name)
	body := t.text().trim_right('\n') + '\n'
	os.write_file(path, body) or { panic('cannot write ${path}: ${err}') }
	println('wrote ${path} (${body.len} bytes)')
}

// ----------------------------------------------------------------- one per file

// emit_property reads one UCD file and writes one generated module file.
fn emit_property(name string, out_file string, source string, value_field int,
	values_name string, range_name_ string, value_comment string, reg &Registry) {
	ranges := coalesce(ucd_ranges(os.join_path(ucd_dir, name), value_field), reg)
	mut t := Text{ parts: []string{} }
	emit_header(mut t, source)
	emit_values(mut t, values_name, value_comment, reg)
	emit_ranges(mut t, range_name_, value_comment, ranges)
	emit_writes(out_file, mut t)
}

// ---------------------------------------------------------------- quotation roles

// quote_roles builds the table that tells an opening quotation mark from a closing one.
//
// LineBreak.txt has a single class, QU, for all three of the committee's roles, so the
// distinction has to be read from the general category: DerivedGeneralCategory.txt marks an
// opening mark Pi and a closing one Pf, and a QU that is neither is the kind that can be
// either — U+0022, the apostrophe, the heavy comma ornaments. Measured against Unicode
// 18.0.0: 28 ranges in LineBreak.txt are QU, covering 39 codepoints, of which 12 are Pi, 10
// are Pf and 17 can be either.
//
// Both the QU set and the Pi/Pf set are read from the UCD rather than written out here,
// because the lists are the UCD's and not this file's. The comment column LineBreak.txt
// puts beside each QU range names the general category too, but a comment is not a data
// column, and reading one is how a generator starts producing tables from prose.
fn quote_roles(lb_ranges []ParsedRange, gc_ranges []ParsedRange, reg &Registry) []CodeRange {
	// Pi and Pf together span 22 codepoints in Unicode 18.0.0, so enumerating them costs
	// nothing and every QU range is then a walk over the few marks that fall inside it.
	mut marks := []u32{}
	mut role := map[u32]string{}
	for r in gc_ranges {
		if r.value != 'Pi' && r.value != 'Pf' {
			continue
		}
		name := if r.value == 'Pi' { 'pi' } else { 'pf' }
		for cp in r.lo .. r.hi + 1 {
			marks << cp
			role[cp] = name
		}
	}
	marks.sort()
	mut pieces := []ParsedRange{}
	for r in lb_ranges {
		if r.value != 'QU' {
			continue
		}
		// A range is cut at each mark that falls strictly inside it, so the pieces that come
		// out carry one role each and the emitted table stays in the shape every other table
		// here uses.
		mut lo := r.lo
		for m in marks {
			if m <= lo || m > r.hi {
				continue
			}
			pieces << ParsedRange{
				lo:    lo
				hi:    m - 1
				value: role[lo] or { 'both' }
			}
			lo = m
		}
		pieces << ParsedRange{
			lo:    lo
			hi:    r.hi
			value: role[lo] or { 'both' }
		}
	}
	return coalesce(pieces, reg)
}

// sa_marks builds the table that tells an SA character LB1 must resolve to a combining mark from
// one it must resolve to a letter.
//
// LineBreak.txt has one class, SA, for every complex-context character, and the committee does not
// answer the class the same way for all of them: U+0E31 THAI CHARACTER MAI HAN-AKAT and U+102C
// MYANMAR VOWEL SIGN AA answer `[9.0]`, which is a combining mark on either side, while U+0E01
// THAI CHARACTER KO KAI answers `[28.0]`, which is a letter. The property that separates them is
// General_Category — Mc and Mn against Lo, Lm and So — so this reads the same pair of files
// quote_roles does and for the same reason: neither file answers the question alone.
//
// Only the intersection is emitted, because the engine asks the table about a character the line
// break table has already called SA, and asking it about any other character would need the whole
// Mn and Mc set for an answer that never changes. Every Mn and Mc codepoint outside the SA ranges
// is a mark the other tables already carry a combining class for.
fn sa_marks(lb_ranges []ParsedRange, gc_ranges []ParsedRange, reg &Registry) []CodeRange {
	mut sa := []ParsedRange{}
	for r in lb_ranges {
		if r.value == 'SA' {
			sa << r
		}
	}
	// LineBreak.txt is sorted by codepoint already, but the sort is what the ranges are meant to be
	// walked with and it costs nothing here, the way parse_brackets sorts above.
	sa.sort_with_compare(fn (a &ParsedRange, b &ParsedRange) int {
		if a.lo < b.lo {
			return -1
		}
		if a.lo > b.lo {
			return 1
		}
		return 0
	})
	mut pieces := []ParsedRange{}
	for r in gc_ranges {
		if r.value != 'Mn' && r.value != 'Mc' {
			continue
		}
		// A mark range can straddle several SA ranges and the gaps between them, so it is cut at
		// every SA range it meets and only the overlap is kept. Looping the few SA ranges this way
		// keeps the intersection obvious, where a merged walk of two sorted lists would not.
		for s in sa {
			lo := if r.lo > s.lo { r.lo } else { s.lo }
			hi := if r.hi < s.hi { r.hi } else { s.hi }
			if lo <= hi {
				pieces << ParsedRange{ lo: lo, hi: hi, value: 'sa_mark' }
			}
		}
	}
	return coalesce(pieces, reg)
}

// ------------------------------------------------------------------------ main

fn main() {
	// Bidi category. Ordinal 0 is L, which is also what an absent range means;
	// the overwhelmingly common case then costs no lookup.
	mut bidi := new_registry()
	intern_order(mut bidi, bidi_class_order)
	bidi_ranges := coalesce(ucd_ranges(os.join_path(ucd_dir, 'DerivedBidiClass.txt'), 1), bidi)
	brackets := parse_brackets(os.join_path(ucd_dir, 'BidiBrackets.txt'))
	mut tb := Text{ parts: []string{} }
	emit_header(mut tb, 'extracted/DerivedBidiClass.txt, BidiBrackets.txt')
	emit_values(mut tb, 'bidi_class_names', 'the UAX#9 bidirectional category of every codepoint',
		bidi)
	emit_ranges(mut tb, 'bidi_class_ranges', 'the UAX#9 bidirectional category of every codepoint',
		bidi_ranges)
	// Rule N0 needs to know which brackets pair up, so the table goes with the
	// bidi class rather than in a file of its own.
	tb.w('// bidi_brackets_data lists the bracket pairs rule N0 resolves.\n')
	tb.w('// Format: one pair per line, "cp paired o|c canonical", sorted by cp.\n')
	tb.w("// The canonical field is the codepoint's canonical equivalent, or 0.\n")
	tb.w("pub const bidi_brackets_data = '")
	for b in brackets {
		kind := if b.kind == 0 { 'o' } else { 'c' }
		tb.w('${b.cp:04x} ${b.paired:04x} ${kind} ${b.canonical:04x}\n')
	}
	tb.w("'\n\n")
	emit_writes('ucd_bidi.v', mut tb)

	// Joining_Type and Joining_Group, both needed for Arabic shaping.
	mut jt := new_registry()
	intern_order(mut jt, joining_type_order)
	jt_ranges := coalesce(ucd_ranges(os.join_path(ucd_dir, 'DerivedJoiningType.txt'), 1), jt)
	mut jg := new_registry()
	jg.intern('') // no group
	jg_ranges := coalesce(ucd_ranges(os.join_path(ucd_dir, 'DerivedJoiningGroup.txt'), 1), jg)
	mut t := Text{ parts: []string{} }
	emit_header(mut t, 'extracted/DerivedJoiningType.txt, extracted/DerivedJoiningGroup.txt')
	emit_values(mut t, 'joining_type_names', 'the Joining_Type property', jt)
	emit_values(mut t, 'joining_group_names', 'the Joining_Group property', jg)
	emit_ranges(mut t, 'joining_type_ranges', 'the Joining_Type of every codepoint', jt_ranges)
	emit_ranges(mut t, 'joining_group_ranges', 'the Joining_Group of every codepoint', jg_ranges)
	emit_writes('ucd_joining.v', mut t)

	// Canonical combining class, needed to order marks around a base. The class
	// is itself a small number, so it is stored directly in the range table
	// rather than as an ordinal into a name table; there is nothing to look up.
	mut cc_ranges := []CodeRange{}
	for r in ucd_ranges(os.join_path(ucd_dir, 'DerivedCombiningClass.txt'), 1) {
		cc_ranges << CodeRange{ lo: r.lo, hi: r.hi, value: dec_u16(r.value) }
	}
	cc_ranges = coalesce_numeric(mut cc_ranges)
	mut tcc := Text{ parts: []string{} }
	emit_header(mut tcc, 'extracted/DerivedCombiningClass.txt')
	emit_ranges(mut tcc, 'combining_class_ranges',
		'canonical combining class of every codepoint, as a number', cc_ranges)
	emit_writes('ucd_combining.v', mut tcc)

	// UAX#29 grapheme cluster break property.
	mut gb := new_registry()
	intern_order(mut gb, grapheme_class_order)
	emit_property('GraphemeBreakProperty.txt', 'ucd_grapheme.v',
		'auxiliary/GraphemeBreakProperty.txt', 1, 'grapheme_class_names',
		'grapheme_class_ranges', 'the UAX#29 grapheme break class of every codepoint', gb)

	// UAX#14 line break property.
	mut lb := new_registry()
	intern_order(mut lb, line_break_order)
	emit_property('LineBreak.txt', 'ucd_linebreak.v', 'LineBreak.txt', 1,
		'line_break_names', 'line_break_ranges',
		'the UAX#14 line break class of every codepoint', lb)

	// The quotation roles, which are a second property derived from the same two files: the
	// line break class says a character is a quotation mark and the general category says
	// which kind. LB15a and LB15b are the only rules that tell them apart.
	mut qr := new_registry()
	intern_order(mut qr, quote_role_order)
	lb_all := ucd_ranges(os.join_path(ucd_dir, 'LineBreak.txt'), 1)
	gc_all := ucd_ranges(os.join_path(ucd_dir, 'DerivedGeneralCategory.txt'), 1)
	qr_ranges := quote_roles(lb_all, gc_all, qr)
	mut tq := Text{ parts: []string{} }
	emit_header(mut tq, 'LineBreak.txt, extracted/DerivedGeneralCategory.txt')
	emit_values(mut tq, 'quote_role_names', 'quotation role the UAX #14 rules can tell apart',
		qr)
	emit_ranges(mut tq, 'quote_ranges', 'quotation role the UAX #14 rules can tell apart',
		qr_ranges)
	emit_writes('ucd_quote.v', mut tq)

	// The SA marks, which are the third property derived from the same two files: the line break
	// class says a character is complex context and the general category says whether LB1 resolves
	// it to a letter or to a combining mark.
	mut sm := new_registry()
	intern_order(mut sm, sa_mark_order)
	sm_ranges := sa_marks(lb_all, gc_all, sm)
	mut tsm := Text{ parts: []string{} }
	emit_header(mut tsm, 'LineBreak.txt, extracted/DerivedGeneralCategory.txt')
	emit_values(mut tsm, 'sa_mark_names', 'resolution LB1 gives a complex-context character',
		sm)
	emit_ranges(mut tsm, 'sa_mark_ranges', 'resolution LB1 gives a complex-context character',
		sm_ranges)
	emit_writes('ucd_sa_mark.v', mut tsm)

	// Script, which decides which shaping features and joining rules apply. The
	// values are ISO 15924 codes, mapped from the long names Scripts.txt uses.
	codes := script_codes()
	mut sc := new_registry()
	sc.intern('Unknown')
	mut mapped := []ParsedRange{}
	for r in ucd_ranges(os.join_path(ucd_dir, 'Scripts.txt'), 1) {
		code := codes[r.value] or { r.value }
		mapped << ParsedRange{ lo: r.lo, hi: r.hi, value: code }
	}
	sc_ranges := coalesce(mapped, sc)
	mut t2 := Text{ parts: []string{} }
	emit_header(mut t2, 'Scripts.txt, PropertyValueAliases.txt')
	emit_values(mut t2, 'script_names', 'the script of every codepoint (ISO 15924 tags)', sc)
	emit_ranges(mut t2, 'script_ranges', 'the script of every codepoint', sc_ranges)
	emit_writes('ucd_script.v', mut t2)

	println('done')
}
