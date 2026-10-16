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
| GPOS: cursive attachment, format 1 and 2 | read and verified glyph-for-glyph against fontTools; the attachment is not written, and no font here both carries a rule and shapes letters the way a rule describes |
| Line breaking (UAX #14) | partial, and now measured: **18,777 of 19,346 (97.1%)** against the Unicode test, with a floor asserted on every run |
| Line options beyond a feature list | done: line height, letter spacing, word spacing. Alignment absent by decision |
| Rasterized glyph reuse | absent: the cache is the caller's, and the atlas was never real |
| Glyph box measurement | done: the layout pass asks for the box, not the pixels |
| Vertical extent of a line | done: was twice the ink, found by `tools/metrics` |

Twenty-six test files, all passing. The cursive reader is tested twice over: from words in
`gpos_cursive_test.v` for the byte shapes, and against real cursive rules in the licensed corpus under
`testdata/fonts/`, because a fixture written to match the reader cannot catch a reader that is wrong about
where the records start. That is not hypothetical — it is how the record-offset bug survived.

Two UCD conformance files are committed, not fetched, and both are excepted from the `ucd/*` ignore by
name beside a comment explaining that the licence travels with them. `NormalizationTest.txt` was missing
from that list until 2026-10-11 and `normalize_test.v` panicked on every checkout that had not fetched
it — a suite that is green here because the data is on this machine and red anywhere else is the same
failure as a fixture written to match the reader.

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

**Measured, because "done" above was a description and not a number. 18,777 of 19,346 — 97.1%.**

`ucd/LineBreakTest.txt` is the Unicode committee's own list of cases for this version, and it is now
committed and run by `linebreak_conformance_test.v` on every test pass. The test asserts a floor rather
than an exact figure, so a rule landing shows up as a number somebody has to choose to raise the floor to,
and the property that matters — that a fix cannot be undone by accident — holds without the number ever
being quietly lowered.

One rule was fixed on the strength of it, and it was the cheapest failure in the file: **an ambiguous
character was a class no rule matched.** The table names `AI`, nothing in the chain tests for it, so it
fell through to the permissive default at the end and broke away from its neighbours on both sides. UAX#14
resolves it to a letter unless the text is being treated as East Asian, and this engine has no such mode,
so it now resolves to `AL`. Sixteen cases, and `× 2757 × 2757` went from a break to no break, which is
the whole of the class of failure the first eight reported were.

**A better version of the same fix measured much worse and is not in.** Giving a combining mark its base's
class, rather than leaving it `.cm`, is what LB9 reads like on both sides, and it took the score from
13,074 to **10,912** — 8,434 failures against 6,272. The mark then carries its base's class into the rule
*after* it, and a base that is allowed to break away, a space or a character whose own class permits it,
has that break suppressed by the mark on top of it.

### The rules that were missing, and the one that was invented — 4,159 cases

The 4,893 that were left were listed as one bullet about CJ characters, and that bullet was the wrong
shape of answer: most of them were rules that had never been written, and the bullet was describing their
consequences rather than their cause. Each was found by asking the committee's own test file a question
directly, which is a better instrument than reading the rule numbers.

**A space was answering before anything could ask it a question.** `× SP × CL` broke where LB13 refuses
it. The chain opened with LB18 as a leading return, which is right for a space against a letter and wrong
against every rule that says which character may not start a line. That alone was 2,551, and four other
rules were hiding behind it. `.bk` shared the return and was dead code: a mandatory break is answered
above it, so no pair could carry one on the left.

**LB5 was missing and a test asserted its absence.** Nothing handled a hard break on the *right*, so
`× AL × LF` fell through to the default and produced a break. 67 of the 70 cases the file writes for a
class in front of a newline are breaks that must not happen. `inspect_test.v` asserted the opposite, that
the break *exists* and is not mandatory, and named LB7 while doing it. LB7 is about spaces.

**LB8, LB11, LB12a and LB20 were all shaped as the wrong rule.** LB8 is a break *after* a zero width
space, and there was nothing on either side of one — the committee answers `× 200B ÷ X ÷` with `[8.0]` for
every class X, which is the whole of why ZW and SP are different characters despite both being spaces.
LB12a exempts two classes from its prohibition and the reader had three, because `[^SP BA HY]` reads as
though a break-after character were exempt; `× 3000 × 16FE4 ÷` [12.1] says it is not. LB20 needed both
halves *and* an LB19 in front of them.

**Four classes were folded into a mark, and only one of them is one.** `is_markish` named `.ap`, `.vi`,
`.idcj`, `.h2` and `.h3` alongside `.cm`. An aksara pre-base and a virama final are not combines; the
committee asks for a break before one 497 times and refuses one 615. `.h2` and `.h3` were the surprise —
Hangul syllables, kept on the strength of LB26's jamo rule, which is true and is not the same thing.
`.idcj` measured zero and went anyway.

**Three LB1 resolutions were missing** from a function that handled `.ai` alone: unknown, complex context
and conditional Japanese starter all fell through to the default. `.sa` to a letter is 58, `.xx` 28 and
`.cj` to a non-starter 13.

**A quotation mark was one class, so an opening one and a closing one answered the same pair two
different ways.** Derived from the file rather than recalled, over 1,753 quotation positions: a break
before a mark is allowed only for a `Pi`, or after a hard break, or after a zero width space; a break
after a mark is never allowed for a `Pi` and is allowed past a space or a mark for the other two. Two
rules, worth 245, and the `[15.11]`/`[15.21]` failure counts go from 111 and 139 to one each. The
distinction is the general category, so it could not be a codepoint list in the source:
`DerivedGeneralCategory.txt` is fetched, `tools/gen_tables.v` emits a `ucd_quote.v` in the same form as
its siblings, and nothing was hand-written.

### And the one rule that was invented rather than missing: a line may end on a combining mark. Worth 922 cases

A rule refusing a break *after* a mark was added on 2026-10-04 for 312 cases and was generalised from
a single case — the file's only one containing U+200C, a zero width non-joiner — into "a line may not
end on a combining mark". LB9 forbids a break *before* a mark. It says nothing about what follows
one, and the default there is a break.

Removing it alone was 713 cases; the 768 it broke were `× 2757 × 0308 × 2757 ÷`, where LB28 reads
through the mark to a pair of letters. Those are recovered by `pair_left`, which reaches the base for
LB28 and LB23 and for nothing else — and **that is the whole shape of the change**. LB30 reads through
a mark in the opposite direction: `× 2757 × 0308 × 0028 ÷` breaks, where `× 2757 × 0028 ÷` does not,
because LB30 was missing entirely and is not one. An open punctuation may begin a line after a marked
letter but not after a bare one, which is what a diacritic carrying word-final stress through to the
next word looks like.

Plus LB28's four pairs — it had one. `× 2757 × 0308 × 05D0 ÷` is annotated `[28.0]` at the Hebrew
letter, so LB28 reads a Hebrew letter as the same kind of letter as a Latin one. And an opening
quotation mark's hold now reaches a run ending in a mark as well as one ending in a space,
`× 00AB × 0308 × 2757 ÷` [15.11], which the `left == .sp` gate had been refusing.

### And the complex-context class is 757 characters, not one. Worth 360 cases

LB1 resolved every SA codepoint to a letter, and the committee splits the class. U+0E31 and U+102C
answer `[9.0]` and behave as combining marks; U+0E01 answers `[28.0]` and is a letter. The
distinguishing property is `General_Category` — Lo for the letter, Mn or Mc for the marks — and
`DerivedGeneralCategory.txt` had been fetched and committed two commits earlier for the quotation
work, so what was missing was the generator and the plumbing rather than the data. `ucd_sa_mark.v`
is 27 ranges covering the 191 SA codepoints that are marks, emitted by a `sa_marks` generator that
mirrors the quotation `quote_roles` one exactly, with `sa_none` at ordinal 0 so an absent range reads
"not a mark".

The split is asked of a character that *follows* something, which is the same condition LB4a carries,
and the reason is not a coincidence: an SA mark attaches to the character in front of it, so a leading
one has nothing to attach to. Measured rather than assumed — resolving a leading SA mark to CM broke
38 against the 4 it fixed. That leaves a leading mark unresolved in either direction, and the
committee is inconsistent about a leading *ordinary* mark in exactly the same way, so it is the file
disagreeing with itself rather than a gap in the engine.

Four small rules landed with it, each measured alone and none breaking anything: LB24's prefix or
postfix against a letter or Hebrew letter, LB23's prefix against an ideograph or emoji, LB27's prefix
against a Hangul syllable, and `.ns` leaving the prohibited-end list. That last one is worth **121**
where the roadmap had carried a note saying 12 — the note was written from a shape rather than from a
count, which is the same failure as reading a rule number instead of the file.

**The rule that was invented is worth the most instruction in this file.**

Removing it alone was 713 cases; the 768 it broke were `× 2757 × 0308 × 2757 ÷`, where LB28 reads
through the mark to a pair of letters. Those are recovered by `pair_left`, which reaches the base for
LB28 and LB23 and for nothing else — and **that is the whole shape of the change**. LB30 reads through
a mark in the opposite direction: `× 2757 × 0308 × 0028 ÷` breaks, where `× 2757 × 0028 ÷` does not,
because LB30 was missing entirely and is not one. An open punctuation may begin a line after a marked
letter but not after a bare one, which is what a diacritic carrying word-final stress through to the
next word looks like.

Plus LB28's four pairs — it had one. `× 2757 × 0308 × 05D0 ÷` is annotated `[28.0]` at the Hebrew
letter, so LB28 reads a Hebrew letter as the same kind of letter as a Latin one. And an opening
quotation mark's hold now reaches a run ending in a mark as well as one ending in a space,
`× 00AB × 0308 × 2757 ÷` [15.11], which the `left == .sp` gate had been refusing.

**The rule that was invented is worth the most instruction in this file.** It was added for 312 cases,
removed for 713, and the 768 that came back with LB28 reading through it are a different rule from the
one that paid for it. A conformance score is a count of cases and cases are not a random sample: the
312 were a shape the file asks often, and the shape it asks *about* — a letter, a mark, a letter — is
what the mark was for. The one-sided rule at the end of the chain is what is left, and it is the
smaller one.

What the remaining **676** are, worth writing down before anyone starts:

- **An opening punctuation holds the run it precedes end to end, and the engine now agrees.** `× OP ×
  SP × R` and `× OP × CM × SP × R` are 138 × each with no ÷ counterpart in either shape, and the
  `is_prohibited_end` list could not answer them because it reads the space itself. Measured 223
  fixed, none broken, by reading the run origin the way LB15a already did.
- **The leading mark, in either direction.** A mark with nothing in front of it is unresolved: the
  committee breaks after a leading *ordinary* mark in some cases and not others —
  `× 302A ÷ 1B05 ÷` breaks, `× 302A × 2757 ÷` does not — and gating the mark rule on the mark having
  a predecessor measured 76 restored against 75 broken. UAX #14 has no rule for a mark that starts a
  line, and the file has both answers, so this is the file disagreeing with itself rather than a gap
  in the engine. The same contradiction accounts for **130 positions**: bare `SP × PO` is `[18.0]` and
  `SP × CM × PO` is `[24.03]`, across all six of SP, ZW, BK, CR, LF and NL, and no rule answers both.
- **`.insp`, `.ex`, `.hy` and `.bb` are still class lists where the committee has pairs.** The
  `× 0029 ÷ 2757 ÷` / `× 0029 × 2757 ÷` split that took `.cp` out measured the same shape for each of
  them, and it was measured rather than predicted: reading `eff_left` through them fixed 20 and broke
  94, because it propagated the over-refusal into the mark rules. Each needs its own pass, and they
  are the largest bucket left.
- **LB19 is one rule where the committee has two.** `× QU_Pi × SP × QU_Pf ÷` is the pair both rules
  answer, and the long real-world lines at the end of the file track whether a closing quote closes a
  span that is still open, which no pair rule can reproduce. UAX #14 has no quotation-span state and
  this engine's pair chain cannot express one.
- **LB28's aksara sub-rules**, the 17 cases already noted on `is_markish`, and LB26's jamo run.
- **LB25's numeric matrix**, which this engine reads as pairs. It is what the one open `(4·)$` case
  wants, and the currency symbol is a break at four other positions, so the pair cannot be widened.

None of them are Arabic or Persian, which is why the library is usable without them and why they are
listed rather than fixed here: each is a rule with its own cases, and a run that reports a percentage is
the wrong unit of work for one of them.

### An aksara is not a combining mark — done 2026-10-04

Worth 51 cases, from 13,402 to 13,453, and it was the last item on the list above.

`is_markish` named `.ak` among the classes it folds into a combining mark, so no line could end before an
aksara. The conformance test reports it as `× 2757 ÷ 1B05 ÷` — a break the specification asks for and the
engine refused. U+1B05 BALINESE LETTER AKARA is class AK, and the class is its own in the UCD and treated
as a base by the rules.

The comment on the function said the list came from "the ones called aksara and virama in older versions of
the table", which is where the mistake came from: an older UAX #14 folded aksara into CM, and this engine
carried the folding forward into a version of the table that no longer does it. `.ap` stays — an aksara
*prebase* is a mark in the same sense a Devanagari prebase is, and it is the one carrying the accent-like
behaviour. The distinction is the whole point of having two classes.

### A combining mark may no longer end a line, and that is a Persian trade-off

The biggest single gain available was one rule: **a line may not end on a combining mark.** It is worth
**312** cases, from 13,090 to 13,402, and it is the largest jump in this whole line of work.

It was found by going after the gap the conformance test reported first, which was every case of the form
`× 2757 × 0308 × 2757 ÷` failing at the index *after* the mark. The engine already refused a break *before*
one, and the comment said the mark "glues one side only, which is deliberate".

**That is now reversed, and the reason is U+200C.** A zero width non-joiner is class CM in the UCD, so it
is a combining mark as far as line breaking goes, and a grapheme cluster member is indivisible from both
sides. The Unicode committee's own test settles it: its single case containing U+200C reads `× 200C ×`.
There is no interpretation left to argue about, and the spec has one answer.

**The trade-off is real and this is a library for Persian.** A ZWNJ-separated pair is two words —
`نیم‌فاصله` — and a line may no longer end between them. To break there the text has to carry a word
joiner. The previous behaviour was deliberate and documented, so it was not an oversight, but it was a
choice made without the 312 cases in front of it, and the conformance test says it is wrong.

Two things are worth recording about how it was done. The first attempt gave the mark its base's *class*,
which is what LB9 reads like across both sides; that measured **10,912**, a fall of 2,178, because a base
that is allowed to break away has its break suppressed by the mark in front of it. Refusing the break *at* a
mark is a narrower change — one position rather than a class every later rule reads — and it gets all 312.
And the broken test that followed the first attempt was not a bug in the change: it was the ZWNJ test
asserting the old behaviour, which is what finally showed the trade-off existed rather than being a free
correction.

### ~~Numeric breaking: two rules, and the comment that hid one~~ — done 2026-10-04

**This entry first said the cheapest remaining rule was LB28's numeric cases. That was half right, and the
half that was wrong was the one that mattered.**

LB28's other two pairs — `AL × NU` and `NU × AL` — were genuinely missing, and adding them took the score
from 13,074 to 13,084. Sixteen cases became ten, which is small, and I wrote a test expecting `19C` to hold
together and it failed. The reason was not in LB28 at all:

| text | before | after |
| --- | --- | --- |
| `H2O` | one break at the end | one break at the end |
| `19C` | breaks at **1** and 3 | breaks at 3 |
| `1,000` | breaks at 3, 4, 5 | breaks at 5 |
| `a1b` | one break at the end | one break at the end |

**A run of digits was not held together at all.** `12345` could break between any two digits. The code at
that point carried the comment "LB23a and LB23b: two of the same class that must not be split, which is
Hangul syllables and a numeric run's own continuation" and implemented only the Hangul half — **a comment
claiming a rule is not the rule**, and the comment is what kept it from looking absent. Nothing about the
output said wrong either: a number split across two lines is still a number-shaped thing, and a phone number
or an account id wrapping as `12` / `345` reads as ordinary wrapping.

`NU × NU` is now implemented, worth six cases on the conformance score and rather more than six in text.
The score is a poor proxy here for the same reason it was a poor proxy in the cursive case: a percentage
counts cases, and the cases a rule is *about* are not a random sample of the corpus.

`AL × NU` and `NU × AL` matter for the same reason and are Latin, not CJK: `H2O` and `COVID19` are single
names with a digit in the middle, and a break there leaves a line ending in a digit and the next starting
with a letter, which reads as a hyphenation nobody asked for.

LB29 — an infix separator holding to what follows — turned out to be already handled for the digit case,
which the same table showed; only `IS × AL` was added, and the tests cover `1,000`, `1.5x` and `H2O`
because each failed for a different reason.

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

### ~~Cursive attachment: what it actually needs~~ — the premise was wrong, and so was the survey

**The reader had two bugs and the survey was built to hide both. Both are fixed; cursive attachment is
now read, and it was never a font-availability problem.**

What this section previously claimed is worth recording because it was confidently wrong twice. It said
the engine read the rule and refused it, that unwrapping extensions found no cursive attachment on any
font on this machine, and that the blocker was finding a font that has one. Every one of those was a
consequence of a reader that could not see a cursive rule even when handed one.

The two bugs:

1. **The dispatch never looked.** `parse_cursive` was only called when a lookup resolved to GPOS type 1.
   Cursive attachment is **type 3**. So the reader ran exclusively against single positionings, always
   failed, and the failure was then interpreted as "this table is a positioning, not a cursive rule".
   The comment saying "type 1 is two different tables under one number, a single positioning and a cursive
   attachment" was the belief that produced it. There is no such ambiguity in GPOS: type 1 is SinglePos and
   type 3 is CursivePos.
2. **The record array was read from the wrong offset.** Both cursive formats have an identical six-byte
   header — `posFormat`, `coverageOffset`, `entryExitCount` — so the records start six bytes in and the
   count is *stated*, never inferred from the coverage. The reader started at four, the offset of a
   SinglePos header, which put it two bytes early and shifted every record. The code asserted the opposite
   in a comment, and the hand-built fixtures in `gpos_cursive_test.v` were written to match the reader, so
   they agreed with it.

Bug 2 is the one that made bug 1 invisible. Reading two bytes early turns a record into its neighbour's
fields; the resulting "anchors" fail the plausibility check and the rule is refused, which is exactly what
a single positioning should do. So the reader was behaving correctly for the wrong reason, on the right
tables, and the survey built on it reported zero everywhere.

What the corrected reader finds:

| font | cursive rules | glyphs covered | entry anchors | exit anchors |
| --- | --- | --- | --- | --- |
| Amiri-Regular.ttf | 1 | 288 | 52 | 236 |
| NotoNastaliqUrdu-Regular.ttf | 1 | 378 | 196 | 340 |
| NotoNaskhArabic-Regular.ttf | 0 | — | — | — |
| DUBAI-REGULAR.TTF | 1 | via `curs` | — | — |

Noto Naskh is the negative control and matters as much as the positive rows: it joins with substitutions
alone and has no cursive rule, so a reader that accepted every type 3 subtable would fail there rather
than pass quietly. Amiri declares its rule directly and Noto Nastaliq reaches one through an extension, so
both dispatch paths are covered.

**On fontTools.** The earlier note in this file held that fontTools reports `CursivePos` for subtables that
are really mark attachments, and that a conformant consumer should follow `extensionLookupType`. That
observation was correct — fontTools does classify from shape — and the conclusion drawn from it was wrong.
Dubai's extension really does resolve to type 3 and really does carry a cursive rule; the shape had been
read from two bytes out of position. The general rule still stands and is the one worth keeping: **read the
header that names the type, not the bytes that resemble it.** It was applied in the wrong direction here.

What is still missing is the attachment itself, which is not a positioning rule but a change to advance:
the pen carries from one glyph's exit anchor to the next glyph's entry anchor, so a letter can end up
wider or narrower than its advance says. There is now a font for it to be written against.

### ~~Cursive attachment: the attachment itself~~ — the reader is verified; the attachment has no font

**This entry has been rewritten three times and the reader has been right every time. What is left is not a
gap in the engine.**

The reader is now verified against an independent implementation, glyph for glyph. fontTools' counts for
Noto Nastaliq Urdu's one cursive lookup are **378 records, 38 entry-only, 182 exit-only, 158 both, none with
neither** — and this engine reports the same five numbers. Amiri's are 52 entry-only, 236 exit-only and none
with both, which is also what this engine reports. Those counts are pinned in `cursive_anchors_test.v`, so a
reader that loses the 158 both-ended glyphs, or shifts the record array and reshuffles which end a glyph
claims, fails rather than looking plausible.

The glyph names show the rule is a conventional one, and that the entry/exit pattern is what a cursive rule
should look like:

```
alef-ar.fina[E]              an alef at the end of a word: receives a stroke, emits none
behDotless-ar.fina[E]        the same
behDotless-ar.medi[EX]       a letter joining both ways: both ends
behDotless-ar.medi.alef[EX]  the lam-alef ligature
behDotless-ar.medi.cain[EX]  Nastaliq's own stacked two-letter forms
```

So the anchors are right, the pattern is right, and the attachment is still wrong to write — because the only
font that reaches its own rule positions its letters with **pre-drawn ligature glyphs**, and on those the
cursive rule is vestigial. `سلام` shapes to eight glyphs; the sin's exit sits at (0, 0) and the next letter's
entry at (848, 384), in a face whose advances run about 540 units. Joining those would put the letter 848
units to the *left*, on top of its neighbour. The font does not want it — it has already drawn the answer
into the glyph names.

**The blocker is neither a reader nor reachability. It is that no font available here both carries a cursive
rule and shapes its letters in a way the rule describes.** That is narrower and more honest than what this
file carried for most of a week, and it took three attempts and one independent reader to reach.

### The two withdrawals, since the reasoning is worth keeping

Not headings of their own — this is the same entry, and the history is kept because each attempt is what the
next one corrected.

**First attempt — the pass was written and measured.** A cursive rule covers particular glyphs, and a letter
only reaches one if shaping picked it. Every covered glyph in Amiri was unreachable: all 288 have no codepoint
in the cmap, because the joining pass resolved a letter's shape through the presentation form rather than the
font's own features. Nastaliq had 158 both-ended glyphs and the layout selected almost none. The pass was
withdrawn rather than committed, because a feature that cannot be shown to change a single advance on any
font available is not a feature, and shipping it behind a test that measures nothing would have been the same
mistake in a new place.

**Second attempt — reachable, and still not writable.** The joining work fixed reachability, which was a real
win on its own: Nastaliq went from unjoined base letters to proper Nastaliq. But reaching the rule showed the
adjacent exit-to-entry pairing is not what it means. The measurements are in the entry on preferring GSUB:
Dubai, Traditional Arabic and Amiri reach nothing at all, and Nastaliq reaches four anchors, which is enough
to be worth writing and not enough to write correctly.

### ~~Arabic joining through GSUB~~ — done 2026-10-04

The four joining features now run over the run, each masked to the glyphs in its own shape, between `ccmp`
and `rlig` as the specification orders them. `Ligatable` carries the shape and `effective` filters on it.

**What it fixed.** Noto Nastaliq Urdu drew its letters as unjoined base letters, because that font keeps its
shapes in GSUB and its cmap has no presentation forms, so the fallback branch ran a per-glyph call that
could not apply the rule. `سلام دنیا` is now **18 glyphs from 9 characters** and renders as Nastaliq, with
the descending letterforms and joined strokes; before, every letter was the base glyph. Amiri and Noto Naskh
are unchanged, because they map the presentation forms and take the cmap route: Amiri still gives 8 glyphs
from those 9 characters, one fusion being the lam-alef.

Two things had to be true for this and neither was obvious.

**The mask cannot be a filtered list.** A MultipleSubst changes the length of the list as it runs — 46 of
Nastaliq's 68 `init` rules turn one glyph into two or three — so a mask built from the input goes stale
within a few rules. The shape therefore rides on `Ligatable` and `ligatables` copies it to the pieces, which
is the only arrangement that stays aligned. Removing the mask is not a slower version of this: it produces 4
glyphs where the correct answer is 8, because unmasked `init` claims every letter and the run is entirely
initial before `medi` runs.

**A latent loop, in code that was already shipped.** `Substitution.span` measured only what a substitution
*consumed*, and the walk resumes from it. For a 1:1 that is right. For a 1:3 the resume lands on the second
of the three pieces, which is in the same rule's coverage because it is the same shaped form, so it expands
again. Nastaliq hung for over twenty minutes on a four-letter word before this was found; the run grows
without bound. `span` now takes the larger of the input and output extents, which is correct for a fusion
(consumes more), an expansion (produces more) and a 1:1 (the same number either way). The single-substitution
branch had a guard against substituting a glyph to itself and the multiple branch never did; the span is the
fix that matters, because the guard would only have hidden one way to loop.

**Three versions of the main test were green against a broken build.** Worth writing down, because it is the
part that would have shipped:

1. Compare the first and last letter of a word. Proves nothing — a *different* letter in the same shape is
   still a different glyph.
2. Assert the two occurrences are merely *different*. Also proves nothing — a letter left as its base glyph
   differs from every shaped form, and removing `medi` leaves exactly that. Still green.
3. The test that holds: put **the same letter** in two positions (`سسل`), then assert each occurrence was
   substituted away from the base glyph **and** that the two are not the same form. That fails on a build
   with `medi` removed, naming the base glyph id.

A test that passes when the feature is removed is not testing the feature. Each version was checked by
removing the feature and watching it stay green, which is the only way to find out.

The `reshape` helper went with it. It applied one glyph at a time, so leaving it in place would shape a
letter per-glyph and then miss the run-level rule, because a shaped glyph is no longer in a coverage written
against base letters. `Font.shaped_glyph_index` stays, as a question, with its limits written down.

### ~~Should GSUB joining win over the cmap?~~ — tried, measured, and reverted 2026-10-04

**No, not yet, and the measurement is a picture rather than a number.**

The argument for preferring the font's own joining features is the one OpenType makes: they are written
against the base letters, the glyphs they select are the ones the font's own cursive and mark rules are
written against, and a cmap lookup of a presentation form bypasses all of it. The change was small — take
the presentation form only when no font in the chain has the four features — and it worked in the sense that
the routing moved: Amiri's shaped gids all changed, to the font's own, and Noto Naskh began expanding
letters into the several glyphs its rules ask for.

What it did not do was make the cursive rules reachable, which was the reason for trying it. Measured after
the change, over `سلام`:

| font | glyphs with a cursive anchor | adjacent exit+entry pairs |
| --- | --- | --- |
| Dubai | 0 | 0 |
| Amiri | 0 | 0 |
| NotoNaskhArabic | 0 | 0 |
| NotoNastaliqUrdu | 4 | 0 |

So the rules those fonts carry cover glyphs that are neither the presentation forms nor the joining
results. The preference bought nothing and cost the rendering:

- **Amiri** is visually identical either way, which is what a well-made font should be when asked to shape
  its own letters.
- **Noto Naskh Arabic is visibly broken.** `سلام دنیا` renders as mangled letters where it previously read
  correctly.

**And the cause was not the preference at all. It was the mask.** The mask restricted each joining feature to
the glyphs in its own shape, and a combining mark has no joining shape, so no mark took part in any of them.
Arabic joining features are also **mark composition**: a dot sits below the letter in one joining shape and
above it in another, so a font composes its marks differently per shape, through the very feature that names
the shape. Excluding marks left every dot in the composition meant for a different shape, and `سلام دنیا`
came out mangled. Fixing the mask — a mark takes part in every shape — makes Noto Naskh render correctly with
the preference in place. That is measured on the rendered image, not inferred.

So the preference was rejected on its own merits, not as the cause of the breakage:

| route | glyphs for `سلام دنیا` | width | dots | cursive anchors reached |
| --- | --- | --- | --- | --- |
| cmap presentation form | 9 | 186.2 px | correct | 0 |
| GSUB joining, mask fixed | 12 | 186.2 px | correct | 0 |

Same width, same rendering, **more glyphs**, and still no cursive rule reached. There is nothing to show for
it, so it is not in. What landed instead is the mask fix, which is a bug fix in its own right and which
Nastaliq needed before this was found.

One thing the attempt did settle, and the lam-alef depends on it: **the two routes are not interchangeable
for a ligature.** A shaped letter standing for two characters is a different question from one standing for a
single character, because the presentation form codepoint *is* the fusion — the cmap maps it to one glyph and
no rule is needed. Letting GSUB at it expands the pair back into two letters, and three layout and mark
attachment tests noticed the extra glyph at once. A ligature has to keep the cmap. Which is the order the
two mechanisms compose in: the shaper fuses what it recognises as one shape, the font shapes what it
recognises as one letter.

### ~~Why Noto Naskh names one SingleSubst lookup from init, medi and fina~~ — answered 2026-10-04

**It is a mark composition rule, and this engine's reader was right all along.** fontTools agrees with it
exactly: `init` names lookups [23, 4], `medi` names [24, 4], `fina` names [25], and lookup 4 is a SingleSubst
with eleven rules that all do the same thing:

```
dotcenterar               -> dotbelowar
twodotsverticalcenterar   -> twodotsverticalbelowar
fourdotscenterar          -> fourdotsbelowar
tahcenterar               -> tahbelowar
```

A dot-centred mark becomes a dot-below one. A font names that lookup from all three joining features because
the same mark has to be composed differently depending on the letter's joining shape, and nothing in
OpenType stops one lookup being named by several features. The reader read it correctly; the entry above was
a measurement that had not been interpreted yet.

The cost of not asking an independent reader first is now on record: two entries and one reverted change were
spent treating this as a parser mystery.

---


### Device and variation tables — measured before building, 2026-10-04

A GPOS value record can point at a table that says the value is different at a
different size. Skipping it means a kern is the same at every size, which is
wrong but not visibly so. Reading it is a matter of applying a table of
adjustments by pixels-per-em, and a variable font's version needs the variation
store.

**The reader for this was written and then thrown away, because the machine could no longer compile anything
and unbuilt code is worse than none.** What survived is the measurement and one real bug, which is the part
that would otherwise be paid for twice.

**How much is actually out there.** Scanning every GPOS value record in the 337 Windows fonts and the four in
`testdata/fonts/`, with fontTools:

| | |
| --- | --- |
| value records carrying a Device table | **1** |
| value records carrying a VariationIndex | **0** |

The single record is in `SitkaVF.ttf`. So the per-size half of this item is one record in one font, and the
variable-font half has no fixture on this machine at all. That is the answer to whether this is worth building
blind, and it is the reason it should not be.

**The first scan said zero across all 341 fonts, and that was wrong.** fontTools was opened with `lazy=True`,
which does not decompile subtables, so the walk over the lookup list never reached a single value record and
had nothing to find. Tahoma's GPOS holds **13,539** of them. A scanner that reports nothing everywhere is
indistinguishable from a scanner that is broken, so it needs a positive control: set the Device bit on one
real record and confirm the walk counts it. It does, and that is the only reason the 341-font number above can
be believed. **This is the same mistake as a fixture written to match the reader** — a measurement that
cannot fail is not a measurement — and it is the second time in this repository that a probe has needed
proving before its result was allowed to mean anything.

**The bug this found, which is worth fixing before anything else here.** `pair_value_size` decides how many
bytes a value record occupies so the reader can step to the next one, and it counted only
`0x0001 0x0002 0x0004 0x0008 0x0010 0x0020 0x0040 0x0080` — the four values, two placement device offsets and
two advance device offsets. The four **VariationIndex** offsets, `0x0100` `0x0200` `0x0400` `0x0800`, are
missing. A value record carrying one is therefore mis-stepped, and **every pair record after it is read from
the wrong place**. The read would land in the middle of a neighbouring record and produce plausible small
numbers, so nothing would look wrong.

No font here uses a VariationIndex, so nothing caught it. That is the honest reason it survived: not because
the case is unreachable, but because no available font exercises it. Adding the four bits is a one-line fix
and needs no font to be correct.

**What implementing it would take, for whoever does it with a machine that compiles.** A Device table is
`startSize`, `endSize`, `deltaFormat` and one delta per pixel size in four encodings — int16, uint16, int8,
uint8 — of which only the two placement offsets are worth reading, since this engine applies a kern as an
advance. `read_device` has to take the encoding from the table rather than infer it, and has to clamp the
stated count to the bytes actually present, because a table that overruns itself is read as far as it goes.
The size then has to reach the engine: `kern_offset` has no size parameter and changing its signature breaks
the API, so the shape is a `kern_offset_at(left, right, script, ppem)` with the old one delegating at ppem
zero, where zero means "no device adjustment" rather than "size zero". The adjustment is added in design
units, because everything this library returns is in design units and the caller scales once.

The variation half is a different and much larger piece of work than this entry suggests. `VariationIndex`
points into a delta-set index that adjusts a *value* along an axis, which is tractable; making the engine
honour a variable font's `gvar` outlines is not, and is a different feature with its own entry.

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

### The 19 copies of a font-path helper, and why the better answer was not taken

Done on 2026-10-13, and recorded because it is the one place in this repository where the right fix
was known, measured, and deliberately not taken.

`v test <single_file>` compiles that file and not its siblings. `tools/run_tests.v` invokes
`v test <name>` per file, because per-file invocation is what lets it report pass, fail, blocked and
skip counts per file rather than one number for the directory. So a shared `corpus_font_path`
helper in a neighbouring test file satisfies `v test .` and fails every run the runner makes.

Eighteen test files therefore each carry the same forty lines of resolution order
(`$VTEXT_TEST_FONTS`, `testdata/fonts`, then the platform directory last and only on Windows) and
the same `skip_missing`. That is duplication, and it is the price of the report the runner gives.

The better answer is to move the helpers into the module itself, where every test file sees them and
one copy serves all. It was not taken here because it moves code out of the test files into the
library's own sources, which is a different change with its own review, and a test-only helper
reaching into `vtext.v` is a worse arrangement than a duplicated block whose duplication has one
named cause.

The trigger for writing this down is the platform work on 2026-10-12/13, which made the suite run on
Linux and macOS for the first time and needed the helper everywhere at once. Before that, one file
carried a Windows path and the question had never arisen.

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

### ~~`tools/glyphdump`~~ — done 2026-10-04

Three modes, because they answer three questions. `--sheet` draws a grid of glyphs on one page on a
shared baseline, so a whole font can be eyeballed at once and two letters can be compared for sitting at
the same height. `--each DIR` writes one image per glyph sized to that glyph's own ink box, which is the
form to diff against another rasteriser. `--text STR` draws the run a string shapes into and tabulates
it: four characters becoming three glyphs, each naming the character it came from and the substitution
that replaced it.

Writing it needed one thing the library did not have, which is the other half of this entry: a glyph id
cannot be named without mapping it back to a character, and nothing in the public API did that.
`Font.codepoint_for` does now, returning the lowest codepoint that maps to the glyph.

That direction is a search, not a table, and the first version of it had a bug that the first test found:
V's `..` range is exclusive and a cmap segment is inclusive of its end, so every segment was losing its
last codepoint. It showed up as a letter answering with its presentation form instead of itself, which is
a plausible-looking wrong answer rather than a failure. The loops are written as explicit counters now,
with the reason in a comment.

### ~~`tools/subset`~~ — done 2026-10-10

```
v run tools/subset.v <font.ttf> --text "STRING" -o out.ttf [--file FILE] [--size N]
```

Verification always runs, and it is the point of the tool. The font it just wrote is loaded back, the
same string is shaped through it, and every glyph it kept is rasterized beside its original at three
sizes and two subpixel bins. A subset that shapes differently is an error, not a small success.

| font | text | chars → glyphs | bytes before → after | glyphs kept |
| --- | --- | --- | --- | --- |
| segoeui.ttf | `office ffi difficulty` | 21 → 21 | 959752 → 348168 | 37 of 5394 |
| tahoma.ttf | `The quick brown fox… Affluent flow office.` | 66 → 66 | 919260 → 311320 | 35 of 4498 |
| arial.ttf | `efficient staff off shelf flour chaff` | 37 → 37 | 1045720 → 371112 | 50 of 4651 |
| DUBAI-REGULAR.TTF | `لَآ أَهْلاً بِک` | 16 → 18 | 181484 → 110320 | 21 of 677 |
| Amiri-Regular.ttf | `بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ` | 14 → 14 | 437780 → 162072 | 36 of 6710 |
| NotoNaskhArabic-Regular.ttf | `سلام دنیا` | 9 → 8 | 291980 → 73092 | 18 of 1719 |
| NotoNastaliqUrdu-Regular.ttf | `سلام دنیا` | 9 → **18** | 176600 → 80036 | 47 of 977 |
| NotoNaskhArabic-Variable.ttf | `متن آزمایشی` | 11 → 13 | 253880 → 140768 | 22 of 1415 |
| cambria.ttc | `office ffi difficulty` | 21 → 21 | 1792664 → 495412 | 35 of 7614 |

Nastaliq is the number that carries the argument: 9 characters produce 18 glyphs through the
pipeline, so the per-character cmap walk this tool refuses to use would have kept 9 and dropped 9 the
run actually draws.

**Glyph ids are preserved rather than renumbered, and that is the whole of the design.** Renumbering
means rewriting every glyph id in cmap, hmtx, GSUB, GPOS and GDEF, and a wrong rewrite there is a font
that loads fine and draws the wrong letter. Preserving them means those five tables are copied byte for
byte and the only claim the tool makes is that the outlines it kept are the outlines it read. The
price is in the table: the saving is glyf, and the reduction is 2–4x rather than the 10–20x a full
renumbering subsetter would reach. `maxp.numGlyphs` is left alone for the same reason — lowering it
buys almost nothing while making every GSUB, GPOS and GDEF reference above the new count point at a
glyph the font no longer declares.

**Two things had to be right before the tool could be trusted, and both were found by reading the
output with a second reader rather than by the tool's own report.**

The closure has to run to a fixed point. Running the glyf pass and then the GSUB pass, in that order,
kept **0** glyphs from composite outlines on Segoe UI: every composite in that run arrived through a
substitution, so the pass that would have closed over it had already finished. Segoe UI's `i` is gid
3388, `glyph03315` plus `dotaccent`, and the subset that came out had the dotaccent reference intact
and its outline empty. The word drawn was a dotless i. Restoring the two passes into a loop that runs
until neither changes anything fixes it, and is the only ordering that cannot be wrong by accident.

The verification has to cover every glyph the tool kept, not only the ones the shaped run named. The
first version reported green on exactly that font, because gid 3388 is not in the run's own list — the
substitution closure added it — so nothing compared it. It now compares every kept glyph, and both
controls are worth recording: with the single-pass closure restored, the tool reports `gid 3388 at 16
pixels rasterizes differently` and refuses to write a font at all, which is the behaviour the roadmap
asked for. With the closure disabled entirely, it verifies on 12 glyphs and says nothing, which is
the check being vacuous and is why the closure is not what makes the tool correct.

**Independently checked, because the tool's own report is not evidence.** fontTools 4.66.1 reads
every subset above, agrees the glyph order is unchanged, and reports that no glyph has ink in a subset
it did not have in the original and that every glyph carrying ink carries identical coordinates. The
whole-file checksum is `0xB1B0AFBA` on all of them. One real bug was found that way before these were
written down: the checksum constant had been written in decimal, one digit out, producing fonts that
every reader loaded and drew correctly while summing to `0xB1B180F2`.

**Refused: CFF, untested.** There is no CFF or OpenType font on this machine, so the refusal path has
never run. The reason is in the message rather than left to the reader: this rebuilds `glyf` and
`loca`, and a charstring is a different language the library exposes no reader for. `gvar`, `hdmx`,
`LTSH` and friends are copied whole for the same reason, which is why NotoNaskhArabic-Variable's
subset is still 140768 bytes — 83204 of them `gvar` this cannot prune.

**Three API gaps it hit, none of them blocking.** There is no closure API in `inspect.v`, so the tool
walks `glyf` and the GSUB lookups itself over the raw bytes. `Font` exposes only `path()`, so the tool
reads the file a second time with `os.read_bytes(font.path())` — which means a `Font` built with
`load_font_bytes` cannot be subsetted at all, and a `Font.data()` is the single smallest addition that
would help. And `Font.codepoint_for` cannot name a glyph after subsetting, because the ids are not
contiguous.

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
