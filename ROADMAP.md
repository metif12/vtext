# Roadmap

Where this library is, what is left in the engine, and what comes after it.

The order matters. Examples come late on purpose: an example is a claim that a
capability works, and building one before the capability does just produces
something that has to be rewritten. Tools come last of all, because a tool is a
program built out of the examples, and a tool written against an API that is
still moving is work thrown away.

## Where this is

The shaping engine is done for Arabic and Persian, and for the Latin text that
comes with them.

| Stage | State |
| --- | --- |
| SFNT and TTC containers, table directory | done |
| cmap formats 0, 4, 6, 12 | done |
| Metrics, underline placement, rasterization | done |
| Unicode normalization (UAX #15) | done |
| Bidirectional paragraphs (UAX #9) | done |
| Arabic joining (UAX #53) | done |
| Grapheme clusters (UAX #29) | done |
| Font fallback chains | done |
| GSUB: single, multiple, alternate, ligature, contextual | done |
| GPOS: mark-to-base, mark-to-ligature, mark-to-mark | done |
| GPOS: pair adjustment (kerning) | done |

Fourteen test files, all passing, reading real fonts from the system.

## Phase 1: the engine's remaining gaps

These are the things a caller would hit and find missing. Each one is a
correctness question, not a feature, and none of them is large.

### Line breaking (UAX #14)

The class data is already in `properties.v`. What is missing is the rule
engine, and the hard part is not the rules themselves: it is that a line must
be measured before it is broken, so breaking has to come after layout and
interact with it. A break opportunity that is chosen before the glyphs have
widths is chosen wrongly for a line whose last word does not fit.

The API should be a break function over a shaped paragraph, not inside
`layout_paragraph`, because the caller owns the width and the caller may be
drawing to something that scrolls rather than to a page.

### Contextual positioning (GPOS types 5 and 6)

Chaining-context lookups. A font uses them to move a glyph based on what is
around it, which is how a script with stacked forms places the forms. The
engine already parses chaining contexts for GSUB, so the shape of the code is
known; it is the same walk with a positioning action at the end.

### Device and variation tables

A GPOS value record can point at a table that says the value is different at a
different size. Skipping it means a kern is the same at every size, which is
wrong but not visibly so. Reading it is a matter of applying a table of
adjustments by pixels-per-em, and a variable font's version needs the variation
store.

### Vertical text

The metrics are there. Everything else is not: the vertical origin, the writing
mode, and the substitution of vertical forms. No Arabic or Persian need, and
worth doing only if CJK is.

## Phase 2: reach

The engine works; whether anyone can find it does not.

### Language and platform coverage

The tests read fonts from `C:\Windows\Fonts`, so they only run on this machine.
Shipping means a test corpus in the repository and a way to run the same checks
on Linux and macOS. This comes before anything else in this phase, because
every claim made after it is a claim about a platform nobody has run.

### The public API, settled

`LayoutOptions` is one field. It should be the place a caller reaches for
everything that is a choice rather than a fact: line height, alignment, the
fallback order, the feature set, the direction when the text does not imply
one. A caller should be able to do everything the library can do through it,
and nothing should need a separate function that only works for one script.

### Documentation

The README covers the pipeline and the API. What is missing is the part a
reader needs before the API: what the library guarantees, what it refuses to
guess, and what a caller has to decide that the library cannot decide for them.

## Phase 3: examples

Each example demonstrates one capability, is small enough to read in one
sitting, and runs with one command. An example that needs three arguments and a
config file is a tool.

### `examples/hello`

Shape a string, draw it, quit. The starting point, and the one that proves the
whole pipeline end to end: text in, positioned glyphs on a window. It is
currently being rewritten; the version in the repository history reached the
composition and timing work and stopped at the window binding.

### `examples/rtl_line`

A right-to-left paragraph with a mark on every letter and a ligature in the
middle, drawn large, with a debug mode that draws each glyph's box and its
cluster index. The example that makes the engine's output checkable by eye, and
the one to look at first when something is placed wrong.

### `examples/mark_stack`

One letter with a fatha, a shadda and a kasra, next to the same three marks on
a lam-alef, next to the same three on a letter in a font with no mark-to-mark
rules. Shows what mark attachment does and what happens without it, which is
the clearest way to see why the feature exists.

### `examples/kerning`

A word in a font with kerning next to the same word in one without, and a
debug overlay that draws each glyph's advance so the gap between two letters is
visible rather than asserted.

### `examples/fallback`

One paragraph in a script the first font has no glyphs for, with the second
font in the chain doing the work. Shows the chain from the only angle that
matters, which is what the reader actually sees.

### `examples/bidi`

A paragraph mixing Arabic, Latin and digits, showing the reordering with the
logical order printed underneath. The example for the case that is hardest to
reason about and easiest to get wrong.

### `examples/features`

The same word drawn with the required features only, then with a discretionary
feature turned on, and the width of both printed. Shows what a feature does to
the text rather than to the code.

### `examples/line_break`

A paragraph that wraps, with the break opportunities marked, and a width slider
or a few fixed widths. Depends on phase 1.

### `examples/glyph_grid`

Every glyph in a font in a grid, with the codepoints that reach it. The
example that turns "the font has no glyph for this character" from a guess into
a fact, and the one to reach for when a shaping result looks wrong.

## Phase 4: tools

Programs for people using the library, built out of the examples. Each one
should be useful on its own without the library, and the library should be
something it happens to use.

### `tools/fontdump`

Print what a font actually contains: its tables, the scripts and features it
offers, how many glyphs each cmap subtable maps, whether it has mark
attachment, whether it kerns. The tool to reach for first, because most
shaping questions are answered by knowing what the font has, and half of the
bugs in this library were a font using a structure the library did not expect.

### `tools/shapetrace`

Print the pipeline for one string, step by step: what normalization did, what
bidi decided, which joining form each letter took, which substitution rule
fired and replaced what, which positioning rule answered and with what. Every
debugging session on this engine ended by writing a version of this and reading
it, so it should exist.

### `tools/fontcheck`

Validate a font against the library and report what it cannot use. Not
whether the font is valid: whether this library can shape with it, which is a
different question and the one that matters. A font whose GSUB references a
glyph its cmap never produces is valid and unusable, and that is a report
rather than a crash.

### `tools/metrics`

Report a font's metrics at a given size: ascent, descent, line height, the
advance of every glyph, and the side bearings. Useful on its own for anyone
laying out a page, and the tool that makes a wrong `hhea` table visible.

### `tools/glyphdump`

Write a font's glyphs to a directory of images, and a specimen sheet. The tool
for checking a rasterizer against a reference, and for seeing what a substitution
actually produced.

### `tools/subset`

Produce a smaller font holding only the glyphs a given text needs. The tool
that most affects what a caller can do with the library, and the one that
depends on the engine being right: a subsetter that keeps a glyph the shaping
pipeline needed and drops one it did not is worse than no subsetter at all.

## Explicitly not planned

Worth writing down so that these do not come back as questions.

- A text editor, or any interactive application. The library is a library.
- A layout engine for boxes, flex, or CSS. Line breaking is the most this needs
  and no further.
- HarfBuzz bindings, or a port of anything. The engine is written from the
  specifications.
- Variable font instancing. Reading the variation store is in phase 1 because
  the hints depend on it; generating new instances is not.
