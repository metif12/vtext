module vtext

import vtext.shape
import vtext.font
// Class and glyph based contextual substitution: type 5 formats 2 and 3, type 6 formats 1 and 2.
//
// Format 3 on both sides matches through coverages and was read first; formats 1 and 2 of the
// chaining side and format 2 of the plain side match through glyph ids and glyph classes. No
// synthetic table can prove the reader against a font, so the parse is checked against built
// bytes here and against Amiri, which carries all four: lookup 55 is plain format 2, lookups
// 27 and friends are plain format 3, lookup 28 is chaining format 1, and lookup 66 is
// chaining format 2. The corpus asserts the ratchet: every record stays inside its pattern
// and names a lookup this engine can apply.
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

fn class_font(name string) ?&shape.Font {
	p := corpus_font_path(name) or {
		skip_missing(name)
		return none
	}
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
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

// context2_bytes builds one class-based plain subtable (type 5, format 2): coverage [10, 11],
// glyph 10 in class 1 and glyph 11 in class 2, an empty set for class 0, and one rule in the
// set for class 1 matching a class-2 glyph next and substituting input position 1 through
// lookup 7.
//
// The words are the hex dump: format, coverage offset, class offset, set count, set offsets,
// then the coverage, the class definition, the set, then the rule.
fn context2_bytes() []u8 {
	return bytes_of([2, 14, 22, 3, 0, 32, 0, 1, 2, 10, 11, 1, 10, 2, 1, 2, 1, 4, 2, 1, 2, 1, 7])
}

// chain1_bytes builds one glyph-based chaining subtable (type 6, format 1): coverage [10], one
// set with one rule matching backtrack [5], input [10, 20], lookahead [30], substituting input
// position 1 through lookup 7.
fn chain1_bytes() []u8 {
	return bytes_of([1, 8, 1, 14, 1, 1, 10, 1, 4, 1, 5, 2, 20, 1, 30, 1, 1, 7])
}

// chain2_bytes builds one class-based chaining subtable (type 6, format 2): coverage [10],
// glyph 5 in backtrack class 3, glyph 10 in input class 1 and glyph 11 in input class 2,
// glyph 30 in lookahead class 7, an empty set for class 0, and one rule in the set for
// class 1 matching backtrack class 3, input class 2, lookahead class 7, substituting input
// position 1 through lookup 7.
fn chain2_bytes() []u8 {
	return bytes_of([2, 16, 22, 30, 40, 2, 0, 48, 1, 1, 10, 1, 5, 1, 3, 1, 10, 2, 1, 2, 1, 30,
		1, 7, 1, 4, 1, 3, 2, 2, 1, 7, 1, 1, 7])
}

// context3_bytes builds one coverage-based plain subtable (type 5, format 3): two input
// coverages [10] and [20], substituting input position 1 through lookup 7.
//
// The substitution count comes before the coverage offsets, which is what makes this format
// different from the chaining one: format, input count, substitution count, offsets, records.
fn context3_bytes() []u8 {
	return bytes_of([3, 2, 1, 14, 20, 1, 7, 1, 1, 10, 1, 1, 20])
}

fn test_gsub_context2_parses_from_bytes() {
	r := font.new_reader(context2_bytes())
	c := font.parse_context2(r, 0) or { panic('a well-formed format 2 subtable should parse') }
	assert c.coverage.len == 2, 'two covered glyphs'
	assert c.sets.len == 3, 'one set per class value'
	assert c.sets[0].len == 0, 'a NULL set offset is an empty rule list'
	assert c.sets[1].len == 1, 'one rule in the covered first glyph class set'
	assert c.sets[2].len == 0, 'an uncovered class keeps its empty set'
	rule := c.sets[1][0]
	assert rule.input == [u16(2)], 'the input holds the classes after the covered first'
	assert rule.records.len == 1, 'one substitution record'
	assert rule.records[0].position == 1 && rule.records[0].lookup == 7, 'substituting the second input glyph through lookup 7'
	// A format that is not 2 is not this reader's, and a truncated subtable
	// ends the walk rather than reading past it.
	bad := bytes_of([1, 8, 1, 14, 1, 1, 10, 1, 4, 1, 5, 2, 20, 1, 1, 7])
	assert font.parse_context2(font.new_reader(bad), 0) == none, 'format 1 is another reader'
	assert font.parse_context2(font.new_reader(context2_bytes()[..6]), 0) == none, 'a cut header parses to nothing'
}

fn test_gsub_chain1_parses_from_bytes() {
	r := font.new_reader(chain1_bytes())
	c := font.parse_chain1(r, 0) or { panic('a well-formed format 1 subtable should parse') }
	assert c.coverage.len == 1, 'one coverage range'
	assert c.coverage[0].first == 10 && c.coverage[0].last == 10, 'covering glyph 10'
	assert c.sets.len == 1, 'one set for one covered glyph'
	assert c.sets[0].len == 1, 'one rule in the set'
	rule := c.sets[0][0]
	assert rule.backtrack == [u16(5)], 'backtrack names glyph 5'
	assert rule.input == [u16(20)], 'input holds the glyphs after the covered first'
	assert rule.lookahead == [u16(30)], 'lookahead names glyph 30'
	assert rule.records.len == 1, 'one substitution record'
	assert rule.records[0].position == 1 && rule.records[0].lookup == 7, 'substituting the second input glyph through lookup 7'
	bad := bytes_of([2, 8, 11, 15, 20, 2, 0, 24, 1, 1, 10, 1, 5, 1, 3])
	assert font.parse_chain1(font.new_reader(bad), 0) == none, 'format 2 is another reader'
	assert font.parse_chain1(font.new_reader(chain1_bytes()[..6]), 0) == none, 'a cut header parses to nothing'
}

fn test_gsub_chain2_parses_from_bytes() {
	r := font.new_reader(chain2_bytes())
	c := font.parse_chain2(r, 0) or { panic('a well-formed format 2 subtable should parse') }
	assert c.coverage.len == 1, 'one coverage range'
	assert c.sets.len == 2, 'one set per input class value'
	assert c.sets[0].len == 0, 'a NULL set offset is an empty rule list'
	assert c.sets[1].len == 1, 'one rule in the covered first glyph class set'
	rule := c.sets[1][0]
	assert rule.backtrack == [u16(3)], 'backtrack names class 3'
	assert rule.input == [u16(2)], 'input holds the classes after the covered first'
	assert rule.lookahead == [u16(7)], 'lookahead names class 7'
	assert rule.records.len == 1, 'one substitution record'
	assert rule.records[0].position == 1 && rule.records[0].lookup == 7, 'substituting the second input glyph through lookup 7'
	bad := bytes_of([1, 4, 1, 7, 1, 1, 10, 1, 2, 1, 5, 2, 20, 1, 30, 1, 1, 7])
	assert font.parse_chain2(font.new_reader(bad), 0) == none, 'format 1 is another reader'
	assert font.parse_chain2(font.new_reader(chain2_bytes()[..10]), 0) == none, 'a cut header parses to nothing'
}

fn test_gsub_context3_parses_from_bytes() {
	r := font.new_reader(context3_bytes())
	c := font.parse_context3(r, 0) or { panic('a well-formed format 3 subtable should parse') }
	assert c.input.len == 2, 'two input coverages'
	assert c.backtrack.len == 0 && c.lookahead.len == 0, 'a plain context has no backtrack or lookahead'
	assert c.records.len == 1, 'one substitution record'
	assert c.records[0].position == 1 && c.records[0].lookup == 7, 'substituting the second input glyph through lookup 7'
	// The count lives before the offsets here, so a reader that looks for it after them
	// walks into the next subtable. Amiri lookup 27 is that reader's control: its first
	// subtable carries a 60 where the offsets end, and the right answer is still 3 records.
	bad := bytes_of([1, 4, 1, 7, 1, 1, 10, 1, 2, 1, 5, 2, 20, 1, 30, 1, 1, 7])
	assert font.parse_context3(font.new_reader(bad), 0) == none, 'format 1 is another reader'
	assert font.parse_context3(font.new_reader(context3_bytes()[..6]), 0) == none, 'a cut header parses to nothing'
}

// ligatables_of wraps glyph ids the way the substitution walk sees them: plain base letters
// with no mark flag and no joining shape, so every glyph takes part in matching.
fn ligatables_of(gids []u16) []font.Ligatable {
	mut out := []font.Ligatable{cap: gids.len}
	for i, gid in gids {
		out << font.Ligatable{
			gid:     gid
			cluster: i
			source:  i
			form:    font.JoiningForm.isolated
			is_mark: false
		}
	}
	return out
}

fn test_gsub_context_class_rule_matches_by_class() {
	r := font.new_reader(context2_bytes())
	c := font.parse_context2(r, 0) or { panic('the built subtable should parse') }
	g := &font.Gsub{}
	items := ligatables_of([u16(10), u16(11)])
	eff := [0, 1]
	m, rule := g.match_context_class_at(&c, eff, items, 0) or {
		panic('the class pattern should match')
	}
	assert m.start == 0, 'the match starts at the covered first glyph'
	assert m.positions == [0, 1], 'both input glyphs are matched'
	assert rule.records.len == 1 && rule.records[0].lookup == 7, 'the matched rule carries its record'
	// A glyph whose class is not the rule's does not match, and neither does a run
	// that ends before the pattern does.
	plain := ligatables_of([u16(10), u16(10)])
	assert g.match_context_class_at(&c, [0, 1], plain, 0) == none, 'a class the rule does not name matches nothing'
	assert g.match_context_class_at(&c, [0], ligatables_of([u16(10)]), 0) == none, 'a run the pattern does not fit matches nothing'
}

fn test_gsub_chain_glyph_rule_matches_by_glyph() {
	r := font.new_reader(chain1_bytes())
	c := font.parse_chain1(r, 0) or { panic('the built subtable should parse') }
	g := &font.Gsub{}
	items := ligatables_of([u16(5), u16(10), u16(20), u16(30)])
	eff := [0, 1, 2, 3]
	m, rule := g.match_chain_glyph_at(&c, eff, items, 1) or {
		panic('the glyph pattern should match')
	}
	assert m.start == 1, 'the match starts at the covered first glyph'
	assert m.positions == [1, 2], 'the covered first plus the stored input glyph'
	assert rule.records.len == 1 && rule.records[0].lookup == 7, 'the matched rule carries its record'
	back := ligatables_of([u16(6), u16(10), u16(20), u16(30)])
	assert g.match_chain_glyph_at(&c, [0, 1, 2, 3], back, 1) == none, 'a backtrack the rule does not name matches nothing'
	ahead := ligatables_of([u16(5), u16(10), u16(20), u16(31)])
	assert g.match_chain_glyph_at(&c, [0, 1, 2, 3], ahead, 1) == none, 'a lookahead the rule does not name matches nothing'
}

fn test_gsub_chain_class_rule_matches_by_class() {
	r := font.new_reader(chain2_bytes())
	c := font.parse_chain2(r, 0) or { panic('the built subtable should parse') }
	g := &font.Gsub{}
	items := ligatables_of([u16(5), u16(10), u16(11), u16(30)])
	eff := [0, 1, 2, 3]
	m, rule := g.match_chain_class_at(&c, eff, items, 1) or {
		panic('the class pattern should match')
	}
	assert m.start == 1, 'the match starts at the covered first glyph'
	assert m.positions == [1, 2], 'the covered first plus the stored input glyph'
	assert rule.records.len == 1 && rule.records[0].lookup == 7, 'the matched rule carries its record'
	back := ligatables_of([u16(6), u16(10), u16(11), u16(30)])
	assert g.match_chain_class_at(&c, [0, 1, 2, 3], back, 1) == none, 'a backtrack class the rule does not name matches nothing'
	ahead := ligatables_of([u16(5), u16(10), u16(11), u16(31)])
	assert g.match_chain_class_at(&c, [0, 1, 2, 3], ahead, 1) == none, 'a lookahead class the rule does not name matches nothing'
}

// The numbers below are glyph ids measured in Amiri with fontTools, and the mappings are the
// single substitutions the records name: lookup 54 turns 1591 into 4031, lookup 65 turns 1817
// into 3378 and 1632 into 3396, lookup 24 turns 5439 into 5440.
fn test_gsub_class_context_applies_from_a_real_font() {
	f := class_font('Amiri-Regular.ttf') or { return }
	g := f.face.gsub or { panic('Amiri has no gsub') }
	// font.Lookup 55 is the plain format-2 rlig rule: a class-1 glyph, a class-2 mark, a class-3
	// glyph, substituting the first through the single lookup 54.
	mut items := ligatables_of([u16(1591), u16(40), u16(1781)])
	out := g.substitute_one(u16(55), mut items, none)
	assert out.len == 3, 'a single substitution keeps the run length'
	assert out[0].gid == 4031 && out[1].gid == 40 && out[2].gid == 1781, 'the first glyph substituted, got ${out[0].gid},${out[1].gid},${out[2].gid}'
}

fn test_gsub_class_chaining_applies_from_a_real_font() {
	f := class_font('Amiri-Regular.ttf') or { return }
	g := f.face.gsub or { panic('Amiri has no gsub') }
	// font.Lookup 66 is the class-based chaining rlig rule: an input class-2 glyph, an input
	// class-1 glyph, a lookahead class-1 glyph, substituting both inputs through lookup 65.
	mut items := ligatables_of([u16(1817), u16(1632), u16(1542)])
	out := g.substitute_one(u16(66), mut items, none)
	assert out.len == 3, 'two single substitutions keep the run length'
	assert out[0].gid == 3378 && out[1].gid == 3396 && out[2].gid == 1542, 'both inputs substituted, got ${out[0].gid},${out[1].gid},${out[2].gid}'
}

fn test_gsub_glyph_chaining_applies_from_a_real_font() {
	f := class_font('Amiri-Regular.ttf') or { return }
	g := f.face.gsub or { panic('Amiri has no gsub') }
	// font.Lookup 28 is the glyph-based chaining ccmp rule: uni0644 before glyph 54339, uni0627
	// after it, substituting the covered glyph through lookup 24.
	mut items := ligatables_of([u16(84), u16(5439), u16(55)])
	out := g.substitute_one(u16(28), mut items, none)
	assert out.len == 3, 'a single substitution keeps the run length'
	assert out[0].gid == 84 && out[1].gid == 5440 && out[2].gid == 55, 'the covered glyph substituted, got ${out[0].gid},${out[1].gid},${out[2].gid}'
}

// A record that applies to an input position the pattern does not have is a misread record,
// and a lookup it names outside the list is a misread offset. The corpus-wide version of this
// lives in gsub_test.v for the coverage forms; this one covers the three tables added here.
fn test_gsub_class_records_stay_inside_their_pattern() {
	f := class_font('Amiri-Regular.ttf') or { return }
	g := f.face.gsub or { panic('Amiri has no gsub') }
	for lookup in g.lookups {
		for cc in lookup.context_classes {
			for set in cc.sets {
				for rule in set {
					for record in rule.records {
						assert record.position <= rule.input.len, 'a record past the plain class pattern'
						assert int(record.lookup) < g.lookups.len, 'a record naming a lookup that does not exist'
						assert font.lookup_substitutes(g.lookups[record.lookup]), 'a record naming a lookup this engine cannot apply'
					}
				}
			}
		}
		for cg in lookup.chain_glyphs {
			for set in cg.sets {
				for rule in set {
					for record in rule.records {
						assert record.position <= rule.input.len, 'a record past the glyph pattern'
						assert int(record.lookup) < g.lookups.len, 'a record naming a lookup that does not exist'
						assert font.lookup_substitutes(g.lookups[record.lookup]), 'a record naming a lookup this engine cannot apply'
					}
				}
			}
		}
		for cc in lookup.chain_classes {
			for set in cc.sets {
				for rule in set {
					for record in rule.records {
						assert record.position <= rule.input.len, 'a record past the class pattern'
						assert int(record.lookup) < g.lookups.len, 'a record naming a lookup that does not exist'
						assert font.lookup_substitutes(g.lookups[record.lookup]), 'a record naming a lookup this engine cannot apply'
					}
				}
			}
		}
	}
}
