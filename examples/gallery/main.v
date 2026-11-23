// gallery is an interactive feature demo for HarfAra. The window and every
// control belong to ui2; the stage is a bitmap that HarfAra renders on every
// parameter change.
//
// ui2 uses native Win32 controls by default, so unlike gg it does not need
// stb_truetype's fontstash copy and can live in the same program as HarfAra.
// (HarfAra's own stb_truetype copy is STBTT_STATIC, so even the custom
// gg renderer in -d ui2_custom_rendering builds coexist in one binary.)
// The stage stays a HarfAra-rendered bitmap in both modes: BMP for the
// native Windows image control, PNG for the custom renderer.
//
//   v run examples/gallery
//   v -d ui2_custom_rendering run examples/gallery
//   v run examples/gallery -- --selftest
module main

import os
import math
import strconv
import ui2
import corpus
import harfara.shape
import harfara.layout

pub struct FontInfo {
pub:
	name string
	path string
	font &shape.Font
}

pub struct GlyphHit {
pub:
	id int
	x  f64
	y  f64
	w  f64
	h  f64
}

// stage_point maps a point in the untransformed stage into preview coordinates.
// Pan and rotation are applied to the stage bitmap, so glyph hotspots have to
// follow the same transform to stay over the glyphs they select.
fn stage_point(app &App, x f64, y f64) (f64, f64) {
	rad := app.rotate * 0.017453292519943295
	cos_a := math.cos(rad)
	sin_a := math.sin(rad)
	cx := f64(stage_w) / 2.0
	cy := f64(stage_h) / 2.0
	px := x + app.pan_x - cx
	py := y + app.pan_y - cy
	sx := cx + px * cos_a + py * sin_a
	sy := cy - px * sin_a + py * cos_a
	return 4.0 + sx * app.stage_scale, 4.0 + sy * app.stage_scale
}

pub struct PageItem {
pub:
	id       int
	name     string
	selected bool
}

// App is both the ui2 VML model and the owner of the shaping engine.
//
// ui2 reflects every *public* model field recursively. The engine objects
// below are deliberately private: they are not UI state, and a public pointer
// to context/font/canvas would send the reflection walk into a cycle.
pub struct App {
pub mut:
	page            int
	pages           []PageItem
	text            string
	content_h       f64    = 50
	text_r          f64    = 28
	text_g          f64    = 32
	text_b          f64    = 40
	text_swatch     string = '#1C2028'
	font_name       string
	size            f64
	dir_name        string
	feature         string
	feature_on      bool
	script          string
	language        string
	letter_spacing  f64
	word_spacing    f64
	line_height     f64
	wrap_width      f64
	wrap_name       string
	align_name      string
	align_width     f64
	vertical        bool
	show_grid       bool = true
	show_baseline   bool = true
	show_guides     bool
	show_char_boxes bool
	show_pen_ticks  bool
	show_margins    bool
	show_center     bool
	grid_size       f64    = 32
	grid_label      string = '32 px'
	preview_zoom    f64    = 1.0
	pan_x           f64
	pan_y           f64
	rotate          f64
	panel_w         f64 = 280
	hits            []GlyphHit
	selected_glyph  int = -1
	stage_scale     f64 = 1.0
	font_query      string
	font_status     string
	sub_x           f64
	sub_y           f64
	zoom            f64
	image_path      string
	desc            string
	status          string
	lib_info        string
mut:
	params       Params
	ctx          &shape.Context
	fonts        []FontInfo
	fsets        []&shape.FontSet
	canvas       &Canvas
	render_count int
	old_paths    []string
	// Custom-renderer drag state: the window point the current stage drag
	// started or last continued from. Sliders stay the primary transform
	// input; this only pans the stage under a pointer drag.
	drag_x   f64
	drag_y   f64
	dragging bool
	// Caller-owned glyph cache, the only honest memo: rasterizing is pure
	// in (font, gid, size, subpixel), so a glyph drawn on every render is
	// rasterized once and re-blitted after. Pan, rotate and guide toggles
	// change no glyph and hit the cache for all of theirs; the engine
	// never sees it. Cleared when fonts change.
	glyph_cache shape.Cache
}

const font_names = [
	'Amiri-Regular.ttf'
	'NotoNaskhArabic-Regular.ttf'
	'NotoNastaliqUrdu-Regular.ttf'
	'FiraCode-Variable.ttf'
	'CascadiaCode-Variable.ttf'
	'NotoSansHebrew-Variable.ttf'
	'NotoSansSC-Variable.ttf'
	'NotoSansBengali-Variable.ttf'
	'NotoSansKhmer-Variable.ttf'
	'SourceSans3-Regular.otf'
	'seguiemj.ttf',
]

const gallery_vml_template = $embed_file('gallery.vml').to_string()
const harfara_vmod = $embed_file('../../v.mod').to_string()

// installed_font_names lists the faces in the OS font directory. They are
// injected into the Dropdown when the VML source is built, because ui2's VML
// options are static.
fn installed_font_names() []string {
	dir := platform_font_dir()
	files := os.ls(dir) or { return []string{} }
	mut names := []string{}
	for f in files {
		ext := os.file_ext(f).to_lower()
		if ext in ['.ttf', '.otf', '.ttc', '.woff'] {
			names << f
		}
	}
	names.sort()
	return names
}

// build_vml_source fills the font dropdown and, for custom-renderer builds,
// adds the transparent stage overlay that reports pointer drags. The native
// VML stays byte-identical: the Win32 gesture hook owns gestures there.
fn build_vml_source(custom_overlay bool) string {
	mut all := font_names.clone()
	for n in installed_font_names() {
		if n !in all {
			all << n
		}
	}
	// Match only the Option expression, not the line around it: the VML file
	// uses CRLF while a V '\n' literal would not match, which left the marker
	// itself as the only option and made the dropdown always blank.
	nl := if gallery_vml_template.contains('\r\n') { '\r\n' } else { '\n' }
	indent := '                '
	mut options := ''
	for i, n in all {
		if i > 0 {
			options += nl + indent
		}
		options += 'Option { text: "${n}" }'
	}
	mut src := gallery_vml_template.replace('Option { text: "__FONT_OPTIONS__" }', options)
	if custom_overlay {
		// The stage Image cannot report pointer phases (VML Image nodes
		// carry no clickable/draggable flags), so a transparent overlay
		// with the same frame reports them instead. It sits before the
		// hotspot repeater, so glyph taps still land on their buttons;
		// its on_tap doubles as the action id the drag phases arrive
		// with. Draggable presses do not scroll their container, so the
		// preview Scroll stays put while the stage pans under it.
		overlay := 'Rectangle {' + nl + indent + 'id: stage_touch' + nl + indent +
			'clickable: true' + nl + indent + 'draggable: true' + nl + indent +
			'on_tap: app.clear_selection()' + nl + indent + 'x: 4' + nl + indent + 'y: 4' + nl +
			indent + 'width: (preview.width - 24) * app.preview_zoom' + nl + indent +
			'height: (preview.width - 24) * 500 / 940 * app.preview_zoom' + nl + indent + '}' + nl + nl + indent
		src = src.replace(indent + 'Repeater {' + nl + indent + 'model: app.hits',
			overlay + 'Repeater {' + nl + indent + 'model: app.hits')
	}
	return src
}

// custom_overlay_enabled reports whether this build renders through ui2's
// custom gg renderer, where the native gesture hook has no slider HWNDs.
fn custom_overlay_enabled() bool {
	mut enabled := false
	$if ui2_custom_rendering ? {
		enabled = true
	}
	return enabled
}

// font_index maps a committed font name to its stable slot in font_names.
pub fn font_index(name string) int {
	for i, n in font_names {
		if n == name {
			return i
		}
	}
	return 0
}

// available_font_names lists the fonts shown in the dropdown.
pub fn available_font_names() []string {
	return font_names.clone()
}

// font_of returns a font by index, clamped to the first entry.
pub fn font_of(app &App, idx int) &shape.Font {
	i := if idx >= 0 && idx < app.fonts.len { idx } else { 0 }
	return app.fonts[i].font
}

// fs_of returns the single-font fallback set at idx.
pub fn fs_of(app &App, idx int) &shape.FontSet {
	i := if idx >= 0 && idx < app.fsets.len { idx } else { 0 }
	return app.fsets[i]
}

fn index_of_name(names []string, value string) int {
	for i, n in names {
		if n == value {
			return i
		}
	}
	return 0
}

// index_of_loaded_font also sees fonts added at runtime, which are not in the
// static VML dropdown list.
fn index_of_loaded_font(fonts []FontInfo, name string) int {
	for i, f in fonts {
		if f.name == name {
			return i
		}
	}
	return 0
}

// platform_font_dir is where the OS keeps installed faces; the file browser
// starts there when the user asks to pick an installed font.
fn platform_font_dir() string {
	$if windows {
		return 'C:/Windows/Fonts'
	} $else $if macos {
		return '/System/Library/Fonts'
	} $else {
		return '/usr/share/fonts'
	}
}

// lib_version reads the version declared in the HarfAra module's v.mod. The file
// is embedded at compile time, so the label stays correct without the source
// tree being present at runtime.
fn lib_version() string {
	for line in harfara_vmod.split('\n') {
		t := line.trim_space()
		if t.starts_with('version:') {
			return t.all_after('version:').trim_space().trim('"').trim("'")
		}
	}
	return '0.0.0'
}

// lib_commit asks git for the short hash of the tree the gallery was built from.
// A binary copied out of the checkout still shows the version and simply falls
// back to 'unknown' here.
fn lib_commit() string {
	res := os.exec(['git', 'rev-parse', '--short', 'HEAD'])
	if res.exit_code != 0 {
		return 'unknown'
	}
	hash := res.output.trim_space()
	return if hash.len > 0 { hash } else { 'unknown' }
}

fn main() {
	if '--selftest' in os.args {
		run_selftest()
		return
	}
	model := initial_app()
	install_gestures()
	ui2.run_vml[App](
		source: build_vml_source(custom_overlay_enabled())
		model:  model
		title:  'HarfAra feature gallery'
		width:  1000
		height: 640
	) or {
		os.write_file(os.join_path(os.temp_dir(), 'gallery_error.txt'), 'gallery: ${err}') or {}
		eprintln('gallery: ${err}')
		exit(1)
	}
}

fn initial_app() App {
	mut app := App{
		ctx:         shape.new_context()
		canvas:      unsafe { nil }
		lib_info:    'HarfAra ${lib_version()} · ${lib_commit()}'
		glyph_cache: shape.new_cache()
	}
	load_fonts(mut app)
	for i, name in page_names {
		app.pages << PageItem{ id: i, name: name, selected: i == 0 }
	}
	// HARFARA_GALLERY_GUIDES=all turns every guide on at startup; useful when
	// checking the overlay without clicking through the toolbar.
	if os.getenv('HARFARA_GALLERY_GUIDES') == 'all' {
		app.show_grid = true
		app.show_baseline = true
		app.show_guides = true
		app.show_char_boxes = true
		app.show_pen_ticks = true
		app.show_margins = true
		app.show_center = true
	}
	mut start := 0
	page_env := os.getenv('HARFARA_GALLERY_PAGE')
	if page_env != '' {
		n := strconv.atoi(page_env) or { 0 }
		if n >= 0 && n < page_names.len {
			start = n
		}
	}
	app.apply_page(start)
	// HARFARA_GALLERY_FONT loads an extra font at startup, for scripted checks.
	font_env := os.getenv('HARFARA_GALLERY_FONT')
	if font_env != '' {
		app.install_font(font_env)
	}
	return app
}

// load_fonts keeps one font per slot in font_names, so the index a page stores
// stays valid even if a face is missing on a particular host.
fn load_fonts(mut app App) {
	base_path := corpus_font('Amiri-Regular.ttf')
	if base_path == '' {
		panic('no corpus fonts found - set HARFARA_EXAMPLE_FONTS')
	}
	base := shape.load_font_file(base_path) or { panic('cannot load ${base_path}') }
	for name in font_names {
		path := corpus_font(name)
		mut f := if path == '' { base } else { shape.load_font_file(path) or { base } }
		// The emoji slot is only useful when the face really covers emoji and
		// has outlines HarfAra can rasterise. On other hosts keep the base font
		// in that slot and let the emoji page say so plainly.
		if name == 'seguiemj.ttf' && !f.has_glyph(rune(0x270c)) {
			f = base
		}
		app.fonts << FontInfo{ name: name, path: path, font: f }
		app.fsets << shape.new_font_set_of(f)
	}
}

// corpus_font is a thin wrapper so main.v does not need to import corpus under
// a name that collides with the module's own data structures.
fn corpus_font(name string) string {
	return corpus.font(name)
}

// apply_page resets the model to a page's defaults and renders it.
pub fn (mut app App) apply_page(i int) {
	if i < 0 || i >= page_names.len {
		return
	}
	app.page = i
	app.params = defaults(unsafe { PageID(i) })
	app.selected_glyph = -1
	for j, item in app.pages {
		app.pages[j] = PageItem{ id: item.id, name: item.name, selected: j == i }
	}
	app.load_params()
	app.desc = page_descs[i]
	app.render()
}

// select_page is the VML action for the sidebar buttons.
pub fn (mut app App) select_page(i int) {
	app.apply_page(i)
}

// load_params copies the shaped parameters into the bound UI fields.
pub fn (mut app App) load_params() {
	p := app.params
	app.text = p.text
	app.font_name = font_names[p.font]
	app.size = p.em
	app.dir_name = dir_names[p.dir_i]
	app.feature = p.feature
	app.feature_on = p.feature_on
	app.script = p.script
	app.language = p.language
	app.letter_spacing = p.letter_spacing
	app.word_spacing = p.word_spacing
	app.line_height = p.line_height
	app.wrap_width = p.wrap_width
	app.wrap_name = wrap_names[p.wrap_i]
	app.align_name = align_names[p.align_i]
	app.align_width = p.align_width
	app.vertical = p.vertical
	app.sub_x = f64(p.sub_x)
	app.sub_y = f64(p.sub_y)
	app.zoom = f64(p.zoom)
}

// sync_params is the other direction: VML writes into the bound fields before
// calling on_change, so a single method can serve every control.
pub fn (mut app App) sync_params() {
	mut p := &app.params
	p.text = app.text
	p.font = index_of_loaded_font(app.fonts, app.font_name)
	p.em = app.size
	p.dir_i = index_of_name(dir_names, app.dir_name)
	p.feature = app.feature
	p.feature_on = app.feature_on
	p.script = app.script
	p.language = app.language
	p.letter_spacing = app.letter_spacing
	p.word_spacing = app.word_spacing
	p.line_height = app.line_height
	p.wrap_width = app.wrap_width
	p.wrap_i = index_of_name(wrap_names, app.wrap_name)
	p.align_i = index_of_name(align_names, app.align_name)
	p.align_width = app.align_width
	p.vertical = app.vertical
	p.sub_x = int(app.sub_x)
	p.sub_y = int(app.sub_y)
	p.zoom = int(app.zoom)
}

fn hex_byte(v u8) string {
	digits := '0123456789abcdef'
	return '${digits[v >> 4]}${digits[v & 0xf]}'
}

// text_color is the ink colour chosen in the properties panel.
pub fn (app &App) text_color() Color {
	return Color{
		r: u8(app.text_r)
		g: u8(app.text_g)
		b: u8(app.text_b)
		a: 255
	}
}

// sync_swatch keeps the VML colour swatch in step with the three channels.
pub fn (mut app App) sync_swatch() {
	r := u8(app.text_r)
	g := u8(app.text_g)
	b := u8(app.text_b)
	app.text_swatch = '#${hex_byte(r)}${hex_byte(g)}${hex_byte(b)}'.to_upper()
}

// changed is the shared on_change action for every bound control.
pub fn (mut app App) changed() {
	app.sync_params()
	app.grid_label = '${int(app.grid_size)} px'
	app.sync_swatch()
	app.render()
}

// select_glyph is the VML action for the invisible hotspots over the preview.
pub fn (mut app App) select_glyph(i int) {
	app.selected_glyph = i
	app.render()
}

// clear_selection drops the glyph outline; tapping the empty stage clears
// what tapping a glyph set. In native builds the stage has no tap target
// and this is unreachable from the UI.
pub fn (mut app App) clear_selection() {
	app.selected_glyph = -1
	app.render()
}

// stage_touch_action names the transparent overlay over the stage image. VML
// action ids fall back to the on_tap call, so pointer phases from that
// overlay arrive with exactly this string.
const stage_touch_action = 'app.clear_selection()'

// on_pointer_event pans the stage under a pointer drag in custom-renderer
// builds, where there are no native slider HWNDs for the Win32 gesture hook
// to drive. Native builds keep the hook (wheel zoom, rotate and pitch need
// modifiers the pointer event does not carry), so the hook body is empty
// there and nothing double-handles a drag.
pub fn (mut app App) on_pointer_event(e ui2.PointerEvent) {
	$if ui2_custom_rendering ? {
		app.custom_drag(e)
	}
}

// custom_drag pans the stage from overlay drag deltas. Deltas arrive in
// window points and are mapped back to stage pixels through the same scale
// the hotspot overlay uses (stage_scale for the layout, preview_zoom for
// the view), rotated back by the stage angle. Taps and drags that start on
// a glyph hotspot keep their own action and never reach here.
fn (mut app App) custom_drag(e ui2.PointerEvent) {
	if e.action != stage_touch_action {
		return
	}
	if e.phase == 'down' {
		app.drag_x = e.x
		app.drag_y = e.y
		app.dragging = true
		return
	}
	if !app.dragging {
		return
	}
	if e.phase == 'up' || e.phase == 'leave' {
		app.dragging = false
		return
	}
	if e.phase != 'drag' {
		return
	}
	scale := app.stage_scale * app.preview_zoom
	if scale <= 0 {
		return
	}
	dx := (e.x - app.drag_x) / scale
	dy := (e.y - app.drag_y) / scale
	// Inverse of the stage_point map: screen = M(stage) with
	// M = [[cos, sin], [-sin, cos]], so stage = M' * screen.
	cos_a := math.cos(app.rotate * 0.017453292519943295)
	sin_a := math.sin(app.rotate * 0.017453292519943295)
	app.pan_x = clamp_range(app.pan_x + dx * cos_a - dy * sin_a, -300, 300)
	app.pan_y = clamp_range(app.pan_y + dx * sin_a + dy * cos_a, -300, 300)
	app.drag_x = e.x
	app.drag_y = e.y
	app.render()
}

// clamp_range keeps a directly-set transform inside its slider's range, so a
// pointer drag and the Pan sliders cannot disagree about the limits.
fn clamp_range(v f64, lo f64, hi f64) f64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// reset_properties restores the current page's parameters to their defaults.
// The guide toggles are view settings, so they are left alone.
pub fn (mut app App) reset_properties() {
	app.apply_page(app.page)
}

// browse_fonts opens the native picker. `installed` starts in the OS font
// directory; `file` starts in the current folder for an arbitrary font file.
pub fn (mut app App) browse_fonts(which string) {
	dir := if which == 'installed' { platform_font_dir() } else { os.getwd() }
	paths := ui2.open_file_dialog(ui2.FileDialogConfig{
		title:     if which == 'installed' { 'Choose an installed font' } else { 'Add a font file' }
		directory: dir
		filters:   [ui2.FileDialogFilter{
			name:       'Font files'
			extensions: ['ttf', 'otf', 'ttc', 'woff']
		}]
	})
	if paths.len > 0 {
		app.install_font(paths[0])
	}
}

// load_font_by_name is the typed-name version of browse_fonts: a path works
// directly, a bare filename is looked up in the platform font directory.
pub fn (mut app App) load_font_by_name() {
	name := app.font_query.trim_space()
	if name == '' {
		app.font_status = 'type a font file name first'
		return
	}
	path := if os.exists(name) { name } else { corpus_font(name) }
	if path == '' {
		app.font_status = 'not found: ${name}'
		return
	}
	app.install_font(path)
}

// install_font loads a face, appends it to the available fonts and selects it
// for the current page. A font that cannot be parsed is reported, not hidden.
pub fn (mut app App) install_font(path string) {
	f := shape.load_font_file(path) or {
		app.font_status = 'cannot load ${os.file_name(path)}: ${err}'
		return
	}
	name := os.file_name(path)
	mut path_exists := false
	for i, info in app.fonts {
		if info.path == path {
			app.fonts[i] = FontInfo{ name: name, path: path, font: f }
			app.fsets[i] = shape.new_font_set_of(f)
			app.params.font = i
			app.font_name = name
			app.font_status = 'reloaded ${name}'
			path_exists = true
			break
		}
	}
	if !path_exists {
		app.fonts << FontInfo{ name: name, path: path, font: f }
		app.fsets << shape.new_font_set_of(f)
		app.params.font = app.fonts.len - 1
		app.font_name = name
		app.font_status = 'added ${name} (${app.fonts.len} fonts available)'
	}
	// New fonts mean new glyph ids in old namespaces: drop the memoized
	// bitmaps rather than risk a stale hit.
	app.glyph_cache.clear()
	app.render()
}

// render shapes and rasterises the current page, writes the PNG the Image
// widget shows, and computes the status line.
pub fn (mut app App) render() {
	mut cache_ptr := &app.glyph_cache
	mut c := new_canvas(stage_w, stage_h, mut cache_ptr)
	c.clear(stage_bg)
	app.canvas = c
	draw_grid_overlay(app)
	pid := unsafe { PageID(app.page) }
	status := match pid {
		.hello { sample_hello(app) }
		.features { sample_features(app) }
		.bidi { sample_bidi(app) }
		.joining { sample_joining(app) }
		.fallback { sample_fallback(app) }
		.marks { sample_marks(app) }
		.kerning { sample_kerning(app) }
		.wrap { sample_wrap(app) }
		.measure { sample_measure(app) }
		.align { sample_align(app) }
		.vertical { sample_vertical(app) }
		.raster { sample_raster(app) }
		.emoji { sample_emoji(app) }
	}
	// Clickable hotspots mirror the shaped glyphs into VML coordinates, and a
	// selected glyph is outlined on the canvas itself.
	app.hits = []GlyphHit{}
	app.stage_scale = f64(782 - int(app.panel_w)) / f64(stage_w)
	if app.stage_scale < 0.3 {
		app.stage_scale = 0.3
	}
	opts := opts_of(&app.params)
	shaped := shape_lines(app, opts)
	mut gi := 0
	for li, line in shaped {
		for g in line.glyphs {
			if g.is_mark {
				continue
			}
			cx := text_x + g.x
			cy := base_y + f64(li) * f64(line_step(app)) - app.params.em
			mut cw := g.advance
			if cw < 8 {
				cw = 8
			}
			ch := app.params.em
			hx, hy := stage_point(app, cx, cy)
			app.hits << GlyphHit{
				id: gi
				x:  hx
				y:  hy
				w:  cw * app.stage_scale
				h:  ch * app.stage_scale
			}
			if gi == app.selected_glyph {
				c.outline(int(cx), int(cy), int(cw), int(ch), accent)
			}
			gi++
		}
	}
	if app.selected_glyph >= 0 && app.selected_glyph < gi {
		app.status += '   selected glyph #${app.selected_glyph}'
	}
	// Pan and rotation move the painted stage; the hotspots above use the same
	// transform so a click still lands on the glyph it covers.
	c.transform(app.pan_x, app.pan_y, app.rotate, stage_bg)
	// The stage border sits on top of everything so the drawable region is
	// always visible, even with the guides turned off.
	c.outline(0, 0, stage_w - 1, stage_h - 1, Color{148, 163, 184, 255})
	app.canvas = unsafe { nil }
	app.status = status
	app.render_count++
	// The stage file format follows the backend: the native Windows image
	// control only loads BMP, while the custom gg renderer reads the PNG
	// every other backend takes.
	mut path := os.join_path(os.temp_dir(), 'harfara_gallery_${app.render_count}.bmp')
	$if ui2_custom_rendering ? {
		path = os.join_path(os.temp_dir(), 'harfara_gallery_${app.render_count}.png')
		c.write_png(path)
	} $else {
		c.write_bmp(path)
	}
	app.image_path = os.real_path(path)
	app.old_paths << path
	if app.old_paths.len > 3 {
		old := app.old_paths[0]
		app.old_paths = app.old_paths[1..]
		os.rm(old) or {}
	}
}

// run_selftest exercises the pipeline without opening a window, so CI can
// check that the gallery's assumptions still hold. It also validates the
// VML document against the App model in both variants (with and without the
// custom-renderer touch overlay), so a VML edit that breaks loading fails
// here rather than at window open.
fn run_selftest() {
	// Reference fields need an initializer even though validation never
	// touches the engine; the VML check reads bound fields only.
	validator := App{
		ctx:    shape.new_context()
		canvas: unsafe { nil }
	}
	for overlay in [false, true] {
		ui2.new_vml_app(build_vml_source(overlay), validator) or {
			eprintln('FAIL: gallery VML invalid (overlay=${overlay}): ${err}')
			exit(1)
		}
	}
	path := corpus_font('Amiri-Regular.ttf')
	if path == '' {
		eprintln('FAIL: no Amiri corpus font')
		exit(1)
	}
	ctx := shape.new_context()
	f := shape.load_font_file(path) or {
		eprintln('FAIL: cannot load ${path}: ${err}')
		exit(1)
	}
	fs := shape.new_font_set_of(f)
	line := layout.layout_paragraph(ctx, 'سلام'.runes(), .rtl, fs, 32.0)
	mut report := 'selftest: glyphs=${line.glyphs.len} width=${line.width:.2f}\n'
	if line.glyphs.len == 0 {
		report += 'FAIL: no glyphs produced\n'
		os.write_file('gallery_selftest.txt', report) or {}
		eprintln(report)
		exit(1)
	}
	bm := f.rasterize(line.glyphs[0].gid, 32.0, 0, 0)
	if bm.is_empty() {
		report += 'FAIL: first glyph has no ink\n'
		os.write_file('gallery_selftest.txt', report) or {}
		eprintln(report)
		exit(1)
	}
	report += 'PASS: selftest shaped and rasterised a line\n'
	os.write_file('gallery_selftest.txt', report) or {}
	println(report)
}
