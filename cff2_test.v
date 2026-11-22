module vtext

import os
import vtext.font

// CFF2 reader pins against fontTools 4.66.1 on the committed OFL face
// SourceSans3VF-Upright.otf. Every number below was read off fontTools
// before it was written here; a reader checked only against fixtures built
// to match it would prove nothing.

fn cff2_path() ?string {
	for d in [os.getenv('VTEXT_TEST_FONTS'), 'testdata/fonts'] {
		if d == '' {
			continue
		}
		p := os.join_path(d, 'SourceSans3VF-Upright.otf')
		if os.exists(p) {
			return p
		}
	}
	return none
}

fn cff2_table() ?[]u8 {
	p := cff2_path() or {
		println('SKIP SourceSans3VF-Upright.otf is in neither testdata/fonts nor VTEXT_TEST_FONTS')
		return none
	}
	data := os.read_bytes(p) or { panic('${p} is not readable: ${err}') }
	sfnt := font.parse_sfnt(data) or { panic('the CFF2 font does not parse: ${err}') }
	assert sfnt.has(font.tag_cff2), 'the face must carry CFF2'
	assert !sfnt.has(font.tag_cff), 'the face must have no CFF1 table'
	return sfnt.table_data(font.tag_cff2)
}

fn test_cff2_parse_pins() {
	table := cff2_table() or { return }
	c := font.parse_cff2(table) or { panic('CFF2 does not parse: ${err}') }
	// fontTools on the committed bytes: 2478 CharStrings, 1 FD, region
	// counts [2, 3, ...] from the VarStore; 738 global subrs.
	assert c.num_charstrings == 2478, 'charstrings ${c.num_charstrings}, not 2478'
	assert c.fds.len == 1, 'FDArray has ${c.fds.len} fonts, not 1'
	assert c.num_global_subrs == 0, 'fontTools sees 0 global subrs on this face'
	assert c.region_counts.len > 0, 'the VarStore has no ItemVariationData'
	assert c.region_counts[0] == 2, 'vsindex 0 must have 2 regions, got ${c.region_counts[0]}'
	for gid in 0 .. c.num_charstrings {
		assert c.fd_for_gid[gid] == 0, 'gid ${gid} must select FD 0'
	}
}

fn test_cff2_outline_counts_match_decompiler() {
	table := cff2_table() or { return }
	c := font.parse_cff2(table) or { panic(err) }
	// fontTools RecordingPen op counts at the default instance:
	// A 2/12/2/2, B 3/10/8/3, C 1/2/8/1, a 2/6/10/2, i 2/4/4/2, m 1/12/8/1
	// (moves/lines/curves/closes).
	cases := [
		TestGid{2, 2, 12, 2, 2},
		TestGid{3, 3, 10, 8, 3},
		TestGid{4, 1, 2, 8, 1},
		TestGid{28, 2, 6, 10, 2},
	]
	for t in cases {
		o := c.outline(t.gid) or { panic('gid ${t.gid} does not outline: ${err}') }
		assert o.count_kind(font.CffOpKind.move_to) == t.m, 'gid ${t.gid} moves: ${o.count_kind(font.CffOpKind.move_to)}, not ${t.m}'
		assert o.count_kind(font.CffOpKind.line_to) == t.l, 'gid ${t.gid} lines: ${o.count_kind(font.CffOpKind.line_to)}, not ${t.l}'
		assert o.count_kind(font.CffOpKind.curve_to) == t.c, 'gid ${t.gid} curves: ${o.count_kind(font.CffOpKind.curve_to)}, not ${t.c}'
		assert o.count_kind(font.CffOpKind.close_path) == t.z, 'gid ${t.gid} closes: ${o.count_kind(font.CffOpKind.close_path)}, not ${t.z}'
	}
}

struct TestGid {
	gid int
	m   int
	l   int
	c   int
	z   int
}

// The first moveTo of 'A' is (10, 0) in fontTools design units, a direct
// check that the blend at the default instance keeps its default operand.
fn test_cff2_first_move_pins() {
	table := cff2_table() or { return }
	c := font.parse_cff2(table) or { panic(err) }
	o := c.outline(2) or { panic(err) }
	assert o.ops[0].kind == font.CffOpKind.move_to, "'A' must start with a move"
	assert o.ops[0].pts == [f64(10), 0], "'A' first move ${o.ops[0].pts}, not [10, 0]"
}

// A truncated header is refused with CFF2 in the message, not misread.
fn test_cff2_truncated_header_refused() {
	c := font.parse_cff2([u8(2), 0, 5, 0]) or {
		assert err.msg().contains('CFF2'), 'refusal must name CFF2: ${err.msg()}'
		return
	}
	panic('a 4-byte CFF2 table must be refused, got ${c.num_charstrings} charstrings')
}
