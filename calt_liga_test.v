module harfara

import os
import harfara.shape
import harfara.layout

// Code ligatures: calt, liga and clig are on by default, the way HarfBuzz and
// every code editor leave them, and a `-tag` entry turns one back off. This
// file pins the behavior against HarfBuzz-measured glyph ids on real fonts:
// Fira Code draws `=>` as two full-width calt alternates (not one fused
// glyph), and Amiri fuses Latin `fi` through liga. Discretionary pairs stay
// off — Tahoma's dlig `fi` is pinned by
// test_discretionary_features_are_off_unless_asked_for in gsub_test.v, which
// this change leaves green by construction.

// This copy lives here because `v test <single_file>` compiles that file and
// not its siblings, so a helper in another test file is one this file cannot
// see.
fn corpus_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('HARFARA_TEST_FONTS'), 'testdata/fonts', windows_font_dir()] {
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
	path := os.getenv('HARFARA_SKIP_LOG')
	if path != '' {
		mut f := os.open_append(path) or { return }
		f.writeln(line) or { return }
		f.close()
		return
	}
	println(line)
}

// Fira Code is the programming-ligature face: its `=>` is a calt rule, drawn
// as two full-width alternates the way a monospace grid requires, and both
// formulation and measurement come from the committed variable font at its
// default instance — the same instance HarfBuzz shapes beside.
fn fira() ?&shape.Font {
	data := corpus_font_bytes('FiraCode-Variable.ttf') or {
		skip_missing('FiraCode-Variable.ttf')
		return none
	}
	return shape.load_font_bytes(data) or { panic(err) }
}

// An arrow is two alternates, not one ligature: Fira Code keeps the monospace
// grid by substituting each character in place. HarfBuzz TTB... LTR with no
// features asked shapes `=>` as gids 1730 and 1736, and the line below has to
// agree without being asked.
fn test_calt_fuses_the_code_arrow_by_default() {
	fira() or { return }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(fira() or { return })
	line := layout.layout_paragraph(ctx, '=>'.runes(), .ltr, fs, 32.0)
	assert line.glyphs.len == 2
	assert line.glyphs[0].gid == 1730, 'the = draws its arrow alternate'
	assert line.glyphs[1].gid == 1736, 'the > draws its arrow alternate'
	assert line.glyphs[0].advance == 19.2, '1200 of 2000 units at 32 px'
	assert line.glyphs[1].advance == 19.2, 'full width keeps the grid'
	assert line.glyphs[0].cluster == 0 && line.glyphs[1].cluster == 1
	assert !line.glyphs[0].is_mark && !line.glyphs[1].is_mark
}

// The editor toggle: `-calt` draws the two plain glyphs HarfBuzz shapes with
// calt off, 1225 and 1227.
fn test_calt_off_draws_two_plain_glyphs() {
	fira() or { return }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(fira() or { return })
	opts := &layout.LayoutOptions{
		features: ['-calt']
	}
	line := layout.layout_paragraph_with(ctx, '=>'.runes(), .ltr, fs, 32.0, opts)
	assert line.glyphs.len == 2
	assert line.glyphs[0].gid == 1225, 'the = stays itself'
	assert line.glyphs[1].gid == 1227, 'the > stays itself'
}

// Naming a default-on feature changes nothing: `+calt` is the bare tag
// spelled explicitly, for generated lists.
fn test_calt_named_explicitly_matches_the_default() {
	fira() or { return }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(fira() or { return })
	opts := &layout.LayoutOptions{
		features: ['+calt']
	}
	line := layout.layout_paragraph_with(ctx, '=>'.runes(), .ltr, fs, 32.0, opts)
	assert line.glyphs.len == 2
	assert line.glyphs[0].gid == 1730 && line.glyphs[1].gid == 1736
}

// Amiri fuses Latin `fi` through liga: HarfBuzz with no features asked shapes
// it as the single gid 6630 at 519 units, and the default line has to agree.
fn test_liga_fuses_fi_by_default() {
	data := corpus_font_bytes('Amiri-Regular.ttf') or {
		skip_missing('Amiri-Regular.ttf')
		return
	}
	original := shape.load_font_bytes(data) or { panic(err) }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(original)
	line := layout.layout_paragraph(ctx, 'fi'.runes(), .ltr, fs, 32.0)
	assert line.glyphs.len == 1
	assert line.glyphs[0].gid == 6630, 'f and i draw the f+i ligature'
	assert line.glyphs[0].advance == 16.608, '519 of 1000 units at 32 px'
	assert line.glyphs[0].cluster == 0, 'the fused glyph reports its first character'
}

// And `-liga` leaves the two letters HarfBuzz shapes with liga off.
fn test_liga_off_leaves_two_letters() {
	data := corpus_font_bytes('Amiri-Regular.ttf') or {
		skip_missing('Amiri-Regular.ttf')
		return
	}
	original := shape.load_font_bytes(data) or { panic(err) }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(original)
	opts := &layout.LayoutOptions{
		features: ['-liga']
	}
	line := layout.layout_paragraph_with(ctx, 'fi'.runes(), .ltr, fs, 32.0, opts)
	assert line.glyphs.len == 2
	assert line.glyphs[0].gid == 6261 && line.glyphs[1].gid == 6264
}

// Naming a default-on feature bare applies it once, not twice: `liga` on
// `fi` is the fused 6630 the default draws, which a double application
// would have to reproduce exactly to stay green.
fn test_liga_named_bare_matches_the_default() {
	data := corpus_font_bytes('Amiri-Regular.ttf') or {
		skip_missing('Amiri-Regular.ttf')
		return
	}
	original := shape.load_font_bytes(data) or { panic(err) }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(original)
	opts := &layout.LayoutOptions{
		features: ['liga']
	}
	line := layout.layout_paragraph_with(ctx, 'fi'.runes(), .ltr, fs, 32.0, opts)
	assert line.glyphs.len == 1
	assert line.glyphs[0].gid == 6630
}

// The last spelling of one tag wins: `-calt` then `calt` turns the arrow
// alternates back on, and the reverse order leaves the two plain glyphs.
fn test_last_spelling_of_a_tag_wins() {
	fira() or { return }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(fira() or { return })
	on := &layout.LayoutOptions{
		features: ['-calt', 'calt']
	}
	redrawn := layout.layout_paragraph_with(ctx, '=>'.runes(), .ltr, fs, 32.0, on)
	assert redrawn.glyphs.len == 2
	assert redrawn.glyphs[0].gid == 1730 && redrawn.glyphs[1].gid == 1736
	off := &layout.LayoutOptions{
		features: ['+calt', '-calt']
	}
	plain := layout.layout_paragraph_with(ctx, '=>'.runes(), .ltr, fs, 32.0, off)
	assert plain.glyphs.len == 2
	assert plain.glyphs[0].gid == 1225 && plain.glyphs[1].gid == 1227
}
