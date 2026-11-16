module main

// Rival A/B harness, the 7.11 second half: the same workload timed on vtext
// and on the stack it replaces, on the same box, in one table.
//
// The V half times vtext (line layout at 16 px for 1024-character Latin and
// Arabic paragraphs, Amiri 'A' rasterized at 32 px cold and through the
// caller-owned cache); tools/rival_bench.py times uharfbuzz shaping and
// Pillow rasterization of the same inputs, built by the same repeat rule.
// Best of five batches of twenty on both sides, because a loaded box lies
// about absolutes and the ratio is the finding.
//
// What each side does differs and the table says so: vtext lays the line
// out (bidi, joining, GSUB/GPOS, measurement) where HarfBuzz only shapes,
// and Pillow renders with its own bundled FreeType at default flags where
// vtext fills unhinted. Throughput is the comparison; correctness is proven
// elsewhere, per part, and a part with no baseline makes no claim.
//
// The harness degrades the platform-ratchet way: no interpreter or no
// rival import prints the vtext half with the reason instead of a table
// with holes. The README A/B numbers come from a run of this tool and are
// re-measured per release; the method is the pin, the absolutes are the
// box's.
//
// Usage: v -cc gcc run tools/rival_bench.v (from the module root)
// The optimizing C compiler matters: a tcc build measures the compiler's
// checks, not the engine, and the published ratio would blame the wrong
// one. -prod would be stricter still, but the tree is not -prod-clean yet
// (pre-existing strict-check errors, e.g. the documented infx cast in
// ucd/properties.v); making it clean is its own slice, and the table below
// names the flags it was measured with.

import os
import time
import vtext.shape
import vtext.layout

const latin_text = 'The quick brown fox jumps over the lazy dog near the river bank at dusk'
const arabic_text = 'سلام دنیا بر شما ای دوست قدیمی من'

fn repeat_to(text string, n int) []rune {
	mut out := []rune{cap: n + 8}
	base := text.runes()
	for out.len < n {
		if out.len > 0 {
			out << rune(` `)
		}
		for c in base {
			if out.len >= n {
				break
			}
			out << c
		}
	}
	return out
}

struct RivalRow {
	op string
	ns f64
	n  int
}

fn parse_rival_line(line string) ?RivalRow {
	// rival shape latin-1024: 1234.5 ns/op (n=20)
	// The op itself holds a space, so the split anchors on the ends: the
	// 'rival ' prefix, the last ': ' before the number, and the trailing
	// 'ns/op (n=N)'.
	if !line.starts_with('rival ') {
		return none
	}
	rest := line.all_after('rival ')
	sep := rest.last_index(': ') or { return none }
	op := rest[..sep]
	tail := rest[sep + 2..].split(' ')
	if tail.len != 3 || tail[1] != 'ns/op' || !tail[2].starts_with('(n=') {
		return none
	}
	ns := tail[0].f64()
	n := tail[2].trim('()').all_after('=').int()
	return RivalRow{
		op: op
		ns: ns
		n:  n
	}
}

fn best_of_shape(ctx &shape.Context, cps []rune, base shape.Direction, fs &shape.FontSet) (i64, int) {
	mut best := i64(1 << 60)
	mut glyphs := 0
	for _ in 0 .. 5 {
		start := time.sys_mono_now()
		for _ in 0 .. 20 {
			line := layout.layout_paragraph(ctx, cps, base, fs, 16.0)
			glyphs = line.glyphs.len
		}
		took := i64(time.sys_mono_now() - start)
		if took < best {
			best = took
		}
	}
	return best / 20, glyphs
}

fn best_of_raster_miss(mut f &shape.Font) i64 {
	// Sustained miss throughput: twenty different glyphs per batch, so no
	// batch re-renders a glyph it already drew. Latin capitals A through T,
	// all present in Amiri. Per-op is one cold-ish render, warm caches.
	mut gids := []u16{cap: 20}
	for i in 0 .. 20 {
		gids << f.glyph_index(rune(int(`A`) + i))
	}
	mut best := i64(1 << 60)
	for _ in 0 .. 5 {
		start := time.sys_mono_now()
		for gid in gids {
			_ = f.rasterize(gid, 32.0, 0, 0)
		}
		took := i64(time.sys_mono_now() - start)
		if took < best {
			best = took
		}
	}
	return best / 20
}

fn python_candidates() []string {
	return ['python3', 'python']
}

fn main() {
	ctx := shape.new_context()
	mut latin_font := shape.load_font_file('testdata/fonts/FiraCode-Variable.ttf') or {
		panic(err)
	}
	mut amiri := shape.load_font_file('testdata/fonts/Amiri-Regular.ttf') or { panic(err) }
	mut latin_fs := shape.new_font_set()
	latin_fs.add(latin_font)
	mut arabic_fs := shape.new_font_set()
	arabic_fs.add(amiri)
	latin := repeat_to(latin_text, 1024)
	arabic := repeat_to(arabic_text, 1024)
	assert latin.len == 1024 && arabic.len == 1024, 'the repeat rule builds the rival workload'
	ltook, lglyphs := best_of_shape(ctx, latin, .ltr, latin_fs)
	atook, aglyphs := best_of_shape(ctx, arabic, .rtl, arabic_fs)
	println('vtext shape+layout latin-1024: ${f64(ltook) / f64(lglyphs):.1f} ns/glyph (${lglyphs} glyphs)')
	println('vtext shape+layout arabic-1024: ${f64(atook) / f64(aglyphs):.1f} ns/glyph (${aglyphs} glyphs)')
	gid := amiri.glyph_index(`A`)
	miss := best_of_raster_miss(mut amiri)
	println('vtext raster amiri-A-T-32 miss: ${f64(miss):.1f} ns/op (n=20)')
	mut cache := shape.new_cache()
	_ = cache.get_or_rasterize(0, amiri, gid, 32.0, 0, 0)
	mut best_hit := i64(1 << 60)
	for _ in 0 .. 5 {
		start := time.sys_mono_now()
		for _ in 0 .. 20 {
			_ = cache.get_or_rasterize(0, amiri, gid, 32.0, 0, 0)
		}
		took := i64(time.sys_mono_now() - start)
		if took < best_hit {
			best_hit = took
		}
	}
	hit := best_hit / 20
	println('vtext raster amiri-A-32 hit: ${f64(hit):.1f} ns/op (n=20)')
	println('vtext cache: ${cache.hits} hits, ${cache.misses} misses')
	if hit >= miss {
		eprintln('rival-bench REFUSED: a cache hit (${hit}ns) must beat a sustained miss (${miss}ns)')
		exit(1)
	}
	// The rival half runs in its own process; the first interpreter that
	// answers runs it, and none answering is a loud skip, not a hole.
	mut rival_out := ''
	for py in python_candidates() {
		r := os.exec_opt([py, 'tools/rival_bench.py']) or { continue }
		if r.exit_code == 0 {
			rival_out = r.output
			break
		}
		if r.exit_code == 2 {
			println(r.output.trim_space())
			println('A/B table needs the rival half; the vtext half above stands alone.')
			return
		}
	}
	if rival_out == '' {
		println('rival SKIPPED: no python interpreter answered')
		println('A/B table needs the rival half; the vtext half above stands alone.')
		return
	}
	mut rivals := map[string]RivalRow{}
	for line in rival_out.split_into_lines() {
		row := parse_rival_line(line.trim_space()) or { continue }
		rivals[row.op] = row
	}
	// Per-op rows pair one vtext timing with its rival by workload name.
	// Shape pairs per 1024-character paragraph — the repeat rule builds the
	// same paragraph on both sides, so no glyph-count normalization is owed
	// to either engine's clustering.
	println('')
	println('op                      | vtext        | rival        | vtext/rival')
	println('------------------------+--------------+--------------+------------')
	print_ab('shape latin-1024', f64(ltook), rivals['shape latin-1024'] or {
		RivalRow{ ns: -1 }
	}, 'ns/paragraph')
	print_ab('shape arabic-1024', f64(atook), rivals['shape arabic-1024'] or {
		RivalRow{ ns: -1 }
	}, 'ns/paragraph')
	print_ab('raster amiri-A-T-32 miss', f64(miss), rivals['raster amiri-A-32'] or {
		RivalRow{ ns: -1 }
	}, 'ns/op')
	print_ab('raster amiri-A-32 hit', f64(hit), rivals['raster amiri-A-32'] or {
		RivalRow{ ns: -1 }
	}, 'ns/op')
}

fn print_ab(name string, ours f64, rival RivalRow, unit string) {
	if rival.ns < 0 {
		println('${name} | ${ours:.1f} ${unit} | (no rival row) | n/a')
		return
	}
	println('${name} | ${ours:.1f} ${unit} | ${rival.ns:.1f} ${unit} | ${ours / rival.ns:.2f}x')
}
