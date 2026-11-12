/* smoke.c — the C API exercised end to end: load, layout, wrap, measure,
 * breaks, rasterize, and one error path. Fails loud on anything unexpected.
 *
 * Build (from this directory, with the DLL beside vtext.h at the repo root):
 *   tcc smoke.c ../../vtext.dll -o smoke.exe
 *   gcc smoke.c -L../.. -lvtext -o smoke.exe   (via the import lib, see USAGE.md)
 * Run (the DLL must sit beside the exe on Windows):
 *   smoke.exe ../../testdata/fonts/Amiri-Regular.ttf
 */
#include <stdio.h>
#include <string.h>

#include "../../vtext.h"

static int fails = 0;
static char err[512];

#define CHECK(cond, msg) do { \
	if (!(cond)) { printf("FAIL: %s\n", msg); fails++; } \
} while (0)

#define CHECK_ERR(msg) do { \
	printf("FAIL: %s: %s\n", msg, err[0] ? err : "(no reason)"); fails++; \
} while (0)

int main(int argc, char **argv) {
	const char *font_path = argc > 1 ? argv[1] : "../../testdata/fonts/Amiri-Regular.ttf";
	printf("vtext version: %s\n", vtext_version());

	vtext_context_t *ctx = vtext_context_new();
	CHECK(ctx != 0, "context created");

	vtext_fontset_t *fs = vtext_fontset_new();
	CHECK(fs != 0, "font set created");

	err[0] = 0;
	vtext_font_t *font = vtext_fontset_add_file(fs, font_path, err, sizeof(err));
	if (!font) {
		printf("FAIL: cannot load %s: %s\n", font_path, err);
		return 1;
	}
	printf("font units/em: %d\n", vtext_font_units_per_em(font));

	/* Layout: mixed-direction text, direction taken from the text. */
	const char *text = "Hello \xd8\xb3\xd9\x84\xd8\xa7\xd9\x85"; /* Hello سلام */
	err[0] = 0;
	vtext_line_t *line = vtext_layout(ctx, text, (int)strlen(text), VTEXT_AUTO, fs, 32.0,
		err, sizeof(err));
	if (!line) {
		CHECK_ERR("line laid out");
		return 1;
	}
	int n = vtext_line_glyph_count(line);
	printf("glyphs: %d width: %.2f\n", n, vtext_line_width(line));
	CHECK(n > 0, "line has glyphs");
	CHECK(vtext_line_width(line) > 0.0, "line has width");
	for (int i = 0; i < n; i++) {
		vtext_glyph_t g;
		CHECK(vtext_line_glyph(line, i, &g), "glyph readable");
		CHECK(vtext_line_glyph_font(line, i) != 0, "glyph has a font");
		if (i < 4) {
			printf("  gid=%u x=%.2f adv=%.2f cluster=%d mark=%d\n",
				g.gid, g.x, g.advance, g.cluster, g.is_mark);
		}
	}
	vtext_glyph_t oob;
	CHECK(!vtext_line_glyph(line, n, &oob), "out-of-range glyph refused");

	/* Wrap at a narrow width: more than one line, covering the whole text. */
	err[0] = 0;
	vtext_wrap_t *w = vtext_wrap(ctx, text, (int)strlen(text), VTEXT_AUTO, fs, 32.0, 100.0,
		err, sizeof(err));
	CHECK(w != 0, "paragraph wrapped");
	int lines = vtext_wrap_line_count(w);
	printf("wrapped lines at 100px: %d\n", lines);
	CHECK(lines >= 1, "at least one line");
	int covered = 0;
	for (int i = 0; i < lines; i++) {
		vtext_line_t *l = vtext_wrap_line(w, i);
		CHECK(l != 0, "wrap line readable");
		covered += vtext_wrap_line_to(w, i) - vtext_wrap_line_from(w, i);
		printf("  line %d: chars [%d,%d) width %.2f\n", i,
			vtext_wrap_line_from(w, i), vtext_wrap_line_to(w, i), vtext_line_width(l));
	}
	CHECK(covered == 10, "lines cover the whole text");

	/* Measure without drawing anything. */
	vtext_metrics_t m;
	err[0] = 0;
	CHECK(vtext_measure(ctx, text, (int)strlen(text), VTEXT_AUTO, fs, 32.0, &m, err, sizeof(err)),
		"paragraph measured");
	printf("min=%.2f max=%.2f line_height=%.2f\n",
		m.min_content_width, m.max_content_width, m.line_height);
	CHECK(m.max_content_width > 0.0, "max width positive");
	CHECK(m.min_content_width <= m.max_content_width, "min within max");

	/* Breaks on plain ASCII. */
	const char *words = "one two";
	err[0] = 0;
	vtext_breaks_t *b = vtext_breaks(ctx, words, (int)strlen(words), 1, err, sizeof(err));
	CHECK(b != 0, "breaks reported");
	printf("breaks:");
	for (int i = 0; i < b->len; i++) {
		printf(" %d%s", b->starts[i], b->mandatory[i] ? "!" : "");
	}
	printf("\n");
	CHECK(b->len == 2, "space plus end");
	vtext_breaks_free(b);

	/* Rasterize the first non-mark glyph with its own font. */
	for (int i = 0; i < n; i++) {
		vtext_glyph_t g;
		vtext_line_glyph(line, i, &g);
		if (g.is_mark) {
			continue;
		}
		vtext_font_t *gf = vtext_line_glyph_font(line, i);
		err[0] = 0;
		vtext_bitmap_t *bm = vtext_rasterize(gf, g.gid, 32.0, 0, 0, err, sizeof(err));
		CHECK(bm != 0, "glyph rasterized");
		printf("bitmap: %dx%d at (%d,%d)%s\n", vtext_bitmap_width(bm),
			vtext_bitmap_height(bm), vtext_bitmap_left(bm), vtext_bitmap_top(bm),
			vtext_bitmap_data(bm) ? "" : " (empty)");
		CHECK(vtext_bitmap_data(bm) != 0, "bitmap has ink");
		vtext_bitmap_free(bm);
		break;
	}

	/* Error path: a font that is not there. */
	err[0] = 0;
	CHECK(vtext_font_load_file("no-such-font.ttf", err, sizeof(err)) == 0,
		"missing font refused");
	CHECK(err[0] != 0, "error recorded");
	printf("error string: %s\n", err[0] ? err : "(none)");

	vtext_wrap_free(w);
	vtext_line_free(line);
	vtext_fontset_free(fs);
	vtext_font_free(font);
	vtext_context_free(ctx);

	if (fails == 0) {
		printf("SMOKE OK\n");
	}
	return fails ? 1 : 0;
}
