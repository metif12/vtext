module providers

// Standalone font discovery helpers.
//
// vtext never reads the host: no VUI_FONT reads, no config-dir walks, no
// fc-match exec, no Android XML parses in this library. The caller owns
// that; this module answers the pure decisions any caller reuses: search
// order and filename-variant heuristics. CoreText / DirectWrite remain
// Phase 7.8 per-OS providers with none elsewhere; legacy kern stays refused
// by design (GPOS only), so discovery migrates filenames, not tables.

// DiscoveryInput names every source a caller may consult, in priority
// order. Empty entries are skipped; the first readable entry wins. The
// caller decides readability (os.is_file / is_readable); this function only
// orders.
pub struct DiscoveryInput {
pub:
	env_font     string
	user_fonts   []string
	system_fonts []string
	bundled      []string
}

// discovery_order flattens inputs to one ordered candidate list.
pub fn discovery_order(inp DiscoveryInput) []string {
	mut out := []string{}
	if inp.env_font != '' {
		out << inp.env_font
	}
	for f in inp.user_fonts {
		if f != '' {
			out << f
		}
	}
	for f in inp.system_fonts {
		if f != '' {
			out << f
		}
	}
	for f in inp.bundled {
		if f != '' {
			out << f
		}
	}
	return out
}

// pick_first answers the first candidate the is_readable predicate accepts.
pub fn pick_first(cands []string, is_readable fn (string) bool) string {
	for c in cands {
		if is_readable(c) {
			return c
		}
	}
	return ''
}

// variant_kind names the filename heuristic vlib/os.font.get_path_variant
// implements. Bold/italic/mono map a -Regular stem or well-known suffix;
// normal answers the input unchanged.
pub enum VariantKind {
	normal
	bold
	italic
	mono
}

// variant_path answers the filename for kind beside font_path without
// touching the filesystem. It mirrors the -Regular/-Bold/-Italic/Mono
// rules callers already rely on so vlib can delegate here.
pub fn variant_path(font_path string, kind VariantKind) string {
	if kind == .normal || font_path == '' {
		return font_path
	}
	lower := font_path.to_lower()
	match kind {
		.bold {
			if font_path.ends_with('-Regular.ttf') {
				return font_path.replace('-Regular.ttf', '-Bold.ttf')
			}
			if lower.starts_with('arial') {
				return font_path + 'bd'
			}
			return font_path.replace('.ttf', '-bold.ttf')
		}
		.italic {
			if font_path.ends_with('-Regular.ttf') {
				return font_path.replace('-Regular.ttf', '-Italic.ttf')
			}
			return font_path.replace('.ttf', 'Italic.ttf')
		}
		.mono {
			if font_path.ends_with('-Regular.ttf') {
				return font_path.replace('-Regular.ttf', 'Mono-Regular.ttf')
			}
			return font_path.replace('.ttf', 'Mono.ttf')
		}
		else {
			return font_path
		}
	}
}

// is_power_of_two answers whether n is a valid atlas edge for callers that
// keep the old sfons power-of-two rule.
pub fn is_power_of_two(n int) bool {
	return n in [2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768]
}
