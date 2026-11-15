module vtext

import os
import vtext.shape
import vtext.layout

// Tests for the second corpus wave: programming faces, Hebrew, CJK and a
// Nerd-patched face. Every number below was read off HarfBuzz and fontTools
// before it was written here; agreement with a second reader is the evidence.
//
// The five faces ship in testdata/fonts with their OFL texts, so they load on
// every platform with no skips: no host font, no platform directory.

fn extra_font_path(name string) ?string {
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

fn extra_font(name string) ?&shape.Font {
	p := extra_font_path(name) or { return none }
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

fn test_extra_fonts_load() {
	for name in ['JetBrainsMono-Variable.ttf', 'CascadiaCode-Variable.ttf',
		'NotoSansHebrew-Variable.ttf', 'NotoSansSC-Variable.ttf', 'JetBrainsMonoNerdFont-Regular.ttf'] {
		f := extra_font(name) or { panic('${name} is not in testdata/fonts') }
		assert f.num_glyphs() > 100, '${name} has almost no glyphs'
		assert f.units_per_em() > 0, '${name} has no units per em'
	}
}

fn test_extra_fonts_cover_what_they_claim() {
	jb := extra_font('JetBrainsMono-Variable.ttf') or { return }
	assert jb.has_glyph(`A`), 'JetBrains covers Latin'
	assert jb.has_glyph(rune(0x0391)), 'JetBrains covers Greek Alpha'
	casc := extra_font('CascadiaCode-Variable.ttf') or { return }
	assert casc.has_glyph(`=`), 'Cascadia covers the code pair'
	assert casc.has_glyph(rune(0x0645)), 'Cascadia covers Arabic mim'
	assert casc.has_glyph(rune(0x05D0)), 'Cascadia covers Hebrew alef'
	assert !casc.has_glyph(rune(0x4E2D)), 'Cascadia covers no CJK'
	assert !casc.has_glyph(rune(0xF09B)), 'the plain face carries no PUA icons'
	he := extra_font('NotoSansHebrew-Variable.ttf') or { return }
	assert he.has_glyph(rune(0x05D0)), 'Hebrew covers alef'
	assert he.has_glyph(rune(0x05B0)), 'Hebrew covers sheva'
	assert !he.has_glyph(rune(0x0645)), 'Hebrew covers no Arabic'
	sc := extra_font('NotoSansSC-Variable.ttf') or { return }
	assert sc.has_glyph(rune(0x4E2D)), 'SC covers U+4E2D'
	assert sc.has_glyph(rune(0x6587)), 'SC covers U+6587'
	nerd := extra_font('JetBrainsMonoNerdFont-Regular.ttf') or { return }
	assert nerd.has_glyph(`A`), 'nerd covers Latin'
	assert nerd.has_glyph(rune(0xF09B)), 'nerd covers the PUA github icon'
	assert nerd.has_glyph(rune(0xEED0)), 'nerd covers a codicon'
	assert !nerd.has_glyph(rune(0x0645)), 'nerd covers no Arabic'
}

fn extra_line(f &shape.Font, text string) layout.Line {
	return extra_line_in(f, text, '', '')
}

// extra_line_in lays one line out under an explicit script/language override.
// The override matters for the code faces: a Common-only run resolves to the
// present script (zyyy), which FiraCode carries and JetBrains/Cascadia do not —
// their calt lives under latn (and DFLT, which this engine does not fall back
// to: an unknown script must find no rules, per gsub_test). Naming latn asks
// the table HarfBuzz folds under, which is what the pins below compare.
fn extra_line_in(f &shape.Font, text string, script string, lang string) layout.Line {
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	mut opts := layout.LayoutOptions{}
	opts.script = script
	opts.language = lang
	return layout.layout_paragraph_with(ctx, text.runes(), .auto, fs, 32.0, &opts)
}

fn test_extra_fonts_fold_code_ligatures() {
	// HarfBuzz-measured: folded under latn, plain cmap glyphs with -calt.
	jb := extra_font('JetBrainsMono-Variable.ttf') or { return }
	folded := extra_line_in(jb, '=>', 'latn', '')
	assert folded.glyphs.len == 2, 'folded arrow is two glyphs, got ${folded.glyphs.len}'
	assert folded.glyphs[0].gid == 0x49a, 'JetBrains folds = to 0x49a, got ${folded.glyphs[0].gid}'
	assert folded.glyphs[1].gid == 0x3fa, 'JetBrains folds > to 0x3fa, got ${folded.glyphs[1].gid}'
	casc := extra_font('CascadiaCode-Variable.ttf') or { return }
	cfold := extra_line_in(casc, '=>', 'latn', '')
	assert cfold.glyphs.len == 2, 'Cascadia folds to two glyphs, got ${cfold.glyphs.len}'
	assert cfold.glyphs[0].gid == 0xa9c, 'Cascadia folds = to 0xa9c, got ${cfold.glyphs[0].gid}'
	assert cfold.glyphs[1].gid == 0xaa2, 'Cascadia folds > to 0xaa2, got ${cfold.glyphs[1].gid}'
	nerd := extra_font('JetBrainsMonoNerdFont-Regular.ttf') or { return }
	nfold := extra_line_in(nerd, '=>', 'latn', '')
	assert nfold.glyphs.len == 2, 'nerd folds to two glyphs, got ${nfold.glyphs.len}'
	assert nfold.glyphs[0].gid == 0x313f, 'nerd folds = to 0x313f, got ${nfold.glyphs[0].gid}'
	assert nfold.glyphs[1].gid == 0x30cc, 'nerd folds > to 0x30cc, got ${nfold.glyphs[1].gid}'
	base_eq := nerd.glyph_index(`=`)
	base_gt := nerd.glyph_index(`>`)
	assert nfold.glyphs[0].gid != base_eq, 'the folded = is not the cmap glyph'
	assert nfold.glyphs[1].gid != base_gt, 'the folded > is not the cmap glyph'
}

fn test_extra_fonts_shape_hebrew() {
	he := extra_font('NotoSansHebrew-Variable.ttf') or { return }
	// Shin with qamats, lamed, vav, mem: HarfBuzz reads seven glyphs, the three
	// marks carrying no advance. The engine flags the same three.
	line := extra_line(he, 'שָׁלוֹם')
	assert line.width > 0, 'a Hebrew word has positive width'
	assert line.glyphs.len >= 4, 'letters plus the mark, got ${line.glyphs.len}'
	mut mark_found := false
	for g in line.glyphs {
		if g.is_mark {
			mark_found = true
			assert g.advance == 0, 'a Hebrew mark shares its base advance'
		}
	}
	assert mark_found, 'the sheva is a mark, not a letter'
}

fn test_extra_fonts_shape_cjk() {
	sc := extra_font('NotoSansSC-Variable.ttf') or { return }
	line := extra_line(sc, '中文')
	assert line.glyphs.len == 2, 'two characters draw two glyphs, got ${line.glyphs.len}'
	assert line.width > 0, 'a CJK word has positive width'
	for g in line.glyphs {
		assert g.gid != 0, 'no .notdef in a covered CJK line'
	}
}

fn test_extra_fonts_draw_nerd_icon() {
	nerd := extra_font('JetBrainsMonoNerdFont-Regular.ttf') or { return }
	gid := nerd.glyph_index(rune(0xF09B))
	assert gid != 0, 'the github icon is a real glyph'
	line := extra_line(nerd, 'A')
	assert line.glyphs.len == 1, 'one letter draws one glyph'
	bitmap := nerd.rasterize(gid, 32.0, 0, 0)
	assert !bitmap.is_empty(), 'the icon rasterises to real ink'
	latin := nerd.rasterize(nerd.glyph_index(`A`), 32.0, 0, 0)
	assert !latin.is_empty(), 'Latin rasterises in the nerd face'
	he := extra_font('NotoSansHebrew-Variable.ttf') or { return }
	alef := he.rasterize(he.glyph_index(rune(0x05D0)), 32.0, 0, 0)
	assert !alef.is_empty(), 'alef rasterises'
	sc := extra_font('NotoSansSC-Variable.ttf') or { return }
	han := sc.rasterize(sc.glyph_index(rune(0x4E2D)), 32.0, 0, 0)
	assert !han.is_empty(), 'U+4E2D rasterises'
}
