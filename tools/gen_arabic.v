module main

// gen_arabic reads the Arabic presentation forms out of UnicodeData.txt and writes the
// tables the joining shaper needs to turn a letter and a form into a glyph.
//
// The shaping itself is the joining algorithm of UAX#53, but the codepoints it produces
// come from the Unicode presentation forms: a letter in its initial, medial, final or
// isolated form is a distinct character with its own entry in the Arabic Presentation
// Forms block, and its decomposition records which base and which form it is.
//
// Two tables are emitted because the lookup shapes differ. Most bases are a single
// codepoint, and those are keyed on the codepoint itself. The lam-alef pairs are two
// letters drawn as one, and they are keyed on both. Bases of three or more codepoints
// are the complex ligatures, which the joining algorithm never produces on its own; they
// are left to the OpenType engine.
//
// Usage: v run tools/gen_arabic.v

import os

const ucd_dir = 'ucd'
const out_file = 'ucd_arabic.v'

// unicode_version is written into the generated file.
const unicode_version = '18.0.0'

// form_order fixes the ordinals, which have to match JoiningForm in joining.v.
const form_order = ['isolated', 'final', 'initial', 'medial']

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

// form_ordinal returns the index of a form name in form_order, or 0xFFFF when the tag is
// one of the other decomposition types, which are not joining forms.
fn form_ordinal(name string) u16 {
	for i, f in form_order {
		if f == name {
			return u16(i)
		}
	}
	return 0xFFFF
}

// Single is a presentation form of a single codepoint base.
struct Single {
	cp    u32
	form  u16
	glyph u32
}

// Pair is a presentation form of a two codepoint base, which is a lam-alef ligature.
struct Pair {
	first  u32
	second u32
	form   u16
	glyph  u32
}

// The letters a lam pairs with. ALEF is U+0627, and the other three are its forms with a
// madda, a hamza above and a hamza below.
const lam = u32(0x0644)
const alef_forms = [u32(0x0627), 0x0622, 0x0623, 0x0625, ]

// is_lam_alef reports whether a two codepoint base is one of the lam-alef ligatures.
fn is_lam_alef(first u32, second u32) bool {
	if first != lam {
		return false
	}
	return second in alef_forms
}

fn main() {
	mut singles := []Single{}
	mut pairs := []Pair{}

	data := os.read_file(os.join_path(ucd_dir, 'UnicodeData.txt')) or {
		panic('cannot read UnicodeData.txt: ${err}')
	}

	for line in data.split_into_lines() {
		fields := line.split(';')
		if fields.len < 6 {
			continue
		}
		decomp := fields[5].trim_space()
		// The only decompositions the shaper wants are the four joining forms. The
		// <compat> ones and the canonical ones belong to the normalizer.
		if !decomp.starts_with('<') {
			continue
		}
		// The tag is delimited by its angle brackets, not by the first space: the tag is
		// one of isolated, final, initial or medial, so searching for the space would
		// pick up the closing bracket instead.
		tag_end := decomp.index('>') or { continue }
		ordinal := form_ordinal(decomp[1..tag_end])
		if ordinal == 0xFFFF {
			continue
		}
		base := split_fields(decomp[tag_end + 1..])
		glyph := parse_hex(fields[0].trim_space())
		if base.len == 1 {
			singles << Single{ cp: parse_hex(base[0]), form: ordinal, glyph: glyph }
		} else if base.len == 2 {
			pair := Pair{
				first:  parse_hex(base[0])
				second: parse_hex(base[1])
				form:   ordinal
				glyph:  glyph
			}
			// Most two codepoint bases are complex ligatures that the joining algorithm
			// never forms on its own, and the OpenType engine handles those later. Only
			// the lam-alef pairs are a joining result, so only those are kept here: the
			// first codepoint has to be LAM and the second one of the four alef forms,
			// which are the only letters that pair with a lam this way.
			if is_lam_alef(pair.first, pair.second) {
				pairs << pair
			}
		}
	}

	// Sorted by the key then the form, so a lookup bisects once and walks a run of at
	// most four.
	singles.sort_with_compare(fn (a &Single, b &Single) int {
		if a.cp != b.cp {
			return if a.cp < b.cp {
				-1
			} else {
				1
			}
		}
		return int(a.form) - int(b.form)
	})
	pairs.sort_with_compare(fn (a &Pair, b &Pair) int {
		if a.first != b.first {
			return if a.first < b.first {
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
		return int(a.form) - int(b.form)
	})

	mut t := Text{ parts: []string{} }
	t.w('module vtext\n\n')
	t.w('// Code generated by tools/gen_arabic.v. DO NOT EDIT.\n')
	t.w('// Source: Unicode Character Database ${unicode_version}, UnicodeData.txt\n\n')

	t.w('// arabic_form_names lists the joining forms in ordinal order. The ordinals have\n')
	t.w('// to match JoiningForm in joining.v.\n')
	t.w('// Format: one form per line.\n')
	t.w("pub const arabic_form_names_data = '")
	for f in form_order {
		t.w(f + '\n')
	}
	t.w("'\n\n")

	t.w('// arabic_form_map gives the presentation form of a single codepoint base, sorted\n')
	t.w('// by codepoint then form. A base with no entry for a form has no such presentation\n')
	t.w('// form, and the shaper keeps the base character instead.\n')
	t.w('// Format: one entry per line, "cp form glyph" in hex and decimal.\n')
	t.w("pub const arabic_form_map_data = '")
	for s in singles {
		t.w('${s.cp:04x} ${s.form} ${s.glyph:04x}\n')
	}
	t.w("'\n\n")

	t.w('// arabic_ligature_map gives the presentation form of a two codepoint base, which\n')
	t.w('// is a lam followed by an alef. The first codepoint is the one that comes first\n')
	t.w('// in the text.\n')
	t.w('// Format: one entry per line, "first second form glyph" in hex and decimal.\n')
	t.w("pub const arabic_ligature_map_data = '")
	for p in pairs {
		t.w('${p.first:04x} ${p.second:04x} ${p.form} ${p.glyph:04x}\n')
	}
	t.w("'\n")

	body := t.text()
	os.write_file(out_file, body) or { panic('cannot write ${out_file}: ${err}') }
	println('wrote ${out_file} (${body.len} bytes)')
	println('  single codepoint forms: ${singles.len}')
	println('  ligature forms:         ${pairs.len}')
	println('done')
}

// split_fields splits a whitespace separated record, dropping the empty fields a double
// space or a trailing one would leave behind.
fn split_fields(s string) []string {
	mut out := []string{}
	for f in s.split(' ') {
		if f != '' {
			out << f
		}
	}
	return out
}
