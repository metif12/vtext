module raster

// Grid-fit application behind box_only/render_into: the bitmap half of the
// autohinter whose outline half lives in font/hint.v.
//
// FreeType's autohinter does two things to the ink: it aligns stems to the
// pixel grid (which moves the box) and it regularizes stem coverage (which
// darkens the core past what the unhinted fill paints). The outline half
// moves the box; this file darkens the core. grid_fit_bitmap snaps every
// coverage byte through a stem-regularizing curve and trims the all-zero
// border the snap leaves behind, adjusting left/top so the trimmed bitmap
// still sits where the ink was. fit_bitmap_to_box then reboxes the snapped
// fill onto the fitted outline's box (clipping or zero-padding by the pixel
// the two mechanisms can disagree by), which is what keeps font.hinted_box
// and font.hinted_rasterize on one box the way box_only and rasterize_glyph
// agree today.
//
// The snap curve is a linear stem stretch between snap_lo and snap_hi:
// at or below lo the pixel drops out, at or above hi it goes solid, between
// them it stretches. lo 16 / hi 240 is measured, not derived: on the Amiri
// dal pin (gid 63 at 32 px) it lifts the stb sum toward FreeType's
// autohinted sum (12447) without overshooting it, and on gid 6227 (A) it
// stays inside the same few-percent tolerance. The passthrough options
// (0, 255, no trim) are the exact identity and the break-fix control: a
// neutered hinter answers its input byte for byte, and every pin in
// raster_hint_test.v fails on it.

// GridFitOptions selects the stem snap. snap_lo drops faint pixels, snap_hi
// saturates strong ones, trim cuts the emptied border. The zero value snaps
// nothing and trims nothing only when snap_hi is also 255; use
// passthrough_grid_fit_options for a guaranteed identity.
pub struct GridFitOptions {
pub:
	snap_lo u8
	snap_hi u8
	trim    bool
}

// default_grid_fit_options answers the measured stem stretch: drop at 16,
// saturate at 240, trim the emptied border.
pub fn default_grid_fit_options() GridFitOptions {
	return GridFitOptions{
		snap_lo: 16
		snap_hi: 240
		trim:    true
	}
}

// passthrough_grid_fit_options answers the identity: every byte maps to
// itself and no border is cut. It is the neutered hinter the break-fix
// control runs: grid_fit_bitmap_opt with these options must answer its input
// unchanged, and any pin that still passes under them proves nothing.
pub fn passthrough_grid_fit_options() GridFitOptions {
	return GridFitOptions{
		snap_lo: 0
		snap_hi: 255
		trim:    false
	}
}

// grid_fit_bitmap snaps src through the default stem stretch. With defaults
// it is the raster half of hinting; for the identity see
// passthrough_grid_fit_options.
pub fn grid_fit_bitmap(src GlyphBitmap) GlyphBitmap {
	return grid_fit_bitmap_opt(src, default_grid_fit_options())
}

// grid_fit_bitmap_opt snaps src through opt: the stem curve first, the trim
// after. An empty bitmap, a coverageless box, or an inverted snap window
// answers src unchanged, because there is no ink to regularize and no sane
// curve to apply. The passthrough options answer src byte for byte.
pub fn grid_fit_bitmap_opt(src GlyphBitmap, opt GridFitOptions) GlyphBitmap {
	if src.is_empty() {
		return src
	}
	if src.coverage.len < src.width * src.height {
		return src
	}
	if opt.snap_hi <= opt.snap_lo {
		return src
	}
	lo := int(opt.snap_lo)
	hi := int(opt.snap_hi)
	span := hi - lo
	mut out := []u8{len: src.coverage.len}
	for i, v in src.coverage {
		iv := int(v)
		if iv <= lo {
			out[i] = 0
		} else if iv >= hi {
			out[i] = 255
		} else {
			out[i] = u8((iv - lo) * 255 / span)
		}
	}
	mut snapped := GlyphBitmap{
		coverage: out
		width:    src.width
		height:   src.height
		left:     src.left
		top:      src.top
	}
	if !opt.trim {
		return snapped
	}
	return trim_empty_border(snapped)
}

// trim_empty_border cuts all-zero outer rows and columns and moves left/top
// with the cut, so the trimmed bitmap sits where the ink was. A bitmap that
// is all zero answers empty; a bitmap with no empty border answers itself
// with the same box.
pub fn trim_empty_border(src GlyphBitmap) GlyphBitmap {
	if src.is_empty() {
		return src
	}
	if src.coverage.len < src.width * src.height {
		return src
	}
	mut x0 := src.width
	mut x1 := -1
	mut y0 := src.height
	mut y1 := -1
	for y in 0 .. src.height {
		for x in 0 .. src.width {
			if src.coverage[y * src.width + x] != 0 {
				if x < x0 {
					x0 = x
				}
				if x > x1 {
					x1 = x
				}
				if y < y0 {
					y0 = y
				}
				if y > y1 {
					y1 = y
				}
			}
		}
	}
	if x1 < x0 || y1 < y0 {
		return GlyphBitmap{}
	}
	tw := x1 - x0 + 1
	th := y1 - y0 + 1
	mut cov := []u8{len: tw * th}
	for y in 0 .. th {
		for x in 0 .. tw {
			cov[y * tw + x] = src.coverage[(y0 + y) * src.width + x0 + x]
		}
	}
	return GlyphBitmap{
		coverage: cov
		width:    tw
		height:   th
		left:     src.left - x0
		top:      src.top - y0
	}
}

// fit_bitmap_to_box reboxes src onto box: same ink, box's left/top/width/
// height, clipped where the fill overshoots and zero-padded where it falls
// short. The copy is pen-relative: column x of src sits at pen offset
// x - src.left, which lands at x - src.left + box.left in the destination,
// and likewise down the rows from top. Either side empty answers empty; a
// coverageless box is reboxed by geometry alone (zeros throughout).
pub fn fit_bitmap_to_box(src GlyphBitmap, box GlyphBitmap) GlyphBitmap {
	if src.is_empty() || box.is_empty() {
		return GlyphBitmap{}
	}
	mut cov := []u8{len: box.width * box.height}
	if src.coverage.len >= src.width * src.height {
		for dy in 0 .. box.height {
			sy := dy - box.top + src.top
			if sy < 0 || sy >= src.height {
				continue
			}
			for dx in 0 .. box.width {
				sx := dx - box.left + src.left
				if sx < 0 || sx >= src.width {
					continue
				}
				cov[dy * box.width + dx] = src.coverage[sy * src.width + sx]
			}
		}
	}
	return GlyphBitmap{
		coverage: cov
		width:    box.width
		height:   box.height
		left:     box.left
		top:      box.top
	}
}

// coverage_sum totals the coverage bytes of a bitmap. Zeros outside the box
// contribute nothing, so a reboxed bitmap's sum is directly comparable to
// the sum before the rebox.
pub fn (b &GlyphBitmap) coverage_sum() u64 {
	mut acc := u64(0)
	for v in b.coverage {
		acc += u64(v)
	}
	return acc
}
