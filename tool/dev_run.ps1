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

$dataDir = $env:TREE_DATA_ROOT
if ([string]::IsNullOrWhiteSpace($dataDir)) {
    $dataDir = Join-Path $env:USERPROFILE '.tree'
}

Write-Host "[dev] 启动核心，数据根：$dataDir"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'dart'
$psi.Arguments = "run packages/tree_core_cli/bin/tree_core.dart --data-dir `"$dataDir`""
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.WorkingDirectory = $repoRoot

$core = [System.Diagnostics.Process]::Start($psi)
if ($null -eq $core) {
    throw '[dev] 无法启动核心进程'
}

# 核心把人类可读日志写在 stderr，这里原样转出来（前缀区分启动器）。
$core.add_ErrorDataReceived({
    param($sender, $e)
    if ($null -ne $e.Data) { Write-Host "[core] $($e.Data)" }
})
$core.BeginErrorReadLine()

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
    Write-Host '[dev] 启动 UI（flutter run）...'

    & flutter run -d windows `
        "--dart-define=TREE_CORE_URL=$coreUrl" `
        "--dart-define=TREE_CORE_TOKEN=$($ready.token)"
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
