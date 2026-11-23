/* harfara.h — the C API of the harfara text shaping library.
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
#ifndef HARFARA_H
#define HARFARA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Direction of a paragraph: 0 is left-to-right, 1 is right-to-left, and 2
 * takes the direction from the first strong character. */
#define HARFARA_LTR  0
#define HARFARA_RTL  1
#define HARFARA_AUTO 2

typedef struct harfara_context harfara_context_t;
typedef struct harfara_fontset harfara_fontset_t;
typedef struct harfara_font harfara_font_t;
typedef struct harfara_line harfara_line_t;
typedef struct harfara_wrap harfara_wrap_t;
typedef struct harfara_bitmap harfara_bitmap_t;

/* Layout options, mirroring LayoutOptions. features is a comma-separated
 * list of discretionary OpenType features and may be NULL. calt, liga and
 * clig are on by default; "-tag" turns one off and "+tag" names one
 * explicitly. line_height of 0 takes the font's own. vertical is 0 for a
 * horizontal line and nonzero for one column of vertical text. script and
 * language are the OpenType tags the run resolves its features under, each
 * NULL or empty for the default, spelt the way the font spells them
 * ('arab', 'URD'). align is 0 left, 1 center, 2 right, 3 justify; anything
 * else is left. align_width is the target width align resolves against for
 * a single line (wrapped lines use the wrap width); 0 is the line's own.
 * wrap_mode is 0 word, 1 char, 2 word_char; anything else is word.
 * tab_stops points at num_tab_stops doubles (NULL or a non-positive count
 * means none); the values are copied, so the caller keeps its array.
 * New fields are appended at the end, so the offsets of every field above
 * never move. */
typedef struct {
	const char *features;
	double line_height;
	double letter_spacing;
	double word_spacing;
	int vertical;
	const char *script;
	const char *language;
	int align;
	double align_width;
	int wrap_mode;
	const double *tab_stops;
	int num_tab_stops;
} harfara_options_t;

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
} harfara_glyph_t;

/* What a measurement reports: the narrowest width without a glyph breaking
 * out, the widest with no break taken, and the ink extent with the resolved
 * line height, all in pixels. */
typedef struct {
	double min_content_width;
	double max_content_width;
	double ascent;
	double descent;
	double line_height;
} harfara_metrics_t;

/* One break query: len parallel entries of starts and whether each is
 * mandatory. Freed together with harfara_breaks_free. */
typedef struct {
	int *starts;
	int *mandatory;
	int len;
} harfara_breaks_t;

const char *harfara_version(void);

harfara_context_t *harfara_context_new(void);
void harfara_context_free(harfara_context_t *ctx);

harfara_font_t *harfara_font_load_file(const char *path, char *err, int errcap);
harfara_font_t *harfara_font_load_bytes(const unsigned char *data, int len, char *err, int errcap);
void harfara_font_free(harfara_font_t *font);

harfara_fontset_t *harfara_fontset_new(void);
harfara_fontset_t *harfara_fontset_new_script(harfara_font_t *primary, harfara_font_t *general,
	char *err, int errcap);
void harfara_fontset_free(harfara_fontset_t *fs);
/* Returns 1 on success, 0 with the reason in err. The set borrows the font. */
int harfara_fontset_add(harfara_fontset_t *fs, harfara_font_t *font, char *err, int errcap);
/* Loads and appends in one call; the set borrows the returned font. */
harfara_font_t *harfara_fontset_add_file(harfara_fontset_t *fs, const char *path, char *err, int errcap);

int harfara_font_units_per_em(harfara_font_t *font);
double harfara_font_ascent(harfara_font_t *font, double em_px);
double harfara_font_descent(harfara_font_t *font, double em_px);
double harfara_font_line_height(harfara_font_t *font, double em_px);
int harfara_font_is_monospace(harfara_font_t *font);
uint16_t harfara_font_glyph_index(harfara_font_t *font, uint32_t cp);
int harfara_font_has_glyph(harfara_font_t *font, uint32_t cp);

harfara_line_t *harfara_layout(harfara_context_t *ctx, const char *text, int len, int dir,
	harfara_fontset_t *fs, double em_px, char *err, int errcap);
harfara_line_t *harfara_layout_with(harfara_context_t *ctx, const char *text, int len, int dir,
	harfara_fontset_t *fs, double em_px, const harfara_options_t *opts, char *err, int errcap);
void harfara_line_free(harfara_line_t *line);
int harfara_line_glyph_count(harfara_line_t *line);
/* Returns 1 and fills out, or 0 when i is out of range. */
int harfara_line_glyph(harfara_line_t *line, int i, harfara_glyph_t *out);
/* Borrowed from the caller's set; needed to rasterize the glyph. */
harfara_font_t *harfara_line_glyph_font(harfara_line_t *line, int i);
double harfara_line_width(harfara_line_t *line);
double harfara_line_ascent(harfara_line_t *line);
double harfara_line_descent(harfara_line_t *line);
double harfara_line_height(harfara_line_t *line);
double harfara_line_column_height(harfara_line_t *line);

harfara_wrap_t *harfara_wrap(harfara_context_t *ctx, const char *text, int len, int dir,
	harfara_fontset_t *fs, double em_px, double max_width, char *err, int errcap);
harfara_wrap_t *harfara_wrap_with(harfara_context_t *ctx, const char *text, int len, int dir,
	harfara_fontset_t *fs, double em_px, double max_width, const harfara_options_t *opts,
	char *err, int errcap);
void harfara_wrap_free(harfara_wrap_t *w);
int harfara_wrap_line_count(harfara_wrap_t *w);
/* Borrowed from the wrap; valid until harfara_wrap_free. */
harfara_line_t *harfara_wrap_line(harfara_wrap_t *w, int i);
/* Half-open range of input characters the line covers. */
int harfara_wrap_line_from(harfara_wrap_t *w, int i);
int harfara_wrap_line_to(harfara_wrap_t *w, int i);

/* Returns 1 and fills out, or 0 with the reason in err. */
int harfara_measure(harfara_context_t *ctx, const char *text, int len, int dir,
	harfara_fontset_t *fs, double em_px, harfara_metrics_t *out, char *err, int errcap);
int harfara_measure_with(harfara_context_t *ctx, const char *text, int len, int dir,
	harfara_fontset_t *fs, double em_px, const harfara_options_t *opts, harfara_metrics_t *out,
	char *err, int errcap);

/* mandatory_first decides whether breaks carry the mandatory flag; the
 * positions are the same either way. Null with the reason in err only when
 * the context is missing; empty text is an empty answer, not an error. */
harfara_breaks_t *harfara_breaks(harfara_context_t *ctx, const char *text, int len,
	int mandatory_first, char *err, int errcap);
void harfara_breaks_free(harfara_breaks_t *b);

harfara_bitmap_t *harfara_rasterize(harfara_font_t *font, uint16_t gid, double em_px,
	int sub_x, int sub_y, char *err, int errcap);
void harfara_bitmap_free(harfara_bitmap_t *bm);
int harfara_bitmap_width(harfara_bitmap_t *bm);
int harfara_bitmap_height(harfara_bitmap_t *bm);
int harfara_bitmap_left(harfara_bitmap_t *bm);
int harfara_bitmap_top(harfara_bitmap_t *bm);
/* Row-major coverage, width*height bytes, borrowed from the bitmap. */
const unsigned char *harfara_bitmap_data(harfara_bitmap_t *bm);

/* Rebuild the font around the seed glyphs. Returns malloc'd bytes and their
 * count, or -1 on error with errno-style text in err. .notdef is always kept.
 * The bytes load with harfara_font_load_bytes; harfara_subset_free releases them. */
int harfara_subset(harfara_font_t *font, const unsigned short *seed, int nseed,
	unsigned char **out, char *err, int errcap);
void harfara_subset_free(unsigned char *bytes);

#ifdef __cplusplus
}
#endif

#endif
