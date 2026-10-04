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
| cmap formats 0, 4, 6, 12, 13, 14 | done |
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
| Line options beyond a feature list | absent: no line height, alignment, or spacing |
| Rasterized glyph reuse | absent: the cache is the caller's, and the atlas was never real |
| Glyph box measurement | done: the layout pass asks for the box, not the pixels |
| Vertical extent of a line | done: was twice the ink, found by `tools/metrics` |

Twenty-two test files, all passing, reading real fonts from the system. The cursive reader is the one
piece with no font to test it against, so its tables are built from words in `gpos_cursive_test.v`
rather than opened from disk.

## Performance: what was actually slow

This section was not here before 2026-10-04, and it is here because the section below it was wrong.
The argument for a glyph cache was that rasterizing per glyph per frame "is the difference between a
page that scrolls and one that does not". That is true, and it was not where the time went.

Measured on this machine, Segoe UI at 16 pixels, best of five batches, with eight other V builds
running — so treat the absolutes as carrying that variance and the ratios as the finding:

| Paragraph | Before | After | Cost per character |
| --- | --- | --- | --- |
| 128 characters | 1835 us | 656 us | 5.1 us, flat |
| 256 characters | 5630 us | 1218 us | 4.8 us |
| 512 characters | 18910 us | 2190 us | 4.3 us |
| 1024 characters | **72190 us** | **4060 us** | 4.0 us |

The cost per character climbing from 11 to 69 microseconds as the text got longer was the signature:
`layout_paragraph` was quadratic. It is linear now, and 1024 characters went from 72 milliseconds to
4.

The cause was not rasterization. One rasterization of a 16 pixel glyph is **3.9 microseconds**, so a
264 character paragraph spent about a millisecond of a seven millisecond layout inside
`measure_line`. It is now a box query instead of a fill (`Face.box_only`), which removes an
allocation and a scanline pass per glyph, and that is the whole of what that change is worth.

The cause was `apply_ligature` in `gsub.v`, which built a view of the entire rest of the run before
trying a ligature at one position. `match_ligature` only ever reads as far as the longest rule's
components, so trying it at each of *n* positions copied O(n) each time: 524,000 element copies per
lookup per layout at 1024 glyphs. The bound is now computed once when the lookup is parsed. Measured
on its own, `Font.substitute_glyphs` over 1024 glyphs went from 65883 us to 1550 us.

What this changes about the rest of the roadmap: glyph reuse is worth having and is the caller's to
have, and it is not the difference between scrolling and not. Nothing else in the list is a
performance item, so there is no longer a performance argument for any of them.


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

**Done**, and the refusal the old version of this section asked for turned out to be the wrong shape of
answer. Refusing is right for a table a reader cannot bound and wrong for a table a reader can bound a
different way.

The awkward part of the format is that its exception list runs *to the end of the subtable*, and a
lookup's subtables carry no length of their own. So the question is what stops the scan. Two things do,
and only one of them is available in general:

- **The extension's length**, when the subtable came through one. `ExtensionPos` writes a uint32
  `extensionLength` that the reader had no use for until now, and it is plumbed through
  `ResolvedSubtable`. Nearly every real positioning rule arrives through an extension, so this is the
  bound that usually applies.
- **The coverage**, always. An exception names *coverage indices*, so it cannot name more glyphs than
  the coverage covers. A count larger than that is not a badly aligned record; it is the end of this
  table and the start of whatever follows.

The second is the one that matters, because it is structural rather than a hope about the font, and
because it is what stops a format 2 subtable read without a wrapper from eating the next lookup's
bytes as exceptions.

What the format actually is: one value for the whole coverage, a `valueCount` that must be 1, and then
exceptions keyed by coverage index. `offset_for` asks the exceptions first and the shared value second,
and which pair of those is live is decided by whether the shared value is set rather than by a format
number — so there is one lookup path for both formats instead of two that can disagree.

No font on this machine uses it, so all eight tests build the subtable as bytes. That is not a
shortcut: a parser that is correct on the specification and never executed is not a parser. The test
that pins the count check uses a record whose four indices are **all valid** for a two glyph coverage,
so that removing the count check is what makes it fail — a record with an out-of-range index would be
refused by either check, and a test using one would pass with the count check deleted. That was caught
by mutating the code and finding the test still green.

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

### ~~Cursive attachment: the attachment itself~~ — re-confirmed blocked, 2026-10-04

**The reader is right and this engine is right to find nothing. The premise was checked again against
fontTools and the check nearly went the other way.**

The earlier survey in this file stands: unwrapping extensions and reading the type each one *declares*
finds no cursive attachment on this machine. That was re-run, and it is still what the declared types
say. What happened is that a second survey, using fontTools instead of reading the bytes, reported nine
fonts with a `CursivePos` — Dubai, Arabic Typesetting, Urdu Typesetting, Aldhabi — and every one of
them is a false positive:

| font | lookup | declared | fontTools class |
| --- | --- | --- | --- |
| arabtype.ttf | 15 | extension, `extensionLookupType` = **3** | CursivePos, 1542 glyphs |
| UrdType.ttf | 0 | **3** (not an extension at all) | CursivePos, ten subtables |

Both are **mark attachment** by declaration. fontTools reports them as `CursivePos` because it
classifies the subtable from the bytes' shape — one coverage followed by N pairs of anchor offsets and
then an anchor table — and that shape is exactly a cursive rule's. A mark attachment is supposed to
have two coverages, and these have one.

So the roadmap's earlier note was right and has now been confirmed with a specific instance to point
at: **fontTools calls a subtable a CursivePos by reading its shape rather than the header that names
its type.** A conformant consumer follows `extensionLookupType`, and this engine does.

The engine's own guard agrees independently, which is the part worth having. It visits all 54 type-1
lookups in arabtype and refuses every one, and the 54 refusals are all the same shape: the word where a
cursive rule's first anchor offset would be holds a number like 5 or 7, which is a value format, and a
value format cannot point past a value array that is already there. Not one refusal involves a
plausible anchor offset, because there is not one in the font.

**This stays blocked, and the blocker is font availability rather than OpenType.** Amiri, Scheherazade
or a Nastaliq face would settle it. Writing the attachment against a mark attachment's bytes would be
worse than not writing it: it would produce a line that joins plausibly and is wrong, and the join is
the one thing an Arabic reader notices immediately.

Two things did come out of the exercise and are kept:

- The reader handles format 1 and format 2, so a font that brings its own attachment is a reader away
  from working. `gpos_cursive_test.v` builds both formats as bytes and checks the guard refuses a single
  positioning whose value format lands where an anchor offset would be — which is a real failure that
  happened, taking Andalus's lookup 21 out of the font and failing the kerning tests.
- `ResolvedSubtable` now carries the extension's length, which is what a format that runs to the end of
  its subtable needs and which nothing wanted until SinglePos format 2.

### Device and variation tables

A GPOS value record can point at a table that says the value is different at a
different size. Skipping it means a kern is the same at every size, which is
wrong but not visibly so. Reading it is a matter of applying a table of
adjustments by pixels-per-em, and a variable font's version needs the variation
store.

### ~~Line options, and measuring a run at a width~~

**Done, in two halves, and one of them is a live bug fixed in the caller.**

`LayoutOptions` has `line_height`, `letter_spacing` and `word_spacing`, and `Line` has
`line_height`. Direction did not move into it, and that was a decision rather than an omission: the
`base_dir` argument already carries it, and a second source for one decision with no stated precedence
is worse than a slightly awkward signature. Alignment is absent for a different reason — aligning
inside a margin needs a container width the engine does not have, and `Line.glyphs` is already
mutable, so the knob would have been a field that does nothing.

Spacing is added to **advances**, before `place_glyphs`, not to positions afterwards. The running sum
in `place_glyphs` and the width in `measure_line` then both account for it with no second walk and no
way for the width and the positions to disagree. A combining mark is skipped: it shares its base's
position and has no advance, so spacing both would charge one character twice. That is the whole of
the implementation and the only non-obvious decision in it.

`line_height` resolves to the caller's value when there is one and otherwise to the largest natural
line height among the fonts that contributed a glyph. `ascent` and `descent` are deliberately left as
the ink's extent rather than made to fit the box, and `gpos_test.v`'s assertion that a mark counts
towards the line height is what pins that. A caller asking for a line height below the glyphs gets the
smaller number and clips the ink itself, which is the only answer that can be right without knowing
what the caller will draw. The question `ROADMAP.md` raised about this — what happens below the
font's natural line height — is answered by that split rather than by a new field.

`measure_paragraph` and `measure_paragraph_with` report the two widths a caller needs before it draws
anything, out of one shaping. The widest is `layout_paragraph`'s width. The narrowest is the width of
the widest unbreakable unit, **excluding trailing spaces**.

That exclusion is the reason the function exists rather than a refinement of it. A break opportunity
falls *after* a space, so the space ends the line before the break rather than starting the one after
it, and a number copied out of `wrap_paragraph` is one space too wide on every word. Measured at 32
pixels on Segoe UI that is **8.77 pixels**, which at a 16 pixel size is about a twentieth of a line.

The caller has this bug today. `../vweb/text/shape.v` computes a min-content width by calling
`wrap_paragraph` with a width of zero and taking the widest line, which is the same number with the
space still in it. It can call `measure_paragraph` instead; that change is in that repository and is
not in this one.

Two things about the measurement that are worth knowing rather than re-deriving:

`max(advances)` and `sum(advances)` agree, because `place_glyphs` accumulates `x` as a running sum
from zero, so for any contiguous run of glyphs the furthest the pen reached equals the total of the
advances. They diverge only when a logical range spans more than one bidi run, which is what makes
the per-cluster prefix sum in `cluster_prefix` correct rather than merely convenient.

And it is O(n). Asking `width_of_range` once per break opportunity walks every glyph once per
opportunity, which is quadratic in the length of a text whose words are short — and short words are
most of the text anyone measures.

`wrap_paragraph` also grew a `_with` form, which was a bug rather than a feature: it took no options
at all, so it shaped without the caller's features while `layout_paragraph_with` shaped with them,
and the two disagreed about the width of the same text.

### ~~A glyph cache~~ — settled, and not in this library

**The cache stays with the caller, and the atlas was never going to arrive.** This reverses what the
rest of this document said for a year, so the reasoning is worth having in one place.

There is a caller on disk, `../vweb`, and it already has a cache: `GlyphKey` packed into a `u64`, the
size quantised to a 64th of a pixel, the subpixel offset to a quarter, and about 22 KB of tests for
it. Both projects had written down that the cache belonged here. It lives there now, which is the only
honest way to record a decision that was already made by other means.

Keeping it there is also the better answer on the merits, which is not what either document said:

- The cache key needs the **font**, and the font is resolved by the caller's own font library, not by
  this engine. `vweb` keys on a font *id* it assigned; this engine's key would need a pointer, and a
  pointer is not comparable across a fallback chain that reloads.
- A cache on `Font` makes every loaded font's face mutable. Nineteen public methods currently take
  `&Font`, and `Context` is documented as shareable between threads; a cache would silently reverse
  that for every caller who took the documentation at face value. `v -race` cannot check the fix here,
  because Windows is not a supported target for it.
- A cache is a memoisation of a pure function of (font, gid, size, subpixel offset). That is a few
  dozen lines of the caller's own code, with no shared mutable state and nothing for the engine to
  keep compatible.

What arrived here instead is the half of the problem that *was* the engine's: `measure_line`
rasterized every glyph of every paragraph to read two integers out of the result and threw the pixels
away. It now asks for the ink box (`Face.box_only`), which is the same two numbers with no fill and
no allocation. `stbtt_test.v` sweeps all 7000-odd glyphs of Segoe UI and six sizes in Tahoma to prove
the two paths report identical boxes, because the argument that they do is one step from the
rasterizer header's own definition of `stbtt_GetGlyphBitmapBox`.

Note that this is not the same as saying it is fast. Rasterization is 3.9 microseconds per glyph and
was never the bottleneck; see the performance section at the top.

An atlas, if anyone wants one, should be a separate type the caller owns, built from these bitmaps.
A GPU texture with a shelf packer is a display backend's concern, and this engine has no display
backend. The claims that this library had one — in `v.mod` and in the module comment — were removed
rather than implemented. The roadmap had attributed the comment to `Context`; it was in the module
comment at the top of `vtext.v`.

### ~~cmap formats 13 and 14~~

**Done, and it turned up two bugs that were not about cmap at all.**

Both formats are read. Format 13 is format 12 with the one difference that matters — a whole span of
codepoints is a single glyph, so the glyph does not advance with the codepoint. Format 14 is what an
emoji actually needs, and the interface question the old version of this section raised is real and was
answered by splitting the lookup rather than by adding a parameter: `Font.glyph_index_variation(cp,
selectors)` sits beside `Font.glyph_index(cp)` rather than inside it, because everything else in the
library is built on a glyph lookup being a pure function of one rune and a parameter would have
undone that quietly.

**The three layout facts in this format are each one a table that reads as empty rather than as
broken**, which is why all three had to be found by dumping bytes rather than by reading the
specification carefully. Segoe UI Emoji's subtable starts like this:

```
00 0E | 00 00 02 E5 | 00 00 00 01 | 00 FE 0F | 00 00 00 15 | 00 00 00 00
format  length 741   language 1    selector   defaultUVS=21  nonDefault=0
```

The length is a **uint32** where every other format's is a uint16. The records begin at offset 10,
immediately after the header, and **there is no count of them** — so a reader expecting the count every
other format has reads the selector U+FE0F as sixteen million records. And each record is **11** bytes,
not 12, because the two uint32 offsets after a uint24 selector are aligned to nothing. A `UnicodeValueRange`
is 4 bytes and a `NonDefaultUVSRecord` is 5, neither of which is what you get by adding the fields as
4-byte words.

With no count to read, the scan ends on the first record whose table offsets point outside the
subtable, which is the only signal available and is unambiguous. For a font with one record the second
"record" is the default table's own bytes, so a reader that does not stop there takes a length of
several hundred million out of a count field and then tries to allocate it.

Measured: Segoe UI Emoji reports **354** bases it can vary, which is the 179 spans in its default table
counted out, and `tools/fontdump` prints it. Before this it printed zero, because the table answers
nothing about any bare codepoint and was being counted by asking.

**The bug that mattered more was not in the cmap.** A variation selector was being dropped during
shaping, before any font was consulted, and the reason is worth recording because it looks like a
correct decision. `attach_marks` treated a transparent character with no combining class as an invisible
format character and gave it no glyph. That is right for a ZWNJ and wrong for U+FE0F, which changes
which glyph the character in front of it draws as.

The second bug was worse and was not about selectors at all. The pass-through branch of the shaping
loop — the one for characters that take no joining shape — stepped over the character and continued,
so **nothing after a non-joining letter was ever attached to it**. For Arabic that never showed,
because every Arabic letter has a joining type that takes a shape and falls through to the branch
below. For a script whose letters are transparent it means every mark after every letter was silently
dropped: Myanmar, Thai and Lao text drew without its vowels. The variation-sequence work found it
because a Myanmar letter was the fixture.

`ShapedGlyph` therefore carries `selectors`, and its fields are now split into what is known before the
glyph exists and what the engine fills in while walking the run, which is what let the leftover
selector at the end of a run reach the letter in front of it.

No font on this machine has a format 13 subtable, so that half is tested against a table built in the
test file rather than read from disk. Ten have a format 14 and the fixtures are real:
`seguiemj.ttf` for a default table, `mmrtext.ttf` for 29 non-default mappings, `phagspa.ttf`,
`msgothic.ttc` for supplementary selectors, and the four `YuGoth*.ttc` for both table kinds at once.

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

`LayoutOptions` is one field, and phase 1 says what it needs to grow into. Once
it has grown, the question is whether it is enough: a caller should be able to
do everything the library can do through it, and nothing should need a separate
function that only works for one script. `Face`, `Sfnt` and `Cmap` are still
private, and whether a font inspection API belongs to the shaping engine or to
its caller is a question this library has not answered.

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

### ~~`tools/shapetrace`~~

**Done**, in `tools/shapetrace.v`, and it works by calling each stage separately rather than by
instrumenting `layout_paragraph`. That is what `trace_api.v` is for, and it is why that module is
`pub`: a trace has to be able to stop between the passes, and the alternative was a build of the
engine with prints in it.

```
v run tools/shapetrace.v "سلام" C:/Windows/Fonts/segoeui.ttf
```

It prints the input, what normalization did, the resolved levels, the joining form each letter took,
the shaped glyphs, and the laid-out result with its width and vertical extent.

### ~~`tools/fontcheck`~~

**Done**, in `tools/fontcheck.v`. Validate a font against the library and report what it cannot use.
Not whether the font is valid: whether this library can shape with it, which is a different question
and the one that matters. A font whose GSUB references a glyph its cmap never produces is valid and
unusable, and that is a report rather than a crash.

It checks the outlines, the lookup kinds, features no script reaches, the cursive reader's refusal,
variable fonts, mark attachment, and per-script coverage. What it does **not** check is a cmap format
this engine cannot read, which is the finding a format 13 or 14 implementation should add.

### The vertical extent of a line was twice what it should have been

**Found by `tools/metrics`, which is the argument for writing the tool before it was needed.**

`measure_line` computed the ascent as the top of a glyph's ink box **plus the height of that box**, and
the descent as the top of the ink read as though it were a depth. The box spans from `top` above the
baseline down to `top - height`, so `top` is already the distance above the baseline and adding the
height to it counts the ink twice.

Measured on Segoe UI at 16 pixels, `"Hxbdfpq"` reported **26 above the baseline and 13 below**, where
the ink is **13 above and 4 below**. A line box two and a third times the em it was drawn at. Every
example in this repository sizes its canvas from `ascent + descent`, so every one of them had been
drawing into a canvas roughly twice as tall as it needed, and a caller laying out a page from these
numbers would have reserved the space and known it.

Two things are worth recording about how it survived. It was not caught by any test, because
`layout_test.v` only asserted `ascent > 0 && descent > 0`, and because
`gpos_test.v`'s assertion that a mark counts towards the line height **passed for the wrong reason** —
the mark did reach past Arial's ascender, and it also reached about twice as far. A test can be right
about what it says and wrong about why it passes.

And it is the kind of bug that a smaller number would have hidden. Every example draws its baseline and
its glyphs from `Glyph.y` and the font's own metrics, and both of those were already correct, so the
pictures looked right. Only `Line.ascent` was wrong, and nothing drew with it.

### ~~tools/metrics~~

**Done**, in `tools/metrics.v`.

```
v run tools/metrics.v <font.ttf> [--size N] [--glyphs N] [--glyph N]
```

Vertical metrics at a size, the shape of the font's advances, and the metrics of a glyph you name. The
part that earns it is a line of ink: the tool lays out a real string and prints what the engine reports
the ink's extent to be, beside the font's own ascender and descender. That comparison is what found the
fault above, and it is not a comparison any single number in the library invites — `Font.ascent` is the
font's number and `Line.ascent` is the ink's, and the interesting case is when they disagree.

It also prints how many glyphs have zero advance, which is the cheapest way to see whether a font's
space is a real space.

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

The last of those is now the load-bearing boundary. There is a caller: a
from-scratch HTML and CSS engine (`../vweb`) that uses this library as its only
text layer, and it is why the three gaps in phase 1 above are written down as
gaps rather than left for later. The division holds as long as it stays this
way: boxes, the cascade and painting are the caller's, and this library ends at
a positioned glyph with a coverage bitmap. Glyph reuse is the one place the
boundary was genuinely awkward, and it has been settled against this document's
earlier reading: the caller rasterizes into its own buffer, so it needs a cache
and not an atlas, and **the cache is the caller's**. See the glyph cache section
for why that is also the better answer on the merits rather than only the one
that was already in force.
