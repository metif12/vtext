module vtext

// The generated tables in ucd_*.v are const strings, one record per line. They
// are decoded once into a Properties value, which the text system owns and hands
// to the shaper.
//
// They are strings rather than const arrays because a V const array written out
// element by element silently materialises with length zero in this compiler.
// Encoding them as text also keeps a few thousand records reviewable in a diff.

// CodeRange maps a contiguous span of codepoints to one property value. Tables
// are sorted by lo and non-overlapping, so a property lookup is a binary search.
pub struct CodeRange {
pub:
	lo    u32
	hi    u32
	value u16
}

// Properties holds the decoded Unicode property tables. It is immutable once
// built, so it can be shared between threads and between faces.
pub struct Properties {
pub:
	bidi_ranges      []CodeRange
	joining_ranges   []CodeRange
	group_ranges     []CodeRange
	combining_ranges []CodeRange
	script_ranges    []CodeRange
	grapheme_ranges  []CodeRange
	linebreak_ranges []CodeRange
	bidi_names       []string
	joining_names    []string
	group_names      []string
	script_names     []string
	grapheme_names   []string
	linebreak_names  []string
}

// new_properties decodes every generated table. It costs a few hundred
// microseconds, so it is done once per text system rather than per lookup.
pub fn new_properties() &Properties {
	return &Properties{
		bidi_ranges:      parse_ranges(bidi_class_ranges_data)
		joining_ranges:   parse_ranges(joining_type_ranges_data)
		group_ranges:     parse_ranges(joining_group_ranges_data)
		combining_ranges: parse_ranges(combining_class_ranges_data)
		script_ranges:    parse_ranges(script_ranges_data)
		grapheme_ranges:  parse_ranges(grapheme_class_ranges_data)
		linebreak_ranges: parse_ranges(line_break_ranges_data)
		bidi_names:       parse_names(bidi_class_names_data)
		joining_names:    parse_names(joining_type_names_data)
		group_names:      parse_names(joining_group_names_data)
		script_names:     parse_names(script_names_data)
		grapheme_names:   parse_names(grapheme_class_names_data)
		linebreak_names:  parse_names(line_break_names_data)
	}
}

// hex_value parses a hexadecimal number with no prefix, either case.
fn hex_value(s string) u32 {
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

// dec_value parses a decimal number.
fn dec_value(s string) u16 {
	mut out := u16(0)
	for i in 0 .. s.len {
		c := s[i]
		if c >= `0` && c <= `9` {
			out = out * 10 + u16(c - `0`)
		}
	}
	return out
}

// parse_ranges decodes a "lo hi value" table, one range per line. It walks the
// string directly rather than splitting it, so a table costs one allocation
// instead of one per line.
fn parse_ranges(data string) []CodeRange {
	mut out := []CodeRange{}
	if data.len == 0 {
		return out
	}
	mut lo := u32(0)
	mut hi := u32(0)
	mut value := u16(0)
	mut field := 0
	mut num := []u8{cap: 8}
	for i in 0 .. data.len {
		c := data[i]
		if c == ` ` || c == `\n` || c == `\r` || c == `\t` {
			if num.len > 0 {
				match field {
					0 {
						lo = hex_value(num.bytestr())
					}
					1 {
						hi = hex_value(num.bytestr())
					}
					else {
						value = dec_value(num.bytestr())
					}
				}
				field++
				if field == 3 {
					out << CodeRange{ lo: lo, hi: hi, value: value }
					field = 0
				}
				num = []u8{cap: 8}
			}
			continue
		}
		num << c
	}
	// The last record may not be followed by a newline, so flush whatever is
	// still pending.
	if num.len > 0 {
		match field {
			0 {
				lo = hex_value(num.bytestr())
			}
			1 {
				hi = hex_value(num.bytestr())
			}
			else {
				value = dec_value(num.bytestr())
			}
		}
		field++
	}
	if field == 3 {
		out << CodeRange{ lo: lo, hi: hi, value: value }
	}
	return out
}

// parse_names decodes a one-value-per-line name table.
fn parse_names(data string) []string {
	mut out := []string{}
	if data.len == 0 {
		return out
	}
	for line in data.split_into_lines() {
		s := line.trim_space()
		if s != '' {
			out << s
		}
	}
	return out
}
