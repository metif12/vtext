module main

// subset builds a smaller font holding only the glyphs a given text needs.
//
// The tool that most affects what the rest of the library can be used for, and the one
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
// Usage:
//	v run tools/subset.v <font.ttf> --text "STRING" -o out.ttf
//	v run tools/subset.v <font.ttf> --file text.txt -o out.ttf
//	v run tools/subset.v <font.ttf> --text "STRING" -o out.ttf --size 48
//
// --size is the em size the run is shaped at and the raster comparison is made at.
// Verification always runs and is the point of the tool: the font it just wrote is loaded
// back, the same string is shaped through it, and every glyph in the run is rasterized
// beside its original. A subset that shapes differently is an error, not a small success.
//
// The output is a plain font. A collection is subset to its first member, which is the
// only one the library reads, and the file loses the collection header.
//
// It refuses a CFF font outright, and the reason is stated in the refusal rather than
// left for the reader to infer: this rebuilds glyf and loca, and a charstring is a
// different language that the library exposes no reader for.

import os
import vtext

// ---------------------------------------------------------------- arguments

fn arg(i int, fallback string) string {
	if i < os.args.len {
		return os.args[i]
	}
	return fallback
}

fn flag(name string) bool {
	for a in os.args {
		if a == name {
			return true
		}
	}
	return false
}

// option reads --name value, or the fallback when it is absent or has nothing after it.
fn option(name string, fallback string) string {
	for i, a in os.args {
		if a == name && i + 1 < os.args.len {
			return os.args[i + 1]
		}
	}
	return fallback
}

fn parses(text string, fallback int) int {
	s := text.trim_space()
	if s == '' {
		return fallback
	}
	mut value := 0
	mut any := false
	for ch in s {
		d := ch - `0`
		if d < 0 || d > 9 {
			return fallback
		}
		value = value * 10 + int(d)
		any = true
	}
	return if any { value } else { fallback }
}

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
struct Span {
	offset int
	length int
}

// OutTable is one table as it will be written.
struct OutTable {
	tag   string
	bytes []u8
}

// Subset is what was built: the bytes, and how long each table came out, so the report
// can say which one the saving came from.
struct Subset {
	bytes []u8
	sizes map[string]int
}

// Closure counts what the run did not already contain.
struct Closure {
mut:
	from_composites int
	from_ligatures  int
}

fn main() {
	path := arg(1, '')
	mut text := option('--text', '')
	if text == '' {
		file := option('--file', '')
		if file != '' {
			raw := os.read_file(file) or {
				eprintln('cannot read ${file}: ${err.msg()}')
				exit(1)
			}
			// A trailing newline is the file's, not the text's: keeping it would subset a
			// line break nobody asked for.
			text = raw.trim_right('\r\n')
		}
	}
	if path == '' || flag('--help') || flag('-h') || text == '' {
		eprintln('usage: v run tools/subset.v <font.ttf> --text "STRING" [-o out.ttf] [--size N]')
		eprintln('                               [--file FILE]')
		exit(1)
	}
	out := option('-o', option('--out', ''))
	if out == '' {
		eprintln('no output path: -o out.ttf')
		exit(1)
	}
	size := f64(parses(option('--size', '32'), 32))
	if size <= 0 {
		eprintln('a size of ${size} pixels cannot be laid out')
		exit(1)
	}

	font := vtext.load_font_file(path) or {
		eprintln('cannot load ${path}: ${err.msg()}')
		exit(1)
	}
	data := os.read_bytes(path) or {
		eprintln('cannot read ${path}: ${err.msg()}')
		exit(1)
	}

	// This subsetter rebuilds loca and glyf. A CFF font's charstrings are a different
	// language and the library exposes no reader for them, so this refuses rather than
	// writing a font with its outlines stripped out.
	kind := font.outlines()
	if kind != 'glyf' {
		eprintln('${path} has ${kind} outlines, and this subsetter rebuilds glyf and loca only')
		eprintln('a CFF charstring cannot be rebuilt from what the library exposes')
		exit(1)
	}
	spans := spans_of(font)
	if 'glyf' !in spans || 'loca' !in spans {
		eprintln('${path} has no glyf and loca pair to rewrite')
		exit(1)
	}
	if 'head' !in spans {
		eprintln('${path} has no head table, so its loca format cannot be read')
		exit(1)
	}

	ctx := vtext.new_context()
	fs := vtext.new_font_set()
	fs.add(font)

	// The run, shaped by the engine, is the only source of the glyph set.
	run := vtext.layout_paragraph(ctx, text.runes(), .auto, fs, size)
	missing := uncovered(ctx, font, text)

	mut keep := []bool{len: font.num_glyphs()}
	mut run_glyphs := []u16{}
	for g in run.glyphs {
		keep[int(g.gid)] = true
		if g.gid !in run_glyphs {
			run_glyphs << g.gid
		}
	}
	// .notdef is always kept: a character the font does not cover is drawn as it, and a
	// font that cannot draw its own missing-character box is not a smaller font.
	keep[0] = true

	mut closure := Closure{}
	// The two closures are not a sequence, and running them one after the other is the bug this
	// replaces. A substitution rule names glyphs that may themselves be composites, and a composite
	// names glyphs a substitution rule may reach, so neither pass can be run once and trusted.
	//
	// Measured: running glyf and then GSUB, in that order, kept **0** glyphs from composite outlines
	// on Segoe UI, because every composite in that run arrived through a substitution and the pass
	// that would have closed over it had already finished. The `i` in "difficulty" came out without
	// its dot: gid 3388 is `glyph03315` plus `dotaccent`, and dotaccent was dropped.
	//
	// So both run until neither changes anything, which is also the only ordering that cannot be
	// wrong by accident. The counters count each pass, so a font whose passes interleave reports it.
	mut passes := 0
	// The two closures are not a sequence, and running them one after the other is the bug this
	// replaces. A substitution rule names glyphs that may themselves be composites, and a composite
	// names glyphs a substitution rule may reach, so neither pass can be run once and trusted.
	//
	// Measured: running glyf and then GSUB, in that order, kept **0** glyphs from composite outlines
	// on Segoe UI, because every composite in that run arrived through a substitution and the pass
	// that would have closed over it had already finished. The `i` in "difficulty" came out without
	// its dot: gid 3388 is `glyph03315` plus `dotaccent`, and dotaccent was dropped. The tool then
	// reported its own verification green, because the glyph was not in the run's own list.
	//
	// So both run until neither changes anything, which is also the only ordering that cannot be
	// wrong by accident. The counters count each pass, so a font whose passes interleave reports it.
	for {
		a := count_true(keep)
		close_over_glyf(mut keep, data, spans['glyf'], spans['loca'], spans['head'], mut closure)
		close_over_gsub(mut keep, data, spans['GSUB'], mut closure)
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

	subset := build_font(font, data, keep) or {
		eprintln('cannot build the subset: ${err.msg()}')
		exit(1)
	}
	os.write_file(out, subset.bytes.bytestr()) or {
		eprintln('cannot write ${out}: ${err.msg()}')
		exit(1)
	}

	report(font, text, run, missing, spans, data, subset, keep, run_glyphs, closure,
		size)
	kept := kept_glyph_ids(keep)
	if !verify(out, font, text, run, size, kept) {
		eprintln('')
		eprintln('refusing to call this a subset: it does not shape the same as ${path}')
		exit(1)
	}
	println('')
	println('verified: ${out} shapes and rasterizes the same text as ${font_name(font)}')
}

// ---------------------------------------------------------------- the glyph set

// spans_of maps every tag to where its bytes sit, taken from the engine's own table
// directory. Using it rather than parsing the directory a second time is what stops this
// tool and the library disagreeing about where a table starts.
fn spans_of(f &vtext.Font) map[string]Span {
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
fn uncovered(ctx &vtext.Context, f &vtext.Font, text string) []rune {
	mut out := []rune{}
	for cp in text.runes() {
		if ctx.properties.is_variation_selector(cp) {
			continue
		}
		if !f.has_glyph(cp) && cp !in out {
			out << cp
		}
	}
	return out
}

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
fn kept_glyph_ids(flags []bool) []u16 {
	mut out := []u16{cap: count_true(flags)}
	for i, f in flags {
		if f {
			out << u16(i)
		}
	}
	return out
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
// Glyph ids are preserved rather than renumbered, and that is a decision rather than an
// omission. Renumbering means rewriting every glyph id in cmap, hmtx, GSUB, GPOS and
// GDEF, and a wrong rewrite there is a font that loads fine and draws the wrong letter.
// Preserving ids means those five tables are copied byte for byte, and the only claim
// this tool makes about them is that they still address the same glyph.
//
// The price is real and worth saying out loud: those tables keep entries for glyphs that
// no longer have an outline, so the saving is the outline data rather than the whole
// file. A font that needs them smaller needs a library that renumbers glyph ids.
fn build_font(f &vtext.Font, d []u8, keep []bool) !Subset {
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
fn rebuild_outlines(f &vtext.Font, d []u8, glyf Span, loca Span, head Span, keep []bool) ([]u8, []u8) {
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

// ---------------------------------------------------------------- reporting

fn report(f &vtext.Font, text string, run vtext.Line, missing []rune, spans map[string]Span,
	d []u8, subset Subset, keep []bool, run_glyphs []u16, closure Closure, size f64) {
	println(font_name(f))
	println('  ${spans.len} tables, ${f.num_glyphs()} glyphs, ${f.units_per_em()} units per em')
	// Bytes and characters are both printed because they differ in every non-Latin text:
	// an Arabic letter is two bytes, and a reader who checks the character count against
	// the run length by hand needs the one the run is counted in.
	println('  ${text.runes().len} characters (${text.len} bytes) -> ${run.glyphs.len} glyphs at ${size:.0} pixels')
	println('')
	println('glyph set')
	println('  from the shaped run     ${run_glyphs.len}')
	println('  from a composite outline ${closure.from_composites}')
	println('  from a substitution rule ${closure.from_ligatures}')
	// Named on its own line so the three above it add up to the total, and so a reader
	// can see that .notdef was kept on purpose rather than falling into the count by
	// accident.
	mut notdef := 0
	for g in run_glyphs {
		if g == 0 {
			notdef = 1
		}
	}
	if notdef == 0 {
		println('  .notdef, always kept    1')
	}
	println('  kept                    ${count_true(keep)} of ${f.num_glyphs()}')
	if missing.len > 0 {
		mut names := []string{}
		for cp in missing {
			names << 'U+${u32(cp):04X}'
		}
		println('  no glyph for            ${names.join(' ')}')
		println('    these draw as .notdef in the original and in the subset alike')
	}
	println('')
	println('bytes')
	println('  original      ${d.len:9}')
	println('  subset        ${subset.bytes.len:9}')
	say_tables(spans, subset.sizes)
}

// say_tables says what each table cost before and after, because the saving is all in
// two of them and a single total hides which.
fn say_tables(spans map[string]Span, after map[string]int) {
	mut tags := []string{}
	for tag, _ in spans {
		tags << tag
	}
	tags.sort()
	for tag in tags {
		before := if tag in spans { spans[tag].length } else { 0 }
		now := after[tag]
		mut note := ''
		if tag == 'glyf' || tag == 'loca' {
			note = '   rebuilt'
		}
		println('    ${tag}  ${before:8} -> ${now:8}${note}')
	}
}

fn font_name(f &vtext.Font) string {
	name := f.path()
	if name == '' {
		return 'font'
	}
	parts := name.replace('\\', '/').split('/')
	return parts[parts.len - 1]
}

// ---------------------------------------------------------------- verification

// verify is the reason this tool exists.
//
// It loads the file it just wrote, shapes the same string through it, and compares the
// glyph ids, the positions and the rasterized ink of the whole run against the original
// font. A green run of this is the only claim the report is allowed to make; everything
// above it is arithmetic about bytes.
fn verify(path string, original &vtext.Font, text string, before vtext.Line, size f64,
	kept_glyphs []u16) bool {
	subset := vtext.load_font_file(path) or {
		eprintln('the subset does not load: ${err.msg()}')
		return false
	}
	ctx := vtext.new_context()
	fs := vtext.new_font_set()
	fs.add(subset)
	after := vtext.layout_paragraph(ctx, text.runes(), .auto, fs, size)

	mut ok := true
	if after.glyphs.len != before.glyphs.len {
		eprintln('  ${before.glyphs.len} glyphs before and ${after.glyphs.len} after')
		ok = false
	}
	for i in 0 .. imin(before.glyphs.len, after.glyphs.len) {
		a := before.glyphs[i]
		b := after.glyphs[i]
		if a.gid != b.gid || a.x != b.x || a.y != b.y || a.cluster != b.cluster {
			eprintln('  glyph ${i}: gid ${a.gid} at ${a.x:.2f} before, gid ${b.gid} at ${b.x:.2f} after')
			ok = false
			break
		}
		if a.advance != b.advance {
			eprintln('  glyph ${i} (gid ${a.gid}) advance ${a.advance} before, ${b.advance} after')
			ok = false
			break
		}
	}
	if !ok {
		return false
	}
	if original.units_per_em() != subset.units_per_em() {
		eprintln('  units per em ${original.units_per_em()} before, ${subset.units_per_em()} after')
		return false
	}

	// The ink of every glyph the subset **keeps**, at three sizes and two subpixel bins. The ids
	// agreeing is not the outlines agreeing, and a subset that keeps the ids and drops the points is
	// exactly the failure this section is here to catch.
	//
	// It has to be every kept glyph and not only the ones the run used, and that was not what this
	// did. A subset of Segoe UI for "office ffi difficulty" reported this line green while the `i` in
	// "difficulty" had lost its dot: the composite gid 3388 is `glyph03315` plus `dotaccent`, the
	// closure had dropped dotaccent, and the glyph was not in the run's own list so nothing compared
	// it. The tool's own check passed on a font that drew a different letter. Comparing only what the
	// run names is a check of the shaping, and the closures add glyphs the run never mentions.
	sizes := [16.0, size, 48.0]
	mut glyphs := []u16{}
	for g in before.glyphs {
		if g.gid !in glyphs {
			glyphs << g.gid
		}
	}
	for g in kept_glyphs {
		if g !in glyphs {
			glyphs << g
		}
	}
	for gid in glyphs {
		for s in sizes {
			for dy in [i32(0), i32(1)] {
				a := original.rasterize(gid, s, 0, dy)
				b := subset.rasterize(gid, s, 0, dy)
				if !same_bitmap(a, b) {
					eprintln('  gid ${gid} at ${s:.0} pixels rasterizes differently')
					return false
				}
			}
		}
	}
	println('  ${before.glyphs.len} glyphs in the run, ids and positions identical')
	println('  ${glyphs.len} glyphs rasterized at ${sizes.len} sizes and 2 bins, ink identical')
	return true
}

// same_bitmap compares the ink, not just the box: two glyphs can share a box and differ
// in every pixel inside it.
fn same_bitmap(a vtext.GlyphBitmap, b vtext.GlyphBitmap) bool {
	if a.width != b.width || a.height != b.height || a.left != b.left || a.top != b.top {
		return false
	}
	if a.coverage.len != b.coverage.len {
		return false
	}
	for i, v in a.coverage {
		if v != b.coverage[i] {
			return false
		}
	}
	return true
}
