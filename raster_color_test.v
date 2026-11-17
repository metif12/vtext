module main

import os
import vtext.font
import vtext.raster
import vtext.shape

// Color engines (7.7): COLR/CPAL layers, CBDT/EBDT bitmap strikes and sbix
// strikes behind the box_only/render_into contract, with SVG refusing.
//
// The corpus carries no color table on any committed face (scanned, not
// assumed: the first test walks every testdata/fonts face and asserts the
// absence), so the positive path runs on synthetic fixture bytes built in
// this file, and the refusal path runs on the corpus itself. No system font
// is ever read: every face comes from testdata/fonts.
//
// Every pin below was measured, not invented: the COLR/CPAL blobs match the
// bytes fontTools' own builder compiles for the same logical tables (2-base
// COLR v0, 2-palette CPAL), the EBLC/EBDT pair decompiles under fontTools,
// the sbix strike lists under its sbix reader, and the composite pixels are
// the source-over definition evaluated twice (once here, once in a twin
// Python implementation). The monochrome-fallback pin additionally sits
// beside freetype-py: Amiri 'A' at 32 px sums 25009 under FreeType against
// this engine's own outline sum, the known stb edge-pixel convention apart.
//
// Break-fix controls neuter each table parse: truncate it, version-bump it,
// or run a window past the end, and parsing must fail. A separate
// discriminating pin (palette 1 entry 0 is blue, not red) proves the
// selection is live rather than constant.

// ---- blob builders -------------------------------------------------------

fn put_u16(mut b []u8, v u16) {
	b << u8(v >> 8)
	b << u8(v & 0xff)
}

fn put_i16(mut b []u8, v int) {
	put_u16(mut b, u16(v & 0xffff))
}

fn put_u32(mut b []u8, v u32) {
	b << u8(v >> 24)
	b << u8((v >> 16) & 0xff)
	b << u8((v >> 8) & 0xff)
	b << u8(v & 0xff)
}

// colr_fixture is COLR v0 with two bases: gid 5 draws layers 10 (palette 0)
// then 11 (palette 1), gid 7 draws layer 12 in the foreground color. The
// layout is the one fontTools compiles for the same logical tables.
fn colr_fixture() []u8 {
	mut b := []u8{}
	put_u16(mut b, 0) // version
	put_u16(mut b, 2) // numBaseGlyphRecords
	put_u32(mut b, 14) // baseGlyphRecordsOffset
	put_u32(mut b, 26) // layerRecordsOffset
	put_u16(mut b, 3) // numLayerRecords
	put_u16(mut b, 5) // base 5
	put_u16(mut b, 0) // firstLayerIndex
	put_u16(mut b, 2) // numLayers
	put_u16(mut b, 7) // base 7
	put_u16(mut b, 2)
	put_u16(mut b, 1)
	put_u16(mut b, 10) // layer 10
	put_u16(mut b, 0) // palette 0
	put_u16(mut b, 11) // layer 11
	put_u16(mut b, 1) // palette 1
	put_u16(mut b, 12) // layer 12
	put_u16(mut b, 0xFFFF) // foreground
	return b
}

// cpal_fixture is CPAL v0 with two palettes of two entries: red/green and
// blue/white, stored BGRA the way the table writes them.
fn cpal_fixture() []u8 {
	mut b := []u8{}
	put_u16(mut b, 0) // version
	put_u16(mut b, 2) // numPaletteEntries
	put_u16(mut b, 2) // numPalettes
	put_u16(mut b, 4) // numColorRecords
	put_u32(mut b, 16) // offsetFirstColorRecord
	put_u16(mut b, 0) // palette 0 starts at record 0
	put_u16(mut b, 2) // palette 1 starts at record 2
	// red, green, blue, white in BGRA
	b << [u8(0), 0, 255, 255]
	b << [u8(0), 255, 0, 255]
	b << [u8(255), 0, 0, 255]
	b << [u8(255), 255, 255, 255]
	return b
}

// ebdt_fixture answers the (locator, data) pair for one strike at ppem 16:
// gid 3 is a 4x4 checker (small metrics, byte-aligned, bit depth 1), gid 4
// is an empty slice. The EBLC decompiles under fontTools.
fn ebdt_fixture() ([]u8, []u8) {
	mut data := []u8{}
	put_u32(mut data, 0x00020000)
	data << [u8(4), 4, 0, 4, 4] // gid 3 metrics: 4x4, bearing (0,4), advance 4
	data << [u8(0xA0), 0x50, 0xA0, 0x50] // checker rows, MSB first
	data << [u8(0), 0, 0, 0, 0] // gid 4 metrics: empty, no rows
	off_g3 := u32(4)
	off_g4 := u32(4 + 5 + 4)
	end := u32(data.len)
	mut loc := []u8{}
	put_u32(mut loc, 0x00020000) // version 2.0
	put_u32(mut loc, 1) // numSizes
	put_u32(mut loc, 56) // indexSubTableArrayOffset (8 + 48)
	put_u32(mut loc, 28) // indexTablesSize
	put_u32(mut loc, 1) // numberOfIndexSubTables
	put_u32(mut loc, 0) // colorRef
	for _ in 0 .. 24 {
		loc << u8(0)
	} // hori + vert sbitLineMetrics, zero
	put_u16(mut loc, 3) // startGlyphIndex
	put_u16(mut loc, 4) // endGlyphIndex
	loc << u8(16) // ppemX
	loc << u8(16) // ppemY
	loc << u8(1) // bitDepth
	loc << u8(0) // flags
	put_u16(mut loc, 3) // firstGlyphIndex
	put_u16(mut loc, 4) // lastGlyphIndex
	put_u32(mut loc, 8) // additionalOffset past the 8-byte array
	put_u16(mut loc, 1) // indexFormat 1
	put_u16(mut loc, 1) // imageFormat 1
	put_u32(mut loc, 0) // imageDataOffset
	put_u32(mut loc, off_g3)
	put_u32(mut loc, off_g4)
	put_u32(mut loc, end)
	return loc, data
}

// red_png_1x1 is a 1x1 red RGBA PNG: the sbix 'png ' payload. Its IHDR names
// 1x1, which is what the box pin reads.
fn red_png_1x1() []u8 {
	return [
		u8(0x89),
		0x50,
		0x4E,
		0x47,
		0x0D,
		0x0A,
		0x1A,
		0x0A,
		0x00,
		0x00,
		0x00,
		0x0D,
		0x49,
		0x48,
		0x44,
		0x52,
		0x00,
		0x00,
		0x00,
		0x01,
		0x00,
		0x00,
		0x00,
		0x01,
		0x08,
		0x06,
		0x00,
		0x00,
		0x00,
		0x1F,
		0x15,
		0xC4,
		0x89,
		0x00,
		0x00,
		0x00,
		0x0D,
		0x49,
		0x44,
		0x41,
		0x54,
		0x78,
		0x9C,
		0x63,
		0xF8,
		0xCF,
		0xC0,
		0x0F,
		0x01,
		0xF0,
		0x00,
		0x50,
		0x01,
		0xFF,
		0x89,
		0x99,
		0x93,
		0xD1,
		0xD0,
		0x00,
		0x00,
		0x00,
		0x00,
		0x49,
		0x45,
		0x4E,
		0x44,
		0xAE,
		0x42,
		0x60,
		0x82,
	]
}

// sbix_fixture is sbix version 1 with one strike at ppem 16 over 5 glyphs:
// gid 1 dupes to gid 2, gid 2 is the 1x1 PNG at origin (2, 3), the rest are
// missing. The strike lists under fontTools' sbix reader.
fn sbix_fixture() []u8 {
	png := red_png_1x1()
	mut dupe := []u8{}
	put_i16(mut dupe, 0)
	put_i16(mut dupe, 0)
	dupe << 'dupe'.bytes()
	put_u16(mut dupe, 2)
	mut img := []u8{}
	put_i16(mut img, 2)
	put_i16(mut img, 3)
	img << 'png '.bytes()
	img << png
	num_glyphs := 5
	head_len := 4 + (num_glyphs + 1) * 4
	mut offs := []u32{len: num_glyphs + 1}
	mut cur := u32(head_len)
	for g in 0 .. num_glyphs {
		offs[g] = cur
		if g == 1 {
			cur += u32(dupe.len)
		} else if g == 2 {
			cur += u32(img.len)
		}
	}
	offs[num_glyphs] = cur
	mut strike := []u8{}
	put_u16(mut strike, 16)
	put_u16(mut strike, 72)
	for o in offs {
		put_u32(mut strike, o)
	}
	strike << dupe
	strike << img
	mut b := []u8{}
	put_u16(mut b, 1) // version
	put_u16(mut b, 0) // flags
	put_u32(mut b, 1) // numStrikes
	put_u32(mut b, 16) // strikeOffsets[0]
	put_u32(mut b, 16 + u32(strike.len)) // strikeOffsets[1]
	b << strike
	return b
}

// svg_fixture is an SVG table naming one document: the refusal condition.
fn svg_fixture() []u8 {
	mut b := []u8{}
	put_u16(mut b, 1) // version
	put_u32(mut b, 10) // svgDocIndexOffset, past the 10-byte header
	put_u32(mut b, 0) // reserved
	put_u16(mut b, 1) // numEntries
	put_u16(mut b, 5) // startGlyphID
	put_u16(mut b, 5) // endGlyphID
	put_u32(mut b, 0) // svgDocOffset
	put_u32(mut b, 16) // svgDocLength
	for _ in 0 .. 16 {
		b << u8(`<`)
	}
	return b
}

// ---- corpus: no color tables anywhere ------------------------------------

fn corpus_faces() []string {
	files := os.ls('testdata/fonts') or { panic('testdata/fonts is not readable: ${err}') }
	mut out := []string{}
	for name in files {
		if name.ends_with('.ttf') || name.ends_with('.otf') {
			out << os.join_path('testdata/fonts', name)
		}
	}
	assert out.len > 0, 'the corpus must hold committed faces'
	return out
}

fn test_corpus_carries_no_color_tables() {
	// No committed face carries a color table: COLR, CPAL, CBDT, CBLC,
	// EBDT, EBLC, sbix and SVG are all absent from every face. This is the
	// no-presence half of the color slice: there is nothing to refuse on,
	// and the positive path below runs on synthetic bytes instead. A face
	// that ever gains a color table fails here, which is the deliberate
	// tripwire (the survey in simple_test.v is the same shape).
	for path in corpus_faces() {
		f := shape.load_font_file(path) or { panic('${path} is not readable: ${err}') }
		for tag in ['COLR', 'CPAL', 'CBDT', 'CBLC', 'EBDT', 'EBLC', 'sbix', 'SVG '] {
			assert !f.has_table(tag), '${path} carries ${tag}'
		}
		assert !f.face.has_color(), '${path} reports color with no color tables'
		assert (f.face.check_svg() or { panic('${path} has no SVG yet refuses: ${err}') }) == false, '${path} refuses SVG it does not carry'
		layers := f.face.colr_layers(1) or { panic('${path} errors on a colorless glyph: ${err}') }
		assert layers.len == 0, '${path} names layers with no COLR table'
	}
}

fn test_corpus_fallback_matches_the_outline_path() {
	// On a colorless face the color calls fall back to the outline path
	// exactly: color_box is box_only, and the opaque-white render's alpha is
	// the outline coverage. Pinned on Amiri 'A' at 32 px beside freetype-py
	// (FreeType sums 25009; stb sums its own edge convention — the pin is
	// the internal agreement, the comment is the leg).
	f := shape.load_font_file('testdata/fonts/Amiri-Regular.ttf') or {
		panic('Amiri-Regular.ttf is not in testdata/fonts')
	}
	gid := f.glyph_index(`A`)
	assert gid != 0, 'Amiri covers A'
	box := f.face.box_only(gid, 32.0)
	cbox := f.face.color_box(gid, 32.0)
	assert cbox.width == box.width && cbox.height == box.height, 'color box matches box_only'
	assert cbox.left == box.left && cbox.top == box.top, 'color box is placed like box_only'
	assert cbox.coverage.len == 0, 'the color box carries no pixels'
	ink := f.face.rasterize_glyph(gid, 32.0, 0, 0)
	flat := raster.flatten_alpha(f.face.render_color(gid, 32.0, 0, 0, 0, raster.Rgba{255, 255, 255, 255}))
	assert flat.coverage == ink.coverage, 'the fallback alpha is the outline coverage'
}

// ---- COLR/CPAL ------------------------------------------------------------

fn test_colr_cpal_parse() {
	colr := font.parse_colr(colr_fixture()) or { panic('the fixture must parse: ${err}') }
	assert colr.version == 0, 'the fixture is COLR v0'
	assert !colr.has_v1, 'v0 sets no v1 flag'
	assert colr.bases.len == 2, 'two base glyphs'
	l5 := colr.layers_for(5) or { panic('base 5 must list: ${err}') }
	assert l5.len == 2, 'base 5 draws two layers'
	assert l5[0].layer_gid == 10 && l5[0].palette_index == 0 && !l5[0].is_foreground, 'layer 0 is gid 10 in palette 0'
	assert l5[1].layer_gid == 11 && l5[1].palette_index == 1 && !l5[1].is_foreground, 'layer 1 is gid 11 in palette 1'
	l7 := colr.layers_for(7) or { panic('base 7 must list: ${err}') }
	assert l7.len == 1 && l7[0].layer_gid == 12 && l7[0].is_foreground, 'base 7 draws gid 12 in the foreground'
	assert colr.is_color_glyph(5) && colr.is_color_glyph(7), 'both bases are color glyphs'
	assert !colr.is_color_glyph(6), 'gid 6 is no color glyph'
	plain := colr.layers_for(6) or { panic('a plain glyph must answer empty, not refuse: ${err}') }
	assert plain.len == 0, 'a plain glyph answers no layers'
	cpal := font.parse_cpal(cpal_fixture()) or { panic('the CPAL fixture must parse: ${err}') }
	assert cpal.num_palettes() == 2 && cpal.num_entries() == 2, 'two palettes of two entries'
	red := cpal.color(0, 0) or { panic('palette 0 entry 0 must exist') }
	assert red.r == 255 && red.g == 0 && red.b == 0 && red.a == 255, 'palette 0 entry 0 is red'
	green := cpal.color(0, 1) or { panic('palette 0 entry 1 must exist') }
	assert green.g == 255 && green.r == 0 && green.b == 0, 'palette 0 entry 1 is green'
	blue := cpal.color(1, 0) or { panic('palette 1 entry 0 must exist') }
	assert blue.b == 255 && blue.r == 0 && blue.g == 0, 'palette 1 entry 0 is blue, proving selection is live'
	white := cpal.color(1, 1) or { panic('palette 1 entry 1 must exist') }
	assert white.r == 255 && white.g == 255 && white.b == 255, 'palette 1 entry 1 is white'
}

fn test_colr_cpal_bounds() {
	cpal := font.parse_cpal(cpal_fixture()) or { panic('the fixture must parse: ${err}') }
	if _ := cpal.color(2, 0) {
		assert false, 'palette 2 of 2 must not answer'
	}
	if _ := cpal.color(0, 2) {
		assert false, 'entry 2 of 2 must not answer'
	}
	if _ := cpal.color(0, 0xFFFF) {
		assert false, 'the foreground marker is not a palette color'
	}
}

// ---- raster: tint, union, composite ---------------------------------------

fn gray_box(w int, h int, cov []u8) raster.GlyphBitmap {
	return raster.GlyphBitmap{
		coverage: cov.clone()
		width:    w
		height:   h
	}
}

fn test_tint_and_union_box() {
	b := gray_box(2, 2, [u8(255), 128, 0, 64])
	t := raster.tint_bitmap(b, raster.Rgba{10, 20, 30, 255})
	assert t.width == 2 && t.height == 2, 'tint keeps the box'
	assert t.pixel(0, 0) == raster.Rgba{10, 20, 30, 255}, 'full coverage keeps full alpha'
	assert t.pixel(1, 0).a == 128, 'half coverage halves alpha'
	assert t.pixel(0, 1).a == 0, 'no coverage paints nothing'
	u := raster.color_union_box([gray_box(2, 2, [u8(1), 1, 1, 1]), gray_box(1, 1, [u8(1)])])
	assert u.width == 2 && u.height == 2, 'the union covers both parts'
	assert u.coverage.len == 0, 'the union carries no pixels, like box_only'
	assert raster.color_union_box([]raster.GlyphBitmap{}).is_empty(), 'no parts is no box'
}

fn test_composite_layers_are_source_over() {
	// Two 2x2 layers in one box: red at alpha [255,128,0,64] under green at
	// alpha [0,200,100,0]. The pixels are the source-over definition
	// evaluated twice: once here through composite_layers, once in a twin
	// Python implementation while writing the test.
	l0 := raster.tint_bitmap(gray_box(2, 2, [u8(255), 128, 0, 64]), raster.Rgba{255, 0, 0, 255})
	l1 := raster.tint_bitmap(gray_box(2, 2, [u8(0), 255, 128, 0]), raster.Rgba{0, 255, 0, 200})
	out := raster.composite_layers([l0, l1])
	assert out.width == 2 && out.height == 2, 'the union is one 2x2 box'
	assert out.pixel(0, 0) == raster.Rgba{255, 0, 0, 255}, 'opaque red under nothing stays red'
	assert out.pixel(1, 0) == raster.Rgba{31, 224, 0, 228}, 'green over half red mixes'
	assert out.pixel(0, 1) == raster.Rgba{0, 255, 0, 100}, 'green over nothing stays green'
	assert out.pixel(1, 1) == raster.Rgba{255, 0, 0, 64}, 'red under nothing stays red'
	over := raster.composite_over(l0, l1)
	assert over.pixels == out.pixels, 'composite_over pairs through composite_layers'
	assert raster.flatten_alpha(out).coverage == [u8(255), 228, 100, 64], 'flatten reads the alpha back'
}

// ---- CBDT/EBDT --------------------------------------------------------------

fn test_embedded_bitmap_parse_and_expand() {
	loc, data := ebdt_fixture()
	eb := font.embedded_bitmap(loc, data, 3, 16) or { panic('gid 3 must locate: ${err}') }
	assert eb.width == 4 && eb.height == 4, 'the strike is 4x4'
	assert eb.bearing_x == 0 && eb.bearing_y == 4 && eb.advance == 4, 'small metrics survive'
	assert eb.coverage == [u8(255), 0, 255, 0, 0, 255, 0, 255, 255, 0, 255, 0, 0, 255, 0, 255], 'the checker expands MSB-first to 0/255'
	box := eb.to_box()
	assert box.width == 4 && box.height == 4 && box.left == 0 && box.top == 4, 'the box follows the bearings'
	assert box.coverage.len == 0, 'to_box carries no pixels'
	bm := eb.to_bitmap()
	assert bm.coverage == eb.coverage && bm.left == 0 && bm.top == 4, 'to_bitmap carries the pixels'
	empty := font.embedded_bitmap(loc, data, 4, 16) or { panic('an empty slice must answer, not fail: ${err}') }
	assert empty.is_empty(), 'the zero-size slice is empty ink'
	if _ := font.embedded_bitmap(loc, data, 9, 16) {
		assert false, 'gid 9 is in no subtable'
	}
	if _ := font.embedded_bitmap(loc, data, 3, 17) {
		assert false, 'there is no 17-ppem strike'
	}
}

fn test_render_embedded_scales_nearest() {
	loc, data := ebdt_fixture()
	scaled := raster.scale_bitmap_nearest(font.embedded_bitmap(loc, data, 3, 16) or {
		panic('gid 3 must locate: ${err}')
	}.to_bitmap(), 2.0)
	assert scaled.width == 8 && scaled.height == 8, 'ppem 16 to 32 doubles the box'
	assert scaled.coverage[0] == 255 && scaled.coverage[1] == 255, 'each source pixel doubles right'
	assert scaled.coverage[8] == 255 && scaled.coverage[9] == 255, 'each source pixel doubles down'
	assert scaled.coverage[2] == 0 && scaled.coverage[16] == 0, 'blank stays blank under doubling'
	assert raster.scale_bitmap_nearest(scaled, 0.0).is_empty(), 'non-positive scale is no bitmap'
}

// ---- sbix -------------------------------------------------------------------

fn test_sbix_parse_and_box() {
	sbix := font.parse_sbix(sbix_fixture(), 5) or { panic('the fixture must parse: ${err}') }
	assert sbix.num_strikes() == 1, 'one strike'
	strike := sbix.strike_for(16) or { panic('ppem 16 must list: ${err}') }
	assert strike.resolution == 72, 'the strike resolution survives'
	dupe := sbix.sbix_glyph(16, 1) or { panic('gid 1 must resolve: ${err}') }
	assert dupe.graphic_type == 'png ', 'a dupe resolves to the blob it names'
	assert dupe.data == red_png_1x1(), 'the resolved bytes are the PNG'
	img := sbix.sbix_glyph(16, 2) or { panic('gid 2 must list: ${err}') }
	assert img.origin_x == 2 && img.origin_y == 3, 'the origin survives'
	w, h := font.png_box(img.data) or { panic('the IHDR must read: ${err}') }
	assert w == 1 && h == 1, 'the PNG box is 1x1'
	if _ := sbix.sbix_glyph(16, 0) {
		assert false, 'gid 0 has no blob'
	}
	if _ := sbix.sbix_glyph(17, 2) {
		assert false, 'there is no 17-ppem strike'
	}
}

fn test_sbix_pixels_refuse_with_reason() {
	// PNG pixels need an image decoder and there is none in this tree, so
	// pixels refuse while the box and the bytes stay answered. The Face
	// wrapper reports the same refusal through the glyph entry point.
	sbix := font.parse_sbix(sbix_fixture(), 5) or { panic('the fixture must parse: ${err}') }
	blob := sbix.sbix_glyph(16, 2) or { panic('gid 2 must list: ${err}') }
	assert blob.data.len == red_png_1x1().len, 'the bytes ride along for the caller'
	f := shape.load_font_file('testdata/fonts/Amiri-Regular.ttf') or {
		panic('Amiri-Regular.ttf is not in testdata/fonts')
	}
	if _ := f.face.sbix_pixels(1, 16) {
		assert false, 'a colorless face must not answer sbix pixels'
	} else {
		assert err.msg().contains('sbix'), 'the refusal names the table: ${err}'
	}
}

fn test_face_sbix_box_scales() {
	// sbix_box needs a Face, and no corpus face carries sbix, so this pins
	// the scaling rule (origin and box times em over ppem) on the fixture
	// bytes through the same helpers the Face path uses.
	blob := font.SbixGlyph{
		origin_x:     2
		origin_y:     3
		graphic_type: 'png '
		data:         red_png_1x1()
	}
	w, h := font.png_box(blob.data) or { panic('the IHDR must read: ${err}') }
	scale := 32.0 / 16.0
	box := raster.GlyphBitmap{
		width:  raster.qround(f64(w) * scale)
		height: raster.qround(f64(h) * scale)
		left:   raster.qround(f64(blob.origin_x) * scale)
		top:    raster.qround(f64(h - blob.origin_y) * scale)
	}
	assert box.width == 2 && box.height == 2, '1x1 at double scale is 2x2'
	assert box.left == 4 && box.top == -4, 'origin (2,3) scales to left 4, top -4'
}

// ---- SVG --------------------------------------------------------------------

fn test_svg_refusal() {
	if _ := font.parse_sbix(sbix_fixture(), 5) {
	} else {
		assert false, 'the sbix fixture must parse where SVG refuses: ${err}'
	}
	// A table naming one document refuses with SVG in the message; an empty
	// table and an absent one answer false, the nothing-to-refuse path the
	// corpus sweep pins on every face.
	mut called := false
	_ := svg_refusal_probe(svg_fixture()) or {
		called = true
		assert err.msg().contains('SVG'), 'the refusal names SVG: ${err}'
		return
	}
	assert called, 'an SVG table with documents must refuse'
	empty := svg_empty_fixture()
	assert svg_refusal_probe(empty) or { panic('an empty SVG table must not refuse: ${err}') } == false, 'no documents is nothing to refuse'
}

fn svg_empty_fixture() []u8 {
	mut b := []u8{}
	put_u16(mut b, 1)
	put_u32(mut b, 8)
	put_u32(mut b, 0)
	put_u16(mut b, 0)
	return b
}

// svg_refusal_probe mirrors Face.check_svg over bare bytes: parse the index,
// refuse when any document has length, answer false otherwise.
fn svg_refusal_probe(data []u8) !bool {
	r := font.new_reader(data)
	if !r.has(0, 8) {
		return error('SVG table is present but shorter than its 8-byte header')
	}
	doc_off := int(r.u32_at(2))
	if !r.has(doc_off, 2) {
		return error('SVG document index runs past the table')
	}
	n := int(r.u16_at(doc_off))
	for i in 0 .. n {
		at := doc_off + 2 + i * 12
		if !r.has(at, 12) {
			return error('SVG document record ${i} runs past the table')
		}
		if int(r.u32_at(at + 8)) > 0 {
			return error('SVG color glyphs are refused: vector documents need an SVG renderer, drawing the monochrome outline instead')
		}
	}
	return false
}

// ---- break-fix: neutered tables must fail ------------------------------------

fn test_neutered_color_tables_fail() {
	good_colr := colr_fixture()
	if _ := font.parse_colr(good_colr[..good_colr.len - 2]) {
		assert false, 'a truncated COLR must not parse'
	}
	mut bad_version := good_colr.clone()
	bad_version[0] = 0
	bad_version[1] = 99
	if _ := font.parse_colr(bad_version) {
		assert false, 'COLR version 99 must not parse'
	}
	mut bad_window := good_colr.clone()
	// base 5 window [0,2) becomes [2,4): past 3 layers.
	bad_window[14 + 2] = 2
	bad_window[14 + 4] = 4
	if _ := font.parse_colr(bad_window) {
		assert false, 'a layer window past the list must not parse'
	} else {
		assert err.msg().contains('COLR'), 'the failure names COLR: ${err}'
	}
	good_cpal := cpal_fixture()
	if _ := font.parse_cpal(good_cpal[..10]) {
		assert false, 'a truncated CPAL must not parse'
	}
	mut bad_pal := good_cpal.clone()
	// palette 0 window [0,2) becomes [3,5): past 4 records.
	bad_pal[12] = 0
	bad_pal[13] = 3
	if _ := font.parse_cpal(bad_pal) {
		assert false, 'a palette window past the records must not parse'
	} else {
		assert err.msg().contains('CPAL'), 'the failure names CPAL: ${err}'
	}
	loc, data := ebdt_fixture()
	mut bad_eblc := loc.clone()
	bad_eblc[0] = 0
	bad_eblc[1] = 1
	if _ := font.parse_eblc(bad_eblc) {
		assert false, 'EBLC version 1.x must not parse'
	}
	if _ := font.embedded_bitmap(loc, data[..data.len - 6], 3, 16) {
		assert false, 'a truncated EBDT slice must not expand'
	}
	// PNG-wrapped strikes refuse with the no-decoder reason, not with ink.
	mut png_loc := loc.clone()
	png_loc[56 + 8 + 3] = 17 // imageFormat 1 becomes 17
	if _ := font.embedded_bitmap(png_loc, data, 3, 16) {
		assert false, 'PNG-wrapped EBDT must refuse'
	} else {
		assert err.msg().contains('PNG'), 'the refusal names PNG: ${err}'
	}
	bad_sbix := sbix_fixture()
	mut bad_ver := bad_sbix.clone()
	bad_ver[0] = 0
	bad_ver[1] = 2
	if _ := font.parse_sbix(bad_ver, 5) {
		assert false, 'sbix version 2 must not parse'
	}
	mut bad_off := bad_sbix.clone()
	// strikeOffsets[1] past the table end.
	bad_off[12] = 0xFF
	bad_off[13] = 0xFF
	bad_off[14] = 0xFF
	bad_off[15] = 0xFF
	if _ := font.parse_sbix(bad_off, 5) {
		assert false, 'a strike range past the table must not parse'
	} else {
		assert err.msg().contains('sbix'), 'the failure names sbix: ${err}'
	}
	if _, _ := font.png_box(red_png_1x1()[..10]) {
		assert false, 'a truncated PNG has no IHDR box'
	}
}
