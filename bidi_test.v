module vtext

import os

// The UAX#9 conformance test. BidiCharacterTest.txt is the normative test data:
// every line is a paragraph with its expected paragraph level, resolved levels and
// visual order. Running all of it is the only way to know the implementation is
// right, so this is not a sample.
//
// The file is fetched by tools/fetch_ucd.ps1 and is not committed.

const bidi_test_file = 'ucd/BidiCharacterTest.txt'

// BidiCase is one line of the conformance data.
struct BidiCase {
	cps []rune
	dir Direction
	// want_para is the expected paragraph level.
	want_para u8
	// want_levels holds the expected level per character, or -1 for the
	// characters rule X9 removed, which the data marks with an 'x'.
	want_levels []int
	// want_order lists the visual order, excluding the X9-removed characters.
	want_order []int
	// text is the input, for failure messages.
	text string
}

fn parse_bidi_case(line string) ?BidiCase {
	fields := line.split(';')
	if fields.len < 5 {
		return none
	}
	mut cps := []rune{}
	mut text_parts := []string{cap: 16}
	for tok in fields[0].trim_space().split(' ') {
		if tok == '' {
			continue
		}
		cps << rune(hex_value(tok))
		text_parts << '${rune(hex_value(tok)):04X}'
	}
	mut want_levels := []int{len: cps.len, init: 0}
	mut lf := 0
	for tok in fields[3].trim_space().split(' ') {
		if lf >= want_levels.len {
			break
		}
		if tok == 'x' {
			want_levels[lf] = -1
		} else if tok != '' {
			want_levels[lf] = int(tok.i64())
		}
		lf++
	}
	mut want_order := []int{}
	for tok in fields[4].trim_space().split(' ') {
		if tok != '' {
			want_order << int(tok.i64())
		}
	}
	mut dir := Direction.auto
	match fields[1].trim_space() {
		'0' {
			dir = .ltr
		}
		'1' {
			dir = .rtl
		}
		else {}
	}
	return BidiCase{
		cps:         cps
		dir:         dir
		want_para:   u8(fields[2].trim_space().i64())
		want_levels: want_levels
		want_order:  want_order
		text:        text_parts.join(' ')
	}
}

fn levels_to_string(levels []u8) string {
	mut parts := []string{cap: levels.len}
	for l in levels {
		parts << '${l}'
	}
	return parts.join(' ')
}

fn ints_to_string(v []int) string {
	mut parts := []string{cap: v.len}
	for x in v {
		parts << '${x}'
	}
	return parts.join(' ')
}

// check_case reports why a case failed, or an empty string when it passed.
fn check_case(p &Properties, c BidiCase) string {
	got := resolve_paragraph(p, c.cps, c.dir)
	mut reasons := []string{}

	if int(got.paragraph_level) != int(c.want_para) {
		reasons << 'paragraph level: got ${got.paragraph_level} want ${c.want_para}'
	}

	// Levels. A position marked 'x' in the data must be one X9 removed, and a
	// position with a level must not be.
	mut got_levels := []int{len: c.cps.len, init: 0}
	for i in 0 .. c.cps.len {
		if got.visible[i] {
			got_levels[i] = int(got.levels[i])
		} else {
			got_levels[i] = -1
		}
	}
	if got_levels != c.want_levels {
		reasons << 'levels: got ${ints_to_string(got_levels)}'
		reasons << '        want ${ints_to_string(c.want_levels)}'
	}

	// Visual order, with the X9-removed characters dropped.
	mut got_order := []int{cap: c.want_order.len}
	for i in got.visual_order {
		if got.visible[i] {
			got_order << i
		}
	}
	if got_order != c.want_order {
		reasons << 'order: got ${ints_to_string(got_order)}'
		reasons << '       want ${ints_to_string(c.want_order)}'
	}

	if reasons.len == 0 {
		return ''
	}
	mut out := 'UAX#9 case [${c.text}] dir=${c.dir} failed:\n'
	for r in reasons {
		out += '  ${r}\n'
	}
	return out
}

fn test_ucd_bidi_conformance() {
	if !os.exists(bidi_test_file) {
		println('skipping ${bidi_test_file}: run tools/fetch_ucd.ps1 to get the UCD')
		return
	}
	p := new_properties()
	data := os.read_file(bidi_test_file) or { panic(err) }

	mut checked := 0
	mut failures := 0
	mut reported := 0
	max_reported := 20
	for line in data.split_into_lines() {
		s := line.trim_space()
		if s == '' || s[0] == `#` {
			continue
		}
		c := parse_bidi_case(s) or { continue }
		checked++
		reason := check_case(p, c)
		if reason == '' {
			continue
		}
		failures++
		if reported < max_reported {
			reported++
			println(reason)
		}
	}
	println('UAX#9 conformance: ${checked} cases, ${failures} failed')
	assert failures == 0, '${failures} of ${checked} UAX#9 cases failed'
}

fn test_bidi_known_paragraphs() {
	p := new_properties()
	// A pure Persian sentence: one level, right to left.
	persian := 'سلام دنیا'.runes()
	rtl := resolve_paragraph(p, persian, .auto)
	assert rtl.paragraph_level == 1, 'Persian should resolve to an RTL paragraph'
	for l in rtl.levels {
		assert l == 1, 'pure Persian text should be all level 1'
	}
	// Visual order is the reverse of logical order.
	for i in 0 .. persian.len {
		assert rtl.visual_order[i] == persian.len - 1 - i, 'RTL should reverse'
	}

	// A Latin sentence stays left to right.
	latin := 'hello world'.runes()
	ltr := resolve_paragraph(p, latin, .auto)
	assert ltr.paragraph_level == 0
	for l in ltr.levels {
		assert l == 0, 'pure Latin text should be all level 0'
	}

	// Persian with a Latin word and digits: everything after the first space is one
	// level-2 run, which rule L2 leaves alone, so it reads left to right inside the
	// right-to-left paragraph.
	mixed := 'سلام vlang 123'.runes()
	res := resolve_paragraph(p, mixed, .auto)
	assert res.paragraph_level == 1
	// 'سلام' is Arabic and stays on the paragraph level.
	for i in 0 .. 4 {
		assert res.levels[i] == 1, 'Arabic should stay on the paragraph level'
	}
	// The space after it is a neutral between R and L, so N2 gives it the embedding
	// direction and it stays on the paragraph level too.
	assert res.levels[4] == 1, 'the neutral after the Arabic word should stay at level 1'
	// 'vlang 123' is L plus numbers that W7 turns into L, so the whole tail is one
	// level-2 run.
	mut run := []int{}
	for i in 5 .. mixed.len {
		assert res.levels[i] == 2, 'the Latin tail should be level 2'
		run << i
	}
	// L2 reverses the line but leaves a level-2 run in logical order, so the tail
	// comes out at the left edge of the line, contiguous and left to right.
	mut at := 0
	for visual_index, logical_index in res.visual_order {
		if logical_index in run {
			assert visual_index == at, 'the level 2 run should be contiguous at the left'
			at++
		}
	}
	assert at == run.len, 'every member of the run should be drawn'
}

fn test_bidi_empty_and_single() {
	p := new_properties()
	empty := resolve_paragraph(p, []rune{}, .auto)
	assert empty.levels.len == 0
	assert empty.visual_order.len == 0

	one := resolve_paragraph(p, [rune(`a`)], .auto)
	assert one.paragraph_level == 0
	assert one.levels[0] == 0
	assert one.visual_order[0] == 0

	// A lone Arabic letter makes the paragraph right to left.
	arabic := resolve_paragraph(p, [rune(0x0628)], .auto)
	assert arabic.paragraph_level == 1
}

fn test_bidi_bracket_table_parses() {
	b := bracket_table()
	assert b.len > 100, 'bracket table looks truncated'
	// A parenthesis is an opening bracket that pairs with a closing one.
	open := b.find(u32(0x0028)) or { panic('LEFT PARENTHESIS missing') }
	assert open.kind == bracket_open
	assert open.paired == 0x0029
	// The table has to be sorted for the binary search to work.
	for i in 1 .. b.len {
		assert b[i].cp > b[i - 1].cp, 'bracket table is not sorted at ${i}'
	}
}

// BD16 compares brackets through their canonical equivalents, which is what lets
// U+2329 pair with U+3009 even though BidiBrackets.txt only records it with U+232A.
fn test_bidi_bracket_canonical_equivalence() {
	b := bracket_table()
	angle := b.find(u32(0x2329)) or { panic('U+2329 missing') }
	assert angle.kind == bracket_open, 'U+2329 is an opening bracket'
	assert angle.paired == 0x232a, 'BidiBrackets records U+2329 with U+232A'
	assert angle.canonical == 0x3008, 'U+2329 canonically decomposes to U+3008'
	// U+3009 is the canonical equivalent of U+232A, so both it and U+232A close a
	// pair opened by U+2329.
	assert b.same_bracket(angle, 0x3009), 'U+2329 should pair with U+3009'
	assert b.same_bracket(angle, 0x232a), 'U+2329 should pair with U+232A'
	// Symmetrically, U+3008 opens for U+232A as well as for U+3009.
	open := b.find(u32(0x3008)) or { panic('U+3008 missing') }
	assert b.same_bracket(open, 0x3009)
	assert b.same_bracket(open, 0x232a)
	// But it must not close with an unrelated bracket.
	assert !b.same_bracket(open, 0x0029), 'U+3008 should not pair with a parenthesis'
}

// The two angle-bracket spellings have to resolve as one pair, which is the whole
// point of the canonical equivalence above.
fn test_bidi_bracket_canonical_pair_resolves() {
	p := new_properties()
	// U+2329 opens, U+3009 closes, and the only strong type inside is Latin. In a
	// left-to-right paragraph N0 gives the pair that direction.
	span := 'a\u2329b\u3009c'.runes()
	res := resolve_paragraph(p, span, .ltr)
	assert res.levels[1] == 0, 'the opener should take the surrounding L direction'
	assert res.levels[3] == 0, 'the closer should take the surrounding L direction'
}
