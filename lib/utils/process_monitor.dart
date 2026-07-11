import 'dart:io';

void startProcessMonitor() {
  if (!Platform.isWindows) return;
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;
  
  final parentPid = pid;
  final bridgeScript = '''
    \$ErrorActionPreference = 'Stop'
    \$parentPid = $parentPid
    
    function Kill-Tree(\$p) {
      \$children = Get-CimInstance Win32_Process -Filter "ParentProcessId = \$p" -ErrorAction SilentlyContinue
      if (\$children) {
        foreach (\$child in \$children) {
          if (\$child.ProcessId -ne \$PID) {
            Kill-Tree \$child.ProcessId
          }
        }
      }
      if (\$p -ne \$parentPid) {
        Stop-Process -Id \$p -Force -ErrorAction SilentlyContinue
      }
    }

    while (\$true) {
      Start-Sleep -Seconds 1
      \$parent = Get-Process -Id \$parentPid -ErrorAction SilentlyContinue
      if (-not \$parent) {
        Kill-Tree \$parentPid
        Stop-Process -Id \$PID -Force
        break
      }
    }
  ''';

  try {
    Process.start(
      'powershell',
      ['-WindowStyle', 'Hidden', '-Command', bridgeScript],
      runInShell: false,
    );
  } catch (_) {}
}
