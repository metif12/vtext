// pages.v is the gallery's content: twelve feature pages, their default
// parameters, the shared control row and one live drawing per page.
module main

import harfara.shape
import harfara.layout
import harfara.subset

pub enum PageID {
	hello
	features
	bidi
	joining
	fallback
	marks
	kerning
	wrap
	measure
	align
	vertical
	raster
	emoji
}

pub const page_names = [
	'Hello / Shaping'
	'OpenType features'
	'Bidi & direction'
	'Arabic joining'
	'Font fallback'
	'Marks'
	'Kerning'
	'Wrap & breaks'
	'Measure'
	'Align & spacing'
	'Vertical text'
	'Raster / subset'
	'Emoji & variation',
]

pub const page_descs = [
	'Shape a line: glyph ids, advances and the pen'
	'Turn a feature on and off and watch the glyphs change'
	'Resolved paragraph direction in mixed text'
	'isol / init / medi / fina shapes in a line'
	'Which font in the chain supplied each glyph'
	'Combining marks anchored on their bases'
	'GPOS pair adjustments between two glyphs'
	'Cut a paragraph to a width, with break points'
	'min-content, max-content and the ink extent'
	'Left, center, right, justify; letter and word spacing'
	'One vertical column and its length'
	'Coverage bitmap, subpixel offsets and a font subset'
	'Variation selectors, text versus emoji glyphs',
]

pub const dir_names = ['LTR', 'RTL', 'Auto']
pub const align_names = ['Left', 'Center', 'Right', 'Justify']
pub const wrap_names = ['Word', 'Char', 'Word+Char']

pub struct Params {
pub mut:
	text           string
	font           int
	em             f64
	dir_i          int
	feature        string
	feature_on     bool
	script         string
	language       string
	letter_spacing f64
	word_spacing   f64
	line_height    f64
	wrap_width     f64
	wrap_i         int
	align_i        int
	align_width    f64
	vertical       bool
	sub_x          int
	sub_y          int
	zoom           int
}

// defaults returns the starting parameters for one feature page.
pub fn defaults(pid PageID) Params {
	mut p := Params{
		text:           'سلام Hello 123'
		font:           0
		em:             48
		dir_i:          2
		feature:        ''
		feature_on:     true
		script:         ''
		language:       ''
		letter_spacing: 0
		word_spacing:   0
		line_height:    0
		wrap_width:     420
		wrap_i:         0
		align_i:        0
		align_width:    600
		vertical:       false
		sub_x:          0
		sub_y:          0
		zoom:           5
	}
	match pid {
		.hello {
			p.text = 'سلام Hello 123'
			p.font = font_index('Amiri-Regular.ttf')
		}
		.features {
			// Amiri's Latin fi is the clearest pin: liga fuses two glyphs into
			// one, so the count and the drawing both change.
			p.text = 'fi'
			p.font = font_index('Amiri-Regular.ttf')
			p.feature = 'liga'
			p.em = 72
		}
		.bidi {
			p.text = 'abc 123 שלום مرحبا'
			p.font = font_index('CascadiaCode-Variable.ttf')
			p.em = 40
		}
		.joining {
			// Naskh joins with substitutions alone, so no cursive attachment is
			// needed for a correct shape. Nastaliq reaches its real forms through
			// cursive anchors, which this engine reads but deliberately does not
			// apply, so it is the wrong face for a joining demo.
			p.text = 'سلام دنیا'
			p.font = font_index('NotoNaskhArabic-Regular.ttf')
			p.em = 56
			p.dir_i = 1
		}
		.fallback {
			// Three scripts, three faces: the chain below routes each run to the
			// font that really covers it and colours it by that font.
			p.text = 'Hello שלום مرحبا'
			p.font = font_index('FiraCode-Variable.ttf')
		}
		.marks {
			p.text = 'بِه ESL فارسی'
			p.font = font_index('Amiri-Regular.ttf')
			p.em = 60
			p.dir_i = 1
		}
		.kerning {
			p.text = 'ToVa WA'
			p.font = font_index('FiraCode-Variable.ttf')
			p.em = 56
		}
		.wrap {
			p.text = 'The quick brown fox jumps over the lazy dog and then runs away again.'
			p.font = font_index('FiraCode-Variable.ttf')
			p.em = 26
			p.wrap_width = 360
			p.line_height = 36
		}
		.measure {
			p.text = 'سلام دنیا'
			p.font = font_index('Amiri-Regular.ttf')
			p.em = 44
			p.dir_i = 1
		}
		.align {
			p.text = 'Align me'
			p.font = font_index('FiraCode-Variable.ttf')
			p.em = 40
			p.align_i = 1
			p.align_width = 600
			p.letter_spacing = 1
		}
		.vertical {
			p.text = '垂直テキスト'
			p.font = font_index('NotoSansSC-Variable.ttf')
			p.em = 40
			p.vertical = true
		}
		.raster {
			p.text = 'A'
			p.font = font_index('FiraCode-Variable.ttf')
			p.em = 32
			p.zoom = 6
		}
		.emoji {
			// Segoe UI Emoji is a normal glyf face with a real cvt table, so
			// HarfAra can rasterise it; the committed corpus faces have no
			// emoji coverage at all.
			p.text = '✌️ ☺ ❤️ 👍 😀'
			p.font = font_index('seguiemj.ttf')
			p.em = 56
		}
	}
	return p
}

fn dir_of(i int) shape.Direction {
	return match i {
		0 { .ltr }
		1 { .rtl }
		else { .auto }
	}
}

fn align_of(i int) layout.Align {
	return match i {
		0 { .left }
		1 { .center }
		2 { .right }
		else { .justify }
	}
}

fn wrap_of(i int) layout.WrapMode {
	return match i {
		0 { .word }
		1 { .char }
		else { .word_char }
	}
}

// opts_of builds the LayoutOptions the shared controls describe.
fn opts_of(p &Params) &layout.LayoutOptions {
	mut o := &layout.LayoutOptions{}
	if p.feature != '' {
		o.features << if p.feature_on { p.feature } else { '-' + p.feature }
	}
	o.script = p.script
	o.language = p.language
	o.letter_spacing = p.letter_spacing
	o.word_spacing = p.word_spacing
	o.line_height = p.line_height
	o.align = align_of(p.align_i)
	o.align_width = p.align_width
	o.vertical = p.vertical
	o.wrap_mode = wrap_of(p.wrap_i)
	return o
}

// The stage is a standalone image: ui2 draws it in a frame, HarfAra renders
// these exact dimensions into the bitmap that frame displays.
const stage_y = 0
const stage_w = 940
const stage_h = 500
const text_x = 30
const base_y = 280

const grid_color = Color{222, 229, 239, 255}
const guide_color = Color{158, 178, 208, 255}
const box_color = Color{186, 206, 234, 255}

// draw_grid_overlay paints the configurable studio guides behind the sample.
// It shapes the same line the page will draw, so character boxes and pen ticks
// line up with what is on the stage.
pub fn draw_grid_overlay(app &App) {
	mut c := app.canvas
	p := &app.params
	if app.show_grid {
		mut step := int(app.grid_size)
		if step < 8 {
			step = 8
		}
		// Divide the whole stage into equal cells: a fixed step leaves a short
		// last cell and reads as a badly divided grid.
		cols := int(f64(stage_w) / f64(step) + 0.5)
		rows := int(f64(stage_h) / f64(step) + 0.5)
		if cols > 1 {
			for i in 1 .. cols {
				c.vline(int(f64(i) * f64(stage_w) / f64(cols)), 0, stage_h - 1, grid_color)
			}
		}
		if rows > 1 {
			for i in 1 .. rows {
				c.hline(int(f64(i) * f64(stage_h) / f64(rows)), 0, stage_w - 1, grid_color)
			}
		}
	}
	if app.show_margins {
		c.outline(30, 30, stage_w - 60, stage_h - 60, guide_color)
	}
	if app.show_center {
		c.vline(stage_w / 2, 0, stage_h - 1, guide_color)
		c.hline(stage_h / 2, 0, stage_w - 1, guide_color)
	}
	if app.show_baseline {
		c.hline(base_y, 0, stage_w - 1, guide_color)
	}
	mut line := layout.Line{}
	if app.show_guides || app.show_char_boxes || app.show_pen_ticks {
		opts := opts_of(p)
		line = layout.layout_paragraph_with(app.ctx, p.text.runes(), dir_of(p.dir_i),
			fs_of(app, p.font), p.em, opts)
	}
	if app.show_guides {
		c.hline(base_y - int(p.em * 0.5), 0, stage_w - 1, grid_color)
		c.hline(base_y - int(p.em * 0.8), 0, stage_w - 1, grid_color)
		c.hline(base_y + int(line.descent), 0, stage_w - 1, grid_color)
	}
	if app.show_char_boxes {
		for g in line.glyphs {
			mut w := int(g.advance)
			if w < 1 {
				w = 1
			}
			c.outline(text_x + int(g.x), base_y - int(p.em), w, int(p.em), box_color)
		}
	}
	if app.show_pen_ticks {
		for g in line.glyphs {
			c.vline(text_x + int(g.x), base_y - int(p.em), base_y + int(p.em * 0.2), guide_color)
		}
	}
}

// The controls and the list are ui2 widgets; pages.v owns only the sample
// drawing. main.render() creates the canvas, calls the matching sample below,
// and writes the result as the PNG shown by the ui2 Image widget.

fn line_of(app &App, opts &layout.LayoutOptions) layout.Line {
	p := &app.params
	return layout.layout_paragraph_with(app.ctx, p.text.runes(), dir_of(p.dir_i),
		fs_of(app, p.font), p.em, opts)
}

// shape_lines splits multi-line content from the TextArea and shapes each line
// separately, so line breaks are visible on the stage.
fn shape_lines(app &App, opts &layout.LayoutOptions) []layout.Line {
	p := &app.params
	mut out := []layout.Line{}
	for s in p.text.split('\n') {
		out << layout.layout_paragraph_with(app.ctx, s.runes(), dir_of(p.dir_i),
			fs_of(app, p.font), p.em, opts)
	}
	return out
}

fn line_step(app &App) int {
	p := &app.params
	return int(if p.line_height > 0 { p.line_height } else { p.em * 1.2 })
}

fn sample_hello(app &App) string {
	p := &app.params
	lines := shape_lines(app, opts_of(p))
	step := line_step(app)
	mut widest := 0.0
	mut count := 0
	for i, line in lines {
		y := base_y + i * step
		app.canvas.draw_line(&line, text_x, y, p.em, app.text_color())
		app.canvas.hline(y, text_x - 10, text_x + 40, guide)
		if line.width > widest {
			widest = line.width
		}
		count += line.glyphs.len
	}
	return '${lines.len} line(s), ${count} glyphs  widest=${widest:.1f}  ascent=${p.em:.1f}px em'
}

fn sample_features(app &App) string {
	p := &app.params
	tag := if p.feature == '' { 'liga' } else { p.feature }
	mut off := opts_of(p)
	off.features = ['-' + tag]
	mut on := opts_of(p)
	on.features = [tag]
	offline := line_of(app, off)
	online := line_of(app, on)
	app.canvas.line(text_x - 12, base_y - 70, text_x - 12, base_y + 30, guide)
	app.canvas.draw_line(&offline, text_x, base_y - 60, p.em, dim)
	app.canvas.draw_line(&online, text_x, base_y + 30, p.em, app.text_color())
	return 'without ${tag}: ${offline.glyphs.len} glyphs / ${offline.width:.1f}px   |   with ${tag}: ${online.glyphs.len} glyphs / ${online.width:.1f}px'
}

fn sample_bidi(app &App) string {
	p := &app.params
	line := line_of(app, opts_of(p))
	app.canvas.draw_line(&line, text_x, base_y, p.em, app.text_color())
	app.canvas.hline(base_y, text_x - 10, text_x + int(line.width) + 10, guide)
	level := if line.paragraph_level % 2 == 1 { 'RTL (level 1)' } else { 'LTR (level 0)' }
	return 'resolved paragraph: ${level}   glyphs=${line.glyphs.len}   width=${line.width:.1f}px'
}

fn sample_joining(app &App) string {
	p := &app.params
	line := line_of(app, opts_of(p))
	app.canvas.draw_line(&line, text_x, base_y, p.em, app.text_color())
	// Annotate the shaped glyphs in place: the four joining forms are the
	// feature this page is about, so they should be visible, not just counted.
	fs := fs_of(app, p.font)
	app.canvas.label(app.ctx, fs, 'I isolated   F final   B initial   M medial', text_x, 34,
		12.0, dim)
	for g in line.glyphs {
		if g.is_mark {
			continue
		}
		x := text_x + int(g.x)
		letter := match int(g.form) {
			0 { 'I' }
			1 { 'F' }
			2 { 'B' }
			else { 'M' }
		}
		app.canvas.label(app.ctx, fs, letter, x, base_y - int(p.em) - 12, 12.0,
			Color{71, 85, 105, 255})
		app.canvas.vline(x, base_y - int(p.em) - 8, base_y - int(p.em) - 2, box_color)
	}
	mut forms := ''
	for i, g in line.glyphs {
		if i > 0 {
			forms += ' '
		}
		forms += match int(g.form) {
			0 { 'I' }
			1 { 'F' }
			2 { 'B' }
			else { 'M' }
		}
	}
	return '${line.glyphs.len} glyphs from ${p.text.runes().len} characters   forms: ${forms}'
}

fn sample_fallback(app &App) string {
	p := &app.params
	mut fs := shape.new_font_set()
	mut picked := []&shape.Font{}
	chain := [p.font, font_index('Amiri-Regular.ttf'), font_index('NotoSansHebrew-Variable.ttf')]
	for idx in chain {
		f := app.fonts[idx % app.fonts.len].font
		fs.add(f)
		picked << f
	}
	mut opts := opts_of(p)
	line := layout.layout_paragraph_with(app.ctx, p.text.runes(), dir_of(p.dir_i), fs, p.em,
		opts)
	colors := [Color{214, 96, 92, 255}, Color{86, 156, 244, 255}, Color{96, 184, 132, 255}]
	for g in line.glyphs {
		if f := g.font {
			mut col := fg
			for i, cand in picked {
				if f == cand {
					col = colors[i % colors.len]
					break
				}
			}
			app.canvas.draw_glyph(f, g, text_x, base_y, p.em, col)
		}
	}
	mut names := ''
	for i, idx in chain {
		if i > 0 {
			names += ' -> '
		}
		names += app.fonts[idx % app.fonts.len].name
	}
	return 'chain: ' + names + '   (each glyph is coloured by the font that supplied it)'
}

fn sample_marks(app &App) string {
	p := &app.params
	line := line_of(app, opts_of(p))
	app.canvas.draw_line(&line, text_x, base_y, p.em, app.text_color())
	app.canvas.hline(base_y, text_x - 10, text_x + int(line.width) + 10, guide)
	mut marks := 0
	for g in line.glyphs {
		if g.is_mark {
			marks++
		}
	}
	return '${marks} marks on ${line.glyphs.len - marks} base glyphs   width=${line.width:.1f}px'
}

fn sample_kerning(app &App) string {
	p := &app.params
	line := line_of(app, opts_of(p))
	app.canvas.draw_line(&line, text_x, base_y, p.em, app.text_color())
	f := font_of(app, p.font)
	script := if p.script == '' { 'latn' } else { p.script }
	mut info := if f.kerns(script, '') { 'font kerns: yes' } else { 'font kerns: no' }
	if line.glyphs.len >= 2 {
		g0 := line.glyphs[0]
		g1 := line.glyphs[1]
		if off := f.kern_offset(g0.gid, g1.gid, script, p.language) {
			info += '   first pair x=${off.x} y=${off.y} design units'
		} else {
			info += '   first pair: no GPOS rule'
		}
	}
	return info
}

fn sample_wrap(app &App) string {
	p := &app.params
	mut opts := opts_of(p)
	lines := layout.wrap_paragraph_with(app.ctx, p.text.runes(), dir_of(p.dir_i),
		fs_of(app, p.font), p.em, p.wrap_width, opts)
	step := int(if p.line_height > 0 { p.line_height } else { p.em * 1.2 })
	for i, wl in lines {
		y := stage_y + 60 + i * step
		app.canvas.draw_line(&wl.line, text_x, y, p.em, app.text_color())
		app.canvas.hline(y, text_x - 10, text_x + int(p.wrap_width), guide)
	}
	app.canvas.vline(text_x + int(p.wrap_width), stage_y + 40, stage_y + stage_h - 30, accent)
	return '${lines.len} lines at width ${p.wrap_width:.0f}px   mode=${wrap_names[p.wrap_i]}'
}

fn sample_measure(app &App) string {
	p := &app.params
	mut opts := opts_of(p)
	line := line_of(app, opts)
	app.canvas.draw_line(&line, text_x, base_y, p.em, app.text_color())
	m := layout.measure_paragraph_with(app.ctx, p.text.runes(), dir_of(p.dir_i),
		fs_of(app, p.font), p.em, opts)
	app.canvas.vline(text_x + int(m.min_content_width), base_y - int(p.em), base_y + 20,
		Color{96, 184, 132, 255})
	app.canvas.vline(text_x + int(m.max_content_width), base_y - int(p.em), base_y + 20, warn)
	app.canvas.hline(base_y, text_x - 10, text_x + int(m.max_content_width) + 10, guide)
	return 'min=${m.min_content_width:.1f}  max=${m.max_content_width:.1f}  ascent=${m.ascent:.1f}  descent=${m.descent:.1f}  line_height=${m.line_height:.1f}'
}

fn sample_align(app &App) string {
	p := &app.params
	mut opts := opts_of(p)
	line := line_of(app, opts)
	app.canvas.rect(text_x, base_y - int(p.em), int(p.align_width), int(p.em * 1.5),
		Color{242, 244, 248, 255})
	app.canvas.outline(text_x, base_y - int(p.em), int(p.align_width), int(p.em * 1.5), guide)
	app.canvas.draw_line(&line, text_x, base_y, p.em, app.text_color())
	for x in [text_x, text_x + int(p.align_width)] {
		app.canvas.vline(x, base_y - int(p.em) - 6, base_y + int(p.em * 0.5) + 6, accent)
	}
	return 'align=${align_names[p.align_i]}  target=${p.align_width:.0f}px  letter=${p.letter_spacing:.1f}  word=${p.word_spacing:.1f}'
}

fn sample_vertical(app &App) string {
	p := &app.params
	mut opts := opts_of(p)
	opts.vertical = true
	line := line_of(app, opts)
	app.canvas.draw_line(&line, text_x, stage_y + 50, p.em, app.text_color())
	app.canvas.vline(text_x, stage_y + 40, stage_y + stage_h - 30, guide)
	return 'column width=${line.width:.1f}px  length=${line.height:.1f}px  step=${line.line_height:.1f}px'
}

fn sample_raster(app &App) string {
	p := &app.params
	f := font_of(app, p.font)
	rs := p.text.runes()
	if rs.len == 0 {
		return 'type a character to rasterise it'
	}
	gid := f.glyph_index(rs[0])
	w, h := app.canvas.glyph_zoom(f, gid, p.em, i32(p.sub_x), i32(p.sub_y), text_x,
		stage_y + 60, p.zoom, app.text_color())
	app.canvas.outline(text_x - 1, stage_y + 59, w + 2, h + 2, guide)
	mut seed := [gid]
	sub := subset.subset_font(f, seed) or {
		return 'gid=${gid}  bitmap=${w}x${h}  subset failed: ${err.msg()}'
	}
	return 'gid=${gid}  bitmap=${w}x${h}  zoom=${p.zoom}x  subset=${sub.bytes.len} bytes from full font'
}

fn sample_emoji(app &App) string {
	p := &app.params
	line := line_of(app, opts_of(p))
	app.canvas.draw_line(&line, text_x, base_y, p.em, app.text_color())
	app.canvas.hline(base_y, text_x - 10, text_x + int(line.width) + 10, guide)
	f := font_of(app, p.font)
	rs := p.text.runes()
	mut report := ''
	mut missing := 0
	mut seen := map[rune]bool{}
	for r in rs {
		if r == rune(0xfe0f) || r == rune(0x20) || seen[r] {
			continue
		}
		seen[r] = true
		base := f.glyph_index(r)
		emoji := f.glyph_index_variation(r, [rune(0xfe0f)])
		has := f.has_variation_sequence(r, rune(0xfe0f))
		if base == 0 || !f.has_glyph(r) {
			missing++
		}
		report += 'U+${r.hex().to_upper()} ${base}/${emoji} vs=${has}  '
	}
	if missing > 0 {
		return '${missing} codepoint(s) have no glyph in this face (.notdef box): pick seguiemj.ttf | ${report}'
	}
	return 'base/emoji gids: ${report} | ${line.glyphs.len} glyphs from ${rs.len} codepoints: VS draws nothing'
}
