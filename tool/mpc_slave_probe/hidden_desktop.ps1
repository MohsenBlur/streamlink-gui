param([string]$CommandLine, [int]$TimeoutSec = 120, [string]$WorkDir = $null)
# Runs $CommandLine on a separate desktop that is never shown, and waits for it.
# Everything it starts inherits that desktop: windows cannot cross desktops,
# so nothing it opens can appear on the user's monitors or take the focus -
# which MPC-HC otherwise did on its first runs here, /nofocus or not.
# Window messages only pass within a desktop, which is why the whole chain
# (the control window's owner and the player) runs there together. Video
# renders there as usual. Sound does not stay there: mute the player.
#
#   hidden_desktop.ps1 -CommandLine 'cmd.exe /d /c "probe.exe ... > out.txt 2>&1"'
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class HiddenDesk {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct STARTUPINFO { public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; public short wShowWindow, cbReserved2;
    public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
  [StructLayout(LayoutKind.Sequential)]
  public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern IntPtr CreateDesktop(string name, IntPtr dev, IntPtr mode, int flags, uint access, IntPtr sa);
  [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, int flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
  public delegate bool EnumProc(IntPtr hwnd, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumDesktopWindows(IntPtr desk, EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr w, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr w, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr w);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr w, out int pid);
  public static List<string> Visible(IntPtr desk) {
    var rows = new List<string>();
    EnumDesktopWindows(desk, (w, l) => {
      if (!IsWindowVisible(w)) return true;
      int pid; GetWindowThreadProcessId(w, out pid);
      var c = new StringBuilder(256); GetClassName(w, c, 256);
      var t = new StringBuilder(512); GetWindowText(w, t, 512);
      rows.Add("pid " + pid + " class=" + c + " title='" + t + "'"); return true; }, IntPtr.Zero);
    return rows;
  }
}
'@
$name = "gmpc_hidden_desk"
$desk = [HiddenDesk]::CreateDesktop($name, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
if ($desk -eq [IntPtr]::Zero) { "CreateDesktop failed"; exit 1 }
$si = New-Object HiddenDesk+STARTUPINFO
$si.cb = [Runtime.InteropServices.Marshal]::SizeOf($si)
$si.lpDesktop = "WinSta0\$name"
$pinfo = New-Object HiddenDesk+PROCESS_INFORMATION
$sb = New-Object System.Text.StringBuilder($CommandLine)
$dir = if ($WorkDir) { $WorkDir } else { [NullString]::Value }
# CREATE_NO_WINDOW: a console child gets no console window, on any desktop.
if (-not [HiddenDesk]::CreateProcess([NullString]::Value, $sb, [IntPtr]::Zero, [IntPtr]::Zero, $false, 0x08000000, [IntPtr]::Zero, $dir, [ref]$si, [ref]$pinfo)) {
  "CreateProcess failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"; [HiddenDesk]::CloseDesktop($desk) | Out-Null; exit 1
}
"started pid $($pinfo.dwProcessId) on $name"
$r = [HiddenDesk]::WaitForSingleObject($pinfo.hProcess, [uint32]($TimeoutSec * 1000))
if ($r -ne 0) { "TIMED OUT after $TimeoutSec s" }
$code = 0; [HiddenDesk]::GetExitCodeProcess($pinfo.hProcess, [ref]$code) | Out-Null
"exit code $code"
"windows left on the desktop:"; [HiddenDesk]::Visible($desk)
[HiddenDesk]::CloseHandle($pinfo.hProcess) | Out-Null; [HiddenDesk]::CloseHandle($pinfo.hThread) | Out-Null
[HiddenDesk]::CloseDesktop($desk) | Out-Null
