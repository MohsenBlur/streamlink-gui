#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

// A class abstraction for a high DPI-aware Win32 Window. Intended to be
// inherited from by classes that wish to specialize with custom
// rendering and input handling
class Win32Window {
 public:
  struct Point {
    unsigned int x;
    unsigned int y;
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  struct Size {
    unsigned int width;
    unsigned int height;
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  Win32Window();
  virtual ~Win32Window();

  // Creates a win32 window with |title| that is positioned and sized using
  // |origin| and |size|. New windows are created on the default monitor. Window
  // sizes are specified to the OS in physical pixels, hence to ensure a
  // consistent size this function will scale the inputted width and height as
  // as appropriate for the default monitor. The window is invisible until
  // |Show| is called. Returns true if the window was created successfully.
  bool Create(const std::wstring& title, const Point& origin, const Size& size);

  // Show the current window. Returns true if the window was successfully shown.
  // Uses the first-show command (see SetFirstShowCommand).
  bool Show();

  // The first show at launch: Show(), unless the launcher asked for
  // something else (SetLaunchShowCommand) - minimized, without activation,
  // or maximized - in which case that, on top of the restored placement.
  // Ends the start in the background after the show. A window already shown
  // (by a second launch, before the first frame) gets Show() alone.
  void ShowAsLaunched();

  // The show command the launcher put in STARTUPINFO, or -1 for none. Call
  // before Create.
  //
  // Windows applies it itself only by swapping it in for the process's first
  // ShowWindow, and only when that call asks for a plain show (SW_SHOWNORMAL
  // or SW_SHOW; SW_SHOWMAXIMIZED and SW_RESTORE are left alone, measured).
  // For a window restored maximized the first show is SW_SHOWMAXIMIZED, so a
  // shortcut set to run minimized, or a launcher's SW_SHOWNOACTIVATE, got a
  // maximized, activated window instead. And when the launch stayed hidden,
  // the swap waited for whatever show came first - a summons from the tray,
  // say - and would have done the launcher's bidding there instead. So Create
  // uses the swap up while the window is still hidden, and the first show at
  // launch applies the command (ShowAsLaunched).
  void SetLaunchShowCommand(int command) { launch_show_command_ = command; }

  // The ShowWindow command the window is first shown with: SW_SHOWNORMAL, or
  // SW_SHOWMAXIMIZED when the restored placement was maximized. Maximizing is
  // part of the show rather than a step after it, so a window restored
  // maximized never appears at its normal size first - and a maximize that
  // ran before the show could not survive it, because SW_SHOWNORMAL restores.
  void SetFirstShowCommand(int command) { first_show_command_ = command; }
  int first_show_command() const { return first_show_command_; }

  // For a launch that must not take the foreground: one started hidden, or
  // one whose launcher asked for a show without activation. Call before
  // Create.
  //
  // The window stays hidden until its first frame, and anything that
  // activates it in that time takes the foreground from the user's own app
  // whenever Windows lets this process take it - a launch at login, or one
  // asked to stay in the background, included. SetWindowPos without
  // SWP_NOACTIVATE activates a top-level window, visible or not, and
  // window_manager's title bar setup calls it there. A plugin's call cannot
  // be given the flag; adding it in WM_WINDOWPOSCHANGING or giving the
  // window WS_EX_NOACTIVATE does not stop the activation, and refusing it
  // in a CBT hook leaves no foreground window at all, since Windows has
  // moved the foreground to this thread by then. Such a launch therefore
  // holds the foreground lock (LockSetForegroundWindow) from creation until
  // the window is first shown, or its first frame passes with it hidden: a
  // hidden activation then stays inside this thread, and the user's app
  // keeps the foreground and the keyboard. The lock also gives up this
  // process's own right to take the foreground, which a normal launch needs
  // for its first show - so only these launches take it. While it is held,
  // other background processes cannot take the foreground either; the user
  // pressing Alt or clicking another window lifts it, as Windows does for
  // every holder.
  void SetStartInBackground(bool in_background) {
    start_in_background_ = in_background;
  }

  // The same hold on the foreground, from now on, for a launch found to start
  // hidden only once the window exists: the Start minimized setting, which
  // only the Dart side reads. Whatever activated the window before this call
  // has taken the foreground already, so it has to come before anything that
  // can - window_manager's title bar setup first of all. A no-op once the
  // start is over (EndBackgroundStart), since nothing would let go of the
  // lock after that.
  void BeginBackgroundStart();

  // Whether the frame has been visible at any point. Tracked from the window's
  // own messages, so a show by any route counts: the first-frame Show(), a
  // plugin's ShowWindow, a second launch.
  bool HasBeenShown() const { return has_been_shown_; }

  // Release OS resources associated with window.
  void Destroy();

  // Ends a start in the background (SetStartInBackground): the window has
  // been shown, or its first frame has passed with it staying hidden.
  // Show() calls it. Lets go of the lock if it is held, and either way makes
  // BeginBackgroundStart a no-op for the rest of this window's life.
  void EndBackgroundStart();

  // Inserts |content| into the window tree.
  void SetChildContent(HWND content);

  // Returns the backing Window handle to enable clients to set icon and other
  // window properties. Returns nullptr if the window has been destroyed.
  HWND GetHandle();

  // If true, closing this window will quit the application.
  void SetQuitOnClose(bool quit_on_close);

  // Return a RECT representing the bounds of the current client area.
  RECT GetClientArea();

 protected:
  // Processes and route salient window messages for mouse handling,
  // size change and DPI. Delegates handling of these to member overloads that
  // inheriting classes can handle.
  virtual LRESULT MessageHandler(HWND window,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;

  // Called when CreateAndShow is called, allowing subclass window-related
  // setup. Subclasses should return false if setup fails.
  virtual bool OnCreate();

  // Called when Destroy is called.
  virtual void OnDestroy();

  // Shows the hosted content if its own WS_VISIBLE flag is clear, and returns
  // whether it had to. The frame being visible says nothing about the
  // content: the hidden-content state is an empty, see-through window with
  // only the DWM border drawn. See the WM_WINDOWPOSCHANGED handler.
  bool ShowChildContentIfHidden();

  // Called after ShowChildContentIfHidden had to re-show the content, so a
  // subclass can repaint a surface that was presented while it was hidden.
  virtual void OnChildContentReshown();

  // The hosted content, or nullptr before SetChildContent and after
  // ForgetChildContent.
  HWND GetChildContent() const { return child_content_; }

  // Forgets the hosted content without touching it. For the content's owner
  // to call before destroying it, so that no message handled during or after
  // that teardown acts on a dead HWND.
  void ForgetChildContent();

 private:
  friend class WindowClassRegistrar;

  // OS callback called by message pump. Handles the WM_NCCREATE message which
  // is passed when the non-client area is being created and enables automatic
  // non-client DPI scaling so that the non-client area automatically
  // responds to changes in DPI. All other messages are handled by
  // MessageHandler.
  static LRESULT CALLBACK WndProc(HWND const window,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;

  // Retrieves a class instance pointer for |window|
  static Win32Window* GetThisFromHandle(HWND const window) noexcept;

  // Update the window frame's theme to match the system theme.
  static void UpdateTheme(HWND const window);

  bool quit_on_close_ = false;

  int first_show_command_ = SW_SHOWNORMAL;
  int launch_show_command_ = -1;
  bool has_been_shown_ = false;

  bool start_in_background_ = false;
  bool holds_foreground_lock_ = false;
  bool background_start_over_ = false;

  // window handle for top level window.
  HWND window_handle_ = nullptr;

  // window handle for hosted content.
  HWND child_content_ = nullptr;
};

#endif  // RUNNER_WIN32_WINDOW_H_
