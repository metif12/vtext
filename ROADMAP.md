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
| GPOS: pair adjustment (kerning) | done, both formats |
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

### ~~`examples/mark_stack`~~

**Done**, and the comparison is not what it was planned to be. `v run .` writes `mark_stack.png`: seven
rows, each drawn twice, once as the engine placed it and once with every offset discarded, with the
baseline ruled under both columns so "is this mark on the baseline or not" can be measured rather than
believed. A fatha sits 17 pixels higher in the first column than in the second, which is the feature
visible in one image.

The third column was meant to be a font with no mark-to-mark rules. No font on this machine is: of the
35 that cover beh, fatha, shadda, kasra, lam and alef, all 35 have a `mark` feature. So the row is a
single mark that the font has a glyph for and no rule for anywhere — U+0301 in Tahoma, which has anchors
for 53 combining marks and 168 it has glyphs for but no anchors. Both columns are identical there, which
is the correct answer to a font that has said nothing, and it makes the point better than a second font
would have: the difference between the columns is the font's anchors, not the engine.

Two things were wrong in the plan and in the first draft of the text:

A shadda and a fatha together become **one glyph by ligature substitution** in Tahoma, so the row written
to show mark-to-mark showed no mark-to-mark at all. One glyph and a y of 8.7 is the ligature firing and a
single placement, and it looks on the page like the row above it. The row that does show mark-to-mark is
shadda on a kasra, where the two stay separate: gid 2354 placed at y of 18.3 on top of gid 2353 at 2.8.

And the two columns first looked identical, which was me misreading a small picture rather than a bug.
Measured, the fatha's ink reaches 22 pixels above the baseline in the first column and 35 in the second.
The offsets are in `Glyph.y`, so clearing y is the whole of "not placed", and the engine stores a mark's
anchor result there: x at the base's x plus the anchor's, y at minus the anchor's, scaled to pixels.

### ~~`examples/kerning`~~

**Done.** `v run .` writes `kerning.png`: `AVAST To Yo WAY` at 90 pixels in Segoe UI and in Tahoma,
with the pen's position at every glyph ruled full height and every advance ruled at the foot.

The comparison is only honest because both fonts are real and the difference is the font's own decision.
Segoe UI has 8146 Latin kern pairs and Tahoma has none, which is not an accident: Tahoma has Arabic
kerning and no Latin kerning, and this engine has to respect that rather than treat an absent table as an
empty one it may fill in.

Measured, not eyeballed. Segoe UI kerns five of the fourteen pairs in the word, to −4.30 pixels at `To`,
and the sum of the advances equals the line's width exactly in both fonts, so the kerning is inside the
measurement rather than added to it afterwards.

This example is also where the previous entry's fix came from: reading it needed real kern pairs to
compare against, and asking Segoe UI for them produced none at all.

### ~~`examples/fallback`~~

**Done.** `v run .` writes `fallback.png`: three lines, every glyph underlined in the grey of the font it
came from, with the counts printed under each line.

A line drawn correctly looks exactly like a line drawn from one font, which is why the underlines are
there: the mechanism is only visible when the report of it is drawn next to the result.

The fonts are chosen to force the choice rather than avoid it. Consolas covers Latin, Greek and Cyrillic
and no Arabic at all; Traditional Arabic covers Arabic and little else. Neither covers Hebrew.

Measured: line one is 39 glyphs from Consolas and none from the second font. Line two is 29 and 7 — the
change is at the script, not at a word boundary, because the decision is per character. Line three is 31
from Consolas and 3 from neither, which are the three Hebrew letters.

The last row needed the right test. The engine does not return no font for a character nothing covers: it
returns the font it asked, with glyph index zero, because that is the font whose `.notdef` is being drawn.
So a first version that counted glyphs with no font reported zero missing on a line with three characters
that no font can draw. The test is the glyph index, and `.notdef` is drawn as the hollow box it is rather
than dropped — dropping it would move every glyph after it along, which changes the text instead of
showing that something was lost.

### ~~`examples/bidi`~~

**Done.** `v run .` writes `bidi.png`: four mixed-direction paragraphs, each printed with its resolved
levels, its visual order as the pen meets the characters, and the characters as they are drawn.

Four lines, each one a different decision:

- `The word سلام means peace.` is mostly Latin with one Arabic word in it. Nothing moves.
- `سلام The world` starts right to left, so the paragraph level is odd and the Latin moves to the left of
  the Arabic. A line like this drawn as if it were the first has the order of its halves swapped.
- `abc سلام 123 def` has a number between the scripts. Numbers are weak and take the direction of what
  surrounds them, so `123` comes out before the Arabic rather than after it.
- `۱۲۳ فارسی abc ۴۵۶` has two runs of Persian digits, and the visual order printed under it is the only
  honest way to read it.

The two printed orders are not redundant and their agreement is the check. `visual_order` names the
characters in the order the pen meets them, which for a right-to-left run is the reverse of the order
they were typed; the drawn glyphs are what a reader actually sees. Where the two differ, the difference
has a reason: in the first line `السلام` ligates, so `سلام` contributes three glyphs rather than four, and
the two orders are one character apart because of it. In the fourth line, which has no ligature, they are
identical.

Writing this turned up the difference between a visual order and a drawn line, which is easy to confuse
because both are "the order it comes out in". A glyph array is left to right with a right-to-left run
laid out backwards inside it, and the array order is the visual order; the readable reading is the
reverse. Confusing them made the first two lines look like bugs in the engine when they were neither.

### ~~`examples/features`~~

**Done.** `v run .` writes `features.png`: three words laid out twice, once with the required features
alone and once with one discretionary feature by name, with the pen ruled at every glyph and both widths
printed.

Two words because a feature does two different kinds of thing, and the second kind is the more common:

- `الله` goes from four glyphs to two under `liga` in every Arabic font on this machine — Segoe UI 90.84
  to 80.16 pixels, Tahoma 92.63 to 77.53. That is a count change: two of those letters have a shape that
  only exists as a pair.
- `فارسی` stays at five glyphs under `liga` in Segoe UI and the line gets 16 pixels narrower. That is a
  substitution that keeps the count: the same five letters, drawn differently, taking less room. It is
  easy to miss, because nothing about the number of glyphs moves.

The risk in this one was whether any feature on this machine changes anything measurable at all. It does,
in every Arabic font tested, so there was real material rather than a contrived case.

### ~~`examples/line_break`~~

**Done.** `v run .` writes `line_break.png`: one paragraph wrapped at 700, 400, 200 and 100 pixels as
four columns side by side, each with its margin ruled, and an Arabic paragraph underneath the second
column.

Measured rather than believed, and the ranges are the check that matters. At 400 the lines are
`[0..35]`, `[35..71]`, `[71..83]`: the paragraph accounted for three times over with no gap and no
overlap. A wrapper that loses a space between lines or reorders two is visible in the printed ranges and
nowhere else.

The overflow is the second thing worth reading. At 100 pixels three lines run past the margin, and the
printed widths say why: `quick brown` is 137, `jumps over` 124, `keeps on` 102. A line is not broken
inside a word, so a word that does not fit is overlong rather than hyphenated — a decision the caller
would have to make for itself and this engine will not make on their behalf.

The Arabic paragraph is what makes wrapping a problem rather than an exercise. A Latin paragraph breaks
at its spaces and that is all there is to it; Arabic has no spaces, so its breaks come from the UAX #14
rules and this engine's coverage of them is partial. It wraps by the same call and breaks where the rules
say, which is the honest statement of what that means today: five lines, none overlong at 220 pixels.

One API gap found here and worth recording: `break_opportunities` is public but returns
`[]BreakOpportunity`, which is private, so a caller outside the module cannot name the type it gets back
and cannot read a break's position or whether it is mandatory. `wrap_paragraph` is enough to wrap with,
but the ability to ask where a line may break is a question a caller has, and the answer is currently
unreachable from outside. This is the second such gap; the other is `Face`, `Gpos` and `Gsub`, which are
unreachable entirely.

Drawing it needed two things the earlier examples did not. A column has to be as wide as its own widest
line rather than the whole paragraph's, or every column is as wide as the widest and the four drawings
overlap. And a glyph's x within its line is added by `draw_glyph_at` already, so passing the column offset
plus the glyph position counts it twice.

### ~~`examples/glyph_grid`~~

**Done.** `v run .` writes `glyph_grid.png`: every glyph Consolas has, in a grid, at one of three greys
depending on how many scanned codepoints reach it.

The three greys answer the question this example exists for, which is whether an empty box means the cmap
does not name the character or the font has no glyph for it. Those are different faults and only one of
them is fixed by falling back to another font.

Measured on Consolas: 3031 glyphs, of which 2196 are reached by exactly one codepoint in U+0000 to
U+24FF, 40 are reached by more than one, and 795 by none. The 40 are invisible characters — U+0000 and
U+0008 both land on gid 1, U+0020 and U+00A0 both on gid 3 — and they are why a font can cover a character
and still not draw it. The 795 faint ones are box drawing, powerline and symbol glyphs, and they are real
ink the engine can draw and ordinary text cannot ask for.

Two things found while writing it, both about the compiler rather than the engine:

`m[k] or []T{}` compiles on a map whose values are strings and fails on one whose values are slices,
with the failure reported as an unexpected end of file at the end of the function rather than at the
expression. That is a real fault and it contradicts the compiler-bug section that was removed earlier on
the grounds that the shapes suspected then did not exist. Asking `if k in m` first compiles and reads no
worse.

And `none` is not available as a variable name. It reads as the option's empty value, so a counter called
`none` produces "non-name `none` on left side of `:=`" rather than anything that says the name is taken.

## Phase 4: tools

Programs for people using the library, built out of the examples. Each one
should be useful on its own without the library, and the library should be
something it happens to use.

### The inspection API

**Done**, in `inspect.v`. `fontdump`, `shapetrace` and `fontcheck` all need to ask a font questions that
no part of the shaping pipeline was written to answer, and all three were otherwise going to reach into
private state or re-parse the file themselves. The API is what they are written against.

```
Font.tables() []TableInfo          tag, offset, length, sorted
Font.has_table(tag) bool
Font.table_length(tag) int         zero when absent
Font.outlines() string             'glyf', 'CFF ', or ''
Font.num_lookups(table) int        the LookupList's own count
Font.features(table) []string      the FeatureList, sorted, deduplicated
Font.num_features(table) int
Font.scripts(table) []string       the ScriptList, sorted
Font.cmap_formats() []int
Font.cmap_counts() []int           mapped codepoints per subtable, notdef excluded
Font.glyph_class_counts() [5]int   in the order of glyph_class_names
Font.is_variable() bool
Font.variable_axes() []VariableAxis
```

Everything here is a report about a font the engine has already read. None of it changes what the engine
does, and none of it guesses. The distinction worth keeping is between a report and the engine acting:
`Font.kerns` says whether a font kerns, `Font.kern_offset` says what it does to a pair.

Two decisions in it were settled by measurement rather than by taste.

`features` reads the **FeatureList**, not the features the scripts enable. Those are different sets and
the difference is not academic: Segoe UI declares 25 tags in GSUB and only 23 are reachable from any
default language system, because `isol` and `locl` are enabled only under a tagged language. A count of
23 would say the font cannot isolate a letter, which is false. It can, and this engine does not ask the
text which language it is in. The shaping path is left reading the scripts, which is still the right
answer for shaping a run of text.

`glyph_class_counts` puts every glyph in `unclassified` when there is no GDEF, rather than returning zeros.
Returning early looked reasonable and meant the counts did not add up to anything: a caller summing them
to check no class had been dropped would conclude all of them had been. That was a real bug, caught
against a real font with its GDEF stripped rather than against a mock.

`BreakOpportunity` is now public. It was not, and `break_opportunities` was, which left a caller able to
count its results and read none of them.

### `tools/fontdump`

**Done**, in `tools/fontdump.v`. Everything it prints comes from the inspection API, so this program and
the library cannot disagree about a font: there is one parser and one set of numbers.

```
v run tools/fontdump.v C:/Windows/Fonts/segoeui.ttf [--verbose]
```

It prints the tables with their offsets, marking the ones this engine reads, the cmap subtables with their
formats and mapped counts, the glyph class histogram by name, and for each of GSUB and GPOS the scripts
and features split into the ones the engine uses and the ones it skips.

The split is the point. A font's features are not a list of things that work; they are a list of things a
font contains, some of which any given engine reaches. Printing both side by side is the only way to see
the difference instead of arguing about it.

`--verbose` adds the per-script lookup count for every feature the engine claims to use. That number is
what separates a font that offers a feature and implements it from one that offers the name and leaves it
empty, and on Segoe UI it settles an argument that was previously being had from memory:

```
isol  no script names it with any lookups
locl  no script names it with any lookups
kern under arab  19 lookups
kern under latn   1 lookup
```

Both `isol` and `locl` are in Segoe UI's GSUB FeatureList. Neither has a single lookup under any script,
because this engine asks one language system and none of them names them. A report that stopped at the
feature tag would say the font can isolate a letter and that the font cannot, which is the same sentence
pointing both ways.

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
