module layout

import time

// F1 is the opt-in per-stage shaping profiler: five counters beside the
// pipeline, silent unless the caller asks. layout_paragraph_with runs the
// same code with a disabled profiler and answers exactly what it always
// did; layout_paragraph_profiled enables the caller's profiler and records
// every stage. Adding a script never touches this file: the stages are
// the pipeline's, not any script's.
//
// The stage map, fixed where the calls sit in layout_paragraph_inner:
//   - segment: normalization, bidi resolution and run shaping (joining
//     forms through glyph lookup) — everything that turns text into
//     shaped runs.
//   - reorder: indic_visual — the split-vowel growth plus the repha,
//     matra and script-tail moves, per bidi sequence.
//   - gsub: substitute_glyphs per font — the fusion pass.
//   - gpos: pair kern, singles and mark positioning — the placement pass.
//   - place: spacing, glyph placing, tabs, measuring and alignment —
//     the line-assembly pass.
//
// Ticks are monotonic nanoseconds from time.sys_mono_now; counts and
// units are deterministic (spans entered, glyphs or runs seen), so tests
// pin the shape of a profile without depending on the clock.
pub enum Stage {
	segment
	reorder
	gsub
	gpos
	place
}

const stage_count = 5

// Profiler collects per-stage shaping costs. The zero value is disabled:
// every record call returns without touching the clock, which is what
// keeps the default path exactly as fast as it was. The profiled entry
// point enables the caller's profiler for the run.
pub struct Profiler {
pub mut:
	enabled bool
	ticks   [5]i64
	calls   [5]int
	units   [5]int
}

// stage_ticks answers the accumulated nanoseconds for one stage.
pub fn (p &Profiler) stage_ticks(s Stage) i64 {
	return p.ticks[int(s)]
}

// stage_calls answers how many spans one stage recorded.
pub fn (p &Profiler) stage_calls(s Stage) int {
	return p.calls[int(s)]
}

// stage_units answers how many glyphs or runs one stage saw.
pub fn (p &Profiler) stage_units(s Stage) int {
	return p.units[int(s)]
}

// total_ticks answers the sum over all five stages.
pub fn (p &Profiler) total_ticks() i64 {
	mut total := i64(0)
	for i in 0 .. stage_count {
		total += p.ticks[i]
	}
	return total
}

// begin reads the clock for one span, or nothing when disabled.
fn (mut p Profiler) begin() u64 {
	if !p.enabled {
		return 0
	}
	return time.sys_mono_now()
}

// end folds one span into its stage, or nothing when disabled.
fn (mut p Profiler) end(s Stage, start u64, units int) {
	if !p.enabled {
		return
	}
	p.ticks[int(s)] += i64(time.sys_mono_now() - start)
	p.calls[int(s)]++
	p.units[int(s)] += units
}
