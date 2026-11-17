module providers

// directwrite is the Windows provider: family in, file path out, through
// DirectWrite.
//
// The walk follows the documented DirectWrite client path: DWriteCreateFactory
// for the factory, GetSystemFontCollection, FindFamilyName, GetFontFamily,
// GetFirstMatchingFont, then the local-file-loader key back to a path with
// IDWriteLocalFontFileLoader::GetFilePathFromKey. The factory step is the
// DLL export rather than CoCreateInstance: measured on Windows 11,
// CoCreateInstance answers REGDB_E_CLASSNOTREG because no factory coclass is
// registered (dwrite.dll exports only DWriteCreateFactory), and Microsoft
// prescribes DWriteCreateFactory for the IDWriteFactory object. The matched
// family is read off the family object beside the path the way fontconfig
// reports it, so a fallback would name itself; this walk never falls back,
// so the two agree. Anything unusable on the way there answers none with the
// reason printed, never a wrong font, which is the documented stub kept as
// the failure path. Off Windows there is no DirectWrite and the answer is
// none the same way. Nothing links unless a caller imports providers: the
// dwrite import library only, through the factory export and the interface
// vtables. Nothing in this file imports vlib.

// DwGuid mirrors the C GUID layout DirectWrite and COM take: one 32-bit
// word, two 16-bit words, then eight bytes, sixteen bytes with no padding.
// It is a plain V struct at top level (rather than a C struct inside the
// windows branch) so the generated C always carries its body; only the
// windows branch below constructs one, and it crosses the C boundary only as
// an untyped pointer. It is not named GUID: windows.h owns that name in the
// generated C.
struct DwGuid {
	data1 u32
	data2 u16
	data3 u16
	data4 [8]u8
}

$if windows {
	#include <windows.h>
	#include <dwrite.h>
}

#flag windows -ldwrite

$if windows {
	// C.DWriteCreateFactory is the DLL export that creates the factory; the
	// factory type travels as a plain word (shared below) and the interface
	// id and the new factory as untyped pointers, so no header type crosses
	// the V boundary by name.
	fn C.DWriteCreateFactory(factory_type u32, iid voidptr, factory &voidptr) i32

	// dw_factory_shared is DWRITE_FACTORY_TYPE_SHARED: the documented default,
	// which lets DirectWrite share its loader registration and cached font
	// data instead of sandboxing this lookup in an isolated factory.
	const dw_factory_shared = u32(0)
	// dw_weight_normal, dw_stretch_normal and dw_style_normal name the regular
	// face: DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL and
	// DWRITE_FONT_STYLE_NORMAL.
	const dw_weight_normal = u32(400)
	const dw_stretch_normal = u32(5)
	const dw_style_normal = u32(0)

	// The vtable slots this walk calls, read off dwrite.h: three IUnknown
	// entries first, then the interface methods in header order.
	const dw_slot_get_system_collection = 3
	const dw_slot_release = 2
	const dw_slot_query_interface = 0
	const dw_slot_find_family = 5
	const dw_slot_get_family = 4
	const dw_slot_first_matching = 7
	const dw_slot_family_names = 6
	const dw_slot_create_face = 13
	const dw_slot_get_files = 4
	const dw_slot_reference_key = 3
	const dw_slot_get_loader = 4
	const dw_slot_path_length = 4
	const dw_slot_path_from_key = 5
	const dw_slot_strings_count = 3
	const dw_slot_find_locale = 4
	const dw_slot_string_length = 7
	const dw_slot_get_string = 8

	type DwReleaseFn = fn (this voidptr) u32
	type DwQueryInterfaceFn = fn (this voidptr, riid voidptr, out &voidptr) i32
	type DwGetSystemCollectionFn = fn (this voidptr, collection &voidptr, check u32) i32
	type DwFindFamilyFn = fn (this voidptr, name &u16, index &u32, exists &i32) i32
	type DwGetFamilyFn = fn (this voidptr, index u32, family &voidptr) i32
	type DwFirstMatchingFn = fn (this voidptr, weight u32, stretch u32, style u32, font &voidptr) i32
	type DwFamilyNamesFn = fn (this voidptr, names &voidptr) i32
	type DwCreateFaceFn = fn (this voidptr, face &voidptr) i32
	type DwGetFilesFn = fn (this voidptr, count &u32, files voidptr) i32
	type DwReferenceKeyFn = fn (this voidptr, key &voidptr, size &u32) i32
	type DwGetLoaderFn = fn (this voidptr, loader &voidptr) i32
	type DwPathLengthFn = fn (this voidptr, key voidptr, size u32, length &u32) i32
	type DwPathFromKeyFn = fn (this voidptr, key voidptr, size u32, path &u16, length u32) i32
	type DwStringsCountFn = fn (this voidptr) u32
	type DwFindLocaleFn = fn (this voidptr, locale &u16, index &u32, exists &i32) i32
	type DwStringLengthFn = fn (this voidptr, index u32, length &u32) i32
	type DwGetStringFn = fn (this voidptr, index u32, buffer &u16, size u32) i32

	// dw_factory_iid is IID_IDWriteFactory, the interface id the factory
	// export is asked for.
	fn dw_factory_iid() DwGuid {
		return DwGuid{
			data1: u32(0xb859ee5a)
			data2: u16(0xd838)
			data3: u16(0x4b5b)
			data4: [u8(0xa2), u8(0xe8), u8(0x1a), u8(0xdc), u8(0x7d), u8(0x93), u8(0xdb), u8(0x48)]!
		}
	}

	// dw_local_loader_iid is IID_IDWriteLocalFontFileLoader, asked of the
	// file's loader so only a local file answers with a path.
	fn dw_local_loader_iid() DwGuid {
		return DwGuid{
			data1: u32(0xb2d9f3ec)
			data2: u16(0xc9fe)
			data3: u16(0x4a11)
			data4: [u8(0xa2), u8(0xec), u8(0xd8), u8(0x62), u8(0x08), u8(0xf7), u8(0xc0), u8(0xa2)]!
		}
	}

	// dw_vslot reads one vtable entry off a COM object: the object starts
	// with its vtable pointer, and each slot is one pointer wide.
	fn dw_vslot(obj voidptr, idx int) voidptr {
		vt := unsafe { *&voidptr(u64(obj)) }
		return unsafe { *&voidptr(u64(vt) + u64(idx) * u64(sizeof(voidptr))) }
	}

	// dw_release drops one COM reference, silently when there is nothing to
	// drop, which is what makes the cleanup loops safe over zeroed slots.
	fn dw_release(obj voidptr) {
		if obj == 0 {
			return
		}
		f := unsafe { DwReleaseFn(dw_vslot(obj, dw_slot_release)) }
		f(obj)
	}

	fn dw_factory_system_collection(factory voidptr, collection &voidptr) i32 {
		f := unsafe { DwGetSystemCollectionFn(dw_vslot(factory, dw_slot_get_system_collection)) }
		return f(factory, collection, u32(0))
	}

	fn dw_collection_find_family(collection voidptr, name &u16, index &u32, exists &i32) i32 {
		f := unsafe { DwFindFamilyFn(dw_vslot(collection, dw_slot_find_family)) }
		return f(collection, name, index, exists)
	}

	fn dw_collection_get_family(collection voidptr, index u32, family &voidptr) i32 {
		f := unsafe { DwGetFamilyFn(dw_vslot(collection, dw_slot_get_family)) }
		return f(collection, index, family)
	}

	fn dw_family_first_matching(family voidptr, font &voidptr) i32 {
		f := unsafe { DwFirstMatchingFn(dw_vslot(family, dw_slot_first_matching)) }
		return f(family, dw_weight_normal, dw_stretch_normal, dw_style_normal, font)
	}

	fn dw_family_get_names(family voidptr, names &voidptr) i32 {
		f := unsafe { DwFamilyNamesFn(dw_vslot(family, dw_slot_family_names)) }
		return f(family, names)
	}

	fn dw_font_create_face(font voidptr, face &voidptr) i32 {
		f := unsafe { DwCreateFaceFn(dw_vslot(font, dw_slot_create_face)) }
		return f(font, face)
	}

	fn dw_face_get_files(face voidptr, count &u32, files voidptr) i32 {
		f := unsafe { DwGetFilesFn(dw_vslot(face, dw_slot_get_files)) }
		return f(face, count, files)
	}

	fn dw_file_get_key(file voidptr, key &voidptr, size &u32) i32 {
		f := unsafe { DwReferenceKeyFn(dw_vslot(file, dw_slot_reference_key)) }
		return f(file, key, size)
	}

	fn dw_file_get_loader(file voidptr, loader &voidptr) i32 {
		f := unsafe { DwGetLoaderFn(dw_vslot(file, dw_slot_get_loader)) }
		return f(file, loader)
	}

	fn dw_query_interface(obj voidptr, riid voidptr, out &voidptr) i32 {
		f := unsafe { DwQueryInterfaceFn(dw_vslot(obj, dw_slot_query_interface)) }
		return f(obj, riid, out)
	}

	fn dw_local_path_length(loader voidptr, key voidptr, size u32, length &u32) i32 {
		f := unsafe { DwPathLengthFn(dw_vslot(loader, dw_slot_path_length)) }
		return f(loader, key, size, length)
	}

	fn dw_local_get_path(loader voidptr, key voidptr, size u32, path &u16, length u32) i32 {
		f := unsafe { DwPathFromKeyFn(dw_vslot(loader, dw_slot_path_from_key)) }
		return f(loader, key, size, path, length)
	}

	fn dw_strings_count(names voidptr) u32 {
		f := unsafe { DwStringsCountFn(dw_vslot(names, dw_slot_strings_count)) }
		return f(names)
	}

	fn dw_strings_find_locale(names voidptr, locale &u16, index &u32, exists &i32) i32 {
		f := unsafe { DwFindLocaleFn(dw_vslot(names, dw_slot_find_locale)) }
		return f(names, locale, index, exists)
	}

	fn dw_strings_get_length(names voidptr, index u32, length &u32) i32 {
		f := unsafe { DwStringLengthFn(dw_vslot(names, dw_slot_string_length)) }
		return f(names, index, length)
	}

	fn dw_strings_get(names voidptr, index u32, buffer &u16, size u32) i32 {
		f := unsafe { DwGetStringFn(dw_vslot(names, dw_slot_get_string)) }
		return f(names, index, buffer, size)
	}

	// dw_wide converts an UTF-8 string to UTF-16 with a trailing zero for the
	// name-taking calls. Invalid bytes answer U+FFFD rather than stopping the
	// lookup, and the caller never sends an empty buffer.
	fn dw_wide(s string) []u16 {
		mut out := []u16{cap: s.len + 1}
		mut i := 0
		for i < s.len {
			c := s[i]
			if c < u8(0x80) {
				out << u16(c)
				i++
			} else if (c & u8(0xe0)) == u8(0xc0) {
				if i + 1 >= s.len {
					out << u16(0xfffd)
					break
				}
				c2 := s[i + 1]
				if (c2 & u8(0xc0)) != u8(0x80) {
					out << u16(0xfffd)
					i++
					continue
				}
				out << u16((u32(c & u8(0x1f)) << 6) | u32(c2 & u8(0x3f)))
				i += 2
			} else if (c & u8(0xf0)) == u8(0xe0) {
				if i + 2 >= s.len {
					out << u16(0xfffd)
					break
				}
				c2 := s[i + 1]
				c3 := s[i + 2]
				if (c2 & u8(0xc0)) != u8(0x80) || (c3 & u8(0xc0)) != u8(0x80) {
					out << u16(0xfffd)
					i++
					continue
				}
				out << u16((u32(c & u8(0x0f)) << 12) | (u32(c2 & u8(0x3f)) << 6) | u32(c3 & u8(0x3f)))
				i += 3
			} else if (c & u8(0xf8)) == u8(0xf0) {
				if i + 3 >= s.len {
					out << u16(0xfffd)
					break
				}
				c2 := s[i + 1]
				c3 := s[i + 2]
				c4 := s[i + 3]
				if (c2 & u8(0xc0)) != u8(0x80) || (c3 & u8(0xc0)) != u8(0x80)
					|| (c4 & u8(0xc0)) != u8(0x80) {
					out << u16(0xfffd)
					i++
					continue
				}
				cp := (u32(c & u8(0x07)) << 18) | (u32(c2 & u8(0x3f)) << 12) | (u32(c3 & u8(0x3f)) << 6) | u32(c4 & u8(0x3f))
				if cp > u32(0x10ffff) {
					out << u16(0xfffd)
				} else {
					top := cp - u32(0x10000)
					out << u16(u32(0xd800) + (top >> 10))
					out << u16(u32(0xdc00) + (top & u32(0x3ff)))
				}
				i += 4
			} else {
				out << u16(0xfffd)
				i++
			}
		}
		out << u16(0)
		return out
	}

	// dw_utf8 converts n UTF-16 units to a caller-owned string, stopping at
	// the first zero. Surrogate pairs combine; anything else unusable answers
	// U+FFFD, so a hostile length never reads past the buffer.
	fn dw_utf8(buf &u16, n int) string {
		mut out := []u8{cap: n * 3 + 1}
		mut i := 0
		for i < n {
			w := unsafe { buf[i] }
			if w == u16(0) {
				break
			}
			if w < u16(0xd800) || w > u16(0xdfff) {
				if w < u16(0x80) {
					out << u8(w)
				} else if w < u16(0x800) {
					out << u8(u32(0xc0) | (u32(w) >> 6))
					out << u8(u32(0x80) | (u32(w) & u32(0x3f)))
				} else {
					out << u8(u32(0xe0) | (u32(w) >> 12))
					out << u8(u32(0x80) | ((u32(w) >> 6) & u32(0x3f)))
					out << u8(u32(0x80) | (u32(w) & u32(0x3f)))
				}
				i++
			} else if w <= u16(0xdbff) && i + 1 < n {
				w2 := unsafe { buf[i + 1] }
				if w2 >= u16(0xdc00) && w2 <= u16(0xdfff) {
					cp := (u32(w - u16(0xd800)) << 10) + u32(w2 - u16(0xdc00)) + u32(0x10000)
					out << u8(u32(0xf0) | (cp >> 18))
					out << u8(u32(0x80) | ((cp >> 12) & u32(0x3f)))
					out << u8(u32(0x80) | ((cp >> 6) & u32(0x3f)))
					out << u8(u32(0x80) | (cp & u32(0x3f)))
					i += 2
				} else {
					out << u8(0xef)
					out << u8(0xbf)
					out << u8(0xbd)
					i++
				}
			} else {
				out << u8(0xef)
				out << u8(0xbf)
				out << u8(0xbd)
				i++
			}
		}
		if out.len == 0 {
			return ''
		}
		// The bytes belong to the array, so they are cloned into caller
		// memory the way the fontconfig provider clones its C strings.
		out << u8(0)
		return unsafe { cstring_to_vstring(out.data) }.clone()
	}

	// dw_family_display_name reads the matched family name off the family
	// object, preferring en-us so the answer is stable across host locales and
	// taking the first string otherwise. Anything unreadable answers none: a
	// fallback the provider cannot name is a fallback it must not report.
	fn dw_family_display_name(family voidptr) ?string {
		mut names := voidptr(0)
		if dw_family_get_names(family, &names) < 0 || names == 0 {
			return none
		}
		defer {
			dw_release(names)
		}
		count := dw_strings_count(names)
		if count == 0 {
			return none
		}
		wloc := dw_wide('en-us')
		mut index := u32(0)
		mut exists := i32(0)
		if dw_strings_find_locale(names, wloc.data, &index, &exists) < 0 || exists == 0 {
			index = 0
		}
		if index >= count {
			index = 0
		}
		mut slen := u32(0)
		if dw_strings_get_length(names, index, &slen) < 0 || slen == 0 {
			return none
		}
		mut wbuf := []u16{len: int(slen) + 1, init: u16(0)}
		if dw_strings_get(names, index, wbuf.data, slen + u32(1)) < 0 {
			return none
		}
		name := dw_utf8(wbuf.data, int(slen))
		if name == '' {
			return none
		}
		return name
	}

	// dw_lookup_family walks the documented DirectWrite path for one family:
	// factory, system collection, family lookup, first matching font, font
	// face, first file, local loader, key back to a path, and the matched name
	// beside it. Every step that cannot answer reports why and returns none.
	fn dw_lookup_family(family string) ?SystemFont {
		mut factory := voidptr(0)
		iid := dw_factory_iid()
		if C.DWriteCreateFactory(dw_factory_shared, voidptr(&iid), &factory) < 0
			|| factory == 0 {
			println('providers: DirectWrite DWriteCreateFactory failed; answering none rather than a wrong font')
			return none
		}
		defer {
			dw_release(factory)
		}
		mut collection := voidptr(0)
		if dw_factory_system_collection(factory, &collection) < 0 || collection == 0 {
			println('providers: DirectWrite GetSystemFontCollection failed; answering none rather than a wrong font')
			return none
		}
		defer {
			dw_release(collection)
		}
		wfam := dw_wide(family)
		mut index := u32(0)
		mut exists := i32(0)
		if dw_collection_find_family(collection, wfam.data, &index, &exists) < 0 || exists == 0 {
			println('providers: DirectWrite has no family "${family}"; answering none rather than a wrong font')
			return none
		}
		mut famobj := voidptr(0)
		if dw_collection_get_family(collection, index, &famobj) < 0 || famobj == 0 {
			println('providers: DirectWrite GetFontFamily failed for "${family}"; answering none rather than a wrong font')
			return none
		}
		defer {
			dw_release(famobj)
		}
		mut font := voidptr(0)
		if dw_family_first_matching(famobj, &font) < 0 || font == 0 {
			println('providers: DirectWrite GetFirstMatchingFont failed for "${family}"; answering none rather than a wrong font')
			return none
		}
		defer {
			dw_release(font)
		}
		mut face := voidptr(0)
		if dw_font_create_face(font, &face) < 0 || face == 0 {
			println('providers: DirectWrite CreateFontFace failed for "${family}"; answering none rather than a wrong font')
			return none
		}
		defer {
			dw_release(face)
		}
		mut nfiles := u32(0)
		if dw_face_get_files(face, &nfiles, unsafe { nil }) < 0 || nfiles == 0 {
			println('providers: DirectWrite GetFiles counted no files for "${family}"; answering none rather than a wrong font')
			return none
		}
		mut files := []voidptr{len: int(nfiles), init: voidptr(0)}
		if dw_face_get_files(face, &nfiles, files.data) < 0 {
			println('providers: DirectWrite GetFiles read no files for "${family}"; answering none rather than a wrong font')
			return none
		}
		// The face AddRefs every file it hands out, so every slot the second
		// call filled is released here; zeroed slots are skipped by release.
		defer {
			for f in files {
				dw_release(f)
			}
		}
		if nfiles == 0 || files[0] == 0 {
			println('providers: DirectWrite first file is missing for "${family}"; answering none rather than a wrong font')
			return none
		}
		file := files[0]
		mut loader := voidptr(0)
		if dw_file_get_loader(file, &loader) < 0 || loader == 0 {
			println('providers: DirectWrite GetLoader failed for "${family}"; answering none rather than a wrong font')
			return none
		}
		defer {
			dw_release(loader)
		}
		mut key := voidptr(0)
		mut key_size := u32(0)
		if dw_file_get_key(file, &key, &key_size) < 0 || key == 0 || key_size == 0 {
			println('providers: DirectWrite GetReferenceKey failed for "${family}"; answering none rather than a wrong font')
			return none
		}
		mut local := voidptr(0)
		local_iid := dw_local_loader_iid()
		if dw_query_interface(loader, voidptr(&local_iid), &local) < 0 || local == 0 {
			println('providers: DirectWrite font "${family}" is not a local file; answering none rather than a wrong font')
			return none
		}
		defer {
			dw_release(local)
		}
		mut path_len := u32(0)
		if dw_local_path_length(local, key, key_size, &path_len) < 0 || path_len == 0 {
			println('providers: DirectWrite GetFilePathLengthFromKey failed for "${family}"; answering none rather than a wrong font')
			return none
		}
		mut wpath := []u16{len: int(path_len) + 1, init: u16(0)}
		if dw_local_get_path(local, key, key_size, wpath.data, path_len + u32(1)) < 0 {
			println('providers: DirectWrite GetFilePathFromKey failed for "${family}"; answering none rather than a wrong font')
			return none
		}
		path := dw_utf8(wpath.data, int(path_len))
		if path == '' {
			println('providers: DirectWrite answered an empty path for "${family}"; answering none rather than a wrong font')
			return none
		}
		matched := dw_family_display_name(famobj) or {
			println('providers: DirectWrite family names unreadable for "${family}"; answering none rather than a wrong font')
			return none
		}
		if matched == '' {
			println('providers: DirectWrite matched family is unnamed for "${family}"; answering none rather than a wrong font')
			return none
		}
		return SystemFont{
			path:   path
			family: matched
		}
	}

	// directwrite_font resolves a family name through DirectWrite and answers
	// the file backing the match, with the family the match actually named
	// beside it. DirectWrite does not fall back at this level: a family that
	// is not installed answers none, so a caller never draws in a font it
	// never asked for. Anything unusable on the way there answers none with
	// the reason printed.
	pub fn directwrite_font(family string) ?SystemFont {
		if family == '' {
			println('providers: DirectWrite lookup needs a family name; answering none rather than a wrong font')
			return none
		}
		return dw_lookup_family(family)
	}
} $else {
	// Off Windows there is no DirectWrite. A caller asking here gets no font
	// rather than a build break, and the reason is printed where the answer
	// would have been.
	pub fn directwrite_font(family string) ?SystemFont {
		println('providers: DirectWrite lookup is windows-only; no provider on this platform')
		return none
	}
}
