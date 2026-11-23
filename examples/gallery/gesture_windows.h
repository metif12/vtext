#ifndef GALLERY_GESTURE_WINDOWS_H
#define GALLERY_GESTURE_WINDOWS_H

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#include <windows.h>
#include <wchar.h>

// The gallery's transform controls are ordinary ui2 Sliders. Driving them the
// same way a user would (set the trackbar, then notify its parent with
// WM_HSCROLL) makes ui2 fire their on_change actions, so the VML model, the
// sliders and the rendered stage all stay in step without any private state in
// the app.

#define GAL_WH_MOUSE_LL 14
#define GAL_TBM_GETPOS (WM_USER)
#define GAL_TBM_SETRANGEMIN (WM_USER + 1)
#define GAL_TBM_SETRANGEMAX (WM_USER + 2)
#define GAL_TBM_SETPAGESIZE (WM_USER + 4)
#define GAL_TBM_SETPOS (WM_USER + 5)
#define GAL_SLIDER_STEPS 10000
#define GAL_SB_THUMBPOSITION 4

enum {
	GAL_PITCH = 0,
	GAL_ZOOM,
	GAL_PANX,
	GAL_PANY,
	GAL_ROTATE,
	GAL_PANE,
	GAL_SLIDER_COUNT
};

static HHOOK g_gal_hook = NULL;
static HWND g_gal_main = NULL;
static HWND g_gal_sliders[GAL_SLIDER_COUNT];
static int g_gal_dragging = 0;
static int g_gal_mode = 0; // 0 pan, 1 rotate, 2 pitch
static POINT g_gal_last;

// Client positions of the sliders in the guides bar. A child's VML coordinates
// are relative to the bar at (178, 8).
static const int g_gal_slider_x[GAL_SLIDER_COUNT] = { 250, 226, 228, 378, 534, 418 };
static const int g_gal_slider_y[GAL_SLIDER_COUNT] = { 60, 86, 112, 112, 112, 86 };
static const double g_gal_min[GAL_SLIDER_COUNT] = { 8.0, 1.0, -300.0, -300.0, -180.0, 220.0 };
static const double g_gal_max[GAL_SLIDER_COUNT] = { 64.0, 3.0, 300.0, 300.0, 180.0, 420.0 };

static double gal_clamp(double v, double lo, double hi) {
	if (v < lo) return lo;
	if (v > hi) return hi;
	return v;
}

static double gal_value(int index) {
	HWND hwnd = g_gal_sliders[index];
	if (hwnd == NULL) return g_gal_min[index];
	double norm = (double)SendMessageW(hwnd, GAL_TBM_GETPOS, 0, 0) / GAL_SLIDER_STEPS;
	double v = g_gal_min[index] + norm * (g_gal_max[index] - g_gal_min[index]);
	return gal_clamp(v, g_gal_min[index], g_gal_max[index]);
}

static void gal_set_value(int index, double value) {
	HWND hwnd = g_gal_sliders[index];
	if (hwnd == NULL) return;
	double norm = (value - g_gal_min[index]) / (g_gal_max[index] - g_gal_min[index]);
	norm = gal_clamp(norm, 0.0, 1.0);
	int pos = (int)(norm * GAL_SLIDER_STEPS + 0.5);
	SendMessageW(hwnd, GAL_TBM_SETRANGEMIN, FALSE, 0);
	SendMessageW(hwnd, GAL_TBM_SETRANGEMAX, FALSE, GAL_SLIDER_STEPS);
	SendMessageW(hwnd, GAL_TBM_SETPAGESIZE, 0, GAL_SLIDER_STEPS / 10);
	SendMessageW(hwnd, GAL_TBM_SETPOS, TRUE, pos);
	HWND parent = GetParent(hwnd);
	if (parent != NULL) {
		SendMessageW(parent, WM_HSCROLL,
			(WPARAM)(GAL_SB_THUMBPOSITION | (pos << 16)), (LPARAM)hwnd);
	}
}

static BOOL CALLBACK gal_enum_child(HWND hwnd, LPARAM unused) {
	(void)unused;
	wchar_t cls[64];
	int length = GetClassNameW(hwnd, cls, 64);
	if (length == 0 || wcscmp(cls, L"msctls_trackbar32") != 0) return TRUE;
	RECT rect;
	if (!GetWindowRect(hwnd, &rect)) return TRUE;
	POINT pt = { rect.left, rect.top };
	if (!ScreenToClient(g_gal_main, &pt)) return TRUE;
	for (int i = 0; i < GAL_SLIDER_COUNT; i++) {
		if (abs(pt.x - g_gal_slider_x[i]) <= 6 && abs(pt.y - g_gal_slider_y[i]) <= 8) {
			g_gal_sliders[i] = hwnd;
			break;
		}
	}
	return TRUE;
}

static void gal_find_sliders(void) {
	for (int i = 0; i < GAL_SLIDER_COUNT; i++) g_gal_sliders[i] = NULL;
	EnumChildWindows(g_gal_main, gal_enum_child, 0);
}

static int gal_in_preview(POINT pt) {
	if (g_gal_main == NULL) return 0;
	// A global hook sees every mouse event on the desktop; only act when the
	// gallery is really the window under the pointer, so an overlapping window
	// keeps its own wheel and drag behaviour.
	HWND under = WindowFromPoint(pt);
	if (under == NULL || (under != g_gal_main && !IsChild(g_gal_main, under))) return 0;
	RECT client;
	if (!GetClientRect(g_gal_main, &client)) return 0;
	POINT local = pt;
	if (!ScreenToClient(g_gal_main, &local)) return 0;
	int right = client.right - 34 - (int)gal_value(GAL_PANE);
	return local.x >= 190 && local.x <= right
		&& local.y >= 192 && local.y <= client.bottom - 26;
}

static LRESULT CALLBACK gal_mouse_proc(int code, WPARAM wparam, LPARAM lparam) {
	if (code >= 0) {
		MSLLHOOKSTRUCT *ms = (MSLLHOOKSTRUCT *)lparam;
		if (g_gal_main == NULL || !IsWindow(g_gal_main)) {
			g_gal_main = FindWindowW(NULL, L"HarfAra feature gallery");
			if (g_gal_main != NULL) gal_find_sliders();
		}
		if (g_gal_main != NULL && ms != NULL && gal_in_preview(ms->pt)) {
			if (wparam == WM_MOUSEWHEEL) {
				int delta = GET_WHEEL_DELTA_WPARAM(ms->mouseData);
				int ctrl = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
				if (ctrl) {
					gal_set_value(GAL_PITCH, gal_value(GAL_PITCH) + (delta > 0 ? 4 : -4));
				} else {
					gal_set_value(GAL_ZOOM, gal_value(GAL_ZOOM) + (delta > 0 ? 0.1 : -0.1));
				}
				return 1; // zoom/pitch, not a scroll of the preview pane
			}
			if (wparam == WM_LBUTTONDOWN || wparam == WM_MBUTTONDOWN) {
				g_gal_dragging = 1;
				g_gal_last = ms->pt;
				int shift = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
				int ctrl = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
				g_gal_mode = (wparam == WM_MBUTTONDOWN || shift) ? 1 : (ctrl ? 2 : 0);
			} else if (wparam == WM_LBUTTONUP || wparam == WM_MBUTTONUP) {
				g_gal_dragging = 0;
			} else if (wparam == WM_MOUSEMOVE && g_gal_dragging) {
				int dx = ms->pt.x - g_gal_last.x;
				int dy = ms->pt.y - g_gal_last.y;
				g_gal_last = ms->pt;
				if (g_gal_mode == 0) {
					gal_set_value(GAL_PANX, gal_value(GAL_PANX) - dx);
					gal_set_value(GAL_PANY, gal_value(GAL_PANY) - dy);
				} else if (g_gal_mode == 1) {
					gal_set_value(GAL_ROTATE, gal_value(GAL_ROTATE) + dx * 0.5);
				} else {
					gal_set_value(GAL_PITCH, gal_value(GAL_PITCH) + dx * 0.1);
				}
			}
		}
	}
	return CallNextHookEx(g_gal_hook, code, wparam, lparam);
}

static int gallery_gestures_install(void) {
	if (g_gal_hook != NULL) return 1;
	// A low-level hook is delivered through this thread's message loop, but it
	// must be installed globally: a thread-scoped hook only sees messages aimed
	// at that thread, so a wheel over a different foreground window is missed.
	g_gal_hook = SetWindowsHookExW(GAL_WH_MOUSE_LL, gal_mouse_proc, NULL, 0);
	return g_gal_hook != NULL;
}

#endif
