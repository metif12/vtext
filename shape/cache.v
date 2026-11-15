module shape

import math
import vtext.raster

// The reference glyph cache: the only honest key, written once so no caller
// hand-rolls it twice. The boundary holds — the engine never caches and the
// caller owns the Cache value — but a cache keyed on anything less than
// (font, gid, size, subpixel offset) is wrong, and that key is the same in
// every caller.
//
// A Cache is a memoisation of Font.rasterize, which is a pure function of its
// inputs: the same font, glyph, size and quarter-pixel offset always produce
// the same coverage. What the cache buys is skipping the re-rasterization,
// not a different answer. Rasterization is about 3.9 microseconds per glyph,
// so this matters in a tight draw loop and nowhere else; see the performance
// section in ROADMAP.md for why it was never the layout bottleneck.
//
// Font identity is a caller-assigned id, and that is deliberate. Nothing on
// Font is stable across calls: face is a pointer, so it is object identity —
// two loads of the same file are different objects, and the address dangles
// once the font is freed; path is empty for a font built from memory and one
// file can hold several faces, so it neither names memory fonts nor
// disambiguates a collection; hashing the font bytes on every lookup would
// put an O(font) read on the lookup path that nobody measured. The caller
// already assigns such an id — vweb keys its own GlyphKey on one — so the
// key takes it as a u64 (an index into the caller's own font list does).
//
// The limits travel with the choice: two fonts sharing one id share entries,
// so one id must never name two different (file, face) pairs, nor two
// variation instances once instancing lands (Phase 7.10), since the outlines
// differ. One file loaded twice under one id shares entries, which is
// correct: the ink is a pure function of the bytes.
//
// Size is keyed by exact f64 bits, with no bucketing: 16.0 and 16.000001 are
// different keys. A caller that wants fewer entries quantises before calling.
// Subpixel offsets are the quarters rasterize takes, 0 to 3, passed through
// unvalidated — a whole pixel or more shifts the ink as far as it says.
//
// There is no eviction: the map is unbounded and the caller evicts, with
// clear, when its own budget says so (a size change, a font unload, memory
// pressure). A bound here would be a policy this library cannot set without
// knowing the caller's display backend.
//
// Bitmaps come back sharing the cached coverage: treat them as read-only and
// clone coverage before drawing through anything that mutates it. hits and
// misses count lookups since the last clear, so a caller can measure whether
// the cache is earning its keep.

// CacheKey names one rasterization: a font id the caller assigned, a glyph
// index within that font, an em size, and a quarter-pixel subpixel offset.
pub struct CacheKey {
pub:
	// font_id is the caller's own id for the font, stable across calls by
	// the caller's own assignment. See the module comment for the limits.
	font_id u64
	// gid is the glyph index within the font. Zero is .notdef, which is a
	// legitimate cache entry: it rasterizes the same way every time.
	gid u16
	// size_bits is the em size as f64 bits. Read it back with em_px.
	size_bits u64
	// sub_x and sub_y are the quarter-pixel offsets rasterize takes.
	sub_x i32
	sub_y i32
}

// new_cache_key builds the key for one rasterization. em_px is stored as its
// exact bits, so two sizes that differ by one ulp are different keys.
pub fn new_cache_key(font_id u64, gid u16, em_px f64, sub_x i32, sub_y i32) CacheKey {
	return CacheKey{
		font_id:   font_id
		gid:       gid
		size_bits: math.f64_bits(em_px)
		sub_x:     sub_x
		sub_y:     sub_y
	}
}

// em_px reads the size back out of the key.
pub fn (k CacheKey) em_px() f64 {
	return math.f64_from_bits(k.size_bits)
}

// == compares every field: two keys are equal only when the font, the glyph,
// the size bits and both subpixel offsets all agree.
pub fn (a CacheKey) == (b CacheKey) bool {
	return a.font_id == b.font_id && a.gid == b.gid && a.size_bits == b.size_bits
		&& a.sub_x == b.sub_x && a.sub_y == b.sub_y
}

// str is the canonical encoding of the key, and the hash story: V maps take
// no struct keys, so the Cache is keyed on this string. Every field appears
// in it, which is what makes dropping a field from the key a failing test
// rather than a silent alias.
pub fn (k CacheKey) str() string {
	return '${k.font_id}:${k.gid}:${k.size_bits}:${k.sub_x}:${k.sub_y}'
}

// Cache is a caller-owned store of rasterized glyphs, keyed on CacheKey. The
// caller creates it, holds it, clears it and drops it; the engine never sees
// it. It is not safe to share between threads without the caller's own lock,
// for the same reason Font carries no cache itself.
pub struct Cache {
mut:
	entries map[string]raster.GlyphBitmap
pub mut:
	// hits and misses count lookups since construction or the last clear.
	hits   int
	misses int
}

// new_cache returns an empty cache.
pub fn new_cache() Cache {
	return Cache{
		entries: map[string]raster.GlyphBitmap{}
	}
}

// get_or_rasterize answers the bitmap for one glyph, rasterizing on a miss
// and remembering the result. font is only touched on a miss: a hit returns
// the stored coverage without calling back into the font at all.
pub fn (mut c Cache) get_or_rasterize(font_id u64, font &Font, gid u16, em_px f64, sub_x i32, sub_y i32) raster.GlyphBitmap {
	key := new_cache_key(font_id, gid, em_px, sub_x, sub_y).str()
	if key in c.entries {
		c.hits++
		return c.entries[key]
	}
	bm := font.rasterize(gid, em_px, sub_x, sub_y)
	c.entries[key] = bm
	c.misses++
	return bm
}

// len is the number of stored bitmaps.
pub fn (c &Cache) len() int {
	return c.entries.len
}

// clear drops every stored bitmap and resets the hit and miss counts, so the
// cache reads as newly made. Call it when the budget says so: the map itself
// never evicts.
pub fn (mut c Cache) clear() {
	c.entries = map[string]raster.GlyphBitmap{}
	c.hits = 0
	c.misses = 0
}
