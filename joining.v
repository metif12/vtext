module vtext

// Arabic joining, the shaping pass that gives each letter the shape it takes in its
// surroundings.
//
// This is the algorithm of UAX#53 in its presentation form form: a letter's shape
// depends on whether it connects to the letter before it and to the letter after it, and
// there are four shapes to choose between. The codepoints those shapes map to come from
// the Unicode presentation forms.
//
// The output is shaped codepoints, not glyph indices. Mapping them to glyphs is the font
// layer's job, because the codepoint is what a font's cmap and its OpenType tables both
// key on.
//
// The presentation forms are only half the story, and a shaped glyph therefore carries two
// things: the form codepoint, and the base characters it was made from. A font that carries
// the forms maps the codepoint directly, but most modern Arabic fonts do not: they carry the
// base letters and put the four shapes in a GSUB table, so the form codepoint is .notdef
// there. Keeping the base characters lets the font layer draw the letter anyway, and keeping
// the form lets it hand the right shape to the OpenType pass afterwards.

// JoiningForm is one of the four shapes a letter can take. The ordinals have to match the
// generated arabic_form_names table.
pub enum JoiningForm {
	isolated = 0
	final    = 1
	initial  = 2
	medial   = 3
}

// The two controls that override what the letters around them would otherwise do.
const zero_width_non_joiner = rune(0x200C)
const zero_width_joiner = rune(0x200D)

// ShapedGlyph is one letter after joining, and the characters it stands for.
pub struct ShapedGlyph {
pub:
	// cps is the presentation form, or the base character when the UCD has no
	// presentation form for this shape. It is one codepoint, except for a lam-alef
	// ligature.
	cps []rune
	// base is the character or characters cps was made from, unchanged. It is what the
	// font layer draws when no font carries cps, which is the usual case for a font that
	// keeps its shapes in a GSUB table rather than in the cmap.
	base []rune
	// form is the shape the joining algorithm chose. It is meaningful even when neither
	// cps nor base can be drawn as itself, because a caller driving a font's positional
	// feature table needs to know the shape rather than the codepoint.
	form JoiningForm
	// script is the script tag of the letter, which is what selects the script a font
	// resolves its positional features under. A font may offer 'fina' for more than one
	// script, and the rules differ.
	script string
	// start and end index the run of input characters this glyph covers, which is more
	// than one for a lam-alef ligature.
	start int
	end   int
	// is_mark marks a combining mark. A mark is drawn at the position of the letter it
	// follows and adds no advance of its own, so the layout pass has to know which
	// glyphs to place without moving the pen and to draw last so they land on top.
	is_mark bool
}

// ShapedRun is a whole run of text after joining, in logical order. Reordering it is the
// bidirectional pass's job, not this one's.
pub struct ShapedRun {
pub mut:
	glyphs []ShapedGlyph
}

// Shaper holds the presentation form tables. Like the normalizer it is immutable once
// built and shared.
pub struct Shaper {
pub:
	// forms maps a base codepoint and a shape to a presentation form, sorted by
	// codepoint then shape.
	forms []FormEntry
	// ligatures maps a lam and an alef to a ligature form, sorted by the pair then the
	// shape.
	ligatures []LigatureEntry
}

// FormEntry is one presentation form of a single codepoint.
pub struct FormEntry {
pub:
	cp    u32
	form  u16
	glyph u32
}

// LigatureEntry is one presentation form of a lam followed by an alef.
pub struct LigatureEntry {
pub:
	first  u32
	second u32
	form   u16
	glyph  u32
}

// new_shaper decodes the generated tables.
pub fn new_shaper() &Shaper {
	return &Shaper{
		forms:     parse_form_entries(arabic_form_map_data)
		ligatures: parse_ligature_entries(arabic_ligature_map_data)
	}
}

// shape_arabic runs the joining algorithm over a run of text in logical order and returns
// the shaped glyphs in the same order. Reordering the result is the bidirectional pass's
// job, not this one's.
//
// The text is expected to be canonically decomposed first: the algorithm keys on
// joining types, and a precomposed character is a different codepoint with a different
// one.
pub fn (s &Shaper) shape_arabic(p &Properties, cps []rune) ShapedRun {
	mut out := ShapedRun{ glyphs: []ShapedGlyph{cap: cps.len} }
	if cps.len == 0 {
		return out
	}

	// The decision for a letter needs the nearest non-transparent letter on each side,
	// since combining marks are transparent for joining: they attach to the letter they
	// follow without coming between it and the next letter.
	//
	// ZWNJ and ZWJ are not transparent. ZWNJ breaks the join, and ZWJ forces one, so
	// both have to be seen by the scan.
	mut join_prev := []bool{len: cps.len, init: false}
	mut join_next := []bool{len: cps.len, init: false}
	compute_joins(p, cps, mut join_prev, mut join_next)

	mut i := 0
	for i < cps.len {
		cp := cps[i]
		jt := p.joining_type_of(cp)
		// A lam followed by an alef is one glyph, not two.
		//
		// The ligature's shape comes from the join on the lam's own left, which is the
		// only side the pair can connect on: the alef is right joining, so it takes no
		// join of its own and the pair is never medial. That is why the form is asked
		// for from the lam's join alone rather than from a pair of them.
		if cp == 0x0644 && i + 1 < cps.len && p.joining_type_of(cps[i + 1]) == .r {
			form := if join_prev[i] { JoiningForm.final } else { JoiningForm.isolated }
			glyph := s.find_ligature(0x0644, u32(cps[i + 1]), u16(form))
			if glyph != 0 {
				// The ligature is drawn as one glyph, but it sits where the lam was, and
				// the lam was free to connect to the letter on its other side. That join
				// has to be carried over to whatever follows the alef, or the word would
				// break at the ligature. This is what lets a lam-alef sit in the middle
				// of a word rather than only at its edges.
				propagate_past_ligature(p, cps, i, mut join_prev, mut join_next)
				// The pair covers the lam and the alef. Any mark after the alef belongs to
				// the ligature, and becomes a glyph of its own.
				out.glyphs << ShapedGlyph{
					cps:    [rune(glyph)]
					base:   [cps[i], cps[i + 1]]
					form:   form
					script: p.script_tag_of(cps[i])
					start:  i
					end:    i + 2
				}
				i = attach_marks(p, cps, i + 2, mut out)
				continue
			}
		}

		// A non-joiner is a control rather than a character: it holds a connection
		// open by preventing one, and it is never drawn. It is dropped from the run
		// entirely, and the letters it sat between keep their own shapes.
		if cp == zero_width_non_joiner {
			i++
			continue
		}

		// Anything else that cannot connect to either side is passed through as itself:
		// a space, a mark on its own, a letter that is not part of a word. A mark that
		// lands here has no letter to attach to, so it is still positioned as one.
		if !jt.takes_a_shape() {
			out.glyphs << ShapedGlyph{
				cps:     [cp]
				base:    [cp]
				form:    .isolated
				script:  p.script_tag_of(cp)
				start:   i
				end:     i + 1
				is_mark: p.combining_class_of(cp) != 0
			}
			i++
			continue
		}

		form := form_for(join_prev[i], join_next[i])
		// The lam of a lam-alef pair that had no ligature form still needs a shape, and
		// so does a tatweel, which is a join causing character rather than a letter.
		form_cp := s.find_form(cp, u16(form))
		out.glyphs << ShapedGlyph{
			cps:    if form_cp != 0 { [rune(form_cp)] } else { [cp] }
			base:   [cp]
			form:   form
			script: p.script_tag_of(cp)
			start:  i
			end:    i + 1
		}
		i = attach_marks(p, cps, i + 1, mut out)
	}
	return out
}

// attach_marks appends the combining marks that follow position from as glyphs of their own
// and returns the index just past them.
//
// A mark is its own glyph rather than part of the letter's, because it is its own
// codepoint and has to reach the font's cmap: a letter's glyph can only name one
// codepoint, so a mark folded into it would be lost at the font lookup and never drawn.
// The mark still costs no advance and still sits where the letter is, so the layout pass
// places it from is_mark.
fn attach_marks(p &Properties, cps []rune, from int, mut out &ShapedRun) int {
	mut i := from
	for i < cps.len {
		// Transparent is the joining type that covers a mark, and it is what decided
		// where the letter's run of characters stopped, so the two agree on the boundary.
		if !p.joining_type_of(cps[i]).is_transparent() {
			break
		}
		// A transparent character with no combining class is an invisible format
		// character such as ZWSP. It belongs to the letter it follows and is not
		// drawn at all, so it gets no glyph.
		if p.combining_class_of(cps[i]) != 0 {
			out.glyphs << ShapedGlyph{
				cps:     [cps[i]]
				base:    [cps[i]]
				form:    .isolated
				script:  p.script_tag_of(cps[i])
				start:   i
				end:     i + 1
				is_mark: true
			}
		}
		i++
	}
	return i
}

// propagate_past_ligature carries the lam's forward join onto the letter after the alef.
//
// The alef is right joining, so it never connects to the letter that follows it, and
// the join the lam would have made to that letter is lost when the two are drawn as one
// glyph. Handing it on is what keeps a lam-alef in the middle of a word connected to what
// comes after it.
fn propagate_past_ligature(p &Properties, cps []rune, lam_at int, mut join_prev []bool,
	mut join_next []bool) {
	// A join the lam could not make in the first place carries nothing forward.
	if !join_next[lam_at] {
		return
	}
	after := next_letter(p, cps, lam_at + 1)
	if after < 0 {
		return
	}
	// The letter after the alef takes the join, and it does so by the same rule as any
	// other pair: the ligature stands where the lam was, and the ligature connects
	// forward whenever the lam could.
	join_prev[after] = true
}

// form_for picks the shape from the two join decisions.
fn form_for(join_prev bool, join_next bool) JoiningForm {
	if join_prev && join_next {
		return .medial
	}
	if join_prev {
		return .final
	}
	if join_next {
		return .initial
	}
	return .isolated
}

// compute_joins fills in whether each character connects to the one before it and to the
// one after it.
fn compute_joins(p &Properties, cps []rune, mut join_prev []bool, mut join_next []bool) {
	// The previous non-transparent index for each position, so a mark does not hide the
	// letter in front of it.
	mut prev_letter := []int{len: cps.len, init: -1}
	mut last := -1
	for i in 0 .. cps.len {
		prev_letter[i] = last
		if !p.joining_type_of(cps[i]).is_transparent() {
			last = i
		}
	}

	for i in 0 .. cps.len {
		cp := cps[i]

		// A joiner forces a connection on both sides and a non-joiner prevents one on
		// both. Neither is a letter, so neither is passed to connect as one: instead the
		// two letters it sits between are looked up and the control decides for them.
		if cp == zero_width_joiner || cp == zero_width_non_joiner {
			before := prev_letter[i]
			after := next_letter(p, cps, i)
			if before >= 0 && after >= 0 {
				// A control only ever has marks between it and the letters on either
				// side, because prev_letter and next_letter both skip transparents.
				connect(p, cps, before, after, mut join_prev, mut join_next)
			}
			continue
		}

		before := prev_letter[i]
		if before >= 0 {
			connect(p, cps, before, i, mut join_prev, mut join_next)
		}
		after := next_letter(p, cps, i)
		if after >= 0 {
			connect(p, cps, i, after, mut join_prev, mut join_next)
		}
	}
}

// connect decides the join between two letters that face each other. The two may have
// controls between them, and a control there overrides what the letters would do.
fn connect(p &Properties, cps []rune, left int, right int, mut join_prev []bool, mut join_next []bool) {
	// The letters have to face each other: a right joining letter connects only to what
	// comes before it, and a left joining letter only to what comes after.
	mut allowed := p.joining_type_of(cps[left]).joins_to_next()
		&& p.joining_type_of(cps[right]).joins_to_previous()

	// A control between the two overrides what the letters would do. A non-joiner wins
	// over a joiner, so a pair of them in either order leaves the letters apart.
	for k in left + 1 .. right {
		if cps[k] == zero_width_non_joiner {
			allowed = false
			break
		}
		if cps[k] == zero_width_joiner {
			allowed = true
		}
	}
	if !allowed {
		return
	}
	join_next[left] = true
	join_prev[right] = true
}

// next_letter returns the index of the nearest non-transparent character after i.
fn next_letter(p &Properties, cps []rune, i int) int {
	for k in i + 1 .. cps.len {
		if !p.joining_type_of(cps[k]).is_transparent() {
			return k
		}
	}
	return -1
}

// find_form returns the presentation form of a base in a shape, or 0 when there is none.
fn (s &Shaper) find_form(cp rune, form u16) u32 {
	f := s.forms
	mut lo := 0
	mut hi := f.len
	for lo < hi {
		mid := (lo + hi) >> 1
		if f[mid].cp < u32(cp) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	for i := lo; i < f.len && f[i].cp == u32(cp); i++ {
		if f[i].form == form {
			return f[i].glyph
		}
	}
	return 0
}

// find_ligature returns the ligature form of a lam and an alef, or 0 when there is none.
fn (s &Shaper) find_ligature(first u32, second u32, form u16) u32 {
	l := s.ligatures
	mut lo := 0
	mut hi := l.len
	for lo < hi {
		mid := (lo + hi) >> 1
		if l[mid].first < first || (l[mid].first == first && l[mid].second < second) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	for i := lo; i < l.len && l[i].first == first && l[i].second == second; i++ {
		if l[i].form == form {
			return l[i].glyph
		}
	}
	return 0
}

// parse_form_entries decodes the "cp form glyph" table.
fn parse_form_entries(data string) []FormEntry {
	mut out := []FormEntry{}
	for line in data.split_into_lines() {
		s := line.trim_space()
		if s == '' {
			continue
		}
		fields := split_on_spaces(s)
		if fields.len < 3 {
			continue
		}
		out << FormEntry{
			cp:    hex_value(fields[0])
			form:  u16(dec_value(fields[1]))
			glyph: hex_value(fields[2])
		}
	}
	return out
}

// parse_ligature_entries decodes the "first second form glyph" table.
fn parse_ligature_entries(data string) []LigatureEntry {
	mut out := []LigatureEntry{}
	for line in data.split_into_lines() {
		s := line.trim_space()
		if s == '' {
			continue
		}
		fields := split_on_spaces(s)
		if fields.len < 4 {
			continue
		}
		out << LigatureEntry{
			first:  hex_value(fields[0])
			second: hex_value(fields[1])
			form:   u16(dec_value(fields[2]))
			glyph:  hex_value(fields[3])
		}
	}
	return out
}

// split_on_spaces splits on spaces, dropping the empty fields a double space or a
// trailing one would leave behind.
fn split_on_spaces(s string) []string {
	mut out := []string{}
	for f in s.split(' ') {
		if f != '' {
			out << f
		}
	}
	return out
}
