module providers

// coretext is the macOS provider: family in, file path out, through CoreText,
// the way vlib gg.canvas drives CoreText (frameworks linked only here, so a
// caller that never imports providers never links CoreText through vtext).
//
// Everywhere else there is no provider, and a caller asking here gets none
// rather than a build break. Nothing in this file imports vlib.

$if macos {
	#include <CoreText/CoreText.h>
	#include <CoreGraphics/CoreGraphics.h>
	#include <CoreFoundation/CoreFoundation.h>
}

#flag macos -framework CoreText -framework CoreGraphics -framework CoreFoundation

$if macos {
	// k_cfstring_encoding_utf8 is kCFStringEncodingUTF8: the C-string encoding
	// both conversions below speak.
	const k_cfstring_encoding_utf8 = u32(0x08000100)

	fn C.CFStringCreateWithCString(voidptr, &u8, u32) voidptr
	fn C.CFRelease(voidptr)
	fn C.CTFontDescriptorCreateWithNameAndSize(voidptr, f64) voidptr
	fn C.CTFontCreateWithFontDescriptor(voidptr, f64, voidptr) voidptr
	fn C.CTFontCopyAttribute(voidptr, voidptr) voidptr
	fn C.CFURLGetFileSystemRepresentation(voidptr, bool, &u8, i64) bool
	fn C.CTFontCopyFamilyName(voidptr) voidptr
	fn C.CFStringGetCString(voidptr, &u8, i64, u32) bool

	// coretext_font resolves a family name through CoreText and answers the
	// file backing the match, with the family the match actually named beside
	// it. A family that is not installed still matches — CoreText falls back
	// the way fontconfig does — so the caller compares the two before drawing
	// in a font it never asked for. Anything unusable on the way there
	// answers none.
	//
	// The URL comes off CTFontCopyAttribute with kCTFontURLAttribute and the
	// name off CTFontCopyFamilyName; the attribute key is CoreText's own
	// constant, declared in CTFont.h, so no graphics-font round trip is
	// needed (and none of the calls here need a CGFont at all).
	pub fn coretext_font(family string) ?SystemFont {
		if family == '' {
			return none
		}
		name := C.CFStringCreateWithCString(unsafe { nil }, family.str, k_cfstring_encoding_utf8)
		if name == unsafe { nil } {
			return none
		}
		desc := C.CTFontDescriptorCreateWithNameAndSize(name, 0.0)
		C.CFRelease(name)
		if desc == unsafe { nil } {
			return none
		}
		defer {
			C.CFRelease(desc)
		}
		font := C.CTFontCreateWithFontDescriptor(desc, 0.0, unsafe { nil })
		if font == unsafe { nil } {
			return none
		}
		defer {
			C.CFRelease(font)
		}
		url := C.CTFontCopyAttribute(font, C.kCTFontURLAttribute)
		if url == unsafe { nil } {
			return none
		}
		defer {
			C.CFRelease(url)
		}
		// The URL owns the bytes the representation reads, so the buffer is
		// only borrowed for the copy below and freed with the array.
		mut path_buf := []u8{len: 1024}
		if C.CFURLGetFileSystemRepresentation(url, true, path_buf.data, 1024) == false {
			return none
		}
		famname := C.CTFontCopyFamilyName(font)
		if famname == unsafe { nil } {
			return none
		}
		defer {
			C.CFRelease(famname)
		}
		mut fam_buf := []u8{len: 512}
		if C.CFStringGetCString(famname, fam_buf.data, 512, k_cfstring_encoding_utf8) == false {
			return none
		}
		// Both strings belong to CoreText objects the defers release on the
		// way out, so they are cloned into caller memory before returning.
		path := unsafe { cstring_to_vstring(path_buf.data) }.clone()
		matched := unsafe { cstring_to_vstring(fam_buf.data) }.clone()
		return SystemFont{
			path:   path
			family: matched
		}
	}
} $else {
	// Everywhere else there is no CoreText. A caller asking here gets no font
	// rather than a build break, and the reason is printed where the answer
	// would have been.
	pub fn coretext_font(family string) ?SystemFont {
		println('providers: CoreText lookup is macos-only; no provider on this platform')
		return none
	}
}
