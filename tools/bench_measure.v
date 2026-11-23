// Interleaved A/B for measure_line: the shipped per-line memo against the old
// per-glyph call path (metric reads and box_only on every glyph). The two are
// asserted field-equal before timing, so a ratio only counts when both are the
// same function. Best-of interleaved keeps a loaded box from deciding the result;
// the ratio is the finding.
module main

import time
import harfara.shape
import harfara.layout

const iters = 1200

// plain_measure_line is the pre-memo path, kept here as the A/B control.
fn plain_measure_line(mut line layout.Line, em_px f64, options &layout.LayoutOptions) {
	mut natural := f64(0)
	for g in line.glyphs {
		line.width = layout.larger(line.width, g.x + g.advance)
		if f := g.font {
			line.ascent = layout.larger(line.ascent, f.ascent(em_px))
			line.descent = layout.larger(line.descent, f.descent(em_px))
			natural = layout.larger(natural, f.line_height(em_px))
			bmp := f.face.box_only(g.gid, em_px)
			if !bmp.is_empty() {
				line.ascent = layout.larger(line.ascent, g.y + f64(bmp.top))
				line.descent = layout.larger(line.descent, f64(bmp.height) - g.y - f64(bmp.top))
			}
		}
	}
	line.line_height = if options.line_height > 0.0 { options.line_height } else { natural }
}

fn same(a layout.Line, b layout.Line) bool {
	return a.width == b.width && a.ascent == b.ascent && a.descent == b.descent && a.line_height == b.line_height
}

fn bench(line layout.Line, options &layout.LayoutOptions, plain bool) i64 {
	for _ in 0 .. 200 {
		mut x := line
		if plain {
			plain_measure_line(mut x, 16.0, options)
		} else {
			layout.measure_line(mut x, 16.0, options)
		}
	}
	mut best := i64(1 << 60)
	mut sink := f64(0)
	for _ in 0 .. 7 {
		start := time.sys_mono_now()
		for _ in 0 .. iters {
			mut x := line
			if plain {
				plain_measure_line(mut x, 16.0, options)
			} else {
				layout.measure_line(mut x, 16.0, options)
			}
			sink += x.width + x.ascent + x.descent
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

fn main() {
	f := shape.load_font_file('testdata/fonts/FiraCode-Variable.ttf') or {
		println('no font')
		return
	}
	mut glyphs := []shape.Glyph{cap: 1024}
	for i in 0 .. 1024 {
		glyphs << shape.Glyph{
			gid:     u16(30 + i % 47)
			advance: 8.0
			x:       f64(i) * 8.0
			font:    f
		}
	}
	line := layout.Line{ glyphs: glyphs }
	options := &layout.LayoutOptions{}

	mut shipped := line
	layout.measure_line(mut shipped, 16.0, options)
	mut plain := line
	plain_measure_line(mut plain, 16.0, options)
	assert same(shipped, plain), 'memo must be the same function'

	mut plain_best := i64(1 << 60)
	mut memo_best := i64(1 << 60)
	for _ in 0 .. 3 {
		p := bench(line, options, true)
		m := bench(line, options, false)
		if p < plain_best {
			plain_best = p
		}
		if m < memo_best {
			memo_best = m
		}
	}
	println('measure_line 1024: plain=${plain_best}ns memo=${memo_best}ns ratio=${f64(plain_best) / f64(memo_best):.2f}x')
}
