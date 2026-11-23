# gallery

An interactive example: one ui2 window, a list of thirteen HarfAra features,
and a live page for each one. The controls belong to ui2; the stage is a
bitmap that HarfAra renders again on every parameter change. The numbers under
the picture come from the same layout that was drawn.

## Run

From the repository root, with `harfara`, `corpus` and `ui2` on the module
path (`VMODULES` pointing at the directory that holds all three checkouts):

```sh
v run examples/gallery
```

Or from this directory:

```sh
cd examples/gallery
v run .
```

The custom gg renderer (same text, no native controls) builds with ui2's
custom-rendering define — this is also the cross-platform path, since the
native backend is Windows-only:

```sh
v -d ui2_custom_rendering run examples/gallery
```

Or from this directory:

```sh
cd examples/gallery
v -d ui2_custom_rendering run .
```

`HARFARA_EXAMPLE_FONTS` overrides where fonts are found; by contrast the corpus
under `testdata/fonts` is used by default, as in every other example.

## Controls

- The left column is a vertical sidebar: a branded header, a `FEATURES` section
  label, flat navigation rows with an accent bar on the active page, and a
  footer showing the HarfAra version (embedded from `v.mod`) and the short git
  hash of the checkout. The right column is a properties panel
  with vertically stacked, evenly spaced controls, grouped under TEXT, LAYOUT,
  OPENTYPE, RASTER, FONTS and COLOR, like an IDE inspector. The COLOR section
  has R/G/B sliders and a live swatch that set the ink colour used by the
  stage. The `Reset` button in its header
  restores the current page's parameters without changing the guide settings.
- The Content field is a multi-line TextArea; newlines are shaped as separate
  lines on the stage. The slider in its row resizes it, shifting the controls
  below and extending the properties pane's scroll range. The Feature tag,
  Script and Lang fields update the line on every edit. Unicode input works, so
  Persian, Hebrew and CJK text can be tried directly.
- The Font dropdown lists the committed faces plus every font file found in
  the OS font directory. Dropdowns for paragraph direction, wrap mode and
  alignment are separate. The `FONTS` section can also browse installed fonts
  with the native picker, add an arbitrary font file, or load one by typed
  name/path. A newly loaded font is selected at once and stays available for
  the rest of the session; its name is shown under the dropdown.
- Numeric fields control size, letter and word spacing, line height, wrap
  width, align width, raster subpixel offsets and zoom, and the grid size in
  the guide bar. They are editable text fields rather than native sliders:
  ui2's Windows trackbar paints a dark native background that did not fit the
  light properties panel.
- The horizontal guide bar above the preview toggles the studio guides: Grid,
  Baseline, Guides (x-height/cap/descent), Char boxes, Pen ticks, Margins and
  Center. Its `Pitch` slider sets the equal cell size, `Zoom` scales the
  preview image, and `Pane` resizes the preview/properties split. `Pan X` /
  `Pan Y` shift the stage and `Rotate` turns it; both are applied to the
  rendered bitmap, and the glyph hotspots follow the same transform. When the
  zoomed image is larger than the pane, the preview scrolls on both axes with
  always-visible scrollbars. All guides are drawn behind the text by HarfAra on
  every re-render.
- On native Windows the same controls also take direct mouse gestures over the
  preview: wheel zooms, `Ctrl`+wheel changes the pitch, drag pans,
  `Shift`+drag (or the middle button) rotates, and `Ctrl`+drag changes the
  pitch. The hook drives the real Sliders, so the toolbar and the model stay
  in sync. In custom-renderer builds there are no native sliders to drive, so
  a drag over the stage pans it directly through the model's pointer hook;
  wheel and modifier gestures stay on the sliders there, and other platforms
  keep the sliders as the only input.
- Clicking a glyph in the preview selects it: the glyph is outlined and the
  selection is reported in the status line. Clicking the empty stage clears the
  selection (custom-renderer builds; native builds keep the selection until
  another glyph is picked).

## Pages

1. Hello / Shaping — glyph ids, advances, pen positions.
2. OpenType features — the same text with `-tag` and with `tag`.
3. Bidi & direction — resolved paragraph level in mixed text.
4. Arabic joining — `isol`/`init`/`medi`/`fina` annotated per glyph, drawn in
   a naskh face that joins with substitutions alone so no cursive attachment
   is needed for a correct shape.
5. Font fallback — each glyph coloured by the font that supplied it.
6. Marks — mark count and anchor placement.
7. Kerning — `kerns` and a GPOS pair offset.
8. Wrap & breaks — wrapped lines at a chosen width.
9. Measure — min/max content width and ink extent.
10. Align & spacing — all four alignments and the spacing options.
11. Vertical text — one column, its width, length and stacking step.
12. Raster / subset — the enlarged coverage bitmap and the subset byte count.
13. Emoji & variation — text and emoji glyph ids for the sample emoji (for
    example ✌️, U+270C), plus the honest answer about whether the face carries
    a U+FE0F variation sequence. The committed corpus faces have no emoji
    coverage, so this page defaults to `seguiemj.ttf` from the platform font
    directory; if another face is chosen and a glyph is missing, the status
    names it instead of leaving a silent `.notdef` box.

## Checks

Headless checks, no window:

```sh
v run examples/gallery -- --selftest
v -d ui2_custom_rendering run examples/gallery -- --selftest
```

It validates the VML document against the App model in both variants (with and
without the custom-renderer touch overlay), then writes `gallery_selftest.txt`
with the result. The exit code is zero only when the VML loads and a line
shaped and its first glyph rasterised with ink.

`HARFARA_GALLERY_PAGE` opens a chosen page directly (zero-based), and
`HARFARA_GALLERY_GUIDES=all` starts with every guide enabled. The rendered
stage is written as a bitmap into the system temp directory, which is how every
page and guide can be checked without clicking through the UI. BMP is used in
native builds because ui2's native Windows image control only loads BMP;
custom-renderer builds write PNG, which the gg image loader reads on every
backend.

## Why ui2 rather than gg directly

The stage is pure HarfAra: glyphs are rasterised into an RGBA framebuffer and
written as a bitmap that the ui2 `Image` widget shows. ui2 owns the window and
every control; the custom-renderer define (`-d ui2_custom_rendering`) swaps the
native Win32 controls for ui2's own gg renderer without touching the gallery's
code — HarfAra's stb_truetype copy is `STBTT_STATIC`, so the two C copies
coexist in one binary either way.

The VML model keeps engine objects (context, fonts, canvas) private. ui2
reflects every public model field recursively, and a public pointer into the
shaping engine sends that walk into a cycle.

The light slider styling used here depends on the ui2 fix in
[vlang/ui2#127](https://github.com/vlang/ui2/pull/127): on Windows a Slider is
a native trackbar that otherwise paints its own dark background.
