module harfara

import os
import harfara.shape

// The reference glyph cache: keyed on (font id, gid, size, subpixel offset),
// owned by the caller. This file pins the key matrix, the hit behaviour and
// the break-fix controls that fail if a field is dropped from the key.
//
// This copy of the helpers lives here because `v test <single_file>`
// compiles that file and not its siblings, so a helper in another test file
// is one this file cannot see.
fn corpus_font_path(name string) ?string {
	mut dirs := []string{}
	for d in [os.getenv('HARFARA_TEST_FONTS'), 'testdata/fonts', windows_font_dir()] {
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

fn corpus_font_bytes(name string) ?[]u8 {
	p := corpus_font_path(name) or { return none }
	return os.read_bytes(p) or { panic('${p} is not readable: ${err}') }
}

$if windows {
	fn windows_font_dir() string {
		return 'C:\\Windows\\Fonts'
	}
} $else {
	fn windows_font_dir() string {
		return ''
	}
}

fn skip_missing(name string) {
	line := 'SKIP ${name} is in neither testdata/fonts nor the platform font directory'
	path := os.getenv('HARFARA_SKIP_LOG')
	if path != '' {
		mut f := os.open_append(path) or { return }
		f.writeln(line) or { return }
		f.close()
		return
	}
	println(line)
}

// Amiri is the committed raster source: its Latin capitals have real ink at
// every size below, so a test that rasterizes nothing is a test that
// measures nothing.
fn amiri() ?&shape.Font {
	data := corpus_font_bytes('Amiri-Regular.ttf') or {
		skip_missing('Amiri-Regular.ttf')
		return none
	}
	return shape.load_font_bytes(data) or { panic(err) }
}

fn test_cache_key_equal_when_all_fields_match() {
	a := shape.new_cache_key(7, 100, 16.0, 1, 0)
	b := shape.new_cache_key(7, 100, 16.0, 1, 0)
	assert a == b
	assert a.str() == b.str()
	assert a.em_px() == 16.0
}

fn test_cache_key_differs_in_each_dimension() {
	base := shape.new_cache_key(7, 100, 16.0, 1, 0)
	// Each variant differs from the base in exactly one field, so a key that
	// dropped that field would read the two as equal and this would fail.
	assert base != shape.new_cache_key(8, 100, 16.0, 1, 0), 'font id is in the key'
	assert base != shape.new_cache_key(7, 101, 16.0, 1, 0), 'gid is in the key'
	assert base != shape.new_cache_key(7, 100, 32.0, 1, 0), 'size is in the key'
	assert base != shape.new_cache_key(7, 100, 16.0, 2, 0), 'subpixel x is in the key'
	assert base != shape.new_cache_key(7, 100, 16.0, 1, 2), 'subpixel y is in the key'
	assert base.str() != shape.new_cache_key(8, 100, 16.0, 1, 0).str()
	assert base.str() != shape.new_cache_key(7, 101, 16.0, 1, 0).str()
	assert base.str() != shape.new_cache_key(7, 100, 32.0, 1, 0).str()
	assert base.str() != shape.new_cache_key(7, 100, 16.0, 2, 0).str()
	assert base.str() != shape.new_cache_key(7, 100, 16.0, 1, 2).str()
}

fn test_cache_hit_returns_identical_bytes_without_rerasterizing() {
	f := amiri() or { return }
	gid := f.glyph_index(`A`)
	assert gid != 0
	mut c := shape.new_cache()
	first := c.get_or_rasterize(1, f, gid, 32.0, 0, 0)
	assert first.width > 0 && first.height > 0, 'the fixture glyph has ink at 32 px'
	second := c.get_or_rasterize(1, f, gid, 32.0, 0, 0)
	assert second.width == first.width && second.height == first.height
	assert second.left == first.left && second.top == first.top
	assert second.coverage.len == first.coverage.len
	for i in 0 .. first.coverage.len {
		assert second.coverage[i] == first.coverage[i], 'a hit returns the stored bytes'
	}
	assert c.misses == 1, 'the second fetch was a hit, not a rasterization'
	assert c.hits == 1
	assert c.len() == 1
}

fn test_cache_different_subpixel_offsets_miss() {
	f := amiri() or { return }
	gid := f.glyph_index(`A`)
	mut c := shape.new_cache()
	c.get_or_rasterize(1, f, gid, 32.0, 0, 0)
	other := c.get_or_rasterize(1, f, gid, 32.0, 2, 0)
	assert other.width > 0 && other.height > 0
	assert c.misses == 2, 'the shifted fetch rasterized again'
	assert c.hits == 0
	assert c.len() == 2, 'both offsets coexist'
}

fn test_cache_size_in_key_breaks_without_it() {
	// Two entries differing ONLY in size. If size ever drops out of the key
	// or its encoding, the second fetch overwrites the first and len stays 1.
	f := amiri() or { return }
	gid := f.glyph_index(`A`)
	mut c := shape.new_cache()
	small := c.get_or_rasterize(1, f, gid, 16.0, 0, 0)
	big := c.get_or_rasterize(1, f, gid, 32.0, 0, 0)
	assert c.len() == 2, '16 px and 32 px coexist'
	assert small.width > 0 && big.width > 0
	assert small.width != big.width, 'the two entries hold their own sizes'
	again := c.get_or_rasterize(1, f, gid, 16.0, 0, 0)
	assert again.width == small.width
	assert c.hits == 1 && c.misses == 2
}

fn test_cache_subpixel_in_key_breaks_without_it() {
	// Two entries differing ONLY in subpixel x. Same shape as the size
	// control above: without the field in the key, len stays 1.
	f := amiri() or { return }
	gid := f.glyph_index(`A`)
	mut c := shape.new_cache()
	c.get_or_rasterize(1, f, gid, 32.0, 0, 0)
	c.get_or_rasterize(1, f, gid, 32.0, 2, 0)
	assert c.len() == 2, 'subpixel 0 and 2 coexist'
	assert c.misses == 2 && c.hits == 0
}

fn test_cache_font_id_in_key() {
	// Two entries differing ONLY in font id. The same &Font answers both —
	// the id is the caller's assignment, not the pointer — and aliasing two
	// fonts under one id would mix their ink, which is the documented limit.
	f := amiri() or { return }
	gid := f.glyph_index(`A`)
	mut c := shape.new_cache()
	c.get_or_rasterize(1, f, gid, 32.0, 0, 0)
	c.get_or_rasterize(2, f, gid, 32.0, 0, 0)
	assert c.len() == 2, 'font ids 1 and 2 coexist'
	c.get_or_rasterize(1, f, gid, 32.0, 0, 0)
	assert c.len() == 2 && c.hits == 1 && c.misses == 2
}

fn test_cache_gid_in_key() {
	f := amiri() or { return }
	a := f.glyph_index(`A`)
	b := f.glyph_index(`B`)
	assert a != b && a != 0 && b != 0
	mut c := shape.new_cache()
	c.get_or_rasterize(1, f, a, 32.0, 0, 0)
	c.get_or_rasterize(1, f, b, 32.0, 0, 0)
	assert c.len() == 2, 'two glyphs coexist'
	assert c.misses == 2 && c.hits == 0
}

fn test_cache_clear_empties_and_resets() {
	f := amiri() or { return }
	gid := f.glyph_index(`A`)
	mut c := shape.new_cache()
	c.get_or_rasterize(1, f, gid, 32.0, 0, 0)
	c.get_or_rasterize(1, f, gid, 32.0, 2, 0)
	assert c.len() == 2
	c.clear()
	assert c.len() == 0
	assert c.hits == 0 && c.misses == 0
	c.get_or_rasterize(1, f, gid, 32.0, 0, 0)
	assert c.misses == 1 && c.hits == 0, 'a cleared cache rasterizes again'
}
