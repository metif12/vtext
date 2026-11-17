module providers

// directwrite is the Windows provider: family in, file path out, through
// DirectWrite.
//
// Status: documented stub, answering none. A real wiring would walk COM the
// way a DirectWrite client does — CoCreateInstance for the factory,
// GetSystemFontCollection, FindFamilyName, GetFontFamily,
// GetFirstMatchingFont, then the local-file-loader key back to a path with
// IDWriteLocalFontFileLoader::GetFilePathFromKey — and report the matched
// family beside the path the way fontconfig does, so a fallback names
// itself. That walk is 7.8 work still open; until it lands every caller gets
// none rather than a wrong font, and nothing links: there is deliberately no
// #flag here. Nothing in this file imports vlib.

$if windows {
	// directwrite_font answers none on Windows for now: the DirectWrite walk
	// above is unwritten, and the reason is printed where the answer would
	// have been.
	pub fn directwrite_font(family string) ?SystemFont {
		println('providers: DirectWrite lookup is open work (7.8); answering none on windows rather than a wrong font')
		return none
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
