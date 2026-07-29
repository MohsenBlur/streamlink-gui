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
                    std::wstring targetStr = targetDir.wstring();
                    // Case-insensitive check if process is inside target directory
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
void ElevateAndRelaunch(const wchar_t* cmdLine) {
    wchar_t selfPath[MAX_PATH];
    GetModuleFileNameW(NULL, selfPath, MAX_PATH);

    SHELLEXECUTEINFOW sei = { sizeof(sei) };
    sei.cbSize = sizeof(sei);
    sei.lpVerb = L"runas";
    sei.lpFile = selfPath;
    sei.lpParameters = cmdLine;
    sei.nShow = SW_SHOWNORMAL;

    if (ShellExecuteExW(&sei)) {
        ExitProcess(0);
    }
}

// 4. Perform atomic directory swap and preserve user configuration
bool PerformSwap(const fs::path& targetDir, const fs::path& stagingDir) {
    fs::path backupDir = targetDir.parent_path() / (targetDir.filename().wstring() + L"_old");

    std::error_code ec;
    if (fs::exists(backupDir, ec)) {
        fs::remove_all(backupDir, ec);
    }

    // Step A: Target -> Backup
    if (!MoveFileExW(targetDir.c_str(), backupDir.c_str(), MOVEFILE_WRITE_THROUGH)) {
        return false;
    }

    // Step B: Staging -> Target
    if (!MoveFileExW(stagingDir.c_str(), targetDir.c_str(), MOVEFILE_WRITE_THROUGH)) {
        // Rollback on failure
        MoveFileExW(backupDir.c_str(), targetDir.c_str(), MOVEFILE_WRITE_THROUGH);
        return false;
    }

    // Step C: Preserve Portable Configuration Files
    const wchar_t* configFiles[] = { L"channels_config.json", L"portable.txt" };
    for (const auto* cfg : configFiles) {
        fs::path srcCfg = backupDir / cfg;
        fs::path dstCfg = targetDir / cfg;
        if (fs::exists(srcCfg, ec)) {
            CopyFileW(srcCfg.c_str(), dstCfg.c_str(), FALSE);
        }
    }

    // Step D: Clean up old backup
    fs::remove_all(backupDir, ec);
    return true;
}

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
    // 1. Lock DLL search path to System32 for security against DLL hijacking
    SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32);

    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc < 4) return 1;

    fs::path targetDir = argv[1];
    fs::path stagingDir = argv[2];
    std::wstring exeName = argv[3];

    // 2. Wait for main app Mutex release
    HANDLE hMutex = OpenMutexW(SYNCHRONIZE, FALSE, MUTEX_NAME);
    if (hMutex) {
        WaitForSingleObject(hMutex, 6000);
        CloseHandle(hMutex);
    }

    // 3. Terminate any child processes running in target directory
    TerminateProcessesInDir(targetDir);

    // 4. Privilege check & self-elevation if write permission is denied
    if (!IsDirWritable(targetDir)) {
        std::wstring rawCmd = GetCommandLineW();
        ElevateAndRelaunch(rawCmd.c_str());
    }

    // 5. Perform Atomic Directory Swap
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
