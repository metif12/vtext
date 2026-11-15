module vtext

import os
import vtext.shape
import vtext.layout

// Common-base marks: a mark whose base has no script of its own (Common,
// Inherited, Unknown — the dotted circle a dakuten sits on) resolves to the
// neighbouring strong script instead of falling back to arab. The vertical
// slice 2g left this as the known gap: a Common base still resolved arab
// and missed the kana anchors, in horizontal text the same as vertical.
//
// This file pins the fix against HarfBuzz-agreeing anchors on MS Gothic,
// read with fontTools in the font's own design units: the dakuten and the
// handakuten on a dotted circle attach at mark (0, 0) on base (-68, 0) under
// the latn rule — an x shift of -68 — while the arab fallback this replaces
// answers nothing, so the mark used to stay at the pen. HarfBuzz draws the
// same point and reports -766 at its 1000-unit scale, which is that anchor
// measured from the pen (-68 minus the dotted circle's own 128-unit
// advance). The first two tests fail on the old resolution (mark at the
// pen) and pass on the new one (mark anchored).
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

fn msgothic_bytes() ?[]u8 {
	return corpus_font_bytes('msgothic.ttc') or {
		skip_missing('msgothic.ttc')
		return none
	}
}

fn close(got f64, want f64, tol f64) bool {
	d := got - want
	return if d < 0 { -d <= tol } else { d <= tol }
}

// A dakuten on a dotted circle in Latin text resolves latn, the neighbouring
// strong script, and lands on the latn anchor: mark (0, 0) on base (-68, 0),
// an x shift of -68 design units. The old arab fallback answers nothing —
// our reader finds no arab rule for the pair, so the mark stayed at the pen —
// and HarfBuzz agrees with the anchored point, reporting -766 at its
// 1000-unit scale, which is the same point measured from the pen (-68 minus
// the dotted circle's own 128-unit advance). Fails before the fix (mark at
// the pen), passes after (mark anchored).
fn test_common_base_resolves_neighbour_script() {
	data := msgothic_bytes() or { return }
	original := shape.load_font_bytes(data) or { panic(err) }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(original)
	em_px := 32.0
	scale := em_px / f64(original.face.units_per_em)
	line := layout.layout_paragraph(ctx, 'a◌゙'.runes(), .ltr, fs, em_px)
	mut base_x := 0.0
	mut found := false
	for g in line.glyphs {
		if g.is_mark {
			assert close(g.x, base_x - 68.0 * scale, 0.01), 'dakuten at ${g.x}, base at ${base_x}'
			assert close(g.y, 0.0, 0.01), 'dakuten y ${g.y}'
			found = true
		} else if g.cluster == 1 {
			base_x = g.x
		}
	}
	assert found, 'the dakuten has to be on the line to say anything'
}

// Its sibling: the handakuten attaches at the same anchor.
fn test_common_base_handakuten_sibling() {
	data := msgothic_bytes() or { return }
	original := shape.load_font_bytes(data) or { panic(err) }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(original)
	em_px := 32.0
	scale := em_px / f64(original.face.units_per_em)
	line := layout.layout_paragraph(ctx, 'a◌゚'.runes(), .ltr, fs, em_px)
	mut base_x := 0.0
	mut found := false
	for g in line.glyphs {
		if g.is_mark {
			assert close(g.x, base_x - 68.0 * scale, 0.01), 'handakuten at ${g.x}, base at ${base_x}'
			assert close(g.y, 0.0, 0.01)
			found = true
		} else if g.cluster == 1 {
			base_x = g.x
		}
	}
	assert found, 'the handakuten has to be on the line to say anything'
}

// A strong base is untouched by the neighbour search: あ carries Hira, which
// folds to kana exactly as before, and the dakuten lands on the kana anchor
// fontTools reads — mark (0, 0) on base (18, 12), the (18 right, 12 up) the
// vertical slice measured. HarfBuzz draws the same point, reporting -930 at
// its 1000-unit scale, which is that anchor measured from the pen (18 minus
// the あ advance of 256). This is the revert guard for the 2g path: it
// passes before and after, and fails if the strong-base answer ever moves.
fn test_strong_base_keeps_its_own_script() {
	data := msgothic_bytes() or { return }
	original := shape.load_font_bytes(data) or { panic(err) }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(original)
	em_px := 32.0
	scale := em_px / f64(original.face.units_per_em)
	line := layout.layout_paragraph(ctx, 'あ゙'.runes(), .ltr, fs, em_px)
	mut base_x := 0.0
	mut found := false
	for g in line.glyphs {
		if g.is_mark {
			assert close(g.x, base_x + 18.0 * scale, 0.01), 'dakuten at ${g.x}, base at ${base_x}'
			assert close(g.y, -12.0 * scale, 0.01), 'dakuten y ${g.y}'
			found = true
		} else if g.cluster == 0 {
			base_x = g.x
		}
	}
	assert found, 'the dakuten has to be on the line to say anything'
}

// With no strong character on either side there is no neighbour to resolve
// to, so the answer keeps arab — the historical default — and a fatha on a
// tatweel lands on the arab anchor fontTools reads: mark (258, 801) on base
// (93, 801), an x shift of -165 design units. This pins the last resort, so
// a neighbour search that invents scripts fails here.
fn test_no_strong_neighbour_keeps_arab() {
	data := corpus_font_bytes('Amiri-Regular.ttf') or {
		skip_missing('Amiri-Regular.ttf')
		return
	}
	original := shape.load_font_bytes(data) or { panic(err) }
	ctx := shape.new_context()
	mut fs := shape.new_font_set()
	fs.add(original)
	em_px := 32.0
	scale := em_px / f64(original.face.units_per_em)
	line := layout.layout_paragraph(ctx, 'ـً'.runes(), .rtl, fs, em_px)
	mut base_x := 0.0
	mut found := false
	for g in line.glyphs {
		if g.is_mark {
			assert close(g.x, base_x - 165.0 * scale, 0.01), 'fatha at ${g.x}, base at ${base_x}'
			assert close(g.y, 0.0, 0.01), 'fatha y ${g.y}'
			found = true
		} else if g.cluster == 0 {
			base_x = g.x
		}
	}
	assert found, 'the fatha has to be on the line to say anything'
}
