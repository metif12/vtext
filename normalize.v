module vtext

// Unicode normalization, in the canonical forms UAX#15 defines: NFD and NFC.
//
// The shaper needs canonically equivalent text before anything else. Arabic
// shaping in particular works on the decomposed form, and a font's cmap rarely maps
// the precomposed characters a user types, so normalizing is what turns typed text
// into something the glyph lookup can resolve.
//
// NFKD and NFKC are deliberately absent. They apply compatibility decompositions,
// which the shaper must never do: halfwidth forms, circled letters and the like are
// distinct characters with distinct meanings, and folding them together changes what
// the text says.
//
// Both forms get a quick check from the UCD, so the common case costs one lookup per
// character and no allocation: a string whose characters all pass is already in that
// form.

/// normalizing_max_expansion bounds the recursive decomposition. The UCD's canonical
/// decompositions are at most two levels deep, so the bound is slack; it is there
/// so a malformed table degrades to less normalization instead of running forever.
const normalizing_max_expansion = 8

// Hangul. UAX#15 defines the composition and decomposition of the 11172 precomposed
// syllables arithmetically, so they are not in a table: a stored entry for each would
// be larger than every other table in the module put together.
const hangul_s_base = u32(0xAC00)
const hangul_l_base = u32(0x1100)
const hangul_v_base = u32(0x1161)
const hangul_t_base = u32(0x11A7)
const hangul_l_count = u32(19)
const hangul_v_count = u32(21)
const hangul_t_count = u32(28)
const hangul_n_count = hangul_v_count * hangul_t_count // 588
const hangul_s_count = hangul_l_count * hangul_n_count // 11172

// Decomposition is one canonical decomposition.
pub struct Decomposition {
pub:
	cp u32
	// to is the decomposition in canonical order. The UCD already lists it that way,
	// and the reordering pass relies on it.
	to []u32
}

// Composition is one canonical composition: a starter and a following character that
// combine into a composite.
pub struct Composition {
pub:
	starter   u32
	second    u32
	composite u32
}

// Normalizer holds the decoded normalization tables, and the Properties it needs the
// canonical combining class from. It is immutable once built, so one instance can be
// shared.
//
// The Properties are held on the heap rather than by reference, because a reference
// field would have to be proven non-escaping at every assignment; the tables are small
// and a value copy is not worth worrying about.
pub struct Normalizer {
pub:
	// decompositions is sorted by cp.
	decompositions []Decomposition
	// compositions is sorted by starter, then by second.
	compositions []Composition
	// nfd_no and nfc_no are the quick check sets: the characters that are never
	// already in the corresponding form. Sorted, non-overlapping ranges.
	nfd_no []CodeRange
	nfc_no []CodeRange
	props  Properties @[heap]
}

// new_normalizer decodes the generated tables. It costs a few hundred microseconds,
// so it is built once next to the Properties rather than per call.
pub fn new_normalizer(props Properties) &Normalizer {
	return &Normalizer{
		decompositions: parse_decompositions(canonical_decomposition_data)
		compositions:   parse_compositions(canonical_composition_data)
		nfd_no:         parse_ranges(nfd_qc_no_ranges_data)
		nfc_no:         parse_ranges(nfc_qc_no_ranges_data)
		props:          props
	}
}

// check_tables verifies the invariants the binary searches rely on. A table that
// arrives unsorted or unterminated from a generator change would otherwise make every
// lookup quietly return the wrong answer, and the conformance run would report it as
// hundreds of unrelated failures.
pub fn (n &Normalizer) check_tables() string {
	for i in 1 .. n.decompositions.len {
		if n.decompositions[i].cp <= n.decompositions[i - 1].cp {
			return 'decompositions not sorted at ${i}'
		}
	}
	for d in n.decompositions {
		if d.to.len == 0 {
			return 'empty decomposition for ${d.cp:04x}'
		}
	}
	for i in 1 .. n.compositions.len {
		a := n.compositions[i - 1]
		b := n.compositions[i]
		if b.starter < a.starter || (b.starter == a.starter && b.second <= a.second) {
			return 'compositions not sorted at ${i}'
		}
	}
	if n.nfd_no.len == 0 {
		return 'the NFD quick check set is empty'
	}
	if n.nfc_no.len == 0 {
		return 'the NFC quick check set is empty'
	}
	return ''
}

// is_nfd_qc_yes reports whether cp is already canonically decomposed, and so whether
// a string of such characters is already NFD.
pub fn (n &Normalizer) is_nfd_qc_yes(cp rune) bool {
	return !in_ranges(n.nfd_no, u32(cp))
}

// is_nfc_qc_yes reports whether cp is already canonically composed.
pub fn (n &Normalizer) is_nfc_qc_yes(cp rune) bool {
	return !in_ranges(n.nfc_no, u32(cp))
}

// is_normalized_nfd reports whether cps is already in NFD, which the caller can use
// to skip the copy entirely.
pub fn (n &Normalizer) is_normalized_nfd(cps []rune) bool {
	for cp in cps {
		if !n.is_nfd_qc_yes(cp) {
			return false
		}
	}
	return true
}

// is_normalized_nfc reports whether cps is already in NFC.
pub fn (n &Normalizer) is_normalized_nfc(cps []rune) bool {
	for cp in cps {
		if !n.is_nfc_qc_yes(cp) {
			return false
		}
	}
	return true
}

// nfd returns the canonically decomposed form of cps.
pub fn (n &Normalizer) nfd(cps []rune) []rune {
	if n.is_normalized_nfd(cps) {
		// The quick check answers one question only: whether any character needs
		// decomposing. It says nothing about order, and a string can pass it and still
		// have its marks in the wrong order, so the reordering pass has to run either
		// way. Checking before copying keeps the common case free of an allocation.
		if !n.marks_out_of_order(cps) {
			return cps
		}
		mut ordered := cps.clone()
		n.reorder_canonical(mut ordered)
		return ordered
	}
	mut out := []rune{cap: cps.len}
	for cp in cps {
		n.append_decomposed(cp, 0, mut out)
	}
	n.reorder_canonical(mut out)
	return out
}

// marks_out_of_order reports whether any run of non-starters is not in combining class
// order, which is the one thing the NFD quick check cannot see.
fn (n &Normalizer) marks_out_of_order(cps []rune) bool {
	mut i := 0
	for i < cps.len {
		if n.props.combining_class_of(cps[i]) == 0 {
			i++
			continue
		}
		// A maximal run of marks starts here, including one at the start of the string,
		// and reaches to the next starter or to the end. A mark that follows a mark of
		// a higher class puts the run out of order.
		mut prev := -1
		mut j := i
		for j < cps.len {
			cc := n.props.combining_class_of(cps[j])
			if cc == 0 {
				break
			}
			// Strictly less, so that marks sharing a class count as ordered.
			if prev >= 0 && cc < prev {
				return true
			}
			prev = cc
			j++
		}
		// j is at least i+1, and cps[j] is the starter that ended the run, so resuming
		// there advances rather than rescanning.
		i = j
	}
	return false
}

// nfc returns the canonically composed form of cps.
pub fn (n &Normalizer) nfc(cps []rune) []rune {
	decomposed := n.nfd(cps)
	return n.compose_canonical(decomposed)
}

// append_decomposed appends the full canonical decomposition of cp to out.
fn (n &Normalizer) append_decomposed(cp rune, depth int, mut out []rune) {
	c := u32(cp)
	if c >= hangul_s_base && c < hangul_s_base + hangul_s_count {
		out << rune(hangul_l_base + (c - hangul_s_base) / hangul_n_count)
		v_index := (c - hangul_s_base) % hangul_n_count / hangul_t_count
		out << rune(hangul_v_base + v_index)
		t := (c - hangul_s_base) % hangul_t_count
		if t != 0 {
			out << rune(hangul_t_base + t)
		}
		return
	}
	d := n.find_decomposition(c) or {
		out << cp
		return
	}
	// A decomposition can itself be decomposable, and the table stores the mapping
	// rather than its transitive closure, so this has to recurse.
	if depth >= normalizing_max_expansion {
		for part in d.to {
			out << rune(part)
		}
		return
	}
	for part in d.to {
		n.append_decomposed(rune(part), depth + 1, mut out)
	}
}

// find_decomposition returns the canonical decomposition of cp, if the UCD has one.
fn (n &Normalizer) find_decomposition(cp u32) ?Decomposition {
	d := n.decompositions
	mut lo := 0
	mut hi := d.len
	for lo < hi {
		mid := (lo + hi) >> 1
		if d[mid].cp < cp {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo >= d.len || d[lo].cp != cp {
		return none
	}
	return d[lo]
}

// reorder_canonical sorts each run of non-starters by combining class, which is what
// makes a decomposition canonical rather than merely complete.
//
// The rule from UAX#15 is about every maximal run of non-starters, including one at the
// very start of the string: a leading run sorts as a unit, and only a starter in front
// of it would hold it in place. Within a run the marks sort by class, and the sort is
// stable, so marks that share a class keep the order they arrived in.
fn (n &Normalizer) reorder_canonical(mut cps []rune) {
	mut i := 0
	for i < cps.len {
		if n.props.combining_class_of(cps[i]) == 0 {
			i++
			continue
		}
		// The run starts here and reaches to the next starter, or to the end.
		run_start := i
		for i < cps.len && n.props.combining_class_of(cps[i]) != 0 {
			i++
		}
		// A run of one mark is already in order. Two is the shortest run that can be
		// wrong, so the test is two or more rather than three or more.
		if i - run_start > 1 {
			n.insertion_sort_marks(mut cps[run_start..i])
		}
	}
}

// insertion_sort_marks sorts a run of non-starters by combining class. Insertion
// rather than a general sort because the runs are short, almost always one or two
// marks, and because it is stable without extra work.
fn (n &Normalizer) insertion_sort_marks(mut run []rune) {
	for i in 1 .. run.len {
		c := run[i]
		cc := n.props.combining_class_of(c)
		mut j := i - 1
		for j >= 0 {
			// Strictly greater, never greater or equal: marks that share a class
			// have to keep their input order.
			if n.props.combining_class_of(run[j]) <= cc {
				break
			}
			run[j + 1] = run[j]
			j--
		}
		run[j + 1] = c
	}
}

// compose_canonical composes a canonically decomposed string as far as it can go.
//
// This is the algorithm UAX#15 specifies. It carries the position of the last starter
// and the combining class of the last character it emitted, and tries to compose each
// following character onto the starter.
//
// The rule that decides whether a character is blocked from the starter is the whole
// subtlety: a character is blocked when something between them has a combining class
// greater than or equal to its own, because that intervening mark is what the starter
// would have had to combine with first. A character with class zero is never blocked,
// and neither is anything that follows a class zero directly.
pub fn (n &Normalizer) compose_canonical(cps []rune) []rune {
	if cps.len == 0 {
		return cps
	}
	mut out := []rune{cap: cps.len}
	out << cps[0]
	// starter is the index in out that later characters compose onto.
	mut starter := 0
	// last_class is the combining class of the most recently emitted character. It is
	// only meaningful once a character has failed to compose, because a successful
	// composition leaves the starter in place with class zero.
	mut last_class := n.props.combining_class_of(out[0])
	if last_class != 0 {
		// A string that opens with marks has no starter for them to compose onto. The
		// class is set past any real value so that nothing composes here, and the first
		// class zero character after them becomes the starter.
		last_class = 256
	}

	for cp in cps[1..] {
		cc := n.props.combining_class_of(cp)
		// Unblocked means the starter is still reachable: nothing with a higher or
		// equal class has been emitted since it.
		unblocked := last_class < cc || last_class == 0
		if unblocked {
			composed := n.try_compose(out[starter], cp)
			if composed != 0 {
				// The composite replaces the starter, and a composite always has class
				// zero, so last_class is deliberately left alone.
				out[starter] = composed
				continue
			}
		}
		if cc == 0 {
			starter = out.len
		}
		last_class = cc
		out << cp
	}
	return out
}

// try_compose returns the composite a starter and a following character make, or 0
// when the pair does not compose. Hangul is handled arithmetically, before the table,
// because the table has no entry for it.
fn (n &Normalizer) try_compose(starter rune, second rune) rune {
	composite := compose_hangul(starter, second)
	if composite != 0 {
		return rune(composite)
	}
	return rune(n.find_composition(u32(starter), u32(second)))
}

// compose_hangul returns the syllable a leading and trailing Jamo compose into, or 0.
// UAX#15 section 10.2 defines both the L+V and the LV+T steps.
fn compose_hangul(lead rune, trail rune) u32 {
	l := u32(lead)
	t := u32(trail)
	// L + V gives a syllable with no trailing consonant, which is also the base the
	// second case extends.
	if l >= hangul_l_base && l < hangul_l_base + hangul_l_count {
		if t >= hangul_v_base && t < hangul_v_base + hangul_v_count {
			l_index := l - hangul_l_base
			v_index := t - hangul_v_base
			return hangul_s_base + (l_index * hangul_v_count + v_index) * hangul_t_count
		}
		return 0
	}
	// LV + T completes a syllable that has a leading consonant and a vowel but no
	// trailing one, so its index within the block is a multiple of the T count.
	if l >= hangul_s_base && l < hangul_s_base + hangul_s_count {
		if (l - hangul_s_base) % hangul_t_count == 0 && t > hangul_t_base
			&& t < hangul_t_base + hangul_t_count {
			return l + (t - hangul_t_base)
		}
	}
	return 0
}

// find_composition returns the composite a starter and a following character make, or
// 0. The table is sorted by starter then second, so the starter is bisected and its
// run walked.
fn (n &Normalizer) find_composition(starter u32, second u32) u32 {
	c := n.compositions
	mut lo := 0
	mut hi := c.len
	for lo < hi {
		mid := (lo + hi) >> 1
		if c[mid].starter < starter {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	for i := lo; i < c.len && c[i].starter == starter; i++ {
		if c[i].second == second {
			return c[i].composite
		}
	}
	return 0
}

// split_fields splits a whitespace separated record. Splitting on a space alone leaves
// empty fields wherever the data has a double space or a trailing one, and an empty
// field parses as zero, which is a real codepoint.
fn split_fields(s string) []string {
	mut out := []string{}
	for f in s.split(' ') {
		if f != '' {
			out << f
		}
	}
	return out
}

// parse_decompositions decodes the "cp d1 d2 ..." table. Each line is one slice
// allocation, which is why the table stays a const string rather than a const array
// of structs: this compiler materialises such an array with length zero.
fn parse_decompositions(data string) []Decomposition {
	mut out := []Decomposition{}
	if data.len == 0 {
		return out
	}
	for line in data.split_into_lines() {
		s := line.trim_space()
		if s == '' {
			continue
		}
		fields := split_fields(s)
		if fields.len < 2 {
			continue
		}
		mut to := []u32{cap: fields.len - 1}
		for i in 1 .. fields.len {
			to << hex_value(fields[i])
		}
		out << Decomposition{ cp: hex_value(fields[0]), to: to }
	}
	return out
}

// parse_compositions decodes the "starter second composite" table.
fn parse_compositions(data string) []Composition {
	mut out := []Composition{}
	if data.len == 0 {
		return out
	}
	for line in data.split_into_lines() {
		s := line.trim_space()
		if s == '' {
			continue
		}
		fields := split_fields(s)
		if fields.len < 3 {
			continue
		}
		out << Composition{
			starter:   hex_value(fields[0])
			second:    hex_value(fields[1])
			composite: hex_value(fields[2])
		}
	}
	return out
}

// in_ranges reports whether cp falls in a sorted, non-overlapping range list.
fn in_ranges(ranges []CodeRange, cp u32) bool {
	mut lo := 0
	mut hi := ranges.len
	for lo < hi {
		mid := (lo + hi) >> 1
		if ranges[mid].hi < cp {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo < ranges.len && ranges[lo].lo <= cp && cp <= ranges[lo].hi
}
