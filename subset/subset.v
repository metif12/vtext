module subset

// subset builds a smaller font holding only the glyphs a given text needs.
//
// This part most affects what the rest of the library can be used for, and it is the one
// that depends on the engine being right: a subsetter that keeps a glyph the shaping
// pipeline needed and drops one it did not is worse than no subsetter at all.
//
// So the glyph set is not a cmap walk. A character's own mapping is not the glyph the
// pipeline draws. An Arabic letter is drawn as the joining form GSUB substitutes for it, a
// pair of letters may become one ligature, and a mark may compose into a glyph of its
// own — none of which looking up characters one at a time can see. The set starts from
// what layout_paragraph produces for this text, which is the same run the library would
// draw, and is then closed over the references those glyphs make to others.
//
// What it closes over, and why each is a real reference rather than a guess:
//
//	composites   a composite glyph's outline is a list of other glyphs with placement
//	             values, not data of its own. Dropping a component leaves the composite
//	             with a hole in it, so the outline is wrong rather than absent.
//	ligatures    a ligature glyph stands for the letters it is made of, and a subset
//	             that drops them carries a rule it can no longer fire.
//
// The library call is subset_font: a seed of glyph ids in, a rebuilt font out.
// The tool in tools/subset.v shapes the text for the seed, reports what was kept, and
// verifies the result shapes and rasterizes the same: the font it just wrote is loaded
// back, the same string is shaped through it, and every kept glyph is rasterized beside
// its original. A subset that shapes differently is an error, not a small success.
//
// The output is a plain font. A collection is subset to its first member, which is the
// only one the library reads, and the file loses the collection header.
//
// It rebuilds glyf and loca, and a charstring is a different language the library
// exposes no reader for: a CFF font has no outlines this can rebuild, so the tool
// refuses one before calling in and build_font errors on a table set with no glyf.

import vtext.shape

// ---------------------------------------------------------------- bytes

// The font is a big-endian file and everything is read through these two. They answer
// zero outside the file rather than failing, because a table directory is a document
// about bytes that may not all be there, and a reader that stops at the first short table
// stops on fonts that draw perfectly well.
fn be16(d []u8, at int) int {
	if at < 0 || at + 2 > d.len {
		return 0
	}
	return int(d[at]) * 256 + int(d[at + 1])
}

// be32 reads a big-endian word as a signed 64-bit value.
//
// Not an `int`: a word with its top bit set is larger than a signed 32-bit int, and a
// checksum is the sum of those words. `int` happens to be 64 bits on the machines this is
// built on, which is exactly the kind of thing that makes a 64-bit return look redundant
// until the code is built somewhere it is not.
fn be32(d []u8, at int) i64 {
	if at < 0 || at + 4 > d.len {
		return 0
	}
	return i64(d[at]) * 16777216 + i64(d[at + 1]) * 65536 + i64(d[at + 2]) * 256 + i64(d[at + 3])
}

fn align_up(n int, to int) int {
	if to <= 1 {
		return n
	}
	mut v := n
	for v % to != 0 {
		v++
	}
	return v
}

fn imin(a int, b int) int {
	if a < b {
		return a
	}
	return b
}

fn put32(mut b []u8, v int) {
	b << u8((v >> 24) & 0xff)
	b << u8((v >> 16) & 0xff)
	b << u8((v >> 8) & 0xff)
	b << u8(v & 0xff)
}

// ---------------------------------------------------------------- the model

// Span is where one table sits in the file.
pub struct Span {
pub:
	offset int
	length int
}

// OutTable is one table as it will be written.
struct OutTable {
	tag   string
	bytes []u8
}

// Subset is what was built: the bytes, how long each table came out, which glyphs
// were kept, and what the closure added beyond the seed — so the report can say which
// table the saving came from and the verification can compare every glyph the subset
// kept, not only the ones the shaped run named.
pub struct Subset {
pub:
	bytes   []u8
	sizes   map[string]int
	keep    []bool
	closure Closure
}

// Closure counts what the seed did not already contain.
pub struct Closure {
pub mut:
	from_composites int
	from_ligatures  int
}

// ---------------------------------------------------------------- the glyph set

// spans_of maps every tag to where its bytes sit, taken from the engine's own table
// directory. Using it rather than parsing the directory a second time is what stops this
// tool and the library disagreeing about where a table starts.
pub fn spans_of(f &shape.Font) map[string]Span {
	mut out := map[string]Span{}
	for t in f.tables() {
		out[t.tag] = Span{
			offset: t.offset
			length: t.length
		}
	}
	return out
}

// uncovered lists the characters the font has no glyph for, which the run draws as
// .notdef. A variation selector is not one of them: it has no glyph of its own in any
// font and is a question about the character in front of it.
fn count_true(flags []bool) int {
	mut n := 0
	for f in flags {
		if f {
			n++
		}
	}
	return n
}

// kept_glyph_ids lists the ids the closure left true. It exists so the verification can compare
// every glyph the tool decided to keep, rather than only the ones the shaped run happened to name.
pub fn kept_glyph_ids(flags []bool) []u16 {
	mut out := []u16{cap: count_true(flags)}
	for i, f in flags {
		if f {
			out << u16(i)
		}
	}
	return out
}

// subset_font keeps the seed glyphs and everything they need, and rebuilds the
// font around them.
//
// .notdef is always kept: a character the font does not cover is drawn as it, and a
// font that cannot draw its own missing-character box is not a smaller font.
//
// The two closures are not a sequence, and running them one after the other is the bug
// this replaces. A substitution rule names glyphs that may themselves be composites,
// and a composite names glyphs a substitution rule may reach, so neither pass can be
// run once and trusted.
//
// Measured: running glyf and then GSUB, in that order, kept **0** glyphs from composite
// outlines on Segoe UI, because every composite in that run arrived through a
// substitution and the pass that would have closed over it had already finished. The `i`
// in "difficulty" came out without its dot: gid 3388 is `glyph03315` plus `dotaccent`,
// and dotaccent was dropped.
//
// So both run until neither changes anything, which is also the only ordering that
// cannot be wrong by accident. The counters count each pass, so a font whose passes
// interleave reports it.
pub fn subset_font(f &shape.Font, seed []u16) !Subset {
	data := f.data()
	spans := spans_of(f)
	glyf := spans['glyf'] or { Span{} }
	loca := spans['loca'] or { Span{} }
	head := spans['head'] or { Span{} }
	gsub := spans['GSUB'] or { Span{} }
	mut keep := []bool{len: f.num_glyphs()}
	for gid in seed {
		if int(gid) < keep.len {
			keep[gid] = true
		}
	}
	// .notdef is always kept, for the reason above.
	keep[0] = true
	mut closure := Closure{}
	mut passes := 0
	for {
		a := count_true(keep)
		close_over_glyf(mut keep, data, glyf, loca, head, mut closure)
		close_over_gsub(mut keep, data, gsub, mut closure)
		passes++
		if count_true(keep) == a {
			break
		}
		if passes > 16 {
			// A closure that will not close. Each pass either keeps something new or stops, so this
			// is a font whose tables reference each other in a ring, and stopping at a fixed bound
			// is better than a loop with no exit.
			eprintln('warning: the glyph closure did not settle in 16 passes, stopped early')
			break
		}
	}
	built := build_font(f, data, keep) or { return err }
	return Subset{
		bytes:   built.bytes
		sizes:   built.sizes
		keep:    keep
		closure: closure
	}
}

// ---------------------------------------------------------------- the closure

// loca_at is where a glyph's outline sits inside glyf.
//
// A loca value is measured from the start of glyf, not from the start of the file, which
// is the one thing about the table that is easy to get backwards: reading one as a file
// offset points at whichever table happens to be sitting at that distance, and a glyph
// read from there is a wrong outline rather than an error.
fn loca_at(d []u8, loca Span, long bool, gid int) int {
	if long {
		return int(be32(d, loca.offset + gid * 4))
	}
	return be16(d, loca.offset + gid * 2) * 2
}

// close_over_glyf keeps the glyphs a composite outline refers to.
//
// numberOfContours of -1 says the glyph is a list of other glyphs with placement values
// rather than points of its own. The walk is bounded by the glyph's own length from
// loca, so a composite whose components run past the end of its data is read as far as it
// goes rather than off the end of the file.
fn close_over_glyf(mut keep []bool, d []u8, glyf Span, loca Span, head Span, mut out Closure) {
	long := be16(d, head.offset + 50) == 1
	glyf_end := imin(glyf.offset + glyf.length, d.len)
	mut pending := []int{}
	for i, k in keep {
		if k {
			pending << i
		}
	}
	for pending.len > 0 {
		gid := pending[pending.len - 1]
		pending.delete_last()
		start := glyf.offset + loca_at(d, loca, long, gid)
		mut end := glyf.offset + loca_at(d, loca, long, gid + 1)
		if end <= start || start >= glyf_end {
			continue
		}
		if end > glyf_end {
			end = glyf_end
		}
		if be16(d, start) != 0xffff {
			continue // a simple glyph references nothing
		}
		mut p := start + 10
		for p + 4 <= end {
			flags := be16(d, p)
			component := be16(d, p + 2)
			p += 4
			if flags & 0x0001 != 0 {
				p += 4 // ARG_1_AND_2_ARE_WORDS
			} else {
				p += 2
			}
			// A single scale, a per-axis pair, or a whole two by two. Exactly one is
			// present, and reading the wrong one shifts every component after it.
			if flags & 0x0008 != 0 {
				p += 2
			} else if flags & 0x0040 != 0 {
				p += 4
			} else if flags & 0x0080 != 0 {
				p += 8
			}
			if component < keep.len && !keep[component] {
				keep[component] = true
				pending << component
				out.from_composites++
			}
			if flags & 0x0020 == 0 {
				break // no MORE_COMPONENTS
			}
		}
	}
}

// close_over_gsub keeps the glyphs a kept substitution refers to: the output of a single
// substitution, and the components of a ligature.
//
// Both are the font's own claim that the glyphs go together. A subset that breaks a pair
// the table still names has broken something the font still says.
fn close_over_gsub(mut keep []bool, d []u8, gsub Span, mut out Closure) {
	if gsub.length <= 12 {
		return
	}
	lookups := gsub.offset + be16(d, gsub.offset + 8)
	count := be16(d, lookups)
	for i in 0 .. count {
		lookup := lookups + be16(d, lookups + 2 + i * 2)
		if lookup < gsub.offset || lookup >= gsub.offset + gsub.length {
			continue
		}
		kind := be16(d, lookup)
		subtables := be16(d, lookup + 4)
		for j in 0 .. subtables {
			sub := lookup + be16(d, lookup + 6 + j * 2)
			mut at := sub
			mut type_id := kind
			// An extension lookup hides the real type behind an offset. Reading its type
			// field as a subtable count would read the subtable list as garbage.
			if kind == 7 {
				type_id = be16(d, sub + 2)
				at = sub + int(be32(d, sub + 4))
			}
			if at < gsub.offset || at >= gsub.offset + gsub.length {
				continue
			}
			match type_id {
				1 { close_single(mut keep, d, at, mut out) }
				2 { close_sequence(mut keep, d, at, mut out) }
				3 { close_sequence(mut keep, d, at, mut out) }
				4 { close_ligature(mut keep, d, at, mut out) }
				else {}
			}
		}
	}
}

// coverage_glyphs reads a Coverage table and returns its glyphs in coverage order.
//
// Coverage order is the index every subtable's own arrays are keyed by, so the answer has
// to be a list: a format 2 coverage's ranges are written in the order the substitution
// arrays are written in, and reading them as glyph ids shifts every substitution onto its
// neighbour.
fn coverage_glyphs(d []u8, at int) []int {
	format := be16(d, at)
	mut out := []int{}
	if format == 1 {
		n := be16(d, at + 2)
		for i in 0 .. n {
			out << be16(d, at + 4 + i * 2)
		}
		return out
	}
	if format == 2 {
		ranges := be16(d, at + 2)
		for i in 0 .. ranges {
			rec := at + 4 + i * 6
			start := be16(d, rec)
			end := be16(d, rec + 2)
			for g in start .. end + 1 {
				out << g
			}
		}
	}
	return out
}

fn keep_others(mut keep []bool, ids []int) int {
	mut added := 0
	for g in ids {
		if g >= 0 && g < keep.len && !keep[g] {
			keep[g] = true
			added++
		}
	}
	return added
}

fn close_single(mut keep []bool, d []u8, at int, mut out Closure) {
	format := be16(d, at)
	cov := coverage_glyphs(d, at + be16(d, at + 2))
	if format == 1 {
		// Format 1 is a delta, and a delta is added modulo 65536: a font may use one to
		// map the top of the Unicode range onto glyphs below it.
		delta := be16(d, at + 4)
		for src in cov {
			if src < keep.len && keep[src] {
				out.from_ligatures += keep_others(mut keep, [(src + delta) % 65536])
			}
		}
		return
	}
	if format == 2 {
		count := be16(d, at + 4)
		for i, src in cov {
			if i >= count {
				break
			}
			if src < keep.len && keep[src] {
				out.from_ligatures += keep_others(mut keep, [be16(d, at + 6 + i * 2)])
			}
		}
	}
}

// close_sequence handles both multiple and alternate substitution, which differ only in
// what their sets hold: a list of glyphs, or a list of alternatives. Both say the source
// glyph stands for others, so both are closed the same way.
fn close_sequence(mut keep []bool, d []u8, at int, mut out Closure) {
	if be16(d, at) != 1 {
		return
	}
	cov := coverage_glyphs(d, at + be16(d, at + 2))
	sets := be16(d, at + 4)
	for i, src in cov {
		if i >= sets {
			break
		}
		if src >= keep.len || !keep[src] {
			continue
		}
		set := at + be16(d, at + 6 + i * 2)
		n := be16(d, set)
		mut ids := []int{}
		for k in 0 .. n {
			ids << be16(d, set + 2 + k * 2)
		}
		out.from_ligatures += keep_others(mut keep, ids)
	}
}

// close_ligature keeps the letters a kept ligature is made of.
fn close_ligature(mut keep []bool, d []u8, at int, mut out Closure) {
	if be16(d, at) != 1 {
		return
	}
	cov := coverage_glyphs(d, at + be16(d, at + 2))
	sets := be16(d, at + 4)
	for i, src in cov {
		if i >= sets {
			break
		}
		set := at + be16(d, at + 6 + i * 2)
		n := be16(d, set)
		for k in 0 .. n {
			lig := set + be16(d, set + 2 + k * 2)
			lig_glyph := be16(d, lig)
			if lig_glyph >= keep.len || !keep[lig_glyph] {
				continue
			}
			components := be16(d, lig + 2)
			mut ids := []int{}
			for c in 0 .. components - 1 {
				ids << be16(d, lig + 4 + c * 2)
			}
			out.from_ligatures += keep_others(mut keep, ids)
		}
	}
}

// ---------------------------------------------------------------- writing

// build_font assembles the subset.
//
// shape.Glyph ids are preserved rather than renumbered, and that is a decision rather than an
// omission. Renumbering means rewriting every glyph id in cmap, hmtx, GSUB, GPOS and
// GDEF, and a wrong rewrite there is a font that loads fine and draws the wrong letter.
// Preserving ids means those five tables are copied byte for byte, and the only claim
// this tool makes about them is that they still address the same glyph.
//
// The price is real and worth saying out loud: those tables keep entries for glyphs that
// no longer have an outline, so the saving is the outline data rather than the whole
// file. A font that needs them smaller needs a library that renumbers glyph ids.
fn build_font(f &shape.Font, d []u8, keep []bool) !Subset {
	spans := spans_of(f)
	glyf := spans['glyf'] or { return error('no glyf table') }
	loca := spans['loca'] or { return error('no loca table') }
	head := spans['head'] or { return error('no head table') }

	new_glyf, new_loca := rebuild_outlines(f, d, glyf, loca, head, keep)

	mut tables := []OutTable{cap: spans.len}
	for tag, span in spans {
		if tag == 'glyf' || tag == 'loca' {
			continue
		}
		raw := d[span.offset..imin(span.offset + span.length, d.len)]
		if tag == 'head' {
			// checkSumAdjustment is zeroed while the table's own checksum is taken, which
			// is what the specification says it is computed over. It is patched back at
			// the end, once the whole file is laid out.
			mut bytes := raw.clone()
			for i in 8 .. 12 {
				bytes[i] = u8(0)
			}
			tables << OutTable{
				tag:   tag
				bytes: bytes
			}
			continue
		}
		tables << OutTable{
			tag:   tag
			bytes: raw
		}
	}
	tables << OutTable{
		tag:   'glyf'
		bytes: new_glyf
	}
	tables << OutTable{
		tag:   'loca'
		bytes: new_loca
	}
	// Sorted by tag, which is what the engine reads the directory as and what makes two
	// runs of this tool produce the same bytes.
	tables.sort(a.tag < b.tag)

	num := tables.len
	mut power := 1
	mut exponent := 0
	for power * 2 <= num {
		power *= 2
		exponent++
	}
	search_range := power * 16
	range_shift := num * 16 - search_range

	mut out := []u8{cap: d.len}
	out << u8(0x00)
	out << u8(0x01)
	out << u8(0x00)
	out << u8(0x00)
	out << u8(num >> 8)
	out << u8(num)
	out << u8(search_range >> 8)
	out << u8(search_range)
	out << u8(exponent >> 8)
	out << u8(exponent)
	out << u8(range_shift >> 8)
	out << u8(range_shift)

	mut offset := 12 + 16 * num
	mut head_at := 0
	mut sizes := map[string]int{}
	for t in tables {
		for ch in t.tag {
			out << u8(ch)
		}
		put32(mut out, int(table_checksum(t.bytes)))
		put32(mut out, offset)
		put32(mut out, t.bytes.len)
		sizes[t.tag] = t.bytes.len
		if t.tag == 'head' {
			head_at = offset
		}
		offset += align_up(t.bytes.len, 4)
	}
	for t in tables {
		for b in t.bytes {
			out << b
		}
		pad := align_up(t.bytes.len, 4) - t.bytes.len
		for _ in 0 .. pad {
			out << u8(0)
		}
	}
	adjust := adjustment_checksum(out)
	out[head_at + 8] = u8((adjust >> 24) & 0xff)
	out[head_at + 9] = u8((adjust >> 16) & 0xff)
	out[head_at + 10] = u8((adjust >> 8) & 0xff)
	out[head_at + 11] = u8(adjust & 0xff)
	return Subset{
		bytes: out
		sizes: sizes
	}
}

// rebuild_outlines writes glyf and loca for the kept glyphs.
//
// A dropped glyph's loca entry spans a zero length range, which is what an empty glyph in
// the original font is too. loca keeps an entry for every glyph the font declares, so
// every id in cmap, GSUB, GPOS, GDEF and hmtx still addresses the glyph it addressed.
fn rebuild_outlines(f &shape.Font, d []u8, glyf Span, loca Span, head Span, keep []bool) ([]u8, []u8) {
	num := f.num_glyphs()
	long := be16(d, head.offset + 50) == 1
	step := if long { 4 } else { 2 }
	glyf_end := imin(glyf.offset + glyf.length, d.len)

	mut glyf_out := []u8{cap: glyf.length}
	mut offsets := []int{cap: num + 1}
	offsets << 0
	mut at := 0
	for gid in 0 .. num {
		mut n := 0
		start := glyf.offset + loca_at(d, loca, long, gid)
		end := glyf.offset + loca_at(d, loca, long, gid + 1)
		if keep[gid] && end > start && start < glyf_end {
			stop := imin(end, glyf_end)
			for i in start .. stop {
				glyf_out << d[i]
			}
			n = stop - start
		}
		// The padding is not cosmetic. A short loca stores the offset halved, so an odd
		// offset is not representable, and a glyph written at one is unreadable.
		pad := align_up(n, step)
		for _ in 0 .. pad - n {
			glyf_out << u8(0)
		}
		at += pad
		offsets << at
	}

	mut loca_out := []u8{cap: (num + 1) * 4}
	for off in offsets {
		if long {
			put32(mut loca_out, off)
		} else {
			half := off / 2
			loca_out << u8(half >> 8)
			loca_out << u8(half)
		}
	}
	return glyf_out, loca_out
}

// table_checksum is the sum of the table's big-endian words, zero padded to a multiple of
// four. It is accumulated in an i64 because a word can have its top bit set, which makes
// it larger than a signed 32-bit int, and the running total has to survive that.
fn table_checksum(b []u8) u32 {
	mut sum := i64(0)
	mut i := 0
	for i + 4 <= b.len {
		sum += be32(b, i)
		i += 4
	}
	// The last word is padded with zeros to four bytes, which is what the specification
	// says a checksum is taken over, and a table whose length is not a multiple of four
	// would otherwise be summed short.
	mut tail := [4]i64{}
	for j := 0; j < b.len - i; j++ {
		tail[j] = i64(b[i + j])
	}
	sum += tail[0] * 16777216 + tail[1] * 65536 + tail[2] * 256 + tail[3]
	sum = ((sum % 4294967296) + 4294967296) % 4294967296
	return u32(sum)
}

// adjustment_checksum is the value head.checkSumAdjustment must hold for the whole file to
// sum to 0xB1B0AFBA. The field is still zero at this point, which is what the
// specification says the sum is taken over.
//
// The constant is written in hex on purpose. It was written in decimal once and one digit
// out, and the result was a file that every reader loaded and drew correctly and that
// summed to 0xB1B180F2: a font whose checksum is wrong by a number nobody would pick up
// by looking at a rendering, which is the whole reason the field exists to be checked.
fn adjustment_checksum(whole []u8) u32 {
	mut sum := i64(0)
	for i := 0; i + 4 <= whole.len; i += 4 {
		sum += be32(whole, i)
	}
	sum = ((sum % 4294967296) + 4294967296) % 4294967296
	mut adjust := i64(0xB1B0AFBA) - sum
	if adjust < 0 {
		adjust += 4294967296
	}
	return u32(adjust)
}
