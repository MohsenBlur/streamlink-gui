#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <shellapi.h>
#include <shlwapi.h>
#include <string>
#include <filesystem>
#include <vector>

#pragma comment(lib, "Shell32.lib")
#pragma comment(lib, "Shlwapi.lib")
#pragma comment(lib, "User32.lib")

namespace fs = std::filesystem;
const wchar_t* MUTEX_NAME = L"Local\\TwitchStreamlinkGUIUniqueMutexName";
const wchar_t* BREAKAWAY_FLAG = L"--no-job";

static std::wstring g_logPath;// Set when an install failed AND its rollback could not fully restore the
// previous files, so the installation is left in a mixed state.
static bool g_installInconsistent = false;

// Appends a line to updater.log next to the target application.
//
// The updater used to run completely blind: a single generic message box was
// its only output, so a failed update left nothing to diagnose.
void LogLine(const std::wstring& message) {
    if (g_logPath.empty()) return;
    HANDLE hFile = CreateFileW(g_logPath.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ,
                               NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) return;

    SYSTEMTIME st;
    GetLocalTime(&st);
    wchar_t stamp[32];
    swprintf_s(stamp, L"%02d:%02d:%02d  ", st.wHour, st.wMinute, st.wSecond);

    std::wstring line = std::wstring(stamp) + message + L"\r\n";
    int bytes = WideCharToMultiByte(CP_UTF8, 0, line.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (bytes > 1) {
        std::vector<char> utf8(static_cast<size_t>(bytes));
        WideCharToMultiByte(CP_UTF8, 0, line.c_str(), -1, utf8.data(), bytes, nullptr, nullptr);
        DWORD written = 0;
        WriteFile(hFile, utf8.data(), static_cast<DWORD>(bytes - 1), &written, NULL);
    }
    CloseHandle(hFile);
}

// Returns the value of a "--name value" argument, or an empty string.
std::wstring ArgValue(int argc, LPWSTR* argv, const wchar_t* name) {
    for (int i = 1; i + 1 < argc; ++i) {
        if (wcscmp(argv[i], name) == 0) return argv[i + 1];
    }
    return std::wstring();
}

// Creates the file the launching app waits on to learn that we are safely
// outside its job object and it may exit. Returns false when there was nothing
// to signal, so the caller does not claim it signalled when it did not.
bool SignalReady(int argc, LPWSTR* argv) {
    for (int i = 1; i + 1 < argc; ++i) {
        if (wcscmp(argv[i], L"--ready-file") != 0) continue;
        HANDLE h = CreateFileW(argv[i + 1], GENERIC_WRITE, FILE_SHARE_READ, NULL,
                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h != INVALID_HANDLE_VALUE) {
            const char ok[] = "ready";
            DWORD written = 0;
            WriteFile(h, ok, sizeof(ok) - 1, &written, NULL);
            CloseHandle(h);
            return true;
        }
        return false;
    }
    return false;
}

// The main app assigns itself to a job object with KILL_ON_JOB_CLOSE so its
// helper processes cannot outlive it. We inherit that job, which would kill us
// the moment the app exits - in the middle of replacing its files. Relaunch
// ourselves outside the job and let this instance exit.
//
// Returns true if a breakaway relaunch was started and the caller should exit.
bool EnsureOutsideJob(int argc, LPWSTR* argv) {
    for (int i = 1; i < argc; ++i) {
        if (wcscmp(argv[i], BREAKAWAY_FLAG) == 0) return false;  // already broken away
    }

    BOOL inJob = FALSE;
    if (!IsProcessInJob(GetCurrentProcess(), NULL, &inJob) || !inJob) {
        return false;
    }

    wchar_t selfPath[MAX_PATH];
    if (GetModuleFileNameW(NULL, selfPath, MAX_PATH) == 0) return false;

    std::wstring cmd = std::wstring(L"\"") + selfPath + L"\"";
    for (int i = 1; i < argc; ++i) {
        cmd += std::wstring(L" \"") + argv[i] + L"\"";
    }
    cmd += std::wstring(L" ") + BREAKAWAY_FLAG;

    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi = {};
    std::vector<wchar_t> mutableCmd(cmd.begin(), cmd.end());
    mutableCmd.push_back(L'\0');

    if (CreateProcessW(NULL, mutableCmd.data(), NULL, NULL, FALSE,
                       CREATE_BREAKAWAY_FROM_JOB | DETACHED_PROCESS,
                       NULL, NULL, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return true;
    }

    // The job may forbid breakaway. Continuing in-job is still better than not
    // updating at all: the app has usually already exited by this point, which
    // closes the job and would take us with it, but if it has not we may still
    // finish.
    LogLine(L"WARNING: could not break away from job object; continuing in-job.");
    return false;
}

// Posts WM_CLOSE to every top-level window owned by the given process, so it
// can shut down cleanly instead of being terminated.
BOOL CALLBACK CloseWindowForPid(HWND hwnd, LPARAM lParam) {
    DWORD windowPid = 0;
    GetWindowThreadProcessId(hwnd, &windowPid);
    if (windowPid == static_cast<DWORD>(lParam)) {
        PostMessageW(hwnd, WM_CLOSE, 0, 0);
    }
    return TRUE;
}

// 1. Terminate processes whose executable resides inside target directory
void TerminateProcessesInDir(const fs::path& targetDir) {
    HANDLE hSnapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (hSnapshot == INVALID_HANDLE_VALUE) return;

    std::wstring targetStr = targetDir.wstring();
    if (!targetStr.empty() && targetStr.back() != L'\\' && targetStr.back() != L'/') {
        targetStr += L'\\';
    }

    PROCESSENTRY32W pe = { sizeof(pe) };
    if (Process32FirstW(hSnapshot, &pe)) {
        do {
            if (pe.th32ProcessID == GetCurrentProcessId()) continue;
            HANDLE hProcess = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE | SYNCHRONIZE, FALSE, pe.th32ProcessID);
            if (hProcess) {
                wchar_t exePath[MAX_PATH];
                DWORD size = MAX_PATH;
                if (QueryFullProcessImageNameW(hProcess, 0, exePath, &size)) {
                    std::wstring pStr(exePath);
                    if (_wcsicmp(pStr.substr(0, targetStr.length()).c_str(), targetStr.c_str()) == 0) {
                        LogLine(L"Closing process: " + pStr);
                        // Ask nicely first. This used to call
                        // PostThreadMessage(pe.th32ProcessID, WM_QUIT, ...),
                        // passing a PROCESS id where a THREAD id is required:
                        // it always failed, so every process ate the full
                        // timeout and was then hard-killed - and because thread
                        // and process ids share a namespace it could also
                        // deliver WM_QUIT into an unrelated application.
                        EnumWindows(CloseWindowForPid, static_cast<LPARAM>(pe.th32ProcessID));
                        if (WaitForSingleObject(hProcess, 2500) == WAIT_TIMEOUT) {
                            LogLine(L"  did not exit in time; terminating.");
                            TerminateProcess(hProcess, 0);
                            WaitForSingleObject(hProcess, 2000);
                        }
                    }
                }
                CloseHandle(hProcess);
            }
        } while (Process32NextW(hSnapshot, &pe));
    }
    CloseHandle(hSnapshot);
}

// 2. Test directory write permission.
//
// Distinguishes "denied" from other failures so a transient error (a locked
// probe file, a disconnected drive) is not misread as "needs elevation".
bool IsDirWritable(const fs::path& dirPath, bool* accessDenied) {
    if (accessDenied) *accessDenied = false;

    fs::path testFile = dirPath / L".perm_probe";
    HANDLE hFile = CreateFileW(testFile.c_str(), GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                               FILE_ATTRIBUTE_HIDDEN | FILE_FLAG_DELETE_ON_CLOSE, NULL);
    if (hFile == INVALID_HANDLE_VALUE) {
        DWORD err = GetLastError();
        if (accessDenied) {
            *accessDenied = (err == ERROR_ACCESS_DENIED || err == ERROR_PRIVILEGE_NOT_HELD);
        }
        LogLine(L"Target directory is not writable (error " + std::to_wstring(err) + L").");
        return false;
    }
    CloseHandle(hFile);
    return true;
}

// Paths longer than MAX_PATH need the extended-length prefix. Applied to the
// roots so every path derived from them inherits it.
fs::path LongPath(const fs::path& p) {
    std::wstring s = p.wstring();
    if (s.size() < 240) return p;                              // comfortably short
    if (s.rfind(L"\\\\?\\", 0) == 0) return p;                 // already extended
    if (s.rfind(L"\\\\", 0) == 0) return fs::path(L"\\\\?\\UNC\\" + s.substr(2));
    return fs::path(L"\\\\?\\" + s);
}

bool IsPreservedConfig(const std::wstring& filename) {
    // Must never be replaced by an update: these hold the user's own data.
    return _wcsicmp(filename.c_str(), L"channels_config.json") == 0 ||
           _wcsicmp(filename.c_str(), L"portable.txt") == 0 ||
           _wcsicmp(filename.c_str(), L"recent_watched_vods.json") == 0 ||
           _wcsicmp(filename.c_str(), L"yt_dlp_archive.txt") == 0;
}

void ClearReadOnly(const fs::path& p) {
    DWORD attrs = GetFileAttributesW(p.c_str());
    if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_READONLY)) {
        SetFileAttributesW(p.c_str(), attrs & ~FILE_ATTRIBUTE_READONLY);
    }
}

// Collects every regular file under root, as paths relative to root.
//
// Uses the error_code form of directory_iterator::increment throughout. The
// previous implementation drove a recursive_directory_iterator with a range-for,
// whose operator++ throws - and this binary is compiled with _HAS_EXCEPTIONS=0,
// so any unreadable subdirectory (an ACL, an antivirus lock, a directory removed
// mid-walk) called terminate() and aborted the updater outright, halfway through
// replacing the installation and with no rollback performed.
bool CollectFiles(const fs::path& root, std::vector<fs::path>& out) {
    std::error_code ec;
    if (!fs::exists(root, ec)) return false;

    std::vector<fs::path> pending;
    pending.push_back(root);

    while (!pending.empty()) {
        fs::path dir = pending.back();
        pending.pop_back();

        fs::directory_iterator it(dir, fs::directory_options::skip_permission_denied, ec);
        if (ec) {
            LogLine(L"  skipping unreadable directory: " + dir.wstring());
            ec.clear();
            continue;
        }
        const fs::directory_iterator end;
        while (it != end) {
            const fs::path entry = it->path();
            std::error_code statEc;
            if (fs::is_directory(entry, statEc) && !statEc) {
                pending.push_back(entry);
            } else if (fs::is_regular_file(entry, statEc) && !statEc) {
                std::error_code relEc;
                fs::path rel = fs::relative(entry, root, relEc);
                if (!relEc) out.push_back(rel);
            }
            it.increment(ec);
            if (ec) {
                LogLine(L"  stopped enumerating " + dir.wstring());
                ec.clear();
                break;
            }
        }
    }
    return true;
}

// Copies the given relative paths from src to dst.
bool CopyFiles(const fs::path& src, const fs::path& dst,
               const std::vector<fs::path>& relatives, bool preserveConfigs) {
    std::error_code ec;
    for (size_t i = 0; i < relatives.size(); ++i) {
        const fs::path& rel = relatives[i];
        const fs::path from = src / rel;
        const fs::path to = dst / rel;

        if (preserveConfigs && IsPreservedConfig(rel.filename().wstring())) {
            ec.clear();
            if (fs::exists(to, ec)) continue;
        }

        ec.clear();
        fs::create_directories(to.parent_path(), ec);

        ClearReadOnly(to);
        ec.clear();
        fs::copy_file(from, to, fs::copy_options::overwrite_existing, ec);
        if (ec) {
            LogLine(L"FAILED to copy " + rel.wstring() + L" (error " +
                    std::to_wstring(ec.value()) + L")");
            return false;
        }
    }
    return true;
}

// 5. Replace the installation, with a backup limited to what actually changes.
//
// The backup used to be a byte copy of the entire installation (hundreds of MB,
// including the bundled Python and ffmpeg) into %TEMP% on every update. Only the
// files the update will overwrite need saving.
bool PerformSwap(const fs::path& targetDir, const fs::path& stagingDir) {
    std::error_code ec;

    wchar_t tempPathBuffer[MAX_PATH + 1] = {};
    if (GetTempPathW(MAX_PATH + 1, tempPathBuffer) == 0) {
        LogLine(L"Could not resolve %TEMP%.");
        return false;
    }
    const fs::path backupDir = LongPath(fs::path(tempPathBuffer) / L"streamlink_gui_backup");

    fs::remove_all(backupDir, ec);
    ec.clear();

    std::vector<fs::path> incoming;
    if (!CollectFiles(stagingDir, incoming) || incoming.empty()) {
        // A missing or empty staging directory previously sailed straight
        // through and was reported to the user as a successful update.
        LogLine(L"Staging directory is missing or empty - refusing to continue.");
        return false;
    }
    LogLine(L"Update contains " + std::to_wstring(incoming.size()) + L" files.");

    // Step A: back up only the files that will be overwritten.
    std::vector<fs::path> toBackup;
    for (size_t i = 0; i < incoming.size(); ++i) {
        const fs::path& rel = incoming[i];
        if (IsPreservedConfig(rel.filename().wstring())) continue;
        ec.clear();
        if (fs::exists(targetDir / rel, ec)) toBackup.push_back(rel);
    }
    LogLine(L"Backing up " + std::to_wstring(toBackup.size()) + L" existing files.");
    if (!CopyFiles(targetDir, backupDir, toBackup, false)) {
        LogLine(L"Backup failed - aborting before touching the installation.");
        ec.clear();
        fs::remove_all(backupDir, ec);
        return false;
    }

    // Step B: install the update.
    if (!CopyFiles(stagingDir, targetDir, incoming, true)) {
        LogLine(L"Install failed - rolling back.");
        if (CopyFiles(backupDir, targetDir, toBackup, false)) {
            LogLine(L"Rollback restored " + std::to_wstring(toBackup.size()) + L" files.");
            ec.clear();
            fs::remove_all(backupDir, ec);
        } else {
            // The rollback result used to be discarded, so a partially restored
            // installation was still reported as "safely restored". Keep the
            // backup in place so it can be recovered by hand.
            g_installInconsistent = true;
            LogLine(L"ROLLBACK INCOMPLETE - installation may be inconsistent. "
                    L"Previous files kept at: " + backupDir.wstring());
        }
        return false;
    }

    LogLine(L"Install completed successfully.");
    ec.clear();
    fs::remove_all(backupDir, ec);
    return true;
}

// Launches the updated application.
//
// Called from the NON-elevated instance. When the target needs elevation the
// swap runs in a separate elevated child, so the relaunched app inherits the
// user's token rather than an administrator one. Relaunching from the elevated
// process left the app running as admin until manually restarted: it broke
// drag-and-drop, gave every downloaded file admin ownership, and - for a
// standard user who elevated with a different admin account - redirected
// %APPDATA% so the app appeared to have lost all of its settings.
void RelaunchApp(const fs::path& targetDir, const std::wstring& exeName) {
    const fs::path exePath = targetDir / exeName;
    std::error_code ec;
    if (!fs::exists(exePath, ec)) {
        LogLine(L"Cannot relaunch: " + exePath.wstring() + L" not found.");
        return;
    }

    SHELLEXECUTEINFOW sei = { sizeof(sei) };
    sei.cbSize = sizeof(sei);
    sei.fMask = SEE_MASK_NOASYNC;  // this process exits immediately afterwards
    sei.lpVerb = L"open";
    sei.lpFile = exePath.c_str();
    sei.lpDirectory = targetDir.c_str();
    sei.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&sei)) {
        LogLine(L"Relaunch failed (error " + std::to_wstring(GetLastError()) + L").");
    } else {
        LogLine(L"Relaunched " + exePath.wstring());
    }
}

enum SwapOutcome { kSwapOk, kSwapFailed, kSwapCancelled };

// 3. Run the swap in an elevated copy of ourselves and wait for it to finish.
SwapOutcome RunElevatedSwap(const fs::path& targetDir, const fs::path& stagingDir,
                            const std::wstring& exeName) {
    wchar_t selfPath[MAX_PATH] = {};
    if (GetModuleFileNameW(NULL, selfPath, MAX_PATH) == 0) {
        LogLine(L"Could not determine our own path for elevation.");
        return kSwapFailed;
    }

    std::wstring targetStr = targetDir.wstring();
    std::wstring stagingStr = stagingDir.wstring();
    // Trailing separators must be stripped: CommandLineToArgvW treats a
    // backslash immediately before a closing quote as an escape, which corrupts
    // the argument the elevated instance receives.
    while (!targetStr.empty() && (targetStr.back() == L'\\' || targetStr.back() == L'/')) targetStr.pop_back();
    while (!stagingStr.empty() && (stagingStr.back() == L'\\' || stagingStr.back() == L'/')) stagingStr.pop_back();

    std::wstring params = L"\"" + targetStr + L"\" \"" + stagingStr + L"\" \"" +
                          exeName + L"\" --elevated " + BREAKAWAY_FLAG;
    if (!g_logPath.empty()) {
        params += L" --log-file \"" + g_logPath + L"\"";
    }

    SHELLEXECUTEINFOW sei = { sizeof(sei) };
    sei.cbSize = sizeof(sei);
    sei.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
    sei.lpVerb = L"runas";
    sei.lpFile = selfPath;
    sei.lpParameters = params.c_str();
    sei.nShow = SW_SHOWNORMAL;

    if (!ShellExecuteExW(&sei)) {
        const DWORD err = GetLastError();
        if (err == ERROR_CANCELLED) {
            // The user declined the UAC prompt. Previously execution simply fell
            // through into the swap and spent minutes copying the entire
            // installation into %TEMP% before failing on the first write to a
            // directory it had already proven it could not write to.
            LogLine(L"Elevation declined by the user.");
            return kSwapCancelled;
        }
        LogLine(L"Elevation failed (error " + std::to_wstring(err) + L").");
        return kSwapFailed;
    }

    if (sei.hProcess == NULL) return kSwapFailed;

    WaitForSingleObject(sei.hProcess, INFINITE);
    DWORD exitCode = 1;
    GetExitCodeProcess(sei.hProcess, &exitCode);
    CloseHandle(sei.hProcess);

    LogLine(L"Elevated swap finished with code " + std::to_wstring(exitCode) + L".");
    return exitCode == 0 ? kSwapOk : kSwapFailed;
}

void ShowError(const std::wstring& message) {
    MessageBoxW(NULL, message.c_str(), L"Streamlink GUI Update",
                MB_OK | MB_ICONERROR | MB_SETFOREGROUND | MB_TOPMOST);
}

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
    SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32);

    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc < 4) {
        if (argv) LocalFree(argv);
        return 1;
    }

    const fs::path targetDir = LongPath(fs::path(argv[1]));
    const fs::path stagingDir = LongPath(fs::path(argv[2]));
    const std::wstring exeName = argv[3];

    bool isElevated = false;
    for (int i = 4; i < argc; ++i) {
        if (wcscmp(argv[i], L"--elevated") == 0) isElevated = true;
    }

    // Log where this instance can actually write.
    //
    // updater.log lives next to the app, but for a Program Files install only
    // the ELEVATED instance can write there - so the non-elevated parent, which
    // performs the job breakaway, the writability probe, the elevation decision
    // and the readiness handshake, produced no diagnostics at all. That is
    // precisely the phase most likely to fail.
    //
    // The elevated child is handed the parent's path so the whole sequence ends
    // up in one file.
    const std::wstring logOverride = ArgValue(argc, argv, L"--log-file");
    if (!logOverride.empty()) {
        g_logPath = logOverride;
    } else {
        const fs::path preferred = targetDir / L"updater.log";
        HANDLE probe = CreateFileW(preferred.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ,
                                   NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (probe != INVALID_HANDLE_VALUE) {
            CloseHandle(probe);
            g_logPath = preferred.wstring();
        } else {
            wchar_t tempDir[MAX_PATH + 1] = {};
            if (GetTempPathW(MAX_PATH + 1, tempDir) != 0) {
                g_logPath = (fs::path(tempDir) / L"streamlink_gui_updater.log").wstring();
            } else {
                g_logPath = preferred.wstring();
            }
        }
    }
    LogLine(L"--- updater start (elevated=" + std::wstring(isElevated ? L"yes" : L"no") + L") ---");
    LogLine(L"target:  " + targetDir.wstring());
    LogLine(L"staging: " + stagingDir.wstring());

    // Escape the app's job object before doing anything slow, or its
    // KILL_ON_JOB_CLOSE will take us down the moment the app exits - in the
    // middle of replacing its files.
    if (EnsureOutsideJob(argc, argv)) {
        // The relaunched instance signals readiness; this one is still inside
        // the job and is about to exit.
        LocalFree(argv);
        return 0;
    }

    // Safely outside the app's job object (or never in one). Tell the app it
    // may now exit: until this point, its exit would close the job and kill us
    // in the middle of replacing its files.
    if (SignalReady(argc, argv)) {
        LogLine(L"Signalled ready; the application may now exit.");
    }

    // Wait for the app to release its single-instance mutex.
    HANDLE hMutex = OpenMutexW(SYNCHRONIZE, FALSE, MUTEX_NAME);
    if (hMutex) {
        WaitForSingleObject(hMutex, 6000);
        CloseHandle(hMutex);
    }

    TerminateProcessesInDir(targetDir);

    // The elevated child performs only the swap; its non-elevated parent does
    // the relaunch, so the app never inherits the administrator token.
    if (isElevated) {
        const bool ok = PerformSwap(targetDir, stagingDir);
        LogLine(ok ? L"--- elevated swap ok ---" : L"--- elevated swap failed ---");
        LocalFree(argv);
        return ok ? 0 : 1;
    }

    SwapOutcome outcome = kSwapFailed;
    bool accessDenied = false;
    if (IsDirWritable(targetDir, &accessDenied)) {
        outcome = PerformSwap(targetDir, stagingDir) ? kSwapOk : kSwapFailed;
    } else if (accessDenied) {
        outcome = RunElevatedSwap(targetDir, stagingDir, exeName);
    } else {
        LogLine(L"Target directory is unavailable.");
    }

    // Always bring the application back. The relaunch previously lived only in
    // the success branch, so any failure - backup error, declined UAC, copy
    // error - left the user with no running application at all, because the app
    // had already exited before the updater started.
    RelaunchApp(targetDir, exeName);

    if (outcome == kSwapCancelled) {
        ShowError(L"The update was cancelled because administrator permission was not granted.\n\n"
                  L"Your current version has been restarted and is unchanged.");
    } else if (outcome == kSwapFailed && g_installInconsistent) {
        // Do not claim the previous version was restored when it demonstrably
        // was not: some files are from the new version and some from the old,
        // and the app has just been relaunched in that state.
        ShowError(L"The update failed and the previous version could NOT be fully restored, "
                  L"so this installation is now in a mixed state.\n\n"
                  L"A copy of your previous files is kept in your TEMP folder under "
                  L"streamlink_gui_backup. Reinstalling the latest version from GitHub is the "
                  L"safest way to recover.\n\nSee updater.log for details.");
    } else if (outcome == kSwapFailed) {
        ShowError(L"The update could not be completed and your previous version has been restarted.\n\n"
                  L"See updater.log in the application folder for details.");
    }

    LogLine(L"--- updater end ---");
    LocalFree(argv);
    return outcome == kSwapOk ? 0 : 1;
}
