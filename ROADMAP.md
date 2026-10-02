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
| GPOS: single positioning (format 1) | done |
| GPOS: chaining-context positioning, format 3 | read and applied |
| GPOS: cursive attachment, format 1 and 2 | read; the attachment itself is not written |
| Line breaking (UAX #14) | partial: no dictionary, strict level, or CJK |

Eighteen test files, all passing, reading real fonts from the system. The cursive reader is the one
piece with no font to test it against, so its tables are built from words in `gpos_cursive_test.v`
rather than opened from disk.

## Phase 1: the engine's remaining gaps

These are the things a caller would hit and find missing. Each one is a
correctness question, not a feature, and none of them is large.

### ~~Line breaking (UAX #14)~~

**Done.** `break_opportunities` reports where a line may end, and `wrap_paragraph` measures the
shaped paragraph once and cuts it into lines that fit. It is separate from `layout_paragraph` because a
line has to be measured before it can be broken, and laying out the whole paragraph once is what
makes a narrower width affordable to try.

Three rules a caller would otherwise get wrong are handled there: a space is never left at the end of
a line, a word wider than the margin goes on a line of its own rather than being split, and a
newline ends the paragraph whatever the width is.

The rules that are not implemented are the ones that need a resolved line-break level and a
dictionary: LB15a and LB16a for a non-standard level, LB16b and LB17b for dictionary segmentation,
and the CJK-specific rules LB27 and LB31. None of them affect Arabic or Persian text, which is why
they are not there.

### ~~Chaining-context positioning (GPOS type 8)~~

**Parsed, format 3, and applied.** `apply_contextual` walks a glyph run and returns what each matched
rule asks for, and `context_placement` answers a pair from one. Counted against fontTools on the same
fonts, the parse agrees exactly: Tahoma 229 rules over 32 lookups, Simplified Arabic 15 over 11,
Majalla 71 over 27, Calibri 69 over 69.

The rules under `mark` are unreachable, and the reason is worth more than the rule engine. Tahoma names
208 glyphs across its patterns and this engine produces one of them. The patterns name glyphs 3426
through 3440, which GSUB lookup 55 makes from the Persian digits — and no feature in the font names
lookup 55. It is a dead lookup, so those glyphs cannot exist however the text is shaped, and the rules
that want them cannot fire in any engine. The same is true of glyph 1499, which no lookup and no
codepoint produces at all.

That is a font bug rather than a gap here, and it is worth knowing because it means the 229 rules are
not 229 rules that are being missed. The rules under `kern` are a different matter and do fire.

### ~~Context-sensitive kerning~~

**Done.** `context_placement` takes a shaped run and two indices into it, and answers the pair from
either a plain pair rule or a rule that matches around it. A font may put both under one feature and the
caller does not have to know which lookup a given pair lives in.

This is where the chaining rules turn out to matter after all, under `kern` rather than `mark`. Ten of
Tahoma's are under kern, 17 of Segoe UI's, 10 in Arial and Times, 6 in Traditional Arabic, 11 in
Simplified Arabic, 22 in Majalla, 8 in Andalus and 26 in Calibri. Asked about the runs they were written
for, 28 of them answer.

Two things had to be right, and both were found by reading a font's own bytes rather than the
specification:

A rule under kern usually names a single positioning rather than a pair. Of the records a kern feature
reaches across these fonts, 186 name a single and 12 name a pair. Andalus's first rule is "if one of
glyphs 160 through 167 comes before glyph 3, apply lookup 21", and lookup 21 covers glyph 3 with an
xPlacement of -120: it moves the second letter because of what came before the first.

And a rule with a backtrack is about one glyph with a condition. Its pattern names the glyph being
placed and reaches back to what makes it different, so the pair a caller names is a glyph and its
context rather than two the pattern both names.

SinglePos format 1 has no count of its values, because the coverage already says how many there are.
Reading the first value as a count turns -120 into 65416 and walks off the end of the table. The pair
tables beside it in the same table do have a count, which is what makes the two easy to confuse.

### ~~SinglePos format 2~~

**Not done, and nothing here uses it.** Format 2 has one value for a whole coverage and a second array
naming the glyphs that want something else, each by its coverage index. No font on this machine uses it,
and reading it as format 1 takes the valueCount as a count and then reads coverage indices as records,
which is worse than refusing it.

### ~~Cursive attachment: what it actually needs~~

**The premise was wrong, and it is worth writing down how.** I had recorded that Traditional Arabic
carries 7 cursive lookups, Simplified Arabic 57 and Majalla 54, and that this is what makes a cursive
script look cursive. Those counts are GPOS lookup type 1, and lookup type 1 is two tables under one
number: a single positioning and a cursive attachment. All of them are single positionings. The same
mistake twice in one session, after the compiler bug: a number counted, then given a meaning it did
not have.

Counting properly means unwrapping extensions first, because a font that reaches its positioning
through an extension stores the real type in the extension header. Walking every font on this machine
that way finds no cursive attachment at all. The one `curs` feature, in Dubai, names an extension whose
header says type 3 — a mark attachment — and fontTools calls that subtable a CursivePos because it
reads the bytes' shape rather than the header that names the type. Its mark array offset happens to land
on something shaped like an anchor, which is how one table looks like the other.

So Arabic joining in these fonts is entirely GSUB substitution, which this engine already does. What
remains is the reader, and it is written:

- `Cursive` and `EntryExit` in `gpos.v`, in both formats, with a record found through the coverage.
- A refusal that matters. A single positioning's valueFormat sits exactly where a cursive rule's first
  anchor offset sits, and 3 is a valid anchor format, so reading anchors first takes real kerning rules
  out of the font — it did, and the kerning tests failed. The test now fixes that shape as bytes.
- The guard is structural rather than lucky: in a cursive rule the anchors are a table after the
  records, so every offset points past the records, while a value format is a bitmask of a few hundred
  and cannot point past a value array that is already there.
- What is still missing is the attachment itself, which is not a positioning rule but a change to
  advance: the pen carries from one glyph's exit anchor to the next glyph's entry anchor, so a letter
  can end up wider or narrower than its advance says. That needs a font with a cursive attachment to be
  worth writing, and there is none here.

### Cursive attachment: the attachment itself

The reader for a cursive rule is done. The attachment is not, and it is not a positioning rule: the
pen carries from one glyph's exit anchor to the next glyph's entry anchor, so a letter can end up wider
or narrower than its advance says, and the whole line has to be placed in two passes rather than one.
It needs a font that has a cursive attachment to be measured against, and none of the fonts on this
machine has one. Bringing one in — Amiri or Scheherazade, or a Nastaliq face — is the first thing this
needs, and it is a question about which fonts the library is expected to open rather than about OpenType.

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

### ~~`examples/hello`~~

**Done**, as a file rather than a window. `v run .` in that directory writes `hello.png` and prints
its path. Three lines go through the whole pipeline in one call: Latin with an `ffi` ligature, an
Arabic word, and an English line with one Arabic word in it so bidirectional reordering has to do
something. The canvas is sized from the lines the engine lays out rather than written down, because a
fixed height crops the last line the moment the text changes.

No window, deliberately. A window needs a graphics binding, and a binding is a dependency that has
nothing to do with the text engine, so the part that shows the engine works is the part that writes a
file. The PNG is written by hand out of `compress/zlib` and `hash/crc32` from the standard library, so
the example depends on nothing but vtext.

Writing it turned up two things worth knowing, both found by looking at the picture rather than at a
passing test:

A V string is a byte array, so `for r in text` over "مرحبا" yields the UTF-8 bytes `D9 85` as two
separate runes and the text draws as `Ø` and friends. `.runes()` decodes it. Nothing in the engine
notices, because by the time it is called the text is already nonsense.

And `rasterize`'s subpixel offset is in quarters of a pixel, not the sixtieths stb_truetype takes, so
a glyph placed at x of 17.39 wants `sub_x` of 2 and not 25. Sixty-fourths read as quarters is sixteen
times too far and every glyph lands up to sixteen pixels from where the layout put it. That one is now
written on the function, since an argument that is too large does not look like a wrong argument.

The original version of this example reached composition and timing work and stopped at the window
binding; those files are not recoverable, so this is a rewrite rather than a restoration.

### ~~`examples/rtl_line`~~

**Done.** `v run .` writes `rtl_line.png`; `v run . -debug` writes the same line with a box around every
glyph and its cluster index under it.

A right-to-left line drawn at 44 pixels, with a mark on every letter and a lam-alef in the middle, plus a
Latin line above it so one FontSet and one call cover both directions. What to read off the debug
picture:

- The Latin line's cluster indexes ascend from 0 and the Arabic line's descend from 21 to 0, which is
  the whole of bidirectional reordering visible in one glance. A line where they ascend on both is laid
  out left to right twice.
- A mark has no advance and shares its letter's x, so it has no box. Two boxes on one letter would mean
  a mark had been given an advance it should not have.
- The `ffi` ligature is one glyph with one box and three clusters, because the font says those three
  characters are one thing and the cluster is what a caret position would use to get back to the text.

Two things about the drawing rather than the engine, both of which look like engine bugs until measured:
the cluster numbers are laid out with their own hand-drawn digits, because a debug number that fights the
text is worse than a crude one; and they read left to right in both directions, since a number reads that
way in every script. Drawing the digits backwards prints 12 as 21 on a mirrored line, which is exactly
the kind of thing this picture exists to make visible rather than to hide.

`paint.v` is a copy in each example rather than a shared module. A V program can only import a module on
its module path, and making every example depend on a sibling directory to save forty lines of zlib is a
worse trade than the forty lines. The two copies are kept identical.

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
