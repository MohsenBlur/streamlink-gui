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
            HANDLE hProcess = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE, FALSE, pe.th32ProcessID);
            if (hProcess) {
                wchar_t exePath[MAX_PATH];
                DWORD size = MAX_PATH;
                if (QueryFullProcessImageNameW(hProcess, 0, exePath, &size)) {
                    std::wstring pStr(exePath);
                    if (_wcsicmp(pStr.substr(0, targetStr.length()).c_str(), targetStr.c_str()) == 0) {
                        PostThreadMessage(pe.th32ProcessID, WM_QUIT, 0, 0);
                        if (WaitForSingleObject(hProcess, 2500) == WAIT_TIMEOUT) {
                            TerminateProcess(hProcess, 0);
                        }
                    }
                }
                CloseHandle(hProcess);
            }
        } while (Process32NextW(hSnapshot, &pe));
    }
    CloseHandle(hSnapshot);
}

// 2. Test directory write permission
bool IsDirWritable(const fs::path& dirPath) {
    fs::path testFile = dirPath / L".perm_probe";
    HANDLE hFile = CreateFileW(testFile.c_str(), GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                               FILE_ATTRIBUTE_HIDDEN | FILE_FLAG_DELETE_ON_CLOSE, NULL);
    if (hFile == INVALID_HANDLE_VALUE) return false;
    CloseHandle(hFile);
    return true;
}

// 3. Self-elevation via UAC (RunAs)
void ElevateAndRelaunch(const fs::path& targetDir, const fs::path& stagingDir, const std::wstring& exeName) {
    wchar_t selfPath[MAX_PATH];
    GetModuleFileNameW(NULL, selfPath, MAX_PATH);

    std::wstring targetStr = targetDir.wstring();
    std::wstring stagingStr = stagingDir.wstring();

    while (!targetStr.empty() && (targetStr.back() == L'\\' || targetStr.back() == L'/')) targetStr.pop_back();
    while (!stagingStr.empty() && (stagingStr.back() == L'\\' || stagingStr.back() == L'/')) stagingStr.pop_back();

    std::wstring params = L"\"" + targetStr + L"\" \"" + stagingStr + L"\" \"" + exeName + L"\" --elevated";

    SHELLEXECUTEINFOW sei = { sizeof(sei) };
    sei.cbSize = sizeof(sei);
    sei.lpVerb = L"runas";
    sei.lpFile = selfPath;
    sei.lpParameters = params.c_str();
    sei.nShow = SW_SHOWNORMAL;

    if (ShellExecuteExW(&sei)) {
        ExitProcess(0);
    }
}

// 4. Recursive directory copy with config preservation
bool CopyDirectoryContents(const fs::path& src, const fs::path& dst, bool preserveConfigs) {
    std::error_code ec;
    if (!fs::exists(dst, ec)) {
        fs::create_directories(dst, ec);
    }

    for (const auto& entry : fs::recursive_directory_iterator(src, ec)) {
        const auto& srcPath = entry.path();
        auto relativePath = fs::relative(srcPath, src, ec);
        auto dstPath = dst / relativePath;

        if (fs::is_directory(srcPath, ec)) {
            fs::create_directories(dstPath, ec);
        } else if (fs::is_regular_file(srcPath, ec)) {
            fs::create_directories(dstPath.parent_path(), ec);

            if (preserveConfigs) {
                std::wstring filename = srcPath.filename().wstring();
                if (_wcsicmp(filename.c_str(), L"channels_config.json") == 0 ||
                    _wcsicmp(filename.c_str(), L"portable.txt") == 0) {
                    if (fs::exists(dstPath, ec)) {
                        continue;
                    }
                }
            }
            fs::copy_file(srcPath, dstPath, fs::copy_options::overwrite_existing, ec);
            if (ec) {
                return false;
            }
        }
    }
    return true;
}

// 5. Perform safe directory file replacement with backup & rollback
bool PerformSwap(const fs::path& targetDir, const fs::path& stagingDir) {
    std::error_code ec;

    wchar_t tempPathBuffer[MAX_PATH];
    GetTempPathW(MAX_PATH, tempPathBuffer);
    fs::path backupDir = fs::path(tempPathBuffer) / L"streamlink_gui_backup";

    if (fs::exists(backupDir, ec)) {
        fs::remove_all(backupDir, ec);
    }

    // Step A: Backup current installation
    if (!CopyDirectoryContents(targetDir, backupDir, false)) {
        return false;
    }

    // Step B: Copy updated files from staging to target (preserving configs)
    if (!CopyDirectoryContents(stagingDir, targetDir, true)) {
        // Rollback on failure
        CopyDirectoryContents(backupDir, targetDir, false);
        return false;
    }

    // Step C: Clean up backup
    fs::remove_all(backupDir, ec);
    return true;
}

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
    SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32);

    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc < 4) return 1;

    fs::path targetDir = argv[1];
    fs::path stagingDir = argv[2];
    std::wstring exeName = argv[3];
    bool isElevated = (argc >= 5 && std::wstring(argv[4]) == L"--elevated");

    // 1. Wait for main app Mutex release
    HANDLE hMutex = OpenMutexW(SYNCHRONIZE, FALSE, MUTEX_NAME);
    if (hMutex) {
        WaitForSingleObject(hMutex, 6000);
        CloseHandle(hMutex);
    }

    // 2. Terminate any child processes running in target directory
    TerminateProcessesInDir(targetDir);

    // 3. Privilege check & self-elevation if write permission is denied
    if (!isElevated && !IsDirWritable(targetDir)) {
        ElevateAndRelaunch(targetDir, stagingDir, exeName);
    }

    // 4. Perform Directory File Replacement
    if (PerformSwap(targetDir, stagingDir)) {
        // Relaunch Application
        fs::path exePath = targetDir / exeName;
        SHELLEXECUTEINFOW sei = { sizeof(sei) };
        sei.cbSize = sizeof(sei);
        sei.lpVerb = L"open";
        sei.lpFile = exePath.c_str();
        sei.nShow = SW_SHOWNORMAL;
        ShellExecuteExW(&sei);
    } else {
        MessageBoxW(NULL, L"The update could not be completed. Your previous version has been safely restored.",
                    L"Streamlink GUI Update", MB_OK | MB_ICONERROR);
    }

    LocalFree(argv);
    return 0;
}
