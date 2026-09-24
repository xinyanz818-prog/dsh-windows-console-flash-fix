# fix-dsh-console-flash.ps1
#
# Applies a local patch to an installed DSH Desktop so that command execution no
# longer opens console windows on Windows.
# Repository: https://github.com/xinyanz818-prog/dsh-windows-console-flash-fix
#
# This file is ASCII-only by design. Windows PowerShell 5.1 reads a BOM-less .ps1
# using the system ANSI code page, so non-ASCII comments would be decoded
# incorrectly and could break parsing.
#
# Cause: Windows gives a console child process a new, visible console window
# unless the creator passes CREATE_NO_WINDOW (0x08000000). One command involves
# two process creations:
#
#     DSH runtime --spawn--> Windows Job runner --CreateProcessW--> powershell.exe
#
# Neither level passes the flag:
#     - the Job runner spawn has no windowsHide: true
#     - the CreateProcessW / CreateProcessAsUserW calls pass dwCreationFlags
#       1028 (CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT), 4, or 0, none of
#       which implies a hidden console
#
# Usage (must run as Administrator; the install directory is ACL-protected):
#     powershell -ExecutionPolicy Bypass -File .\fix-dsh-console-flash.ps1
#     powershell -ExecutionPolicy Bypass -File .\fix-dsh-console-flash.ps1 -Root "D:\path\to\DSH Desktop\resources\server"
#
# Revert:
#     powershell -ExecutionPolicy Bypass -File .\fix-dsh-console-flash.ps1 -Revert
#
# DSH Desktop must be restarted afterwards; Node modules load at process start.
# The script is idempotent and backs up each modified file to *.dshbak-<stamp>.
# Application updates overwrite the patched files, so re-run the script after one.

param(
  [switch]$Revert,
  [string]$Root = ''
)

$ErrorActionPreference = 'Stop'

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $ok = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $ok) {
    Write-Host 'ERROR: run this script as Administrator (the install dir is ACL-protected).' -ForegroundColor Red
    exit 1
  }
}

function Find-ServerRoot {
  # 1) from a running DSH Desktop process
  $proc = Get-Process -Name 'DSH Desktop' -ErrorAction SilentlyContinue |
          Where-Object { $_.Path } | Select-Object -First 1
  if ($proc) {
    $candidate = Join-Path (Split-Path $proc.Path -Parent) 'resources\server'
    if (Test-Path $candidate) { return $candidate }
  }
  # 2) common install roots
  $bases = @()
  foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
    if ($drive.Root) { $bases += $drive.Root }
  }
  $rels = @(
    'deepseek\DSH Desktop\resources\server',
    'Program Files\DSH Desktop\resources\server',
    'Program Files (x86)\DSH Desktop\resources\server',
    'DSH Desktop\resources\server'
  )
  foreach ($b in $bases) {
    foreach ($rel in $rels) {
      $candidate = Join-Path $b $rel
      if (Test-Path $candidate) { return $candidate }
    }
  }
  return $null
}

Assert-Admin

if (-not $Root -or $Root.Trim() -eq '') {
  $Root = Find-ServerRoot
  if (-not $Root) {
    Write-Host 'ERROR: could not locate the DSH Desktop server directory.' -ForegroundColor Red
    Write-Host 'Pass it explicitly, e.g.:' -ForegroundColor Yellow
    Write-Host '  -Root "D:\deepseek\DSH Desktop\resources\server"' -ForegroundColor Yellow
    exit 1
  }
  Write-Host "auto-detected server root: $Root" -ForegroundColor Cyan
}
if (-not (Test-Path $Root)) { Write-Host "ERROR: directory not found: $Root" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- operations
# 1) INSERT "windowsHide: true," right after an anchor (Node spawn options).
$insertTargets = @(
  @{ File = 'node_modules\@deepseek-ai\dsh-subprocess-local\lib\index.js'
     Pattern = 'env: runnerEnvironment\(WINDOWS_RUNNER_SELECTION, invocation\),'
     Note    = 'Windows Job runner spawn (Node)' }
  @{ File = 'src\engine\agents\workspace_turn_snapshot.js'
     Pattern = 'spawn\(command, args, \{'
     Note    = 'git snapshot per turn' }
  @{ File = 'src\engine\agents\workspace_change_provider.js'
     Pattern = 'spawn\("git", args, \{'
     Note    = 'change-list refresh' }
  @{ File = 'src\engine\agents\git_workspace.js'
     Pattern = 'spawn\("git", args, \{'
     Note    = 'worktree operations' }
  @{ File = 'src\engine\agent_kernel\app_server_client.js'
     Pattern = 'this\.spawnFn\(this\.binary, this\.args, \{'
     Note    = 'codex app-server' }
  @{ File = 'src\engine\dsh_runtime\client.js'
     Pattern = 'this\.spawn\(launchPath, launchArgs, \{'
     Note    = 'DSH runtime fork' }
)

# 2) REPLACE literal text (Win32 creation flags: add CREATE_NO_WINDOW).
$W32 = 'node_modules\@deepseek-ai\dsh-win32-process\lib\index.js'
$replaceTargets = @(
  @{ File = $W32
     Find = '1, 1028, environment'
     Repl = '1, 1028 | 0x08000000, environment'
     Note = 'CreateProcessW (ordinary): 0x404 -> 0x08000404' }
  @{ File = $W32
     Find = 'commandLine, 4, startupInfo, processInfo'
     Repl = 'commandLine, 4 | 0x08000000, startupInfo, processInfo'
     Note = 'CreateProcessAsUserW (restricted token): 0x4 -> 0x08000004' }
  @{ File = $W32
     Find = 'options.args), 0, startupInfo, processInfo'
     Repl = 'options.args), 0x08000000, startupInfo, processInfo'
     Note = 'CreateProcessAsUserW (inherited handles): 0x0 -> 0x08000000' }
)

# ------------------------------------------------------------------- helpers
$utf8  = New-Object System.Text.UTF8Encoding($false)
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:backedUp = @{}
$touched = 0

function Backup-Once([string]$path) {
  if ($script:backedUp.ContainsKey($path)) { return }
  Copy-Item -LiteralPath $path -Destination "$path.dshbak-$stamp" -Force
  $script:backedUp[$path] = $true
}

function Get-LatestBackup([string]$path) {
  return Get-ChildItem "$path.dshbak-*" -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Save-Text([string]$path, [string]$text) {
  Backup-Once $path
  [IO.File]::WriteAllText($path, $text, $utf8)
}

# ---------------------------------------------------------------------- main
if ($Revert) {
  $files = @($insertTargets.File) + @($replaceTargets.File) | Select-Object -Unique
  foreach ($rel in $files) {
    $path = Join-Path $Root $rel
    if (-not (Test-Path $path)) { Write-Host "SKIP (missing): $rel" -ForegroundColor Yellow; continue }
    $bak = Get-LatestBackup $path
    if (-not $bak) { Write-Host "SKIP (no backup): $rel" -ForegroundColor Yellow; continue }
    Copy-Item -LiteralPath $bak.FullName -Destination $path -Force
    Write-Host "REVERTED: $rel   <- $($bak.Name)" -ForegroundColor Green
    $touched++
  }
  Write-Host ''
  Write-Host "Revert done ($touched file(s)). Restart DSH Desktop." -ForegroundColor Cyan
  exit 0
}

# --- 1) inserts ---
foreach ($t in $insertTargets) {
  $path = Join-Path $Root $t.File
  if (-not (Test-Path $path)) { Write-Host "SKIP (missing file): $($t.File)" -ForegroundColor Yellow; continue }
  $text = [IO.File]::ReadAllText($path)
  $nl   = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
  $hits = [regex]::Matches($text, $t.Pattern)
  if ($hits.Count -eq 0) { Write-Host "NO MATCH: $($t.File)" -ForegroundColor Yellow; continue }
  $changed = $false
  for ($i = $hits.Count - 1; $i -ge 0; $i--) {
    $m = $hits[$i]
    $tail = $text.Substring($m.Index, [Math]::Min(500, $text.Length - $m.Index))
    if ($tail -match 'windowsHide') { continue }
    $text = $text.Remove($m.Index, $m.Value.Length).Insert($m.Index, $m.Value + $nl + '      windowsHide: true,')
    $changed = $true
  }
  if (-not $changed) { Write-Host "OK (already hidden): $($t.File)" -ForegroundColor DarkGray; continue }
  Save-Text $path $text
  Write-Host "PATCHED (insert): $($t.File)   [$($t.Note)]" -ForegroundColor Green
  $touched++
}

# --- 2) literal replacements ---
foreach ($t in $replaceTargets) {
  $path = Join-Path $Root $t.File
  if (-not (Test-Path $path)) { Write-Host "SKIP (missing file): $($t.File)" -ForegroundColor Yellow; continue }
  $text = [IO.File]::ReadAllText($path)
  if ($text.Contains($t.Repl)) { Write-Host "OK (already patched): $($t.Note)" -ForegroundColor DarkGray; continue }
  if (-not $text.Contains($t.Find)) { Write-Host "NO MATCH: $($t.Note)   find='$($t.Find)'" -ForegroundColor Yellow; continue }
  $count = ([regex]::Matches($text, [regex]::Escape($t.Find))).Count
  $text = $text.Replace($t.Find, $t.Repl)
  Save-Text $path $text
  Write-Host "PATCHED (flags): $($t.Note)   [$count occurrence(s)]" -ForegroundColor Green
  $touched++
}

Write-Host ''
Write-Host "Done ($touched change(s))." -ForegroundColor Cyan
Write-Host 'NOW RESTART DSH Desktop - Node modules load only at startup.' -ForegroundColor Yellow
