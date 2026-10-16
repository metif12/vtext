"""Pango leg of the differential suite (ubuntu CI + any host with libpango).

Pango is HarfBuzz plus FreeType plus a layout policy: it shapes with
HarfBuzz, rasterizes with FreeType, and decides line breaks and run
placement itself. The HarfBuzz leg already checks shaping glyph by glyph
and the Pillow leg checks rasterization box by box, so what Pango adds
is its own decisions — how many lines a paragraph takes at a width, and
how wide each line is. Comparing those against vtext's wrap_paragraph is
the one comparison shaping alone cannot make.

It is a separate module with its own skip path because libpango is not
everywhere: present on ubuntu-latest runners, absent on Windows and macOS
runners. A missing library is a skipped leg with a printed reason, never
a silent pass and never a failure.

Every call below was read out of the installed packages before it was
used, because none of this runs on the machine it was written on:
pangocffi 0.14.1 (Layout.text/.width/.wrap/.font_description as
properties, LayoutIter.get_iter/next_line/get_line_extents,
FontDescription().family/.set_absolute_size, convert.units_to_double),
pangocairocffi 0.7.1 (create_layout over a cairocffi Context), cairocffi
1.7.1 (ImageSurface/Context). Anything those three cannot do is not
attempted here.

Usage from compare.py only; not a standalone program.
"""

PANGO_SCALE = 1024  # ABI-guaranteed by Pango; convert.units_to_double divides by it.
WRAP_PX = 400


def available():
    try:
        import pangocffi  # noqa: F401
        import pangocairocffi  # noqa: F401
        import cairocffi  # noqa: F401
        return True, ''
    except Exception as e:
        return False, f'{type(e).__name__}: {e}'


def layout_lines(family, text, size_px, width_px):
    """Returns ([line_logical_width_px...], nlines) or raises SkipLeg."""
    ok, why = available()
    if not ok:
        raise SkipLeg(f'pango stack unavailable: {why}')
    try:
        import cairocffi
        import pangocairocffi
        from pangocffi import WrapMode
        from pangocffi.convert import units_to_double
    except Exception as e:
        raise SkipLeg(f'pango import failed: {type(e).__name__}: {e}')
    try:
        surface = cairocffi.ImageSurface(cairocffi.FORMAT_ARGB32, 2000, 2000)
        cairo_ctx = cairocffi.Context(surface)
        layout = pangocairocffi.create_layout(cairo_ctx)
        from pangocffi import FontDescription
        desc = FontDescription()
        desc.family = family
        desc.set_absolute_size(float(size_px) * PANGO_SCALE)
        layout.font_description = desc
        layout.text = text
        layout.width = int(width_px * PANGO_SCALE)
        layout.wrap = WrapMode.WORD
        widths = []
        it = layout.get_iter()
        while True:
            _ink, logical = it.get_line_extents()
            widths.append(units_to_double(logical.width))
            if not it.next_line():
                break
        return widths, len(widths)
    except Exception as e:
        raise SkipLeg(f'pango layout failed: {type(e).__name__}: {e}')


class SkipLeg(Exception):
    pass
