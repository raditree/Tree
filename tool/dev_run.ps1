# 开发期附着运行：先起核心，再把握手信息以 --dart-define 交给 UI 进程。
#
# UI 已是 runtime: ui 插件，不再自己拉起核心（U1）。日常开发用这个脚本：
#   1. 用 dart run 起核心（控制台里可以直接看到核心日志）；
#   2. 等核心在 stdout 打出 ready 握手行；
#   3. 把 URL / token / 数据根注入给 `flutter run`；
#   4. UI 退出后向核心 stdin 写 shutdown，超时再杀。
#
# 需要插件身份时（U3 的 ui.hello）：把 tree_ui.exe 与 plugin.json 放进插件目录、
# 由核心拉起即可；本脚本只覆盖「连得上」的开发回路。

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot   # tool/ -> 仓库根
Set-Location $repoRoot

# `dart` 在 Windows 上常常解析到 Flutter 的 dart.bat（本机 PATH 就是这样）。
# Process.Start 不能直接执行 .bat，所以这里：
#   1) 允许用 TREE_DART_EXE 显式指定；
#   2) 否则取 Get-Command dart 的路径，若是 .bat/.cmd，优先用同 SDK 里的 dart.exe
#      （flutter/bin/cache/dart-sdk/bin/dart.exe），找不到才退回 cmd /c 包装。
$dartExe = $env:TREE_DART_EXE
if ([string]::IsNullOrWhiteSpace($dartExe)) {
    $dartCmd = Get-Command dart -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $dartCmd) {
        throw '[dev] 找不到 dart：把 Flutter/Dart 的 bin 放进 PATH，或设 TREE_DART_EXE'
    }
    $dartExe = $dartCmd.Path
}
$useCmdWrapper = $dartExe -match '\.(bat|cmd)$'
if ($useCmdWrapper) {
    $candidate = Join-Path (Split-Path -Parent $dartExe) 'cache\dart-sdk\bin\dart.exe'
    if (Test-Path $candidate) {
        $dartExe = $candidate
        $useCmdWrapper = $false
    }
}

$dataDir = $env:TREE_DATA_ROOT
if ([string]::IsNullOrWhiteSpace($dataDir)) {
    $dataDir = Join-Path $env:USERPROFILE '.tree'
}

Write-Host "[dev] 启动核心，数据根：$dataDir（dart：$dartExe）"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = if ($useCmdWrapper) { 'cmd.exe' } else { $dartExe }
$coreArgs = "run packages/tree_core_cli/bin/tree_core.dart --data-dir `"$dataDir`""
$psi.Arguments = if ($useCmdWrapper) { "/c `"$dartExe`" $coreArgs" } else { $coreArgs }
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
# 核心日志走 stderr：这里**不重定向**，让它直接继承脚本的控制台。
# 不要用 add_ErrorDataReceived + scriptblock：PowerShell 的事件回调跑在 .NET 线程上，
# 没有 Runspace 会抛 PSInvalidOperationException，把脚本连同核心一起带崩
# （2026-11-08 实测：UI 一启动核心就被"杀死"，真因是这条回调）。
$psi.RedirectStandardError = $false
$psi.WorkingDirectory = $repoRoot

$core = [System.Diagnostics.Process]::Start($psi)
if ($null -eq $core) {
    throw '[dev] 无法启动核心进程'
}

try {
    $ready = $null
    while ($null -eq $ready) {
        $line = $core.StandardOutput.ReadLine()
        if ($null -eq $line) {
            throw "[dev] 核心在握手前退出（exit=$($core.ExitCode)）"
        }
        $line = $line.Trim()
        if ($line.Length -eq 0) { continue }
        try { $candidate = $line | ConvertFrom-Json } catch { continue }
        if ($candidate.event -eq 'ready') { $ready = $candidate } else { Write-Host "[core:out] $line" }
    }

    $coreUrl = "ws://$($ready.host):$($ready.port)"
    if ([string]::IsNullOrWhiteSpace($ready.data_root)) {
        $env:TREE_DATA_ROOT = $dataDir
    } else {
        $env:TREE_DATA_ROOT = $ready.data_root
    }
    $env:TREE_INSTANCE_KEY = "dev-$($ready.port)"

    Write-Host "[dev] 核心就绪：$coreUrl（pid $($ready.pid)）"
    Write-Host '[dev] 启动 UI（flutter run，工作目录 = 插件仓的 tree.ui.default）...'

    # UI 源码已迁入插件仓（桌面仓的 plugins/ 是本地挂载点）：flutter run 必须在
    # 那个目录里跑，否则读不到它的 pubspec 与 windows/。
    $uiDir = Join-Path $repoRoot 'plugins/tree.ui.default'
    if (-not (Test-Path (Join-Path $uiDir 'pubspec.yaml'))) {
        throw "[dev] 找不到 UI 工程：$uiDir（插件仓没挂到 plugins/？）"
    }
    Push-Location $uiDir
    try {
        & flutter run -d windows `
            "--dart-define=TREE_CORE_URL=$coreUrl" `
            "--dart-define=TREE_CORE_TOKEN=$($ready.token)"
    }
    finally {
        Pop-Location
    }
}
finally {
    if (-not $core.HasExited) {
        Write-Host '[dev] 请核心优雅退出（stdin shutdown）...'
        try {
            $core.StandardInput.WriteLine('shutdown')
            $core.StandardInput.Flush()
        } catch {
            Write-Host "[dev] 写 shutdown 失败：$($_.Exception.Message)"
        }
        if (-not $core.WaitForExit(3000)) {
            Write-Host '[dev] 核心未在 3s 内退出，强制结束'
            $core.Kill()
        }
    }
}
