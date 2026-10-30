#include "single_instance.h"

#include <cwctype>
#include <string>

namespace single_instance {

namespace {

constexpr wchar_t kMainWindowProperty[] = L"TwitchStreamlinkGUI.MainWindow";
constexpr wchar_t kActivateMessageName[] = L"TwitchStreamlinkGUI.Activate";
constexpr wchar_t kMutexName[] = L"Local\\TwitchStreamlinkGUIUniqueMutexName";

// The tag every installed (non-portable) instance carries. Kept at 1, the
// value tools/shoot.ps1 already accepts as "tagged".
constexpr UINT_PTR kSharedScopeTag = 1;

// |path| as the file system names it, or |path| itself if that cannot be
// told: junctions, symbolic links, subst and mapped drives and short names
// resolved to the one real location, and the "\\?\" (or "\\?\UNC\") prefix
// GetFinalPathNameByHandleW adds taken back off. That is how Dart resolves
// Platform.resolvedExecutable, whose folder StorageService reads portable.txt
// and the config from.
std::wstring FinalPath(const std::wstring& path) {
  const HANDLE file = ::CreateFileW(
      path.c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return path;
  }
  constexpr DWORD kFlags = FILE_NAME_NORMALIZED | VOLUME_NAME_DOS;
  std::wstring final_path;
  const DWORD size = ::GetFinalPathNameByHandleW(file, nullptr, 0, kFlags);
  if (size > 0) {
    final_path.resize(size);
    const DWORD length =
        ::GetFinalPathNameByHandleW(file, &final_path[0], size, kFlags);
    final_path.resize(length > 0 && length < size ? length : 0);
  }
  ::CloseHandle(file);
  if (final_path.empty()) {
    return path;
  }
  constexpr wchar_t kUncPrefix[] = L"\\\\?\\UNC\\";
  constexpr wchar_t kPrefix[] = L"\\\\?\\";
  if (final_path.rfind(kUncPrefix, 0) == 0) {
    return L"\\\\" + final_path.substr(ARRAYSIZE(kUncPrefix) - 1);
  }
  if (final_path.rfind(kPrefix, 0) == 0) {
    return final_path.substr(ARRAYSIZE(kPrefix) - 1);
  }
  return final_path;
}

// The directory holding this executable, resolved (FinalPath) and
// lowercased, or empty.
//
// Resolved because the scope is keyed by it. Spelled as GetModuleFileNameW
// spells it, one portable folder reached two ways - through a junction or a
// subst drive, as a mapped drive and as its UNC path - was two scopes, and a
// launch by the other path started a second instance on the same config
// instead of handing over. Launch at startup set that up on its own: the Run
// value holds the resolved path (StartupService), the user's shortcut need
// not. The executable is resolved rather than its folder, so that a link to
// the exe alone finds portable.txt where Dart finds it too.
std::wstring ExecutableDirectory() {
  wchar_t path[MAX_PATH * 4];
  const DWORD length = ::GetModuleFileNameW(nullptr, path, ARRAYSIZE(path));
  if (length == 0 || length >= ARRAYSIZE(path)) {
    return std::wstring();
  }
  std::wstring directory = FinalPath(std::wstring(path, length));
  const size_t slash = directory.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    return std::wstring();
  }
  directory.resize(slash);
  for (wchar_t& c : directory) {
    c = static_cast<wchar_t>(std::towlower(c));
  }
  return directory;
}

// Whether this executable runs in portable mode: a portable.txt beside it
// puts its config beside it too (StorageService.getStorageFile).
bool IsPortable(const std::wstring& directory) {
  if (directory.empty()) {
    return false;
  }
  const std::wstring marker = directory + L"\\portable.txt";
  const DWORD attributes = ::GetFileAttributesW(marker.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

// FNV-1a over the directory name: stable across runs, unlike a pointer or a
// PID, so a relaunch from the same folder finds the same instance.
UINT_PTR HashDirectory(const std::wstring& directory) {
  uint64_t hash = 14695981039346656037ULL;
  for (wchar_t c : directory) {
    hash ^= static_cast<uint64_t>(c);
    hash *= 1099511628211ULL;
  }
  // Never 0 (GetPropW's "no property") and never the shared tag.
  return static_cast<UINT_PTR>(hash | 2);
}

struct Scope {
  std::wstring mutex_name;
  UINT_PTR tag;
};

// Which other instance a launch hands over to.
//
// Instances that share a config must never run side by side - two writers of
// one channels_config.json - so every installed copy shares one scope,
// wherever it was installed from: a `flutter run` build and the installed app
// both use %APPDATA%. A PORTABLE copy keeps its config beside itself, so it
// is its own scope, keyed by its directory. Before this the mutex name was
// fixed, and a portable test build launched while the installed app sat in
// the tray exited at once and raised the installed app instead.
const Scope& CurrentScope() {
  static const Scope scope = [] {
    const std::wstring directory = ExecutableDirectory();
    if (!IsPortable(directory)) {
      return Scope{kMutexName, kSharedScopeTag};
    }
    const UINT_PTR tag = HashDirectory(directory);
    wchar_t suffix[32];
    swprintf_s(suffix, L".Portable.%016llx", static_cast<unsigned long long>(tag));
    return Scope{std::wstring(kMutexName) + suffix, tag};
  }();
  return scope;
}

struct Search {
  UINT_PTR tag;
  HWND found;
};

// EnumWindows callback: stops at the first top-level window carrying this
// scope's tag. EnumWindows includes hidden windows, which matters here:
// resting in the tray, the main window is hidden, not minimized.
BOOL CALLBACK FindTaggedWindow(HWND window, LPARAM param) {
  auto* search = reinterpret_cast<Search*>(param);
  const auto tag = reinterpret_cast<UINT_PTR>(
      ::GetPropW(window, kMainWindowProperty));
  if (tag != search->tag) {
    return TRUE;
  }
  search->found = window;
  return FALSE;
}

}  // namespace

const std::wstring& MutexName() {
  return CurrentScope().mutex_name;
}

UINT ActivateMessage() {
  static const UINT message = ::RegisterWindowMessageW(kActivateMessageName);
  return message;
}

bool IsActivateMessage(UINT message) {
  return message != 0 && message == ActivateMessage();
}

void MarkMainWindow(HWND window) {
  ::SetPropW(window, kMainWindowProperty,
             reinterpret_cast<HANDLE>(CurrentScope().tag));
  if (ActivateMessage() != 0) {
    ::ChangeWindowMessageFilterEx(window, ActivateMessage(), MSGFLT_ALLOW,
                                  nullptr);
  }
}

void UnmarkMainWindow(HWND window) {
  ::RemovePropW(window, kMainWindowProperty);
}

bool ActivateRunningInstance() {
  if (ActivateMessage() == 0) {
    return false;
  }

  Search search{CurrentScope().tag, nullptr};
  ::EnumWindows(FindTaggedWindow, reinterpret_cast<LPARAM>(&search));
  HWND window = search.found;
  if (window == nullptr) {
    return false;
  }

  // The user just started this process, so Windows lets it bring a window to
  // the foreground. Hand that right to the running instance, which raises
  // itself when it handles the message; without it, the foreground lock
  // would only flash its taskbar button.
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  ::AllowSetForegroundWindow(process_id);

  return ::PostMessageW(window, ActivateMessage(), 0, 0) != FALSE;
}

}  // namespace single_instance
