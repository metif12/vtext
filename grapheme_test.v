module vtext

import os
import vtext.layout
import vtext.shape

// Tests for the UAX #29 grapheme cluster engine in layout/graphemes.v.
// The committee's own GraphemeBreakTest.txt runs as a floor the way the
// word and sentence files run in wordbreak_test.v; the log-attr pass in
// layout/logattr.v answers cursors from these same decisions.

// grapheme_conformance_floor is the grapheme score this tree must not fall
// below: the whole file, like the word and sentence floors.
const grapheme_conformance_floor = 853

fn gb_font_ctx() &shape.Context {
	return shape.new_context()
}

// gb_parse_case reads one GraphemeBreakTest-shaped line: ÷/× decisions with
// the codepoints between them, the comment after # dropped.
fn gb_parse_case(line string) ([]rune, []bool) {
	mut cps := []rune{}
	mut breaks := []bool{}
	for f in line.all_before('#').fields() {
		if f == '÷' || f == '×' {
			breaks << (f == '÷')
		} else {
			mut v := 0
			for ch in f {
				mut d := ch - `0`
				if d > 9 {
					d = ch - `a` + 10
				}
				if d > 15 {
					d = ch - `A` + 10
				}
				v = v * 16 + int(d)
			}
			cps << rune(v)
		}
	}
	return cps, breaks
}

fn test_grapheme_breaking_conformance_against_the_unicode_test() {
	ctx := gb_font_ctx()
	content := os.read_file(os.join_path('ucd', 'GraphemeBreakTest.txt')) or {
		panic('cannot read ucd/GraphemeBreakTest.txt: ${err.msg()}')
	}
	mut total := 0
	mut passed := 0
	for line in content.split_into_lines() {
		trimmed := line.trim_space()
		if trimmed == '' || trimmed.starts_with('#') {
			continue
		}
		cps, want := gb_parse_case(trimmed)
		if cps.len == 0 {
			continue
		}
		total++
		got := layout.grapheme_breaks(ctx, cps, layout.GraphemeOpts{})
		mut ok := got.len == want.len
		if ok {
			for i, w in want {
				if got[i] != w {
					ok = false
					break
				}
			}
		}
		if ok {
			passed++
		}
	}
	assert total == 853, 'the whole test file was read, got ${total} cases'
	println('UAX #29 grapheme conformance: ${passed}/${total}')
	assert passed >= grapheme_conformance_floor, 'conformance fell below the floor: ${passed} of ${total}, floor ${grapheme_conformance_floor}'
}

// Neutering GB9 must break the Extend hold: a combining mark parts from its
// base, and the full-file score falls under the floor.
fn test_grapheme_conformance_needs_gb9() {
	ctx := gb_font_ctx()
	cps := [rune(0x0061), rune(0x0308), rune(0x0062)]
	joined := layout.grapheme_breaks(ctx, cps, layout.GraphemeOpts{})
	assert joined == [true, false, true, true], 'GB9 holds the mark to its base (the mark still parts from what follows it)'
	neutered := layout.grapheme_breaks(ctx, cps, layout.GraphemeOpts{ skip_gb9: true })
	assert neutered == [true, true, true, true], 'without GB9 the mark parts from its base'
	content := os.read_file(os.join_path('ucd', 'GraphemeBreakTest.txt')) or {
		panic('cannot read ucd/GraphemeBreakTest.txt: ${err.msg()}')
	}
	mut total := 0
	mut passed := 0
	for line in content.split_into_lines() {
		trimmed := line.trim_space()
		if trimmed == '' || trimmed.starts_with('#') {
			continue
		}
		c, want := gb_parse_case(trimmed)
		if c.len == 0 {
			continue
		}
		total++
		got := layout.grapheme_breaks(ctx, c, layout.GraphemeOpts{ skip_gb9: true })
		mut ok := got.len == want.len
		if ok {
			for i, w in want {
				if got[i] != w {
					ok = false
					break
				}
			}
		}
		if ok {
			passed++
		}
	}
	assert passed < grapheme_conformance_floor, 'neutering GB9 must move the score: ${passed}/${total}'
}

// Spot pins beside the rules that have no committee line of their own:
// CR×LF holds, a control parts, Hangul LV holds to T, Prepend holds, and a
// ZWJ emoji sequence stays one cluster.
fn test_grapheme_spot_pins() {
	ctx := gb_font_ctx()
	assert layout.grapheme_breaks(ctx, [rune(0x000D), rune(0x000A)], layout.GraphemeOpts{}) == [
		true,
		false,
		true,
	], 'GB3 holds CR LF'
	assert layout.grapheme_breaks(ctx, [rune(0x0061), rune(0x0007)], layout.GraphemeOpts{}) == [
		true,
		true,
		true,
	], 'GB5 parts before a control'
	assert layout.grapheme_breaks(ctx, [rune(0xAC00), rune(0x11A8)], layout.GraphemeOpts{}) == [
		true,
		false,
		true,
	], 'GB7 holds LV T'
	assert layout.grapheme_breaks(ctx, [rune(0x0600), rune(0x0061)], layout.GraphemeOpts{}) == [
		true,
		false,
		true,
	], 'GB9b holds Prepend'
	assert layout.grapheme_breaks(ctx, [rune(0x1F468), rune(0x200D), rune(0x1F469)], layout.GraphemeOpts{}) == [
		true,
		false,
		false,
		true,
	], 'GB11 holds the ZWJ emoji sequence'
	assert layout.grapheme_breaks(ctx, [rune(0x1F1E6), rune(0x1F1E7), rune(0x1F1E8)], layout.GraphemeOpts{}) == [
		true,
		false,
		true,
		true,
	], 'GB12/13 pair the flag run'
}
