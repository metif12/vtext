module vtext

import os
import vtext.font
import vtext.shape
import vtext.layout

// Vertical metrics, slice 1: vhea/vmtx/VORG are read, not placed. Placement is
// a layout question for the slice that lays a vertical line out.

// test_font_path is where a named font is on this machine: the committed corpus first, the platform's own
// font directory second, and none when neither has it. This copy lives here because
// `v test <single_file>` compiles that file and not its siblings, so a helper in
// another test file is one this file cannot see.
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

// skip_missing prints why a test cannot run. A skip that prints nothing is a failure pretending to be a
// pass, so every one of them names the font it wanted and where it looked, and tools/run_tests.v counts
// them file by file.
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

// msgothic is the corpus-external CJK face this file measures: MS Gothic carries
// vhea/vmtx, no VORG table, and a vert feature the engine does not collect yet.
// It is a platform font, so everywhere else this file skips aloud.
fn msgothic_bytes() ?[]u8 {
	return corpus_font_bytes('msgothic.ttc') or {
		skip_missing('msgothic.ttc')
		return none
	}
}

fn put_u16(mut b []u8, v int) {
	b << u8((v >> 8) & 0xff)
	b << u8(v & 0xff)
}

fn put_i16(mut b []u8, v int) {
	b << u8((v >> 8) & 0xff)
	b << u8(v & 0xff)
}

// A vhea/vmtx pair reads the way hmtx does: long records first, then a tail of
// bearings sharing the last advance. Two longs and two tail bearings over four
// glyphs exercises both halves and the handoff between them.
fn test_vhea_vmtx_parse() {
	mut data := []u8{}
	data << [u8(0x00), 0x01, 0x00, 0x00] // version
	put_i16(mut data, 880) // ascent
	put_i16(mut data, -120) // descent
	put_i16(mut data, 0) // lineGap
	for _ in 0 .. 24 {
		data << u8(0)
	}
	put_u16(mut data, 2) // numOfLongVerMetrics at +34
	// vmtx: two long records, then two tail bearings.
	put_u16(mut data, 1000)
	put_i16(mut data, 50)
	put_u16(mut data, 900)
	put_i16(mut data, 60)
	put_i16(mut data, 70)
	put_i16(mut data, 80)
	mut tables := map[string]font.TableRecord{}
	tables['vhea'] = font.TableRecord{ offset: 0, length: 36 }
	tables['vmtx'] = font.TableRecord{ offset: 36, length: 12 }
	mut face := &font.Face{
		sfnt:       &font.Sfnt{
			data:   data
			tables: tables
		}
		num_glyphs: 4
	}
	face.read_vhea()
	face.read_vmtx()
	assert face.v_ascender == 880, 'vhea ascent'
	assert face.v_descender == -120, 'vhea descent signs'
	assert face.has_vertical_metrics(), 'vmtx present'
	assert face.vertical_advance_units(0) == 1000
	assert face.vertical_advance_units(1) == 900
	assert face.vertical_advance_units(2) == 900, 'tail shares the last advance'
	assert face.vertical_advance_units(3) == 900
	assert face.vertical_tsb(0) == 50
	assert face.vertical_tsb(1) == 60
	assert face.vertical_tsb(2) == 70, 'tail bearings are their own array'
	assert face.vertical_tsb(3) == 80
}

// VORG names an explicit origin per glyph and a default for the rest; with no
// VORG table the default is the top of the vertical em box.
fn test_vorg_explicit_and_default() {
	mut data := []u8{}
	put_u16(mut data, 1) // majorVersion
	put_u16(mut data, 0) // minorVersion
	put_i16(mut data, 880) // defaultVertOriginY
	put_u16(mut data, 1) // count
	put_u16(mut data, 5) // gid
	put_i16(mut data, 840) // y
	mut tables := map[string]font.TableRecord{}
	tables['VORG'] = font.TableRecord{ offset: 0, length: 12 }
	mut face := &font.Face{
		sfnt:       &font.Sfnt{
			data:   data
			tables: tables
		}
		num_glyphs: 6
	}
	face.v_ascender = 880
	face.read_vorg()
	assert face.vertical_origin_units(5) == 840, 'explicit entry wins'
	assert face.vertical_origin_units(3) == 880, 'default covers the rest'

	mut bare := &font.Face{
		sfnt:       &font.Sfnt{
			data:   []u8{}
			tables: map[string]font.TableRecord{}
		}
		num_glyphs: 1
	}
	bare.v_ascender = 880
	bare.read_vorg()
	assert bare.vertical_origin_units(0) == 880, 'no VORG falls back to the vertical ascender'
	bare.v_ascender = 0
	bare.ascender = 1000
	bare.read_vorg()
	assert bare.vertical_origin_units(0) == 1000, 'no vhea falls back to the horizontal ascender'
}

// MS Gothic, measured against fontTools: vhea 220/36/0 over 256 units, no VORG,
// full-width 256 advances, per-glyph top bearings. The numbers are the ones
// fontTools reports for the same file, which is what makes them a pin rather
// than a transcription.
fn test_vertical_metrics_msgothic() {
	data := msgothic_bytes() or { return }
	f := shape.load_font_bytes(data) or { panic(err) }
	assert f.has_vertical_metrics(), 'msgothic carries vhea/vmtx'
	assert f.face.v_ascender == 220, 'vhea ascent'
	assert f.face.v_descender == 36, 'vhea descent'
	assert f.face.vertical_advance_units(f.glyph_index(rune(0x4E00))) == 256
	assert f.face.vertical_tsb(f.glyph_index(rune(0x4E00))) == 110
	assert f.face.vertical_advance_units(f.glyph_index(`A`)) == 256
	assert f.face.vertical_tsb(f.glyph_index(`A`)) == 23
	assert f.face.vertical_advance_units(0) == 256, '.notdef advances full width'
	assert f.face.vertical_tsb(0) == 33, '.notdef bearing'
	assert f.face.vertical_origin_units(0) == 220, 'no VORG means the ascender'
	// Slice 2 target, named here so the metrics slice cannot be mistaken for
	// the feature: the engine reads the substitution but collects no vert yet.
	assert 'vert' in f.features('GSUB'), 'vert is the next slice'
}

// vert substitutes vertical forms in vertical mode: the ideographic comma draws
// its vertical variant while a CJK letter without one is unchanged. The gids
// are the fontTools-measured ones for the first member of msgothic.ttc, and the
// comma leads on purpose: it is Common, so a run script taken from the first
// glyph would resolve no features at all.
fn test_vert_substitutes_in_vertical_mode() {
	data := msgothic_bytes() or { return }
	original := shape.load_font_bytes(data) or { panic(err) }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(original)
	text := '、一'
	hline := layout.layout_paragraph(ctx, text.runes(), .auto, fs, 32.0)
	assert hline.glyphs.len == 2
	assert hline.glyphs[0].gid == 2058, 'horizontal comma'
	assert hline.glyphs[1].gid == 2893, 'horizontal CJK'
	vopts := layout.LayoutOptions{ vertical: true }
	vline := layout.layout_paragraph_with(ctx, text.runes(), .auto, fs, 32.0, &vopts)
	assert vline.glyphs.len == 2
	assert vline.glyphs[0].gid == 21155, 'vertical comma'
	assert vline.glyphs[1].gid == 2893, 'CJK letter has no vertical form'
	// The flag defaults off: an explicit horizontal request shapes the same.
	hopts := layout.LayoutOptions{}
	plain := layout.layout_paragraph_with(ctx, text.runes(), .auto, fs, 32.0, &hopts)
	assert plain.glyphs[0].gid == hline.glyphs[0].gid
	assert plain.glyphs[1].gid == hline.glyphs[1].gid
}

// A vertical line is one column: advance boxes at x 0, y accumulating downward
// by vertical advances, width the column width, height its length. Measured at
// 32 px against HarfBuzz TTB on the same file, which reports the same gids,
// 256-unit steps and a 768-unit column for this text; the half-width A is what
// proves the advance swap, stepping the full 256 vertically after advancing
// 128 horizontally.
fn test_vertical_line_places_downward() {
	data := msgothic_bytes() or { return }
	original := shape.load_font_bytes(data) or { panic(err) }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(original)
	text := '、一A'
	vopts := layout.LayoutOptions{ vertical: true }
	vline := layout.layout_paragraph_with(ctx, text.runes(), .auto, fs, 32.0, &vopts)
	assert vline.glyphs.len == 3
	assert vline.glyphs[0].gid == 21155, 'vertical comma'
	assert vline.glyphs[1].gid == 2893, 'CJK letter'
	assert vline.glyphs[2].gid == 36, 'latin has no vertical form'
	for g in vline.glyphs {
		assert g.x == 0, 'one column'
		assert g.advance == 32.0, 'full vertical step'
	}
	assert vline.glyphs[0].y == 0
	assert vline.glyphs[1].y == 32.0
	assert vline.glyphs[2].y == 64.0
	assert vline.width == 32.0, 'column fits the full em'
	assert vline.height == 96.0, 'three full steps'
	assert vline.line_height == 32.0, 'stacking step is the column width'
	assert vline.ascent == 0, 'no horizontal ink metrics on a vertical line'
	assert vline.descent == 0
	// The same text laid out horizontally still advances rightward by the
	// horizontal metrics: the mode changes the pen, not the shaping.
	hline := layout.layout_paragraph(ctx, text.runes(), .auto, fs, 32.0)
	assert hline.glyphs[0].x == 0
	assert hline.glyphs[1].x == 32.0
	assert hline.glyphs[2].x == 64.0, 'half-width A advances 128 units'
	assert hline.glyphs[2].advance == 16.0
	assert hline.height == 0, 'height is the vertical mode field'
}

// c_options carries the vertical flag across the C boundary: nonzero in, true
// out, zero or null stays horizontal. This is the in-process half of the
// proof; the smoke test is the C half, which additionally proves the V and C
// struct layouts agree — a drifted field would arrive as horizontal.
fn test_c_options_carries_vertical() {
	on := COptions{
		features: unsafe { nil }
		vertical: 1
	}
	assert c_options(&on).vertical, 'nonzero vertical arrives'
	mut off := COptions{
		features: unsafe { nil }
	}
	assert !c_options(&off).vertical, 'zero vertical stays horizontal'
	assert !c_options(&COptions(unsafe { nil })).vertical, 'null options stay horizontal'
}

// wrap_paragraph_with in vertical mode cuts columns instead of lines: the width
// budget binds the column height, each column rebases y to its own top, and
// the ranges cover the text in order. Gids and steps are the HarfBuzz-pinned
// ones from the placement test.
fn test_vertical_wrap_cuts_columns() {
	data := msgothic_bytes() or { return }
	original := shape.load_font_bytes(data) or { panic(err) }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(original)
	vopts := layout.LayoutOptions{ vertical: true }
	cols := layout.wrap_paragraph_with(ctx, '一二三四'.runes(), .auto, fs, 32.0, 64.0, &vopts)
	assert cols.len == 2, 'two columns of two steps'
	assert cols[0].from == 0 && cols[0].to == 2
	assert cols[1].from == 2 && cols[1].to == 4
	assert cols[0].line.glyphs[0].gid == 2893
	assert cols[0].line.glyphs[1].gid == 2983
	assert cols[1].line.glyphs[0].gid == 2901
	assert cols[1].line.glyphs[1].gid == 4420
	for col in cols {
		assert col.line.glyphs.len == 2
		assert col.line.glyphs[0].x == 0 && col.line.glyphs[1].x == 0
		assert col.line.glyphs[0].y == 0, 'column rebased to its own top'
		assert col.line.glyphs[1].y == 32.0
		assert col.line.width == 32.0, 'width stays the whole column step'
		assert col.line.height == 64.0, 'two steps'
		assert col.line.line_height == 32.0, 'stacking step unchanged by cutting'
	}
}

// A newline ends the column the way it ends the line: the break takes no
// column of its own and the newline draws nothing in either.
fn test_vertical_wrap_mandatory_break() {
	data := msgothic_bytes() or { return }
	original := shape.load_font_bytes(data) or { panic(err) }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(original)
	vopts := layout.LayoutOptions{ vertical: true }
	cols := layout.wrap_paragraph_with(ctx, '一二\n三四'.runes(), .auto, fs, 32.0, 1000.0, &vopts)
	assert cols.len == 2, 'newline cuts the column'
	assert cols[0].from == 0 && cols[0].to == 2
	assert cols[1].from == 3 && cols[1].to == 5
	for col in cols {
		assert col.line.glyphs.len == 2
		assert col.line.glyphs[0].y == 0, 'column rebased to its own top'
		assert col.line.height == 64.0
	}
}

// An unbreakable run taller than the budget goes on a column of its own and
// overflows, the vertical half of the rule that keeps a horizontal word whole:
// a caller cannot map a click on half a broken word back to the text.
fn test_vertical_wrap_overflow() {
	data := msgothic_bytes() or { return }
	original := shape.load_font_bytes(data) or { panic(err) }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(original)
	vopts := layout.LayoutOptions{ vertical: true }
	cols := layout.wrap_paragraph_with(ctx, 'Hello'.runes(), .auto, fs, 32.0, 40.0, &vopts)
	assert cols.len == 1, 'one word, one column'
	assert cols[0].from == 0 && cols[0].to == 5
	assert cols[0].line.height == 160.0, 'five full steps overflow the budget'
	assert cols[0].line.glyphs[4].y == 128.0
}
