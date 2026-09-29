module vtext

// Rule N0 needs the bracket pairs, which the generator emits next to the bidi
// class table in ucd_bidi.v.

// BracketPair is one entry of the BidiBrackets table: a codepoint, the codepoint
// it pairs with, whether it opens or closes the pair, and its canonical equivalent.
pub struct BracketPair {
pub:
	cp     u32
	paired u32
	// kind is bracket_open for an opening bracket and bracket_close for a closing
	// one.
	kind u8
	// canonical is the codepoint this one canonically decomposes to, or 0. BD16 pairs
	// brackets through their canonical equivalents, so U+2329 pairs with U+3009 even
	// though BidiBrackets.txt only records 2329 with 232A.
	canonical u32
}

const bracket_open = u8(0)
const bracket_close = u8(1)

// parse_bracket_table decodes "cp paired o|c canonical" records, one per line.
//
// Line based rather than character based: a codepoint may contain the hex digits
// a-f, which collide with the o and c markers when scanning a whole string.
fn parse_bracket_table(data string) []BracketPair {
	mut out := []BracketPair{}
	if data.len == 0 {
		return out
	}
	for line in data.split_into_lines() {
		s := line.trim_space()
		if s == '' {
			continue
		}
		fields := s.split(' ')
		if fields.len < 3 {
			continue
		}
		kind := if fields[2] == 'o' { bracket_open } else { bracket_close }
		mut canonical := u32(0)
		if fields.len > 3 {
			canonical = hex_value(fields[3])
		}
		entry := BracketPair{
			cp:        hex_value(fields[0])
			paired:    hex_value(fields[1])
			kind:      kind
			canonical: canonical
		}
		out << entry
	}
	return out
}

// bracket_table returns the decoded bracket table. It is rebuilt on each call: the
// table is a few hundred entries, so caching would save nothing measurable
// against the shaping work that surrounds a lookup.
fn bracket_table() []BracketPair {
	return parse_bracket_table(bidi_brackets_data)
}

// find returns the bracket entry for cp, if it has one. The table is sorted by
// codepoint, so this is a binary search.
fn (b &[]BracketPair) find(cp u32) ?BracketPair {
	mut lo := 0
	mut hi := b.len
	for lo < hi {
		mid := (lo + hi) >> 1
		if b[mid].cp < cp {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo >= b.len || b[lo].cp != cp {
		return none
	}
	return b[lo]
}

// same_bracket reports whether an opening bracket and a closing codepoint are a pair
// under BD16, which compares the two "or its canonical equivalent".
//
// Both sides are normalised before they are compared, which is what makes U+3008 pair
// with U+232A as well as with U+3009. The UCD notes that canonical equivalents exist
// only between U+3008/U+3009 and U+2329/U+232A and that none will be added, so the
// normalisation can never collapse two genuinely different brackets.
fn (b &[]BracketPair) same_bracket(open BracketPair, close_cp u32) bool {
	return b.canonical_form(open.paired) == b.canonical_form(close_cp)
}

// canonical_form returns the codepoint every member of its equivalence class shares:
// its canonical decomposition when it has one, and itself otherwise.
fn (b &[]BracketPair) canonical_form(cp u32) u32 {
	entry := b.find(cp) or { return cp }
	if entry.canonical == 0 {
		return cp
	}
	return entry.canonical
}
