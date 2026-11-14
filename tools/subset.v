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
import vtext.subset
import vtext.layout
import vtext.shape
import vtext.raster

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

	loaded := shape.load_font_file(path) or {
		eprintln('cannot load ${path}: ${err.msg()}')
		exit(1)
	}
	// The bytes come from the loaded font rather than from a second read of the
	// path, which is what stops a font held in memory from being subsettable.
	data := loaded.data()

	// This subsetter rebuilds loca and glyf. A CFF font's charstrings are a different
	// language and the library exposes no reader for them, so this refuses rather than
	// writing a font with its outlines stripped out.
	kind := loaded.outlines()
	if kind != 'glyf' {
		eprintln('${path} has ${kind} outlines, and this subsetter rebuilds glyf and loca only')
		eprintln('a CFF charstring cannot be rebuilt from what the library exposes')
		exit(1)
	}
	spans := subset.spans_of(loaded)
	if 'glyf' !in spans || 'loca' !in spans {
		eprintln('${path} has no glyf and loca pair to rewrite')
		exit(1)
	}
	if 'head' !in spans {
		eprintln('${path} has no head table, so its loca format cannot be read')
		exit(1)
	}

	ctx := shape.new_context()
	fs := shape.new_font_set()
	fs.add(loaded)

	// The run, shaped by the engine, is the only source of the glyph set.
	run := layout.layout_paragraph(ctx, text.runes(), .auto, fs, size)
	missing := uncovered(ctx, loaded, text)

	mut run_glyphs := []u16{}
	for g in run.glyphs {
		if g.gid !in run_glyphs {
			run_glyphs << g.gid
		}
	}

	sub := subset.subset_font(loaded, run_glyphs) or {
		eprintln('cannot build the subset: ${err.msg()}')
		exit(1)
	}
	os.write_file(out, sub.bytes.bytestr()) or {
		eprintln('cannot write ${out}: ${err.msg()}')
		exit(1)
	}

	kept := subset.kept_glyph_ids(sub.keep)
	report(loaded, text, run, missing, spans, data, sub, run_glyphs, kept, size)
	if !verify(out, loaded, text, run, size, kept) {
		eprintln('')
		eprintln('refusing to call this a subset: it does not shape the same as ${path}')
		exit(1)
	}
	println('')
	println('verified: ${out} shapes and rasterizes the same text as ${font_name(loaded)}')
}

fn uncovered(ctx &shape.Context, f &shape.Font, text string) []rune {
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

// ---------------------------------------------------------------- reporting

fn report(f &shape.Font, text string, run layout.Line, missing []rune, spans map[string]subset.Span,
	d []u8, sub subset.Subset, run_glyphs []u16, kept []u16, size f64) {
	println(font_name(f))
	println('  ${spans.len} tables, ${f.num_glyphs()} glyphs, ${f.units_per_em()} units per em')
	// Bytes and characters are both printed because they differ in every non-Latin text:
	// an Arabic letter is two bytes, and a reader who checks the character count against
	// the run length by hand needs the one the run is counted in.
	println('  ${text.runes().len} characters (${text.len} bytes) -> ${run.glyphs.len} glyphs at ${size:.0} pixels')
	println('')
	println('glyph set')
	println('  from the shaped run     ${run_glyphs.len}')
	println('  from a composite outline ${sub.closure.from_composites}')
	println('  from a substitution rule ${sub.closure.from_ligatures}')
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
	println('  kept                    ${kept.len} of ${f.num_glyphs()}')
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
	println('  subset        ${sub.bytes.len:9}')
	say_tables(spans, sub.sizes)
}

// say_tables says what each table cost before and after, because the saving is all in
// two of them and a single total hides which.
fn say_tables(spans map[string]subset.Span, after map[string]int) {
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

fn font_name(f &shape.Font) string {
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
fn verify(path string, original &shape.Font, text string, before layout.Line, size f64,
	kept_glyphs []u16) bool {
	sub := shape.load_font_file(path) or {
		eprintln('the subset does not load: ${err.msg()}')
		return false
	}
	ctx := shape.new_context()
	fs := shape.new_font_set()
	fs.add(sub)
	after := layout.layout_paragraph(ctx, text.runes(), .auto, fs, size)

	mut ok := true
	if after.glyphs.len != before.glyphs.len {
		eprintln('  ${before.glyphs.len} glyphs before and ${after.glyphs.len} after')
		ok = false
	}
	mut n := before.glyphs.len
	if after.glyphs.len < n {
		n = after.glyphs.len
	}
	for i in 0 .. n {
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
	if original.units_per_em() != sub.units_per_em() {
		eprintln('  units per em ${original.units_per_em()} before, ${sub.units_per_em()} after')
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
				b := sub.rasterize(gid, s, 0, dy)
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
fn same_bitmap(a raster.GlyphBitmap, b raster.GlyphBitmap) bool {
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
