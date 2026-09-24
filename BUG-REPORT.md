# 缺陷报告：Windows 下每条命令都会打开控制台窗口

本文件记录该问题的完整定位过程与建议修复，可直接提交给 DSH Desktop 官方，或作为 GitHub issue 的内容。

## 环境

- 操作系统：Windows 11
- DSH Desktop 安装路径：`D:\deepseek\DSH Desktop`
- 涉及包：`@deepseek-ai/dsh-subprocess-local`、`@deepseek-ai/dsh-win32-process`
- 权限预设：`workspace-write` 与 `danger-full-access` 均可复现

## 复现步骤

1. 在 DSH Desktop 中让智能体执行任意一条命令。
2. 观察桌面。每次调用都会出现一个控制台窗口，窗口随命令结束而关闭。

若系统的“默认终端应用程序”为 Windows Terminal，窗口表现为完整的 Windows Terminal 应用窗口（约一秒后出现）；若为“Windows 控制台主机”，表现为经典控制台窗口。

## 预期结果

命令在后台执行，不产生可见窗口。

## 实际结果

每次命令调用打开一个可见控制台窗口。

## 技术分析

Windows 为控制台子进程分配新的控制台窗口，除非创建进程时传入 `CREATE_NO_WINDOW`（`0x08000000`）。执行一条命令涉及两级进程创建：

```
DSH Desktop (server) → DSH Desktop (runner.js) → powershell.exe → conhost.exe
```

第二级创建的命令进程自身持有该窗口。修复前的进程状态：

```
GetConsoleWindow()  = 有效句柄 (462730)
窗口类              = ConsoleWindowClass
IsWindowVisible     = True
WS_VISIBLE          = True
窗口尺寸            = 992 × 837
stdin/stdout/stderr = 均为管道
```

标准流为管道排除了伪终端（ConPTY）路径，可以确认窗口来自常规控制台分配。

两处遗漏：

1. `@deepseek-ai/dsh-subprocess-local/lib/index.js`，`launchWindowsJob()`：
   启动 Windows Job runner 的 `spawn(...)` 只传了 `cwd`、`env`、`stdio`，没有 `windowsHide: true`。

2. `@deepseek-ai/dsh-win32-process/lib/index.js`：
   三处进程创建调用的 `dwCreationFlags` 均不含 `CREATE_NO_WINDOW`。
   - 普通进程：`CreateProcessW(..., 1, 1028, ...)`，`1028` = `0x404` = `CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT`
   - 受限令牌：`CreateProcessAsUserW(..., 4, ...)`，`4` = `CREATE_SUSPENDED`
   - 继承句柄：`CreateProcessAsUserW(..., 0, ...)`

   这三个取值都不隐含隐藏控制台，因此每个命令进程都会获得一个新的可见控制台。

## 建议修复

```diff
--- a/node_modules/@deepseek-ai/dsh-win32-process/lib/index.js
+++ b/node_modules/@deepseek-ai/dsh-win32-process/lib/index.js
@@ 普通进程
-  api.createProcessW(options.applicationName, commandLine, null, null, 1, 1028, environment, options.cwd, startupInfo, processInfo)
+  api.createProcessW(options.applicationName, commandLine, null, null, 1, 1028 | 0x08000000, environment, options.cwd, startupInfo, processInfo)
@@ 受限令牌
-  createRestrictedProcess(api, options, commandLine, 4, startupInfo, processInfo)
+  createRestrictedProcess(api, options, commandLine, 4 | 0x08000000, startupInfo, processInfo)
@@ 继承句柄
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

应用以上改动并重启后，命令进程的 `GetConsoleWindow()` 返回 `0`，桌面不再出现窗口。

## 其他同类位置

`resources/server/src/engine/` 下还有若干 spawn 调用未设置 `windowsHide`，同样会打开控制台窗口：

- `agents/workspace_turn_snapshot.js`（每轮对话的 git 快照）
- `agents/workspace_change_provider.js`（改动列表刷新）
- `agents/git_workspace.js`（worktree 操作）
- `agent_kernel/app_server_client.js`（codex app-server 启动）
- `dsh_runtime/client.js`（运行时子进程）

`dsh-better-sidebar` 在 0.19.0 已修复过同类问题（PR #301，对应 issue #124），可以对这批位置做相同处理。

## 参考

- openai/codex issue 18984：Windows 上为命令安全解析进程隐藏窗口以消除 pwsh.exe 闪烁
  <https://github.com/openai/codex/issues/18984>
- openai/codex issue 44768：app-server 守护进程为每条命令打开可见控制台窗口
  <https://github.com/openai/codex/issues/44768>
- anthropics/claude-code issue 78189：分离式后台 pty 宿主导致会话启动时控制台窗口闪烁
  <https://github.com/anthropics/claude-code/issues/78189>

---

## English

**Every command opens a console window on Windows (`dwCreationFlags` lacks `CREATE_NO_WINDOW`)**

Environment: Windows 11, DSH Desktop at `D:\deepseek\DSH Desktop`; reproduces under both
`workspace-write` and `danger-full-access`.

Each command invocation opens a visible console window that closes when the command
finishes. The window belongs to the command process itself: before the fix,
`GetConsoleWindow()` returned a valid handle (`ConsoleWindowClass`, `IsWindowVisible`
true, 992 × 837) while all three standard streams were pipes, which rules out the ConPTY
path.

Two process-creation sites omit the flag:

1. `@deepseek-ai/dsh-subprocess-local/lib/index.js`, `launchWindowsJob()`: the Windows Job
   runner is spawned with `cwd`, `env` and `stdio` only — no `windowsHide: true`.
2. `@deepseek-ai/dsh-win32-process/lib/index.js`: three creation calls pass
   `dwCreationFlags` values `1028` (`CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT`),
   `4` (`CREATE_SUSPENDED`) and `0`. None of them implies a hidden console.

Fix: OR `0x08000000` into those three flag words and add `windowsHide: true` to the runner
spawn. After applying and restarting, `GetConsoleWindow()` returns `0`.

Several un-hidden `spawn` calls under `src/engine/` (git snapshot, change-list refresh,
worktree operations, codex app-server, runtime child process) have the same problem;
`dsh-better-sidebar` 0.19.0 fixed the equivalent issue in its own `runGit()` (PR #301,
issue #124).
