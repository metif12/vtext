module vtext

// Direction is the resolved direction of a paragraph.
pub enum Direction {
	ltr  = 0
	rtl  = 1
	auto = 2
}

// bidi_max_depth is the UAX#9 explicit embedding depth limit (BD2).
const bidi_max_depth = 125

// BidiResult is the outcome of resolving one paragraph.
pub struct BidiResult {
pub mut:
	// levels holds the resolved embedding level of every character in the input,
	// after rule L1.
	levels []u8
	// visible reports whether a character is part of the text after rule X9. The
	// formatting controls that X9 removes are false; everything else is true.
	visible []bool
	// visual_order maps a visual index to a logical index into the input, which is
	// the result of rule L2. visual_order[0] is the leftmost character. It
	// includes the X9-removed characters, so a visual index is a direct index
	// into levels; use visible to skip them when drawing.
	visual_order []int
	// paragraph_level is the level from rules P2 and P3, or the level the caller
	// forced.
	paragraph_level u8
	// isolating_sequences counts the isolating run sequences rule X10 found. It
	// is a cheap signal when comparing against a reference implementation.
	isolating_sequences int
	// sequences holds the isolating run sequences themselves, each one the list of
	// input indices it covers in text order. Shaping runs on one sequence at a
	// time, because the rules that resolved a sequence had to treat it as a unit.
	// X9-removed characters are absent, so an index here is always a character
	// that will be drawn.
	sequences [][]int
}

// DirEntry is one entry of the directional status stack built by rules X1 to X8.
struct DirEntry {
	level    u8
	override BidiClass
	// isolate marks an isolate initiator, so X6a knows when to stop popping.
	isolate bool
}

// no_override is the override value meaning "the character's own class".
const no_override = BidiClass.class_none

// removed is the type given to characters that rule X9 removes from the text.
const removed = BidiClass.x9_removed

// resolve_paragraph runs the UAX#9 algorithm over cps and returns the resolved
// levels plus the visual reordering.
//
// base_dir drives rules P2 and P3: .ltr and .rtl force the paragraph level, .auto
// takes it from the first strong character.
pub fn resolve_paragraph(p &Properties, cps []rune, base_dir Direction) BidiResult {
	mut result := BidiResult{
		levels:       []u8{len: cps.len, init: 0}
		visible:      []bool{len: cps.len, init: true}
		visual_order: []int{len: cps.len, init: 0}
	}
	if cps.len == 0 {
		return result
	}

	// Original types, kept because rules W1 to N2 work on a mutable copy and N0
	// consults the original classes.
	mut orig := []BidiClass{len: cps.len, init: .l}
	for i, cp in cps {
		orig[i] = p.bidi_class_of(cp)
	}

	// P2 and P3.
	mut para_level := u8(0)
	match base_dir {
		.ltr {
			para_level = 0
		}
		.rtl {
			para_level = 1
		}
		.auto {
			para_level = u8(if first_strong_direction(p, cps, 0, cps.len) == .rtl {
				1
			} else {
				0
			})
		}
	}
	result.paragraph_level = para_level

	// X1 to X9.
	mut types := explicit_levels(p, cps, orig, para_level, mut result.levels)

	// Rules I1 and I2 overwrite levels in place, so sos, eos and the embedding
	// direction of N0 and N2 have to read the levels as X1 to X8 left them. Keeping a
	// copy is what stops one sequence's implicit levels from changing the next
	// sequence's boundary.
	explicit := result.levels.clone()

	// X10, then the weak, neutral and implicit rules per isolating run sequence.
	sequences := isolating_run_sequences(types, orig, explicit)
	result.isolating_sequences = sequences.len
	result.sequences = sequences
	for seq in sequences {
		work := flatten_sequence(seq)
		sos := boundary_type(types, explicit, para_level, work[0], true)
		eos := boundary_type(types, explicit, para_level, work[work.len - 1], false)
		mut seq_types := slice_types(types, work)
		apply_w_rules(mut seq_types, orig, work, sos)
		apply_n0(mut seq_types, cps, orig, work, explicit, sos)
		apply_n_rules(mut seq_types, sos, eos, explicit, work)
		apply_i_rules(seq_types, explicit, mut result.levels, work)
		write_back_types(mut types, work, seq_types)
	}

	// Which characters survived X9. This is read off the working types rather
	// than tracked separately, so the two cannot fall out of step.
	for i in 0 .. types.len {
		result.visible[i] = types[i] != .x9_removed
	}

	// L1.
	apply_l1(orig, mut result.levels, para_level)

	// L2.
	result.visual_order = reorder_by_levels(result.levels, result.visible)
	return result
}

// first_strong_direction implements P2 and P3 over cps[from..to]: the direction of
// the first strong character, skipping over isolate runs so a strong character
// inside an isolate cannot decide the paragraph.
fn first_strong_direction(p &Properties, cps []rune, from int, to int) Direction {
	mut i := from
	for i < to {
		cls := p.bidi_class_of(cps[i])
		match cls {
			.l {
				return .ltr
			}
			.r, .al {
				return .rtl
			}
			.lri, .rli, .fsi {
				i = matching_pdi(p, cps, i + 1, to)
			}
			else {}
		}
		i++
	}
	return .ltr
}

// matching_pdi returns the index just past the PDI matching an isolate initiator
// whose contents start at start, or `to` when there is none.
fn matching_pdi(p &Properties, cps []rune, start int, to int) int {
	mut depth := 1
	mut i := start
	for i < to {
		cls := p.bidi_class_of(cps[i])
		if cls in [.lri, .rli, .fsi] {
			depth++
		} else if cls == .pdi {
			depth--
			if depth == 0 {
				return i + 1
			}
		}
		i++
	}
	return to
}

// explicit_levels implements X1 to X9, filling levels and returning the working
// types in which the X9-removed characters are marked `removed`.
fn explicit_levels(p &Properties, cps []rune, orig []BidiClass, para_level u8, mut levels []u8) []BidiClass {
	mut types := orig.clone()
	mut stack := [DirEntry{ level: para_level, override: no_override, isolate: false }]
	mut overflow_embedding := 0
	mut overflow_isolate := 0
	mut valid_isolate := 0

	for i in 0 .. cps.len {
		cls := orig[i]
		match cls {
			.rle, .lre, .rlo, .lro {
				// X2 to X5: the new level is the least level above the current one
				// with the parity the formatting character requires.
				mut new_level := u8(0)
				mut ov := no_override
				if cls in [.rle, .rlo] {
					new_level = least_greater(stack[stack.len - 1].level, true)
				} else {
					new_level = least_greater(stack[stack.len - 1].level, false)
				}
				if cls == .rlo {
					ov = .r
				} else if cls == .lro {
					ov = .l
				}
				levels[i] = stack[stack.len - 1].level
				types[i] = removed
				stack, overflow_embedding = push_embedding(stack, new_level, ov,
					overflow_embedding, overflow_isolate)
			}
			.rli, .lri, .fsi {
				// X5a to X5c. An FSI takes its direction from the first strong
				// character between it and its matching PDI.
				mut d := BidiClass.r
				if cls == .lri {
					d = .l
				} else if cls == .fsi {
					j := matching_pdi(p, cps, i + 1, cps.len)
					if first_strong_direction(p, cps, i + 1, j) == .ltr {
						d = .l
					}
				}
				// The initiator's own level is that of the scope it opens. An override
				// in force replaces its type, but with a neutral override it keeps the
				// isolate class, which is what makes it a neutral for N1 and N2.
				ov := stack[stack.len - 1].override
				types[i] = if ov == no_override { cls } else { ov }
				new_level := least_greater(stack[stack.len - 1].level, d == .r)
				levels[i] = stack[stack.len - 1].level
				if new_level <= bidi_max_depth && overflow_isolate == 0
					&& overflow_embedding == 0 && stack.len < 125 {
					stack << DirEntry{ level: new_level, override: no_override, isolate: true }
					valid_isolate++
				} else {
					overflow_isolate++
				}
			}
			.pdi {
				// X6a. In every case the PDI takes the level of the scope left after
				// the pops, and an override in force replaces its type.
				if overflow_isolate > 0 {
					overflow_isolate--
				} else if valid_isolate > 0 {
					overflow_embedding = 0
					stack = pop_to_isolate(stack)
					valid_isolate--
				}
				cur := stack[stack.len - 1]
				levels[i] = cur.level
				types[i] = if cur.override == no_override { .pdi } else { cur.override }
			}
			.pdf {
				// X7: pop the last embedding unless it is an isolate.
				levels[i] = stack[stack.len - 1].level
				types[i] = removed
				if overflow_isolate > 0 {
					// nothing to pop
				} else if overflow_embedding > 0 {
					overflow_embedding--
				} else if stack.len > 1 && !stack[stack.len - 1].isolate {
					stack = stack[..stack.len - 1]
				}
			}
			.b {
				// X8: a paragraph separator resets the stack and the counters.
				levels[i] = para_level
				types[i] = removed
				stack = [DirEntry{ level: para_level, override: no_override, isolate: false }]
				overflow_embedding = 0
				overflow_isolate = 0
				valid_isolate = 0
			}
			.bn {
				// X9.
				levels[i] = stack[stack.len - 1].level
				types[i] = removed
			}
			else {
				// X6: the override status replaces the character's own class.
				levels[i] = stack[stack.len - 1].level
				ov := stack[stack.len - 1].override
				types[i] = if ov == no_override { cls } else { ov }
			}
		}
	}
	return types
}

// push_embedding implements the common overflow handling of X2 to X5. It returns
// the updated stack and overflow counter, because V does not allow a mutable
// scalar parameter.
fn push_embedding(stack []DirEntry, new_level u8, ov BidiClass, overflow_embedding int,
	overflow_isolate int) ([]DirEntry, int) {
	if new_level <= bidi_max_depth && overflow_isolate == 0 && overflow_embedding == 0 {
		if stack.len < 125 {
			mut next := stack.clone()
			entry := DirEntry{ level: new_level, override: ov, isolate: false }
			next << entry
			return next, overflow_embedding
		}
	}
	return stack, overflow_embedding + 1
}

// pop_to_isolate removes entries above the last isolate initiator and the
// initiator itself.
fn pop_to_isolate(stack []DirEntry) []DirEntry {
	mut n := stack.len - 1
	for n >= 1 {
		if stack[n].isolate {
			break
		}
		n--
	}
	return stack[..n]
}

// least_greater returns the smallest level strictly above current with the
// requested parity.
fn least_greater(current u8, odd bool) u8 {
	mut next := current + 1
	if (next % 2 == 1) != odd {
		next++
	}
	return next
}

// level_direction maps an even level to L and an odd level to R.
fn level_direction(level u8) BidiClass {
	return if level % 2 == 1 { .r } else { .l }
}

// isolating_run_sequences implements X10. Each sequence is the flattened list of
// input indices it covers, in text order.
fn isolating_run_sequences(types []BidiClass, orig []BidiClass, levels []u8) [][]int {
	mut runs := build_runs(types, levels)
	if runs.len == 0 {
		return [][]int{}
	}

	// An isolate initiator's matching PDI starts a LevelRun, so the initiator and its
	// PDI can be linked. A run holds only surviving characters, so an initiator is
	// the run's last element and a PDI its first.
	mut run_at := map[int]int{}
	for r in 0 .. runs.len {
		run_at[runs[r][0]] = r
	}
	mut link := map[int]int{} // LevelRun index -> LevelRun index of the matching PDI LevelRun
	for r in 0 .. runs.len {
		first := runs[r][0]
		last := runs[r][runs[r].len - 1]
		if orig[last] in [.lri, .rli, .fsi] {
			pdi := find_matching_pdi(types, last, types.len)
			if pdi < types.len {
				if target := run_at[pdi] {
					link[r] = target
				}
			}
		}
		_ = first
	}

	// A sequence begins at a LevelRun whose first character is not an unmatched PDI.
	mut has_matching_initiator := map[int]bool{}
	for r in 0 .. runs.len {
		if r in link {
			has_matching_initiator[link[r]] = true
		}
	}
	mut used := []bool{len: runs.len, init: false}
	mut out := [][]int{}
	for r in 0 .. runs.len {
		if used[r] {
			continue
		}
		if orig[runs[r][0]] == .pdi && !has_matching_initiator[r] {
			continue
		}
		mut seq := []int{}
		mut cur := r
		for cur >= 0 && cur < runs.len && !used[cur] {
			used[cur] = true
			seq << runs[cur]
			cur = link[cur] or { -1 }
		}
		out << seq
	}
	return out
}

// build_runs splits the surviving text into maximal same-level spans.
//
// Characters X9 removed are transparent: they do not start a run, do not end one,
// and do not break one. A run is therefore a maximal span of *surviving*
// characters that all carry the same level, even when removed characters sit
// between them. The list itself is the indices, because a rule that walks a
// sequence must never see a removed character.
fn build_runs(types []BidiClass, levels []u8) [][]int {
	mut runs := [][]int{}
	mut cur := []int{}
	mut cur_level := u8(0)
	mut have := false
	for i in 0 .. levels.len {
		if types[i] == .x9_removed {
			continue
		}
		if have && levels[i] != cur_level {
			runs << cur
			cur = []
			have = false
		}
		cur << i
		cur_level = levels[i]
		have = true
	}
	if have {
		runs << cur
	}
	return runs
}

// find_matching_pdi returns the index of the PDI matching the isolate initiator at
// start, or the text length when there is none.
fn find_matching_pdi(types []BidiClass, start int, limit int) int {
	mut depth := 1
	mut i := start + 1
	for i < limit {
		c := types[i]
		if c == .x9_removed {
			i++
			continue
		}
		if c in [.lri, .rli, .fsi] {
			depth++
		} else if c == .pdi {
			depth--
			if depth == 0 {
				return i
			}
		}
		i++
	}
	return limit
}

// flatten_sequence returns the indices of a sequence in text order.
fn flatten_sequence(seq []int) []int {
	return seq.clone()
}

// slice_types copies the working types of a sequence into a dense array.
fn slice_types(types []BidiClass, idx []int) []BidiClass {
	mut out := []BidiClass{len: idx.len}
	for i, k in idx {
		out[i] = types[k]
	}
	return out
}

// write_back_types copies a sequence's resolved types back into the full array.
fn write_back_types(mut types []BidiClass, idx []int, values []BidiClass) {
	for i, k in idx {
		types[k] = values[i]
	}
}

// boundary_type computes sos or eos for a sequence (X10). at_start selects which.
//
// The character on the other side of the boundary is the nearest surviving one: a
// character X9 removed is not part of the text, so the search steps over it.
fn boundary_type(types []BidiClass, levels []u8, para_level u8, at_index int, at_start bool) BidiClass {
	seq_level := levels[at_index]
	mut other := para_level
	if at_start {
		mut prev := at_index - 1
		for prev >= 0 && types[prev] == .x9_removed {
			prev--
		}
		if prev >= 0 {
			other = levels[prev]
		}
	} else {
		mut next := at_index + 1
		for next < levels.len && types[next] == .x9_removed {
			next++
		}
		if next < levels.len {
			other = levels[next]
		}
	}
	return level_direction(imax_u8(seq_level, other))
}

fn imax_u8(a u8, b u8) u8 {
	return if a > b { a } else { b }
}
