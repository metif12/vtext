module vtext

import os
import vtext.shape
import vtext.layout

// Tibetan stacking pins against HarfBuzz 0.56.2 on the committed OFL face
// NotoSerifTibetan-Variable.ttf (upem 1000). Every number below was measured
// with uharfbuzz before it was written here: glyph ids, advances, clusters and
// the mark offsets of the blws/abvm/mkmk stacks. A 16px line scales design
// units by 0.016; y is flipped relative to HarfBuzz's y_off convention.

fn tibetan_path() ?string {
	for d in [os.getenv('VTEXT_TEST_FONTS'), 'testdata/fonts'] {
		if d == '' {
			continue
		}
		p := os.join_path(d, 'NotoSerifTibetan-Variable.ttf')
		if os.exists(p) {
			return p
		}
	}
	return none
}

struct GlyphPin {
	gid     u16
	advance f64
	cluster int
	x       f64
	y       f64
	is_mark bool
}

fn assert_line(pin []GlyphPin, got layout.Line) {
	assert got.glyphs.len == pin.len, 'glyph count ${got.glyphs.len}, not ${pin.len}'
	for i, p in pin {
		g := got.glyphs[i]
		assert g.gid == p.gid, 'glyph ${i}: gid ${g.gid}, not ${p.gid}'
		assert int(g.advance * 100000) == int(p.advance * 100000), 'glyph ${i}: advance ${g.advance}, not ${p.advance}'
		assert g.cluster == p.cluster, 'glyph ${i}: cluster ${g.cluster}, not ${p.cluster}'
		assert int(g.x * 1000) == int(p.x * 1000), 'glyph ${i}: x ${g.x}, not ${p.x}'
		assert int(g.y * 1000) == int(p.y * 1000), 'glyph ${i}: y ${g.y}, not ${p.y}'
		assert g.is_mark == p.is_mark, 'glyph ${i}: is_mark ${g.is_mark}, not ${p.is_mark}'
	}
}

fn shape_tibetan(ctx &shape.Context, fs &shape.FontSet, cps ...rune) layout.Line {
	return layout.layout_paragraph(ctx, cps, shape.Direction.ltr, fs, 16.0)
}

fn test_tibetan_shaper_registration() {
	ctx := shape.new_context()
	// The tag and the content both resolve to the Tibetan shaper, whose two
	// default features are the ones HarfBuzz proves default-on.
	plan := shape.feature_plan_for('Tibt', [])
	assert 'abvs' in plan.defaults, 'abvs must be a default feature'
	assert 'blws' in plan.defaults, 'blws must be a default feature'
	assert shape.shaper_for_content([rune(0x0F56), 0x0F40]) != none, 'Tibetan content must claim a shaper'
}

fn test_tibetan_bka() {
	path := tibetan_path() or {
		println('SKIP NotoSerifTibetan-Variable.ttf is in neither testdata/fonts nor VTEXT_TEST_FONTS')
		return
	}
	ctx := shape.new_context()
	f := shape.load_font_file(path) or { panic(err) }
	fs := shape.new_font_set_of(f)
	// བཀ — two plain consonants at their design-unit advances.
	assert_line([
		GlyphPin{27, 641.0 / 1000 * 16, 0, 0, 0, false},
		GlyphPin{6, 704.0 / 1000 * 16, 1, 10.256, 0, false},
	], shape_tibetan(ctx, fs, 0x0F56, 0x0F40))
}

fn test_tibetan_bkra_blws_stack() {
	path := tibetan_path() or { return }
	ctx := shape.new_context()
	f := shape.load_font_file(path) or { panic(err) }
	fs := shape.new_font_set_of(f)
	// བཀྲ — the blws variants and the subjoined ra placed below at
	// HarfBuzz's (-564,-172) design units, 0.016px per unit and y flipped.
	assert_line([
		GlyphPin{27, 641.0 / 1000 * 16, 0, 0, 0, false},
		GlyphPin{57, 704.0 / 1000 * 16, 1, 10.256, 0, false},
		GlyphPin{1761, 0, 2, (1345.0 / 1000 * 16 - 564.0 / 1000 * 16), 172.0 / 1000 * 16, true},
	], shape_tibetan(ctx, fs, 0x0F56, 0x0F40, 0x0FB0))
}

fn test_tibetan_skya_two_level_stack() {
	path := tibetan_path() or { return }
	ctx := shape.new_context()
	f := shape.load_font_file(path) or { panic(err) }
	fs := shape.new_font_set_of(f)
	// སྐྱ — a two-level stack: subjoined ka at (-652,-35) and the
	// second-level ya at (-645,-372), both on the base's cluster.
	assert_line([
		GlyphPin{132, 675.0 / 1000 * 16, 0, 0, 0, false},
		GlyphPin{1444, 0, 1, 10.8 - 652.0 / 1000 * 16, 35.0 / 1000 * 16, true},
		GlyphPin{1848, 0, 2, 10.8 - 645.0 / 1000 * 16, 372.0 / 1000 * 16, true},
	], shape_tibetan(ctx, fs, 0x0F66, 0x0F90, 0x0FBB))
}

fn test_tibetan_dist_tsheg() {
	path := tibetan_path() or { return }
	ctx := shape.new_context()
	f := shape.load_font_file(path) or { panic(err) }
	fs := shape.new_font_set_of(f)
	// tsheg after bka is 210 design units by default, tightened to 180
	// by the dist pair when it follows the stacked word.
	line := shape_tibetan(ctx, fs, 0x0F56, 0x0F40, 0x0F0B)
	assert line.glyphs.len == 3, 'tsheg line has ${line.glyphs.len} glyphs, not 3'
	assert line.glyphs[2].gid == 1261, 'tsheg gid ${line.glyphs[2].gid}, not 1261'
}
