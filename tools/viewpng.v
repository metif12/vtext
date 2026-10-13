module main

// viewpng shows a PNG in a window, with zoom and pan.
//
// This started as a window inside the examples themselves, which is what the roadmap asks for and
// what a text engine's examples want. It cannot be that, and the reason is worth recording because
// it is not a question of effort: **a program that imports both `gg` and `vtext` does not build.**
// The two each include `stb_truetype.h` with `STB_TRUETYPE_IMPLEMENTATION` into V's single generated
// C translation unit, and C forbids two definitions of the same identifier in one unit whatever their
// linkage — 453 errors, `redefinition of 'stbtt__buf_get8'` and its neighbours. `stbtt.c.v` says
// `STBTT_STATIC` is what stops that; it stops duplicate symbols at *link* time, which is what it
// guarded against when V emitted one translation unit per module. There is only one now.
//
// So the viewer is a separate program that knows nothing about text. That is also the better
// arrangement for the usual reasons: one dependency instead of nine, it opens any PNG rather than one
// this library wrote, and the examples keep building on a machine with no display.
//
// Usage: `v run tools/viewpng.v <file.png>`
//
// The wheel scales about the cursor, the left drag pans, and closing the window ends it. Zoom is
// bounded at 0.05 to 24: below that the picture is a dot and above it a pixel is a screen, and
// neither is a thing anybody wants to scroll through.

import gg
import os

fn main() {
	if os.args.len < 2 {
		eprintln('usage: v run tools/viewpng.v <file.png>')
		exit(1)
	}
	path := os.args[1]
	mut app := &App{
		path: path
	}
	app.gg = gg.new_context(
		width:         800
		height:        600
		create_window: true
		window_title:  os.file_name(path)
		frame_fn:      frame
		user_data:     app
		init_fn:       initialize
	)
	app.gg.run()
}

// App is the state the callbacks draw from.
//
// It is the `user_data` gg hands back to `init_fn` and `frame_fn`, which is why both take it by
// reference rather than taking a `voidptr`: these two callbacks are the only place a gg program gets
// its state, and a `__global` of a struct imported from another module does not survive this
// compiler — it links and then dies before `main` with no output, in a GUI-subsystem binary whose
// `eprintln` goes nowhere to say so.
struct App {
mut:
	gg       &gg.Context = unsafe { nil }
	path     string
	img      gg.Image
	zoom     f32 = 1.0
	pan_x    f32
	pan_y    f32
	dragging bool
	last_x   int
	last_y   int
}

// initialize is called once sokol is up, which is the only point an image can be made at all.
//
// `create_image_from_byte_array` from `main` — before `run()` — exits 255 with no message, because
// sokol has no GPU context yet. The panic is silent because a GUI-subsystem binary on Windows has no
// console; this tool's first version was diagnosed as dying for no reason when it had been failing to
// decode all along.
fn initialize(mut app App) {
	bytes := os.read_bytes(app.path) or { return }
	app.img = app.gg.create_image_from_byte_array(bytes, gg.ImageConfig{}) or { return }
}

// frame draws the picture at the current zoom and pan.
fn frame(mut app App) {
	app.gg.begin()
	if app.img.width > 0 && app.img.height > 0 {
		drag_zoom_pan(mut app)
		dw := f32(app.img.width) * app.zoom
		dh := f32(app.img.height) * app.zoom
		app.gg.draw_image(app.pan_x, app.pan_y, dw, dh, &app.img)
		// The readout sits over the picture rather than beside it, because a pane beside it costs a
		// third of the width on a picture that is already the whole point.
		label := '${app.img.width}x${app.img.height}  zoom ${app.zoom:.2f}x'
		app.gg.draw_rect_filled(8, 8, f32(label.len * 7) + 12, 20, gg.Color{0, 0, 0, 170})
		app.gg.draw_text(12, 10, label, gg.TextCfg{
			color: gg.Color{240, 240, 240, 255}
			size:  14
		})
	}
	app.gg.end()
}

// drag_zoom_pan reads the mouse. The wheel is read once per frame rather than per event, so a fast
// scroll is one jump rather than a queue of them.
fn drag_zoom_pan(mut app App) {
	ctx := app.gg
	if ctx.scroll_y != 0 {
		before := app.zoom
		// 1.1 per notch: small enough to be a fine adjustment at 16 pixels, large enough to cross a
		// font size in three notches.
		app.zoom *= if ctx.scroll_y > 0 { f32(1.1) } else { f32(1.0 / 1.1) }
		if app.zoom < 0.05 {
			app.zoom = 0.05
		}
		if app.zoom > 24.0 {
			app.zoom = 24.0
		}
		// Zoom about the cursor, so the thing under the pointer stays under it. Growing from the
		// top-left corner instead moves what is being looked at on every nudge.
		mx := f32(ctx.mouse_pos_x)
		my := f32(ctx.mouse_pos_y)
		if mx > 0 || my > 0 {
			f := app.zoom / before
			app.pan_x = mx - (mx - app.pan_x) * f
			app.pan_y = my - (my - app.pan_y) * f
		}
	}
	if app.dragging {
		if ctx.mouse_pos_x != app.last_x || ctx.mouse_pos_y != app.last_y {
			app.pan_x += f32(ctx.mouse_pos_x - app.last_x)
			app.pan_y += f32(ctx.mouse_pos_y - app.last_y)
			app.last_x = ctx.mouse_pos_x
			app.last_y = ctx.mouse_pos_y
		}
	} else if ctx.mouse_buttons.has(.left) {
		app.dragging = true
		app.last_x = ctx.mouse_pos_x
		app.last_y = ctx.mouse_pos_y
	}
	if !ctx.mouse_buttons.has(.left) {
		app.dragging = false
	}
}
