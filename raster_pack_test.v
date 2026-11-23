module main

import harfara.raster

fn test_pack_two_boxes_fit_side_by_side() {
	mut a := raster.new_pack_atlas(64, 64)
	x0, y0 := a.insert(32, 32) or {
		assert false, 'first insert must fit'
		return
	}
	x1, y1 := a.insert(32, 32) or {
		assert false, 'second insert must fit'
		return
	}
	assert x0 == 0 && y0 == 0
	assert !(x1 == x0 && y1 == y0)
}

fn test_pack_full_returns_none() {
	mut a := raster.new_pack_atlas(16, 16)
	_, _ := a.insert(16, 16) or {
		assert false, 'must fit'
		return
	}
	if _, _ := a.insert(8, 8) {
		assert false, 'full atlas must refuse'
	}
}

fn test_pack_reset_reuses_space() {
	mut a := raster.new_pack_atlas(16, 16)
	_, _ := a.insert(16, 16) or {
		assert false, 'must fit'
		return
	}
	a.reset(16, 16)
	_, _ := a.insert(8, 8) or {
		assert false, 'reset atlas must fit'
		return
	}
}
