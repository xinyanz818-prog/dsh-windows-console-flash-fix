# Bug report: every command opens a console window on Windows (`dwCreationFlags` lacks `CREATE_NO_WINDOW`)

This file records the problem, the analysis that located it, and a suggested fix. It can be submitted to DSH Desktop upstream as is, or used as the body of a GitHub issue.

## Environment

- Operating system: Windows 11
- DSH Desktop installation path: `D:\deepseek\DSH Desktop`
- Packages involved: `@deepseek-ai/dsh-subprocess-local`, `@deepseek-ai/dsh-win32-process`
- DSH Desktop 0.2.5 (`DSH Desktop.exe` file version); bundled server `@dsh/server` 0.2.5
- `@deepseek-ai/dsh-subprocess-local` and `@deepseek-ai/dsh-win32-process` 0.1.5-rc.1
- `@openai/codex` 0.147.0- Permission presets: reproduces under both `workspace-write` and `danger-full-access`

## Steps to reproduce

1. In DSH Desktop, have the agent execute any command.
2. Watch the desktop. A console window appears for each invocation and closes when the command ends.

With Windows Terminal set as the default terminal application, the window is a full Windows Terminal window that appears after about a second; with Windows Console Host, it is a classic console window.

## Expected result

The command runs in the background without producing a visible window.

## Actual result

Every command invocation opens a visible console window.

## Analysis

Windows allocates a new console window for a console child process unless the creator passes `CREATE_NO_WINDOW` (`0x08000000`). One command involves two process creations:

```
DSH Desktop (server) → DSH Desktop (runner.js) → powershell.exe → conhost.exe
```

The process created at the second level owns the window. Process state before the fix:

```
GetConsoleWindow()  = valid handle (462730)
window class        = ConsoleWindowClass
IsWindowVisible     = True
WS_VISIBLE          = True
window size         = 992 x 837
stdin/stdout/stderr = pipes
```

The standard streams being pipes rules out a pseudo-terminal (ConPTY) path, which confirms that the window comes from an ordinary console allocation.

Two sites omit the flag:

1. `@deepseek-ai/dsh-subprocess-local/lib/index.js`, `launchWindowsJob()`:
   the spawn of the Windows Job runner passes only `cwd`, `env` and `stdio` — no `windowsHide: true`.

2. `@deepseek-ai/dsh-win32-process/lib/index.js`:
   three process-creation calls pass `dwCreationFlags` values that do not include `CREATE_NO_WINDOW`.
   - ordinary process: `CreateProcessW(..., 1, 1028, ...)`, where `1028` = `0x404` = `CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT`
   - restricted token: `CreateProcessAsUserW(..., 4, ...)`, where `4` = `CREATE_SUSPENDED`
   - inherited handles: `CreateProcessAsUserW(..., 0, ...)`

   None of these values implies a hidden console, so every command process receives a new visible console.

## Verified scope

| Site | Changed | Verified |
| --- | --- | --- |
| `dsh-win32-process` ordinary `CreateProcessW` (`dwCreationFlags` 1028) | yes | yes, under `danger-full-access`: `GetConsoleWindow()` returns 0 and no visible console window appears |
| `dsh-win32-process` restricted-token `CreateProcessAsUserW` (4) | yes | no |
| `dsh-win32-process` inherited-handle `CreateProcessAsUserW` (0) | yes | no |
| `dsh-subprocess-local` Job runner spawn | yes | no |
| five `spawn` calls under `src/engine/` | yes | no |

- The two restricted-token sites serve the `read-only` and `workspace-write` presets; nothing was verified under those presets.
- The five `src/engine/` sites were not exercised. The test machine has no git installed, so the git-related paths never ran.
- No regression testing was done for background jobs, the integrated terminal (a separate pseudo-terminal path), plugin installation, or the packaged office tools. Removing the console from a child process can change the behaviour of commands that read console properties, such as `chcp` or `[Console]::WindowWidth`.
- One observation remains unexplained: the owning thread of the visible console window was attributed to the command process rather than to conhost. The report states what was measured; the ownership model was not investigated further.
## Suggested fix

```diff
--- a/node_modules/@deepseek-ai/dsh-win32-process/lib/index.js
+++ b/node_modules/@deepseek-ai/dsh-win32-process/lib/index.js
@@ ordinary process
-  api.createProcessW(options.applicationName, commandLine, null, null, 1, 1028, environment, options.cwd, startupInfo, processInfo)
+  api.createProcessW(options.applicationName, commandLine, null, null, 1, 1028 | 0x08000000, environment, options.cwd, startupInfo, processInfo)
@@ restricted token
-  createRestrictedProcess(api, options, commandLine, 4, startupInfo, processInfo)
+  createRestrictedProcess(api, options, commandLine, 4 | 0x08000000, startupInfo, processInfo)
@@ inherited handles
-  createRestrictedProcess(api, options, buildCommandLine(options.command, options.args), 0, startupInfo, processInfo)
+  createRestrictedProcess(api, options, buildCommandLine(options.command, options.args), 0x08000000, startupInfo, processInfo)
```

```diff
--- a/node_modules/@deepseek-ai/dsh-subprocess-local/lib/index.js
+++ b/node_modules/@deepseek-ai/dsh-subprocess-local/lib/index.js
@@ launchWindowsJob()
   child = (internals.spawn ?? spawn)(command, [...prefix, "--", ...spec.argv], {
       cwd: process.cwd(),
       env: runnerEnvironment(WINDOWS_RUNNER_SELECTION, invocation),
+      windowsHide: true,
       stdio: runnerStdio(spec, true, ignoredStdinFd ?? "pipe")
   });
```

After these changes and a restart, the command process reports `GetConsoleWindow() = 0` and no window appears on the desktop.

## Other affected sites

Several spawn calls under `resources/server/src/engine/` also omit `windowsHide` and open console windows the same way:

- `agents/workspace_turn_snapshot.js` (per-turn git snapshot)
- `agents/workspace_change_provider.js` (change-list refresh)
- `agents/git_workspace.js` (worktree operations)
- `agent_kernel/app_server_client.js` (codex app-server start)
- `dsh_runtime/client.js` (runtime child process)

`dsh-better-sidebar` fixed the equivalent problem in its own `runGit()` in 0.19.0 (PR #301, issue #124); the same treatment applies here.

## References

- openai/codex issue 18984 — Windows: hide command-safety PowerShell parser process to avoid pwsh.exe console flashes
  <https://github.com/openai/codex/issues/18984>
- openai/codex issue 44768 — Windows: app-server daemon opens a visible console window for every hook and shell command it runs
  <https://github.com/openai/codex/issues/44768>
- anthropics/claude-code issue 78189 — Windows: detached background pty hosts cause visible pwsh/console window flashes at session start
  <https://github.com/anthropics/claude-code/issues/78189>
