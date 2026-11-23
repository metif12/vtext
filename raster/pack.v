module raster

// Standalone rect packing for caller-owned atlases.
//
// harfara never owns an atlas (Phase 1); the caller does. This is the generic
// skyline packer any caller can use to place glyph boxes into its own
// texture: bottom-left heuristic over skyline nodes, no hidden allocation
// beyond the node list, no dependency on fontstash, stb or freetype.

pub struct PackNode {
pub mut:
	x     int
	y     int
	width int
}

pub struct PackAtlas {
pub mut:
	width  int
	height int
	nodes  []PackNode
}

// new_pack_atlas answers an empty atlas of w*h with a single root node.
pub fn new_pack_atlas(w int, h int) PackAtlas {
	if w <= 0 || h <= 0 {
		return PackAtlas{}
	}
	return PackAtlas{
		width:  w
		height: h
		nodes:  [PackNode{0, 0, w}]
	}
}

// is_empty reports whether the atlas can hold anything.
pub fn (a &PackAtlas) is_empty() bool {
	return a.width <= 0 || a.height <= 0
}

// rect_fits answers the y a w*h rect would sit at on node i, or -1.
fn (a &PackAtlas) rect_fits(i int, w int, h int) int {
	if i < 0 || i >= a.nodes.len {
		return -1
	}
	mut x := a.nodes[i].x
	mut y := a.nodes[i].y
	if x + w > a.width {
		return -1
	}
	mut space := w
	mut j := i
	for space > 0 {
		if j >= a.nodes.len {
			return -1
		}
		if a.nodes[j].y > y {
			y = a.nodes[j].y
		}
		if y + h > a.height {
			return -1
		}
		space -= a.nodes[j].width
		j++
	}
	return y
}

fn (mut a PackAtlas) add_skyline(idx int, x int, y int, w int, h int) bool {
	if a.nodes.len + 1 > 4096 {
		return false
	}
	a.nodes.insert(idx + 1, PackNode{x + w, y, a.nodes[idx].width - w})
	a.nodes[idx].x = x
	a.nodes[idx].y = y + h
	a.nodes[idx].width = w
	mut i := idx + 1
	for i < a.nodes.len {
		if a.nodes[i].x < a.nodes[i - 1].x + a.nodes[i - 1].width {
			shrink := a.nodes[i - 1].x + a.nodes[i - 1].width - a.nodes[i].x
			a.nodes[i].x += shrink
			a.nodes[i].width -= shrink
			if a.nodes[i].width <= 0 {
				a.nodes.delete(i)
				continue
			}
			break
		} else {
			break
		}
	}
	mut k := 0
	for k < a.nodes.len - 1 {
		if a.nodes[k].y == a.nodes[k + 1].y {
			a.nodes[k].width += a.nodes[k + 1].width
			a.nodes.delete(k + 1)
		} else {
			k++
		}
	}
	return true
}

// insert packs a w*h rect bottom-left, answering its x/y or none.
pub fn (mut a PackAtlas) insert(w int, h int) ?(int, int) {
	if w <= 0 || h <= 0 || a.is_empty() {
		return none
	}
	mut best_i := -1
	mut best_x := -1
	mut best_y := -1
	mut best_h := a.height + 1
	mut best_w := a.width + 1
	for i in 0 .. a.nodes.len {
		y := a.rect_fits(i, w, h)
		if y < 0 {
			continue
		}
		if y + h < best_h || (y + h == best_h && a.nodes[i].width < best_w) {
			best_i = i
			best_x = a.nodes[i].x
			best_y = y
			best_h = y + h
			best_w = a.nodes[i].width
		}
	}
	if best_i < 0 {
		return none
	}
	if !a.add_skyline(best_i, best_x, best_y, w, h) {
		return none
	}
	return best_x, best_y
}

// reset clears placements without freeing the node storage.
pub fn (mut a PackAtlas) reset(w int, h int) {
	if w <= 0 || h <= 0 {
		a.width = 0
		a.height = 0
		a.nodes.clear()
		return
	}
	a.width = w
	a.height = h
	a.nodes = [PackNode{0, 0, w}]
}
