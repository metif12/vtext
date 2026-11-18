module vtext

import os
import vtext.shape
import vtext.layout

// Tests for the F1 profiler (Phase 11): the opt-in per-stage shaping
// costs on the Thai/Khmer/Myanmar bench rows. The inputs mirror the
// rival-bench PerfCases rune for rune, so the profiled shapes are the
// same shapes the perf table reports. Every pin is self-consistency,
// never a clock reading: the profiled line must equal the unprofiled
// line glyph for glyph (profiling is silent), and every stage must have
// recorded its spans (a neutered record call fails its test).
//
// The faces ship in testdata/fonts with their OFL texts, so they load on
// every platform with no skips: no host font, no platform directory.
fn profiler_font(name string) ?&shape.Font {
	for dir in ['testdata/fonts', os.getenv('VTEXT_TEST_FONTS')] {
		if dir == '' {
			continue
		}
		p := os.join_path(dir, name)
		if os.exists(p) {
			return shape.load_font_file(p) or { panic('${p} is not a readable font: ${err}') }
		}
	}
	return none
}

fn profiler_shape(face &shape.Font, cps []rune) (layout.Line, layout.Profiler) {
	ctx := shape.new_context()
	fs := shape.new_font_set_of(face)
	opts := layout.LayoutOptions{}
	plain := layout.layout_paragraph_with(ctx, cps, .auto, fs, 32.0, &opts)
	mut prof := layout.Profiler{}
	profiled := layout.layout_paragraph_profiled(ctx, cps, .auto, fs, 32.0, &opts, mut prof)
	assert profiled.glyphs.len == plain.glyphs.len, 'profiling must not change the glyph count'
	for i in 0 .. plain.glyphs.len {
		assert profiled.glyphs[i].gid == plain.glyphs[i].gid, 'profiling must not change gid ${i}'
		assert profiled.glyphs[i].advance == plain.glyphs[i].advance, 'profiling must not change advance ${i}'
		assert profiled.glyphs[i].cluster == plain.glyphs[i].cluster, 'profiling must not change cluster ${i}'
	}
	assert profiled.width == plain.width, 'profiling must not change the line width'
	return profiled, prof
}

fn profiler_check_stages(prof layout.Profiler) {
	for s in [layout.Stage.segment, .reorder, .gsub, .gpos, .place] {
		assert prof.stage_calls(s) >= 1, 'stage ${s} recorded no spans'
		assert prof.stage_ticks(s) >= 0, 'stage ${s} has negative ticks'
	}
	assert prof.total_ticks() == prof.stage_ticks(.segment) + prof.stage_ticks(.reorder) +
		prof.stage_ticks(.gsub) + prof.stage_ticks(.gpos) + prof.stage_ticks(.place), 'total must be the sum of the five stages'
}

fn test_profiler_thai_bench_row() {
	th := profiler_font('NotoSansThai-Variable.ttf') or { return }
	cps := [rune(0x0E2A), 0x0E27, 0x0E31, 0x0E2A, 0x0E14, 0x0E35]
	line, prof := profiler_shape(th, cps)
	assert line.glyphs.len == 6, 'thai bench row draws six glyphs, got ${line.glyphs.len}'
	profiler_check_stages(prof)
}

fn test_profiler_khmer_bench_row() {
	kh := profiler_font('NotoSansKhmer-Variable.ttf') or { return }
	cps := [rune(0x179F), 0x17BD, 0x179F, 0x17D2, 0x178F, 0x17B8]
	line, prof := profiler_shape(kh, cps)
	assert line.glyphs.len > 0, 'khmer bench row draws glyphs'
	profiler_check_stages(prof)
}

fn test_profiler_myanmar_bench_row() {
	my := profiler_font('NotoSansMyanmar-Variable.ttf') or { return }
	cps := [rune(0x1019), 0x1004, 0x103A, 0x1039, 0x1002, 0x101C, 0x102C]
	line, prof := profiler_shape(my, cps)
	assert line.glyphs.len > 0, 'myanmar bench row draws glyphs'
	profiler_check_stages(prof)
}

fn test_profiler_disabled_is_silent() {
	prof := layout.Profiler{}
	assert !prof.enabled, 'a fresh profiler is disabled'
	assert prof.total_ticks() == 0, 'a fresh profiler carries no ticks'
	for s in [layout.Stage.segment, .reorder, .gsub, .gpos, .place] {
		assert prof.stage_calls(s) == 0, 'a fresh profiler carries no calls'
		assert prof.stage_units(s) == 0, 'a fresh profiler carries no units'
	}
}
