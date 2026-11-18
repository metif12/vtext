module shape

import vtext.font
import vtext.ucd
import vtext.raster

// vtext is a text shaping and rendering engine written in V.
//
// The pipeline is: normalization -> Unicode itemisation -> bidirectional
// reordering -> OpenType shaping -> font fallback -> line layout -> rasterize ->
// draw. Everything is V except the outline rasteriser, which reuses the
// public-domain stb_truetype header that already ships inside V's own thirdparty
// tree, so importing this module adds no new external dependency.
//
// This list said "glyph atlas" where it now says "rasterize", and the difference is a decision rather than
// a rewording. An atlas is a GPU texture with a shelf packer, which is a display backend's concern and not
// a text engine's, and one that rasterizing into its own buffer has no use for. What that caller wants is a
// cache from a key to a bitmap, which it can hold itself: a cache is a memoisation of a pure function of
// (font, gid, size, subpixel offset), so it is a few dozen lines and no shared mutable state, whereas an
// atlas inside the engine would make every loaded font's rasterizer state global to the engine and give
// Font a thread-safety contract it deliberately does not have.

import os

// Font is a loaded font file. It is the entry point for metrics, glyph lookup
// and rasterisation.
pub struct Font {
pub mut:
	face &font.Face
	path string
}

// load_font_file reads and parses a font from disk.
pub fn load_font_file(path string) !&Font {
	data := os.read_bytes(path) or { return error('cannot read font "${path}": ${err}') }
	// A WOFF1 file unwraps to its sfnt before parsing; anything else passes
	// through untouched, and WOFF2 refuses with its reason.
	raw := font.maybe_woff_to_sfnt(data) or { return error('cannot parse font "${path}": ${err}') }
	mut f := Font{
		face: font.new_face(raw) or { return error('cannot parse font "${path}": ${err}') }
		path: path
	}
	return &f
}

// load_font_bytes parses a font already held in memory.
pub fn load_font_bytes(data []u8) !&Font {
	raw := font.maybe_woff_to_sfnt(data) or { return error('cannot parse font: ${err}') }
	mut f := Font{
		face: font.new_face(raw) or { return error('cannot parse font: ${err}') }
	}
	return &f
}

// path returns where the font was loaded from, or an empty string when it came
// from memory.
pub fn (f &Font) path() string {
	return f.path
}

// data returns the bytes the face was parsed from: the whole file, which for a
// collection member is the whole collection, because the table offsets the
// inspection API reports are file offsets. It is a copy, made once per call, so
// the caller owns it outright and a font built from memory is subsettable the
// same way one built from a path is — the tool used to re-read the path, which
// meant a memory font could not be subsetted at all.
pub fn (f &Font) data() []u8 {
	return f.face.sfnt.data.clone()
}

// units_per_em is the font's design grid size.
pub fn (f &Font) units_per_em() int {
	return f.face.units_per_em
}

// num_glyphs is the number of glyphs the font contains.
pub fn (f &Font) num_glyphs() int {
	return f.face.num_glyphs
}

// is_monospaced reports whether every glyph shares one advance.
pub fn (f &Font) is_monospaced() bool {
	return f.face.is_fixed_pitch
}

// is_cff_outlined reports whether outlines are CFF rather than TrueType.
pub fn (f &Font) is_cff_outlined() bool {
	return f.face.sfnt.is_cff()
}

// ascent is the distance above the baseline, in pixels at the given em size.
pub fn (f &Font) ascent(em_px f64) f64 {
	return f.face.ascent(em_px)
}

// descent is the distance below the baseline, in pixels, always positive.
pub fn (f &Font) descent(em_px f64) f64 {
	return f.face.descent(em_px)
}

// line_height is the baseline-to-baseline distance in pixels.
pub fn (f &Font) line_height(em_px f64) f64 {
	return f.face.line_height(em_px)
}

// glyph_index maps a codepoint to a glyph index. Zero means .notdef, which for
// a codepoint the font does not cover is the correct answer.
pub fn (f &Font) glyph_index(cp rune) u16 {
	return f.face.glyph_index(cp)
}

// codepoint_for maps a glyph index back to the character the font draws it for, or none when the font
// does not say.
//
// This is the direction cmap lookup does not do, and a caller needs it to name anything it did not type:
// a tool listing a font's glyphs, a subsetter reporting what it kept, a caller mapping a glyph id that
// came back from a substitution. It is genuinely many-to-one — a font may map several codepoints to one
// glyph — so the lowest is returned, and glyph 0 has no answer at all because it is .notdef.
pub fn (f &Font) codepoint_for(gid u16) ?rune {
	return f.face.codepoint_for(gid)
}

// has_glyph reports whether the font really covers cp. Font fallback needs this
// distinction: a font that maps cp to .notdef is not a candidate for it.
pub fn (f &Font) has_glyph(cp rune) bool {
	return f.face.has_glyph(cp)
}

// glyph_index_variation maps a codepoint to a glyph index with variation selectors after it.
//
// This is the form to use for text that may contain a variation sequence, because it is the only one
// that can reach a cmap format 14 subtable. With an empty selector list it is exactly `glyph_index`,
// so a caller with no emoji in its text can use either.
//
// The selectors are consumed by this lookup rather than looked up themselves. U+FE0F has no glyph of
// its own in any font, and asking for one is the mistake this function's existence makes impossible: a
// selector is a question about the character in front of it, not a character.
pub fn (f &Font) glyph_index_variation(cp rune, selectors []rune) u16 {
	return f.face.glyph_index_variation(cp, selectors)
}

// has_variation_sequence reports whether the font says anything about this base and selector
// together, as opposed to what it says about the base alone.
//
// A font can cover a base and still have no opinion about the sequence, in which case the caller draws
// the base's text presentation. That is a result rather than a miss, and this is how a fallback chain
// tells the two apart.
pub fn (f &Font) has_variation_sequence(cp rune, selector rune) bool {
	return f.face.has_variation_sequence(cp, selector)
}

// substitute_glyphs applies the font's substitution features to a run of glyphs.
//
// This is what the joining pass cannot do on its own. It knows that a lam and an alef are one
// shape, and it says so with a presentation form codepoint, but whether the font has a glyph for
// that form, and how wide it is, are questions only the font can answer. A lam-alef drawn as
// two letters is legible and wrong: the pair is narrower fused than apart, so a line built that
// way is the wrong length.
//
// The features applied by default are ccmp and rlig, in the order the specification gives them, so
// that a mark which composes into a single glyph is not then swallowed by a rule written for the
// pair. Those two are on for every line because a line missing its mark composition is not the
// text, and neither of them is a presentation choice.
//
// Three more are on for every line for the same reason HarfBuzz leaves them on: calt, liga and
// clig. A code editor's `=>` is a calt alternate (Fira Code draws it as two full-width glyphs,
// not one fused one), and Persian letter pairs have liga forms in the font — turning either off
// by default draws text no other shaper draws. Discretionary features (dlig and the stylistic
// sets) stay off until named: a caller that wants one names it in extra, and it is applied
// after the vertical forms, which is the order the specification gives discretionary features.
// A `-tag` entry turns a default-on feature back off (`-calt` draws `=>` as two plain glyphs),
// and `+tag` is the same as naming the tag; the required features above are not toggleable,
// because a line missing them is not the text.

pub fn (f &Font) substitute_glyphs(glyphs []Glyph, script string, lang string, em_px f64,
	extra []string, vertical bool) []Glyph {
	g := f.face.gsub or { return glyphs }
	mut out := []font.Ligatable{cap: glyphs.len}
	for i, glyph in glyphs {
		out << font.Ligatable{
			gid:     glyph.gid
			cluster: glyph.cluster
			source:  i
			form:    glyph.form
			is_mark: glyph.is_mark
		}
	}
	// Asked features a shaper runs before ccmp come from the registry:
	// Myanmar's medial-dot fusion consumes DOT BELOW whole, and ccmp
	// splits DOT BELOW into spacing and dummy marks first, which starves
	// the rule when blwf runs late. Asked early it fuses the way HarfBuzz
	// fuses with +blwf. Default lines never reach it: blwf is not a
	// Myanmar default, and an unasked tag names nothing, so the default
	// unfused answer does not move.
	shaper_early := shaper_early_features_for(script, extra)
	for feature in shaper_early {
		out = g.substitute(g.lookups_for_lang(script, lang, feature), out)
	}
	for feature in ['ccmp'] {
		out = g.substitute(g.lookups_for_lang(script, lang, feature), out)
	}
	// locl comes next, before the joining forms, because it is written against
	// the base glyphs: Noto Naskh's Sindhi meem and Urdu digits, Amiri's Urdu
	// digits. Applied after the joining forms it would look up shaped glyphs
	// in a coverage of base ones and find nothing. Under a language system
	// that does not list it the lookup list is empty, so this is nothing.
	for feature in ['locl'] {
		out = g.substitute(g.lookups_for_lang(script, lang, feature), out)
	}
	// The four joining features come next and in the specification's order, each masked to the glyphs in
	// its own shape. They are on for every line for the same reason ccmp is: a line whose letters are all
	// in the isolated shape is not the text.
	//
	// They were absent until 2026-10-04, which is why this is worth a paragraph. They cannot be reached by
	// calling substitute over the whole run once each, because every rule is written against the base
	// letters: unmasked, `init` claims every letter and the run is entirely initial before `medi` runs. Nor
	// can they be reached one glyph at a time, because 46 of Noto Nastaliq's 68 `init` rules turn one glyph
	// into several and a call that returns a single glyph id cannot express that. The run-level path with a
	// mask is the only route that is correct for both.
	//
	// A glyph that a font already gave as a Unicode presentation form is not re-shaped by this. Its form is
	// set but its glyph is a shaped one, and these coverages hold base letters, so there is nothing to match.
	for form in [font.JoiningForm.isolated, font.JoiningForm.initial, font.JoiningForm.medial,
		font.JoiningForm.final] {
		out = g.substitute_forms(g.lookups_for_lang(script, lang, font.feature_tag_for(form)), out, form)
	}
	// The shaping features run next, in each script's order, for the
	// same reason the joining features do: a line whose conjuncts stay
	// unfused is not the text. The registry answers the run script's
	// defaults (Indic, Khmer, Myanmar in registration order) and an
	// unregistered script gets an empty list, which is nothing. Like the
	// joining features these are not toggleable; a `-tag` for one names
	// nothing.
	shaper_defaults := shaper_default_features_for(script)
	for feature in shaper_defaults {
		out = g.substitute(g.lookups_for_lang(script, lang, feature), out)
	}
	for feature in ['rlig'] {
		out = g.substitute(g.lookups_for_lang(script, lang, feature), out)
	}
	// calt, liga and clig are on unless the caller turned them off with `-tag`: the
	// contextual alternates first, because they are written against the same base glyphs
	// the joining features were, and the fusing ones after. The `+tag` spelling is the
	// same as naming the tag and exists so a generated list can be explicit. The last
	// spelling of one tag wins: `-calt` then `calt` turns it back on for the line.
	mut enabled := {
		'calt': true
		'liga': true
		'clig': true
	}
	mut asked := []string{}
	for feature in extra {
		if feature.starts_with('-') && feature.len > 1 {
			off := feature[1..]
			if off == 'calt' || off == 'liga' || off == 'clig' {
				enabled[off] = false
			}
			// Anything else is already off by default, and the required features
			// above are not toggleable, so a `-tag` for those names nothing.
		} else {
			mut tag := feature
			if tag.starts_with('+') && tag.len > 1 {
				tag = tag[1..]
			}
			if tag == 'calt' || tag == 'liga' || tag == 'clig' {
				enabled[tag] = true
			} else if tag in shaper_defaults {
				// Already on above: applying a fusing feature twice is not
				// idempotent in every font (a Bengali below-base piece fuses
				// again), so naming a registry default is a no-op rather
				// than a second run.
				continue
			} else if tag in shaper_early {
				// Already ran above, before ccmp: a fusing feature must not
				// run twice, and the late run would find nothing anyway.
				continue
			} else {
				mut seen := false
				for prev in asked {
					if prev == tag {
						seen = true
						break
					}
				}
				if !seen {
					asked << tag
				}
			}
		}
	}
	mut on := []string{}
	for tag in ['calt', 'liga', 'clig'] {
		if enabled[tag] {
			on << tag
		}
	}
	for feature in on {
		out = g.substitute(g.lookups_for_lang(script, lang, feature), out)
	}
	// Vertical forms come next when the line is vertical, for the same reason
	// rlig is unconditional: a vertical line whose punctuation draws its
	// horizontal form is not vertical text. They are collected under the run's
	// script like every other required feature, which is why the run resolves
	// Common and Inherited to the strong script in front of this call.
	if vertical {
		for feature in ['vert'] {
			out = g.substitute(g.lookups_for_lang(script, lang, feature), out)
		}
	}
	for feature in asked {
		out = g.substitute(g.lookups_for_lang(script, lang, feature), out)
	}
	// Every advance is read again, not just the fused ones, so the advance always belongs to the
	// glyph it is on. A ligature is usually narrower than the glyphs it replaced, and carrying
	// the first letter's advance over would leave the line the wrong length in exactly the way
	// the ligature was meant to fix.
	mut result := []Glyph{cap: out.len}
	for item in out {
		mut glyph := glyphs[item.source]
		glyph.gid = item.gid
		glyph.cluster = item.cluster
		// The substitution may have decided this piece is a mark — a 1:N split of a base
		// letter produces the letter's dot components, and the font's GDEF table is what
		// says those are marks. The flag rides on the substitution result rather than on
		// the input glyph, because the input was the base letter and the pieces are not.
		// A piece that became a mark also loses the base's advance: a mark never moves
		// the pen, and carrying the base's advance would charge one character twice.
		if item.is_mark && !glyph.is_mark {
			glyph.advance = 0
		}
		glyph.is_mark = item.is_mark
		// A mark never advances the pen, whatever glyph it ended up as, so its zero advance is
		// kept rather than measured. Measuring it would give a mark the width of its outline and
		// push everything after it along the line.
		if !glyph.is_mark {
			glyph.advance = f.glyph_advance(item.gid, em_px)
		}
		result << glyph
	}
	return result
}

// has_gsub reports whether the font carries glyph substitution, which is what decides whether
// it can draw a letter in anything but its base shape.
pub fn (f &Font) has_gsub() bool {
	return f.face.gsub != none
}

// has_mark_attachment reports whether the font says where a mark goes on the letter it
// belongs to. A font without it draws the mark at the pen position, which for an Arabic letter
// is beside the letter rather than on it.
pub fn (f &Font) has_mark_attachment() bool {
	g := f.face.gpos or { return false }
	return g.has_mark_attachment()
}

// mark_glyphs_passthrough reports whether the mark glyphs a font uses in its positioning rules
// are the ones its cmap maps the marks to.
//
// It exists because the two are not always the same and the difference matters. A font that
// composes its marks through a ccmp substitution has its positioning rules written against the
// composed glyph, not against the one the cmap hands out, so a mark that has not been through
// that substitution will not be found in any coverage.
//
// The composition is run, so this is no longer a report of something the engine has not done. It
// is a report of a font whose composition rules are written against glyphs the pipeline never
// produces, which is Dubai's case and is not a thing the substitution pass can fix: the rules are
// reachable and parsed, and there is simply no path from the text to the glyphs they name.
pub fn (f &Font) mark_glyphs_passthrough() bool {
	gpos := f.face.gpos or { return true }
	return gpos.covers_mark(f.glyph_index(rune(0x064E)))
}

// is_mark_glyph reports whether the font classifies this glyph as a combining mark. The
// classification comes from the font rather than from Unicode, because the font is what decides
// how its own glyphs are used.
pub fn (f &Font) is_mark_glyph(gid u16) bool {
	g := f.face.gdef or { return false }
	return g.is_mark(gid)
}

// mark_offset returns where to draw a mark relative to the origin of the glyph it belongs to, in
// design units, with y positive upwards as the font's own coordinates run.
//
// base_is_mark says what the second glyph is, because the three rules a mark can be placed by are
// three different tables: over a letter is mark-to-base, over another mark is mark-to-mark, and
// over a ligature is mark-to-ligature. A font that uses one of them for a pair has nothing to say
// about the pair in the others, so the caller has to say which situation it is in.
//
// found is false when the font has no rule for this pair, or has none for this mark's class on
// this glyph. That is not an error: it is a font that does not say, and the caller is expected to
// leave the mark where the pen is rather than invent a position.
pub fn (f &Font) mark_offset(mark_gid u16, base_gid u16, base_is_mark bool) ?font.Offset2 {
	gpos := f.face.gpos or { return none }
	return gpos.mark_offset(mark_gid, base_gid, base_is_mark)
}

// mark_offset_in is mark_offset for the script the run is in. Mark rules live
// under per-script features, and asking under the wrong script finds a rule
// written for another script's glyphs or -- more often -- nothing at all.
pub fn (f &Font) mark_offset_in(mark_gid u16, base_gid u16, base_is_mark bool, script string, lang string) ?font.Offset2 {
	gpos := f.face.gpos or { return none }
	return gpos.mark_offset_in(mark_gid, base_gid, base_is_mark, script, lang)
}

// cursive_anchors returns where one glyph's joining stroke enters and leaves, in design units, with y
// positive upwards as the font's own coordinates run.
//
// Joining two glyphs is placing one glyph's entry anchor on the previous glyph's exit anchor, so a caller
// walking a run in text order needs the exit of the glyph it has just placed and the entry of the one it
// is about to place, and each of those may be absent. A letter at the start of a word has an entry and no
// exit; a letter at the end is the other way round. A font that gives a glyph neither has no opinion
// about it, and none is returned.
pub fn (f &Font) cursive_anchors(gid u16, script string, lang string) ?font.CursiveAnchors {
	gpos := f.face.gpos or { return none }
	return gpos.cursive_anchors(gid, script, lang)
}

// kern_offset returns how far to move one glyph when another follows it, in design units, with y
// positive upwards as the font's own coordinates run.
//
// The two glyphs are given in the order the text reads them, which for a right-to-left script means
// the rightmost glyph first. That is the order the font's rules are written in, and the reverse
// order finds nothing: a font that kerns a pair tightly has a rule for that pair in reading order
// and none for it backwards, so the line comes out slightly too wide rather than visibly wrong.
//
// script is the script the pair is in, because a font may kern one script differently from another
// and applying the wrong script's rules is worse than applying none.
//
// A pair the font says nothing about returns none, and so does a pair it says is already correct as
// far as this position is concerned, because a zero adjustment and no adjustment cannot be told
// apart by the number alone and neither one moves the pen.
pub fn (f &Font) kern_offset(left_gid u16, right_gid u16, script string, lang string) ?font.Offset2 {
	gpos := f.face.gpos or { return none }
	return gpos.kern_offset(left_gid, right_gid, script, lang)
}

// vkern_offset returns how far to move left_gid down when right_gid follows it in a vertical
// line, in design units. It is the vkrn half of kern_offset: plain pairs, no answer when the font
// names no rule, and the y of the answer is the y advance the rule carries.
pub fn (f &Font) vkern_offset(left_gid u16, right_gid u16, script string, lang string) ?font.Offset2 {
	gpos := f.face.gpos or { return none }
	return gpos.vkern_offset(left_gid, right_gid, script, lang)
}

// single_adjustment returns one glyph's single positioning under the features the line applies,
// in design units: the placements and the advances together, with the format saying which
// fields the font wrote. No rule at all is none, which is not the same as a rule of zeros.
//
// The lookups consulted are the pair-kerning feature's single half — kern in a horizontal
// line, vkrn in a vertical one — plus the default-on discretionary features and the caller's
// extras, resolved with the same off-switch semantics substitute_glyphs keeps: `-tag` turns
// a default off, `+tag` names one explicitly. Each lookup is consulted once however many
// features name it, because a shift applied twice is a letter moved to where no other
// shaper puts it. Mark features (abvm, blwm, mark, mkmk) are not consulted: position_marks
// owns marks, and a second shift from here would move them twice.
// What this answers for a mark is therefore nothing, and the layout pass skips them.
pub fn (f &Font) single_adjustment(gid u16, script string, lang string, extra []string, vertical bool) ?font.PairValue {
	gpos := f.face.gpos or { return none }
	mut enabled := {
		'calt': true
		'liga': true
		'clig': true
	}
	mut asked := []string{}
	for feature in extra {
		if feature.starts_with('-') && feature.len > 1 {
			tag := feature[1..]
			if tag == 'calt' || tag == 'liga' || tag == 'clig' {
				enabled[tag] = false
			}
		} else {
			mut tag := feature
			if tag.starts_with('+') && tag.len > 1 {
				tag = tag[1..]
			}
			if tag == 'calt' || tag == 'liga' || tag == 'clig' {
				enabled[tag] = true
			} else {
				mut seen := false
				for prev in asked {
					if prev == tag {
						seen = true
						break
					}
				}
				if !seen {
					asked << tag
				}
			}
		}
	}
	mut lookups := []u16{}
	mut seen := map[u16]bool{}
	if vertical {
		for li in gpos.lookups_for_lang(script, lang, 'vkrn') {
			if li !in seen {
				seen[li] = true
				lookups << li
			}
		}
	} else {
		for li in gpos.lookups_for_lang(script, lang, 'kern') {
			if li !in seen {
				seen[li] = true
				lookups << li
			}
		}
	}
	for tag in ['calt', 'liga', 'clig'] {
		if enabled[tag] {
			for li in gpos.lookups_for_lang(script, lang, tag) {
				if li !in seen {
					seen[li] = true
					lookups << li
				}
			}
		}
	}
	for tag in asked {
		// A tag consulted above is already in the list: the kern feature is
		// unconditional, and a default the caller named explicitly is enabled.
		// Adding its lookups again would apply every one of them twice, and a
		// shift applied twice is a letter moved to where no shaper puts it.
		if (!vertical && tag == 'kern') || (vertical && tag == 'vkrn') {
			continue
		}
		if tag == 'calt' || tag == 'liga' || tag == 'clig' {
			continue
		}
		for li in gpos.lookups_for_lang(script, lang, tag) {
			if li !in seen {
				seen[li] = true
				lookups << li
			}
		}
	}
	return gpos.single_offset_on(gid, lookups)
}

// kerns reports whether the font has any pair adjustment for a script.
pub fn (f &Font) kerns(script string, lang string) bool {
	gpos := f.face.gpos or { return false }
	return gpos.has_kerning(script, lang)
}

// context_placement returns what the font says about a pair of adjacent glyphs in a run, where the
// answer may depend on what is around them.
//
// This is the form to use when the two glyphs are known to be adjacent rather than picked out of the
// text. A font can place the same two letters differently depending on what precedes them, and that is
// a rule about a position in a run rather than about a pair of glyphs, so the run is what the question
// needs.
//
// The answer is a placement or an advance in design units, whichever the font's rule says. A rule under
// the kern feature is usually a placement rather than a kern, so a caller asking for a kerning value
// and getting a placement is getting what the font asked for.
//
// gids is the run in logical order, which is the order the font's patterns are written in. left and
// right are indices into it, and for a right-to-left run left is the rightmost of the two.
pub fn (f &Font) context_placement(gids []u16, left int, right int, script string, lang string) ?font.Offset2 {
	gpos := f.face.gpos or { return none }
	return gpos.context_offset(gids, left, right, script, lang, f.face.gdef)
}

// contextually_positions reports whether the font moves a glyph based on what is around it.
//
// This is what a script with stacked forms needs: the middle shape of a three-letter stack has to move
// depending on whether there is anything above it, and a font says so with a rule rather than with a
// fifth shape. A Latin font has none, because Latin has nothing to stack, so this is a question worth
// asking before expecting a mark to land somewhere particular.
pub fn (f &Font) contextually_positions(script string, lang string) bool {
	gpos := f.face.gpos or { return false }
	return gpos.has_contextual_positioning(script, lang)
}

// places_marks_on_ligatures reports whether the font can position a mark on a fused pair, which
// decides whether a mark after a lam-alef has a chance of landing anywhere useful.
pub fn (f &Font) places_marks_on_ligatures() bool {
	gpos := f.face.gpos or { return false }
	return gpos.has_mark_to_ligature()
}

// stacks_marks reports whether the font can position one mark on another, which is what a shadda
// carrying a fatha needs.
pub fn (f &Font) stacks_marks() bool {
	gpos := f.face.gpos or { return false }
	return gpos.has_mark_to_mark()
}

// shaped_glyph_index asks the font which glyph carries a joining shape for one glyph.
//
// This is a question, not a step: the pipeline shapes a run through substitute_glyphs, which can
// apply a rule that turns one glyph into several. This cannot, because it returns one glyph id. In
// Noto Nastaliq Urdu, 46 of the 68 rules under `init` replace one glyph with two or three, so for
// that font this answers nothing useful and the run-level path is the one that shapes the text. It
// remains for a caller that wants to ask about one glyph, and for the fonts whose joining rules are
// all one-for-one.
//
// A font with no such table, or no rule for this letter, returns the base glyph.
//
// script is the script of the letter, so a font offering the same feature tag for several
// scripts resolves the right rule.
pub fn (f &Font) shaped_glyph_index(gid u16, form font.JoiningForm, script string, lang string) u16 {
	g := f.face.gsub or { return gid }
	return g.shaped_glyph(gid, form, script, lang)
}

// glyph_advance is the horizontal advance of a glyph in pixels.
pub fn (f &Font) glyph_advance(gid u16, em_px f64) f64 {
	return f.face.glyph_advance(gid, em_px)
}

// has_vertical_metrics reports whether the font carries vhea/vmtx: CJK fonts
// do, and it is what a vertical line is measured with.
pub fn (f &Font) has_vertical_metrics() bool {
	return f.face.has_vertical_metrics()
}

// vertical_advance is the vertical advance of a glyph in pixels: how far the
// pen moves down past this glyph in a vertical line.
pub fn (f &Font) vertical_advance(gid u16, em_px f64) f64 {
	return f.face.scale(f64(f.face.vertical_advance_units(gid)), em_px)
}

// vertical_origin_y is the glyph's vertical origin in pixels above the
// baseline: the VORG entry when the font names one for this glyph, else the
// top of the vertical em box.
pub fn (f &Font) vertical_origin_y(gid u16, em_px f64) f64 {
	return f.face.scale(f64(f.face.vertical_origin_units(gid)), em_px)
}

// underline_thickness is the recommended underline weight in pixels.
pub fn (f &Font) underline_thickness(em_px f64) f64 {
	return f.face.scale(f.face.underline_thickness, em_px)
}

// underline_position is the recommended underline offset from the baseline,
// in pixels, positive downwards.
pub fn (f &Font) underline_position(em_px f64) f64 {
	return f.face.scale(f.face.underline_position, em_px)
}

// rasterize renders a glyph. sub_x and sub_y select a quarter-pixel bin, so
// callers can round to 0, 0.25, 0.5 or 0.75 of a pixel.
// rasterize renders one glyph at em_px and returns its coverage in 8 bits, with the ink box placed
// relative to the pen on the baseline.
//
// sub_x and sub_y are the subpixel offset of the pen, in **quarters of a pixel**: four is one whole
// pixel, and a whole pixel or more shifts the ink as far as it says. They are quarters rather than the
// sixtieths stb_truetype itself takes because the rasteriser behind this counts a pixel in quarters,
// which keeps a glyph's cache key to four positions per pixel instead of sixty-four.
//
// Passing sixtieths here is the mistake worth naming, because it is the other convention and the
// failure is not obviously a bad argument: sixtieths of a pixel read as quarters is sixteen times too
// far, so every glyph is drawn up to sixteen pixels from where the layout put it and a line of text
// comes out as overlapping ink. A glyph placed at x of 17.39 is drawn at 17 with sub_x of 2.
//
// The bitmap's left is how far the ink reaches left of the pen and its top how far it reaches above the
// baseline, so the pixel the bitmap's own (0, 0) belongs at is (pen - left, baseline - top).
pub fn (f &Font) rasterize(gid u16, em_px f64, sub_x i32, sub_y i32) raster.GlyphBitmap {
	return f.face.rasterize_glyph(gid, em_px, sub_x, sub_y)
}

// num_cmap_subtables reports how many character maps the font offers. More than
// one is normal; the highest-scoring Unicode subtable is used.
pub fn (f &Font) num_cmap_subtables() int {
	return f.face.cmaps.len
}

// set_var_coords stores caller-chosen design coordinates on the face
// underneath, one per fvar axis in design units. It is the entry point that
// plays the FT_Set_Var_Design_Coordinates role: coordinates are kept, and
// instanced_glyph_points draws from them.
pub fn (mut f Font) set_var_coords(coords []f64) ! {
	f.face.set_var_coords(coords) or { return err }
}

// var_coords answers the effective design coordinates: what the caller
// stored, or the fvar defaults when nothing was stored.
pub fn (f &Font) var_coords() []f64 {
	return f.face.var_coords()
}

// instanced_glyph_points instances one glyph outline at the stored design
// coordinates through the fvar/gvar application in font.var: the default
// instance when the caller stored nothing, the chosen one once
// set_var_coords ran.
pub fn (f &Font) instanced_glyph_points(gid u16) !font.InstancedOutline {
	o := f.face.instanced_glyph_points(gid) or { return err }
	return o
}
