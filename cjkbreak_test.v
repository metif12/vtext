module harfara

import harfara.shape
import harfara.layout
import os

// Phase 9.1: CJK line breaking (UAX #14 ID/CJ/NS/OP/CL).
//
// The UAX #14 tail work already closed the ideograph rules — the whole
// LineBreakTest.txt scores 19,346/19,346 — so this file pins the CJK slice of
// it rather than landing a rule. What it proves, in order:
//
//  1. the pair pins: what each ID/CJ/NS/OP/CL pair around an ideograph does,
//     each against the committee's own case and tag;
//  2. the deltas: the ID class (1,753 cases) and the CJK subset
//     ID/CJ/NS/OP/CL (5,333 cases) both score zero failures;
//  3. the wrap pins: CJK text wrapped on the committed NotoSansSC face, with
//     every gid and advance read off HarfBuzz first (uharfbuzz 0.56.2, default
//     instance, scale 1000: 中 8805/1000, 文 14750/1000, 测 16732/1000,
//     试 24519/1000, 「 1152/1000, 」 1153/1000, 、 1141/1000, A 34/574,
//     B 35/632, C 36/619, D 37/661, a 66/536, b 67/593 — at 32 px an
//     ideograph is 32.0 and A is 18.368), and the engine agreeing exactly;
//  4. the break-fix control: a neutered oracle that holds every boundary
//     touching an ideograph moves the subset score by 951 cases (the file
//     wants a break touching an ideograph in 951 of the 5,333), so the delta
//     pins above are load-bearing rather than decorative. The same neuter
//     applied to the real engine costs 520 conformance cases, measured;
//     the oracle is the bound and the engine run is the proof.
//
// Self-contained: every helper here is this file's own, because `v test`
// compiles one file and not its neighbours.

// cjk_word builds a rune slice from codepoints. A backtick in V is one
// character, so a word cannot be written as a literal the way it can be in a
// test written in any other language.
fn cjk_word(cps ...int) []rune {
	mut out := []rune{cap: cps.len}
	for c in cps {
		out << rune(c)
	}
	return out
}

// cjk_starts_of is the break positions of a text as a sorted list, which is
// what every pair pin below is asked about.
fn cjk_starts_of(ctx &shape.Context, cps []rune) []int {
	mut out := []int{}
	for o in layout.break_opportunities(ctx, cps, true) {
		out << o.start
	}
	return out
}

// cjk_approx reports whether two pixel measurements agree to within tol.
// Advance widths come out of a scale from font units, so an exact compare is
// the wrong test.
fn cjk_approx(got f64, want f64, tol f64) bool {
	d := got - want
	return d > -tol && d < tol
}

// cjk_font_path is where a committed face is: the HARFARA_TEST_FONTS override
// first, then the corpus. NotoSansSC ships with the repo, so a miss is a
// failure rather than a skip.
fn cjk_font_path(name string) string {
	for d in [os.getenv('HARFARA_TEST_FONTS'), 'testdata/fonts'] {
		if d == '' {
			continue
		}
		p := os.join_path(d, name)
		if os.exists(p) {
			return p
		}
	}
	panic('${name} is committed under testdata/fonts and was not found')
}

// cjk_sc loads the CJK face the wrap pins are measured on.
fn cjk_sc() &shape.Font {
	return shape.load_font_file(cjk_font_path('NotoSansSC-Variable.ttf')) or {
		panic('NotoSansSC-Variable.ttf is not readable: ${err}')
	}
}

// The line break table names the classes the pair pins stand on, so the pins
// stand on the table rather than on a comment about it.
fn test_cjk_table_names_the_ideograph_classes() {
	ctx := shape.new_context()
	assert ctx.properties.line_break_of(rune(0x4E2D)) == .idas, 'U+4E2D is ID'
	assert ctx.properties.line_break_of(rune(0x231A)) == .idas, 'U+231A WATCH is ID'
	assert ctx.properties.line_break_of(rune(0x3041)) == .cj, 'U+3041 small kana is CJ'
	assert ctx.properties.line_break_of(rune(0x3005)) == .ns, 'U+3005 iteration mark is NS'
	assert ctx.properties.line_break_of(rune(0x300C)) == .op, 'U+300C is OP'
	assert ctx.properties.line_break_of(rune(0x3001)) == .cl, 'U+3001 ideographic comma is CL'
	assert ctx.properties.line_break_of(rune(0x300D)) == .cl, 'U+300D is CL'
}

// Two ideographs break between them. LB31, the permissive default at the end
// of the chain: nothing holds ID to ID, so a run of Han is one break per
// boundary. The committee's own case is `× 231A ÷ 231A ÷` [31.01].
fn test_cjk_two_ideographs_break() {
	ctx := shape.new_context()
	assert cjk_starts_of(ctx, cjk_word(0x231A, 0x231A)) == [1, 2], 'ID×ID parts'
	assert cjk_starts_of(ctx, cjk_word(0x4E2D, 0x6587)) == [1, 2], '中 文 parts'
}

// An ideograph breaks against a letter in both directions. Neither LB28's
// letter pairs nor LB30's open-punctuation rule names ID, so both fall
// through to the default.
fn test_cjk_ideograph_breaks_against_a_letter() {
	ctx := shape.new_context()
	assert cjk_starts_of(ctx, cjk_word(0x0041, 0x4E2D)) == [1, 2], 'AL×ID parts'
	assert cjk_starts_of(ctx, cjk_word(0x4E2D, 0x0041)) == [1, 2], 'ID×AL parts'
}

// An ideograph holds to a nonstarter after it and parts from one before it.
// `× 231A × 3005 ÷` is [21.04]: a line may not begin with NS, and ID is not
// otherwise held to anything. The other direction is the default break.
fn test_cjk_ideograph_holds_a_nonstarter_after_it() {
	ctx := shape.new_context()
	assert cjk_starts_of(ctx, cjk_word(0x231A, 0x3005)) == [2], 'ID×NS holds at [21.04]'
	assert cjk_starts_of(ctx, cjk_word(0x4E2D, 0x3005)) == [2], '中 holds 々 the same way'
	assert cjk_starts_of(ctx, cjk_word(0x3005, 0x4E2D)) == [1, 2], 'NS×ID still parts'
}

// An opening bracket holds the ideograph after it, unconditionally and across
// a space run. LB14 reads the bracket rather than the space, which is what
// keeps `× 300C × 0020 × ...` whole; the 223-case measurement is recorded on
// the rule.
fn test_cjk_open_bracket_holds_the_ideograph() {
	ctx := shape.new_context()
	assert cjk_starts_of(ctx, cjk_word(0x300C, 0x4E2D)) == [2], 'OP×ID holds at LB14'
	assert cjk_starts_of(ctx, cjk_word(0x300C, 0x0020, 0x4E2D)) == [3], 'the hold reads across the space run'
}

// ...while an ideograph breaks before a narrow open punctuation. LB30 covers
// AL, HL and NU on the left and nothing else, so `× 672C ÷ 0028 × ...` is
// [31.01] where `× 2757 × 0028 ÷` is [30.01]. An East Asian bracket is the
// other half: Wide, so `× 2757 ÷ 2329 ÷` breaks too, and both break here.
fn test_cjk_ideograph_breaks_before_a_narrow_open_bracket() {
	ctx := shape.new_context()
	assert cjk_starts_of(ctx, cjk_word(0x4E2D, 0x0028)) == [1, 2], 'ID×OP(narrow) parts at [31.01]'
}

// An ideograph holds to the closing punctuation after it and parts from one
// before it. `× 306F × 3001 ÷` is [13.02] on the comma — a line may not begin
// with CL — and the comma lets go of what precedes nothing else.
fn test_cjk_ideograph_holds_a_closing_comma() {
	ctx := shape.new_context()
	assert cjk_starts_of(ctx, cjk_word(0x4E2D, 0x3001)) == [2], 'ID×CL holds at [13.02]'
	assert cjk_starts_of(ctx, cjk_word(0x3001, 0x4E2D)) == [1, 2], 'CL×ID still parts'
}

// A close bracket holds to a nonstarter. LB16: `(CL | CP) SP* × NS`, which is
// the rule that makes `× 232A × 0020 × 3005 ÷` one unit.
fn test_cjk_close_bracket_holds_a_nonstarter() {
	ctx := shape.new_context()
	assert cjk_starts_of(ctx, cjk_word(0x3001, 0x3005)) == [2], 'CL×NS holds at LB16'
}

// A small kana is CJ and LB1 resolves it to NS, so it behaves as one in CJK
// text: held after an ideograph, holding a close bracket's LB16 the way a
// real nonstarter does.
fn test_cjk_small_kana_resolves_to_a_nonstarter() {
	ctx := shape.new_context()
	assert cjk_starts_of(ctx, cjk_word(0x4E2D, 0x3041)) == [2], 'ID×CJ holds like ID×NS'
	assert cjk_starts_of(ctx, cjk_word(0x007D, 0x3041)) == [2], 'CL×CJ holds at LB16 like CL×NS'
}

// cjk_hex_word reads four or more hex digits as a number, which is how the
// conformance file writes a codepoint.
fn cjk_hex_word(w string) int {
	mut v := 0
	for ch in w {
		mut d := ch - `0`
		if d > 9 {
			d = ch - `a` + 10
		}
		if d > 15 {
			d = ch - `A` + 10
		}
		v = v * 16 + int(d)
	}
	return v
}

// cjk_parse_case reads one line of the conformance file up to its comment and
// returns the codepoints and the break decisions. Decision i is the break
// before character i, and the last one is the break at the end of the string.
fn cjk_parse_case(line string) ([]rune, []bool) {
	mut cps := []rune{}
	mut breaks := []bool{}
	for f in line.all_before('#').fields() {
		if f == '÷' || f == '×' {
			breaks << (f == '÷')
		} else {
			cps << rune(cjk_hex_word(f))
		}
	}
	return cps, breaks
}

// cjk_in_subset reports whether cp is one of the classes this slice owns:
// ID, CJ, NS, OP or CL, read raw rather than resolved, because the resolution
// (CJ to NS) is itself what is being pinned.
fn cjk_in_subset(ctx &shape.Context, cp rune) bool {
	c := ctx.properties.line_break_of(cp)
	return c == .idas || c == .cj || c == .ns || c == .op || c == .cl
}

// cjk_score_subset runs the conformance file and scores the CJK slice of it:
// every case touching ID/CJ/NS/OP/CL, or only the ones touching ID when
// id_only is set. With neuter set, every allowed break with an ideograph on
// either side is held first, which is the break-fix control's simulation of
// the ID rules being deleted.
fn cjk_score_subset(ctx &shape.Context, id_only bool, neuter bool) (int, int) {
	path := os.join_path('ucd', 'LineBreakTest.txt')
	content := os.read_file(path) or { panic('no ${path}; the UCD data is committed') }
	mut total := 0
	mut passed := 0
	mut first_failures := []string{}
	for line in content.split('\n') {
		t := line.trim_space()
		if t == '' || t.starts_with('#') {
			continue
		}
		cps, want := cjk_parse_case(t)
		if cps.len == 0 {
			continue
		}
		mut touches := false
		for cp in cps {
			if id_only {
				if ctx.properties.line_break_of(cp) == .idas {
					touches = true
					break
				}
			} else if cjk_in_subset(ctx, cp) {
				touches = true
				break
			}
		}
		if !touches {
			continue
		}
		total++
		mut at := map[int]bool{}
		for g in layout.break_opportunities(ctx, cps, false) {
			at[g.start] = true
		}
		if neuter {
			for i in 1 .. cps.len {
				if at[i] {
					lc := ctx.properties.line_break_of(cps[i - 1])
					rc := ctx.properties.line_break_of(cps[i])
					if lc == .idas || rc == .idas {
						at.delete(i)
					}
				}
			}
		}
		mut ok := true
		for i, w in want {
			if w != at[i] {
				ok = false
				if first_failures.len < 6 {
					first_failures << '${t.all_before('#').trim_space()} at ${i}'
				}
				break
			}
		}
		if ok {
			passed++
		}
	}
	if first_failures.len > 0 {
		println('first CJK failures: ${first_failures}')
	}
	return passed, total
}

// The ID-class delta is zero: every conformance case touching an ideograph
// agrees with the engine. 1,753 cases, and the guard keeps the pin from
// passing on an empty slice.
fn test_cjk_id_class_delta_is_zero() {
	ctx := shape.new_context()
	passed, total := cjk_score_subset(ctx, true, false)
	println('CJK ID conformance: ${passed}/${total}')
	assert total > 1500, 'the ID slice was read, got ${total} cases'
	assert passed == total, 'ID-class delta must be zero: ${passed} of ${total}'
}

// The CJK-subset delta is zero: ID, CJ, NS, OP and CL together, 5,333 cases.
fn test_cjk_subset_delta_is_zero() {
	ctx := shape.new_context()
	passed, total := cjk_score_subset(ctx, false, false)
	println('CJK subset conformance: ${passed}/${total}')
	assert total > 5000, 'the CJK slice was read, got ${total} cases'
	assert passed == total, 'CJK-subset delta must be zero: ${passed} of ${total}'
}

// The engine shapes CJK the way HarfBuzz does, on the committed SC face at
// 32 px. Every number below was read off uharfbuzz first (default instance,
// scale 1000) and the engine agrees exactly: 全角 1000 units is 32.0 px,
// A is 574 units is 18.368 px.
fn test_cjk_sc_shaping_matches_harfbuzz() {
	f := cjk_sc()
	assert f.units_per_em() == 1000, 'SC is a 1000-upm face'
	assert f.glyph_index(rune(0x4E2D)) == 8805, 'U+4E2D is gid 8805'
	assert f.glyph_index(rune(0x6587)) == 14750, 'U+6587 is gid 14750'
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	line := layout.layout_paragraph(ctx, '中文'.runes(), .ltr, fs, 32.0)
	assert line.glyphs.len == 2, 'two characters draw two glyphs, got ${line.glyphs.len}'
	assert line.glyphs[0].gid == 8805 && line.glyphs[1].gid == 14750, 'the HarfBuzz gids'
	assert line.glyphs[0].cluster == 0 && line.glyphs[1].cluster == 1, 'in logical order'
	assert cjk_approx(line.glyphs[0].advance, 32.0, 0.001), '全角 advance, got ${line.glyphs[0].advance}'
	assert cjk_approx(line.glyphs[1].advance, 32.0, 0.001), '全角 advance, got ${line.glyphs[1].advance}'
	assert cjk_approx(line.glyphs[1].x, 32.0, 0.001), 'the second glyph starts where the first ends'
	assert cjk_approx(line.width, 64.0, 0.001), 'the line is two ideographs wide, got ${line.width}'
	for g in line.glyphs {
		assert g.gid != 0, 'no .notdef in a covered CJK line'
	}
}

// Mixed Latin and CJK, beside HarfBuzz: A 34/18.368, B 35/20.224,
// 中 8805/32.0, 文 14750/32.0, C 36/19.808, D 37/21.152 at 32 px.
fn test_cjk_sc_mixed_shaping_matches_harfbuzz() {
	f := cjk_sc()
	ctx := shape.new_context()
	fs := shape.new_font_set_of(f)
	line := layout.layout_paragraph(ctx, 'AB中文CD'.runes(), .ltr, fs, 32.0)
	assert line.glyphs.len == 6, 'six characters draw six glyphs, got ${line.glyphs.len}'
	want_gids := [34, 35, 8805, 14750, 36, 37]
	want_advs := [18.368, 20.224, 32.0, 32.0, 19.808, 21.152]
	for i in 0 .. 6 {
		assert line.glyphs[i].gid == want_gids[i], 'glyph ${i} is ${want_gids[i]}, got ${line.glyphs[i].gid}'
		assert cjk_approx(line.glyphs[i].advance, want_advs[i], 0.001), 'glyph ${i} advances ${want_advs[i]}, got ${line.glyphs[i].advance}'
		assert line.glyphs[i].cluster == i, 'glyph ${i} reports its own character'
	}
	assert cjk_approx(line.width, 143.552, 0.01), 'the line is its advances, got ${line.width}'
}

// Four ideographs at two全角 wide wrap as two and two: every ID×ID boundary
// is a break, so the wrap is decided by the measure and nothing else.
fn test_cjk_wrap_breaks_between_ideographs() {
	ctx := shape.new_context()
	fs := shape.new_font_set_of(cjk_sc())
	cps := '中文测试'.runes()
	lines := layout.wrap_paragraph(ctx, cps, .ltr, fs, 32.0, 64.0)
	assert lines.len == 2, 'two and two, got ${lines.len}'
	assert lines[0].from == 0 && lines[0].to == 2, 'the first line holds 中文'
	assert lines[1].from == 2 && lines[1].to == 4, 'and the second 测试'
}

// Mixed text wraps at the same breaks the pair pins name: AB holds (LB28),
// then every CJK boundary parts, so at 64 px the lines are AB, 中文, CD.
fn test_cjk_wrap_mixed_latin_and_cjk() {
	ctx := shape.new_context()
	fs := shape.new_font_set_of(cjk_sc())
	cps := 'AB中文CD'.runes()
	lines := layout.wrap_paragraph(ctx, cps, .ltr, fs, 32.0, 64.0)
	assert lines.len == 3, 'AB / 中文 / CD, got ${lines.len}'
	assert lines[0].from == 0 && lines[0].to == 2, 'the Latin pair holds'
	assert lines[1].from == 2 && lines[1].to == 4, 'the ideographs pair'
	assert lines[2].from == 4 && lines[2].to == 6, 'and the trailing Latin pair'
}

// At one全角 wide every ideograph stands alone: the narrowest width is one
// character, not zero, and the widest is the whole run.
fn test_cjk_wrap_at_one_ideograph_wide() {
	ctx := shape.new_context()
	fs := shape.new_font_set_of(cjk_sc())
	cps := '中文'.runes()
	lines := layout.wrap_paragraph(ctx, cps, .ltr, fs, 32.0, 32.0)
	assert lines.len == 2, 'one ideograph per line, got ${lines.len}'
	assert lines[0].from == 0 && lines[0].to == 1
	assert lines[1].from == 1 && lines[1].to == 2
}

// An ideographic comma holds to the letter before it, so a line too narrow
// for `a、` carries both over rather than stranding the punctuation: the
// first line overflows whole instead of splitting the pair.
fn test_cjk_wrap_holds_a_comma_to_its_letter() {
	ctx := shape.new_context()
	fs := shape.new_font_set_of(cjk_sc())
	cps := 'a、b'.runes()
	assert cjk_starts_of(ctx, cps) == [2, 3], 'AL×CL holds, CL×AL parts'
	lines := layout.wrap_paragraph(ctx, cps, .ltr, fs, 32.0, 32.0)
	assert lines.len == 2, 'two lines, got ${lines.len}'
	assert lines[0].from == 0 && lines[0].to == 2, 'a、 overflows whole'
	assert lines[1].from == 2 && lines[1].to == 3, 'and b follows'
}

// Break-fix control: neutering the ID rules must move the subset score.
//
// The oracle holds every allowed break with an ideograph on either side —
// the shape of deleting LB31's ID coverage — and rescores the same 5,333
// cases. The file wants a break touching an ideograph in 951 of them, so a
// suite that stayed green under the neuter would be proving nothing. The
// threshold is a floor with margin rather than the exact 951, the way the
// suite-wide floor is.
fn test_cjk_conformance_needs_id_breaks() {
	ctx := shape.new_context()
	assert cjk_starts_of(ctx, cjk_word(0x4E2D, 0x6587)) == [1, 2], 'the control: two ideographs part'
	mut at := map[int]bool{}
	for o in layout.break_opportunities(ctx, cjk_word(0x4E2D, 0x6587), false) {
		at[o.start] = true
	}
	at.delete(1)
	assert 1 !in at, 'the neutered oracle holds them instead'
	passed, total := cjk_score_subset(ctx, false, true)
	println('CJK subset conformance without ID breaks: ${passed}/${total}')
	assert total > 5000, 'the CJK slice was read, got ${total} cases'
	assert total - passed >= 900, 'neutering the ID rules must move the score: ${passed}/${total}'
}
