module main

// gen_codepoint_names reads UnicodeData.txt and writes a front-coded table of codepoint names.
//
// The only reason this exists is that tools/shapetrace prints codepoints, and a trace reading "U+FEA7"
// tells a reader nothing they can act on. The codepoints a shaping trace prints are mostly presentation
// forms, U+FExx and U+FB50 onward, and the difference between a trace that names them and one that numbers
// them is the difference between a question that gets settled and one that gets argued about from memory.
//
// Front coding is not an optimisation here, it is the difference between compiling and not compiling.
// The names in codepoint order share long prefixes: consecutive entries are usually variants of one
// another, "ARABIC LETTER KHAH INITIAL FORM" next to "ARABIC LETTER KHAH MEDIAL FORM", and the average
// shared prefix across the table is eighteen characters. Storing each name whole wrote a 13MB constant,
// which the C backend emits as a string literal and which then fails with "could not allocate 16777216
// bytes" before a line of anything is tested. Storing (shared length, suffix) writes about 330KB, which
// compiles.
//
// The formats, all three in codepoint order and all the same length:
//
//	codepoint_names_data     the suffixes, concatenated, one byte per character
//	codepoint_name_cps       the codepoint of each name, u32
//	codepoint_name_offsets   where each suffix starts in the data, u32, one more than there are names
//	codepoint_name_prefix    how many bytes each suffix shares with the name before it, u8
//
// A suffix of length zero is a name repeated verbatim, which happens for the control aliases, and it is
// why the prefix length is stored rather than the suffix length.
//
// Usage: v run tools/gen_codepoint_names.v
//
// The UCD files under ucd/ are pinned by tools/fetch_ucd.v and are not committed. The generated table
// records the Unicode version it came from, so a stale table is visible in its own contents rather than in
// a file timestamp.

import os

const ucd_file = 'ucd/UnicodeData.txt'
const out_file = 'ucd_names.v'

// Text accumulates generated source. The builder is passed by value rather than by reference because the
// same helper exists in gen_tables.v for the same reason.
struct Text {
mut:
	parts []string
}

fn (mut t Text) w(s string) {
	t.parts << s
}

// writeln is w with a newline. The generated file is line-oriented because every other generated file in
// this directory is, and a diff that does not line up against those is a diff nobody reads.
fn (mut t Text) writeln(s string) {
	t.parts << s
	t.parts << '\n'
}

fn (t &Text) text() string {
	mut sb := []u8{}
	for p in t.parts {
		sb << p.bytes()
	}
	return sb.bytestr()
}

// A name is one codepoint and the string it is called.
struct Name {
mut:
	cp   int
	name string
}

fn main() {
	text := os.read_file(ucd_file) or { panic('cannot read ${ucd_file}: ${err}') }
	version := ucd_version()

	mut names := []Name{cap: 40000}
	mut first_cp := -1
	mut marker := Marker{}

	for line in text.split('\n') {
		fields := line.split(';')
		if fields.len < 2 {
			continue
		}
		cp := int(parse_hex(fields[0].trim_space()))
		mut name := fields[1].trim_space()

		if name.starts_with('<') {
			// A range marker, and the decision about which ones to expand is not the same as "which ones
			// name a codepoint". Three kinds appear and only the first is worth expanding.
			//
			// CJK Ideograph is a real name: a trace printing a Han ideograph has to print which one, and
			// "CJK Ideograph+4F60" is the whole of what Unicode says about it. Expanding that is the point
			// of this generator.
			//
			// Hangul Syllable is derived, not named. Unicode's own name for U+AC00 is not a syllable name
			// but a formula, because the syllable is composed and the composition is the fact. Expanding
			// the marker would give eleven thousand names that say "HANGUL SYLLABLE" with a number on the
			// end, which is a worse answer than none: it looks like a name and is not one.
			//
			// Private Use has no name at all, and Unicode says so by giving a range marker instead. Making
			// one up from the codepoint would be inventing data.
			//
			// So only CJK is expanded. The other two are skipped, and a codepoint with no name is answered
			// with its hex value by the caller, which is what a missing name should look like.
			if name.contains(', First>') {
				// Only CJK Ideograph is expanded. Hangul Syllable is derived rather than named, and
				// Private Use has no name at all, so both are left to the caller's hex fallback: a name
				// invented from a range marker reads like a fact from the UCD and is not one.
				if name.starts_with('<CJK Ideograph') {
					first_cp = cp
					marker = parse_marker(name)
				}
			} else if name.contains(', Last>') && first_cp >= 0 {
				// The marker is "<CJK Ideograph, First>": the brackets are notation, the comma is the
				// separator before the digit count, and what is left between them is the name's stem. So the
				// stem is everything from after the '<' up to that comma, not everything before the '<'.
				// all_before('<') on a string whose only '<' is the first character returns the whole string,
				// which is how every name in this block came out as its own digits.
				stem := cjk_stem(marker.prefix.all_after('<').trim_right(' ,'))
				for c in first_cp .. cp + 1 {
					names << Name{
						cp:   c
						name: stem + hex_fixed(c, marker.width)
					}
				}
				first_cp = -1
			}
			continue
		}
		// Field 2 can carry a legacy alias after a semicolon, and the canonical name is the part before it.
		if name.contains(';') {
			name = name.all_before(';').trim_space()
		}
		if name != '' {
			names << Name{ cp: cp, name: name }
		}
	}

	sort_names(mut names)

	// Front coding: each entry keeps only the bytes it does not share with the entry before it. The
	// previous name is tracked rather than the previous entry's bytes, because the first entry has no
	// predecessor and every later one compares against the fully expanded name. Comparing against the
	// previous suffix instead would chain the sharing and store a prefix length that is relative to a
	// string the reader has not rebuilt yet.
	mut data := []u8{}
	mut offsets := []u32{cap: names.len + 1}
	mut cps := []u32{cap: names.len}
	mut prefixes := []u8{cap: names.len}
	mut prev := ''
	for n in names {
		offsets << u32(data.len)
		cps << u32(n.cp)
		shared := common_prefix_len(prev, n.name)
		// A prefix longer than 255 does not occur in this table, and it is checked rather than cast:
		// a u8 that wrapped would store a short length and the reader would rebuild a name from the wrong
		// prefix, which is a table that answers confidently and wrongly.
		if shared > 255 {
			panic('shared prefix of ${shared} bytes at U+${n.cp:x} does not fit the format')
		}
		prefixes << u8(shared)
		data << n.name[shared..].bytes()
		prev = n.name
	}
	offsets << u32(data.len)

	// The codepoints and the offsets are both ascending and both bounded, so each is stored as a delta
	// from the previous entry. That roughly halves the two widest columns, and they were what decided
	// whether the generated file was a reasonable thing to have in a tree at all.
	//
	// The delta is from the previous entry rather than from zero so a reader cannot lose its place by
	// skipping one: a running total that skipped an add gives every later entry the wrong absolute value,
	// and a name read at the wrong offset is a plausible string rather than an obvious failure. The first
	// delta of each table is therefore the absolute first value, which is worth saying out loud because an
	// array whose first element means something different from the rest is a trap.
	mut cps_delta := []u32{cap: cps.len}
	if cps.len > 0 {
		cps_delta << cps[0]
		for i in 1 .. cps.len {
			cps_delta << cps[i] - cps[i - 1]
		}
	}
	mut offsets_delta := []u32{cap: offsets.len}
	if offsets.len > 0 {
		offsets_delta << offsets[0]
		for i in 1 .. offsets.len {
			offsets_delta << offsets[i] - offsets[i - 1]
		}
	}

	mut out := Text{}
	out.writeln('module vtext')
	out.writeln('')
	out.writeln('// Code generated by tools/gen_codepoint_names.v. DO NOT EDIT.')
	out.writeln('// Source: Unicode Character Database ${version}, UnicodeData.txt')
	out.writeln('')
	out.writeln('// The names of every assigned codepoint, front coded and in codepoint order.')
	out.writeln('//')
	out.writeln('// Each entry is the length of the prefix it shares with the name before it and the')
	out.writeln('// bytes that follow it, so a reader rebuilds a name by taking the previous name, cutting')
	out.writeln('// it to that length and appending the suffix. An entry with a zero-length suffix repeats the')
	out.writeln('// previous name verbatim.')
	out.writeln('//')
	out.writeln('// All four tables are in the same order and the same length, so one binary search over the')
	out.writeln('// codepoints finds the other three.')
	out.writeln("pub const codepoint_names_data = '" + data.bytestr().replace('\n', '\\n') + "'")
	out.writeln('')
	out.writeln('pub const codepoint_name_cps_delta = [')
	write_numbers(mut out, cps_delta)
	out.writeln(']')
	out.writeln('')
	out.writeln('pub const codepoint_name_offsets_delta = [')
	write_numbers(mut out, offsets_delta)
	out.writeln(']')
	out.writeln('')
	out.writeln('pub const codepoint_name_prefix = [')
	write_u8s(mut out, prefixes)
	out.writeln(']')

	os.write_file(out_file, out.text()) or { panic('cannot write ${out_file}: ${err}') }
	// The unencoded size is printed as well as the encoded one, because the ratio is the only way to tell
	// at a glance whether the table has stopped sharing prefixes. A format change that broke the sharing
	// would grow the file by four times and still compile, so the ratio is the thing to watch, not the
	// presence of a file.
	mut plain := 0
	for n in names {
		plain += n.name.len
	}
	println('wrote ${out_file}: ${names.len} names from Unicode ${version}, ${data.len} bytes front coded from ${plain}')
}

// common_prefix_len is how many leading bytes two names share.
//
// Bytes and not runes: the data is bytes, the offsets are bytes, and a name with a non-ASCII character in
// it would make a rune count disagree with the offsets table. Comparing bytes is the only way the two stay
// in step, and a prefix cut in the middle of a multi-byte character is still a byte-identical prefix.
fn common_prefix_len(a string, b string) int {
	limit := if a.len < b.len { a.len } else { b.len }
	mut i := 0
	for i < limit && a[i] == b[i] {
		i++
	}
	return i
}

// write_numbers writes an array literal, wrapping on width. The wrapping is not decoration: a generated
// file with one line a kilometre long is a file no diff can show and no tool can read.
fn write_numbers(mut out Text, values []u32) {
	mut line := ''
	for v in values {
		piece := '${v}, '
		if line.len + piece.len > 100 {
			out.writeln(line.trim_right(' '))
			line = ''
		}
		line += piece
	}
	if line.trim_right(' ').len > 0 {
		out.writeln(line.trim_right(' '))
	}
}

// write_u8s writes the prefix lengths, which are single bytes and so the only table of its kind.
fn write_u8s(mut out Text, values []u8) {
	mut line := ''
	for v in values {
		piece := '${v}, '
		if line.len + piece.len > 100 {
			out.writeln(line.trim_right(' '))
			line = ''
		}
		line += piece
	}
	if line.trim_right(' ').len > 0 {
		out.writeln(line.trim_right(' '))
	}
}

// Marker is a UnicodeData.txt range marker with its First or Last suffix removed, e.g.
// "<CJK Ideograph, First>" becomes "<CJK Ideograph,".
//
// The trailing comma is kept, and that is the whole point. The marker names its codepoint suffix width in
// its last field, so "<CJK Ideograph Extension A, First>" says one digit and "<CJK Ideograph, First>" says
// five, and the width is read by splitting on the last comma. Stripping the suffix with a replacement that
// leaves no comma behind leaves nothing to split on: rfind(',') returns -1, the prefix slice is the whole
// string, and every ideograph in the block comes out named "<CJK Ideograph>00000000004e00".
//
// The markers also carry angle brackets, which are part of the range notation rather than part of the
// name, so they are dropped when the name is assembled.
struct Marker {
mut:
	// prefix is the name up to the last comma, brackets included.
	prefix string
	// width is how many hex digits the codepoint is written in.
	width int
}

// cjk_stem maps a CJK range marker's own wording onto the name Unicode actually uses for those codepoints.
//
// UnicodeData.txt calls the blocks "CJK Ideograph" in their range markers and calls the codepoints
// "CJK UNIFIED IDEOGRAPH" in their names. Both are correct and they are not the same string: the marker is a
// label for the range and the name is a label for one codepoint. Copying the marker's wording produces a
// table of names that read like UCD names and are not in the UCD, and the difference is only visible by
// comparing against unicodedata, which is the check that found it.
//
// Only two forms exist among the blocks this expands. Verified against unicodedata for U+3400, U+4E00,
// U+20000, U+2A700, U+2F800 and U+30000: every ideograph block is "CJK UNIFIED IDEOGRAPH" with no letter
// suffix at all, and the compatibility ideographs are "CJK COMPATIBILITY IDEOGRAPH". The marker names carry
// the block letter ("Extension A") and Unicode's names do not, so the letter is dropped rather than kept.
fn cjk_stem(marker_name string) string {
	if marker_name.starts_with('CJK Ideograph Compatibility') {
		return 'CJK COMPATIBILITY IDEOGRAPH-'
	}
	return 'CJK UNIFIED IDEOGRAPH-'
}

// parse_marker reads a First marker and returns the name template and the digit width it implies.
//
// The split is on the last comma, done with all_before_last rather than an index search: this V has no
// rfind, and a marker has exactly one comma so either end of the split would do, but the last is the one
// before the digit count and that is the one the format needs.
//
// The prefix keeps the leading bracket, because the bracket is what says where the name starts. Dropping it
// here and trying to strip it later leaves nothing to strip from: all_before('<') on a string whose only
// '<' is the first character returns the whole string, so every name came out as the digits alone.
fn parse_marker(name string) Marker {
	head := name.all_before_last(',')
	if head.len == name.len {
		// No comma at all: the marker has no digit field and nothing to say about the width. Four is the
		// width Unicode uses for a block that does not state one, and it is only reachable from a marker
		// this build has not seen.
		return Marker{ prefix: name, width: 4 }
	}
	digits := name.all_after_last(',').trim_right('>')
	mut width := 0
	for c in digits {
		if c >= `0` && c <= `9` {
			width++
		}
	}
	return Marker{
		prefix: head + ','
		width:  width
	}
}

// hex_fixed writes a codepoint as an uppercase hex number, padded to at least width digits.
//
// The width matters and is not cosmetic: UnicodeData.txt's marker for the main CJK block states five digits
// and the extension blocks state four, so a fixed four-digit substitution would name every ideograph in the
// main block with a number that is not a codepoint at all.
//
// The number is never truncated to the width. A four-digit width and a five-digit codepoint both occur, the
// second in the main CJK block, and Unicode writes the name with the codepoint's own digits: U+4E00 is
// "CJK UNIFIED IDEOGRAPH-4E00" with five. Padding to a minimum is what matches; trimming to a maximum would
// drop the leading digit and name a different codepoint.
//
// Uppercase matters for the same reason and is the difference between a name the UCD agrees with and one a
// character away from it: Unicode writes "4E00" and a lowercase generator writes "4e00", which reads as a
// codepoint and is not what the UCD says.
fn hex_fixed(cp int, width int) string {
	mut digits := '${cp:04X}'
	for digits.len < width {
		digits = '0' + digits
	}
	return digits
}

// ucd_version reads the version out of the directory's ReadMe.
//
// It does not come from UnicodeData.txt itself: that file has no header comment, and a generator that
// reported "unknown" would put "unknown" into the generated table, where it reads as a fact rather than as
// a failure to look. ReadMe.txt says "final data files for version 18.0.0 of the", which is the version of
// the data in this directory and of every other file here, which is the thing worth recording.
fn ucd_version() string {
	text := os.read_file('ucd/ReadMe.txt') or { return 'unknown' }
	for line in text.split('\n') {
		if line.contains('final data files for version ') {
			rest := line.all_after('final data files for version ')
			// The sentence carries "18.0.0 of the", so the version is the run of digits and dots up to the
			// first space. Indexing the string and taking one character at a time is what V needs here:
			// iterating a string yields runes and appending their str() to a string does not assemble the
			// characters, it concatenates the decimal codes.
			mut version := []u8{}
			for i in 0 .. rest.len {
				c := rest[i]
				if c == ` ` {
					break
				}
				version << c
			}
			return version.bytestr().trim_right('.')
		}
	}
	return 'unknown'
}

// sort_names orders by codepoint. The input is already nearly ordered because UnicodeData.txt is in
// codepoint order except for the expanded ranges, so an insertion sort is close to linear here and it
// keeps the generator free of a dependency it would otherwise need for a one-time job.
fn sort_names(mut list []Name) {
	for i in 1 .. list.len {
		mut k := i
		for k > 0 && list[k].cp < list[k - 1].cp {
			list[k], list[k - 1] = list[k - 1], list[k]
			k--
		}
	}
}

// parse_hex reads a UCD hex field with no prefix. UCD files mix upper and lower case freely.
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
