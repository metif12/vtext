// Scratch probe: which GSUB feature group costs the most on a Latin run?
module main

import time
import harfara.shape

const iters = 300

fn bench(f &shape.Font, glyphs []shape.Glyph, extra []string) i64 {
	for _ in 0 .. 50 {
		_ = f.substitute_glyphs(glyphs, 'latn', '', 16.0, extra, false)
	}
	mut best := i64(1 << 60)
	mut sink := 0
	for _ in 0 .. 5 {
		start := time.sys_mono_now()
		for _ in 0 .. iters {
			r := f.substitute_glyphs(glyphs, 'latn', '', 16.0, extra, false)
			sink += r.len
		}
		took := i64(time.sys_mono_now() - start) / iters
		if took < best {
			best = took
		}
	}
	if sink == -1 {
		println('')
	}
	return best
}

fn main() {
	f := shape.load_font_file('testdata/fonts/FiraCode-Variable.ttf') or { return }
	mut glyphs := []shape.Glyph{cap: 1024}
	for i in 0 .. 1024 {
		cp := rune(32 + i % 95)
		glyphs << f.glyph_for(cp, 16.0)
	}
	cases := [
		['default', ''],
		['no-calt', '-calt'],
		['no-liga', '-liga'],
		['no-clig', '-clig'],
		['no-liga-clig', '-liga', '-clig'],
		['none-of-three', '-calt', '-liga', '-clig'],
	]
	for case in cases {
		extra := if case.len == 1 { []string{} } else { case[1..] }
		println('${case[0]}: ${bench(f, glyphs, extra)}ns')
	}
}
