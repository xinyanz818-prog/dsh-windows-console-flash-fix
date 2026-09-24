# Test-ConsoleFlash.ps1
#
# Verifies whether running commands creates NEW visible console windows.
# Repository: https://github.com/xinyanz818-prog/dsh-windows-console-flash-fix
#
# This file is ASCII-only by design: Windows PowerShell 5.1 decodes BOM-less .ps1
# files using the system ANSI code page.
#
# Usage:
#     powershell -ExecutionPolicy Bypass -File .\Test-ConsoleFlash.ps1
#     powershell -ExecutionPolicy Bypass -File .\Test-ConsoleFlash.ps1 -HoldSeconds 10
#
# Behaviour:
#   1. prints this host process's own console window state
#      (after the fix this should be "no console window", when the host is DSH Desktop)
#   2. snapshots all visible console windows
#   3. runs console child processes, including a control group that explicitly asks
#      Windows for a NEW console (CreateNoWindow=false), sampling every 100 ms
#   4. reports PASS when no new visible console window appeared

param(
  [int]$HoldSeconds = 6
)

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class ConsoleWatch {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static long OwnConsole() { return GetConsoleWindow().ToInt64(); }
  public static string OwnConsoleInfo() {
    IntPtr h = GetConsoleWindow();
    if (h == IntPtr.Zero) return "no console window at all (GetConsoleWindow() = 0)";
    var c = new StringBuilder(256); GetClassName(h, c, 256);
    RECT r; GetWindowRect(h, out r);
    return string.Format("hwnd={0} class={1} visible={2} {3}x{4}", h, c, IsWindowVisible(h), r.R - r.L, r.B - r.T);
  }
  public static string VisibleConsoles() {
    var sb = new StringBuilder();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      var c = new StringBuilder(256); GetClassName(h, c, 256);
      if (c.ToString() != "ConsoleWindowClass") return true;
      if (!IsWindowVisible(h)) return true;
      RECT r; GetWindowRect(h, out r);
      if (r.R - r.L <= 20 || r.B - r.T <= 20) return true;
      var t = new StringBuilder(512); GetWindowText(h, t, 512);
      uint pid; GetWindowThreadProcessId(h, out pid);
      sb.AppendLine(string.Format("{0} | pid={1} | {2}x{3} | {4}", h, pid, r.R - r.L, r.B - r.T, t));
      return true;
    }, IntPtr.Zero);
    return sb.ToString();
  }
}
'@

function Get-Lines([string]$text) {
  if (-not $text) { return @() }
  return @($text -split "`n" | Where-Object { $_.Trim() -ne '' })
}

Write-Host '=== console flash test ===' -ForegroundColor Cyan
Write-Host ''
Write-Host '1) this host process'
Write-Host ('   ' + [ConsoleWatch]::OwnConsoleInfo())
$own = [ConsoleWatch]::OwnConsole()

$before = Get-Lines ([ConsoleWatch]::VisibleConsoles())
Write-Host ''
Write-Host "2) visible console windows before: $($before.Count)"
$before | ForEach-Object { Write-Host "   $_" }

Write-Host ''
Write-Host '3) running console child processes...'
$tmp = Join-Path $env:TEMP 'dsh-flash-test.txt'
& "$env:SystemRoot\System32\cmd.exe" /c "echo child-ok > `"$tmp`""
$echoed = Get-Content -LiteralPath $tmp -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
Write-Host "   cmd /c echo -> $echoed"

Write-Host '   control group: CreateNoWindow = false (asks for a new console), ~2s, sampled every 100ms'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "$env:SystemRoot\System32\cmd.exe"
$psi.Arguments = '/c ping -n 3 127.0.0.1 >nul'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $false
$proc = [System.Diagnostics.Process]::Start($psi)
$new = @{}
while (-not $proc.HasExited) {
  foreach ($line in (Get-Lines ([ConsoleWatch]::VisibleConsoles()))) {
    if ($before -notcontains $line) { $new[$line] = $true }
  }
  Start-Sleep -Milliseconds 100
}

Write-Host ''
Write-Host "4) holding $HoldSeconds second(s) - watch the screen now"
Start-Sleep -Seconds $HoldSeconds

foreach ($line in (Get-Lines ([ConsoleWatch]::VisibleConsoles()))) {
  if ($before -notcontains $line) { $new[$line] = $true }
}

Write-Host ''
if ($new.Count -gt 0) {
  Write-Host 'RESULT: FAIL - new visible console window(s) appeared:' -ForegroundColor Red
  $new.Keys | ForEach-Object { Write-Host "   $_" }
  exit 1
}
Write-Host 'RESULT: PASS - no new visible console window appeared.' -ForegroundColor Green
if ($own -ne 0) {
  Write-Host 'NOTE: this host itself owns a console window (expected when you run this from a terminal).' -ForegroundColor DarkGray
  Write-Host '      The verdict above concerns NEW windows created while commands run.' -ForegroundColor DarkGray
}
exit 0
