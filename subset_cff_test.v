module harfara

import os
import harfara.font
import harfara.shape
import harfara.subset

// Tests for the CFF subsetter (subset/cff.v) against a real CFF font.
//
// The font is Source Sans 3 Regular, the same OFL Adobe release cff_test.v
// pins the reader against: OTTO, 2478 glyphs, CFF outlines, no glyf/loca.
// Every number below was read off the committed bytes — agreement with a
// second build of the same bytes is the evidence, the way the glyf subset
// pins rasterize the same ink. A subsetter verified only against tables
// built to match it would prove nothing.
//
// The corpus carries no CFF2 face, so the CFF2 refusal is pinned on a
// synthetic one-table sfnt, the way cff_test.v pins the reader's CFF2
// refusal where no committed font can stand in.

fn cff_subset_font_path() ?string {
	p := os.join_path('testdata/fonts', 'SourceSans3-Regular.otf')
	if os.exists(p) {
		return p
	}
	return none
}

fn cff_subset_font_bytes() ?[]u8 {
	p := cff_subset_font_path() or { return none }
	return os.read_bytes(p) or { panic('${p} is not readable: ${err}') }
}

fn cff_subset_skip() bool {
	line := 'SKIP SourceSans3-Regular.otf is not in testdata/fonts'
	path := os.getenv('HARFARA_SKIP_LOG')
	if path != '' {
		mut f := os.open_append(path) or { return true }
		f.writeln(line) or { return true }
		f.close()
		return true
	}
	println(line)
	return true
}

fn cff_subset_original() ?&shape.Font {
	p := cff_subset_font_path() or {
		cff_subset_skip()
		return none
	}
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

fn cff_subset_parse(data []u8) font.Cff {
	sfnt := font.parse_sfnt(data) or { panic('the sfnt does not parse: ${err}') }
	return font.parse_cff_from_sfnt(&sfnt) or { panic('the CFF table does not parse: ${err}') }
}

fn cff_subset_outlines_equal(a font.CffOutline, b font.CffOutline) bool {
	if a.has_width != b.has_width {
		return false
	}
	if a.has_width && a.width != b.width {
		return false
	}
	if a.ops.len != b.ops.len {
		return false
	}
	for i, op in a.ops {
		if op.kind != b.ops[i].kind {
			return false
		}
		if op.pts.len != b.ops[i].pts.len {
			return false
		}
		for j, v in op.pts {
			if v != b.ops[i].pts[j] {
				return false
			}
		}
	}
	return true
}

// The subset keeps the seed and .notdef, reloads, keeps the glyph count and
// the table set, and every kept outline compares equal. A second build of
// the same seed is byte-identical.
fn test_cff_subset_keeps_outlines() {
	original := cff_subset_original() or { return }
	assert original.outlines() == 'CFF ', "expected CFF outlines, got '${original.outlines()}'"
	assert original.num_glyphs() == 2478, 'glyph count ${original.num_glyphs()}, not 2478'
	mut seed := []u16{}
	seed << original.glyph_index(`A`)
	seed << original.glyph_index(`a`)
	seed << original.glyph_index(` `)
	sub := subset.subset_cff_font(original, seed) or { panic('CFF subset did not build: ${err}') }
	assert sub.keep[0], '.notdef always kept'
	for gid in seed {
		assert sub.keep[gid], 'seed gid ${gid} kept'
	}
	reread := shape.load_font_bytes(sub.bytes) or { panic('subset does not load: ${err}') }
	assert reread.outlines() == 'CFF ', "subset must stay CFF, got '${reread.outlines()}'"
	assert reread.num_glyphs() == original.num_glyphs(), 'glyph count preserved'
	assert reread.tables().len == original.tables().len, 'same table set'
	data := original.data()
	before := cff_subset_parse(data)
	after := cff_subset_parse(sub.bytes)
	for gid in subset.kept_glyph_ids(sub.keep) {
		a := before.outline(int(gid)) or { panic('gid ${gid} does not outline before: ${err}') }
		b := after.outline(int(gid)) or { panic('gid ${gid} does not outline after: ${err}') }
		assert cff_subset_outlines_equal(a, b), 'gid ${gid} outline changed'
	}
	// A dropped glyph draws nothing in the subset while it drew something
	// before: ids are preserved, outlines are not.
	mut dropped := -1
	for i, k in sub.keep {
		if !k {
			orig := before.outline(i) or { continue }
			if orig.ops.len > 0 {
				dropped = i
				break
			}
		}
	}
	assert dropped > 0, 'the subset must drop a glyph that drew something'
	bad_outline := after.outline(dropped) or { panic('dropped gid ${dropped} must still outline: ${err}') }
	assert bad_outline.ops.len == 0, 'dropped gid ${dropped} must draw nothing in the subset'
	again := subset.subset_cff_font(original, seed) or { panic(err) }
	assert again.bytes == sub.bytes, 'subset is deterministic'
}

// Break-fix: rebuilding the same closure with one kept entry dropped must
// fail the outline comparison for that entry. A test that stayed green on
// the tampered bytes would prove nothing about the keep mask.
fn test_cff_subset_dropped_closure_entry_fails() {
	original := cff_subset_original() or { return }
	mut seed := []u16{}
	seed << original.glyph_index(`A`)
	seed << original.glyph_index(`a`)
	sub := subset.subset_cff_font(original, seed) or { panic(err) }
	data := original.data()
	before := cff_subset_parse(data)
	// Drop the first kept seed glyph and rebuild around the tampered mask.
	target := original.glyph_index(`A`)
	assert sub.keep[target], 'A must be kept before the tamper'
	mut tampered := sub.keep.clone()
	tampered[target] = false
	bad := subset.subset_cff_with_keep(original, tampered) or {
		panic('a dropped entry must still build: ${err}')
	}
	bad_reread := shape.load_font_bytes(bad.bytes) or { panic('tampered subset does not load: ${err}') }
	assert bad_reread.num_glyphs() == original.num_glyphs(), 'ids stay preserved under tampering'
	bad_cff := cff_subset_parse(bad.bytes)
	a := before.outline(int(target)) or { panic(err) }
	b := bad_cff.outline(int(target)) or { panic(err) }
	assert !cff_subset_outlines_equal(a, b), 'dropping gid ${target} must change its outline'
	assert a.ops.len > 0 && b.ops.len == 0, 'the dropped A must go from ink to empty'
}

// A CFF2-only face refuses with the format's name: there is no committed
// CFF2 face to verify a rebuild against, so the refusal names the reason
// rather than writing an unverified table.
fn test_cff_subset_refuses_cff2() {
	fake := cff_subset_fake_sfnt(['CFF2'])
	only2 := shape.load_font_bytes(fake) or { panic('the CFF2-only sfnt did not load: ${err}') }
	assert only2.outlines() == 'CFF2'
	if _ := subset.subset_cff_font(only2, [u16(0)]) {
		assert false, 'a CFF2 face subsetted'
	} else {
		assert err.msg().contains('CFF2'), 'unexpected refusal: ${err.msg()}'
	}
	if _ := subset.subset_cff_with_keep(only2, [true]) {
		assert false, 'a CFF2 face subsetted with an explicit mask'
	} else {
		assert err.msg().contains('CFF2'), 'unexpected refusal: ${err.msg()}'
	}
}

// cff_subset_fake_sfnt builds a minimal sfnt holding the named tables with
// four zero bytes each — the shape inspect_test proves the loader accepts —
// for the CFF2 refusal above, where no committed font can stand in.
fn cff_subset_fake_sfnt(tags []string) []u8 {
	mut out := []u8{cap: 12 + tags.len * 20}
	out << 'OTTO'.bytes()
	out << u8(tags.len >> 8)
	out << u8(tags.len & 0xff)
	out << [u8(0), 0, 0, 0, 0, 0]
	mut body_at := 12 + tags.len * 16
	for t in tags {
		assert t.len == 4
		out << t.bytes()
		out << [u8(0), 0, 0, 0]
		out << u8(body_at >> 24)
		out << u8((body_at >> 16) & 0xff)
		out << u8((body_at >> 8) & 0xff)
		out << u8(body_at & 0xff)
		out << u8(0)
		out << u8(0)
		out << u8(0)
		out << u8(4)
		body_at += 4
	}
	for _ in 0 .. tags.len * 4 {
		out << u8(0)
	}
	return out
}
