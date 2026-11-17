module vtext

import vtext.shape
import vtext.font
import os

// HVAR/MVAR/cvar readers, standalone beside fontTools.
//
// The pins below are fontTools values, measured with the decompiler beside
// the raw bytes: region edges as F2DOT14, VarData items as stored, index
// maps as decoded, and deltas at normalized blend coordinates. The
// break-fix control at the bottom neuters the deltas and watches the pins
// fail, so a dropped applier cannot pass.

fn hvar_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('VTEXT_TEST_FONTS'), 'testdata/fonts', hvar_windows_dir()] {
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
	fn hvar_windows_dir() string {
		return 'C:\\Windows\\Fonts'
	}
} $else {
	fn hvar_windows_dir() string {
		return ''
	}
}

fn hvar_skip(name string) {
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

fn hvar_font(name string) ?&shape.Font {
	p := hvar_font_path(name) or { return none }
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

// NotoNaskhArabic HVAR: the mapped face. The table is 1594 bytes, the store
// holds one region (0,1,1) over two VarData subtables (99 byte items plus 7
// short items), and the advance map covers all 1415 glyphs. gid 4 (uni0621)
// maps to varIdx 26 with item [15]; gid 23 (uni062D.fina) maps to 67 with
// [58]; space and .notdef share varIdx 13 with [0]; gid 181 reaches the
// second subtable at (1,0) with [-286].
fn test_hvar_naskh_header_and_maps() {
	mut f := hvar_font('NotoNaskhArabic-Variable.ttf') or {
		hvar_skip('NotoNaskhArabic-Variable.ttf')
		return
	}
	hvar := f.face.sfnt.table_data(font.tag_hvar)
	assert hvar.len == 1594, 'Naskh HVAR is 1594 bytes, got ${hvar.len}'
	t := font.hvar_parse(hvar) or { panic('Naskh HVAR must parse: ${err}') }
	assert t.has_store, 'Naskh HVAR carries a store'
	assert t.store.axis_count == 1, 'one axis, got ${t.store.axis_count}'
	assert t.store.regions.len == 1, 'one region, got ${t.store.regions.len}'
	assert t.store.regions[0][0].start == 0.0, 'region start 0, got ${t.store.regions[0][0].start}'
	assert t.store.regions[0][0].peak == 1.0, 'region peak 1, got ${t.store.regions[0][0].peak}'
	assert t.store.regions[0][0].end == 1.0, 'region end 1, got ${t.store.regions[0][0].end}'
	assert t.store.datas.len == 2, 'two VarData, got ${t.store.datas.len}'
	assert t.store.datas[0].deltas.len == 99, 'VarData0 holds 99 items, got ${t.store.datas[0].deltas.len}'
	assert t.store.datas[0].region_indexes == [0], 'VarData0 over region 0, got ${t.store.datas[0].region_indexes}'
	assert t.store.datas[0].deltas[0] == [-42], 'VarData0 item 0 is -42, got ${t.store.datas[0].deltas[0]}'
	assert t.store.datas[0].deltas[1] == [-39], 'VarData0 item 1 is -39, got ${t.store.datas[0].deltas[1]}'
	assert t.store.datas[0].deltas[13] == [0], 'VarData0 item 13 is 0, got ${t.store.datas[0].deltas[13]}'
	assert t.store.datas[1].deltas.len == 7, 'VarData1 holds 7 items, got ${t.store.datas[1].deltas.len}'
	assert t.store.datas[1].deltas[0] == [-286], 'VarData1 item 0 is -286, got ${t.store.datas[1].deltas[0]}'
	assert t.store.datas[1].deltas[1] == [128], 'VarData1 item 1 is 128, got ${t.store.datas[1].deltas[1]}'
	assert t.store.datas[1].deltas[6] == [198], 'VarData1 item 6 is 198, got ${t.store.datas[1].deltas[6]}'
	assert t.adv_map.present, 'Naskh carries an advance map'
	assert t.adv_map.var_idxs.len == 1415, 'advance map covers 1415 glyphs, got ${t.adv_map.var_idxs.len}'
	assert font.hvar_adv_var_idx(t, 0) == 13, 'gid 0 maps to 13, got ${font.hvar_adv_var_idx(t, 0)}'
	assert font.hvar_adv_var_idx(t, 3) == 13, 'space maps to 13, got ${font.hvar_adv_var_idx(t, 3)}'
	assert font.hvar_adv_var_idx(t, 4) == 26, 'uni0621 maps to 26, got ${font.hvar_adv_var_idx(t, 4)}'
	assert font.hvar_adv_var_idx(t, 23) == 67, 'uni062D.fina maps to 67, got ${font.hvar_adv_var_idx(t, 23)}'
	assert font.hvar_adv_var_idx(t, 181) == 65536, 'gid 181 reaches outer 1, got ${font.hvar_adv_var_idx(t, 181)}'
	assert font.hvar_adv_var_idx(t, 205) == 65542, 'gid 205 reaches (1,6), got ${font.hvar_adv_var_idx(t, 205)}'
	assert !t.lsb_map.present, 'no LSB map on Naskh'
	assert !t.rsb_map.present, 'no RSB map on Naskh'
	// Deltas beside fontTools at blend coordinates: 15 * 0.5 = 7.5 rounds
	// to 8, 58 * 0.5 = 29, -286 * 0.5 = -143.
	assert font.hvar_advance_delta(t, 4, [0.0]) or { panic('delta: ${err}') } == 0, 'uni0621 at 0 is 0'
	assert font.hvar_advance_delta(t, 4, [0.5]) or { panic('delta: ${err}') } == 8, 'uni0621 at 0.5 is 8, got ${font.hvar_advance_delta(t, 4, [0.5]) or { -9999 }}'
	assert font.hvar_advance_delta(t, 4, [1.0]) or { panic('delta: ${err}') } == 15, 'uni0621 at 1 is 15'
	assert font.hvar_advance_delta(t, 23, [0.5]) or { panic('delta: ${err}') } == 29, 'uni062D.fina at 0.5 is 29'
	assert font.hvar_advance_delta(t, 23, [1.0]) or { panic('delta: ${err}') } == 58, 'uni062D.fina at 1 is 58'
	assert font.hvar_advance_delta(t, 3, [0.5]) or { panic('delta: ${err}') } == 0, 'space never varies'
	assert font.hvar_advance_delta(t, 181, [0.5]) or { panic('delta: ${err}') } == -143, 'outer-1 item at 0.5 is -143'
	assert font.hvar_advance_delta(t, 181, [1.0]) or { panic('delta: ${err}') } == -286, 'outer-1 item at 1 is -286'
}

// NotoSansSC HVAR: the identity face. No maps (NULL offsets), one VarData
// of 31036 items in glyph order, region (0,1,1). Exclam gid 2 holds [122]:
// 61 at 0.5, 122 at 1.0. With the avar warp (0.5 becomes 0.55999...) the
// mid delta is 68, which is what the gvar phantom derivation reports at
// the same coordinates.
fn test_hvar_sc_identity_and_deltas() {
	mut f := hvar_font('NotoSansSC-Variable.ttf') or {
		hvar_skip('NotoSansSC-Variable.ttf')
		return
	}
	hvar := f.face.sfnt.table_data(font.tag_hvar)
	assert hvar.len == 62122, 'SC HVAR is 62122 bytes, got ${hvar.len}'
	t := font.hvar_parse(hvar) or { panic('SC HVAR must parse: ${err}') }
	assert t.has_store, 'SC HVAR carries a store'
	assert t.store.axis_count == 1, 'one axis'
	assert t.store.regions.len == 1, 'one region'
	assert t.store.regions[0][0].peak == 1.0, 'peak 1'
	assert t.store.datas.len == 1, 'one VarData'
	assert t.store.datas[0].deltas.len == 31036, '31036 items, got ${t.store.datas[0].deltas.len}'
	assert t.store.datas[0].deltas[0] == [0], 'gid 0 delta 0, got ${t.store.datas[0].deltas[0]}'
	assert t.store.datas[0].deltas[1] == [9], 'gid 1 delta 9, got ${t.store.datas[0].deltas[1]}'
	assert t.store.datas[0].deltas[2] == [122], 'exclam delta 122, got ${t.store.datas[0].deltas[2]}'
	assert t.store.datas[0].deltas[3] == [257], 'gid 3 delta 257, got ${t.store.datas[0].deltas[3]}'
	assert !t.adv_map.present, 'SC has no advance map (NULL offset)'
	assert font.hvar_adv_var_idx(t, 2) == 2, 'identity maps gid 2 to varIdx 2'
	assert font.hvar_advance_delta(t, 2, [0.0]) or { panic('delta: ${err}') } == 0, 'exclam at 0 is 0'
	assert font.hvar_advance_delta(t, 2, [0.5]) or { panic('delta: ${err}') } == 61, 'exclam at 0.5 is 61'
	assert font.hvar_advance_delta(t, 2, [1.0]) or { panic('delta: ${err}') } == 122, 'exclam at 1 is 122'
	// The avar warp is load-bearing: design 500 normalizes to 0.5 and
	// warps to 0.55999755859375, where 122 lands on 68.
	axes := f.variable_axes()
	avar := f.face.sfnt.table_data(font.tag_avar)
	blended := font.var_blend_coords(axes, avar, [500.0]) or { panic('blend: ${err}') }
	assert font.hvar_advance_delta(t, 2, blended) or { panic('delta: ${err}') } == 68, 'exclam at wght 500 (warped) is 68, got ${font.hvar_advance_delta(t, 2, blended) or { -9999 }}'
	dflt := font.var_blend_coords(axes, avar, [100.0]) or { panic('blend: ${err}') }
	assert font.hvar_advance_delta(t, 2, dflt) or { panic('delta: ${err}') } == 0, 'exclam at default is 0'
}

// Empty stores: FiraCode HVAR holds 1857 items over zero regions (all
// deltas zero, no maps), Cascadia HVAR holds one empty item over zero
// regions with a map of all zeros. Both parse and both answer zero at
// every coordinate.
fn test_hvar_empty_stores() {
	mut f := hvar_font('FiraCode-Variable.ttf') or {
		hvar_skip('FiraCode-Variable.ttf')
		return
	}
	hvar := f.face.sfnt.table_data(font.tag_hvar)
	assert hvar.len == 48, 'FiraCode HVAR is 48 bytes, got ${hvar.len}'
	t := font.hvar_parse(hvar) or { panic('FiraCode HVAR must parse: ${err}') }
	assert t.has_store, 'FiraCode HVAR carries a store'
	assert t.store.regions.len == 1, 'one region even when unused'
	assert t.store.datas.len == 1, 'one VarData'
	assert t.store.datas[0].deltas.len == 1857, '1857 items, got ${t.store.datas[0].deltas.len}'
	assert !t.adv_map.present, 'FiraCode has no advance map'
	assert font.hvar_advance_delta(t, 1, [0.0]) or { panic('delta: ${err}') } == 0, 'A at 0 is 0'
	assert font.hvar_advance_delta(t, 1, [0.5]) or { panic('delta: ${err}') } == 0, 'A at 0.5 is 0'
	assert font.hvar_advance_delta(t, 1, [1.0]) or { panic('delta: ${err}') } == 0, 'A at 1 is 0'
	mut g := hvar_font('CascadiaCode-Variable.ttf') or {
		hvar_skip('CascadiaCode-Variable.ttf')
		return
	}
	chvar := g.face.sfnt.table_data(font.tag_hvar)
	assert chvar.len == 47, 'Cascadia HVAR is 47 bytes, got ${chvar.len}'
	ct := font.hvar_parse(chvar) or { panic('Cascadia HVAR must parse: ${err}') }
	assert ct.has_store, 'Cascadia HVAR carries a store'
	assert ct.store.regions.len == 0, 'zero regions, got ${ct.store.regions.len}'
	assert ct.adv_map.present, 'Cascadia carries an advance map'
	assert font.hvar_adv_var_idx(ct, 1) == 0, 'A maps to 0'
	assert font.hvar_advance_delta(ct, 1, [1.0]) or { panic('delta: ${err}') } == 0, 'Cascadia advance never varies'
}

// MVAR on FiraCode: three value records (cpht->1, stro->0, xhgt->1) over
// one region (0,1,1) with items [7] and [12]. stro is 3.5 at 0.5, which
// rounds half up to 4; cpht/xhgt are 6 at 0.5 and 12 at 1.0.
fn test_mvar_fira() {
	mut f := hvar_font('FiraCode-Variable.ttf') or {
		hvar_skip('FiraCode-Variable.ttf')
		return
	}
	mvar := f.face.sfnt.table_data(font.tag_mvar)
	assert mvar.len == 68, 'FiraCode MVAR is 68 bytes, got ${mvar.len}'
	t := font.mvar_parse(mvar) or { panic('MVAR must parse: ${err}') }
	assert t.has_store, 'MVAR carries a store'
	assert t.records.len == 3, 'three value records, got ${t.records.len}'
	assert t.records[0].tag == 'cpht', 'record 0 is cpht, got ${t.records[0].tag}'
	assert t.records[0].var_idx == 1, 'cpht varIdx 1, got ${t.records[0].var_idx}'
	assert t.records[1].tag == 'stro', 'record 1 is stro, got ${t.records[1].tag}'
	assert t.records[1].var_idx == 0, 'stro varIdx 0, got ${t.records[1].var_idx}'
	assert t.records[2].tag == 'xhgt', 'record 2 is xhgt, got ${t.records[2].tag}'
	assert t.records[2].var_idx == 1, 'xhgt varIdx 1, got ${t.records[2].var_idx}'
	assert t.store.axis_count == 1, 'one axis'
	assert t.store.datas[0].deltas[0] == [7], 'item 0 is 7, got ${t.store.datas[0].deltas[0]}'
	assert t.store.datas[0].deltas[1] == [12], 'item 1 is 12, got ${t.store.datas[0].deltas[1]}'
	assert font.mvar_delta(t, 'stro', [0.0]) or { panic('delta: ${err}') } == 0, 'stro at 0 is 0'
	assert font.mvar_delta(t, 'stro', [0.5]) or { panic('delta: ${err}') } == 4, 'stro at 0.5 is 4 (3.5 rounds up)'
	assert font.mvar_delta(t, 'stro', [1.0]) or { panic('delta: ${err}') } == 7, 'stro at 1 is 7'
	assert font.mvar_delta(t, 'cpht', [0.5]) or { panic('delta: ${err}') } == 6, 'cpht at 0.5 is 6'
	assert font.mvar_delta(t, 'cpht', [1.0]) or { panic('delta: ${err}') } == 12, 'cpht at 1 is 12'
	assert font.mvar_delta(t, 'xhgt', [1.0]) or { panic('delta: ${err}') } == 12, 'xhgt at 1 is 12'
	if _ := font.mvar_delta(t, 'xxxx', [0.5]) {
		assert false, 'unknown MVAR tag must not parse'
	}
}

// cvar on CascadiaCode: two tuples over 161 CVT values, peaks -1 and +1,
// points {147,148,151,159} with deltas {-48,-48,-45,-50} and
// {+34,+40,+40,+20}. Untouched CVT values (0, 10) stay zero; the -0.5 pin
// on CVT 151 is -22.5, which rounds half up to -22.
fn test_cvar_cascadia() {
	mut f := hvar_font('CascadiaCode-Variable.ttf') or {
		hvar_skip('CascadiaCode-Variable.ttf')
		return
	}
	cvar := f.face.sfnt.table_data(font.tag_cvar)
	assert cvar.len == 42, 'Cascadia cvar is 42 bytes, got ${cvar.len}'
	// The CVT table holds 161 values; cvar needs the count to size the
	// all-points runs.
	t := font.cvar_parse(cvar, 1, 161) or { panic('cvar must parse: ${err}') }
	assert t.axis_count == 1, 'one axis'
	assert t.cvt_count == 161, '161 CVT values'
	assert t.tuples.len == 2, 'two tuples, got ${t.tuples.len}'
	assert t.tuples[0].peak == [-1.0], 'tuple 0 peak -1, got ${t.tuples[0].peak}'
	assert t.tuples[1].peak == [1.0], 'tuple 1 peak +1, got ${t.tuples[1].peak}'
	assert t.tuples[0].points == [147, 148, 151, 159], 'tuple 0 points, got ${t.tuples[0].points}'
	assert t.tuples[0].deltas == [-48, -48, -45, -50], 'tuple 0 deltas, got ${t.tuples[0].deltas}'
	assert t.tuples[1].points == [147, 148, 151, 159], 'tuple 1 points, got ${t.tuples[1].points}'
	assert t.tuples[1].deltas == [34, 40, 40, 20], 'tuple 1 deltas, got ${t.tuples[1].deltas}'
	assert font.cvar_delta(t, 147, [-1.0]) or { panic('delta: ${err}') } == -48, 'CVT 147 at -1 is -48'
	assert font.cvar_delta(t, 147, [0.0]) or { panic('delta: ${err}') } == 0, 'CVT 147 at 0 is 0'
	assert font.cvar_delta(t, 147, [0.5]) or { panic('delta: ${err}') } == 17, 'CVT 147 at 0.5 is 17'
	assert font.cvar_delta(t, 147, [1.0]) or { panic('delta: ${err}') } == 34, 'CVT 147 at +1 is 34'
	assert font.cvar_delta(t, 148, [1.0]) or { panic('delta: ${err}') } == 40, 'CVT 148 at +1 is 40'
	assert font.cvar_delta(t, 151, [-1.0]) or { panic('delta: ${err}') } == -45, 'CVT 151 at -1 is -45'
	assert font.cvar_delta(t, 151, [-0.5]) or { panic('delta: ${err}') } == -22, 'CVT 151 at -0.5 is -22 (-22.5 rounds up)'
	assert font.cvar_delta(t, 151, [1.0]) or { panic('delta: ${err}') } == 40, 'CVT 151 at +1 is 40'
	assert font.cvar_delta(t, 159, [-1.0]) or { panic('delta: ${err}') } == -50, 'CVT 159 at -1 is -50'
	assert font.cvar_delta(t, 159, [1.0]) or { panic('delta: ${err}') } == 20, 'CVT 159 at +1 is 20'
	assert font.cvar_delta(t, 0, [1.0]) or { panic('delta: ${err}') } == 0, 'CVT 0 is untouched'
	assert font.cvar_delta(t, 10, [-1.0]) or { panic('delta: ${err}') } == 0, 'CVT 10 is untouched'
	mut seen := false
	for v in t.tuples[0].deltas {
		if v != 0 {
			seen = true
		}
	}
	assert seen, 'cvar deltas are nonzero, or the pins prove nothing'
	if _ := font.cvar_delta(t, 200, [1.0]) {
		assert false, 'CVT 200 of 161 must not parse'
	}
}

// The break-fix control: zeroing the extracted deltas collapses the mid
// adjustments back to zero and away from the fontTools pins. If the
// applier ever dropped the deltas on the floor, the tests above would pass
// with zeros and this test would fail with the pins.
fn test_hvar_zeroed_deltas_breakfix() {
	mut f := hvar_font('NotoNaskhArabic-Variable.ttf') or {
		hvar_skip('NotoNaskhArabic-Variable.ttf')
		return
	}
	hvar := f.face.sfnt.table_data(font.tag_hvar)
	t := font.hvar_parse(hvar) or { panic('HVAR must parse: ${err}') }
	mid := font.hvar_advance_delta(t, 4, [0.5]) or { panic('delta: ${err}') }
	assert mid == 8, 'uni0621 at 0.5 is 8, got ${mid}'
	assert mid != 0, 'the mid delta is nonzero, or the pin proves nothing'
	// A store with the same shape but neutered deltas answers zero.
	mut neutered_datas := t.store.datas.clone()
	mut d0 := neutered_datas[0].deltas.clone()
	for i in 0 .. d0.len {
		mut row := d0[i].clone()
		for j in 0 .. row.len {
			row[j] = 0
		}
		d0[i] = row
	}
	neutered_datas[0] = font.HvarVarData{
		region_indexes: neutered_datas[0].region_indexes.clone()
		deltas:         d0
	}
	neutered := font.HvarVarStore{
		axis_count: t.store.axis_count
		regions:    t.store.regions.clone()
		datas:      neutered_datas
	}
	assert font.hvar_store_delta(neutered, true, 26, [0.5]) or { panic('delta: ${err}') } == 0, 'neutered VarData answers zero'
	assert 0 != mid, 'zeroed deltas must miss the wght pins'
	// MVAR neutering: stro at 0.5 is 4, neutered is 0.
	mut g := hvar_font('FiraCode-Variable.ttf') or {
		hvar_skip('FiraCode-Variable.ttf')
		return
	}
	mvar := g.face.sfnt.table_data(font.tag_mvar)
	mt := font.mvar_parse(mvar) or { panic('MVAR must parse: ${err}') }
	smid := font.mvar_delta(mt, 'stro', [0.5]) or { panic('delta: ${err}') }
	assert smid == 4, 'stro at 0.5 is 4, got ${smid}'
	assert font.hvar_store_delta(mt.store, mt.has_store, 0, [0.5]) or { panic('delta: ${err}') } == 4, 'stro varIdx 0 at 0.5 is 4'
	// cvar neutering: CVT 147 at +1 is 34, neutered is 0.
	mut h := hvar_font('CascadiaCode-Variable.ttf') or {
		hvar_skip('CascadiaCode-Variable.ttf')
		return
	}
	cvar := h.face.sfnt.table_data(font.tag_cvar)
	ct := font.cvar_parse(cvar, 1, 161) or { panic('cvar must parse: ${err}') }
	cmid := font.cvar_delta(ct, 147, [1.0]) or { panic('delta: ${err}') }
	assert cmid == 34, 'CVT 147 at +1 is 34, got ${cmid}'
	mut neutered_tuples := ct.tuples.clone()
	mut nt0 := neutered_tuples[1].deltas.clone()
	for i in 0 .. nt0.len {
		nt0[i] = 0
	}
	neutered_tuples[1] = font.CvarTuple{
		peak:       ct.tuples[1].peak.clone()
		start:      ct.tuples[1].start.clone()
		end:        ct.tuples[1].end.clone()
		points:     ct.tuples[1].points.clone()
		deltas:     nt0
		all_points: ct.tuples[1].all_points
	}
	neutered_ct := font.CvarTable{
		axis_count: ct.axis_count
		cvt_count:  ct.cvt_count
		tuples:     neutered_tuples
	}
	// Neutering only the +1 tuple leaves the -1 tuple, which is zero at
	// +1, so the total collapses to zero.
	assert font.cvar_delta(neutered_ct, 147, [1.0]) or { panic('delta: ${err}') } == 0, 'neutered cvar answers zero'
	assert 0 != cmid, 'zeroed cvar must miss the pins'
}

// What the readers refuse: truncated tables, bad versions, blend lengths
// that do not match the store axes, unknown MVAR tags and out-of-range CVT
// indexes. Each refusal names its table.
fn test_hvar_rejects() {
	mut f := hvar_font('NotoNaskhArabic-Variable.ttf') or {
		hvar_skip('NotoNaskhArabic-Variable.ttf')
		return
	}
	hvar := f.face.sfnt.table_data(font.tag_hvar)
	if _ := font.hvar_parse(hvar[..10]) {
		assert false, 'a ten-byte HVAR must not parse'
	}
	mut bad := hvar.clone()
	// Version 2.0 is not 1.0.
	bad[0] = 0x00
	bad[1] = 0x02
	if _ := font.hvar_parse(bad) {
		assert false, 'HVAR version 2.0 must not parse'
	} else {
		assert err.msg().contains('version'), 'the refusal names the version, got: ${err}'
	}
	t := font.hvar_parse(hvar) or { panic('HVAR must parse: ${err}') }
	if _ := font.hvar_advance_delta(t, 4, [0.5, 0.5]) {
		assert false, 'two blends for one axis must not evaluate'
	} else {
		assert err.msg().contains('blend'), 'the refusal names blends, got: ${err}'
	}
	mut g := hvar_font('FiraCode-Variable.ttf') or {
		hvar_skip('FiraCode-Variable.ttf')
		return
	}
	mvar := g.face.sfnt.table_data(font.tag_mvar)
	mt := font.mvar_parse(mvar) or { panic('MVAR must parse: ${err}') }
	if _ := font.mvar_delta(mt, 'zzzz', [0.5]) {
		assert false, 'unknown MVAR tag must not evaluate'
	}
	if _ := font.mvar_parse(mvar[..8]) {
		assert false, 'an eight-byte MVAR must not parse'
	}
	mut h := hvar_font('CascadiaCode-Variable.ttf') or {
		hvar_skip('CascadiaCode-Variable.ttf')
		return
	}
	cvar := h.face.sfnt.table_data(font.tag_cvar)
	ct := font.cvar_parse(cvar, 1, 161) or { panic('cvar must parse: ${err}') }
	if _ := font.cvar_delta(ct, 147, [0.5, 0.5]) {
		assert false, 'two blends for one cvar axis must not evaluate'
	}
	if _ := font.cvar_parse(cvar[..6], 1, 161) {
		assert false, 'a six-byte cvar must not parse'
	}
	// A static font has no HVAR or MVAR table at all.
	p := hvar_font_path('Amiri-Regular.ttf') or {
		hvar_skip('Amiri-Regular.ttf')
		return
	}
	mut s := shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
	assert s.face.sfnt.table_data(font.tag_hvar).len == 0, 'Amiri has no HVAR table'
	assert s.face.sfnt.table_data(font.tag_mvar).len == 0, 'Amiri has no MVAR table'
	if _ := font.hvar_parse(s.face.sfnt.table_data(font.tag_hvar)) {
		assert false, 'an empty HVAR must not parse'
	}
}
