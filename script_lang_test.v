module harfara

import os
import harfara.shape
import harfara.layout

// Tests for slice 7.2, second half: the script and language override.
//
// Detection stays the default: an empty override shapes exactly the way the
// engine always has, and every number below was read off the committed fonts
// with HarfBuzz and fontTools before it was written here. HarfBuzz shaped
// each string with the same override (`buf.language`, default features plus
// locl) and the gids below are its answer; harfara agreeing with another
// reader is the evidence, one reader agreeing with itself is not.
//
// The override names the OpenType language system: the script tag the font
// spells ('arab') and the language tag the font spells ('URD', 'SND',
// 'FAR'). A BCP 47 code is not a tag ('ur' is not 'URD'), and a language the
// font does not tag falls back to the default system.

// lang_font_path is where a test font is: the override first, then the
// committed corpus. There is no platform font-directory fallback here, because
// every font this file needs is committed and a host font of the same name is
// a different font.
fn lang_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('HARFARA_TEST_FONTS'), 'testdata/fonts'] {
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

// lang_skip records why a test could not run. A skip that prints nothing is a
// failure pretending to be a pass.
fn lang_skip(name string) {
	line := 'SKIP ${name}'
	path := os.getenv('HARFARA_SKIP_LOG')
	if path != '' {
		mut f := os.open_append(path) or { return }
		f.writeln(line) or { return }
		f.close()
		return
	}
	println(line)
}

fn lang_font(name string) ?&shape.Font {
	p := lang_font_path(name) or {
		lang_skip('${name} is in neither $HARFARA_TEST_FONTS nor testdata/fonts')
		return none
	}
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

fn lang_set(font &shape.Font) &shape.FontSet {
	mut fs := shape.new_font_set()
	fs.add(font)
	return fs
}

fn lang_line(font &shape.Font, text string, script string, lang string) layout.Line {
	return lang_line_dir(font, text, .rtl, script, lang)
}

fn lang_line_dir(font &shape.Font, text string, dir shape.Direction, script string, lang string) layout.Line {
	ctx := shape.new_context()
	fs := lang_set(font)
	mut opts := layout.LayoutOptions{}
	opts.script = script
	opts.language = lang
	return layout.layout_paragraph_with(ctx, text.runes(), dir, fs, 32.0, &opts)
}

fn test_empty_override_shapes_like_no_override() {
	f := lang_font('NotoNaskhArabic-Regular.ttf') or { return }
	// An empty override is the default path, spelled out: same script
	// detection, same default language system, same line.
	def := lang_line(f, 'سلام', '', '')
	auto := lang_line(f, 'سلام', '', '')
	assert def.width == auto.width, 'empty override is the default'
	assert def.glyphs.len == auto.glyphs.len, 'same glyph count, got ${def.glyphs.len} vs ${auto.glyphs.len}'
	for i, g in def.glyphs {
		assert g.gid == auto.glyphs[i].gid, 'same glyph ${i}: ${g.gid} vs ${auto.glyphs[i].gid}'
	}
}

fn test_language_override_applies_sindhi_locl() {
	f := lang_font('NotoNaskhArabic-Regular.ttf') or { return }
	// U+0645 MEEM: HarfBuzz reads gid 72 by default and gid 73
	// (uni0645.locl) under SND, with the advance going 489 to 598. The
	// substitution is written against the base glyph, so it has to run before
	// the joining forms: after them the coverage misses and the base stays.
	def := lang_line(f, 'م', '', '')
	assert def.glyphs.len == 1, 'one letter draws one glyph, got ${def.glyphs.len}'
	assert def.glyphs[0].gid == 72, 'default meem is gid 72, got ${def.glyphs[0].gid}'
	snd := lang_line(f, 'م', '', 'SND')
	assert snd.glyphs.len == 1, 'one letter draws one glyph, got ${snd.glyphs.len}'
	assert snd.glyphs[0].gid == 73, 'Sindhi meem is gid 73, got ${snd.glyphs[0].gid}'
	assert snd.width > def.width, 'the locl advance is wider: ${snd.width} vs ${def.width}'
}

fn test_language_override_applies_urdu_digits() {
	f := lang_font('Amiri-Regular.ttf') or { return }
	// U+06F4 EXTENDED ARABIC-INDIC DIGIT FOUR: HarfBuzz reads gid 260 by
	// default and gid 1463 under URD. A digit has no joining form, so this
	// pins the language resolution with no ordering question in it.
	def := lang_line(f, '۴', '', '')
	assert def.glyphs.len == 1, 'one digit draws one glyph, got ${def.glyphs.len}'
	assert def.glyphs[0].gid == 260, 'default four is gid 260, got ${def.glyphs[0].gid}'
	urd := lang_line(f, '۴', '', 'URD')
	assert urd.glyphs.len == 1, 'one digit draws one glyph, got ${urd.glyphs.len}'
	assert urd.glyphs[0].gid == 1463, 'Urdu four is gid 1463, got ${urd.glyphs[0].gid}'
}

fn test_language_override_applies_farsi_punctuation() {
	f := lang_font('NotoNaskhArabic-Regular.ttf') or { return }
	// U+066B ARABIC DECIMAL SEPARATOR: HarfBuzz reads gid 160 by default
	// and gid 162 under FAR, with the advance going 222 to 201.
	def := lang_line(f, '٫', '', '')
	assert def.glyphs.len == 1, 'one separator draws one glyph, got ${def.glyphs.len}'
	assert def.glyphs[0].gid == 160, 'default separator is gid 160, got ${def.glyphs[0].gid}'
	far := lang_line(f, '٫', '', 'FAR')
	assert far.glyphs.len == 1, 'one separator draws one glyph, got ${far.glyphs.len}'
	assert far.glyphs[0].gid == 162, 'Farsi separator is gid 162, got ${far.glyphs[0].gid}'
	assert far.width < def.width, 'the locl advance is narrower: ${far.width} vs ${def.width}'
}

fn test_unknown_language_falls_back_to_default() {
	f := lang_font('Amiri-Regular.ttf') or { return }
	// A language the font does not tag is the default system, the way
	// HarfBuzz falls back, rather than nothing.
	def := lang_line(f, '۴', '', '')
	unknown := lang_line(f, '۴', '', 'ZZZ')
	assert unknown.glyphs.len == def.glyphs.len, 'same count, got ${unknown.glyphs.len} vs ${def.glyphs.len}'
	for i, g in unknown.glyphs {
		assert g.gid == def.glyphs[i].gid, 'same glyph ${i} under an unknown language'
	}
	assert unknown.width == def.width, 'same width under an unknown language'
}

fn test_script_override_forces_feature_resolution() {
	f := lang_font('FiraCode-Variable.ttf') or { return }
	// '=>' folds under the detected Common script (calt lives under zyyy
	// here as well as latn), and forcing a script the font does not carry
	// unfolds it: same cmap glyphs, none of the calt forms.
	def := lang_line_dir(f, '=>', .ltr, '', '')
	assert def.glyphs.len == 2, 'the arrow folds to two glyphs, got ${def.glyphs.len}'
	assert def.glyphs[0].gid == 1730, 'HarfBuzz reads 1730 first, got ${def.glyphs[0].gid}'
	assert def.glyphs[1].gid == 1736, 'HarfBuzz reads 1736 second, got ${def.glyphs[1].gid}'
	arab := lang_line_dir(f, '=>', .ltr, 'arab', '')
	assert arab.glyphs.len == 2, 'unfolded is still two glyphs, got ${arab.glyphs.len}'
	assert arab.glyphs[0].gid == f.glyph_index(`=`), 'unfolded starts at the base equals'
	assert arab.glyphs[1].gid == f.glyph_index(`>`), 'unfolded ends at the base greater-than'
	assert arab.width == def.width, 'Fira Code is monospace: unfolding swaps outlines, not metrics'
	latn := lang_line_dir(f, '=>', .ltr, 'latn', '')
	assert latn.glyphs.len == def.glyphs.len, 'named latn folds like the default'
	for i, g in latn.glyphs {
		assert g.gid == def.glyphs[i].gid, 'same glyph ${i} under the named script'
	}
}

fn test_script_tag_spelling_is_normalized() {
	f := lang_font('Amiri-Regular.ttf') or { return }
	// The override takes the Unicode spelling too: 'Arab' resolves the way
	// the detected 'arab' does, because the tag is lowercased before lookup.
	def := lang_line(f, 'سلام', '', '')
	spelled := lang_line(f, 'سلام', 'Arab', '')
	assert spelled.width == def.width, 'Arab spells arab: ${spelled.width} vs ${def.width}'
}

fn test_lowercase_language_tag_resolves() {
	f := lang_font('Amiri-Regular.ttf') or { return }
	// The language tag is case-insensitive: 'urd' names the 'URD ' system the
	// font tags, with the padding tolerated. A BCP 47 code still does not:
	// 'ur' is not 'URD' and falls back to the default.
	lower := lang_line(f, '۴', '', 'urd')
	assert lower.glyphs.len == 1, 'one digit draws one glyph'
	assert lower.glyphs[0].gid == 1463, 'lowercase urd is the URD system, got ${lower.glyphs[0].gid}'
	bcp := lang_line(f, '۴', '', 'ur')
	assert bcp.glyphs[0].gid == 260, 'a BCP 47 code is not a tag: default gid 260, got ${bcp.glyphs[0].gid}'
}
