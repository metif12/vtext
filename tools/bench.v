module main

// Bench for layout throughput: the harness an optimization lands against.
//
// Best of five batches, because a loaded box lies about absolutes and the
// ratio is the finding. Paragraphs of 128, 256, 512 and 1024 characters at 16
// pixels, Latin on Segoe UI and Arabic on the corpus Amiri, because the kern
// walk this measures against behaves differently on the two: a Latin font
// carries no chaining kerns and an Arabic one carries a dozen.
//
// Usage: v -gc none -cc tcc run tools/bench.v
// The numbers below it print are the whole result; there is no baseline file
// to go stale, because a baseline that lives in the tree is a number nobody
// re-measures.

import os
import time
import vtext
import vtext.shape
import vtext.layout

fn load_font(paths []string) &shape.Font {
	for r in paths {
		if os.exists(r) {
			return shape.load_font_file(r) or { panic(err) }
		}
	}
	panic('no font found in ${paths}')
}

fn repeat_to(text string, n int) []rune {
	mut out := []rune{cap: n + 8}
	base := text.runes()
	for out.len < n {
		if out.len > 0 {
			out << rune(` `)
		}
		for c in base {
			if out.len >= n {
				break
			}
			out << c
		}
	}
	return out
}

struct Case {
	name  string
	cps   []rune
	base  shape.Direction
	fonts &shape.FontSet
}

fn best_of(ctx &shape.Context, c Case, em_px f64) (i64, i64) {
	mut best := i64(1 << 60)
	mut glyphs := 0
	for _ in 0 .. 5 {
		start := time.sys_mono_now()
		for _ in 0 .. 20 {
			line := layout.layout_paragraph(ctx, c.cps, c.base, c.fonts, em_px)
			glyphs = line.glyphs.len
		}
		took := i64(time.sys_mono_now() - start)
		if took < best {
			best = took
		}
	}
	return best / 20, glyphs
}

fn main() {
	ctx := shape.new_context()
	latin_font := load_font(['C:\\Windows\\Fonts\\segoeui.ttf',
		'testdata/fonts/NotoNaskhArabic-Regular.ttf'])
	arabic_font := load_font(['testdata/fonts/Amiri-Regular.ttf'])
	// Segoe UI is tried first for Latin where it exists, because the historical
	// numbers were measured on it; the corpus face elsewhere so the bench runs
	// anywhere.
	mut latin_fs := shape.new_font_set()
	latin_fs.add(latin_font)
	mut arabic_fs := shape.new_font_set()
	arabic_fs.add(arabic_font)
	latin_text := 'The quick brown fox jumps over the lazy dog near the river bank at dusk'
	arabic_text := 'سلام دنیا بر شما ای دوست قدیمی من'
	for size in [128, 256, 512, 1024] {
		lc := Case{
			name:  'latin-${size}'
			cps:   repeat_to(latin_text, size)
			base:  .ltr
			fonts: latin_fs
		}
		took, glyphs := best_of(ctx, lc, 16.0)
		per := f64(took) / f64(glyphs)
		println('${lc.name}: ${took / 1000} us for ${glyphs} glyphs, ${per:.1f} ns/glyph')
		ac := Case{
			name:  'arabic-${size}'
			cps:   repeat_to(arabic_text, size)
			base:  .rtl
			fonts: arabic_fs
		}
		atook, aglyphs := best_of(ctx, ac, 16.0)
		aper := f64(atook) / f64(aglyphs)
		println('${ac.name}: ${atook / 1000} us for ${aglyphs} glyphs, ${aper:.1f} ns/glyph')
	}
}
