// Interleaved A/B for shape_arabic on ASCII: the shipped ASCII fast path against
// the full UCD walk, forced by replacing one character with U+00E9 (joining type
// U, script Latn, no mark, so the same shape). Everything except that one glyph
// is asserted equal before timing. Best-of interleaved; the ratio is the finding.
module main

import time
import vtext.shape

const iters = 1500

fn same_except_first(a shape.ShapedRun, b shape.ShapedRun) bool {
	if a.glyphs.len != b.glyphs.len {
		return false
	}
	for i in 1 .. a.glyphs.len {
		x := a.glyphs[i]
		y := b.glyphs[i]
		if x.cps != y.cps || x.base != y.base || x.form != y.form || x.script != y.script
			|| x.start != y.start || x.end != y.end || x.is_mark != y.is_mark
			|| x.selectors != y.selectors {
			return false
		}
	}
	return true
}

fn bench(ctx &shape.Context, cps []rune, fast bool) i64 {
	for _ in 0 .. 200 {
		_ = ctx.shaper.shape_arabic(ctx.properties, cps)
	}
	mut best := i64(1 << 60)
	mut sink := 0
	for _ in 0 .. 7 {
		start := time.sys_mono_now()
		for _ in 0 .. iters {
			r := ctx.shaper.shape_arabic(ctx.properties, cps)
			sink += r.glyphs.len
		}
		took := i64(time.sys_mono_now() - start) / iters
		if took < best {
			best = took
		}
	}
	if sink == -1 || !fast {
		println('')
	}
	return best
}

fn main() {
	ctx := shape.new_context()
	mut fast_cps := []rune{cap: 1024}
	for i in 0 .. 1024 {
		fast_cps << if i % 97 == 0 { rune(`\t`) } else { rune(32 + i % 95) }
	}
	mut slow_cps := fast_cps.clone()
	slow_cps[0] = 0x00e9

	fast := ctx.shaper.shape_arabic(ctx.properties, fast_cps)
	slow := ctx.shaper.shape_arabic(ctx.properties, slow_cps)
	assert same_except_first(fast, slow), 'fast path must be the same function'

	mut slow_best := i64(1 << 60)
	mut fast_best := i64(1 << 60)
	for _ in 0 .. 3 {
		s := bench(ctx, slow_cps, false)
		f := bench(ctx, fast_cps, true)
		if s < slow_best {
			slow_best = s
		}
		if f < fast_best {
			fast_best = f
		}
	}
	println('shape_arabic 1024 ASCII: full=${slow_best}ns ascii=${fast_best}ns ratio=${f64(slow_best) / f64(fast_best):.2f}x')
}
