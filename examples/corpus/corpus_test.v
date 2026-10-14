module corpus

import os

// The resolution order is the whole of this module, so it is tested rather than argued about: the
// corpus must win over the platform directory when it carries the font, and the platform directory
// must still be reached for a font only it has.
fn test_corpus_wins_over_the_platform_directory() {
	p := font('Amiri-Regular.ttf')
	assert p != '', 'the corpus has Amiri'
	assert p.contains('testdata'), 'and it comes from the corpus, not the platform: ${p}'
	assert os.exists(p), 'and it is a real file'
}

// A font only Windows ships resolves to the platform directory, which is what keeps the output of the
// examples unchanged on this machine.
fn test_the_platform_directory_is_still_reached() {
	p := font('segoeui.ttf')
	$if windows {
		assert p != '', 'Segoe UI is on this host'
		assert p.contains('Windows'), 'and it came from the platform directory: ${p}'
	} $else {
		// Elsewhere there is no such directory, and the answer is none rather than a wrong path.
		assert p == '', 'no platform directory off Windows, got ${p}'
	}
}

// Preference order inside the families list: the first that exists wins.
fn test_the_first_family_that_exists_wins() {
	p := font('no-such-font.ttf', 'Amiri-Regular.ttf')
	assert p.contains('testdata'), 'the second family answers when the first is absent: ${p}'
}

// No font anywhere is none, not a guess.
fn test_nothing_anywhere_is_none() {
	assert font('no-such-font.ttf', 'nor-this-one.ttf') == ''
	assert font() == ''
}
