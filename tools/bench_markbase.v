// Interleaved single-process A/B for the mark base search: the old per-mark
// walk over the bases hash map against one read of the cand_base array that
// F2c already computes from the same keys. Both are asserted equal for every
// mark before timing. Best-of interleaved; the ratio is the finding.
module main

import time

const iters = 400

fn win_map(bases map[int][]int, cluster int) int {
	mut win := -1
	for c, _ in bases {
		if c <= cluster && (win < 0 || c > win) {
			win = c
		}
	}
	return win
}

fn win_array(sorted []int, cluster int) int {
	mut lo := 0
	mut hi := sorted.len
	for lo < hi {
		mid := (lo + hi) >> 1
		if sorted[mid] <= cluster {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return if lo > 0 { sorted[lo - 1] } else { -1 }
}

fn bench(bases map[int][]int, sorted []int, clusters []int, use_map bool) i64 {
	for _ in 0 .. 20 {
		for c in clusters {
			_ = if use_map { win_map(bases, c) } else { win_array(sorted, c) }
		}
	}
	mut best := i64(1 << 60)
	mut sink := 0
	for _ in 0 .. 7 {
		start := time.sys_mono_now()
		for _ in 0 .. iters {
			for c in clusters {
				sink += if use_map { win_map(bases, c) } else { win_array(sorted, c) }
			}
		}
		took := i64(time.sys_mono_now() - start) / iters
		if took < best {
			best = took
		}
	}
	if sink < -1 << 40 {
		println('')
	}
	return best
}

fn main() {
	// A long marked line: ~700 base clusters and ~300 marks spread over them.
	mut bases := map[int][]int{}
	mut sorted := []int{cap: 700}
	for i in 0 .. 700 {
		c := i * 2
		bases[c] = [i]
		sorted << c
	}
	mut clusters := []int{cap: 300}
	for i in 0 .. 300 {
		clusters << 3 + i * 4
	}
	for c in clusters {
		assert win_map(bases, c) == win_array(sorted, c), 'the two answers must agree'
	}

	mut map_best := i64(1 << 60)
	mut arr_best := i64(1 << 60)
	for _ in 0 .. 3 {
		m := bench(bases, sorted, clusters, true)
		a := bench(bases, sorted, clusters, false)
		if m < map_best {
			map_best = m
		}
		if a < arr_best {
			arr_best = a
		}
	}
	println('mark base search 300 marks / 700 bases: map=${map_best}ns array=${arr_best}ns ratio=${f64(map_best) / f64(arr_best):.2f}x')
}
