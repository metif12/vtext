module ucd

// The generated tables in ucd_*.v are const strings, one record per line. They
// are decoded once into a Properties value, which the text system owns and hands
// to the shaper.
//
// They are strings rather than const arrays because a V const array written out
// element by element silently materialises with length zero in this compiler.
// Encoding them as text also keeps a few thousand records reviewable in a diff.
//
// The codepoint-name delta tables are the same shape for a different reason: three
// 143,217-element const arrays materialise as stack compound literals in the module
// initializer, over 2 MB before a single character is shaped, which faults any caller
// thread with a default stack. They are decoded once at load into the heap arrays
// below instead. The names blob itself was always a string.

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
//
// Public because the joining and normalization tables are decoded from the
// same hex the UCD writes, and the tests read them the same way.
pub fn hex_value(s string) u32 {
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
//
// Public for the same reason as hex_value: joining forms carry decimal
// columns the engine reads directly.
pub fn dec_value(s string) u16 {
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
//
// Public: the normalization tables are decoded by the engine outside this
// module with the same decoder that builds Properties.
pub fn parse_ranges(data string) []CodeRange {
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
//
// Public for the same reason lookup_range is: the property tests pin the
// decoder directly rather than through a table that happens to use it.
pub fn parse_names(data string) []string {
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

// parse_ints decodes a whitespace-separated table of non-negative decimals.
//
// Public for the same reason the other decoders are: the names tests pin it
// directly rather than through the table that happens to use it. The values are
// non-negative by construction — deltas from a previous entry and prefix lengths
// — so no sign is read and a malformed word ends the value rather than failing.
pub fn parse_ints(data string) []int {
	mut out := []int{}
	mut cur := 0
	mut have := false
	for i in 0 .. data.len {
		c := data[i]
		if c >= `0` && c <= `9` {
			cur = cur * 10 + int(c - `0`)
			have = true
			continue
		}
		if have {
			out << cur
			cur = 0
			have = false
		}
	}
	if have {
		out << cur
	}
	return out
}

// The decoded name tables. The generated file holds strings; these decode them into the heap
// arrays the readers index. Each call parses once rather than caching in a global, because a
// cached global needs -enable-globals on every build line that touches this module — the suite,
// every tool, CI, the C library — and a flag threaded through all of those is a worse trade than
// a millisecond parse on a trace path. Callers that walk the table hoist the array into a local;
// the readers below take it as an argument for the same reason.
// codepoint_name_cps holds the codepoint of each name, delta coded: the first value is the
// first codepoint and each later value is the step from the entry before it.
pub fn codepoint_name_cps() []int {
	return parse_ints(codepoint_name_cps_data)
}

// codepoint_name_offsets holds where each suffix starts in the names blob, delta coded the same
// way, with one more entry than there are names so the last suffix has an end.
pub fn codepoint_name_offsets() []int {
	return parse_ints(codepoint_name_offsets_data)
}

// codepoint_name_prefix holds how many bytes each suffix shares with the name before it.
pub fn codepoint_name_prefix() []int {
	return parse_ints(codepoint_name_prefix_data)
}
