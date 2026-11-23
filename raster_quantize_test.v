module main

import harfara.raster

fn solid(w int, h int, v u8) raster.GlyphBitmap {
	return raster.GlyphBitmap{
		coverage: []u8{len: w * h, init: v}
		width:    w
		height:   h
	}
}

fn test_quantize_mono_threshold() {
	b := raster.quantize_mono(solid(2, 1, 200))
	assert b.coverage == [u8(255), 255]
	c := raster.quantize_mono(solid(2, 1, 10))
	assert c.coverage == [u8(0), 0]
}

fn test_quantize_gray4_levels_are_17_steps() {
	b := raster.quantize_gray4(solid(1, 1, 255))
	assert b.coverage[0] == 255
}

fn test_gamma_identity_and_blur_identity() {
	b := solid(2, 2, 100)
	lut := raster.gamma_lut(0.5, 1.0)
	assert lut.len == 256
	id := raster.apply_lut(b, lut)
	assert id.coverage == b.coverage
	same := raster.blur_bitmap(b, 0)
	assert same.coverage == b.coverage
	moved := raster.blur_bitmap(b, 1)
	assert moved.coverage.len == b.coverage.len
}

fn test_blur_spreads_single_pixel() {
	mut cov := []u8{len: 9}
	cov[4] = 255
	b := raster.GlyphBitmap{
		coverage: cov
		width:    3
		height:   3
	}
	out := raster.blur_bitmap(b, 1)
	assert out.coverage[4] < 255
	assert out.coverage[0] > 0
}
