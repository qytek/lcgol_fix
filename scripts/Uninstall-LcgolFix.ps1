<#
.SYNOPSIS
    Removes the CPU-affinity guard installed by Install-LcgolFix.ps1.

.DESCRIPTION
    Stops the guard, deletes the Startup-folder shortcut and removes
    %LOCALAPPDATA%\LcgolFix. The game itself is not touched, so after removal the
    crash comes back on machines with 32+ logical processors.

.PARAMETER KeepLogs
    Keep guard.log (and the folder) instead of deleting it.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Uninstall-LcgolFix.ps1
#>
[CmdletBinding()]
param(
    [switch]$KeepLogs
)

$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:LOCALAPPDATA 'LcgolFix'
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Lcgol Affinity Guard.lnk'

Write-Host '=== LcgolFix uninstaller ===' -ForegroundColor Cyan

$running = Get-Process LcgolAffinityGuard -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "stopping guard (pid $($running.Id))..."
    $running | Stop-Process -Force
    Start-Sleep -Milliseconds 500
} else {
    Write-Host 'guard was not running'
}

if (Test-Path $startupLnk) {
    Remove-Item $startupLnk -Force
    Write-Host "removed startup shortcut"
} else {
    Write-Host 'no startup shortcut found'
}

if (Test-Path $installDir) {
    if ($KeepLogs) {
        Get-ChildItem $installDir -File | Where-Object { $_.Name -ne 'guard.log' } | Remove-Item -Force
        Write-Host "kept $installDir\guard.log"
    } else {
        Remove-Item $installDir -Recurse -Force
        Write-Host "removed $installDir"
    }
}

Write-Host ''
Write-Host 'Uninstalled. Note: on a 32+ logical-CPU machine the game will crash at launch again.' -ForegroundColor Yellow
