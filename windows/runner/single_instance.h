#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

#include <string>

// How a second launch hands over to the instance that is already running.
//
// The running instance's main window carries a window property that only this
// runner sets, and a second launch finds the window by that property rather
// than by its class. FLUTTER_RUNNER_WIN32_WINDOW is the template class that
// every Flutter Win32 app shares, so looking up the class alone could raise
// another app's window and leave this one in the tray. The class name itself
// is kept: tools/shoot.ps1 and tools/click.ps1 find the window by it.
//
// "The instance already running" means the one sharing this launch's config:
// every installed copy shares one, a portable copy (portable.txt beside the
// exe) is its own, keyed by its folder. The property's value says which.
namespace single_instance {

// The single-instance mutex for this launch's scope.
const std::wstring& MutexName();

// The registered message a second launch posts to the running instance's main
// window ("TwitchStreamlinkGUI.Activate"). wParam and lParam are unused (0).
// 0 if registration failed (the user atom table is full), and 0 is WM_NULL, so
// a window procedure must test with IsActivateMessage, never compare to this.
UINT ActivateMessage();

// Whether |message| is the activate message. Never true for WM_NULL, which
// system_tray posts to the main window after every tray menu and which hang
// detectors send, so a failed registration cannot turn those into activations.
bool IsActivateMessage(UINT message);

// Tags |window| as this app's main window ("TwitchStreamlinkGUI.MainWindow"),
// and lets the activate message through UIPI, so a second launch running at a
// lower integrity level than this instance still reaches it.
void MarkMainWindow(HWND window);

// Removes the tag. Must run before |window| finishes being destroyed.
void UnmarkMainWindow(HWND window);

// Called from a second launch: finds the running instance's main window and
// asks it to come forward. Returns false if no tagged window exists, e.g.
// while the first instance is still creating its window.
bool ActivateRunningInstance();

}  // namespace single_instance

#endif  // RUNNER_SINGLE_INSTANCE_H_
