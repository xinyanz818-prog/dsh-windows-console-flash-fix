# Measurement record

All measurements were taken on Windows 11 on the machine where the problem was reported. The probes were executed through the DSH Desktop pwsh tool, so they ran inside the same code path that produced the window. Labels in the original tool output were Chinese; the values are reproduced here unchanged with English labels.

## Environment

- DSH Desktop 0.2.5 (`DSH Desktop.exe` file version); bundled server `@dsh/server` 0.2.5
- `@deepseek-ai/dsh-subprocess-local` and `@deepseek-ai/dsh-win32-process` 0.1.5-rc.1
- `@openai/codex` 0.147.0
- Permission preset during the post-fix measurements: `danger-full-access`

## Method

- Window inspection: `EnumWindows` with `GetClassName`, `IsWindowVisible`, `GetWindowRect`, `GetWindowThreadProcessId`; the process's own console handle from `GetConsoleWindow`.
- Process relationships: `Win32_Process` (name, pid, parent pid, creation time, command line).
- Stream type: `[Console]::IsInputRedirected`, `IsOutputRedirected`, `IsErrorRedirected`.

`Test-ConsoleFlash.ps1` in this repository performs the window inspection part and can be run on any installation.

## 1. The window belongs to the command process (before the fix)

```
GetConsoleWindow()  = 462730
window class        = ConsoleWindowClass
IsWindowVisible     = True
WS_VISIBLE          = True
window size         = 992 x 837
stdin redirected    = True
stdout redirected   = True
stderr redirected   = True
```

The window handle is valid and visible, and it belongs to the process whose pid is the command process. All three standard streams are pipes, so the command is not attached to a pseudo terminal.

A second sample, taken with `EnumWindows` while the command was running, listed the same window as the only visible console window apart from windows opened by the user:

```
ConsoleWindowClass  pid=<command pid>  992x837  title='C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe'
```

## 2. Process chain of one command

```
powershell.exe      pid=26840  parent=27980
DSH Desktop.exe     pid=27980  (command line: ...\@deepseek-ai\dsh-subprocess-local\lib\runner.js -- <target argv>)
conhost.exe         pid=30652  parent=26840
```

The runner is the intermediate process created by `launchWindowsJob()`. The visible console belongs to the powershell process, whose parent is the runner.

## 3. Two console allocations per command (before the fix)

Processes observed within five seconds of one command invocation:

```
conhost         11:50:25.417
powershell      11:50:25.459
DSH Desktop     11:50:26.307   <- Job runner
powershell      11:50:26.418   <- the command
conhost         11:50:26.433
```

## 4. Default terminal application

With `HKCU\Console\%%Startup` unset, the window was hosted by Windows Terminal and appeared as a WindowsTerminal process plus a `CASCADIA_HOSTING_WINDOW_CLASS` window of 1168x624; setting the delegation values to the console host GUID (`{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}`) replaced it with a `ConsoleWindowClass` window. In both cases a visible window was created for every command, so the terminal application only changes the presentation.

## 5. After the fix

Same probe, run after applying the patch and restarting DSH Desktop:

```
GetConsoleWindow()  = 0
IsWindowVisible     = False
WS_VISIBLE          = False
window size         = 0 x 0
top-level windows owned by the process = none
visible console windows while the command ran = none
```

`Test-ConsoleFlash.ps1`, which also runs a control group that explicitly requests a new console (`CreateNoWindow = false`, sampled every 100 ms), reports:

```
=== console flash test ===

1) this host process
   no console window at all (GetConsoleWindow() = 0)

2) visible console windows before: 0

3) running console child processes...
   cmd /c echo -> child-ok
   control group: CreateNoWindow = false (asks for a new console), ~2s, sampled every 100ms

4) holding 6 second(s) - watch the screen now

RESULT: PASS - no new visible console window appeared.
```

Child processes started from within a command (`cmd.exe /c echo`) also produced no window. All post-fix measurements were taken under the `danger-full-access` preset; the restricted-token paths (`CreateProcessAsUserW`) used by `read-only` and `workspace-write` were patched but not exercised. See the verified scope section in BUG-REPORT.md.
