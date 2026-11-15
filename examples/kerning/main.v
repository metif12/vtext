// kerning shows the same word in a font set that kerns and in one that does not, with each glyph's
// advance drawn so the gap between two letters can be measured rather than asserted.
//
// The comparison is only honest because both sets are real and the difference is a font's own decision.
// Amiri kerns both Latin and Arabic, Noto Naskh kerns Latin but not Arabic, and FiraCode (monospace)
// kerns nothing at all, so the two lines below differ by what the fonts say rather than by what the
// engine did. That a font kerns one script and not another is a choice a font can make and this
// engine has to respect.
//
// What to read off the picture:
//
//   - The letters are the same and the spacing is not. Amiri closes Latin AV by 62 units and names a
//     (zero-valued) rule on one Arabic join; the FiraCode+Naskh line leaves both alone. Each is
//     correct for its fonts.
//   - The rule under each glyph is its advance. Two rules the same width apart with no kern are the whole
//     of the difference: a kern is a change to an advance, so a gap that closes is one advance that grew
//     shorter.
//   - The numbers printed say which pairs the font has an opinion about and what it says, in the font's
//     own design units, so the picture can be checked against the font rather than believed.
//
// The word is chosen for pairs the font actually kerns hard. A font's kerning lives in its diagonals:
// A over V, T over o, Y over o, F over A. Kerning a word with no diagonal in it shows nothing.
module main

import math
import vtext
import corpus
import paint
import vtext.layout
import vtext.shape

// Two sets that both cover Latin, Cyrillic and Arabic, and differ in how hard they kern.
//
// Amiri kerns Latin and Arabic; Noto Naskh kerns Latin but not Arabic; FiraCode kerns nothing
// (monospace, only cpsp). The sizes differ too, and that is the second thing to read off the picture:
// two fonts of the same point size are not the same size, so a line that looks bigger in one of them
// is the font's doing.

// A Latin pair the first set kerns and the second does not, and a Cyrillic pair neither kerns
// (FiraCode is monospace): the discretionary difference and the honest null, both on base glyphs.
// Arabic kerns address shaped forms, not base letters, so that pair is probed from the laid-out
// line below rather than from the cmap. The Arabic word is مدرسة because Amiri names a rule on
// one of its joins (with value zero: a rule saying "no adjustment" is still a rule) while Naskh
// names none at all, which is exactly the has_kerning distinction drawn above.
const word = 'AV АВ مدرسة'

// The pairs to report, each with the script it resolves under. These are the numbers fontTools reads
// out of these files, so the printing can be checked against the fonts rather than believed.
const pairs = [
	Pair{
		left:   'A'
		right:  'V'
		script: 'latn'
	}
	Pair{
		left:   'А'
		right:  'В'
		script: 'cyrl'
	},
]

// Pair is one pair of letters, the script it resolves under, and where the font has an opinion about it.
struct Pair {
	left   string
	right  string
	script string
}

const em_px = 90.0
const margin = 30
const row_gap = 60.0

// The advance rules and the box around them are drawn faintly enough to read the letter through.
const rule_level = u8(205)

fn main() {
	ctx := shape.new_context()
	amiri := shape.load_font_file(corpus.font('Amiri-Regular.ttf')) or { panic('cannot open ${err}') }
	naskh := shape.load_font_file(corpus.font('NotoNaskhArabic-Regular.ttf')) or { panic('cannot open ${err}') }
	fira := shape.load_font_file(corpus.font('FiraCode-Variable.ttf')) or { panic('cannot open ${err}') }
	// First covering wins: Latin and Cyrillic come from FiraCode in neither set here, Arabic from Amiri
	// in the first and from Naskh in the second. Amiri kerns both scripts, Naskh only Latin.
	kerned_fs := shape.new_font_set_of(amiri, fira)
	plain_fs := shape.new_font_set_of(fira, naskh)

	// What the fonts say about themselves, printed because the picture only means something next to
	// it: a difference in the spacing is a difference in the font, not in the engine.
	println('${word}')
	println('')
	println('amiri: kerns latin = ${amiri.kerns('latn', '')}   arab = ${amiri.kerns('arab', '')}')
	println('naskh: kerns latin = ${naskh.kerns('latn', '')}   arab = ${naskh.kerns('arab', '')}')
	println('fira:  kerns latin = ${fira.kerns('latn', '')}   arab = ${fira.kerns('arab', '')}')
	println('')
	for p in pairs {
		l := p.left.runes()[0]
		r := p.right.runes()[0]
		lf := kerned_fs.pick(l) or { amiri }
		rf := kerned_fs.pick(r) or { amiri }
		f := if lf.path() == rf.path() { lf } else { lf }
		k := f.kern_offset(f.glyph_index(l), f.glyph_index(r), p.script, '')
		pf := plain_fs.pick(l) or { fira }
		u := pf.kern_offset(pf.glyph_index(l), pf.glyph_index(r), p.script, '')
		// The value as a plain number, because an Option printed across four lines is not something a
		// reader can compare down a column.
		mut ks := 'none'
		if k != none {
			got := k
			ks = '${got.x}'
		}
		mut us := 'none'
		if u != none {
			got := u
			us = '${got.x}'
		}
		println('  ${p.left}${p.right} (${p.script}): kerned ${ks:>7}   plain ${us:>7}')
	}

	// Lay the word out in both sets first: the lines size the canvas, and the kerned line
	// supplies the shaped Arabic pair below.
	kerned_line := layout.layout_paragraph(ctx, word.runes(), .auto, kerned_fs, em_px)
	plain_line := layout.layout_paragraph(ctx, word.runes(), .auto, plain_fs, em_px)
	mut widest := 0.0
	mut ascent := 0.0
	mut descent := 0.0
	for line in [kerned_line, plain_line] {
		if line.width > widest {
			widest = line.width
		}
		if line.ascent > ascent {
			ascent = line.ascent
		}
		if line.descent > descent {
			descent = line.descent
		}
	}
	println('  ${word}: kerned width ${kerned_line.width:.2f}   plain width ${plain_line.width:.2f}')
	// The Arabic probe on shaped glyphs: the first adjacent same-font pair of each laid-out
	// line, asked of its own font. Base letters name no Arabic kern in these faces; the joins
	// do, and the joins only exist after shaping, so the cmap cannot supply this pair.
	println('  shaped arab pair: kerned ${shaped_kern(kerned_line, amiri):>7}   plain ${shaped_kern(plain_line, naskh):>7}')
	canvas_w := int(widest) + 2 * margin
	canvas_h := int((ascent + descent + row_gap) * 2.0) + 2 * margin + 24

	mut canvas := paint.new_canvas(canvas_w, canvas_h, 0xff)
	mut baseline := f64(margin) + ascent
	for line in [kerned_line, plain_line] {
		draw_row(mut canvas, line, baseline, ascent, descent)
		baseline += ascent + descent + row_gap
	}

	canvas.write_png('kerning.png')
}

// shaped_kern asks a font about the adjacent same-font pairs of a laid-out line: the pairs
// whose glyphs the shaper actually put next to each other, which for Arabic are shaped forms
// the cmap never names. The first firing rule wins; a zero value is reported as 0 (a rule saying
// "no adjustment" is still a rule, and different from no rule), and no firing rule is 'none'.
fn shaped_kern(line layout.Line, f &shape.Font) string {
	mut fired := false
	for i in 0 .. line.glyphs.len - 1 {
		a := line.glyphs[i]
		b := line.glyphs[i + 1]
		fa := a.font or { continue }
		fb := b.font or { continue }
		if fa.path() != f.path() || fb.path() != f.path() {
			continue
		}
		if a.advance <= 0 || b.advance <= 0 {
			continue
		}
		if k := f.kern_offset(a.gid, b.gid, 'arab', '') {
			if k.x != 0 || k.y != 0 {
				return '${k.x},${k.y}'
			}
			fired = true
		}
	}
	if fired {
		return '0'
	}
	return 'none'
}

// draw_row paints one line of the word with each glyph's advance ruled.
//
// The rules are the point. A kern changes an advance, so a pair that is kerned has a rule shorter than
// the letters either side of it, and that is the only way to see a kern rather than assert one: the ink
// of two adjacent letters looks the same either way and only the pen moves.
//
// The pen is marked with a full-height line and the advance with a short one at the foot, so the three
// things a reader needs to tell apart are three different marks: where the pen was, where it went, and
// how far it moved.
fn draw_row(mut canvas paint.Canvas, line layout.Line, baseline f64, ascent f64,
	descent f64) {
	for g in line.glyphs {
		f := g.font or { continue }
		canvas.draw_glyph_at(f, g, baseline, em_px, f64(margin))
	}
	baseline_i := int(baseline)
	pen_top := baseline_i - int(ascent)
	pen_bottom := baseline_i + int(descent)
	// The foot rule where the advances are measured from.
	foot := baseline_i + int(descent) + 14
	for g in line.glyphs {
		x := int(math.floor(g.x)) + margin
		w := int(math.round(g.advance))
		// The advance, as a short rule at the foot, one per glyph.
		canvas.rect(x, foot, x + w, foot + 3, rule_level)
	}
	// The pen at each glyph's own origin, and at the end of the line, so a rule has both of its ends.
	mut seen := map[int]bool{}
	for g in line.glyphs {
		x := int(math.floor(g.x)) + margin
		if !seen[x] {
			seen[x] = true
			canvas.vline(x, pen_top, pen_bottom, rule_level)
		}
	}
	canvas.vline(int(math.floor(line.width)) + margin, pen_top, pen_bottom, rule_level)
	// The word's two ends, so the line's own extent is drawn rather than inferred.
	canvas.vline(margin, pen_top, pen_bottom, rule_level)
}
