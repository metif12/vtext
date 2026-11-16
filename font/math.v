module font

// MATH table: constants, italics correction, variants and parts.
//
// This is a standalone reader over the raw MATH table bytes: it takes what
// sfnt.table_data returns and answers HarfBuzz's math questions — constants,
// italics correction, variant selection and assembly parts — without touching
// Face. The orchestration that turns these design units into a laid-out line
// is the opt-in pass in shape/math.v, which is why this file owns no state
// beyond the parsed table.
//
// Offsets are uint16 from the start of the table that holds them, exactly as
// the specification writes them, and every read is bounds-checked through
// Reader: a truncated table parses to none rather than to plausible numbers.

// tag_math names the MATH table in the sfnt directory.
pub const tag_math = 'MATH'

// math_version is the MATH major version this reader understands. Minor
// versions only add tables at offsets this reader does not follow, so a
// newer minor still parses; a newer major does not.
const math_version = u16(1)

// math_constant_count is how many constants the MATH header carries: two
// script percentages, two plain heights, then MathValueRecords.
const math_constant_count = 56

// MathConstant is one of the 56 MATH constants, in table order. The first
// two are percentages (a value of 70 is seventy percent); the next two are
// plain heights; the rest are design units in MathValueRecords whose device
// offsets are not followed.
pub enum MathConstant {
	script_percent_scale_down                     = 0
	script_script_percent_scale_down              = 1
	delimited_sub_formula_min_height              = 2
	display_operator_min_height                   = 3
	math_leading                                  = 4
	axis_height                                   = 5
	accent_base_height                            = 6
	flattened_accent_base_height                  = 7
	subscript_shift_down                          = 8
	subscript_top_max                             = 9
	subscript_baseline_drop_min                   = 10
	superscript_shift_up                          = 11
	superscript_shift_up_cramped                  = 12
	superscript_bottom_min                        = 13
	superscript_baseline_drop_max                 = 14
	sub_superscript_gap_min                       = 15
	superscript_bottom_max_with_subscript         = 16
	space_after_script                            = 17
	upper_limit_gap_min                           = 18
	upper_limit_baseline_rise_min                 = 19
	lower_limit_gap_min                           = 20
	lower_limit_baseline_drop_min                 = 21
	stack_top_shift_up                            = 22
	stack_top_display_style_shift_up              = 23
	stack_bottom_shift_down                       = 24
	stack_bottom_display_style_shift_down         = 25
	stack_gap_min                                 = 26
	stack_display_style_gap_min                   = 27
	stretch_stack_top_shift_up                    = 28
	stretch_stack_bottom_shift_down               = 29
	stretch_stack_gap_above_min                   = 30
	stretch_stack_gap_below_min                   = 31
	fraction_numerator_shift_up                   = 32
	fraction_numerator_display_style_shift_up     = 33
	fraction_denominator_shift_down               = 34
	fraction_denominator_display_style_shift_down = 35
	fraction_numerator_gap_min                    = 36
	fraction_num_display_style_gap_min            = 37
	fraction_rule_thickness                       = 38
	fraction_denominator_gap_min                  = 39
	fraction_denom_display_style_gap_min          = 40
	skewed_fraction_horizontal_gap                = 41
	skewed_fraction_vertical_gap                  = 42
	overbar_vertical_gap                          = 43
	overbar_rule_thickness                        = 44
	overbar_extra_ascender                        = 45
	underbar_vertical_gap                         = 46
	underbar_rule_thickness                       = 47
	underbar_extra_descender                      = 48
	radical_vertical_gap                          = 49
	radical_display_style_vertical_gap            = 50
	radical_rule_thickness                        = 51
	radical_extra_ascender                        = 52
	radical_kern_before_degree                    = 53
	radical_kern_after_degree                     = 54
	radical_degree_bottom_raise_percent           = 55
}

// MathVariant is one size of a stretchy glyph: the glyph to draw and how far
// it reaches along the stretch direction, in design units.
pub struct MathVariant {
pub mut:
	glyph   u16
	advance u16
}

// MathPart is one piece of a glyph assembly: the glyph, the connector
// lengths that overlap its neighbours, how far the pen moves past it, and
// whether it repeats to fill the middle (an extender).
pub struct MathPart {
pub mut:
	glyph           u16
	start_connector u16
	end_connector   u16
	full_advance    u16
	is_extender     bool
}

// MathAssembly is how a stretchy glyph is built when no single variant is
// tall enough: the italics correction of the assembled shape and its parts
// in order.
pub struct MathAssembly {
pub mut:
	italics_correction int
	parts              []MathPart
}

// MathConstruction is everything the MathVariants table says about one
// stretchy glyph: its larger sizes and, when those run out, its assembly.
pub struct MathConstruction {
pub mut:
	variants []MathVariant
	assembly ?MathAssembly
}

// MathTable is a parsed MATH table: the constants and, per coverage index,
// the italics corrections, top accents, extended-shape flags and the
// vertical and horizontal constructions.
pub struct MathTable {
pub mut:
	constants     [56]int
	italics_cover []CoverageRange
	italics       []int
	accents_cover []CoverageRange
	accents       []int
	extended      []CoverageRange
	vert_cover    []CoverageRange
	vert_constr   []MathConstruction
	horiz_cover   []CoverageRange
	horiz_constr  []MathConstruction
	min_overlap   int
}

// parse_math_table reads a MATH table. None means the bytes are not a MATH
// table this reader can use: too short, the wrong major version, or an
// offset pointing outside the bytes.
pub fn parse_math_table(data []u8) ?MathTable {
	if data.len < 8 {
		return none
	}
	r := new_reader(data)
	if r.u16_at(0) != math_version {
		return none
	}
	constants_at := int(r.u16_at(4))
	glyph_info_at := int(r.u16_at(6))
	// The variants offset sits at byte 8, past the 8-byte header, so the
	// table must hold it before it is read.
	if data.len < 10 {
		return none
	}
	variants_at := int(r.u16_at(8))
	mut table := MathTable{}
	if !read_math_constants(r, constants_at, mut table) {
		return none
	}
	// A missing glyph info or variants section is a table that names
	// constants and nothing else, which still parses: the coverages stay
	// empty and every glyph query answers none or zero.
	if glyph_info_at > 0 {
		read_math_glyph_info(r, glyph_info_at, mut table)
	}
	if variants_at > 0 {
		read_math_variants(r, variants_at, mut table)
	}
	return table
}

// read_math_constants reads the 56 constants at off: two int16 percentages,
// two plain uint16 heights, then MathValueRecords whose device offset is not
// followed. False means the records do not fit, and the table is refused.
fn read_math_constants(r &Reader, off int, mut table MathTable) bool {
	if off <= 0 || !r.has(off, 8) {
		return false
	}
	table.constants[0] = int(r.i16_at(off))
	table.constants[1] = int(r.i16_at(off + 2))
	table.constants[2] = int(r.u16_at(off + 4))
	table.constants[3] = int(r.u16_at(off + 6))
	for i in 4 .. math_constant_count {
		at := off + 8 + (i - 4) * 4
		if !r.has(at, 4) {
			return false
		}
		// A MathValueRecord is an int16 value and a device-table offset that
		// is zero in every shipped math font: a rasterizer adjustment this
		// layout reader has no use for, so it is not followed.
		table.constants[i] = int(r.i16_at(at))
	}
	return true
}

// read_math_glyph_info reads italics corrections, top accents and the
// extended-shape coverage. The kern info is deliberately not followed: kerns
// are outside this slice's scope, and skipping them changes no answer here.
fn read_math_glyph_info(r &Reader, at int, mut table MathTable) {
	if !r.has(at, 8) {
		return
	}
	italics_at := at + int(r.u16_at(at))
	top_accent_at := at + int(r.u16_at(at + 2))
	extended_at := at + int(r.u16_at(at + 4))
	if r.u16_at(at) != 0 {
		read_math_corrections(r, italics_at, mut table.italics_cover, mut table.italics)
	}
	if r.u16_at(at + 2) != 0 {
		read_math_corrections(r, top_accent_at, mut table.accents_cover, mut table.accents)
	}
	if r.u16_at(at + 4) != 0 && r.has(extended_at, 4) {
		table.extended = parse_coverage(r, extended_at)
	}
}

// read_math_corrections reads one MathItalicsCorrectionInfo-shaped table —
// coverage plus one MathValueRecord per covered glyph — into cover and vals
// in coverage-index order.
fn read_math_corrections(r &Reader, at int, mut cover []CoverageRange, mut vals []int) {
	if !r.has(at, 4) {
		return
	}
	coverage_at := at + int(r.u16_at(at))
	count := int(r.u16_at(at + 2))
	if !r.has(at + 4, count * 4) {
		return
	}
	cover = parse_coverage(r, coverage_at)
	for i in 0 .. count {
		vals << int(r.i16_at(at + 4 + i * 4))
	}
}

// read_math_variants reads the MathVariants table: the minimum connector
// overlap and the vertical and horizontal constructions, each indexed by its
// own coverage so a coverage index is a construction index.
fn read_math_variants(r &Reader, at int, mut table MathTable) {
	if !r.has(at, 8) {
		return
	}
	table.min_overlap = int(r.u16_at(at))
	vert_cov_at := at + int(r.u16_at(at + 2))
	horiz_cov_at := at + int(r.u16_at(at + 4))
	vert_count := int(r.u16_at(at + 6))
	if !r.has(at + 8, 2) {
		return
	}
	horiz_count := int(r.u16_at(at + 8))
	vert_base := at + 10
	horiz_base := vert_base + vert_count * 2
	if vert_count > 0 && r.u16_at(at + 2) != 0 {
		if r.has(vert_base, vert_count * 2) {
			table.vert_cover = parse_coverage(r, vert_cov_at)
			for i in 0 .. vert_count {
				constr_at := at + int(r.u16_at(vert_base + i * 2))
				table.vert_constr << read_math_construction(r, constr_at)
			}
		}
	}
	if horiz_count > 0 && r.u16_at(at + 4) != 0 {
		if r.has(horiz_base, horiz_count * 2) {
			table.horiz_cover = parse_coverage(r, horiz_cov_at)
			for i in 0 .. horiz_count {
				constr_at := at + int(r.u16_at(horiz_base + i * 2))
				table.horiz_constr << read_math_construction(r, constr_at)
			}
		}
	}
}

// read_math_construction reads one MathGlyphConstruction: an optional
// assembly offset, a variant count, and that many variant records inline.
// The assembly offset is from the construction start and zero means none.
fn read_math_construction(r &Reader, at int) MathConstruction {
	mut constr := MathConstruction{}
	if !r.has(at, 4) {
		return constr
	}
	assembly_at := int(r.u16_at(at))
	count := int(r.u16_at(at + 2))
	if r.has(at + 4, count * 4) {
		for i in 0 .. count {
			constr.variants << MathVariant{
				glyph:   r.u16_at(at + 4 + i * 4)
				advance: r.u16_at(at + 6 + i * 4)
			}
		}
	}
	if assembly_at != 0 {
		if assembly := read_math_assembly(r, at + assembly_at) {
			constr.assembly = assembly
		}
	}
	return constr
}

// read_math_assembly reads one GlyphAssembly: the assembled italics
// correction, a part count, and that many part records inline. None means
// the parts do not fit, and the construction keeps its variants without an
// assembly.
fn read_math_assembly(r &Reader, at int) ?MathAssembly {
	// The header is a 4-byte MathValueRecord and a 2-byte part count, so 6
	// bytes before the first part record.
	if !r.has(at, 6) {
		return none
	}
	correction := int(r.i16_at(at))
	count := int(r.u16_at(at + 4))
	if !r.has(at + 6, count * 10) {
		return none
	}
	mut parts := []MathPart{cap: count}
	for i in 0 .. count {
		base := at + 6 + i * 10
		parts << MathPart{
			glyph:           r.u16_at(base)
			start_connector: r.u16_at(base + 2)
			end_connector:   r.u16_at(base + 4)
			full_advance:    r.u16_at(base + 6)
			is_extender:     r.u16_at(base + 8) & 1 == 1
		}
	}
	return MathAssembly{
		italics_correction: correction
		parts:              parts
	}
}

// constant returns one MATH constant in the units the table stores: a
// percentage for the two script scales, design units for the rest.
pub fn (t &MathTable) constant(c MathConstant) int {
	return t.constants[int(c)]
}

// is_percent_constant reports whether a constant is one of the two script
// percentages rather than a design-unit measurement, which is what decides
// whether scaling it by the em size is meaningful.
pub fn is_percent_constant(c MathConstant) bool {
	return c == .script_percent_scale_down || c == .script_script_percent_scale_down
}

// italics_correction returns the glyph's italics correction in design
// units: how far right a superscript or limit sits past the glyph's right
// edge. Zero means the font names none, which for an upright glyph is the
// usual case rather than a miss.
pub fn (t &MathTable) italics_correction(gid u16) int {
	idx := coverage_index(t.italics_cover, gid) or { return 0 }
	if idx < t.italics.len {
		return t.italics[idx]
	}
	return 0
}

// top_accent_attachment returns where a top accent centres over the glyph,
// measured from the glyph origin in design units. Zero means the font names
// none.
pub fn (t &MathTable) top_accent_attachment(gid u16) int {
	idx := coverage_index(t.accents_cover, gid) or { return 0 }
	if idx < t.accents.len {
		return t.accents[idx]
	}
	return 0
}

// is_extended_shape reports whether the glyph is an extended shape: one the
// engine may draw larger by choosing a variant or assembling parts.
pub fn (t &MathTable) is_extended_shape(gid u16) bool {
	_ = coverage_index(t.extended, gid) or { return false }
	return true
}

// covers_top_accent reports whether the font names a top accent attachment
// for gid. A covered zero is a named zero; an uncovered glyph falls back to
// half its advance, which is why the two need telling apart.
pub fn (t &MathTable) covers_top_accent(gid u16) bool {
	_ = coverage_index(t.accents_cover, gid) or { return false }
	return true
}

// stretch_glyphs_for lists every glyph the stretch constructions covering
// gid name: variant glyphs and assembly parts, both directions. Empty when
// the font stretches gid no way. The subset closure keeps these: the table
// is copied verbatim, so a variant resolves either way, but without its
// outline it draws nothing.
pub fn (t &MathTable) stretch_glyphs_for(gid u16) []u16 {
	mut out := []u16{}
	for vertical in [true, false] {
		constr := t.construction_for(gid, vertical) or { continue }
		for v in constr.variants {
			out << v.glyph
		}
		if assembly_ := constr.assembly {
			for p in assembly_.parts {
				out << p.glyph
			}
		}
	}
	return out
}

// construction_for returns the stretch construction for a glyph in one
// direction, or none when the font gives it neither variants nor assembly.
fn (t &MathTable) construction_for(gid u16, vertical bool) ?MathConstruction {
	if vertical {
		idx := coverage_index(t.vert_cover, gid) or { return none }
		if idx < t.vert_constr.len {
			return t.vert_constr[idx]
		}
		return none
	}
	idx := coverage_index(t.horiz_cover, gid) or { return none }
	if idx < t.horiz_constr.len {
		return t.horiz_constr[idx]
	}
	return none
}

// variants returns the glyph's larger sizes along the stretch direction, in
// order, starting with the base size. Empty means the font offers no larger
// size in that direction.
pub fn (t &MathTable) variants(gid u16, vertical bool) []MathVariant {
	constr := t.construction_for(gid, vertical) or { return []MathVariant{} }
	return constr.variants.clone()
}

// assembly returns how the glyph is built when no variant is tall enough,
// or none when the font names no assembly for it.
pub fn (t &MathTable) assembly(gid u16, vertical bool) ?MathAssembly {
	constr := t.construction_for(gid, vertical) or { return none }
	return constr.assembly
}

// min_connector_overlap returns the minimum overlap of two assembly parts,
// in design units: parts are placed this much closer than their connector
// lengths alone would put them.
pub fn (t &MathTable) min_connector_overlap() int {
	return t.min_overlap
}
