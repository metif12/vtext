module vtext

// The weak, neutral and implicit resolution rules of UAX#9 (W1 to N2 and I1, I2),
// applied to one isolating run sequence at a time.
//
// Each function works on a dense array of types for the sequence, with idx giving
// the input index of each element. Working on a dense array keeps the rules from
// having to reason about run boundaries, which is where this kind of code usually
// goes wrong. Characters rule X9 removed keep the sentinel type 254 and are
// skipped: they are not part of the text the rules operate on.

// is_removed reports whether a working type marks a character removed by X9.
fn is_removed(c BidiClass) bool {
	return c == .x9_removed
}

// apply_w_rules implements W1 to W7.
//
// orig holds the classes from before the copy was made, so idx has to be threaded
// through every read of it: the working array is dense and the original is not.
fn apply_w_rules(mut types []BidiClass, orig []BidiClass, idx []int, sos BidiClass) {
	// W1: an NSM takes the type of the previous character, or sos when it is first.
	// When the previous character is an isolate initiator or PDI the NSM becomes
	// ON. A chain of marks therefore all end up with the same type.
	mut prev := sos
	for i in 0 .. types.len {
		if is_removed(types[i]) {
			continue
		}
		if orig[idx[i]] == .nsm {
			types[i] = if i > 0 && is_isolate_or_pdi(orig[idx[i - 1]]) {
				.on
			} else {
				prev
			}
		}
		prev = types[i]
	}

	// W2: an EN becomes AN when the last strong type before it is AL. This runs
	// before W3, so it reads the original AL classes.
	mut last_strong := sos
	for i in 0 .. types.len {
		if is_removed(types[i]) {
			continue
		}
		if orig[idx[i]] == .en && last_strong == .al {
			types[i] = .an
		}
		sc := strong_at(types, i)
		if sc != .class_none {
			last_strong = sc
		}
	}

	// W3: an AL becomes R.
	for i in 0 .. types.len {
		if orig[idx[i]] == .al {
			types[i] = .r
		}
	}

	// W4: a single ES between two ENs becomes EN; a single CS between two numbers
	// of the same kind becomes that kind.
	if types.len >= 3 {
		for i in 1 .. types.len - 1 {
			if is_removed(types[i]) {
				continue
			}
			if types[i] == .es && types[i - 1] == .en && types[i + 1] == .en {
				types[i] = .en
			} else if types[i] == .cs {
				if types[i - 1] == .en && types[i + 1] == .en {
					types[i] = .en
				} else if types[i - 1] == .an && types[i + 1] == .an {
					types[i] = .an
				}
			}
		}
	}

	// W5: a run of ETs adjacent to an EN becomes EN.
	mut w := 0
	for w < types.len {
		if is_removed(types[w]) || types[w] != .et {
			w++
			continue
		}
		mut j := w
		for j < types.len && types[j] == .et {
			j++
		}
		prev_en := w > 0 && types[w - 1] == .en
		next_en := j < types.len && types[j] == .en
		if prev_en || next_en {
			for k in w .. j {
				types[k] = .en
			}
		}
		w = j
	}

	// W6: whatever is left of ET, ES and CS becomes ON.
	for i in 0 .. types.len {
		if types[i] in [.et, .es, .cs] {
			types[i] = .on
		}
	}

	// W7: an EN becomes L when the last strong type before it is L.
	last_strong = sos
	for i in 0 .. types.len {
		if is_removed(types[i]) {
			continue
		}
		if types[i] == .en && last_strong == .l {
			types[i] = .l
		}
		sc := strong_at(types, i)
		if sc != .class_none {
			last_strong = sc
		}
	}
}

// strong_at returns the strong type at a position for the "last strong type" scans
// of W2 and W7, or .class_none when there is none.
//
// Only L, R and AL are strong. A European or Arabic number is not, and it matters
// that the scan skips it: W2 changes an EN into an AN, and treating the new AN as
// the strong type it just came from would lose the AL that asked for the change.
fn strong_at(types []BidiClass, pos int) BidiClass {
	if types[pos] in [.l, .r, .al] {
		return types[pos]
	}
	return .class_none
}

fn is_isolate_or_pdi(c BidiClass) bool {
	return c in [.lri, .rli, .fsi, .pdi]
}

// apply_n0 implements the paired bracket rule. It runs whatever the embedding
// direction is.
//
// Pairs are processed in the logical order of their *opening* brackets, and a pair
// sees the types left behind by the pairs resolved before it, which is what makes
// nested pairs settle correctly. The sequence need not be contiguous, so every scan
// here walks the dense sequence array and never the input as a whole.
//
// The three outcomes, from UAX#9 N0:
//   b   a strong type inside the pair matches the embedding direction, so both
//       brackets take it;
//   c   the only strong types inside are opposite, and the nearest strong type
//       before the opening bracket is also opposite, so that direction is
//       established and both brackets take it;
//   otherwise either there is no strong type inside, in which case N1 and N2 will
//       resolve the brackets on their own, or there is no supporting context, in
//       which case both brackets fall back to the embedding direction.
fn apply_n0(mut types []BidiClass, cps []rune, orig []BidiClass, idx []int, levels []u8,
	sos BidiClass) {
	brackets := bracket_table()
	for pair in find_bracket_pairs(brackets, cps, types, idx) {
		// The embedding direction of a bracket is the parity of its own level.
		embedding := level_direction(levels[idx[pair.open]])

		// A strong type inside the pair that matches the embedding direction wins.
		mut has_matching := false
		mut has_other := false
		for i in pair.open + 1 .. pair.close {
			c := strong_as_r(types[i])
			if c == .class_none {
				continue
			}
			if c == embedding {
				has_matching = true
				break
			}
			has_other = true
		}

		mut value := embedding
		if !has_matching && has_other {
			// The enclosed text is opposite, so the direction only sticks if the
			// text before the opening bracket agrees.
			before := preceding_strong(types, pair.open, sos)
			if before == embedding {
				// N0 c2: no supporting context, so the embedding direction.
				value = embedding
			} else {
				value = before
			}
		} else if !has_matching && !has_other {
			// N0 d: nothing strong inside; leave the brackets to N1 and N2.
			continue
		}

		types[pair.open] = value
		types[pair.close] = value
		// Marks that immediately followed a bracket which changed type change with
		// it, provided they were NSMs before W1 ran.
		propagate_marks(mut types, orig, idx, pair.open, value)
		propagate_marks(mut types, orig, idx, pair.close, value)
	}
}

// preceding_strong returns the nearest strong type before position, or sos when
// there is none. The types are read as they stand, so a bracket that N0 has already
// resolved counts as the strong type it became.
fn preceding_strong(types []BidiClass, position int, sos BidiClass) BidiClass {
	for i := position - 1; i >= 0; i-- {
		c := strong_as_r(types[i])
		if c != .class_none {
			return c
		}
	}
	return sos
}

// BracketPositions is a matched bracket pair, as offsets into a sequence's dense
// type array.
struct BracketPositions {
	open  int
	close int
}

// find_bracket_pairs implements BD16: a stack of exactly 63 elements, and a closing
// bracket pairs with the deepest opener it is the canonical partner of. A closer that
// matches nothing is not popped.
//
// An opener that arrives with the stack full does not just get dropped: BD16 stops
// there and returns an empty list, so a run of more than 63 nested brackets resolves
// no pair at all and N1 and N2 settle every bracket on its own.
//
// BD14 and BD15 decide what a bracket is by its *current* bidirectional type, not
// its original one, so a bracket that X6 gave a direction to - because it sat
// inside an LRO or RLO - is not a bracket any more and takes no part in pairing.
// That is why types is passed alongside the codepoints.
//
// BD16 emits a pair when the closing bracket is seen, but N0 then works through the
// pairs in the logical order of their *opening* brackets, so the list is sorted
// before it is returned.
fn find_bracket_pairs(brackets []BracketPair, cps []rune, types []BidiClass, idx []int) []BracketPositions {
	mut stack := []int{}
	mut out := []BracketPositions{}
	for pos in 0 .. idx.len {
		// BD14 and BD15: only a character still typed ON is a paired bracket.
		if types[pos] != .on {
			continue
		}
		cp := u32(cps[idx[pos]])
		b := brackets.find(cp) or { continue }
		if b.kind == bracket_open {
			if stack.len >= 63 {
				return []BracketPositions{}
			}
			stack << pos
			continue
		}
		mut s := stack.len - 1
		for s >= 0 {
			ob := brackets.find(u32(cps[idx[stack[s]]])) or {
				s--
				continue
			}
			if brackets.same_bracket(ob, cp) {
				// A temporary: `v fmt` mangles a struct literal whose field name
				// matches a local in the same expression.
				open_pos := stack[s]
				stack = stack[..s]
				found := BracketPositions{ open: open_pos, close: pos }
				out << found
				break
			}
			s--
		}
	}
	out.sort_with_compare(fn (a &BracketPositions, b &BracketPositions) int {
		return a.open - b.open
	})
	return out
}

// strong_as_r returns L or R, or .class_none when the type is not strong. Numbers
// count as R, which is what N0 specifies.
fn strong_as_r(c BidiClass) BidiClass {
	match c {
		.l, .r {
			return c
		}
		.en, .an {
			return .r
		}
		else {
			return .class_none
		}
	}
}

// propagate_marks gives the marks that immediately follow position the new type,
// which is what N0 requires of NSMs that trailed a changed bracket.
fn propagate_marks(mut types []BidiClass, orig []BidiClass, idx []int, position int, value BidiClass) {
	mut i := position + 1
	for i < types.len {
		if orig[idx[i]] != .nsm {
			break
		}
		types[i] = value
		i++
	}
}

// apply_n_rules implements N1 and N2.
//
// N1 leaves a neutral run alone when the strong text on both sides agrees. N2
// otherwise gives it the embedding direction, which is the parity of the run's own
// level, not the direction of sos: a sequence can start at a level lower than the
// level of the character before it.
//
// The isolate formatting characters are neutrals for N1 and N2. X5a to X5c and X6a
// leave them with their own class unless an override rewrites it, so the current
// type is enough here: a bracket N0 already resolved to L or R is strong by now and
// is not dragged around again.
fn apply_n_rules(mut types []BidiClass, sos BidiClass, eos BidiClass, levels []u8, idx []int) {
	mut i := 0
	for i < types.len {
		if is_removed(types[i]) || !types[i].is_neutral_or_isolate() {
			i++
			continue
		}
		mut j := i
		for j < types.len && !is_removed(types[j]) && types[j].is_neutral_or_isolate() {
			j++
		}
		before := if i == 0 { sos } else { strong_as_r(types[i - 1]) }
		after := if j >= types.len { eos } else { strong_as_r(types[j]) }
		value := if before == after && before != .class_none {
			before
		} else {
			level_direction(levels[idx[i]])
		}
		for k in i .. j {
			types[k] = value
		}
		i = j
	}
}

// apply_i_rules implements I1 and I2, turning resolved types into levels.
//
// explicit holds the levels X1 to X8 assigned, which is what the parity is read
// from; levels is the output and receives the resolved level.
fn apply_i_rules(types []BidiClass, explicit []u8, mut levels []u8, idx []int) {
	for pos in 0 .. idx.len {
		c := types[pos]
		if is_removed(c) {
			continue
		}
		k := idx[pos]
		level := explicit[k]
		if level % 2 == 0 {
			// I1
			if c == .r {
				levels[k] = level + 1
			} else if c in [.an, .en] {
				levels[k] = level + 2
			}
		} else {
			// I2
			if c in [.l, .en, .an] {
				levels[k] = level + 1
			}
		}
	}
}

// apply_l1 implements rule L1: separators, and any run of whitespace or isolate
// formatting characters before a separator or at the end of the line, take the
// paragraph level.
fn apply_l1(orig []BidiClass, mut levels []u8, para_level u8) {
	for j in 0 .. orig.len {
		if orig[j] == .s || orig[j] == .b {
			levels[j] = para_level
			mut k := j - 1
			for k >= 0 && orig[k] in [.ws, .lri, .rli, .fsi, .pdi] {
				levels[k] = para_level
				k--
			}
		}
	}
	mut k := orig.len - 1
	for k >= 0 && orig[k] in [.ws, .lri, .rli, .fsi, .pdi] {
		levels[k] = para_level
		k--
	}
}

// reorder_by_levels implements L2: from the highest level down to the lowest odd
// level, reverse every maximal run of characters at or above that level.
//
// only_visible restricts the reordering to the characters rule X9 left in the
// text. The removed formatting controls are not part of the line, so they must not
// break up a run or take part in one.
//
// lowest_odd_level returns the level L2 must stop at, which is the lowest odd
// level present, or 1 when the text has no odd level at all - a line of entirely
// even levels still gets one reversal at the top level and one at level 1, which
// cancel out and leave the line unreversed.
fn reorder_by_levels(levels []u8, visible []bool) []int {
	mut order := []int{}
	for i in 0 .. levels.len {
		if visible[i] {
			order << i
		}
	}
	n := order.len
	mut highest := u8(0)
	mut lowest_odd := u8(1)
	for i in 0 .. levels.len {
		if !visible[i] {
			continue
		}
		l := levels[i]
		if l > highest {
			highest = l
		}
		if l % 2 == 1 && l < lowest_odd {
			lowest_odd = l
		}
	}
	mut level := highest
	for level >= lowest_odd && level > 0 {
		mut i := 0
		for i < n {
			if levels[order[i]] < level {
				i++
				continue
			}
			mut j := i
			for j < n && levels[order[j]] >= level {
				j++
			}
			reverse_slice(mut order, i, j)
			i = j
		}
		if level == 0 {
			break
		}
		level--
	}
	return order
}

// reverse_slice reverses order[from..to) in place.
fn reverse_slice(mut order []int, from int, to int) {
	mut i := from
	mut j := to - 1
	for i < j {
		order[i], order[j] = order[j], order[i]
		i++
		j--
	}
}
