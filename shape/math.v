module shape

import vtext.font

// MATH shaping, the opt-in pass that lays out mathematical text.
//
// A math run is not shaped like a text run: a stretchy delimiter grows to
// cover what it encloses, a superscript shifts by the font's constants and
// past the base's italics correction, and a fraction stacks by measured
// gaps rather than by kerning. None of that happens unless the caller asks,
// because a text engine that stretched every parenthesis would mangle every
// smiley: the pass carries an explicit enabled flag and only an enabled one
// selects variants or assembles parts.
//
// The pass holds a parsed MATH table and the font's units per em, and every
// measurement answers in design units with a pixel form beside it. Glyph ids
// come from the caller's font — this pass never maps codepoints itself — so
// a test can drive it from HarfBuzz's own glyph ids and compare directly.

// MathPass is an opt-in MATH layout pass over one font's MATH table.
//
// enabled is the whole opt-in: a disabled pass answers every query with the
// unstretched value — the base glyph, zero correction — so a caller that
// builds one and never enables it gets plain text shaping with no math.
pub struct MathPass {
pub mut:
	table        font.MathTable
	units_per_em int
	enabled      bool
}

// new_math_pass builds a pass over raw MATH table bytes, as returned by
// sfnt.table_data, with the font's units per em for pixel scaling. None
// means the bytes are not a usable MATH table. The pass starts disabled;
// set enabled to let it stretch.
pub fn new_math_pass(table_data []u8, units_per_em int, enabled bool) ?MathPass {
	table := font.parse_math_table(table_data) or { return none }
	upm := if units_per_em > 0 { units_per_em } else { 1000 }
	return MathPass{
		table:        table
		units_per_em: upm
		enabled:      enabled
	}
}

// units returns one MATH constant in the units the table stores: a
// percentage for the two script scales, design units for the rest.
pub fn (p &MathPass) units(c font.MathConstant) int {
	return p.table.constant(c)
}

// px scales a design-unit constant to pixels at the given em size. The two
// script percentages are not design units and scale to their ratio instead —
// seventy percent is 0.7 at any size — which is why they do not go through
// the same multiplication.
pub fn (p &MathPass) px(c font.MathConstant, em_px f64) f64 {
	raw := f64(p.table.constant(c))
	if font.is_percent_constant(c) {
		return raw / 100.0
	}
	return raw / f64(p.units_per_em) * em_px
}

// italics_correction returns how far right of the glyph's right edge a
// superscript or limit sits, in design units. Zero with an enabled pass
// means the font names none for this glyph.
pub fn (p &MathPass) italics_correction(gid u16) int {
	if !p.enabled {
		return 0
	}
	return p.table.italics_correction(gid)
}

// italics_px is the italics correction in pixels at the given em size.
pub fn (p &MathPass) italics_px(gid u16, em_px f64) f64 {
	return f64(p.italics_correction(gid)) / f64(p.units_per_em) * em_px
}

// top_accent_attachment returns where a top accent centres over the glyph,
// measured from the glyph origin in design units.
pub fn (p &MathPass) top_accent_attachment(gid u16) int {
	if !p.enabled {
		return 0
	}
	return p.table.top_accent_attachment(gid)
}

// is_extended_shape reports whether the glyph may be drawn larger by
// variant choice or assembly.
pub fn (p &MathPass) is_extended_shape(gid u16) bool {
	if !p.enabled {
		return false
	}
	return p.table.is_extended_shape(gid)
}

// variants lists the glyph's larger sizes along the stretch direction, in
// order starting with the base size. A disabled pass answers empty: no
// larger size is ever chosen for it.
pub fn (p &MathPass) variants(gid u16, vertical bool) []font.MathVariant {
	if !p.enabled {
		return []font.MathVariant{}
	}
	return p.table.variants(gid, vertical)
}

// select_variant picks the glyph that covers target_units along the stretch
// direction: the first variant reaching at least that far, or the largest
// when none does. With no variants — or a disabled pass — the answer is the
// base glyph, and the caller falls back to assembly or draws it as is.
pub fn (p &MathPass) select_variant(gid u16, target_units int, vertical bool) u16 {
	if !p.enabled {
		return gid
	}
	variants := p.table.variants(gid, vertical)
	if variants.len == 0 {
		return gid
	}
	for v in variants {
		if int(v.advance) >= target_units {
			return v.glyph
		}
	}
	return variants[variants.len - 1].glyph
}

// select_variant_px is select_variant with the target in pixels.
pub fn (p &MathPass) select_variant_px(gid u16, target_px f64, vertical bool, em_px f64) u16 {
	target := int(target_px / em_px * f64(p.units_per_em))
	return p.select_variant(gid, target, vertical)
}

// assembly returns the glyph's part-built form for when no variant is tall
// enough, or none when the font names no assembly — or the pass is
// disabled, in which case nothing is ever part-built.
pub fn (p &MathPass) assembly(gid u16, vertical bool) ?font.MathAssembly {
	if !p.enabled {
		return none
	}
	return p.table.assembly(gid, vertical)
}

// min_connector_overlap returns how much two assembly parts overlap, in
// design units.
pub fn (p &MathPass) min_connector_overlap() int {
	return p.table.min_connector_overlap()
}
