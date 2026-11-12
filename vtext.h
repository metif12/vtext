/* vtext.h — the C API of the vtext text shaping library.
 *
 * Opaque handles over the shaped objects, plain C types everywhere. A C
 * program links the shared library built from this tree (see USAGE.md) and
 * never lays out a V value itself.
 *
 * Ownership: anything returned as a pointer is owned by the caller and freed
 * with the matching free function, except where the name says borrowed.
 * Anything taken as a pointer is borrowed and must outlive the call.
 * Fallible functions take a caller-owned error buffer (err, errcap) and write
 * a sentence into it on failure; a null buffer or no room drops the sentence
 * rather than writing past the end.
 */
#ifndef VTEXT_H
#define VTEXT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Direction of a paragraph: 0 is left-to-right, 1 is right-to-left, and 2
 * takes the direction from the first strong character. */
#define VTEXT_LTR  0
#define VTEXT_RTL  1
#define VTEXT_AUTO 2

typedef struct vtext_context vtext_context_t;
typedef struct vtext_fontset vtext_fontset_t;
typedef struct vtext_font vtext_font_t;
typedef struct vtext_line vtext_line_t;
typedef struct vtext_wrap vtext_wrap_t;
typedef struct vtext_bitmap vtext_bitmap_t;

/* Layout options, mirroring LayoutOptions. features is a comma-separated
 * list of discretionary OpenType features (e.g. "liga") and may be NULL.
 * line_height of 0 takes the font's own. */
typedef struct {
	const char *features;
	double line_height;
	double letter_spacing;
	double word_spacing;
} vtext_options_t;

/* One drawable glyph: the gid to rasterize, the pen movement, the position
 * from the line's left edge in pixels, and the input character it came from.
 * is_mark is 1 for a combining mark, which shares its base's position. */
typedef struct {
	uint16_t gid;
	double advance;
	double x;
	double y;
	int cluster;
	int is_mark;
} vtext_glyph_t;

/* What a measurement reports: the narrowest width without a glyph breaking
 * out, the widest with no break taken, and the ink extent with the resolved
 * line height, all in pixels. */
typedef struct {
	double min_content_width;
	double max_content_width;
	double ascent;
	double descent;
	double line_height;
} vtext_metrics_t;

/* One break query: len parallel entries of starts and whether each is
 * mandatory. Freed together with vtext_breaks_free. */
typedef struct {
	int *starts;
	int *mandatory;
	int len;
} vtext_breaks_t;

const char *vtext_version(void);

vtext_context_t *vtext_context_new(void);
void vtext_context_free(vtext_context_t *ctx);

vtext_font_t *vtext_font_load_file(const char *path, char *err, int errcap);
vtext_font_t *vtext_font_load_bytes(const unsigned char *data, int len, char *err, int errcap);
void vtext_font_free(vtext_font_t *font);

vtext_fontset_t *vtext_fontset_new(void);
vtext_fontset_t *vtext_fontset_new_script(vtext_font_t *primary, vtext_font_t *general,
	char *err, int errcap);
void vtext_fontset_free(vtext_fontset_t *fs);
/* Returns 1 on success, 0 with the reason in err. The set borrows the font. */
int vtext_fontset_add(vtext_fontset_t *fs, vtext_font_t *font, char *err, int errcap);
/* Loads and appends in one call; the set borrows the returned font. */
vtext_font_t *vtext_fontset_add_file(vtext_fontset_t *fs, const char *path, char *err, int errcap);

int vtext_font_units_per_em(vtext_font_t *font);
double vtext_font_ascent(vtext_font_t *font, double em_px);
double vtext_font_descent(vtext_font_t *font, double em_px);
double vtext_font_line_height(vtext_font_t *font, double em_px);
int vtext_font_is_monospace(vtext_font_t *font);
uint16_t vtext_font_glyph_index(vtext_font_t *font, uint32_t cp);
int vtext_font_has_glyph(vtext_font_t *font, uint32_t cp);

vtext_line_t *vtext_layout(vtext_context_t *ctx, const char *text, int len, int dir,
	vtext_fontset_t *fs, double em_px, char *err, int errcap);
vtext_line_t *vtext_layout_with(vtext_context_t *ctx, const char *text, int len, int dir,
	vtext_fontset_t *fs, double em_px, const vtext_options_t *opts, char *err, int errcap);
void vtext_line_free(vtext_line_t *line);
int vtext_line_glyph_count(vtext_line_t *line);
/* Returns 1 and fills out, or 0 when i is out of range. */
int vtext_line_glyph(vtext_line_t *line, int i, vtext_glyph_t *out);
/* Borrowed from the caller's set; needed to rasterize the glyph. */
vtext_font_t *vtext_line_glyph_font(vtext_line_t *line, int i);
double vtext_line_width(vtext_line_t *line);
double vtext_line_ascent(vtext_line_t *line);
double vtext_line_descent(vtext_line_t *line);
double vtext_line_height(vtext_line_t *line);

vtext_wrap_t *vtext_wrap(vtext_context_t *ctx, const char *text, int len, int dir,
	vtext_fontset_t *fs, double em_px, double max_width, char *err, int errcap);
vtext_wrap_t *vtext_wrap_with(vtext_context_t *ctx, const char *text, int len, int dir,
	vtext_fontset_t *fs, double em_px, double max_width, const vtext_options_t *opts,
	char *err, int errcap);
void vtext_wrap_free(vtext_wrap_t *w);
int vtext_wrap_line_count(vtext_wrap_t *w);
/* Borrowed from the wrap; valid until vtext_wrap_free. */
vtext_line_t *vtext_wrap_line(vtext_wrap_t *w, int i);
/* Half-open range of input characters the line covers. */
int vtext_wrap_line_from(vtext_wrap_t *w, int i);
int vtext_wrap_line_to(vtext_wrap_t *w, int i);

/* Returns 1 and fills out, or 0 with the reason in err. */
int vtext_measure(vtext_context_t *ctx, const char *text, int len, int dir,
	vtext_fontset_t *fs, double em_px, vtext_metrics_t *out, char *err, int errcap);
int vtext_measure_with(vtext_context_t *ctx, const char *text, int len, int dir,
	vtext_fontset_t *fs, double em_px, const vtext_options_t *opts, vtext_metrics_t *out,
	char *err, int errcap);

/* mandatory_first decides whether breaks carry the mandatory flag; the
 * positions are the same either way. Null with the reason in err only when
 * the context is missing; empty text is an empty answer, not an error. */
vtext_breaks_t *vtext_breaks(vtext_context_t *ctx, const char *text, int len,
	int mandatory_first, char *err, int errcap);
void vtext_breaks_free(vtext_breaks_t *b);

vtext_bitmap_t *vtext_rasterize(vtext_font_t *font, uint16_t gid, double em_px,
	int sub_x, int sub_y, char *err, int errcap);
void vtext_bitmap_free(vtext_bitmap_t *bm);
int vtext_bitmap_width(vtext_bitmap_t *bm);
int vtext_bitmap_height(vtext_bitmap_t *bm);
int vtext_bitmap_left(vtext_bitmap_t *bm);
int vtext_bitmap_top(vtext_bitmap_t *bm);
/* Row-major coverage, width*height bytes, borrowed from the bitmap. */
const unsigned char *vtext_bitmap_data(vtext_bitmap_t *bm);

#ifdef __cplusplus
}
#endif

#endif
