#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

// How a second launch hands over to the instance that is already running.
//
// The running instance's main window carries a window property that only this
// runner sets, and a second launch finds the window by that property rather
// than by its class. FLUTTER_RUNNER_WIN32_WINDOW is the template class that
// every Flutter Win32 app shares, so looking up the class alone could raise
// another app's window and leave this one in the tray. The class name itself
// is kept: tools/shoot.ps1 and tools/click.ps1 find the window by it.
namespace single_instance {

// The registered message a second launch posts to the running instance's main
// window ("TwitchStreamlinkGUI.Activate"). wParam and lParam are unused (0).
UINT ActivateMessage();

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
