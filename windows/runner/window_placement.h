#ifndef RUNNER_WINDOW_PLACEMENT_H_
#define RUNNER_WINDOW_PLACEMENT_H_

#include <flutter/encodable_value.h>
#include <windows.h>

// The native half of window geometry (lib/services/native_window.dart).
//
// Everything here is in PHYSICAL pixels in virtual-screen coordinates, the one
// coordinate system every monitor agrees on. window_manager and
// screen_retriever each report LOGICAL values instead, and with different
// divisors: screen_retriever divides each monitor by its own scale,
// window_manager divides the window by the scale of whichever monitor it was
// on at that moment. Mixing the two across a 100% and a 150% monitor is how
// the saved geometry grew by 1.5x and drifted from session to session.
namespace window_placement {

// Every monitor: "name", its bounds ("left", "top", "width", "height"), its
// work area ("workLeft", "workTop", "workWidth", "workHeight"), "dpi" and
// "primary".
flutter::EncodableList DescribeMonitors();

// The window's restorable state: its normal (restored) bounds - the rectangle
// it returns to from maximized or minimized, and its live rectangle otherwise
// - plus "maximized", "minimized", "visible", "dpi", the monitor it is on
// ("monitor" and "monitorLeft"/"Top"/"Width"/"Height"), and whether the
// hosted |content| is visible ("contentVisible"), the half of the window that
// went missing in the invisible-window bug.
flutter::EncodableMap DescribeWindow(HWND window, HWND content);

// Moves and sizes |window| until its frame is exactly |bounds|.
//
// A single SetWindowPos is not enough across monitors with different DPI:
// arriving on the new monitor raises WM_DPICHANGED, whose handler applies
// Windows' suggested rectangle - the old size scaled by the DPI ratio. A second
// call, made from the new monitor, then lands exactly. That intermediate
// resize is also what tells the engine about the new DPI, which it otherwise
// only learns from a size change. Returns whether the frame ended up exact.
bool MoveExactly(HWND window, const RECT& bounds);

}  // namespace window_placement

#endif  // RUNNER_WINDOW_PLACEMENT_H_
