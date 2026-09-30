module vtext

// Verifies that one Context serves the whole pipeline, and that the tables it holds
// are shared rather than rebuilt per call. Normalization and bidi lookups are the two
// places a caller is most likely to build their own tables by mistake.

// runes_of reads a column of codepoints written the way the UCD writes one. A non-ASCII
// character written literally makes the C backend emit a broken initialiser for a
// []rune, so the test data stays in hex.
fn runes_of(fields []string) []rune {
	mut out := []rune{}
	for f in fields {
		out << rune(hex_value(f))
	}
	return out
}

// cps_to_string renders a codepoint sequence so a failure can be read against the hex
// the test data is written in.
fn cps_to_string(cps []rune) string {
	mut parts := []string{cap: cps.len}
	for c in cps {
		parts << '${u32(c):04X}'
	}
	return parts.join(' ')
}

fn test_context_holds_real_tables() {
	ctx := new_context()
	assert ctx.properties.combining_ranges.len > 200, 'the context should hold real tables'
	assert ctx.normalizer.decompositions.len > 1000, 'the normalizer should hold real tables'
	assert ctx.normalizer.nfd_no.len > 100, 'the NFD quick check set should be populated'
	assert ctx.normalizer.nfc_no.len > 10, 'the NFC quick check set should be populated'
}

fn test_context_normalizes_arabic_text() {
	ctx := new_context()
	// Arabic text has no canonical decompositions, so NFD is the identity and NFC has
	// nothing to compose. This is the shape of the string the shaper will be handed
	// most of the time, and it must not allocate in the common path.
	persian := runes_of(['0633', '0644', '0627', '0645'])
	decomposed := ctx.normalizer.nfd(persian)
	assert decomposed.len == persian.len, 'Arabic should not decompose'
	for i, cp in persian {
		assert decomposed[i] == cp, 'Arabic should pass through unchanged'
	}
	composed := ctx.normalizer.nfc(persian)
	assert composed.len == persian.len, 'Arabic should not compose'
}

fn test_context_normalizes_latin_with_marks() {
	ctx := new_context()
	// e + combining acute, which is what a text source that does not normalize emits.
	src := runes_of(['0065', '0301'])
	assert cps_to_string(ctx.normalizer.nfc(src)) == '00E9'
	// And the precomposed form has to come apart again, which is the direction the
	// Arabic shaper needs: a font's cmap rarely maps the precomposed character.
	assert cps_to_string(ctx.normalizer.nfd(runes_of(['00E9']))) == '0065 0301'
}

fn test_context_resolves_a_bidi_paragraph() {
	ctx := new_context()
	// The bidi rules need the property tables the context holds, so this is the
	// integration point between the two halves of the module.
	persian := runes_of(['0633', '0644', '0627', '0645'])
	res := resolve_paragraph(ctx.properties, persian, .auto)
	assert res.paragraph_level == 1, 'Arabic text should resolve to an RTL paragraph'
	for l in res.levels {
		assert l == 1, 'pure Arabic should be all level 1'
	}
}

// A Persian phrase with a Latin word and digits, which is the shape that actually
// breaks: the levels have to split into a run and its surroundings, and the run has to
// come back out the other way up in the visual order.
fn test_context_bidi_mixed_script_paragraph() {
	ctx := new_context()
	mixed := runes_of(['0633', '0644', '0627', '0645', '0020', '0061', '0062', '0020', '0031',
		'0032', '0033'])
	res := resolve_paragraph(ctx.properties, mixed, .auto)
	assert res.paragraph_level == 1, 'the first strong character is Arabic, so RTL'
	// The Arabic and the space after it stay on the paragraph level.
	for i in 0 .. 5 {
		assert res.levels[i] == 1, 'the Arabic run should stay at level 1'
	}
	// The Latin word, the space after it and the digits are one left-to-right island at
	// level 2.
	for i in 5 .. mixed.len {
		assert res.levels[i] == 2, 'the Latin island should be level 2'
	}
	// L2 reverses the line, so the island lands at the left edge in logical order.
	mut seen := 0
	for visual_index, logical_index in res.visual_order {
		if res.levels[logical_index] == 2 {
			assert visual_index == seen, 'the island should be contiguous at the left'
			seen++
		}
	}
	assert seen == mixed.len - 5, 'every character of the island should be drawn'
}
