module vtext

// Reading what a font contains, for the programs that want to know rather than to draw.
//
// Everything here is a report about a font the engine has already read. None of it changes what the engine
// does with the font, and none of it guesses: a number is the number in the font's tables, and a list is
// the list those tables hold. That is the distinction worth keeping. `Font.kerns` answers whether the font
// kerns, which is a report about the font. `Font.kern_offset` answers what it does to a pair, which is the
// engine acting. A caller that wants to know what a font can do asks here, and a caller that wants to know
// what the engine did with a string asks the layout.
//
// This is what `tools/fontdump`, `tools/fontcheck` and `tools/shapetrace` are written against, and it is
// public because a library that cannot be inspected cannot be diagnosed from outside itself.

// TableInfo is one table a font carries: its tag, where it is, and how long it is.
pub struct TableInfo {
pub:
	// tag is the four character tag, which is not always four characters: 'OS/2' is three with a slash,
	// and the last table's tag is padded with a space rather than shortened.
	tag string
	// offset is where the table's bytes begin in the file. In a collection that is inside the file of the
	// whole collection rather than of the member, which is what a caller slicing the file wants.
	offset int
	// length is how many bytes the table has. A table's bytes are padded to a four byte boundary in the
	// file, and this counts the bytes rather than the padding.
	length int
}

// VariableAxis is one axis of a variable font: its tag, its range, and its default.
pub struct VariableAxis {
pub:
	// tag is the four character axis tag: 'wght' for weight, 'wdth' for width, 'ital', 'slnt', 'opsz'.
	tag string
	// minimum, deflt and maximum are the axis's range in design units. A font's named instances are points
	// inside this range, and its variation store is indexed by how far along the range a point is.
	minimum f64
	deflt   f64
	maximum f64
}

// glyph_class_names are GDEF's five glyph classes, indexed by the class number.
//
// GDEF says what a glyph is with a number from 1 to 4, and every table that reads it uses those numbers,
// so a report that said "class 3" would be a report in the font's language rather than the reader's. Index
// zero is the class a glyph is in when no table says, which is not the same as being a base: it is the
// absence of a claim.
pub const glyph_class_names = ['unclassified', 'base', 'ligature', 'mark', 'component']

// tables lists the font's tables, sorted by tag.
//
// The directory carries no order of its own, and it is read into a map, so sorting here is what makes two
// reports of the same font comparable. A report that came out in a different order each time would be one
// nobody could read twice.
pub fn (f &Font) tables() []TableInfo {
	mut out := []TableInfo{cap: f.face.sfnt.tables.len}
	for tag, rec in f.face.sfnt.tables {
		out << TableInfo{
			tag:    tag
			offset: rec.offset
			length: rec.length
		}
	}
	return sort_table_info(out)
}

// has_table reports whether the font carries a table with this tag.
//
// This is the question "can this engine use the font's colouring", answered without trying to: COLR and
// CPAL are there, sbix and CBDT are there, and none of them is read. The engine draws outlines, so a
// colour table it cannot use is a fact about the font and not a promise about the output.
pub fn (f &Font) has_table(tag string) bool {
	return f.face.sfnt.has(tag)
}

// table_length is how many bytes a table has, or zero when the font has no such table.
//
// The zero is a choice worth naming. A table that is absent and a table that is empty mean different things
// to a font, so a caller asking for the length of a table it may not have needs to tell them apart, and
// `has_table` is how. Reporting minus one for absent would be tidier and would hide the difference from
// everyone who used the zero.
pub fn (f &Font) table_length(tag string) int {
	rec := f.face.sfnt.record(tag) or { return 0 }
	return rec.length
}

// outlines says which kind the font draws with: 'glyf' for TrueType outlines, 'CFF ' for PostScript
// outlines, and an empty string for neither, which is a font that draws nothing at all.
pub fn (f &Font) outlines() string {
	sfnt := f.face.sfnt
	if sfnt.has(tag_glyf) && sfnt.has(tag_loca) {
		return 'glyf'
	}
	if sfnt.has('CFF ') {
		return 'CFF '
	}
	return ''
}

// num_lookups says how many lookups a table has, or zero when the font has no such table.
//
// The number is the lookup count in the table's own list, which is what a font's size is made of. It is not
// the number the engine did anything with: a lookup the engine did not read is counted here and nowhere
// else, which is exactly what makes the difference between a font that has a feature and a font this
// engine can use that feature from.
pub fn (f &Font) num_lookups(table string) int {
	match table {
		'GSUB' {
			gsub := f.face.gsub or { return 0 }
			return gsub.lookups.len
		}
		'GPOS' {
			gpos := f.face.gpos or { return 0 }
			return gpos.lookups.len
		}
		else {
			return 0
		}
	}
}

// features lists the feature tags a table offers, sorted.
//
// This is a report about the table rather than about anything the engine does with it. A feature named
// under a script the engine never selects is still one the font offers, so it is listed. What the engine
// can reach with a feature is asked through `lookups_for`, which answers for one script at a time and says
// nothing when the answer is nothing.
//
// The same tag under two scripts appears once. The count of tags is not the count of places a tag is
// named, and a font that names 'kern' under both arab and latn offers one kerning feature.
pub fn (f &Font) features(table string) []string {
	mut tags := []string{}
	match table {
		'GSUB' {
			gsub := f.face.gsub or { return []string{} }
			tags = gsub.feature_tags()
		}
		'GPOS' {
			gpos := f.face.gpos or { return []string{} }
			tags = gpos.feature_tags()
		}
		else {
			return []string{}
		}
	}
	return sort_tags(tags)
}

// num_features says how many distinct feature tags a table offers, across every script and language it
// declares. It is `features(tag).len`, named on its own because a report line that had to spell the whole
// call out to count something would not get written.
pub fn (f &Font) num_features(table string) int {
	return f.features(table).len
}

// scripts lists the script tags a table declares, sorted.
//
// This is the table's own list of scripts, which is not the same as the scripts the text in it needs. A font
// can declare 'arab' and carry nothing the engine can reach with it, which is Dubai's case for its mark
// attachment rules, and the difference between what is declared and what is usable is the reason to ask.
// A font that names DFLT rather than a real script tag is reported as naming DFLT.
pub fn (f &Font) scripts(table string) []string {
	mut tags := []string{}
	match table {
		'GSUB' {
			gsub := f.face.gsub or { return []string{} }
			tags = gsub.script_tags()
		}
		'GPOS' {
			gpos := f.face.gpos or { return []string{} }
			tags = gpos.script_tags()
		}
		else {
			return []string{}
		}
	}
	return sort_tags(tags)
}

// cmap_counts says how many codepoints each of the font's cmap subtables maps, in the same order as
// `Font.num_cmap_subtables` counts subtables and `cmap_formats` lists their formats.
//
// Every subtable is listed, including the ones the engine does not pick, because the engine picking one
// and a reader knowing that it picked are different questions. A font with one subtable of 94 mappings and
// another of 9472 is a font whose coverage depends on which one is read, and that is worth seeing.
//
// The count is a walk of the codepoints rather than a field in the table, because no cmap format stores
// one: format 4 has a segment count and format 12 has a group count, and neither is the number of mappings.
// The walk covers the Basic Multilingual Plane, which is every mapping any font on this machine has. A font
// that maps something above it is counted short, which is stated here rather than left to be discovered by
// a count that did not add up.
pub fn (f &Font) cmap_counts() []int {
	mut out := []int{cap: f.face.cmaps.len}
	for c in f.face.cmaps {
		out << c.mapped_count()
	}
	return out
}

// cmap_formats lists the format number of each cmap subtable, in the same order as `cmap_counts`.
//
// The format is the first field of a subtable and the count above it is not, so the two together say more
// than either: a format 4 with 94 mappings and a format 12 with 9472 are one font's coverage written twice,
// and a format 0 with 256 mappings is a byte table that no modern character is in.
pub fn (f &Font) cmap_formats() []int {
	mut out := []int{cap: f.face.cmaps.len}
	for c in f.face.cmaps {
		out << c.format
	}
	return out
}

// glyph_class_counts counts the font's glyphs by what GDEF says each one is, in the order of
// `glyph_class_names`.
//
// A font with no GDEF puts every glyph in "unclassified", which is what GDEF's absence means rather than a
// claim that the font has no bases and no marks: the table is where the classes come from, and without it
// there are none to count. The counts therefore add up to the glyph count either way, which is what makes
// a report of them worth printing.
pub fn (f &Font) glyph_class_counts() [5]int {
	mut out := [5]int{}
	gdef := f.face.gdef or {
		// Every glyph goes in the first bucket, which is "no table says". Returning here instead would
		// report that a font without GDEF has no glyphs at all, and the counts would not add up to
		// anything: a caller summing them to check the reader had not dropped a class would be told the
		// reader had dropped all of them.
		out[0] = f.num_glyphs()
		return out
	}
	for gid in 0 .. f.num_glyphs() {
		class := int(gdef.glyph_class(u16(gid)))
		if class >= 0 && class < 5 {
			out[class]++
		}
	}
	return out
}

// is_variable says whether the font carries an `fvar` table, which is what makes it variable.
//
// It does not say whether this engine reads one, and it does not: a variable font whose GPOS kerning has no
// variation index kerns identically at every weight, and the six variable fonts on this machine are all
// like that. So this is a fact about the font, and the engine's lack of variation support is a fact about
// the engine, and neither is dressed up as the other.
pub fn (f &Font) is_variable() bool {
	return f.face.sfnt.has(tag_fvar)
}

// variable_axes lists a variable font's axes, or nothing when the font is not variable.
//
// The list is read from `fvar` whether or not this engine can act on a variation, because a caller laying
// out with a variable font wants to know it has axes before it draws. Finding out afterwards that the weight
// it asked for did nothing is worse than knowing in advance that nothing would happen, and this is the
// cheapest way to know.
//
// An empty list here and an empty list from a font with no `fvar` are told apart by `is_variable`.
pub fn (f &Font) variable_axes() []VariableAxis {
	return f.face.read_variable_axes()
}

// sort_table_info orders a table list by tag.
//
// The sort is written out rather than reached for because this V has no sort_with on a slice of a struct,
// and these lists are short enough that the straightforward version is also the readable one.
//
// The list is sorted into a copy rather than in place. The caller's list belongs to the caller, and a
// report function that reordered what it was handed would be a surprise with a number in it.
fn sort_table_info(list []TableInfo) []TableInfo {
	mut out := list.clone()
	for i in 1 .. out.len {
		mut k := i
		for k > 0 && out[k].tag < out[k - 1].tag {
			out[k], out[k - 1] = out[k - 1], out[k]
			k--
		}
	}
	return out
}

// sort_tags orders a list of tags, for the same reason sort_table_info orders a table list.
fn sort_tags(list []string) []string {
	mut out := list.clone()
	for i in 1 .. out.len {
		mut k := i
		for k > 0 && out[k] < out[k - 1] {
			out[k], out[k - 1] = out[k - 1], out[k]
			k--
		}
	}
	return out
}

// mapped_count is how many codepoints this subtable gives a glyph that is not .notdef.
//
// The walk skips .notdef because a subtable is allowed to name a character it has no glyph for, and
// counting those as mappings would say a font covers a character it cannot draw. That is the same
// distinction `glyph_grid` draws, and it is why a font's coverage number and its mapped number are two
// different numbers.
fn (c &Cmap) mapped_count() int {
	mut n := 0
	for cp in 0 .. 0x10000 {
		gid := c.lookup_glyph(u32(cp)) or { continue }
		if gid != 0 {
			n++
		}
	}
	return n
}
