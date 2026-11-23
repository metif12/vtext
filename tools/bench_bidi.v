// Focused A/B for the ASCII bidi fast path: resolve_paragraph on 4096 ASCII
// characters against the same class sequence with one L replaced by U+00E9,
// which forces the full UAX9 walk. Interleaved best-of so a loaded box moves
// both sides alike; the ratio is the finding, not either absolute.
module main

import time
import harfara.shape
import harfara.ucd

const iters = 1500

fn bench(p &ucd.Properties, cps []rune) i64 {
	for _ in 0 .. 200 {
		_ = shape.resolve_paragraph(p, cps, .ltr)
	}
	mut best := i64(1 << 60)
	mut sink := 0
	for _ in 0 .. 7 {
		start := time.sys_mono_now()
		for _ in 0 .. iters {
			r := shape.resolve_paragraph(p, cps, .ltr)
			sink += r.levels.len + r.sequences.len
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
	p := ucd.new_properties()
	base := 'abcdefghijklmnopqrstuvwxyz0123456789 ():;.,-/\t'.runes()
	mut fast := []rune{cap: 4096}
	for i in 0 .. 4096 {
		fast << base[i % base.len]
	}
	// One Arabic letter forces the slow path over otherwise identical text.
	mut slow := fast.clone()
	slow[2048] = 0x0628

	// Interleave so machine noise hits both measurements alike.
	mut fast_best := i64(1 << 60)
	mut slow_best := i64(1 << 60)
	for _ in 0 .. 3 {
		f := bench(p, fast)
		s := bench(p, slow)
		if f < fast_best {
			fast_best = f
		}
		if s < slow_best {
			slow_best = s
		}
	}
	println('ASCII 4096 fast=${fast_best}ns slow=${slow_best}ns ratio=${f64(slow_best) / f64(fast_best):.2f}x')
}
