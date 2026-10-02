module main

// shapetrace prints the pipeline for one string, step by step.
//
// Every debugging session on this engine ended by writing a version of this and reading it, so it exists.
// The stages are called separately rather than by instrumenting layout_paragraph, because a trace that can
// only be produced by adding print statements to the pipeline cannot be run against a build that is not
// being debugged, and because the whole value of a trace is stopping between stages and comparing.
//
// What it prints, and the question each stage answers:
//
//	input         the text as given, with its properties: bidi class, joining type, script
//	normalize     what UAX#15 did, and what it did to the indices
//	bidi          the paragraph level, the levels per character, and the visual order
//	shape         the joining form of each letter, and the codepoint the shape produced
//	fonts         which font each character came from, and the glyph index it became
//	substitute    which feature rule fired and what it replaced
//	position      which positioning rule answered and with what offset
//	marks         which mark attached to which base, and how far it moved
//
// Every stage says when it did nothing. A trace that only prints what changed is useless on the runs that
// matter, because the runs that matter are the ones where nothing changed and the question is why.
//
// The tables come from the UCD under ucd/ via tools/fetch_ucd.ps1 and are not committed.
//
// Usage:
//	v run tools/shapetrace.v <font.ttf> <text>
//	v run tools/shapetrace.v --fonts a.ttf,b.ttf <text>
//
// Without --fonts the single font is used for everything, which is the right way to read a trace: the
// font is not the variable being investigated. With --fonts the set is per script, so a Latin font and a
// naskh font can be told apart and the seam between them is visible.

import os
import vtext

// name_of_cp is a codepoint as a name when the UCD has one and as a hex value when it does not. The
// fallback matters: a trace full of U+FB50 says less than a trace that says LAM WITH ALEF, and the
// codepoints this prints are presentation forms, most of which no reader has in their head.
fn name_of_cp(cp rune) string {
	return vtext.codepoint_name(cp)
}

fn show_codepoints(label string, cps []rune) {
	mut parts := []string{cap: cps.len}
	for cp in cps {
		parts << 'U+${u32(cp):04X}(${name_of_cp(cp)})'
	}
	println('  ${label}: ${parts.join(' ')}')
}

fn main() {
	// The first argument is always the font, and everything after it is the text. That is simpler than a
	// flag parser and it is what the usage line says, and the earlier version treated the first argument as
	// text and so printed the usage message for every invocation.
	args := os.args[1..]
	if args.len < 2 {
		println('usage: v run tools/shapetrace.v <font.ttf> <text>')
		println('       v run tools/shapetrace.v --fonts a.ttf,b.ttf <text>')
		exit(1)
	}
	mut font_paths := []string{}
	mut text := ''
	if args[0] == '--fonts' {
		if args.len < 3 {
			println('--fonts needs at least a font list and some text')
			exit(1)
		}
		font_paths = args[1].split(',')
		text = args[2..].join(' ')
	} else {
		font_paths = [args[0]]
		text = args[1..].join(' ')
	}
	mut fonts := []&vtext.Font{}
	for p in font_paths {
		fonts << vtext.load_font_file(p) or { panic('cannot open ${p}: ${err}') }
	}
	if text == '' {
		println('usage: v run tools/shapetrace.v <font.ttf> <text>')
		exit(1)
	}

	ctx := vtext.new_context()
	fs := if fonts.len == 1 {
		vtext.new_font_set_of(fonts[0])
	} else {
		vtext.new_script_font_set(fonts[1], fonts[0])
	}

	cps := text.trim_right(' ').runes()
	println('text "${text}"')
	println('')

	// 1. Input, with the properties every later stage keys on. A joining type that is wrong here explains
	// a wrong shape at the end, so this stage exists to be checked first.
	println('1. input')
	for cp in cps {
		joining := vtext.joining_type_name(ctx, cp)
		script := ctx.properties.script_tag_of(cp)
		bidi := ctx.properties.bidi_class_name(cp)
		println('  U+${u32(cp):04X} ${name_of_cp(cp)}  script=${script} joining=${joining} bidi=${bidi}')
	}
	println('')

	// 2. Normalization. The indices matter as much as the codepoints: a precomposed character becomes
	// several, and a mark written after another mark is reordered ahead of it.
	println('2. normalize (UAX#15 canonical decomposition)')
	normalized := ctx.normalize_nfd(cps)
	show_codepoints('decomposed', normalized)
	mut mark_moves := 0
	for i in 0 .. normalized.len {
		if normalized[i] != cps[i] {
			mark_moves++
		}
	}
	if mark_moves == 0 {
		println('  nothing changed: every character had a single canonical form already')
	} else {
		println('  ${normalized.len} codepoints from ${cps.len}: something decomposed or reordered')
	}
	println('')

	// 3. Bidi, which decides the order the line is drawn in and therefore what "to the left of" means
	// for every stage after it.
	println('3. bidi (UAX#9)')
	bidi := vtext.resolve_bidi(ctx, normalized, .auto)
	println('  paragraph level ${bidi.paragraph_level}, ${bidi.sequences.len} run sequence(s)')
	mut levels := []string{cap: normalized.len}
	for c in bidi.levels {
		levels << '${c}'
	}
	println('  levels   ${levels.join(' ')}')
	println('  visual order:')
	println('    ${bidi.visual_string(normalized)}')
	println('')

	// 4. Joining, which is where a letter gets its shape.
	println('4. shape (UAX#53 joining)')
	mut run := ctx.shape_for_trace(normalized)
	for g in run.glyphs {
		mut tags := []string{}
		tags << 'form=${g.form}'
		if g.is_mark {
			tags << 'mark'
		}
		println('  U+${u32(g.base[0]):04X} ${name_of_cp(g.base[0])} -> ${tags.join(' ')} cps=${g.cps.len}')
		show_codepoints('    form codepoints', g.cps)
	}
	println('')

	// 5. Fonts and glyphs. This is where a trace says which font answered, which the eye cannot.
	println('5. fonts and glyphs')
	line := vtext.layout_paragraph(ctx, normalized, .auto, fs, 32.0)
	mut by_font := map[string][]int{}
	for g in line.glyphs {
		mut key := 'none'
		if f := g.font {
			key = f.path()
		}
		by_font[key] << int(g.gid)
	}
	for key, gids in by_font {
		println('  ${key} drew ${gids.len} glyph(s): gids ${gids}')
	}
	println('')

	// 6 and 7. Positioning, per glyph pair and per mark. The offset is in pixels at the size asked for,
	// and a zero offset is printed as zero rather than omitted, because "nothing moved" is an answer.
	println('6. position')
	mut moved := 0
	for i, g in line.glyphs {
		f := g.font or { continue }
		if g.advance == 0.0 {
			// A mark: ask the font where it belongs rather than where the pen went.
			mut base_idx := -1
			for j in 0 .. i {
				if line.glyphs[j].advance > 0.0 {
					base_idx = j
				}
			}
			if base_idx >= 0 {
				base := line.glyphs[base_idx]
				bf := base.font or { continue }
				off := bf.mark_offset(g.gid, base.gid, base.is_mark) or {
					println('  mark gid ${g.gid} over base ${base.gid}: no rule')
					continue
				}
				moved++
				println('  mark gid ${g.gid} over base ${base.gid}: dx=${off.x}d dy=${off.y}d design units')
			}
			continue
		}
		if i + 1 < line.glyphs.len {
			next := line.glyphs[i + 1]
			nf := next.font or { continue }
			if off := f.kern_offset(g.gid, next.gid, 'arab') {
				moved++
				println('  pair ${g.gid} ${next.gid}: dx=${off.x}d dy=${off.y}d design units')
			}
		}
	}
	if moved == 0 {
		println('  nothing moved: no mark rule matched and no kern pair matched')
	}
	println('')

	println('result: ${line.glyphs.len} glyphs, width ${line.width:.3f}, ${line.ascent:.3f} above and ${line.descent:.3f} below the baseline')
}
