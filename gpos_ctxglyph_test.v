module vtext

// Chaining-context positioning through glyph ids (format 1).
//
// Formats 2 and 3 match through classes and coverages; format 1 matches the
// same three sequences as glyph ids, with one rule list per covered first
// glyph. No corpus font writes it, so the parse is checked against bytes
// built here and against LeelawUI, a Windows Malayalam face that does, and
// the corpus asserts the ratchet: nothing in it fires yet.
import os

// corpus_font_path is where a named font is: the committed corpus first, this platform's font directory
// second, and none when neither has it.
//
// The corpus is first because a test that runs only because one machine ships a font is a test about that
// machine, and everything asserted here is a structural property of a parsed table rather than a number
// out of one file. VTEXT_TEST_FONTS overrides both.
fn corpus_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('VTEXT_TEST_FONTS'), 'testdata/fonts', windows_font_dir()] {
		if d != '' && d !in dirs {
			dirs << d
		}
	}
	for dir in dirs {
		p := os.join_path(dir, name)
		if os.exists(p) {
			return p
		}
	}
	return none
}

$if windows {
	fn windows_font_dir() string {
		return 'C:\\Windows\\Fonts'
	}
} $else {
	fn windows_font_dir() string {
		return ''
	}
}

// skip_missing records why a test cannot run. A skip that prints nothing is a failure pretending to be a
// pass, so every one of them names the font it wanted and where it looked, and it is written to the file
// tools/run_tests.v names in VTEXT_SKIP_LOG rather than to stdout.
fn skip_missing(name string) {
	line := 'SKIP ${name} is in neither testdata/fonts nor the platform font directory'
	path := os.getenv('VTEXT_SKIP_LOG')
	if path != '' {
		mut f := os.open_append(path) or { return }
		f.writeln(line) or { return }
		f.close()
		return
	}
	println(line)
}

fn ctx_font(name string) ?&Font {
	p := corpus_font_path(name) or {
		skip_missing(name)
		return none
	}
	return load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

// bytes_of turns a list of sixteen bit words into the bytes a font stores, in the
// gpos_cursive_test.v convention. Local to this file because one test file never
// sees another's helpers: the runner builds each file on its own.
fn bytes_of(words []int) []u8 {
	mut b := []u8{len: words.len * 2}
	for i, w in words {
		b[i * 2] = u8((w >> 8) & 0xff)
		b[i * 2 + 1] = u8(w & 0xff)
	}
	return b
}

// chain_glyph_bytes builds one format-1 subtable: coverage [10], one set with one rule
// matching backtrack [5], input [10, 20], lookahead [30], positioning input position 1
// through lookup 7.
//
// The words are the hex dump: format, coverage offset, set count, set offset, then the
// coverage (format, count, glyph), the set (rule count, rule offset), then the rule.
fn chain_glyph_bytes() []u8 {
	return bytes_of([1, 8, 1, 14, 1, 1, 10, 1, 4, 1, 5, 2, 20, 1, 30, 1, 1, 7])
}

fn test_gpos_chain_glyph_parses_from_bytes() {
	r := new_reader(chain_glyph_bytes())
	c := parse_chain_glyph(r, 0) or { panic('a well-formed format 1 subtable should parse') }
	assert c.coverage.len == 1, 'one coverage range'
	assert c.coverage[0].first == 10 && c.coverage[0].last == 10, 'covering glyph 10'
	assert c.sets.len == 1, 'one set for one covered glyph'
	assert c.sets[0].len == 1, 'one rule in the set'
	rule := c.sets[0][0]
	assert rule.backtrack == [u16(5)], 'backtrack names glyph 5'
	assert rule.input == [u16(20)], 'input holds the glyphs after the covered first'
	assert rule.lookahead == [u16(30)], 'lookahead names glyph 30'
	assert rule.records.len == 1, 'one positioning record'
	assert rule.records[0].position == 1, 'positioning the second input glyph'
	assert rule.records[0].lookup == 7, 'through lookup 7'
	// A subtable that is not format 1 is not this reader's, and a truncated one
	// ends the walk rather than reading past it.
	bad := bytes_of([3, 8, 1, 14, 1, 1, 10, 1, 4, 1, 5, 2, 20, 1, 30, 1, 1, 7])
	assert parse_chain_glyph(new_reader(bad), 0) == none, 'format 3 is the coverage reader'
	assert parse_chain_glyph(new_reader(chain_glyph_bytes()[..6]), 0) == none, 'a cut header parses to nothing'
}

fn test_gpos_chain_glyph_rule_matches_by_glyph() {
	g := &Gpos{}
	cg := ChainGlyph1{
		coverage: [CoverageRange{ first: 10, last: 10 }]
		sets:     [[ChainGlyphRule{
			backtrack: [u16(5)]
			input:     [u16(20)]
			lookahead: [u16(30)]
			records:   [ContextRecord{ position: 1, lookup: 7 }]
		}]]
	}
	m, rule := g.match_chain_glyph_at(&cg, [u16(5), u16(10), u16(20), u16(30)], 1) or {
		panic('the glyph pattern should match')
	}
	assert m.start == 1, 'the match starts at the covered glyph'
	assert m.positions == [1, 2], 'both input glyphs are reported'
	assert rule.lookahead == [u16(30)], 'the returned rule is the one that matched'
	// A wrong glyph anywhere in the three sequences is no match, and a run cut
	// short of the lookahead is one too.
	assert g.match_chain_glyph_at(&cg, [u16(5), u16(10), u16(21), u16(30)], 1) == none, 'a wrong input glyph misses'
	assert g.match_chain_glyph_at(&cg, [u16(6), u16(10), u16(20), u16(30)], 1) == none, 'a wrong backtrack glyph misses'
	assert g.match_chain_glyph_at(&cg, [u16(5), u16(10), u16(20)], 1) == none, 'a cut lookahead misses'
	assert g.match_chain_glyph_at(&cg, [u16(5), u16(10), u16(20), u16(30)], 0) == none, 'an uncovered first glyph starts nothing'
}

// The rule applied end to end through the lookup machinery: a synthetic lookup 0
// names the match and lookup 1 moves the second input glyph left by 50, both under
// a kern feature so the pair path reaches them.
fn test_gpos_chain_glyph_applies_through_a_lookup() {
	g := &Gpos{
		lookups: [GposLookup{
			kind:         gpos_lookup_chain_context
			chain_glyphs: [ChainGlyph1{
				coverage: [CoverageRange{ first: 10, last: 10 }]
				sets:     [[ChainGlyphRule{
					backtrack: [u16(5)]
					input:     [u16(20)]
					lookahead: [u16(30)]
					records:   [ContextRecord{ position: 1, lookup: 1 }]
				}]]
			}]
		}, GposLookup{
			kind:    gpos_lookup_single_position
			singles: [SinglePos{
				ranges: [CoverageRange{ first: 20, last: 20 }]
				format: 1
				values: [PairValue{ format: 1, x_placement: -50 }]
			}]
		}]
		scripts: [Script{
			tag:      'latn'
			features: [ScriptFeature{ tag: 'kern', lookups: [u16(0)] }]
		}]
	}
	gids := [u16(5), u16(10), u16(20), u16(30)]
	apps := g.apply_contextual(gids, 'latn')
	assert apps.len == 1, 'one application, got ${apps.len}'
	assert apps[0].at == 2, 'moving the second input glyph'
	assert apps[0].lookup == 1, 'through the lookup the record names'
	off := g.context_offset(gids, 1, 2, 'latn') or { panic('the pair should place contextually') }
	assert off.x == -50 && off.y == 0, 'the single positioning moved it, got ${off}'
	assert g.context_offset([u16(5), u16(10), u16(21), u16(30)], 1, 2, 'latn') == none, 'a run the rule does not match places nothing'
}

// LeelawUI, a Windows Malayalam face, is the font that proves the reader against
// something other than built bytes: lookup 13 carries format-1 chaining under its
// own script, with dozens of rules shaped like backtrack, covered glyph, lookahead.
fn test_gpos_chain_glyph_parsed_from_a_real_font() {
	f := ctx_font('LeelawUI.ttf') or { return }
	gpos := f.face.gpos or { panic('LeelawUI has no GPOS') }
	mut rules := 0
	for lk in gpos.lookups {
		for cg in lk.chain_glyphs {
			assert cg.coverage.len > 0, 'a rule with no covered first glyph matches nothing'
			for set in cg.sets {
				for rule in set {
					rules++
					// Positions index into the covered first plus the stored input glyphs,
					// so the last valid position is the input count itself.
					for rec in rule.records {
						assert rec.position <= rule.input.len, 'position past the pattern'
						assert int(rec.lookup) < gpos.lookups.len, 'lookup past the list'
					}
				}
			}
		}
	}
	assert rules > 0, 'LeelawUI should carry format-1 chaining rules'
}

// The ratchet: no corpus font writes a format-1 chaining subtable, so the reader
// firing on one is a font the corpus does not have yet. A font that gains one
// fails here deliberately, naming the font to record.
fn test_gpos_chain_glyph_fires_on_nothing_in_the_corpus() {
	for name in ['Amiri-Regular.ttf', 'NotoNaskhArabic-Regular.ttf', 'NotoNastaliqUrdu-Regular.ttf',
		'NotoNaskhArabic-Variable.ttf'] {
		f := ctx_font(name) or { return }
		gpos := f.face.gpos or { continue }
		for lk in gpos.lookups {
			assert !has_chain_glyphs(lk), '${name} grew a format-1 chaining rule'
		}
	}
}
