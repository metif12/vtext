// Interleaved A/B for place_glyphs: the shipped dense-array fast path against
// the general map path, forced by one negative cluster (that glyph is undrawn,
// which changes the output by one but not the walk). A reference dense copy
// asserts the shipped path is the same function before timing. Best-of interleaved
// keeps a loaded box from deciding the result; the ratio is the finding.
module main

import time
import vtext.shape
import vtext.layout

const iters = 1500

fn dense_place_glyphs(placed []shape.Glyph, bidi shape.BidiResult, origin []int) []shape.Glyph {
	mut out := []shape.Glyph{cap: placed.len}
	mut max_idx := 0
	for g in placed {
		if g.cluster > max_idx {
			max_idx = g.cluster
		}
	}
	for v in bidi.visual_order {
		orig := if v < origin.len { origin[v] } else { v }
		if orig > max_idx {
			max_idx = orig
		}
	}
	n := max_idx + 1
	mut by_cluster := [][]int{len: n}
	mut drawn := []bool{len: n, init: false}
	for i, g in placed {
		by_cluster[g.cluster] << i
	}
	mut x := f64(0)
	for v in bidi.visual_order {
		if !bidi.visible[v] {
			continue
		}
		orig := if v < origin.len { origin[v] } else { v }
		if drawn[orig] {
			continue
		}
		drawn[orig] = true
		for i in by_cluster[orig] {
			mut g := placed[i]
			g.x += x
			out << g
			x += g.advance
		}
	}
	return out
}

fn bench(placed []shape.Glyph, bidi shape.BidiResult, origin []int, force_maps bool) i64 {
	// One negative cluster takes the public entry point's general map path;
	// the glyph is undrawn, which changes the output by one but not the walk.
	mut p := placed
	if force_maps {
		p = placed.clone()
		p[0].cluster = -1
	}
	for _ in 0 .. 200 {
		_ = layout.place_glyphs(p, bidi, origin)
	}
	mut best := i64(1 << 60)
	mut sink := f64(0)
	for _ in 0 .. 7 {
		start := time.sys_mono_now()
		for _ in 0 .. iters {
			r := layout.place_glyphs(p, bidi, origin)
			sink += r[r.len - 1].x
		}
		took := i64(time.sys_mono_now() - start) / iters
		if took < best {
			best = took
		}
	}
	if sink < 0 {
		println('')
	}
	return best
}

fn assert_same(placed []shape.Glyph, bidi shape.BidiResult, origin []int) {
	a := layout.place_glyphs(placed, bidi, origin)
	b := dense_place_glyphs(placed, bidi, origin)
	assert a.len == b.len
	for i in 0 .. a.len {
		assert a[i].x == b[i].x && a[i].gid == b[i].gid && a[i].cluster == b[i].cluster
	}
}

fn main() {
	n := 1024
	mut placed := []shape.Glyph{cap: n}
	mut bidi := shape.BidiResult{
		levels:          []u8{len: n, init: 0}
		visible:         []bool{len: n, init: true}
		visual_order:    []int{len: n}
		paragraph_level: 0
	}
	mut origin := []int{len: n}
	for i in 0 .. n {
		placed << shape.Glyph{ gid: u16(i % 200), advance: 8.0, cluster: i }
		bidi.visual_order[i] = i
		origin[i] = i
	}

	assert_same(placed, bidi, origin)

	// Harder case: ligature-merged clusters, RTL visual order, two decomposed
	// characters from one original, and an X9-invisible character. The dense
	// version must still be the same function on all of them.
	mut placed2 := []shape.Glyph{cap: 6}
	for g in 0 .. 6 {
		placed2 << shape.Glyph{ gid: u16(g), advance: 4.0, cluster: g / 2 }
	}
	mut bidi2 := shape.BidiResult{
		levels:          []u8{len: 6, init: 1}
		visible:         []bool{len: 6, init: true}
		visual_order:    [5, 4, 3, 2, 1, 0]
		paragraph_level: 1
	}
	bidi2.visible[3] = false
	assert_same(placed2, bidi2, [0, 1, 1, 2, 3, 4])

	mut maps_best := i64(1 << 60)
	mut dense_best := i64(1 << 60)
	for _ in 0 .. 3 {
		m := bench(placed, bidi, origin, true)
		d := bench(placed, bidi, origin, false)
		if m < maps_best {
			maps_best = m
		}
		if d < dense_best {
			dense_best = d
		}
	}
	println('place_glyphs 1024: maps=${maps_best}ns dense=${dense_best}ns ratio=${f64(maps_best) / f64(dense_best):.2f}x')
}
