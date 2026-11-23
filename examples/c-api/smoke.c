/* smoke.c — the C API exercised end to end: load, layout, wrap, measure,
 * breaks, rasterize, and one error path. Fails loud on anything unexpected.
 *
 * Build (from this directory, with the DLL beside harfara.h at the repo root):
 *   tcc smoke.c ../../harfara.dll -o smoke.exe
 *   gcc smoke.c -L../.. -lharfara -o smoke.exe   (via the import lib, see USAGE.md)
 * Run (the DLL must sit beside the exe on Windows):
 *   smoke.exe ../../testdata/fonts/Amiri-Regular.ttf
 */
#include <stdio.h>
#include <string.h>

#include "../../harfara.h"

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
	printf("harfara version: %s\n", harfara_version());

	harfara_context_t *ctx = harfara_context_new();
	CHECK(ctx != 0, "context created");

	harfara_fontset_t *fs = harfara_fontset_new();
	CHECK(fs != 0, "font set created");

	err[0] = 0;
	harfara_font_t *font = harfara_fontset_add_file(fs, font_path, err, sizeof(err));
	if (!font) {
		printf("FAIL: cannot load %s: %s\n", font_path, err);
		return 1;
	}
	printf("font units/em: %d\n", harfara_font_units_per_em(font));

	/* Layout: mixed-direction text, direction taken from the text. */
	const char *text = "Hello \xd8\xb3\xd9\x84\xd8\xa7\xd9\x85"; /* Hello سلام */
	err[0] = 0;
	harfara_line_t *line = harfara_layout(ctx, text, (int)strlen(text), HARFARA_AUTO, fs, 32.0,
		err, sizeof(err));
	if (!line) {
		CHECK_ERR("line laid out");
		return 1;
	}
	int n = harfara_line_glyph_count(line);
	printf("glyphs: %d width: %.2f\n", n, harfara_line_width(line));
	CHECK(n > 0, "line has glyphs");
	CHECK(harfara_line_width(line) > 0.0, "line has width");
	for (int i = 0; i < n; i++) {
		harfara_glyph_t g;
		CHECK(harfara_line_glyph(line, i, &g), "glyph readable");
		CHECK(harfara_line_glyph_font(line, i) != 0, "glyph has a font");
		if (i < 4) {
			printf("  gid=%u x=%.2f adv=%.2f cluster=%d mark=%d\n",
				g.gid, g.x, g.advance, g.cluster, g.is_mark);
		}
	}
	harfara_glyph_t oob;
	CHECK(!harfara_line_glyph(line, n, &oob), "out-of-range glyph refused");

	/* Vertical through the C struct: the flag must arrive as laid out, which
	 * is what proves the V and C option structs agree. Amiri carries no
	 * vertical metrics, so this also exercises the fallback: advances stay
	 * horizontal while the pen runs down one column, and each glyph centers
	 * in the column width instead of sharing a left edge. */
	harfara_options_t vopts;
	memset(&vopts, 0, sizeof(vopts));
	vopts.vertical = 1;
	const char *harfara_str = "Hello";
	err[0] = 0;
	harfara_line_t *vline = harfara_layout_with(ctx, harfara_str, (int)strlen(harfara_str),
		HARFARA_LTR, fs, 32.0, &vopts, err, sizeof(err));
	CHECK(vline != 0, "vertical line laid out");
	if (vline) {
		int vn = harfara_line_glyph_count(vline);
		printf("vertical glyphs: %d column height: %.2f\n", vn,
			harfara_line_column_height(vline));
		CHECK(vn == 5, "vertical glyph count");
		double vy = 0.0;
		double vwidth = harfara_line_width(vline);
		for (int i = 0; i < vn; i++) {
			harfara_glyph_t g;
			CHECK(harfara_line_glyph(vline, i, &g), "vertical glyph readable");
			CHECK(g.x == (vwidth - g.advance) / 2.0, "vertical glyph centered in column");
			CHECK(g.y == vy, "vertical pen accumulates");
			vy += g.advance;
		}
		CHECK(harfara_line_column_height(vline) == vy, "column height is the pen");
		CHECK(harfara_line_width(vline) > 0.0, "column has width");
		harfara_line_free(vline);
	}

	/* The 8.4 fields through the C struct: wrap_mode arrives as laid out —
	 * a drifted trailing field would wrap as word mode. Char mode splits
	 * the single word "Hello" at 20px; word mode lets it overflow whole. */
	harfara_options_t wopts;
	memset(&wopts, 0, sizeof(wopts));
	wopts.wrap_mode = 1;
	err[0] = 0;
	harfara_wrap_t *wwrap = harfara_wrap_with(ctx, harfara_str, (int)strlen(harfara_str),
		HARFARA_LTR, fs, 32.0, 20.0, &wopts, err, sizeof(err));
	CHECK(wwrap != 0, "char-mode wrap laid out");
	if (wwrap) {
		int wlines = harfara_wrap_line_count(wwrap);
		printf("char-mode lines at 20px: %d\n", wlines);
		CHECK(wlines > 1, "char mode splits inside the word");
		harfara_wrap_free(wwrap);
	}
	harfara_options_t wopts0;
	memset(&wopts0, 0, sizeof(wopts0));
	err[0] = 0;
	harfara_wrap_t *wwrap0 = harfara_wrap_with(ctx, harfara_str, (int)strlen(harfara_str),
		HARFARA_LTR, fs, 32.0, 20.0, &wopts0, err, sizeof(err));
	CHECK(wwrap0 != 0, "word-mode wrap laid out");
	if (wwrap0) {
		CHECK(harfara_wrap_line_count(wwrap0) == 1, "word mode lets it overflow whole");
		harfara_wrap_free(wwrap0);
	}

	/* Tab stops through the C struct: the stops array arrives as laid out,
	 * and b starts at the 40 stop. A drifted pointer or count would leave
	 * the tab at its font advance. */
	double stops[2] = {40.0, 80.0};
	harfara_options_t topts;
	memset(&topts, 0, sizeof(topts));
	topts.tab_stops = stops;
	topts.num_tab_stops = 2;
	err[0] = 0;
	harfara_line_t *tline = harfara_layout_with(ctx, "a\tb", 3,
		HARFARA_LTR, fs, 32.0, &topts, err, sizeof(err));
	CHECK(tline != 0, "tab-stop line laid out");
	if (tline) {
		CHECK(harfara_line_glyph_count(tline) == 3, "tab-stop glyph count");
		harfara_glyph_t tg, tb;
		CHECK(harfara_line_glyph(tline, 1, &tg), "tab glyph readable");
		CHECK(harfara_line_glyph(tline, 2, &tb), "b glyph readable");
		printf("tab advance: %.2f b at %.2f width %.2f\n", tg.advance, tb.x,
			harfara_line_width(tline));
		CHECK(tb.x > 39.99 && tb.x < 40.01, "b starts at the stop");
		harfara_line_free(tline);
	}

	/* Wrap at a narrow width: more than one line, covering the whole text. */
	err[0] = 0;
	harfara_wrap_t *w = harfara_wrap(ctx, text, (int)strlen(text), HARFARA_AUTO, fs, 32.0, 100.0,
		err, sizeof(err));
	CHECK(w != 0, "paragraph wrapped");
	int lines = harfara_wrap_line_count(w);
	printf("wrapped lines at 100px: %d\n", lines);
	CHECK(lines >= 1, "at least one line");
	int covered = 0;
	for (int i = 0; i < lines; i++) {
		harfara_line_t *l = harfara_wrap_line(w, i);
		CHECK(l != 0, "wrap line readable");
		covered += harfara_wrap_line_to(w, i) - harfara_wrap_line_from(w, i);
		printf("  line %d: chars [%d,%d) width %.2f\n", i,
			harfara_wrap_line_from(w, i), harfara_wrap_line_to(w, i), harfara_line_width(l));
	}
	CHECK(covered == 10, "lines cover the whole text");

	/* Measure without drawing anything. */
	harfara_metrics_t m;
	err[0] = 0;
	CHECK(harfara_measure(ctx, text, (int)strlen(text), HARFARA_AUTO, fs, 32.0, &m, err, sizeof(err)),
		"paragraph measured");
	printf("min=%.2f max=%.2f line_height=%.2f\n",
		m.min_content_width, m.max_content_width, m.line_height);
	CHECK(m.max_content_width > 0.0, "max width positive");
	CHECK(m.min_content_width <= m.max_content_width, "min within max");

	/* Breaks on plain ASCII. */
	const char *words = "one two";
	err[0] = 0;
	harfara_breaks_t *b = harfara_breaks(ctx, words, (int)strlen(words), 1, err, sizeof(err));
	CHECK(b != 0, "breaks reported");
	printf("breaks:");
	for (int i = 0; i < b->len; i++) {
		printf(" %d%s", b->starts[i], b->mandatory[i] ? "!" : "");
	}
	printf("\n");
	CHECK(b->len == 2, "space plus end");
	harfara_breaks_free(b);

	/* Rasterize the first non-mark glyph with its own font. */
	for (int i = 0; i < n; i++) {
		harfara_glyph_t g;
		harfara_line_glyph(line, i, &g);
		if (g.is_mark) {
			continue;
		}
		harfara_font_t *gf = harfara_line_glyph_font(line, i);
		err[0] = 0;
		harfara_bitmap_t *bm = harfara_rasterize(gf, g.gid, 32.0, 0, 0, err, sizeof(err));
		CHECK(bm != 0, "glyph rasterized");
		printf("bitmap: %dx%d at (%d,%d)%s\n", harfara_bitmap_width(bm),
			harfara_bitmap_height(bm), harfara_bitmap_left(bm), harfara_bitmap_top(bm),
			harfara_bitmap_data(bm) ? "" : " (empty)");
		CHECK(harfara_bitmap_data(bm) != 0, "bitmap has ink");
		harfara_bitmap_free(bm);
		break;
	}

	/* Subset: keep one glyph, reload from the bytes, release everything. */
	err[0] = 0;
	unsigned short seed[1];
	seed[0] = harfara_font_glyph_index(font, 'H');
	unsigned char *sub = 0;
	int sublen = harfara_subset(font, seed, 1, &sub, err, sizeof(err));
	CHECK(sublen > 0 && sub != 0, "subset built");
	err[0] = 0;
	harfara_font_t *font2 = harfara_font_load_bytes(sub, sublen, err, sizeof(err));
	CHECK(font2 != 0, "subset reloads");
	if (font2) {
		CHECK(harfara_font_glyph_index(font2, 'H') == seed[0], "subset keeps the seed id");
		harfara_font_free(font2);
	}
	harfara_subset_free(sub);
	harfara_subset_free(0);

	/* Error path: a font that is not there. */
	err[0] = 0;
	CHECK(harfara_font_load_file("no-such-font.ttf", err, sizeof(err)) == 0,
		"missing font refused");
	CHECK(err[0] != 0, "error recorded");
	printf("error string: %s\n", err[0] ? err : "(none)");

	harfara_wrap_free(w);
	harfara_line_free(line);
	harfara_fontset_free(fs);
	harfara_font_free(font);
	harfara_context_free(ctx);

	if (fails == 0) {
		printf("SMOKE OK\n");
	}
	return fails ? 1 : 0;
}
