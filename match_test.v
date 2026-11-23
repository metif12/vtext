module harfara

import os
import harfara.shape
import harfara.providers

// Tests for slice 8.8: fontconfig sort-by-match with charset and language
// coverage queries, and the fvar named instances on the inspect API.
//
// This file is self-contained: `v test match_test.v` compiles this file and
// not its siblings, so the font-path helper and the skip logger are duplicated
// here rather than borrowed from another test file. That is the same reason
// every other test file carries its own copy.
//
// Every expected instance number below was read from the committed
// NotoNaskhArabic-Variable.ttf with fontTools: 4 instances, subfamily name
// IDs 257/259/261/263, names Regular/Medium/SemiBold/Bold, all at wght
// 400/500/600/700 on the single wght axis (400 to 700, default 400). Two
// independent readers agreeing is evidence; one reader agreeing with itself
// is not.

// match_font_path is where a test font is: the override first, then the
// committed corpus. There is no platform font-directory fallback here, because
// every font this file needs is committed and a host font of the same name is
// a different font.
fn match_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('HARFARA_TEST_FONTS'), 'testdata/fonts'] {
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

// match_skip records why a test could not run. A skip that prints nothing is a
// failure pretending to be a pass, so it is written where tools/run_tests.v
// reads it rather than to stdout, which a passing test's output discards.
fn match_skip(name string) {
	line := 'SKIP ${name}'
	path := os.getenv('HARFARA_SKIP_LOG')
	if path != '' {
		mut f := os.open_append(path) or { return }
		f.writeln(line) or { return }
		f.close()
		return
	}
	println(line)
}

fn match_font(name string) ?&shape.Font {
	p := match_font_path(name) or {
		match_skip('${name} is in neither $HARFARA_TEST_FONTS nor testdata/fonts')
		return none
	}
	return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
}

fn test_variable_instances_agree_with_fonttools() {
	f := match_font('NotoNaskhArabic-Variable.ttf') or { return }
	assert f.is_variable(), 'the variable Naskh has an fvar table'

	insts := f.variable_instances()
	assert insts.len == 4, 'fontTools reads 4 fvar instances, got ${insts.len}'
	assert insts[0].name_id == 257, 'first instance is name ID 257, got ${insts[0].name_id}'
	assert insts[1].name_id == 259, 'second instance is name ID 259, got ${insts[1].name_id}'
	assert insts[2].name_id == 261, 'third instance is name ID 261, got ${insts[2].name_id}'
	assert insts[3].name_id == 263, 'fourth instance is name ID 263, got ${insts[3].name_id}'

	// The single wght axis runs 400 to 700, so each instance is one number.
	assert insts[0].coords == [400.0], 'Regular sits at wght 400, got ${insts[0].coords}'
	assert insts[1].coords == [500.0], 'Medium sits at wght 500, got ${insts[1].coords}'
	assert insts[2].coords == [600.0], 'SemiBold sits at wght 600, got ${insts[2].coords}'
	assert insts[3].coords == [700.0], 'Bold sits at wght 700, got ${insts[3].coords}'

	// Each instance names every axis of the single-axis font with one number,
	// and the axis reader agrees with fontTools on the single wght axis.
	axes := f.variable_axes()
	assert axes.len == 1, 'fontTools reads 1 fvar axis, got ${axes.len}'
	assert axes[0].tag == 'wght', 'the axis is wght, got ${axes[0].tag}'
	assert axes[0].minimum == 400.0, 'wght minimum is 400, got ${axes[0].minimum}'
	assert axes[0].deflt == 400.0, 'wght default is 400, got ${axes[0].deflt}'
	assert axes[0].maximum == 700.0, 'wght maximum is 700, got ${axes[0].maximum}'
	for inst in insts {
		assert inst.coords.len == axes.len, 'one coordinate per axis, got ${inst.coords.len} for ${axes.len} axes'
	}
}

fn test_variable_instance_names_need_the_name_table() {
	// The break-fix control: the fvar records carry only the numeric IDs above
	// (257, 259, 261, 263) and no string at all, so the names below can only
	// come from joining them against the `name` table. Removing that join
	// answers four empty strings, which is what this fails with.
	f := match_font('NotoNaskhArabic-Variable.ttf') or { return }
	names := f.variable_instance_names()
	assert names == ['Regular', 'Medium', 'SemiBold', 'Bold'], 'expected the four UI names, got ${names}'
	for n in names {
		assert n != '', 'a named instance has a non-empty name the raw record cannot supply'
	}
}

fn test_variable_instances_are_empty_without_fvar() {
	f := match_font('NotoNaskhArabic-Regular.ttf') or { return }
	assert !f.is_variable(), 'the static Naskh has no fvar table'
	assert f.variable_instances().len == 0, 'a font with no fvar has no named instances'
	assert f.variable_instance_names().len == 0, 'and no instance names either'
}

$if linux {
	// The provider half, pinned where fontconfig exists. A family that names
	// itself is required before anything is asserted, the way the match test
	// requires it: asserting on a fallback would pin whatever the host
	// happened to substitute.
	fn test_linux_sort_names_best_match_first() {
		for fam in ['DejaVu Sans', 'DejaVu Serif', 'Ubuntu'] {
			sorted := providers.system_fonts_sorted(fam, 5) or { continue }
			if sorted.len == 0 || sorted[0].family != fam {
				continue
			}
			for s in sorted {
				assert os.exists(s.path), 'sorted match ${s.path} exists'
			}
			assert sorted.len <= 5, 'the sort is capped at the requested limit'
			assert providers.system_font_covers_char(fam, rune(0x41)), '${fam} covers A'
			assert providers.system_font_covers_lang(fam, 'en'), '${fam} claims English'
			return
		}
		match_skip('a self-naming DejaVu Sans, DejaVu Serif or Ubuntu in fontconfig')
	}
} $else {
	fn test_provider_stubs_answer_none_off_linux() {
		// No provider off Linux: the match answers none, the sort answers none,
		// and both coverage queries answer false, each with the reason printed.
		if _ := providers.system_font('DejaVu Sans') {
			panic('system_font answers off linux with no provider')
		}
		if _ := providers.system_fonts_sorted('DejaVu Sans', 5) {
			panic('system_fonts_sorted answers off linux with no provider')
		}
		if _ := providers.system_fonts_sorted('', 5) {
			panic('an empty family sorts off linux with no provider')
		}
		assert providers.system_font_covers_char('DejaVu Sans', rune(0x41)) == false, 'no charset off linux'
		assert providers.system_font_covers_lang('DejaVu Sans', 'en') == false, 'no language set off linux'
		match_skip('linux fontconfig')
	}
}
