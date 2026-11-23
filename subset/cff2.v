module subset

import harfara.font
import harfara.shape

// CFF2 subsetting, standalone: a read is not a rebuild.
//
// font/cff2.v reads CharStrings for inspection and the raster backend draws
// them, but neither rebuilds the table. This file rebuilds the CFF2 table
// around a kept-gid closure: a new CharStrings INDEX that keeps every kept
// glyph's bytes verbatim and replaces every dropped glyph with a single
// endchar, a rebuilt FDArray whose Font DICTs name the new Private offsets,
// and a Top DICT naming the new CharStrings/FDArray/FDSelect/VarStore
// offsets. Global Subrs, FDSelect, the VarStore, every Private DICT and both
// subr sets travel through with their bytes intact: charstring operands name
// subrs by number, not by offset, so verbatim bytes keep their meaning
// wherever the INDEX wrappers move.
//
// Glyph ids are preserved, the way the glyf and CFF1 rebuilds preserve
// them: the CharStrings INDEX keeps an entry per glyph the font declares, so
// every id in cmap, hmtx, GSUB, GPOS and GDEF still addresses the glyph it
// addressed. The price is the same as theirs: tables that name dropped
// glyphs keep naming them, and the saving is the outline data rather than
// the whole file.
//
// CID-keyed CFF is refused the way font/cff.v refuses it: its CharStrings
// are FD-indexed, not GID-indexed, so reading one as a GID would hand back
// the wrong glyph. (CFF2 is always FDArray-addressed, but its FDSelect maps
// gid to FD, which is what gid-indexing means here.)

// subset_cff2_font keeps the seed glyphs and everything they need, and
// rebuilds the font around them for a CFF2-outlined face.
//
// .notdef is always kept, for the same reason subset_font keeps it: a
// character the font does not cover draws as it.
//
// The closure is GSUB plus MATH until neither changes anything, the same
// fixpoint subset_font and subset_cff_font run. There is no glyf pass here
// because a CFF2 face has no glyf table: composites are Type 2 charstrings,
// and their sharing runs through subrs the rebuild carries.
pub fn subset_cff2_font(f &shape.Font, seed []u16) !Subset {
	if !f.has_table('CFF2') && f.outlines() != 'CFF2' {
		return error('cff2 subset: the font has no CFF2 table')
	}
	data := f.data()
	spans := spans_of(f)
	gsub := spans['GSUB'] or { Span{} }
	mut keep := []bool{len: f.num_glyphs()}
	for gid in seed {
		if int(gid) < keep.len {
			keep[gid] = true
		}
	}
	if keep.len == 0 {
		return error('cff2 subset: no glyphs in this CFF2 font to keep')
	}
	keep[0] = true
	mut closure := Closure{}
	mut passes := 0
	for {
		a := count_true(keep)
		close_over_gsub(mut keep, data, gsub, mut closure)
		close_over_math(mut keep, data, spans['MATH'] or { Span{} }, mut closure)
		passes++
		if count_true(keep) == a {
			break
		}
		if passes > 16 {
			eprintln('warning: the CFF2 glyph closure did not settle in 16 passes, stopped early')
			break
		}
	}
	built := cff2_build_sfnt(f, data, keep) or { return err }
	return Subset{
		bytes:   built.bytes
		sizes:   built.sizes
		keep:    keep
		closure: closure
	}
}

// subset_cff2_with_keep rebuilds the font around an explicit keep mask.
//
// This is the break-fix half of the API: subset_cff2_font computes the
// closure, and this rebuilds whatever mask it is handed — including one with
// a closure entry dropped — so the test can prove a dropped entry fails the
// outline comparison rather than silently drawing. .notdef is not forced
// here; the caller owns the mask outright.
pub fn subset_cff2_with_keep(f &shape.Font, keep []bool) !Subset {
	if !f.has_table('CFF2') && f.outlines() != 'CFF2' {
		return error('cff2 subset: the font has no CFF2 table')
	}
	if keep.len != f.num_glyphs() {
		return error('cff2 subset: keep holds ${keep.len} flags for ${f.num_glyphs()} CFF2 glyphs')
	}
	data := f.data()
	built := cff2_build_sfnt(f, data, keep) or { return err }
	return Subset{
		bytes:   built.bytes
		sizes:   built.sizes
		keep:    keep.clone()
		closure: Closure{}
	}
}

// ---------------------------------------------------------------- building

// cff2_build_sfnt assembles the subset sfnt around a rebuilt CFF2 table.
//
// Every table but CFF2 is copied byte for byte: ids are preserved, so cmap,
// hmtx, GSUB, GPOS and GDEF still address the glyph they addressed. The head
// checksum dance is the shared assembler the CFF1 rebuild uses, and the
// output is a plain OTTO font.
fn cff2_build_sfnt(f &shape.Font, d []u8, keep []bool) !Subset {
	spans := spans_of(f)
	cspan := spans['CFF2'] or { return error('cff2 subset: the font has no CFF2 table') }
	ctable := d[cspan.offset..imin(cspan.offset + cspan.length, d.len)]
	new_cff2 := cff2_rebuild_table(ctable, keep) or { return err }
	return assemble_sfnt_around(f, d, spans, 'CFF2', 'CFF2', new_cff2)
}

// cff2_rebuild_table rebuilds one CFF2 table around keep.
//
// Kept CharStrings are carried through byte for byte — including their
// callsubr operands, whose biases are a function of the subr counts the
// rebuild preserves — and dropped ones become a single endchar, which the
// reader accepts as an empty outline. The FDArray INDEX is rebuilt with the
// same Font DICT bytes except the Private offset, which names the Private
// block's new home; the Private blocks, both subr sets, the FDSelect and
// the VarStore travel verbatim because nothing inside them addresses the
// table by absolute offset. What changes are the three INDEX wrappers and
// the offsets that address them: a raw Top DICT with the new
// CharStrings/FDArray/FDSelect/VarStore offsets, the CharStrings INDEX,
// and the FDArray INDEX.
fn cff2_rebuild_table(ctable []u8, keep []bool) ![]u8 {
	c := font.parse_cff2(ctable) or { return err }
	if keep.len != c.num_charstrings {
		return error('cff2 subset: keep holds ${keep.len} flags for ${c.num_charstrings} charstrings')
	}
	hdr_size := int(ctable[2])
	if hdr_size < 5 || hdr_size > ctable.len {
		return error('cff2 subset: header size ${hdr_size} is outside a ${ctable.len}-byte table')
	}
	mut header := []u8{cap: hdr_size}
	for i in 0 .. hdr_size {
		header << ctable[i]
	}
	top_len := be16(ctable, 3)
	if top_len < 1 || 5 + top_len > ctable.len {
		return error('cff2 subset: Top DICT length ${top_len} is outside a ${ctable.len}-byte table')
	}
	top_entries := cff2_parse_dict(ctable[5..5 + top_len]) or { return err }
	// Global Subrs verbatim: subr calls name subrs by number, so the bytes
	// keep their meaning wherever the INDEX sits.
	_, _, _, glob_end := cff_index_info(ctable, c.global_subrs_at) or { return err }
	mut glob_block := []u8{cap: glob_end - c.global_subrs_at}
	for i in c.global_subrs_at .. glob_end {
		glob_block << ctable[i]
	}
	// Kept bytes verbatim, dropped as one endchar: an empty charstring the
	// reader accepts as drawing nothing.
	mut entries := [][]u8{cap: c.num_charstrings}
	for gid in 0 .. c.num_charstrings {
		if keep[gid] {
			s, e := cff_index_range(ctable, c.charstrings_at, gid) or { return err }
			entries << ctable[s..e].clone()
		} else {
			entries << [u8(14)]
		}
	}
	new_strings := cff_build_index(entries)
	// FDSelect verbatim: it maps gid ranges to FDs, and gids are preserved.
	mut fdsel_block := []u8{}
	if c.fdselect_at >= 0 {
		fdsel_end := cff2_fdselect_end(ctable, c) or { return err }
		fdsel_block = ctable[c.fdselect_at..fdsel_end].clone()
	}
	// Font DICTs verbatim except the Private offset, which names the new
	// home. The Private size stays: the block travels whole.
	mut fd_dicts := [][]u8{cap: c.fds.len}
	mut priv_sizes := []int{cap: c.fds.len}
	mut priv_subrels := []int{cap: c.fds.len}
	for fdi in 0 .. c.fds.len {
		s, e := cff_index_range(ctable, c.fdarray_at, fdi) or { return err }
		fd_dicts << ctable[s..e].clone()
		priv_sizes << c.fds[fdi].private_len
		if c.fds[fdi].local_subrs_at >= 0 {
			priv_subrels << c.fds[fdi].local_subrs_at - c.fds[fdi].private_off
		} else {
			priv_subrels << -1
		}
	}
	// The VarStore travels verbatim: every offset inside it is
	// store-relative, so the bytes keep their meaning at any table offset.
	mut vs_block := []u8{}
	if c.vstore_at >= 0 {
		vs_end := font.hvar_var_store_end(ctable, c.vstore_at) or { return err }
		if vs_end > ctable.len {
			return error('cff2 subset: VarStore ends past a ${ctable.len}-byte table')
		}
		vs_block = ctable[c.vstore_at..vs_end].clone()
	}
	// Private blocks verbatim per FD, with the subrs gap preserved in zeros
	// the way the CFF1 rebuild preserves it: the gap is padding, not data,
	// and zeros keep it padding.
	mut priv_blocks := [][]u8{cap: c.fds.len}
	mut subr_blocks := [][]u8{cap: c.fds.len}
	for fdi in 0 .. c.fds.len {
		poff := c.fds[fdi].private_off
		plen := c.fds[fdi].private_len
		if poff < 0 || plen < 0 || poff + plen > ctable.len {
			return error('cff2 subset: FD ${fdi} Private range is outside the table')
		}
		priv_blocks << ctable[poff..poff + plen].clone()
		if c.fds[fdi].local_subrs_at >= 0 {
			_, _, _, sub_end := cff_index_info(ctable, c.fds[fdi].local_subrs_at) or {
				return err
			}
			subr_blocks << ctable[c.fds[fdi].local_subrs_at..sub_end].clone()
		} else {
			subr_blocks << []u8{}
		}
	}
	// New offsets hang off the new Top and FDArray sizes, which hang off the
	// new offsets when an encoding grows. Offsets here are table-absolute
	// except the Top DICT's, which the CFF2 spec measures from byte 2; the
	// loop below settles them the way the CFF1 rebuild settles its own.
	mut top_block := []u8{}
	mut fdarray_block := []u8{}
	mut priv_offs := []int{len: c.fds.len}
	// The first guess uses the old sizes, which is what makes the common
	// case settle on the first pass: most offsets keep their width.
	mut top_guess := top_len
	mut fda_guess := 0
	{
		_, _, _, fda_end := cff_index_info(ctable, c.fdarray_at) or { return err }
		fda_guess = fda_end - c.fdarray_at
	}
	for _ in 0 .. 4 {
		base := hdr_size + top_guess
		cs_at := base + glob_block.len
		fdsel_at := cs_at + new_strings.len
		fda_at := fdsel_at + fdsel_block.len
		vs_at := fda_at + fda_guess
		mut cursor := vs_at + vs_block.len
		for fdi in 0 .. c.fds.len {
			priv_offs[fdi] = cursor
			cursor += priv_blocks[fdi].len
			if subr_blocks[fdi].len > 0 {
				target := priv_offs[fdi] + priv_subrels[fdi]
				for cursor < target {
					cursor++
				}
				cursor += subr_blocks[fdi].len
			}
		}
		mut updated := []Cff2DictEntry{cap: top_entries.len}
		for e in top_entries {
			if e.op == 17 {
				updated << Cff2DictEntry{
					op:   17
					args: [cff_encode_dict_int(cs_at - 2)]
				}
			} else if e.op == 1236 {
				updated << Cff2DictEntry{
					op:   1236
					args: [cff_encode_dict_int(fda_at - 2)]
				}
			} else if e.op == 1237 && c.fdselect_at >= 0 {
				updated << Cff2DictEntry{
					op:   1237
					args: [cff_encode_dict_int(fdsel_at - 2)]
				}
			} else if e.op == 24 && c.vstore_at >= 0 {
				updated << Cff2DictEntry{
					op:   24
					args: [cff_encode_dict_int(vs_at - 2)]
				}
			} else {
				updated << e
			}
		}
		top_candidate := cff2_encode_dict(updated)
		mut fd_entries := [][]u8{cap: fd_dicts.len}
		for fdi, raw in fd_dicts {
			fd_entries << cff2_patch_private(raw, priv_sizes[fdi], priv_offs[fdi]) or {
				return err
			}
		}
		fda_candidate := cff_build_index(fd_entries)
		if top_candidate.len == top_guess && fda_candidate.len == fda_guess {
			top_block = top_candidate.clone()
			fdarray_block = fda_candidate.clone()
			break
		}
		top_guess = top_candidate.len
		fda_guess = fda_candidate.len
		top_block = top_candidate.clone()
		fdarray_block = fda_candidate.clone()
	}
	if top_block.len == 0 || fdarray_block.len == 0 {
		return error('cff2 subset: the Top DICT and FDArray rebuild did not settle')
	}
	// Recompute the final layout from the settled sizes rather than trusting
	// the loop's last guess: the guess that settled is the layout.
	cs_at := hdr_size + top_block.len + glob_block.len
	fdsel_at := cs_at + new_strings.len
	fda_at := fdsel_at + fdsel_block.len
	vs_at := fda_at + fdarray_block.len
	// Assemble in file order: the header with its patched Top length, the
	// blocks the offsets address, then each Private region with its subrs.
	mut out := []u8{cap: vs_at + vs_block.len + 64}
	for b in header {
		out << b
	}
	// The header names the Top DICT length at bytes 3-4.
	out[3] = u8((top_block.len >> 8) & 0xff)
	out[4] = u8(top_block.len & 0xff)
	for b in top_block {
		out << b
	}
	for b in glob_block {
		out << b
	}
	for b in new_strings {
		out << b
	}
	for b in fdsel_block {
		out << b
	}
	for b in fdarray_block {
		out << b
	}
	for b in vs_block {
		out << b
	}
	for fdi in 0 .. c.fds.len {
		for b in priv_blocks[fdi] {
			out << b
		}
		if subr_blocks[fdi].len > 0 {
			target := priv_offs[fdi] + priv_subrels[fdi]
			for out.len < target {
				out << u8(0)
			}
			if out.len != target {
				return error('cff2 subset: FD ${fdi} Local Subrs offset overlaps its Private dict')
			}
			for b in subr_blocks[fdi] {
				out << b
			}
		}
	}
	return out
}

// ---------------------------------------------------------------- DICT

// Cff2DictEntry is one DICT operator with its raw number bytes: the bytes
// travel through untouched except for the offsets the rebuild patches, so a
// BCD real or an unknown operator survives byte-identical.
struct Cff2DictEntry {
	op   int
	args [][]u8
}

// cff2_parse_dict splits raw DICT bytes into entries. Every number form is
// accepted — including the 30 BCD real, captured raw and never interpreted —
// and operators are single bytes up to 21 plus 12 b escapes. Anything else
// is refused with its position rather than guessed at; a DICT ending in
// numbers with no operator is refused rather than silently dropping them.
fn cff2_parse_dict(data []u8) ![]Cff2DictEntry {
	mut out := []Cff2DictEntry{}
	mut args := [][]u8{}
	mut i := 0
	for i < data.len {
		b := int(data[i])
		if b == 12 {
			if i + 1 >= data.len {
				return error('cff2 subset: truncated DICT escape operator')
			}
			out << Cff2DictEntry{
				op:   1200 + int(data[i + 1])
				args: args
			}
			args = [][]u8{}
			i += 2
			continue
		}
		if b >= 32 && b <= 246 {
			args << data[i..i + 1]
			i++
			continue
		}
		if (b >= 247 && b <= 250) || (b >= 251 && b <= 254) {
			if i + 1 >= data.len {
				return error('cff2 subset: truncated DICT number')
			}
			args << data[i..i + 2]
			i += 2
			continue
		}
		if b == 28 {
			if i + 2 >= data.len {
				return error('cff2 subset: truncated DICT number')
			}
			args << data[i..i + 3]
			i += 3
			continue
		}
		if b == 29 {
			if i + 4 >= data.len {
				return error('cff2 subset: truncated DICT number')
			}
			args << data[i..i + 5]
			i += 5
			continue
		}
		if b == 30 {
			start := i
			i++
			mut done := false
			for i < data.len && !done {
				nb := int(data[i])
				i++
				if nb >> 4 == 0xf || nb & 0xf == 0xf {
					done = true
				}
			}
			if !done {
				return error('cff2 subset: truncated DICT real')
			}
			args << data[start..i]
			continue
		}
		if b <= 21 || b == 24 {
			// Single-byte operators run to 21; 24 is CFF2's VariationStore.
			// 22, 23 and 25-31 name no DICT operator in CFF or CFF2 and stay
			// refused rather than preserved as unknown.
			out << Cff2DictEntry{
				op:   b
				args: args
			}
			args = [][]u8{}
			i++
			continue
		}
		return error('cff2 subset: reserved DICT operator ${b}')
	}
	if args.len > 0 {
		return error('cff2 subset: ${args.len} trailing DICT numbers with no operator')
	}
	return out
}

// cff2_encode_dict writes entries back to DICT bytes: raw numbers untouched,
// patched ones re-encoded by the caller, operators in place.
fn cff2_encode_dict(entries []Cff2DictEntry) []u8 {
	mut out := []u8{}
	for e in entries {
		for a in e.args {
			for b in a {
				out << b
			}
		}
		if e.op >= 1200 {
			out << u8(12)
			out << u8(e.op - 1200)
		} else {
			out << u8(e.op)
		}
	}
	return out
}

// cff2_dict_int decodes one raw DICT integer. Reals are not integers: the
// offsets this rebuild patches are ints by specification, and a real where
// an offset belongs is a refusal, not a rounding.
fn cff2_dict_int(raw []u8) !int {
	if raw.len == 0 {
		return error('cff2 subset: DICT value is empty')
	}
	b0 := int(raw[0])
	if b0 >= 32 && b0 <= 246 {
		return b0 - 139
	}
	if b0 >= 247 && b0 <= 250 {
		if raw.len < 2 {
			return error('cff2 subset: truncated DICT integer')
		}
		return (b0 - 247) * 256 + int(raw[1]) + 108
	}
	if b0 >= 251 && b0 <= 254 {
		if raw.len < 2 {
			return error('cff2 subset: truncated DICT integer')
		}
		return -(b0 - 251) * 256 - int(raw[1]) - 108
	}
	if b0 == 28 {
		if raw.len < 3 {
			return error('cff2 subset: truncated DICT integer')
		}
		mut v := be16(raw, 1)
		if v >= 0x8000 {
			v -= 0x10000
		}
		return v
	}
	if b0 == 29 {
		if raw.len < 5 {
			return error('cff2 subset: truncated DICT integer')
		}
		v64 := be32(raw, 1)
		mut v := int(v64)
		if v64 >= i64(0x80000000) {
			v = int(v64 - i64(0x100000000))
		}
		return v
	}
	return error('cff2 subset: DICT value is not an integer')
}

// cff2_patch_private rewrites one Font DICT's Private entry (operator 18)
// with a new table-absolute offset, keeping the size. Everything else in
// the DICT — BlueValues, the BlueScale real, subr counts — travels
// byte-identical, which is what keeps the rebuild honest about tables it
// does not interpret.
fn cff2_patch_private(raw []u8, priv_size int, priv_off int) ![]u8 {
	entries := cff2_parse_dict(raw) or { return err }
	mut updated := []Cff2DictEntry{cap: entries.len}
	mut found := false
	for e in entries {
		if e.op == 18 {
			if e.args.len != 2 {
				return error('cff2 subset: Private names ${e.args.len} values, not a size and an offset')
			}
			size := cff2_dict_int(e.args[0]) or { return err }
			if size != priv_size {
				return error('cff2 subset: Private size ${size} disagrees with the parsed ${priv_size}')
			}
			updated << Cff2DictEntry{
				op:   18
				args: [cff_encode_dict_int(size), cff_encode_dict_int(priv_off)]
			}
			found = true
		} else {
			updated << e
		}
	}
	if !found {
		return error('cff2 subset: Font DICT has no Private entry')
	}
	return cff2_encode_dict(updated)
}

// cff2_fdselect_end answers the first byte past the FDSelect table: format 0
// is one byte per glyph after the format byte, format 3 is its header plus
// three bytes per range plus the two-byte sentinel. Anything else was
// refused by the reader, so reaching it here is a corrupt table, not a
// new format.
fn cff2_fdselect_end(ctable []u8, c font.Cff2) !int {
	at := c.fdselect_at
	if at < 0 || at >= ctable.len {
		return error('cff2 subset: FDSelect offset ${at} is outside a ${ctable.len}-byte table')
	}
	fmt := int(ctable[at])
	if fmt == 0 {
		end := at + 1 + c.num_charstrings
		if end > ctable.len {
			return error('cff2 subset: FDSelect format 0 runs past the table')
		}
		return end
	}
	if fmt == 3 {
		if at + 3 > ctable.len {
			return error('cff2 subset: FDSelect format 3 header is truncated')
		}
		n_ranges := be16(ctable, at + 1)
		end := at + 3 + n_ranges * 3 + 2
		if end > ctable.len {
			return error('cff2 subset: FDSelect format 3 runs past the table')
		}
		return end
	}
	return error('cff2 subset: FDSelect format ${fmt} is not supported')
}
