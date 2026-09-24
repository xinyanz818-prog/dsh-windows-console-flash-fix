# DSH Desktop opens a console window for every command on Windows

Every command that DSH Desktop executes opens a console window on the desktop. This repository contains a script that patches an existing local installation to stop it.

The repository does not include or redistribute any DSH Desktop code. The script modifies installed files in place; decide for yourself whether that is acceptable in your environment, and consider reporting the problem upstream as well (see [BUG-REPORT.md](BUG-REPORT.md) for the report and [EVIDENCE.md](EVIDENCE.md) for the measurement record).

## Symptom

Each command invocation opens a console window that closes when the command ends. On Windows 11 with Windows Terminal set as the default terminal application, the window is a full Windows Terminal window that takes about a second to appear; with Windows Console Host as the default, it is a classic console window.

## Cause

Windows allocates a new console window for a console child process unless the creator passes `CREATE_NO_WINDOW` (`0x08000000`). Two levels of process creation in the command path omit it.

A single command involves two creations:

```
DSH runtime → Windows Job runner → powershell.exe
```

1. The spawn of the Job runner does not set `windowsHide`.
   Location: `@deepseek-ai/dsh-subprocess-local/lib/index.js`, `launchWindowsJob()`.

2. The runner creates the actual command process with a `dwCreationFlags` value that does not include `CREATE_NO_WINDOW`.
   Location: `@deepseek-ai/dsh-win32-process/lib/index.js`. Three creation calls pass `1028` (`CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT`), `4` (`CREATE_SUSPENDED`) and `0`.

The second one produces the visible window, which belongs to the command process itself. Process state before the fix:

```
GetConsoleWindow()  = valid handle (462730)
window class        = ConsoleWindowClass
IsWindowVisible     = True
window size         = 992 x 837
stdin/stdout/stderr = pipes (not a ConPTY pseudo terminal)
process chain       = DSH Desktop (server) → DSH Desktop (runner.js) → powershell.exe → conhost.exe
```

All three standard streams being pipes rules out a pseudo-terminal path, so the window comes from an ordinary console allocation.

## Patch

| File | Location | Change |
| --- | --- | --- |
| `node_modules/@deepseek-ai/dsh-win32-process/lib/index.js` | `dwCreationFlags` of the ordinary `CreateProcessW` | `1028` → `1028 \| 0x08000000` |
| same | restricted-token `CreateProcessAsUserW` | `4` → `4 \| 0x08000000` |
| same | inherited-handle `CreateProcessAsUserW` | `0` → `0x08000000` |
| `node_modules/@deepseek-ai/dsh-subprocess-local/lib/index.js` | spawn options in `launchWindowsJob()` | add `windowsHide: true` |
| `src/engine/agents/workspace_turn_snapshot.js` | per-turn git snapshot | add `windowsHide: true` |
| `src/engine/agents/workspace_change_provider.js` | change-list refresh | add `windowsHide: true` |
| `src/engine/agents/git_workspace.js` | worktree operations | add `windowsHide: true` |
| `src/engine/agent_kernel/app_server_client.js` | codex app-server start | add `windowsHide: true` |
| `src/engine/dsh_runtime/client.js` | runtime child process | add `windowsHide: true` |

The first three rows address the cause. The remaining rows are the same class of problem: those spawn calls open console windows too, and the three git-related ones run on every turn. Only the ordinary `CreateProcessW` path has been verified after patching; the verified scope section in [BUG-REPORT.md](BUG-REPORT.md) lists what was and was not exercised.

## Usage

1. Quit DSH Desktop completely, including the tray icon.
2. Open PowerShell as Administrator:

```powershell
powershell -ExecutionPolicy Bypass -File .\fix-dsh-console-flash.ps1
```

The script locates the installation automatically; pass `-Root` to point at the `resources\server` directory explicitly. It writes a `*.dshbak-<timestamp>` backup before modifying each file, can be run repeatedly (already patched sites are skipped), and reports clearly when an anchor does not match the installed version instead of modifying anything.

3. Restart DSH Desktop. Node modules load at process start, so the patch has no effect until then.

## Verification

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-ConsoleFlash.ps1
```

The script records the visible console windows before and after running console child processes, including a control group that asks Windows for a new console, and prints a verdict. Output after the patch:

```
GetConsoleWindow() = 0
RESULT: PASS - no new visible console window appeared.
```

## Revert

```powershell
powershell -ExecutionPolicy Bypass -File .\fix-dsh-console-flash.ps1 -Revert
```

This restores the modified files from the most recent backup.

## Maintenance

Application updates and reinstalls overwrite the patched files, which disables the patch; run the script again afterwards.

The scripts use ASCII characters only. Windows PowerShell 5.1 decodes a `.ps1` file without a BOM using the system ANSI code page, so non-ASCII comments would be decoded incorrectly and some byte sequences would break parsing.

Changing the Windows default terminal application from Windows Terminal to Windows Console Host only changes how the window is presented; it does not remove it.

## References

- openai/codex issue 18984 — Windows: hide command-safety PowerShell parser process to avoid pwsh.exe console flashes
  <https://github.com/openai/codex/issues/18984>
- openai/codex issue 44768 — Windows: app-server daemon opens a visible console window for every hook and shell command it runs
  <https://github.com/openai/codex/issues/44768>
- anthropics/claude-code issue 78189 — Windows: detached background pty hosts cause visible pwsh/console window flashes at session start
  <https://github.com/anthropics/claude-code/issues/78189>
- Node.js `child_process` documentation, `windowsHide` option
  <https://nodejs.org/api/child_process.html>

## License

MIT
