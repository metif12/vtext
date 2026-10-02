module vtext

// Exposing the pipeline's stages, one at a time, for tools/shapetrace.
//
// A trace is worth having only if it can stop between stages. Instrumenting layout_paragraph to print as
// it goes would produce a log of one run on one build, which is what the last three debugging sessions
// each hand-rolled and threw away. These are the same functions the pipeline calls, reached from outside.
//
// Nothing here changes what layout_paragraph does. Each function is a thin call into the stage the real
// pipeline already uses, so a trace cannot disagree with a line: there is one implementation of every
// stage and the tool is calling it.

// codepoint_name is a codepoint's Unicode name, or its hex value when the UCD has no name for it.
//
// The fallback is the point of the function rather than an afterthought. The codepoints a shaping trace
// prints are mostly presentation forms, U+FExx and U+FB50 onward, and a trace reading "U+FEA7" tells a
// reader nothing they can act on. A trace reading "ARABIC LETTER KHAH INITIAL FORM" is a trace that
// settles a question.
//
// Control characters and unassigned codepoints have names in the UCD too, and they are printed rather than
// hidden: a trace that hides the character it is explaining cannot be used on a string that contains one.
pub fn codepoint_name(cp rune) string {
	name := codepoint_name_or(cp, '')
	if name == '' {
		return 'U+${u32(cp):04X}'
	}
	return name
}

// codepoint_name_or is codepoint_name with the caller's fallback for a codepoint the UCD has no name for.
pub fn codepoint_name_or(cp rune, fallback string) string {
	name := name_of_codepoint(cp)
	return if name == '' { fallback } else { name }
}

// name_of_codepoint is the lookup into the generated table, or an empty string when the codepoint is not
// in it.
//
// The table is front coded and delta coded, so a lookup is a binary search followed by a prefix rebuild,
// and both halves have to be right for the answer to be right. A wrong sum in either gives a plausible
// string rather than an obvious failure, which is why the deltas are from the previous entry and not from
// zero: a running total that skipped an add would shift every later entry, while a delta that skipped an
// entry cannot be recomputed.
//
// The rebuild walks backwards one entry at a time, accumulating the name, rather than recursing. A
// recursive rebuild would be shorter and would also be bounded by a table fact nobody checked: the private
// use area has a zero-length suffix on every entry, so a run of identical names runs from the first private
// use codepoint to the end of the table, which is tens of thousands of frames deep.
//
// It is not fast, and it does not need to be. A trace prints a few dozen codepoints and a lookup walks at
// most the length of the longest run of names sharing a prefix. The table exists to make a trace readable,
// not to make it fast, and the shape that would be fast is a tree this file does not carry.
//
// The empty string rather than a placeholder is deliberate. A caller that wants a fallback needs to be able
// to tell "the UCD has no name for this" from "the name happens to be empty", and it cannot: there is no
// codepoint whose name is the empty string, so the two are the same case and returning the empty string is
// the honest answer for both. The callers above each substitute their own fallback.
pub fn name_of_codepoint(cp rune) string {
	idx := codepoint_name_index(cp)
	if idx < 0 {
		return ''
	}
	mut name := []u8{}
	// Front coding stores each entry as the bytes that follow the prefix it shares with the entry *before* it,
	// so entry i is `name_of(i-1)[0..prefix[i]]` followed by entry i's own bytes. That is a dependency on the
	// earlier entry, which means the walk goes forward from 0 to idx and the accumulated name after the last
	// pass is the answer.
	//
	// The walk does not go backwards, and it did for a while. It produced names that were one entry out: asking
	// for U+0041 returned the name of U+003A, and asking for a lowercase letter returned the uppercase one
	// above it. Nothing said so, because a name one entry away is still a real name and reads as a plausible
	// answer for a table read in the wrong direction. This is the third shape of the same bug on this table.
	mut i := 0
	for i <= idx {
		built := rebuild_one(i, name)
		if built.len == 0 && i > 0 {
			// A rebuild that came out empty for an entry after the first is a corrupt table, not a name of
			// length zero. Returning the partial accumulation would hand back the previous entry's name, which
			// reads as a fact and is not this codepoint's.
			return ''
		}
		name = built.clone()
		i++
	}
	return name.bytestr()
}

// rebuild_one is entry i's name, given the name of entry i-1.
//
// The shared prefix comes off the name we already have and this entry's suffix goes on the end. It is built
// into a new buffer rather than in place, because the bytes being read are the bytes being written.
//
// The empty result doubles as the failure answer and as a legitimate empty name, which the caller cannot tell
// apart. That is acceptable because a name is never empty in the UCD and the failure means the table is
// corrupt, which is the case the invariant test in ucd_names_test.v is there to catch.
fn rebuild_one(i int, prev []u8) []u8 {
	shared := int(codepoint_name_prefix[i])
	if shared > prev.len {
		// The table is generated by one program and read by another, so a corrupt prefix length is possible
		// in principle. Returning nothing is the answer; returning the suffix alone would be a name that is
		// not in the UCD, which is worse than no name.
		return []u8{}
	}
	// Entry i's suffix runs from offsets[i] to offsets[i+1], and the deltas give both: offsets[i] is the sum of
	// the deltas up to i and offsets[i+1] is that plus the single next delta. The end is therefore one add
	// on the start and not a second running sum, and the delta is read at i+1 rather than at i because
	// deltas[i] is the step *into* entry i and is already inside the start.
	//
	// Every earlier version of this was wrong in a way that produced a plausible string: seeding the end
	// with the start and summing the whole run again counted the first part twice, and reading the delta at
	// i rather than i+1 counted it once too few or once too many depending on the entry. Both lengthened
	// every suffix by an offset belonging to some other entry, which is how "EXCLAMATION MARKQUOTA" and
	// names one entry out of place both happened.
	deltas := codepoint_name_offsets_delta
	mut start := 0
	mut j := 0
	for j <= i {
		start += int(deltas[j])
		j++
	}
	end := start + int(deltas[i + 1])
	if start > end || end > codepoint_names_data.len {
		return []u8{}
	}
	mut out := []u8{cap: shared + int(end - start)}
	for p in 0 .. shared {
		out << prev[p]
	}
	for k in start .. end {
		out << codepoint_names_data[k]
	}
	return out
}

// absolute_offset is where entry idx's suffix starts in the blob, by summing the deltas up to it.
//
// The sum is from the start of the table rather than from a remembered position because a lookup calls it
// once per entry walked backwards and a running position would have to be wound back. It is O(idx) per call
// and O(idx^2) per lookup, which for the worst case in this table is a few million additions: slow enough to
// be worth noticing and fast enough not to matter for a report that prints forty lines.
// absolute_offset is where entry idx's suffix starts in the blob, by summing the deltas up to it.
//
// The `deltas.len` bound is not here on purpose. With it, this function returned the sum of one element
// fewer than the caller asked for, every time and without a warning, so `absolute_offset(2)` gave 5 where
// the caller could read `offsets_delta[0] + offsets_delta[1]` as 5 and expected the same. The caller read the
// array directly and got the right elements, so the fault is the bound rather than the data, and dropping it
// makes the two agree.
//
// A wrong answer here is invisible at every layer above: the rebuild reads a suffix from the wrong offset and
// still produces a plausible string, or reads an empty range and produces nothing. The whole table answering
// "no name" is what it looks like from the outside, which is how it was found.
// absolute_offset is where entry idx's suffix starts in the blob, by summing the deltas up to it.
//
// The loop condition is `k <= idx` and the first delta is the first entry's own start rather than a step
// from an entry before it. Both matter, and getting either wrong produces a sum one element short: with
// `k < idx` the loop adds one delta fewer than the caller asked for, so `absolute_offset(1)` returned 0
// where the table holds 5, and the lookup that used it answered "no name" for every codepoint in the font.
//
// That failure is worth recording because nothing said so. No error, no warning, a generated file that reads
// correctly when inspected, and a table that reports every codepoint as unnamed. It is the shape of bug this
// project has hit three times now, and the reason every table here is checked against a second reader.
pub fn absolute_offset(idx int) int {
	mut total := 0
	deltas := codepoint_name_offsets_delta
	mut k := 0
	for k <= idx {
		total += int(deltas[k])
		k++
	}
	return total
}

// probe_walk is a temporary diagnostic for the front-coded rebuild and the search.
pub fn probe_walk(cp rune) string {
	idx := codepoint_name_index(cp)
	return 'idx=${idx}'
}

// codepoint_name_index is the binary search for a codepoint, or -1 when the table has no entry for it.
//
// The search walks the absolute values, which means summing the deltas up to the middle on every step. That
// is the cost of the delta form and it is paid once per lookup rather than once per entry, so it does not
// change the shape of the answer: an absolute table would make the generated file about twice as large, and
// the file is what gets committed.
pub fn codepoint_name_index(cp rune) int {
	target := u32(cp)
	deltas := codepoint_name_cps_delta
	if deltas.len == 0 {
		return -1
	}
	// The deltas are summed from zero to the middle on every step rather than carried down from the lower
	// bound. The carried version is the faster one and it was the one in use first, and it returned -1 for
	// every codepoint past the first few hundred: the value it carried was the one it had at the *previous*
	// middle rather than at the current lower bound, so every step after the first compared against a
	// codepoint that was somewhere else in the table.
	//
	// That is the third silent wrong answer on this table, and the shape is worth naming: an incremental
	// optimisation that is only correct if the increment is applied at exactly one place, and where it is not
	// applied the result is a plausible index into the wrong place. Summing from zero costs O(n) per step and
	// is hard to get wrong, and a lookup is a report printing forty lines, not a hot path.
	mut lo := 0
	mut hi := deltas.len - 1
	for lo <= hi {
		mid := (lo + hi) / 2
		mut at_mid := 0
		for i in 0 .. mid + 1 {
			at_mid += int(deltas[i])
		}
		if at_mid == target {
			return mid
		} else if at_mid < target {
			lo = mid + 1
		} else {
			hi = mid - 1
		}
	}
	return -1
}

// normalize_nfd is the canonical decomposition of UAX#15, which is what the pipeline runs before shaping.
//
// This is the decomposition rather than a normalized string, because the indices are what a trace needs: a
// mark written after another mark is reordered ahead of it, and a caller reading the output needs to see
// which input character each resulting codepoint came from.
pub fn (ctx &Context) normalize_nfd(cps []rune) []rune {
	decomposed, _ := ctx.normalizer.nfd_mapped(cps)
	return decomposed
}

// resolve_bidi is the paragraph-level resolution of UAX#9.
//
// base_dir is what P2 and P3 take when the text does not imply a direction. Direction.auto is the honest
// answer for a trace, because it is what a caller who did not know would have passed, and a bug that only
// appears under one of the forced directions would otherwise be invisible here.
pub fn resolve_bidi(ctx &Context, cps []rune, base_dir Direction) BidiResult {
	return resolve_paragraph(ctx.properties, cps, base_dir)
}

// visual_string renders the visual order of the text as it would be drawn left to right, which is the one
// form a person can compare against the picture.
//
// BidiResult holds the order as indices, because that is what a renderer needs and an index cannot be
// misread as a character. This turns it into characters for a report, and it is lossy on purpose: a
// codepoint that appears twice cannot be told apart in the output, so a trace about repeated characters
// needs the index list and not this.
// The characters go in as bytes taken from each rune rather than as a []rune converted at the end. An
// Arabic or Devanagari character is two or three bytes and truncating each rune to one byte produces a
// string that looks like the visual order in ASCII and is not it in any script. `[]rune.str()` is not
// used either: on this V it renders the array as a bracketed list of the runes rather than as text, so
// both of the obvious answers are wrong and the bytes are assembled here.
pub fn (b &BidiResult) visual_string(cps []rune) string {
	mut bytes := []u8{cap: b.visual_order.len * 4}
	for i in b.visual_order {
		if i >= 0 && i < cps.len {
			cp := cps[i]
			if cp < 0x80 {
				bytes << u8(cp)
			} else if cp < 0x800 {
				bytes << u8(0xC0 | (cp >> 6))
				bytes << u8(0x80 | (cp & 0x3F))
			} else if cp < 0x10000 {
				bytes << u8(0xE0 | (cp >> 12))
				bytes << u8(0x80 | ((cp >> 6) & 0x3F))
				bytes << u8(0x80 | (cp & 0x3F))
			} else {
				bytes << u8(0xF0 | (cp >> 18))
				bytes << u8(0x80 | ((cp >> 12) & 0x3F))
				bytes << u8(0x80 | ((cp >> 6) & 0x3F))
				bytes << u8(0x80 | (cp & 0x3F))
			}
		}
	}
	return bytes.bytestr()
}

// shape_for_trace runs the joining pass over a run in logical order, which is the stage between bidi and
// the font.
//
// The run it returns is the same one layout_paragraph gets, not a copy of it computed differently: a
// trace that reshapes to describe the pipeline would be describing itself.
pub fn (ctx &Context) shape_for_trace(cps []rune) ShapedRun {
	return ctx.shaper.shape_arabic(ctx.properties, cps)
}

// joining_type_name is a codepoint's joining type as a word, for a trace that prints the property.
//
// The codepoints here are the ones the decision hinges on, and a decision phrased in numbers has to be
// re-read as numbers. Right-joining, dual-joining, non-joining and transparent are four different answers
// to "can this letter touch its neighbour", and only the fourth is invisible.
pub fn joining_type_name(ctx &Context, cp rune) string {
	return ctx.properties.joining_type_name(cp)
}
