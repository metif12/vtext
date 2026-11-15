module vtext

import os
import vtext.font
import vtext.shape

// Tests for the MATH slice: the MATH table behind an opt-in pass,
// pinned against HarfBuzz (uharfbuzz 0.56.2) and fontTools (4.66.1) on the
// two committed math faces.
//
// Every number below was measured first with those two readers before it
// was written here; agreement with them is the evidence. The faces ship in
// testdata/fonts with their licence texts, so they load on every platform
// with no skips: STIX Two Math under the OFL, Latin Modern Math under the
// GUST Font License (an LPPL instance, not the OFL, which is why its text
// is GFL-LatinModernMath.txt and not OFL-*).

// math_face_path is where a committed math face is: the corpus first, an
// override directory second, and none when neither has it. This copy lives
// here because `v test <single_file>` compiles that file and not its
// siblings, so a helper in another test file is one this file cannot see.
fn math_face_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('VTEXT_TEST_FONTS'), 'testdata/fonts'] {
		if d != '' && d !in dirs {
			dirs << d
		}
	}
	for dir in dirs {
		p := os.join_path(dir, name)
		if os.exists(p) {
			return p
		}
	}
	return none
}

fn math_face(name string) &shape.Font {
	p := math_face_path(name) or { panic('${name} is not in testdata/fonts') }
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

fn math_table_data(name string) []u8 {
	p := math_face_path(name) or { panic('${name} is not in testdata/fonts') }
	data := os.read_bytes(p) or { panic('${p} is not readable: ${err}') }
	sfnt := font.parse_sfnt(data) or { panic('${p} is not an sfnt: ${err}') }
	assert sfnt.has(font.tag_math), '${name} carries no MATH table'
	return sfnt.table_data(font.tag_math)
}

fn math_pass_for(name string, enabled bool) shape.MathPass {
	bytes := math_table_data(name)
	f := math_face(name)
	return shape.new_math_pass(bytes, f.units_per_em(), enabled) or {
		panic('${name} MATH does not parse')
	}
}

// math_close compares two pixel values with room for one rounding of the
// last bit: design-unit math scaled twice can differ by a ulp.
fn math_close(a f64, b f64) bool {
	d := a - b
	dd := if d < 0 { -d } else { d }
	return dd < 1e-9
}

fn test_math_constants_match_harfbuzz() {
	stix := math_pass_for('STIXTwoMath-Regular.ttf', true)
	assert stix.units(.script_percent_scale_down) == 70
	assert stix.units(.script_script_percent_scale_down) == 55
	assert stix.units(.delimited_sub_formula_min_height) == 1325
	assert stix.units(.display_operator_min_height) == 1800
	assert stix.units(.math_leading) == 150
	assert stix.units(.axis_height) == 258
	assert stix.units(.fraction_rule_thickness) == 68
	assert stix.units(.subscript_shift_down) == 210
	assert stix.units(.superscript_shift_up) == 360
	assert stix.units(.radical_kern_after_degree) == -335
	assert stix.units(.radical_degree_bottom_raise_percent) == 55
	lm := math_pass_for('LatinModernMath-Regular.otf', true)
	assert lm.units(.script_percent_scale_down) == 70
	assert lm.units(.script_script_percent_scale_down) == 50
	assert lm.units(.delimited_sub_formula_min_height) == 1300
	assert lm.units(.display_operator_min_height) == 1300
	assert lm.units(.math_leading) == 154
	assert lm.units(.axis_height) == 250
	assert lm.units(.fraction_rule_thickness) == 40
	assert lm.units(.subscript_shift_down) == 247
	assert lm.units(.superscript_shift_up) == 363
	assert lm.units(.radical_kern_after_degree) == -556
	assert lm.units(.radical_degree_bottom_raise_percent) == 60
}

fn test_math_glyph_ids_agree_with_harfbuzz() {
	// The reader keys everything on glyph ids, so the cmap those ids come
	// from must resolve the same codepoints HarfBuzz measured.
	stix := math_face('STIXTwoMath-Regular.ttf')
	assert stix.glyph_index(rune(0x0028)) == 1064
	assert stix.glyph_index(rune(0x2211)) == 1646
	assert stix.glyph_index(rune(0x222B)) == 1698
	assert stix.glyph_index(rune(0x1D453)) == 3331
	lm := math_face('LatinModernMath-Regular.otf')
	assert lm.glyph_index(rune(0x0028)) == 9
	assert lm.glyph_index(rune(0x2211)) == 3060
	assert lm.glyph_index(rune(0x222B)) == 3049
	assert lm.glyph_index(rune(0x1D453)) == 1301
}

fn test_math_italics_correction_sign_and_scale() {
	stix := math_pass_for('STIXTwoMath-Regular.ttf', true)
	f_stix := math_face('STIXTwoMath-Regular.ttf')
	f_gid := f_stix.glyph_index(rune(0x1D453))
	assert stix.italics_correction(f_gid) == 20
	assert stix.italics_correction(f_stix.glyph_index(rune(0x222B))) == 230
	// Upright glyphs carry no correction: zero is the answer, not a miss.
	assert stix.italics_correction(f_stix.glyph_index(rune(0x0028))) == 0
	assert stix.italics_correction(f_stix.glyph_index(rune(0x005B))) == 0
	lm := math_pass_for('LatinModernMath-Regular.otf', true)
	lm_face := math_face('LatinModernMath-Regular.otf')
	lm_f := lm_face.glyph_index(rune(0x1D453))
	assert lm.italics_correction(lm_f) == 90
	assert lm.italics_correction(lm_face.glyph_index(rune(0x222B))) == 332
	assert lm.italics_correction(lm_face.glyph_index(rune(0x0078))) == 16
	assert lm.italics_correction(lm_face.glyph_index(rune(0x0028))) == 0
	// Sign: every slanted glyph leans right, so every correction here is
	// positive, on both faces.
	assert stix.italics_correction(f_gid) > 0
	assert lm.italics_correction(lm_f) > 0
	// Scale: 90 design units at upm 1000 is 9px at 100px em, and doubling
	// the size doubles the correction.
	assert math_close(lm.italics_px(lm_f, 100.0), 9.0)
	assert math_close(lm.italics_px(lm_f, 20.0), 2.0 * lm.italics_px(lm_f, 10.0))
	assert math_close(stix.px(.fraction_rule_thickness, 16.0), 68.0 / 1000.0 * 16.0)
	// Percentages scale to their ratio at any size, not to design units.
	assert math_close(stix.px(.script_percent_scale_down, 16.0), 0.7)
	assert math_close(lm.px(.script_script_percent_scale_down, 24.0), 0.5)
}

fn test_math_top_accent_attachment() {
	// Pinned on covered glyphs: A, x and u1D453 carry table values on both
	// faces. Stretchy operators such as the parenthesis and the n-ary
	// summation are NOT covered — HarfBuzz answers those from a fallback
	// over the glyph extents, which this reader deliberately does not
	// replicate: uncovered means zero here, and the fallback is follow-up
	// work for the wiring slice, not for the table reader.
	stix := math_pass_for('STIXTwoMath-Regular.ttf', true)
	f := math_face('STIXTwoMath-Regular.ttf')
	assert stix.top_accent_attachment(f.glyph_index(rune(0x0041))) == 360
	assert stix.top_accent_attachment(f.glyph_index(rune(0x0078))) == 250
	assert stix.top_accent_attachment(f.glyph_index(rune(0x1D453))) == 470
	assert stix.top_accent_attachment(f.glyph_index(rune(0x0028))) == 0
	assert stix.top_accent_attachment(f.glyph_index(rune(0x2211))) == 0
	lm := math_pass_for('LatinModernMath-Regular.otf', true)
	g := math_face('LatinModernMath-Regular.otf')
	assert lm.top_accent_attachment(g.glyph_index(rune(0x0041))) == 375
	assert lm.top_accent_attachment(g.glyph_index(rune(0x0078))) == 258
	assert lm.top_accent_attachment(g.glyph_index(rune(0x1D453))) == 464
	assert lm.top_accent_attachment(g.glyph_index(rune(0x0028))) == 0
	assert lm.top_accent_attachment(g.glyph_index(rune(0x2211))) == 0
}

fn test_math_variant_selection_on_stretchy_delimiter() {
	stix := math_pass_for('STIXTwoMath-Regular.ttf', true)
	f := math_face('STIXTwoMath-Regular.ttf')
	paren := f.glyph_index(rune(0x0028))
	variants := stix.variants(paren, true)
	// STIX builds its parenthesis from 13 vertical sizes starting at the
	// base glyph, each taller than the last.
	assert variants.len == 13
	assert variants[0].glyph == 1064 && variants[0].advance == 933
	assert variants[1].glyph == 1301 && variants[1].advance == 1187
	assert variants[2].glyph == 1302 && variants[2].advance == 1427
	assert variants[12].glyph == 1312 && variants[12].advance == 3821
	// No horizontal growth for a parenthesis.
	assert stix.variants(paren, false).len == 0
	// A 2000-unit target takes the first variant reaching it: 2145.
	assert stix.select_variant(paren, 2000, true) == 1305
	// The pixel form agrees: 2000 units at a 100px em is 200px.
	assert stix.select_variant_px(paren, 200.0, true, 100.0) == 1305
	// Past the largest variant the answer stays the largest: taller than
	// that is the assembly's job.
	assert stix.select_variant(paren, 99999, true) == 1312
	// Nsum grows too, but only to two sizes and with no assembly.
	sum_variants := stix.variants(f.glyph_index(rune(0x2211)), true)
	assert sum_variants.len == 2
	assert sum_variants[0].glyph == 1646 && sum_variants[0].advance == 1031
	assert sum_variants[1].glyph == 1647 && sum_variants[1].advance == 1326
	// Extended shapes are the glyphs the engine may draw larger: the
	// parenthesis is one on STIX, while on Latin Modern the summation is.
	assert stix.is_extended_shape(paren)
	lm := math_pass_for('LatinModernMath-Regular.otf', true)
	g := math_face('LatinModernMath-Regular.otf')
	lm_sum := g.glyph_index(rune(0x2211))
	assert lm.is_extended_shape(lm_sum)
	lm_paren := g.glyph_index(rune(0x0028))
	// ...while its parenthesis grows by variants without the flag.
	assert !lm.is_extended_shape(lm_paren)
	lm_variants := lm.variants(lm_paren, true)
	assert lm_variants.len == 8
	assert lm_variants[0].glyph == 9 && lm_variants[0].advance == 997
	assert lm_variants[1].glyph == 2367 && lm_variants[1].advance == 1095
	assert lm_variants[7].glyph == 2499 && lm_variants[7].advance == 2991
	assert lm.select_variant(lm_paren, 2000, true) == 2455
	assert lm.select_variant(lm_paren, 99999, true) == 2499
}

fn test_math_assembly_parts() {
	stix := math_pass_for('STIXTwoMath-Regular.ttf', true)
	f := math_face('STIXTwoMath-Regular.ttf')
	paren := f.glyph_index(rune(0x0028))
	assembly := stix.assembly(paren, true) or { panic('STIX paren has no vertical assembly') }
	assert assembly.parts.len == 3
	assert assembly.parts[0].glyph == 4862
	assert assembly.parts[0].start_connector == 0
	assert assembly.parts[0].end_connector == 250
	assert assembly.parts[0].full_advance == 1273
	assert !assembly.parts[0].is_extender
	// The middle part repeats: it is the extender, overlapping 1000 units
	// on both sides.
	assert assembly.parts[1].glyph == 4861
	assert assembly.parts[1].is_extender
	assert assembly.parts[1].start_connector == 1000
	assert assembly.parts[1].end_connector == 1000
	assert stix.min_connector_overlap() == 100
	// Nsum has variants but no assembly: taller than its largest size is
	// simply not offered.
	if _ := stix.assembly(f.glyph_index(rune(0x2211)), true) {
		assert false, 'STIX nsum must name no vertical assembly'
	}
	lm := math_pass_for('LatinModernMath-Regular.otf', true)
	g := math_face('LatinModernMath-Regular.otf')
	lm_assembly := lm.assembly(g.glyph_index(rune(0x0028)), true) or {
		panic('LM paren has no vertical assembly')
	}
	assert lm_assembly.parts.len == 3
	assert lm_assembly.parts[0].glyph == 2503
	assert !lm_assembly.parts[0].is_extender
	assert lm_assembly.parts[1].is_extender
	assert lm.min_connector_overlap() == 20
}

fn test_math_neutered_pass_selects_nothing() {
	// Break-fix control: the same queries against a disabled pass must
	// answer the unstretched values, so these assertions fail if the pass
	// is ever neutered — and pass only because it is enabled above.
	stix := math_pass_for('STIXTwoMath-Regular.ttf', false)
	f := math_face('STIXTwoMath-Regular.ttf')
	paren := f.glyph_index(rune(0x0028))
	assert stix.variants(paren, true).len == 0
	assert stix.select_variant(paren, 2000, true) == paren
	assert stix.select_variant(paren, 2000, true) != 1305
	assert stix.italics_correction(f.glyph_index(rune(0x1D453))) == 0
	assert !stix.is_extended_shape(paren)
	if _ := stix.assembly(paren, true) {
		assert false, 'a disabled pass must name no assembly'
	}
	lm := math_pass_for('LatinModernMath-Regular.otf', false)
	g := math_face('LatinModernMath-Regular.otf')
	lm_paren := g.glyph_index(rune(0x0028))
	assert lm.select_variant(lm_paren, 2000, true) == lm_paren
	assert lm.select_variant(lm_paren, 2000, true) != 2455
}

fn test_math_rejects_garbage() {
	// Sixteen zero bytes carry version 0.0, and a real table cut to 64
	// bytes dangles every offset: neither is a MATH table.
	if _ := font.parse_math_table([]u8{len: 16}) {
		assert false, 'zero bytes must not parse as MATH'
	}
	bytes := math_table_data('STIXTwoMath-Regular.ttf')
	if _ := font.parse_math_table(bytes[..64]) {
		assert false, 'a truncated MATH table must not parse'
	}
}
