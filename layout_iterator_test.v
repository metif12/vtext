module main

import vtext.layout
import vtext.shape

fn test_advance_quads_empty_line() {
	line := layout.Line{}
	assert layout.advance_quads(&line, 64, 64, .top_left).len == 0
}

fn test_advance_quads_order_and_origin() {
	mut line := layout.Line{
		width:   20
		ascent:  10
		descent: 3
	}
	line.glyphs << shape.Glyph{
		advance: 8
		x:       0
		cluster: 0
	}
	line.glyphs << shape.Glyph{
		advance: 12
		x:       8
		cluster: 1
	}
	top := layout.advance_quads(&line, 64, 64, .top_left)
	assert top.len == 2
	assert top[0].x0 == 0 && top[0].x1 == 8
	assert top[1].x0 == 8 && top[1].x1 == 20
	assert top[0].y0 == -10 && top[0].y1 == 3
	bot := layout.advance_quads(&line, 64, 64, .bottom_left)
	assert bot[0].y0 == -3 && bot[0].y1 == 10
	_, _, w, d := layout.line_ink_box(&line)
	assert w == 20 && d == 3
}
