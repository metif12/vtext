module main

// Rival A/B harness, the 7.11 second half: the same workload timed on harfara
// and on the stack it replaces, on the same box, in one table.
//
// The V half times harfara (line layout and wrapping at 16 px for
// 1024-character paragraphs in every script the corpus covers plus
// marks/digits/bidi char types, Amiri 'A' rasterized at 32 px cold and
// through the caller-owned cache, one fontconfig family match, one font
// load); tools/rival_bench.py times uharfbuzz shaping, a Pango wrap at the
// same 400 px width, an fc-match lookup and a fontTools load of the same
// inputs, built by the same repeat rule.
// Best of five batches of twenty on both sides, because a loaded box lies
// about absolutes and the ratio is the finding.
//
// What each side does differs and the table says so: harfara lays the line
// out (bidi, joining, GSUB/GPOS, measurement) where HarfBuzz only shapes;
// Pango lays out and wraps where harfara wraps; fc-match spawns a process
// where the provider calls the library; fontTools parses into Python
// objects where harfara parses into its own tables; Pillow renders with its
// own bundled FreeType at default flags where harfara fills hinted.
// Throughput is the comparison; correctness is proven elsewhere, per part,
// and a part with no baseline makes no claim.
//
// The harness degrades the platform-ratchet way: no interpreter or no
// rival import prints the harfara half with the reason instead of a table
// with holes. The PERF.md numbers come from a run of this tool and are
// re-measured per release; the method is the pin, the absolutes are the
// box's. The CI gate reads its baselines out of PERF.md, so a table edit
// keeps the marker comments around it intact.
//
// Usage: v -prod -cc gcc run tools/rival_bench.v (from the module root)
// The optimizing C compiler matters: a tcc build measures the compiler's
// checks, not the engine, and the published ratio would blame the wrong
// one. The tree is -prod-clean since the IN enum member landed (UCD IN
// was missing from LineBreakClass and one subset loop carried an unused
// value); the PERF.md table names the flags it was measured with, and
// -cc gcc without -prod still works but measures -O0 codegen.

import os
import time
import harfara.shape
import harfara.layout
import harfara.providers

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

fn repeat_to_runes(base []rune, n int) []rune {
	mut out := []rune{cap: n + 8}
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

// PerfCase is one script or char-type workload beyond the latin/arabic pair
// above, which stays exactly as it was so its baselines keep measuring the
// same paragraphs. Samples are short real words pinned by the suites named
// in the comment beside each row — never invented text — repeated to 1024
// by the same repeat rule.
struct PerfCase {
	id        string
	font_file string
	dir       shape.Direction
	cps       []rune
}

fn perf_cases() []PerfCase {
	return [
		PerfCase{'hebrew', 'testdata/fonts/NotoSansHebrew-Variable.ttf', .rtl, [
			rune(0x05E9),
			rune(0x05B8),
			rune(0x05C1),
			rune(0x05DC),
			rune(0x05D5),
			rune(0x05B9),
			rune(0x05DD),
		]},
		PerfCase{'cjk', 'testdata/fonts/NotoSansSC-Variable.ttf', .ltr, [
			rune(0x4E2D),
			rune(0x6587),
		]},
		PerfCase{'thai', 'testdata/fonts/NotoSansThai-Variable.ttf', .ltr, [
			rune(0x0E2A),
			rune(0x0E27),
			rune(0x0E31),
			rune(0x0E2A),
			rune(0x0E14),
			rune(0x0E35),
		]},
		PerfCase{'lao', 'testdata/fonts/NotoSansLao-Variable.ttf', .ltr, [
			rune(0x0EAA),
			rune(0x0EB0),
			rune(0x0E9A),
			rune(0x0EB2),
			rune(0x0E8D),
			rune(0x0E94),
			rune(0x0EB5),
		]},
		PerfCase{'khmer', 'testdata/fonts/NotoSansKhmer-Variable.ttf', .ltr, [
			rune(0x179F),
			rune(0x17BD),
			rune(0x179F),
			rune(0x17D2),
			rune(0x178F),
			rune(0x17B8),
		]},
		PerfCase{'myanmar', 'testdata/fonts/NotoSansMyanmar-Variable.ttf', .ltr, [
			rune(0x1019),
			rune(0x1004),
			rune(0x103A),
			rune(0x1039),
			rune(0x1002),
			rune(0x101C),
			rune(0x102C),
		]},
		PerfCase{'syriac', 'testdata/fonts/NotoSansSyriac-Variable.ttf', .rtl, [
			rune(0x072B),
			rune(0x0720),
			rune(0x0721),
			rune(0x0710),
		]},
		PerfCase{'thaana', 'testdata/fonts/NotoSansThaana-Variable.ttf', .rtl, [
			rune(0x078B),
			rune(0x07A8),
			rune(0x0788),
			rune(0x07AC),
			rune(0x0780),
			rune(0x07A8),
		]},
		PerfCase{'nko', 'testdata/fonts/NotoSansNKo-Regular.ttf', .rtl, [
			rune(0x07D2),
			rune(0x07DE),
			rune(0x07CF),
		]},
		PerfCase{'georgian', 'testdata/fonts/NotoSansGeorgian-Variable.ttf', .ltr, [
			rune(0x10D2),
			rune(0x10D0),
			rune(0x10DB),
			rune(0x10D0),
			rune(0x10E0),
			rune(0x10EF),
			rune(0x10DD),
			rune(0x10D1),
			rune(0x10D0),
		]},
		PerfCase{'armenian', 'testdata/fonts/NotoSansArmenian-Variable.ttf', .ltr, [
			rune(0x0562),
			rune(0x0561),
			rune(0x0580),
			rune(0x0565),
			rune(0x0582),
		]},
		PerfCase{'ethiopic', 'testdata/fonts/NotoSansEthiopic-Variable.ttf', .ltr, [
			rune(0x1230),
			rune(0x120B),
			rune(0x121D),
		]},
		PerfCase{'devanagari', 'testdata/fonts/NotoSansDevanagari-Variable.ttf', .ltr, [
			rune(0x0928),
			rune(0x092E),
			rune(0x0938),
			rune(0x094D),
			rune(0x0924),
			rune(0x0947),
		]},
		PerfCase{'bengali', 'testdata/fonts/NotoSansBengali-Variable.ttf', .ltr, [
			rune(0x09A8),
			rune(0x09AE),
			rune(0x09B8),
			rune(0x09CD),
			rune(0x09A4),
			rune(0x09C7),
		]},
		PerfCase{'nastaliq', 'testdata/fonts/NotoNastaliqUrdu-Regular.ttf', .rtl, [
			rune(0x0633),
			rune(0x0644),
			rune(0x0627),
			rune(0x0645),
			rune(0x0020),
			rune(0x062F),
			rune(0x0646),
			rune(0x06CC),
			rune(0x0627),
		]},
		PerfCase{'marks', 'testdata/fonts/Amiri-Regular.ttf', .rtl, [
			rune(0x0628),
			rune(0x0650),
			rune(0x0633),
			rune(0x0652),
			rune(0x0645),
			rune(0x0650),
			rune(0x0020),
			rune(0x0627),
			rune(0x0644),
			rune(0x0644),
			rune(0x064E),
			rune(0x0647),
			rune(0x0020),
			rune(0x0627),
			rune(0x0644),
			rune(0x0631),
			rune(0x0651),
			rune(0x062D),
			rune(0x0652),
			rune(0x0645),
			rune(0x0670),
			rune(0x0646),
			rune(0x0020),
			rune(0x0627),
			rune(0x0644),
			rune(0x0631),
			rune(0x0651),
			rune(0x062D),
			rune(0x0650),
			rune(0x062C),
			rune(0x0645),
			rune(0x0650),
		]},
		PerfCase{'digits', 'testdata/fonts/Amiri-Regular.ttf', .rtl, [
			rune(0x06F1),
			rune(0x06F2),
			rune(0x06F3),
			rune(0x0020),
			rune(0x0641),
			rune(0x0627),
			rune(0x0631),
			rune(0x0633),
			rune(0x06CC),
			rune(0x0020),
			rune(0x0061),
			rune(0x0062),
			rune(0x0063),
			rune(0x0020),
			rune(0x06F4),
			rune(0x06F5),
			rune(0x06F6),
		]},
		PerfCase{'bidi', 'testdata/fonts/Amiri-Regular.ttf', .rtl, [
			rune(0x0061),
			rune(0x0062),
			rune(0x0063),
			rune(0x0020),
			rune(0x0633),
			rune(0x0644),
			rune(0x0627),
			rune(0x0645),
			rune(0x0020),
			rune(0x0031),
			rune(0x0032),
			rune(0x0033),
			rune(0x0020),
			rune(0x0064),
			rune(0x0065),
			rune(0x0066),
		]},
	]
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

fn best_of_wrap(ctx &shape.Context, cps []rune, base shape.Direction, fs &shape.FontSet) (i64, int) {
	mut best := i64(1 << 60)
	mut lines := 0
	for _ in 0 .. 5 {
		start := time.sys_mono_now()
		for _ in 0 .. 20 {
			wrapped := layout.wrap_paragraph(ctx, cps, base, fs, 16.0, 400.0)
			lines = wrapped.len
		}
		took := i64(time.sys_mono_now() - start)
		if took < best {
			best = took
		}
	}
	return best / 20, lines
}

fn best_of_discovery(family string) ?i64 {
	// A miss answers none, which is a skip with its reason rather than a
	// timed row: CI installs the corpus so Amiri resolves there.
	if _ := providers.system_font(family) {
	} else {
		return none
	}
	mut best := i64(1 << 60)
	for _ in 0 .. 5 {
		start := time.sys_mono_now()
		for _ in 0 .. 20 {
			_ = providers.system_font(family) or { continue }
		}
		took := i64(time.sys_mono_now() - start)
		if took < best {
			best = took
		}
	}
	return best / 20
}

fn best_of_inspect(path string) i64 {
	mut best := i64(1 << 60)
	for _ in 0 .. 5 {
		start := time.sys_mono_now()
		for _ in 0 .. 20 {
			f := shape.load_font_file(path) or { panic(err) }
			_ = f.num_glyphs()
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
	println('harfara shape+layout latin-1024: ${f64(ltook) / f64(lglyphs):.1f} ns/glyph (${lglyphs} glyphs)')
	println('harfara shape+layout arabic-1024: ${f64(atook) / f64(aglyphs):.1f} ns/glyph (${aglyphs} glyphs)')
	mut case_took := []i64{}
	mut case_wrap := []i64{}
	for pc in perf_cases() {
		mut f := shape.load_font_file(pc.font_file) or { panic(err) }
		mut fs := shape.new_font_set()
		fs.add(f)
		text := repeat_to_runes(pc.cps, 1024)
		assert text.len == 1024, 'the repeat rule builds the rival workload'
		took, glyphs := best_of_shape(ctx, text, pc.dir, fs)
		println('harfara shape ${pc.id}-1024: ${f64(took) / f64(glyphs):.1f} ns/glyph (${glyphs} glyphs)')
		case_took << took
		wtook, wlines := best_of_wrap(ctx, text, pc.dir, fs)
		println('harfara layout ${pc.id}-wrap-1024: ${f64(wtook):.1f} ns/paragraph (${wlines} lines)')
		case_wrap << wtook
	}
	gid := amiri.glyph_index(`A`)
	miss := best_of_raster_miss(mut amiri)
	println('harfara raster amiri-A-T-32 miss: ${f64(miss):.1f} ns/op (n=20)')
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
	println('harfara raster amiri-A-32 hit: ${f64(hit):.1f} ns/op (n=20)')
	println('harfara cache: ${cache.hits} hits, ${cache.misses} misses')
	if hit >= miss {
		eprintln('rival-bench REFUSED: a cache hit (${hit}ns) must beat a sustained miss (${miss}ns)')
		exit(1)
	}
	lwrap, llines := best_of_wrap(ctx, latin, .ltr, latin_fs)
	awrap, alines := best_of_wrap(ctx, arabic, .rtl, arabic_fs)
	println('harfara layout latin-wrap-1024: ${f64(lwrap):.1f} ns/paragraph (${llines} lines)')
	println('harfara layout arabic-wrap-1024: ${f64(awrap):.1f} ns/paragraph (${alines} lines)')
	ins := best_of_inspect('testdata/fonts/Amiri-Regular.ttf')
	println('harfara inspect Amiri-load: ${f64(ins):.1f} ns/op (n=20)')
	mut disc := i64(-1)
	if d := best_of_discovery('Amiri') {
		disc = d
		println('harfara discovery fontconfig-match: ${f64(disc):.1f} ns/op (n=20)')
	} else {
		println('harfara discovery fontconfig-match: SKIPPED (Amiri not resolvable here; CI installs the corpus)')
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
			println('A/B table needs the rival half; the harfara half above stands alone.')
			return
		}
	}
	if rival_out == '' {
		println('rival SKIPPED: no python interpreter answered')
		println('A/B table needs the rival half; the harfara half above stands alone.')
		return
	}
	mut rivals := map[string]RivalRow{}
	for line in rival_out.split_into_lines() {
		row := parse_rival_line(line.trim_space()) or { continue }
		rivals[row.op] = row
	}
	// Per-op rows pair one harfara timing with its rival by workload name.
	// Shape pairs per 1024-character paragraph — the repeat rule builds the
	// same paragraph on both sides, so no glyph-count normalization is owed
	// to either engine's clustering.
	println('')
	println('op                      | harfara        | rival        | harfara/rival')
	println('------------------------+--------------+--------------+------------')
	print_ab('shape latin-1024', f64(ltook), rivals['shape latin-1024'] or {
		RivalRow{ ns: -1 }
	}, 'ns/paragraph')
	print_ab('shape arabic-1024', f64(atook), rivals['shape arabic-1024'] or {
		RivalRow{ ns: -1 }
	}, 'ns/paragraph')
	for i, pc in perf_cases() {
		print_ab('shape ${pc.id}-1024', f64(case_took[i]), rivals['shape ${pc.id}-1024'] or {
			RivalRow{ ns: -1 }
		}, 'ns/paragraph')
	}
	print_ab('raster amiri-A-T-32 miss', f64(miss), rivals['raster amiri-A-32'] or {
		RivalRow{ ns: -1 }
	}, 'ns/op')
	print_ab('raster amiri-A-32 hit', f64(hit), rivals['raster amiri-A-32'] or {
		RivalRow{ ns: -1 }
	}, 'ns/op')
	print_ab('layout latin-wrap-1024', f64(lwrap), rivals['layout latin-wrap-1024'] or {
		RivalRow{ ns: -1 }
	}, 'ns/paragraph')
	print_ab('layout arabic-wrap-1024', f64(awrap), rivals['layout arabic-wrap-1024'] or {
		RivalRow{ ns: -1 }
	}, 'ns/paragraph')
	for i, pc in perf_cases() {
		print_ab('layout ${pc.id}-wrap-1024', f64(case_wrap[i]), rivals['layout ${pc.id}-wrap-1024'] or {
			RivalRow{ ns: -1 }
		}, 'ns/paragraph')
	}
	print_ab('inspect fonttools-load', f64(ins), rivals['inspect fonttools-load'] or {
		RivalRow{ ns: -1 }
	}, 'ns/op')
	if disc >= 0 {
		print_ab('discovery fontconfig-match', f64(disc), rivals['discovery fontconfig-match'] or {
			RivalRow{ ns: -1 }
		}, 'ns/op')
	} else {
		println('discovery fontconfig-match | (no harfara measurement) |  | n/a')
	}
}

fn print_ab(name string, ours f64, rival RivalRow, unit string) {
	if rival.ns < 0 {
		println('${name} | ${ours:.1f} ${unit} | (no rival row) | n/a')
		return
	}
	println('${name} | ${ours:.1f} ${unit} | ${rival.ns:.1f} ${unit} | ${ours / rival.ns:.2f}x')
}
