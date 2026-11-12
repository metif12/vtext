# Usage

Using vtext from V and from C: the five-minute path, the build recipes, and
the full API with its ownership rules.

## V in five minutes

vtext is a V module. The module lives in this tree; point `VMODULES` at its
parent and import it:

```sh
# PowerShell
$env:VMODULES='C:\Users\MR\Projects'
# sh
export VMODULES=$HOME/Projects
```

```v
import vtext

fn main() {
	ctx := vtext.new_context()
	fs := vtext.new_font_set()
	fs.add(vtext.load_font_file('testdata/fonts/Amiri-Regular.ttf') or { panic(err) })

	line := vtext.layout_paragraph(ctx, 'Hello سلام'.runes(), .auto, fs, 32.0)
	println('width: ${line.width} glyphs: ${line.glyphs.len}')
	for g in line.glyphs {
		font := g.font or { continue }
		bitmap := font.rasterize(g.gid, 32.0, 0, 0)
		// bitmap.left and bitmap.top place it at g.x and g.y on the baseline
		println('${g.gid} at ${g.x},${g.y} ${bitmap.width}x${bitmap.height}')
	}
}
```

The direction argument (`.ltr`, `.rtl`, `.auto`) drives the bidi algorithm's
P2/P3; `.auto` reads it from the first strong character. `em_px` is the size
of an em square in pixels.

Wrapping, measuring and breaking are separate calls over the same pipeline:

```v
// As many lines as fit 400 px, shaped once and cut out of one layout.
for w in vtext.wrap_paragraph(ctx, text.runes(), .auto, fs, 32.0, 400.0) {
	draw(w.line) // glyphs, positioned, ready to draw
	caret_at(w.from, w.to) // the input range this line holds
}

// The two widths a layout engine needs before it draws anything.
m := vtext.measure_paragraph(ctx, text.runes(), .auto, fs, 32.0)
// m.min_content_width, m.max_content_width, m.ascent, m.descent, m.line_height

// Break positions, for a caller that decides the width itself.
for b in vtext.break_opportunities(ctx, text.runes(), true) {
	// b.start is the input index; b.is_mandatory marks hard breaks
}
```

Options (discretionary features, line height, letter and word spacing) have
`_with` forms that take the same `LayoutOptions`. A paragraph wrapped without
the features was shaped without them, so the box and the line are sized with
the same options or they disagree about the width of the same text:

```v
mut opts := vtext.LayoutOptions{}
opts.features = ['liga']
opts.line_height = 28.0
opts.letter_spacing = 0.5
opts.word_spacing = 2.0
line := vtext.layout_paragraph_with(ctx, text.runes(), .rtl, fs, 32.0, &opts)
```

`README.md` documents the pipeline, the font fallback rules, kerning, marks
and every inspection API in full. This file does not repeat it.

## C in five minutes

The C API is `vtext.h` at the repo root, implemented by `capi.v`. Handles are
opaque; every function takes plain C types; errors come back in a caller-owned
buffer, so there is no hidden state and no per-thread anything.

```c
#include <stdio.h>
#include "vtext.h"

int main(void) {
	char err[512] = {0};
	vtext_context_t *ctx = vtext_context_new();
	vtext_fontset_t *fs = vtext_fontset_new();
	vtext_font_t *font = vtext_fontset_add_file(fs, "Amiri-Regular.ttf", err, sizeof(err));

	const char *text = "Hello \xd8\xb3\xd9\x84\xd8\xa7\xd9\x85"; /* Hello سلام */
	vtext_line_t *line = vtext_layout(ctx, text, 11, VTEXT_AUTO, fs, 32.0, err, sizeof(err));
	for (int i = 0; i < vtext_line_glyph_count(line); i++) {
		vtext_glyph_t g;
		vtext_line_glyph(line, i, &g);
		vtext_font_t *gf = vtext_line_glyph_font(line, i);
		vtext_bitmap_t *bm = vtext_rasterize(gf, g.gid, 32.0, 0, 0, err, sizeof(err));
		/* g.x, g.y place it; vtext_bitmap_left/top place the ink box */
		vtext_bitmap_free(bm);
	}
	vtext_line_free(line);
	vtext_fontset_free(fs);
	vtext_font_free(font);
	vtext_context_free(ctx);
	return 0;
}
```

`examples/c-api/smoke.c` is this shape exercised end to end — layout, wrap,
measure, breaks, rasterize and one error path — and it fails loud on anything
unexpected. Build it the way below and run it against any font.

## Building the shared library

One command from the repo root. `-gc none` is load-bearing, not a preference:
with the Boehm collector the library would free objects the C caller still
holds, and the caller has no handle the collector can see.

```sh
v -shared -gc none -cc tcc -o vtext.dll .
```

On Linux/macOS the same pattern produces `libvtext.so` / `libvtext.dylib`:

```sh
v -shared -gc none -cc gcc -o libvtext.so .
```

That command is the documented pattern but is not verified here — the DLL
below is, on Windows, through both link routes. The `#flag` is Windows-only;
an ELF shared object exports the marked wrappers by default and MSVC marks
them itself.

The export names come from `@[export]` on each function in `capi.v`. A PE
linker ignores the ELF visibility attribute the compiler used to mark them
with for non-MSVC toolchains, so `capi.v` also carries
`#flag windows -Wl,-export-all-symbols` for tcc. MSVC marks the wrappers
itself. (Upstream fix: vlang/v `exported_symbol_attribute` should emit
`__declspec(dllexport)` for every Windows toolchain, not just MSVC.)

Linking a caller:

```sh
# tcc, straight against the DLL:
tcc smoke.c ./vtext.dll -o smoke.exe
# gcc, via an import library generated from the curated export list:
dlltool -d vtext.def --dllname vtext.dll -l libvtext.dll.a
gcc smoke.c -L. -lvtext -o smoke.exe
```

`vtext.def` names exactly the `vtext_*` entry points, so the gcc route links
a clean import library rather than every runtime symbol the tcc flag exports.

### The stack the library needs

A caller thread needs a generous stack — 32 MB, the same reserve V gives its
own executables (`-Wl,-stack,33554432` for tcc, `-Wl,--stack,33554432` for
gcc; MSVC takes `/STACK:33554432`, same meaning, not run here). With the
default 1 MB stack the first call into the library faults with a stack
overflow.

The reason is in the generated tables, not in the call: `ucd_names.v` holds
two 143,217-element constant arrays, and the compiler materializes them as
stack compound literals in the module initializer — over 2 MB before a single
character is shaped. Every in-tree test binary survives this because V links
executables with a 32 MB reserve; a DLL runs on the host's stack and inherits
whatever the host reserved. The real fix is generating those tables as parsed
strings like every other `ucd_*.v` file, which is recorded in `ROADMAP.md`
rather than done here. Until then, reserve the stack.

On Windows the DLL must also sit beside the executable (or on `PATH`); that
is the loader's rule, not this library's.

CI builds the library and runs the smoke test on all three platforms on every
push and pull request (`clib` in `ci.yml`), beside the formatter gate, the
full V suite, and the differential baseline. A green run means the headers in
the tree match the library that was just built, because the smoke test
compiles against exactly those headers.

## Releases

Tag the tree `c-api-vX.Y.Z` and push the tag; `release-c.yml` builds the
library on all three platforms and attaches `vtext.h`, `vtext.def` and the
binaries (plus a MinGW import library on Windows) to the GitHub release.

The tag, `v.mod` and `vtext_version` must be one number: the release job
refuses a tag that disagrees with either. So bumping the version is two edits
— the version in `v.mod` and the `c'...'` string `vtext_version` returns —
and then the tag. The smoke test asserts nothing about the version string, on
purpose: a test that reads the value it is checking from the code under test
passes whatever the code says.

## C API reference

Conventions first, because they hold for every function below:

- `text` is UTF-8 bytes with an explicit `len`; it is copied, so the caller
  owns its buffer throughout.
- `dir` is `VTEXT_LTR` (0), `VTEXT_RTL` (1), or `VTEXT_AUTO` (2).
- `err`/`errcap` is a caller-owned buffer for the failure sentence. A null
  buffer or no room drops the sentence rather than writing past the end.
  Fallible functions return null/0 on failure with the reason in `err`.
- Handles named `*_free` own their object. Handles handed out as "borrowed"
  die with their owner and must not be freed.
- Order of release: lines and wraps first, then the font set, then the fonts,
  then the context. A line's glyphs name their fonts, and a set borrows its
  fonts, so freeing a font first leaves both dangling.

Lifetime:

```c
vtext_context_t *ctx = vtext_context_new();
vtext_fontset_t *fs = vtext_fontset_new();
vtext_font_t *font = vtext_fontset_add_file(fs, path, err, sizeof(err));
/* ... shape, draw ... */
vtext_fontset_free(fs);   /* the chain, not the fonts */
vtext_font_free(font);
vtext_context_free(ctx);
```

Context: one per text system, shared between threads and between faces. It
costs a few hundred microseconds to build (the tables are decoded once), so
it is not a per-call object.

Fonts: `vtext_font_load_file` / `vtext_font_load_bytes` (bytes are copied).
`vtext_fontset_add` borrows; `vtext_fontset_add_file` loads, appends, and
returns the font for the caller to free. `vtext_fontset_new_script(primary,
general)` prefers a font per script, which is what a flat fallback order
cannot express when both fonts cover both scripts. Metrics
(`vtext_font_units_per_em/ascent/descent/line_height/is_monospace`) and
coverage (`vtext_font_glyph_index`, `vtext_font_has_glyph`) read the font;
zero from `glyph_index` is `.notdef`, which for an uncovered codepoint is the
correct answer rather than a miss.

Layout: `vtext_layout` / `vtext_layout_with` (options struct below) return an
owned line. `vtext_line_glyph_count` counts drawable glyphs — a mark and its
base are both present and share a position. `vtext_line_glyph` writes glyph
`i` into the caller's struct (1) or refuses (0). `vtext_line_glyph_font`
is the font that glyph was found in, borrowed from the set; it is what
`vtext_rasterize` needs, because a glyph without its font is not drawable.
`vtext_line_width/ascent/descent/line_height` read the line; ascent and
descent are the ink's extent, larger than the font's own metrics whenever a
mark reaches above or below them. `vtext_line_free` releases the line and its
glyphs, not the fonts.

Options:

```c
vtext_options_t opts = { "liga", 28.0, 0.5, 2.0 };
/* features, line_height (0 takes the font's own), letter_spacing, word_spacing */
```

Features are one comma-separated string because a C caller has no string
array; an empty entry is skipped, so a trailing comma is harmless. A combining
mark is not spaced: it shares its base's advance, and spacing it too would
charge one character twice.

Wrap: `vtext_wrap` / `vtext_wrap_with` return an owned wrap; lines are
borrowed (`vtext_wrap_line`, valid until `vtext_wrap_free`) with their
half-open input range from `vtext_wrap_line_from/to`. A word wider than the
width goes on a line of its own rather than being split, and a text with no
break in it returns one line however narrow the width.

Measure: `vtext_measure` / `vtext_measure_with` fill the caller's
`vtext_metrics_t` (both widths from one shaping) and return 1, or 0 with the
reason in `err`. `min_content_width` excludes trailing spaces; see `README.md`
for why deriving it from a wrapped line over-reports by one space per word.

Breaks: `vtext_breaks` returns an owned `vtext_breaks_t` — two parallel
arrays of `len` ints, starts and whether each is mandatory — freed with
`vtext_breaks_free`. `mandatory_first` decides whether the flags are carried;
the positions are the same either way.

Rasterize: `vtext_rasterize` renders one glyph at `em_px` with quarter-pixel
`sub_x`/`sub_y` (four is one whole pixel) and returns an owned bitmap.
`vtext_bitmap_width/height/left/top` place it — the bitmap's own (0, 0)
belongs at (pen − left, baseline − top), top positive upwards — and
`vtext_bitmap_data` is the row-major 8-bit coverage, borrowed, width×height
bytes, null for an empty glyph. `vtext_bitmap_free` releases the bitmap and
its coverage together.

## Keeping the C surface in step

`capi.v` is the source of truth: every `@[export]` there appears in
`vtext.h` and `vtext.def` under the same name. The header's structs mirror the
V structs field for field (`CGlyph` ↔ `vtext_glyph_t`, `CMetrics` ↔
`vtext_metrics_t`, `CBreaks` ↔ `vtext_breaks_t`, `COptions` ↔
`vtext_options_t`); a field added on one side must be added on the other.

The one thing that does not convert is width: V `int` is 64-bit in this
toolchain, so every integer that crosses the boundary in a struct is an
explicit `i32` on the V side and a 32-bit `int` on the C side. Scalar
parameters and returns go through the export wrappers, which narrow them, so
plain `int` is correct there for values that fit — counts, clusters, glyph
ids. A struct field added as bare `int` will read adjacent memory on one
side; the smoke test's out-of-range and break assertions are what catch that.
