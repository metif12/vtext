module main

import vtext.shape
import vtext.raster

// Flattened stroker over the FiraCode A outline.
//
// The pins below are this engine's own outputs, exact, so any change in the
// offsetting, the joins, the caps, the miter limit or the flattening fails
// loudly. The A outline is all on-curve lines (eleven points, two contours),
// which is what makes it a pure join-and-limit probe: the mitered stroke
// keeps every spike (22 points), the bevel cuts them (33 points), the round
// join arcs them (94 points), and a miter limit of 1.0 falls back to the
// bevel exactly. Caps ride a synthetic open spine beside it, and a synthetic
// off-curve triangle proves the quadratic flattening: a fine tolerance draws
// more points than a coarse one. The break-fix control at the bottom neuters
// the join and the limit and watches the ink move.

// stroke_test_font loads the corpus face this file pins.
fn stroke_test_font() &shape.Font {
	return shape.load_font_file('testdata/fonts/FiraCode-Variable.ttf') or {
		panic('stroke test needs testdata/fonts/FiraCode-Variable.ttf: ${err}')
	}
}

// stroke_test_a strokes the A glyph with the caller's options.
fn stroke_test_a(opt raster.StrokeOptions) raster.StrokedOutline {
	f := stroke_test_font()
	gid := f.face.glyph_index(`A`)
	o := f.face.glyph_outline(gid) or { panic('stroke test needs the A outline: ${err}') }
	assert o.n_points() == 11, 'A has eleven points, got ${o.n_points()}'
	assert o.n_contours() == 2, 'A has two contours, got ${o.n_contours()}'
	return raster.stroke_outline(o.xs, o.ys, o.on_curve, o.end_pts, opt)
}

// stroke_test_opt answers a 40-design-unit stroke with the given join/limit.
fn stroke_test_opt(join raster.StrokeLineJoin, limit f64) raster.StrokeOptions {
	return raster.StrokeOptions{
		radius:      40.0
		line_cap:    raster.StrokeLineCap.butt
		line_join:   join
		miter_limit: limit
		tolerance:   1.0
	}
}

// stroke_close reports whether two areas agree within tol.
fn stroke_close(got f64, want f64, tol f64) bool {
	mut d := got - want
	if d < 0 {
		d = -d
	}
	return d <= tol
}

// The mitered A strokes to two loops per contour with the spikes kept: the
// box grows by the radius past every straight edge, and the ink is the ring
// between the outer and inner loops. No trigonometry runs on this path, so
// every number below is deterministic — but exact only per platform: the
// miter joints divide and normalize, and C allows contraction (FMA) that
// clang and gcc take differently, so macOS lands 1-2 ulps from the pins
// below. The 1e-9 tolerance absorbs that libm noise with four orders of
// margin while any geometry change moves the ink by whole units (the
// break-fix at the bottom moves it by thousands).
fn test_stroke_a_mitered_loops_and_box() {
	st := stroke_test_a(stroke_test_opt(raster.StrokeLineJoin.miter, 4.0))
	assert st.n_contours() == 4, 'two closed contours stroke to four loops, got ${st.n_contours()}'
	assert st.n_points() == 22, 'the mitered A has 22 points, got ${st.n_points()}'
	x0, y0, x1, y1 := st.bbox()
	assert stroke_close(x0, 4.6178374606562755, 1e-9), 'mitered x0 is 4.6178, got ${x0}'
	assert y0 == -40.0, 'mitered y0 is -40, got ${y0}'
	assert stroke_close(x1, 1195.4204354056494, 1e-9), 'mitered x1 is 1195.42, got ${x1}'
	assert y1 == 1414.0, 'mitered y1 is 1414, got ${y1}'
	assert stroke_close(st.area(), 543934.8360647284, 1e-9), 'mitered ink is 543934.83, got ${st.area()}'
}

// Joins change the ink: bevel cuts every outer corner and fills the notches
// less, so its ring is larger than the miter's here; round sits between.
// The bevel path is trigonometry-free, so its numbers are deterministic
// per platform with the same 1-ulp cross-platform noise as the miter's,
// hence the same 1e-9 pins.
fn test_stroke_joins_change_ink() {
	miter := stroke_test_a(stroke_test_opt(raster.StrokeLineJoin.miter, 4.0))
	bevel := stroke_test_a(stroke_test_opt(raster.StrokeLineJoin.bevel, 4.0))
	round := stroke_test_a(stroke_test_opt(raster.StrokeLineJoin.round, 4.0))
	assert bevel.n_contours() == 4 && round.n_contours() == 4
	assert bevel.n_points() == 33, 'the beveled A has 33 points, got ${bevel.n_points()}'
	assert round.n_points() == 94, 'the round-joined A has 94 points, got ${round.n_points()}'
	assert stroke_close(bevel.area(), 556571.5765320654, 1e-9), 'beveled ink is 556571.57, got ${bevel.area()}'
	assert stroke_close(round.area(), 550718.7737340531, 0.5), 'round ink drifts: ${round.area()}'
	assert bevel.area() > round.area(), 'bevel ${bevel.area()} must exceed round ${round.area()}'
	assert round.area() > miter.area(), 'round ${round.area()} must exceed miter ${miter.area()}'
	x0, y0, x1, y1 := bevel.bbox()
	assert stroke_close(x0, 4.6178374606562755, 1e-9) && y0 == -40.0
		&& stroke_close(x1, 1195.4204354056494, 1e-9) && y1 == 1414.0
}

// The miter limit falls back to bevel corner by corner: 1.0 keeps no miter
// and answers the bevel exactly, 2.0 keeps all but one, 100 keeps all.
fn test_stroke_miter_limit_falls_back_to_bevel() {
	bevel := stroke_test_a(stroke_test_opt(raster.StrokeLineJoin.bevel, 4.0))
	flat := stroke_test_a(stroke_test_opt(raster.StrokeLineJoin.miter, 1.0))
	assert flat.n_points() == bevel.n_points(), 'limit 1.0 answers the bevel point for point'
	assert flat.area() == bevel.area(), 'limit 1.0 answers the bevel ink exactly'
	partial := stroke_test_a(stroke_test_opt(raster.StrokeLineJoin.miter, 2.0))
	assert partial.n_points() == 23, 'limit 2.0 keeps all but one miter, got ${partial.n_points()}'
	assert stroke_close(partial.area(), 548396.0769625083, 1e-9), 'limit 2.0 ink is 548396.07, got ${partial.area()}'
	wide := stroke_test_a(stroke_test_opt(raster.StrokeLineJoin.miter, 100.0))
	assert wide.n_points() == 22, 'limit 100 keeps every miter'
	assert stroke_close(wide.area(), 543934.8360647284, 1e-9), 'limit 100 answers the miter ink'
}

// Caps close an open spine: butt cuts flush, square extends a radius past
// each end, round draws the semicircle. The square path is exact; the round
// cap is a twelve-segment polygon, so its ink trails the true semicircle.
fn test_stroke_caps_extend_open_path() {
	for cap in [raster.StrokeLineCap.butt, raster.StrokeLineCap.square, raster.StrokeLineCap.round] {
		opt := raster.StrokeOptions{
			radius:      50.0
			line_cap:    cap
			line_join:   raster.StrokeLineJoin.miter
			miter_limit: 4.0
			tolerance:   1.0
		}
		st := raster.stroke_open_polyline([f64(0), 600], [f64(0), 0], opt)
		assert st.n_contours() == 1, 'an open spine strokes to one loop'
		x0, y0, x1, y1 := st.bbox()
		if cap == raster.StrokeLineCap.butt {
			assert st.n_points() == 4, 'butt has four points, got ${st.n_points()}'
			assert x0 == 0 && x1 == 600 && y0 == -50.0 && y1 == 50.0
			assert st.area() == 60000.0, 'butt ink is the 600 by 100 bar, got ${st.area()}'
		} else if cap == raster.StrokeLineCap.square {
			assert st.n_points() == 8, 'square has eight points, got ${st.n_points()}'
			assert x0 == -50.0 && x1 == 650.0 && y0 == -50.0 && y1 == 50.0
			assert st.area() == 70000.0, 'square ink is the 700 by 100 bar, got ${st.area()}'
		} else {
			assert st.n_points() == 26, 'round has 26 points, got ${st.n_points()}'
			assert x0 == -50.0 && x1 == 650.0 && y0 == -50.0 && y1 == 50.0
			assert stroke_close(st.area(), 67764.57135307562, 0.5), 'round cap ink drifts: ${st.area()}'
		}
	}
}

// A round join on an open elbow arcs the outer corner: twelve points, the
// box reaching a radius past every side, the ink past the barest bar.
fn test_stroke_open_elbow_round_join() {
	opt := raster.StrokeOptions{
		radius:      30.0
		line_cap:    raster.StrokeLineCap.butt
		line_join:   raster.StrokeLineJoin.round
		miter_limit: 4.0
		tolerance:   1.0
	}
	st := raster.stroke_open_polyline([f64(0), 400, 400], [f64(0), 0, 300], opt)
	assert st.n_contours() == 1
	assert st.n_points() == 12, 'the round elbow has 12 points, got ${st.n_points()}'
	x0, y0, x1, y1 := st.bbox()
	assert x0 == 0 && y0 == -30.0 && x1 == 430.0 && y1 == 300.0
	assert stroke_close(st.area(), 42201.18857822319, 0.5), 'elbow ink drifts: ${st.area()}'
}

// Flattening answers the curves: a fine tolerance draws the off-curve apex
// with far more points than a coarse one, both as closed loops.
fn test_stroke_flattens_quadratic() {
	xs := [0, 500, 1000, 1000]
	ys := [0, 800, 0, 0]
	onc := [true, false, true, true]
	ends := [3]
	fine := raster.stroke_outline(xs, ys, onc, ends, raster.StrokeOptions{
		radius:      20.0
		line_cap:    raster.StrokeLineCap.butt
		line_join:   raster.StrokeLineJoin.miter
		miter_limit: 4.0
		tolerance:   0.25
	})
	coarse := raster.stroke_outline(xs, ys, onc, ends, raster.StrokeOptions{
		radius:      20.0
		line_cap:    raster.StrokeLineCap.butt
		line_join:   raster.StrokeLineJoin.miter
		miter_limit: 4.0
		tolerance:   8.0
	})
	assert fine.n_contours() == 2 && coarse.n_contours() == 2
	assert fine.n_points() == 130, 'fine flattening has 130 points, got ${fine.n_points()}'
	assert coarse.n_points() == 30, 'coarse flattening has 30 points, got ${coarse.n_points()}'
	assert fine.area() != coarse.area(), 'flattening moves the ink'
}

// Degenerate inputs answer empty rather than an error: no radius, no points,
// or slices that disagree about the point count.
fn test_stroke_degenerate_inputs_are_empty() {
	f := stroke_test_font()
	gid := f.face.glyph_index(`A`)
	o := f.face.glyph_outline(gid) or { panic('${err}') }
	zero := raster.stroke_outline(o.xs, o.ys, o.on_curve, o.end_pts, raster.StrokeOptions{
		radius:      0
		line_cap:    raster.StrokeLineCap.butt
		line_join:   raster.StrokeLineJoin.miter
		miter_limit: 4.0
		tolerance:   1.0
	})
	assert zero.n_contours() == 0 && zero.n_points() == 0
	assert zero.area() == 0
	short := raster.stroke_outline([1, 2], [3], [true, true], [1], stroke_test_opt(raster.StrokeLineJoin.miter,
		4.0))
	assert short.n_contours() == 0
	empty_open := raster.stroke_open_polyline([]f64{}, []f64{}, stroke_test_opt(raster.StrokeLineJoin.miter,
		4.0))
	assert empty_open.n_contours() == 0
}

// The break-fix control: neutering the mechanism must move the ink. A
// bevelled stroke and a limit-1.0 stroke both refuse the miter pins above —
// point count and ink — so those pins prove the join and the limit do work
// rather than decorating it.
fn test_stroke_neutered_join_changes_ink() {
	miter := stroke_test_a(stroke_test_opt(raster.StrokeLineJoin.miter, 4.0))
	neutered_join := stroke_test_a(stroke_test_opt(raster.StrokeLineJoin.bevel, 4.0))
	assert neutered_join.n_points() != miter.n_points(), 'a neutered join must change the points'
	mut d := neutered_join.area() - miter.area()
	if d < 0 {
		d = -d
	}
	assert d > 1000, 'a neutered join must change the ink, moved only ${d}'
	neutered_limit := stroke_test_a(stroke_test_opt(raster.StrokeLineJoin.miter, 1.0))
	assert neutered_limit.n_points() != miter.n_points(), 'a neutered limit must change the points'
	mut e := neutered_limit.area() - miter.area()
	if e < 0 {
		e = -e
	}
	assert e > 1000, 'a neutered limit must change the ink, moved only ${e}'
}
