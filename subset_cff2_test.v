module harfara

import os
import harfara.font
import harfara.shape
import harfara.subset

// Tests for the CFF2 subsetter (subset/cff2.v) against the committed OFL
// face SourceSans3VF-Upright.otf, the same face cff2_test.v pins the reader
// against: CFF2 outlines, 2478 glyphs, one FD, no FDSelect, a VarStore. Every
// number below was read off the committed bytes — agreement with a second
// build of the same bytes is the evidence, the way the glyf and CFF
// subsetters pin rasterized ink and byte-identical rebuilds. A subsetter
// verified only against tables built to match it would prove nothing.

fn cff2_subset_font_path() ?string {
	p := os.join_path('testdata/fonts', 'SourceSans3VF-Upright.otf')
	if os.exists(p) {
		return p
	}
	return none
}

fn cff2_subset_original() ?&shape.Font {
	p := cff2_subset_font_path() or {
		println('SKIP SourceSans3VF-Upright.otf is not in testdata/fonts')
		return none
	}
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

fn cff2_subset_parse(data []u8) font.Cff2 {
	sfnt := font.parse_sfnt(data) or { panic('the sfnt does not parse: ${err}') }
	return font.parse_cff2_from_sfnt(&sfnt) or { panic('the CFF2 table does not parse: ${err}') }
}

fn cff2_subset_outlines_equal(a font.CffOutline, b font.CffOutline) bool {
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
fn test_cff2_subset_keeps_outlines() {
	original := cff2_subset_original() or { return }
	assert original.outlines() == 'CFF2', "expected CFF2 outlines, got '${original.outlines()}'"
	assert original.num_glyphs() == 2478, 'glyph count ${original.num_glyphs()}, not 2478'
	mut seed := []u16{}
	seed << original.glyph_index(`A`)
	seed << original.glyph_index(`a`)
	sub := subset.subset_cff2_font(original, seed) or { panic('CFF2 subset did not build: ${err}') }
	assert sub.keep[0], '.notdef always kept'
	for gid in seed {
		assert sub.keep[gid], 'seed gid ${gid} kept'
	}
	reread := shape.load_font_bytes(sub.bytes) or { panic('subset does not load: ${err}') }
	assert reread.outlines() == 'CFF2', "subset must stay CFF2, got '${reread.outlines()}'"
	assert reread.num_glyphs() == original.num_glyphs(), 'glyph count preserved'
	assert reread.tables().len == original.tables().len, 'same table set'
	assert reread.face.is_cff2(), 'the subset must take the CFF2 backend'
	data := original.data()
	before := cff2_subset_parse(data)
	after := cff2_subset_parse(sub.bytes)
	for gid in subset.kept_glyph_ids(sub.keep) {
		a := before.outline(int(gid)) or { panic('gid ${gid} does not outline before: ${err}') }
		b := after.outline(int(gid)) or { panic('gid ${gid} does not outline after: ${err}') }
		assert cff2_subset_outlines_equal(a, b), 'gid ${gid} outline changed'
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
	again := subset.subset_cff2_font(original, seed) or { panic(err) }
	assert again.bytes == sub.bytes, 'subset is deterministic'
}

// Break-fix: rebuilding the same closure with one kept seed glyph dropped
// must fail the outline comparison for that entry. A test that stayed green
// on the tampered bytes would prove nothing about the keep mask.
fn test_cff2_subset_dropped_closure_entry_fails() {
	original := cff2_subset_original() or { return }
	mut seed := []u16{}
	seed << original.glyph_index(`A`)
	seed << original.glyph_index(`a`)
	sub := subset.subset_cff2_font(original, seed) or { panic(err) }
	data := original.data()
	before := cff2_subset_parse(data)
	// Drop the first kept seed glyph and rebuild around the tampered mask.
	target := original.glyph_index(`A`)
	assert sub.keep[target], 'A must be kept before the tamper'
	mut tampered := sub.keep.clone()
	tampered[target] = false
	bad := subset.subset_cff2_with_keep(original, tampered) or {
		panic('a dropped entry must still build: ${err}')
	}
	bad_reread := shape.load_font_bytes(bad.bytes) or { panic('tampered subset does not load: ${err}') }
	assert bad_reread.num_glyphs() == original.num_glyphs(), 'ids stay preserved under tampering'
	bad_cff2 := cff2_subset_parse(bad.bytes)
	a := before.outline(int(target)) or { panic(err) }
	b := bad_cff2.outline(int(target)) or { panic(err) }
	assert !cff2_subset_outlines_equal(a, b), 'dropping gid ${target} must change its outline'
	assert a.ops.len > 0 && b.ops.len == 0, 'the dropped A must go from ink to empty'
}

// The VarStore, FDSelect and FDArray survive the rebuild: instancing the
// subset at wght 900 draws the same box as instancing the original. A
// rebuild that truncated the store or dropped the FD mapping would rasterize
// the default here instead.
fn test_cff2_subset_instances_like_original() {
	p := cff2_subset_font_path() or { return }
	mut ofont := shape.load_font_file(p) or { panic(err) }
	mut seed := []u16{}
	seed << ofont.glyph_index(`A`)
	sub := subset.subset_cff2_font(ofont, seed) or { panic(err) }
	mut rfont := shape.load_font_bytes(sub.bytes) or { panic('subset does not load: ${err}') }
	ofont.set_var_coords([900.0]) or { panic(err) }
	want := ofont.rasterize(ofont.glyph_index(`A`), 32.0, 0, 0)
	rfont.set_var_coords([900.0]) or { panic(err) }
	got := rfont.rasterize(rfont.glyph_index(`A`), 32.0, 0, 0)
	assert got.width == want.width && got.height == want.height, 'instanced subset box ${got.width}x${got.height}, original ${want.width}x${want.height}'
	assert got.left == want.left && got.top == want.top, 'instanced subset at (${got.left},${got.top}), original (${want.left},${want.top})'
	assert got.width == 21 && got.height == 21, 'A@900 must keep its 21x21 box through the subset'
	assert got.coverage == want.coverage, 'instanced subset ink must equal the original'
}

// Routing: subset_cff_font sends a CFF2 face down the CFF2 path, so it
// agrees with subset_cff2_font instead of refusing.
fn test_cff2_subset_routing_agrees() {
	original := cff2_subset_original() or { return }
	mut seed := []u16{}
	seed << original.glyph_index(`A`)
	a := subset.subset_cff_font(original, seed) or { panic('CFF2 face must subset: ${err}') }
	b := subset.subset_cff2_font(original, seed) or { panic(err) }
	assert a.bytes == b.bytes, 'routing must reach the same rebuild'
}
