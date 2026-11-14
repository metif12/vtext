module vtext

import os
import vtext.font
import vtext.shape

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
