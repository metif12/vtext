module main

$if windows {
	#include "gesture_windows.h"
	fn C.gallery_gestures_install() bool
}

// Gesture support on Windows is a thin native mouse hook that drives the
// existing Sliders (see gesture_windows.h). It only runs in native builds:
// the custom renderer draws its own sliders, so there are no trackbar HWNDs
// to find, and pointer drags there go through the model's on_pointer_event
// hook instead. On other platforms the sliders remain the only input.
fn install_gestures() {
	$if windows {
		$if !ui2_custom_rendering ? {
			C.gallery_gestures_install()
		}
	}
}
