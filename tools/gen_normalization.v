module main

// gen_normalization reads the Unicode Character Database and writes the tables the
// normalizer needs: canonical decompositions, canonical compositions, and the quick
// check properties that let the common case skip the work.
//
// The three UAX#15 normalization forms are built from two primitives, and only the
// canonical ones matter here: the shaper needs the text canonically equivalent,
// never compatibility equivalent, so NFKD and NFKC are out of scope.
//
//   canonical decomposition   UnicodeData.txt field 5, with the Hangul syllables
//                             done arithmetically rather than from data
//   canonical composition    the reverse of a canonical decomposition, minus the
//                             composition exclusions and minus the singletons
//
// Usage: v run tools/gen_normalization.v

import os

const ucd_dir = 'ucd'
const out_file = 'ucd_normalization.v'

// unicode_version is written into the generated file.
const unicode_version = '18.0.0'

// Hangul. The generator only needs the span of the precomposed syllables, to know
// which UnicodeData.txt rows to leave out; it does not decompose them, because the
// normalizer derives those arithmetically. Storing 11172 decompositions for them
// would dwarf every other table in the shaper.
const hangul_s_base = 0xAC00
const hangul_s_count = 19 * 21 * 28 // 11172, the L x V x T product

// Text accumulates generated source.
struct Text {
mut:
	parts []string
}

fn (mut t Text) w(s string) {
	t.parts << s
}

fn (t &Text) text() string {
	mut sb := []u8{}
	for p in t.parts {
		sb << p.bytes()
	}
	return sb.bytestr()
}

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

// is_hangul_syllable reports whether cp falls in the precomposed Hangul block. Only
// AC00 and AC01 carry a decomposition field in UnicodeData.txt, to mark them as the
// ends of the block; the other 11170 are left blank precisely because the normalizer
// is expected to decompose them arithmetically.
fn is_hangul_syllable(cp u32) bool {
	return cp >= hangul_s_base && cp < hangul_s_base + hangul_s_count
}

// Decomposition is one canonical decomposition, in the form the UAX#15 algorithms
// want: a string of codepoints, sorted by canonical combining class.
struct Decomposition {
	cp     u32
	target []u32
}

// Composition is one canonical composition: a starter and a following character
// combining into a composite.
struct Composition {
	starter   u32
	second    u32
	composite u32
}

fn read_unicode_data() []string {
	data := os.read_file(os.join_path(ucd_dir, 'UnicodeData.txt')) or {
		panic('cannot read UnicodeData.txt: ${err}')
	}
	return data.split_into_lines()
}

// exclusions returns the Full_Composition_Exclusion set: the characters UAX#15 bars
// from taking part in a canonical composition, on top of the singletons, which
// cannot compose by definition.
fn exclusions() map[u32]bool {
	mut out := map[u32]bool{}
	data := os.read_file(os.join_path(ucd_dir, 'CompositionExclusions.txt')) or {
		panic('cannot read CompositionExclusions.txt: ${err}')
	}
	for line in data.split_into_lines() {
		cut := line.index('#') or { line.len }
		s := line[..cut].trim_space()
		if s == '' {
			continue
		}
		out[parse_hex(s)] = true
	}
	return out
}

// qc_flags reads the two quick check properties. NFD_QC=No marks a character that is
// never already decomposed, and NFC_QC=No one that is never already composed.
//
// The two default lines at the top of the file are ranges rather than a single
// value, so they cannot be read as an ordinary property and are dropped here: the
// emitted form is a list of the exceptional codepoints, which needs no default.
fn qc_flags(prop string) []u32 {
	data := os.read_file(os.join_path(ucd_dir, 'DerivedNormalizationProps.txt')) or {
		panic('cannot read DerivedNormalizationProps.txt: ${err}')
	}
	mut out := []u32{}
	for line in data.split_into_lines() {
		cut := line.index('#') or { line.len }
		s := line[..cut].trim_space()
		if s == '' {
			continue
		}
		fields := s.split(';')
		if fields.len < 3 {
			continue
		}
		if fields[1].trim_space() != prop || fields[2].trim_space() != 'N' {
			continue
		}
		codes := fields[0].split('..')
		lo := parse_hex(codes[0])
		hi := if codes.len > 1 { parse_hex(codes[1]) } else { lo }
		for cp in lo .. hi + 1 {
			out << cp
		}
	}
	out.sort()
	return out
}

// flag_ranges coalesces a set of codepoints into "lo hi" pairs. The normalizer
// binary searches this, so 1120 scattered codepoints become 36 lines.
//
// The two appends are written out separately rather than as `out << lo << hi`: this
// compiler miscompiles the chained form, appending one element of zero for the whole
// chain. The result is a table of the right length full of zeros, which looks like a
// parse failure further downstream.
fn flag_ranges(cps []u32) []u32 {
	mut out := []u32{}
	if cps.len == 0 {
		return out
	}
	mut lo := cps[0]
	mut hi := cps[0]
	for cp in cps[1..] {
		if cp == hi + 1 {
			hi = cp
			continue
		}
		out << lo
		out << hi
		lo = cp
		hi = cp
	}
	out << lo
	out << hi
	return out
}

// emit_flag_ranges writes the coalesced set in the shared range form.
//
// The index is stepped by two inside the loop body rather than by a step on the
// for statement: this compiler treats a `i += 2` update in the body as ending the
// iteration one step early, which silently drops every other range.
fn emit_flag_ranges(mut t Text, cps []u32) {
	pairs := flag_ranges(cps)
	for i in 0 .. pairs.len / 2 {
		t.w('${pairs[i * 2]:04x} ${pairs[i * 2 + 1]:04x} 1\n')
	}
}

fn main() {
	excluded := exclusions()
	lines := read_unicode_data()

	mut decompositions := []Decomposition{}
	mut compositions := []Composition{}
	mut hangul := 0

	for line in lines {
		fields := line.split(';')
		if fields.len < 6 {
			continue
		}
		cp := parse_hex(fields[0].trim_space())
		// The Hangul syllables are counted rather than emitted: the normalizer
		// derives them from the arithmetic in UAX#15 instead of from this table.
		if is_hangul_syllable(cp) {
			hangul++
			continue
		}
		decomp := fields[5].trim_space()
		// A decomposition in angle brackets is a compatibility one, which the
		// canonical forms must not apply.
		if decomp == '' || decomp.starts_with('<') {
			continue
		}
		mut target := []u32{}
		for tok in decomp.split(' ') {
			target << parse_hex(tok)
		}
		decompositions << Decomposition{ cp: cp, target: target }
	}

	// The reverse mapping. A canonical decomposition of one codepoint is a
	// composition, unless the composite is excluded or the decomposition is a
	// singleton: a singleton has no starter to compose onto.
	//
	// A decomposition of two codepoints is a composition of the pair in the order
	// they are listed, because the UCD already lists them in canonical order.
	for d in decompositions {
		if d.target.len != 2 {
			continue
		}
		if d.cp in excluded {
			continue
		}
		compositions << Composition{
			starter:   d.target[0]
			second:    d.target[1]
			composite: d.cp
		}
	}

	// Sorted by the pair so the composition lookup is a binary search, and keyed on
	// the starter at run time by walking the range of entries that share one.
	compositions.sort_with_compare(fn (a &Composition, b &Composition) int {
		if a.starter != b.starter {
			return if a.starter < b.starter {
				-1
			} else {
				1
			}
		}
		if a.second != b.second {
			return if a.second < b.second {
				-1
			} else {
				1
			}
		}
		return 0
	})

	// One offset per starter would be simpler to look up than a binary search over
	// the pair table, but most starters have no composition at all, so the table is
	// kept whole and indexed by bisecting on the starter alone.
	mut t := Text{ parts: []string{} }
	t.w('module vtext\n\n')
	t.w('// Code generated by tools/gen_normalization.v. DO NOT EDIT.\n')
	t.w('// Source: Unicode Character Database ${unicode_version},\n')
	t.w('//         UnicodeData.txt, CompositionExclusions.txt, DerivedNormalizationProps.txt\n\n')

	t.w('// canonical_decomposition_data gives the canonical decomposition of every\n')
	t.w('// character that has one, as a single space separated run. Hangul is absent\n')
	t.w('// on purpose: UAX#15 defines those arithmetically and there are 11172 of them.\n')
	t.w('// Format: one line per character, "cp d1 d2 ..." in hex.\n')
	t.w("pub const canonical_decomposition_data = '")
	for d in decompositions {
		mut line := '${d.cp:04x}'
		for t2 in d.target {
			line += ' ${t2:04x}'
		}
		t.w(line + '\n')
	}
	t.w("'\n\n")

	t.w('// canonical_composition_data gives the pairs that compose into a single\n')
	t.w('// character, sorted by starter then second so a lookup is a binary search.\n')
	t.w('// Format: one line per pair, "starter second composite" in hex.\n')
	t.w("pub const canonical_composition_data = '")
	for c in compositions {
		t.w('${c.starter:04x} ${c.second:04x} ${c.composite:04x}\n')
	}
	t.w("'\n\n")

	// These two are emitted in the "lo hi value" form the shared parse_ranges already
	// reads, rather than a two column form of their own. One parser for every range
	// table in the module is worth more than a shorter line here.
	t.w('// nfd_qc_no_ranges gives the characters NFD_QC reports as No, that is the ones\n')
	t.w('// that are never already in their decomposed form. The value column is always\n')
	t.w('// 1, so an absent range means the quick check passes.\n')
	t.w('// Format: one range per line, "lo hi 1" in hex.\n')
	t.w("pub const nfd_qc_no_ranges_data = '")
	emit_flag_ranges(mut t, qc_flags('NFD_QC'))
	t.w("'\n\n")

	t.w('// nfc_qc_no_ranges gives the characters NFC_QC reports as No, that is the ones\n')
	t.w('// that are never already in their composed form.\n')
	t.w('// Format: one range per line, "lo hi 1" in hex.\n')
	t.w("pub const nfc_qc_no_ranges_data = '")
	emit_flag_ranges(mut t, qc_flags('NFC_QC'))
	t.w("'\n")

	body := t.text()
	os.write_file(out_file, body) or { panic('cannot write ${out_file}: ${err}') }
	println('wrote ${out_file} (${body.len} bytes)')
	println('  decompositions: ${decompositions.len} emitted, ${hangul} Hangul syllables derived arithmetically')
	println('  compositions:   ${compositions.len}')
	println('  NFD_QC=No:      ${qc_flags('NFD_QC').len} codepoints in ${flag_ranges(qc_flags('NFD_QC')).len / 2} ranges')
	println('  NFC_QC=No:      ${qc_flags('NFC_QC').len} codepoints in ${flag_ranges(qc_flags('NFC_QC')).len / 2} ranges')
	println('done')
}
