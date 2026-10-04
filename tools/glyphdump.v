module main

// glyphdump writes a font's glyphs out as images, and lays a string out so the shaping result can be
// looked at rather than inferred.
//
// Three jobs, because they answer three different questions:
//
//   --sheet      a grid of glyphs on one page, for seeing what a font contains and for eyeballing a
//                rasteriser across a whole font in one image rather than one glyph at a time.
//   --each DIR   one image per glyph, sized to that glyph's own ink box, which is the form to diff
//                against another rasteriser: the box is the font's answer and two rasterisers that
//                disagree about it disagree about the glyph.
//   --text STR   the run a string shapes into, drawn and tabulated. This is the one for "what did that
//                substitution actually produce", which is otherwise only answerable by printing glyph
//                ids and counting them by hand.
//
// Every glyph is drawn through the same call the examples use, so nothing here is a second rasteriser.
// The one thing this file adds is the table: glyph ids and the characters they stand for, which is what
// a substitution hides.
//
// Usage:
//	v run tools/glyphdump.v <font.ttf>
//	v run tools/glyphdump.v <font.ttf> --size 32 --count 256 --boxes
//	v run tools/glyphdump.v <font.ttf> --each out/glyphs --count 64
//	v run tools/glyphdump.v <font.ttf> --text 'سلام دنیا' --size 48

import os
import math
import vtext
import paint

// The sheet's shape. Sixteen across is a width that fits a screen and still gives each cell room for a
// letter at the sizes a specimen is looked at; the cell is the em plus a gap, so nothing is cropped when
// the size changes.
const columns = 16
const cell_gap = 8
const page_margin = 16

// How much of a glyph's ink to leave around it in a per-glyph image. The point of these images is to be
// compared, and a glyph flush against its own edge tells you less than one with a margin around it.
const ink_pad = 2

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
	if path == '' || flag('--help') || flag('-h') {
		eprintln('usage: v run tools/glyphdump.v <font.ttf> [--size N] [--first N] [--count N]')
		eprintln('                                   [--boxes] [--each DIR] [--sheet NAME] [--text STR]')
		exit(1)
	}
	size := parses(option('--size', '48'), 48)
	first := parses(option('--first', '0'), 0)
	count := parses(option('--count', '256'), 256)

	font := vtext.load_font_file(path) or {
		eprintln('cannot load ${path}: ${err}')
		exit(1)
	}
	total := font.num_glyphs()
	if total == 0 {
		eprintln('${path} has no glyphs')
		exit(1)
	}
	println('${base_name(path)}')
	println('  ${total} glyphs, ${font.units_per_em()} units per em')

	if flag('--text') {
		dump_text(font, option('--text', ''), size)
		return
	}
	dir := option('--each', '')
	if dir != '' {
		mut limit := count
		if limit == 0 {
			limit = total
		}
		dump_each(font, dir, first, limit, size)
		return
	}
	name := option('--sheet', 'sheet.png')
	dump_sheet(font, first, count, size, flag('--boxes'), name)
}

// base_name is the file's own name, which is what the output is titled with.
fn base_name(path string) string {
	parts := path.replace('\\', '/').split('/')
	return parts[parts.len - 1]
}

// range_of resolves --first and --count against the font, so a caller asking for more glyphs than the
// font has is told the count rather than being handed a short page and no warning.
struct Range {
mut:
	first int
	last  int
}

fn range_of(f &vtext.Font, first int, count int) Range {
	total := int(f.num_glyphs())
	mut lo := first
	if lo < 0 {
		lo = 0
	}
	if lo >= total {
		lo = total - 1
	}
	mut hi := lo + count - 1
	if hi > total - 1 {
		hi = total - 1
	}
	return Range{ first: lo, last: hi }
}

// dump_sheet draws a grid of glyphs on one page.
//
// The baseline runs through every row rather than each cell being centred on its own ink, because a
// specimen is read for shape and a baseline is what shows whether two letters sit at the same height.
fn dump_sheet(f &vtext.Font, first int, count int, size f64, boxes bool, name string) {
	r := range_of(f, first, count)
	n := r.last - r.first + 1
	rows := (n + columns - 1) / columns
	// The cell is the font's own height plus a gap, not the em size, because a glyph with a mark on it
	// reaches above the font's ascent and a descender reaches below its descent. Sizing the cell from the
	// em crops both, and a specimen that crops its own marks cannot be used to check mark placement.
	cell := int(math.ceil(f.ascent(size) + f.descent(size))) + cell_gap
	w := columns * cell + 2 * page_margin
	h := rows * cell + 2 * page_margin
	mut canvas := paint.new_canvas(w, h, 0xff)
	// One pixel of slack above the baseline inside the cell, so ink that reaches to the font's ascent is
	// inside the frame rather than on its edge.
	baseline_in_cell := f.ascent(size) + 1.0

	for gid in r.first .. r.last + 1 {
		slot := gid - r.first
		cx := page_margin + (slot % columns) * cell
		cy := page_margin + (slot / columns) * cell
		canvas.draw_glyph(f, glyph_at(f, u16(gid), f64(cx), 0.0), f64(cy) + baseline_in_cell, size)
		if boxes {
			draw_box(mut canvas, f, u16(gid), f64(cx), f64(cy) + baseline_in_cell, size)
		}
	}
	canvas.write_png(name)
	println('  sheet covers glyphs ${r.first}..${r.last}, ${rows} rows of ${columns}')
}

// glyph_at builds the Glyph the drawing call takes, for one glyph at a known pen position.
//
// The advance is the font's own and the cluster is left alone: neither matters to a rasteriser, and
// setting them from guesses would make the tool a second source of answers about the font.
fn glyph_at(f &vtext.Font, gid u16, x f64, y f64) vtext.Glyph {
	return vtext.Glyph{
		gid:     gid
		advance: f.glyph_advance(gid, 1000.0)
		x:       x
		y:       y
		font:    f
	}
}

// draw_box outlines where a glyph's ink actually is, which is the number a caller comparing rasterisers
// needs and cannot see in the picture.
fn draw_box(mut canvas &paint.Canvas, f &vtext.Font, gid u16, x f64, baseline f64, size f64) {
	bmp := f.rasterize(gid, size, 0, 0)
	if bmp.is_empty() {
		return
	}
	x0 := int(x) + bmp.left
	y0 := int(baseline) - bmp.top
	canvas.rect(x0, y0, x0 + bmp.width, y0 + bmp.height, 0x60)
}

// dump_each writes one image per glyph, each sized to that glyph's own ink box.
//
// This is the form to compare against another rasteriser. The image is the glyph and the box it says it
// has, with nothing else in the frame, so two of these that differ differ in the glyph rather than in
// where somebody chose to put it.
fn dump_each(f &vtext.Font, dir string, first int, count int, size f64) {
	os.mkdir_all(dir) or {
		eprintln('cannot make ${dir}: ${err}')
		exit(1)
	}
	r := range_of(f, first, count)
	mut written := 0
	mut empty := 0
	for gid in r.first .. r.last + 1 {
		bmp := f.rasterize(u16(gid), size, 0, 0)
		if bmp.is_empty() {
			empty++
			continue
		}
		// One pixel of slack on each side, so a glyph whose ink touches its own box is not clipped by
		// the canvas edge and reported as blank.
		w := bmp.width + 2 * ink_pad
		h := bmp.height + 2 * ink_pad
		mut canvas := paint.new_canvas(w, h, 0xff)
		for by in 0 .. bmp.height {
			for bx in 0 .. bmp.width {
				cov := bmp.ink(bx, by)
				if cov > 0 {
					canvas.blend(ink_pad + bx, ink_pad + by, cov)
				}
			}
		}
		name := '${dir}/g${gid:05}.png'
		os.write_file(name, canvas.png().bytestr()) or {
			eprintln('cannot write ${name}: ${err}')
			exit(1)
		}
		written++
	}
	println('  wrote ${written} images to ${dir} at ${size:.0} pixels')
	if empty > 0 {
		println('  ${empty} glyphs in ${r.first}..${r.last} have no ink at this size and were not written')
	}
}

// dump_text lays a string out, draws the run, and prints what each glyph came from.
//
// The table is the point. A caller who has just looked at a word and wants to know why it is the wrong
// shape cannot answer that from the picture, and the two columns that matter are the glyph id and the
// character it stands for: a substitution shows up as a glyph id that is not the character's own.
fn dump_text(f &vtext.Font, text string, size f64) {
	if text == '' {
		eprintln('--text needs a string after it')
		exit(1)
	}
	ctx := vtext.new_context()
	fs := vtext.new_font_set()
	fs.add(f)
	cps := text.runes()
	line := vtext.layout_paragraph(ctx, cps, .auto, fs, size)

	margin := 16
	w := int(math.ceil(line.width)) + 2 * margin
	h := int(math.ceil(line.ascent + line.descent)) + 2 * margin
	mut canvas := paint.new_canvas(w, h, 0xff)
	baseline := f64(margin) + line.ascent
	// Drawn through the same call as every example, at the positions the engine chose.
	for g in line.glyphs {
		if gf := g.font {
			canvas.draw_glyph(gf, g, baseline, size)
		}
	}
	canvas.write_png('shaped.png')

	println('  ${cps.len} characters -> ${line.glyphs.len} glyphs, ${line.width:.1f} pixels wide')
	// One table, not two. A ligature covers two characters and reports the first, so the glyph count and
	// the cluster count disagree on purpose, and a table listing the same two numbers twice only invites
	// the reader to compare them and wonder which is wrong.
	//
	// The substitution note is the column that earns the tool: a glyph whose id is not the character's own
	// mapping is a substitution, and which substitution it was is the question "why is this word the wrong
	// shape" actually is.
	println('')
	println('  cluster  glyph  from character')
	for g in line.glyphs {
		mut cp := rune(0)
		if g.cluster < cps.len {
			cp = cps[g.cluster]
		}
		mut note := ''
		if back := f.codepoint_for(g.gid) {
			if back != cp {
				note = '  <- substituted, U+${back:04X} is this glyph'
			}
		}
		println('  ${g.cluster:7}  ${g.gid:5}  U+${u32(cp):04X}${note}')
	}
}
