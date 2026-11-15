module vtext

import os
import vtext.font
import vtext.shape
import vtext.layout

// Single positioning (GPOS type 1): the reader is pinned against bytes in
// gpos_singlepos2_test.v and gpos_valuesize_test.v, and this file pins the
// other two halves — the query over parsed lookups, and the layout pass that
// folds the answer into advances and positions. A rule can be read perfectly
// and still never fire, and a parser test would not notice.
//
// This copy of the helpers lives here because `v test <single_file>`
// compiles that file and not its siblings, so a helper in another test file
// is one this file cannot see.
fn corpus_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('VTEXT_TEST_FONTS'), 'testdata/fonts', windows_font_dir()] {
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

fn corpus_font_bytes(name string) ?[]u8 {
	p := corpus_font_path(name) or { return none }
	return os.read_bytes(p) or { panic('${p} is not readable: ${err}') }
}

$if windows {
	fn windows_font_dir() string {
		return 'C:\\Windows\\Fonts'
	}
} $else {
	fn windows_font_dir() string {
		return ''
	}
}

fn skip_missing(name string) {
	line := 'SKIP ${name} is in neither testdata/fonts nor the platform font directory'
	path := os.getenv('VTEXT_SKIP_LOG')
	if path != '' {
		mut f := os.open_append(path) or { return }
		f.writeln(line) or { return }
		f.close()
		return
	}
	println(line)
}

// single_gpos is two lookups of hand-built single positioning: the first
// holds two rules that both cover gid 11, the second holds one more. What is
// pinned is which of them the query answers — first match within a lookup,
// accumulation across lookups — not the bytes that carried them.
fn single_gpos() &font.Gpos {
	return &font.Gpos{
		lookups: [
			font.GposLookup{
				kind:    font.gpos_lookup_single_position
				singles: [
					font.SinglePos{
						ranges: [font.CoverageRange{ first: 10, last: 12 }]
						format: 0x0007
						values: [
							font.PairValue{
								x_placement: 1
								y_placement: 2
								x_advance:   3
								format:      0x0007
							},
							font.PairValue{
								x_placement: 10
								y_placement: 20
								x_advance:   30
								format:      0x0007
							},
							font.PairValue{
								x_placement: 100
								y_placement: 200
								x_advance:   300
								format:      0x0007
							},
						]
					},
					font.SinglePos{
						ranges: [font.CoverageRange{ first: 11, last: 11 }]
						format: 0x0004
						values: [
							font.PairValue{
								x_advance: 1000
								format:    0x0004
							},
						]
					},
				]
			},
			font.GposLookup{
				kind:    font.gpos_lookup_single_position
				singles: [
					font.SinglePos{
						ranges: [font.CoverageRange{ first: 11, last: 11 }]
						format: 0x0005
						values: [
							font.PairValue{
								x_placement: 7
								x_advance:   9
								format:      0x0005
							},
						]
					},
				]
			},
		]
	}
}

fn test_single_offset_first_match_within_a_lookup() {
	g := single_gpos()
	// Gid 11 is covered by both rules of lookup 0: the first one answers and
	// the second is not consulted, so the 1000-advance rule below never fires.
	v := g.single_offset_on(11, [u16(0)]) or {
		assert false, 'gid 11 is covered by lookup 0'
		return
	}
	assert v.x_placement == 10, 'first matching rule wins, got ${v.x_placement}'
	assert v.y_placement == 20
	assert v.x_advance == 30
}

fn test_single_offset_accumulates_across_lookups() {
	g := single_gpos()
	// Both lookups match gid 11, so the line moves by their sum — the same
	// rule kern_offset keeps for pair kerns.
	v := g.single_offset_on(11, [u16(0), u16(1)]) or {
		assert false, 'gid 11 is covered by both lookups'
		return
	}
	assert v.x_placement == 17, '10 from the first lookup and 7 from the second'
	assert v.x_advance == 39, '30 and 9'
}

fn test_single_offset_reports_no_rule() {
	g := single_gpos()
	if _ := g.single_offset_on(99, [u16(0), u16(1)]) {
		assert false, 'no rule covers gid 99'
	}
	if _ := g.single_offset_on(11, [u16(7)]) {
		assert false, 'lookup 7 does not exist'
	}
}

// Simplified Arabic keeps two small letters under its kern feature: U+06E5
// and U+06E6 shift by (-170, +230) design units, measured with fontTools
// against the system font's own table, and HarfBuzz agrees — it shapes alef
// plus U+06E5 with offsets of -83 and +112 at a 1000-unit scale, which is the
// same pair scaled by the face's 2048 units per em. The line below has to
// carry the same shift.
fn test_single_positions_shifts_a_real_glyph() {
	data := corpus_font_bytes('simpo.ttf') or {
		skip_missing('simpo.ttf')
		return
	}
	original := shape.load_font_bytes(data) or { panic(err) }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(original)
	em_px := 32.0
	line := layout.layout_paragraph(ctx, 'ا\u06e5'.runes(), .rtl, fs, em_px)
	assert line.glyphs.len == 2, 'alef and the small waw, got ${line.glyphs.len}'
	scale := em_px / f64(original.face.units_per_em)
	mut pen := f64(0)
	for g in line.glyphs {
		if g.cluster == 1 {
			assert !g.is_mark, 'U+06E5 is a base letter in this face, not a mark'
			assert g.y == -230.0 * scale, 'the y placement lands on the glyph, got ${g.y}'
			assert g.x == pen - 170.0 * scale, 'the x placement moves only its own glyph, got ${g.x} at pen ${pen}'
			assert g.advance == original.glyph_advance(g.gid, em_px), 'vf=3 carries no advance, so the advance is the hmtx one'
		}
		pen += g.advance
	}
}

// Naming the kern feature explicitly changes nothing: it is already applied,
// and its lookups are consulted once however many features name them. A
// shift applied twice is a letter moved to where no other shaper puts it,
// so this is the revert control for the deduplication in single_adjustment.
fn test_single_positions_applies_kern_once() {
	data := corpus_font_bytes('simpo.ttf') or {
		skip_missing('simpo.ttf')
		return
	}
	original := shape.load_font_bytes(data) or { panic(err) }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(original)
	em_px := 32.0
	plain := layout.layout_paragraph(ctx, 'ا\u06e5'.runes(), .rtl, fs, em_px)
	opt := &layout.LayoutOptions{
		features: ['kern']
	}
	named := layout.layout_paragraph_with(ctx, 'ا\u06e5'.runes(), .rtl, fs, em_px, opt)
	assert named.glyphs.len == plain.glyphs.len
	for i in 0 .. named.glyphs.len {
		assert named.glyphs[i].x == plain.glyphs[i].x, 'glyph ${i}: ${named.glyphs[i].x} against ${plain.glyphs[i].x}'
		assert named.glyphs[i].y == plain.glyphs[i].y
		assert named.glyphs[i].advance == plain.glyphs[i].advance
	}
}

// Amiri carries some thirty single positioning lookups and names none of
// them from any feature — the same dead-lookup story as its GSUB lookup 55.
// A reader that consulted every lookup regardless of features would shift
// Arabic-Indic digits by hundreds of units; the engine consults only the
// features the line applies, so a digit's adjustment is none. The struct
// tests above prove the query can find a rule, which is what makes this
// none meaningful rather than a query that never answers.
fn test_dead_single_lookups_stay_dead() {
	data := corpus_font_bytes('Amiri-Regular.ttf') or {
		skip_missing('Amiri-Regular.ttf')
		return
	}
	original := shape.load_font_bytes(data) or { panic(err) }
	gpos := original.face.gpos or {
		assert false, 'Amiri has a GPOS table'
		return
	}
	mut singles := 0
	for l in gpos.lookups {
		singles += l.singles.len
	}
	assert singles > 0, 'the control: Amiri carries single positioning rules'
	gid := original.glyph_index(0x0661)
	if _ := original.single_adjustment(gid, 'arab', [], false) {
		assert false, 'no applied feature names a single rule for this digit'
	}
}

// Noto Nastaliq carries a cursive rule, and the shaped letters it would join
// are pre-drawn ligature glyphs: the exit of one glyph never meets the entry
// of the next. Measured 2026-11-15 over سلام, four glyphs carry one-sided
// anchors and no adjacent pair carries exit-plus-entry; HarfBuzz agrees, all
// x-offsets zero on the same text. Joining exit to entry here would swing a
// letter by hundreds of units at ~540-unit advances, so the engine applies no
// cursive shift. This test fails the day a shaped line grows an adjacent
// exit-plus-entry pair, which is the day the decision is re-measured rather
// than assumed.
fn test_cursive_attachment_stays_unwired() {
	data := corpus_font_bytes('NotoNastaliqUrdu-Regular.ttf') or {
		skip_missing('NotoNastaliqUrdu-Regular.ttf')
		return
	}
	original := shape.load_font_bytes(data) or { panic(err) }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(original)
	line := layout.layout_paragraph(ctx, 'سلام'.runes(), .rtl, fs, 32.0)
	assert line.glyphs.len > 1
	mut one_sided := 0
	for i in 0 .. line.glyphs.len {
		a := original.cursive_anchors(line.glyphs[i].gid, 'arab') or { continue }
		if a.entry_exists || a.exit_exists {
			one_sided++
		}
		if i + 1 < line.glyphs.len {
			b := original.cursive_anchors(line.glyphs[i + 1].gid, 'arab') or { continue }
			assert !(a.exit_exists && b.entry_exists), 'glyph ${i} exit meets glyph ${i + 1} entry: re-measure the cursive decision'
		}
	}
	assert one_sided > 0, 'the control: the rule is reachable, so the absent pair is meaningful'
}
