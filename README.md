# DSH Desktop Windows 控制台窗口修复

Windows 上使用 DSH Desktop 时，每次命令执行都会打开一个控制台窗口。本仓库提供一个补丁脚本，用于修改本机已安装的 DSH Desktop，消除该行为。

仓库不包含也不重新分发 DSH Desktop 的任何代码。脚本会就地修改已安装的文件，是否采用请自行判断；同时建议向官方反馈，报告文本见 [BUG-REPORT.md](BUG-REPORT.md)。

## 症状

每次命令调用（pwsh 工具）都会在桌面上打开一个控制台窗口。当 Windows 11 的“默认终端应用程序”为 Windows Terminal 时，该窗口表现为一个完整的 Windows Terminal 应用窗口，出现耗时约一秒；当其为“Windows 控制台主机”时，表现为经典控制台窗口。两种情况下的窗口都会在命令结束时关闭。

## 原因

Windows 为控制台子进程分配新的控制台窗口，除非创建进程时传入 `CREATE_NO_WINDOW`（`0x08000000`）。DSH Desktop 的命令执行链有两处未传入该标志。

执行一条命令涉及两级进程创建：

```
DSH runtime → Windows Job runner → powershell.exe
```

1. 启动 Job runner 的 spawn 调用未设置 `windowsHide`。
   位置：`@deepseek-ai/dsh-subprocess-local/lib/index.js`，`launchWindowsJob()`。

2. runner 创建实际命令进程时，`dwCreationFlags` 不含 `CREATE_NO_WINDOW`。
   位置：`@deepseek-ai/dsh-win32-process/lib/index.js`。该文件有三处创建调用，标志值分别为 `1028`（`CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT`）、`4`（`CREATE_SUSPENDED`）和 `0`。

可见窗口由第二处产生，它属于命令进程自身。修复前的进程状态可以印证：

```
GetConsoleWindow()  = 有效句柄 (462730)
窗口类              = ConsoleWindowClass
IsWindowVisible     = True
窗口尺寸            = 992 × 837
stdin/stdout/stderr = 均为管道（非 ConPTY 伪终端）
进程链              = DSH Desktop(server) → DSH Desktop(runner.js) → powershell.exe → conhost.exe
```

三个标准流都是管道，说明命令并非运行在伪终端中，窗口来自常规的控制台分配。

## 补丁内容

| 文件 | 位置 | 改动 |
| --- | --- | --- |
| `node_modules/@deepseek-ai/dsh-win32-process/lib/index.js` | 普通进程 `CreateProcessW` 的 `dwCreationFlags` | `1028` → `1028 \| 0x08000000` |
| 同上 | 受限令牌 `CreateProcessAsUserW` | `4` → `4 \| 0x08000000` |
| 同上 | 继承句柄 `CreateProcessAsUserW` | `0` → `0x08000000` |
| `node_modules/@deepseek-ai/dsh-subprocess-local/lib/index.js` | `launchWindowsJob()` 的 spawn 选项 | 增加 `windowsHide: true` |
| `src/engine/agents/workspace_turn_snapshot.js` | 每轮对话的 git 快照 | 增加 `windowsHide: true` |
| `src/engine/agents/workspace_change_provider.js` | 改动列表刷新 | 增加 `windowsHide: true` |
| `src/engine/agents/git_workspace.js` | worktree 操作 | 增加 `windowsHide: true` |
| `src/engine/agent_kernel/app_server_client.js` | codex app-server 启动 | 增加 `windowsHide: true` |
| `src/engine/dsh_runtime/client.js` | 运行时子进程 | 增加 `windowsHide: true` |

前三行对应上述原因；其余为同类问题，这些 spawn 调用同样会打开控制台窗口，其中 git 相关三处每轮对话都会触发。

## 使用

1. 完全退出 DSH Desktop（包括托盘图标）。
2. 以管理员身份打开 PowerShell：

```powershell
powershell -ExecutionPolicy Bypass -File .\fix-dsh-console-flash.ps1
```

脚本会自动定位安装目录，也可以用 `-Root` 指定 `resources\server` 的路径。修改前为每个文件生成 `*.dshbak-<时间戳>` 备份，可重复执行（已修补的位置会跳过）；锚点与当前版本不匹配时会明确报告，不会继续修改。

3. 重启 DSH Desktop。Node 模块在进程启动时加载，不重启不会生效。

## 验证

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-ConsoleFlash.ps1
```

脚本记录执行前后可见的控制台窗口，并运行一个主动请求新控制台的对照进程，最后给出结论。修复后的输出：

```
GetConsoleWindow() = 0
RESULT: PASS - no new visible console window appeared.
```

## 回滚

```powershell
powershell -ExecutionPolicy Bypass -File .\fix-dsh-console-flash.ps1 -Revert
```

从最近一次备份恢复被修改的文件。

## 维护说明

DSH Desktop 升级或重装会覆盖这些文件，补丁随之失效，需要重新执行脚本。

脚本文件只使用 ASCII 字符。Windows PowerShell 5.1 读取不带 BOM 的 `.ps1` 时按系统 ANSI 代码页解码，非 ASCII 注释会被解码为乱码，其中某些字节还会破坏语法分析。

把系统“默认终端应用程序”从 Windows Terminal 改为“Windows 控制台主机”只改变窗口的呈现形式，不会消除窗口。

## English

DSH Desktop opens a console window for every command it runs on Windows. This repository contains a patch script for an existing local installation; it does not redistribute any DSH Desktop code.

The cause is two process-creation sites that omit `CREATE_NO_WINDOW` (`0x08000000`): the spawn of the Windows Job runner in `@deepseek-ai/dsh-subprocess-local`, and the `dwCreationFlags` values (`1028`, `4`, `0`) used by `@deepseek-ai/dsh-win32-process`. The script adds the flag and the equivalent `windowsHide` option, keeps timestamped backups, and can be reverted with `-Revert`. Run it as Administrator and restart DSH Desktop afterwards; application updates overwrite the patched files.

The scripts are ASCII-only because Windows PowerShell 5.1 decodes BOM-less `.ps1` files using the system ANSI code page.

## 参考

- openai/codex issue 18984 — Windows: hide command-safety PowerShell parser process to avoid pwsh.exe console flashes
  <https://github.com/openai/codex/issues/18984>
- openai/codex issue 44768 — Windows: app-server daemon opens a visible console window for every hook and shell command it runs
  <https://github.com/openai/codex/issues/44768>
- anthropics/claude-code issue 78189 — Windows: detached background pty hosts cause visible pwsh/console window flashes at session start
  <https://github.com/anthropics/claude-code/issues/78189>
- Node.js `child_process` 文档，`windowsHide` 选项
  <https://nodejs.org/api/child_process.html>

## License

MIT
