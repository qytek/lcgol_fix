<#
.SYNOPSIS
    Manual workaround: limits steam.exe (and therefore every game Steam launches)
    to a number of logical CPUs.

.DESCRIPTION
    Steam spawns game processes that inherit Steam's CPU affinity. Restricting
    Steam is the quickest way to test/fix the "more than 31 logical processors"
    crash of Lara Croft and the Guardian of Light without installing anything.

    The setting lasts until Steam is restarted and applies to all Steam games
    (they lose 2 of 32 threads, which is irrelevant in practice).

.PARAMETER Cpus
    Number of logical CPUs Steam may use (1..31). Default 30.

.PARAMETER Mask
    Explicit affinity mask (e.g. 0x3FFFFFFF) instead of -Cpus.

.PARAMETER Restore
    Reset Steam to all available CPUs.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Set-SteamAffinity.ps1 -Cpus 30

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Set-SteamAffinity.ps1 -Restore
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 63)][int]$Cpus = 30,
    [string]$Mask,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
$steam = Get-Process steam -ErrorAction SilentlyContinue
if (-not $steam) { throw 'steam.exe is not running.' }

if ($Restore) {
    $target = [int64]0xFFFFFFFF
    foreach ($p in $steam) {
        $p.ProcessorAffinity = [IntPtr]$target
        Write-Host ("steam pid {0}: affinity 0x{1:X} (all CPUs)" -f $p.Id, [int64]$p.ProcessorAffinity)
    }
    return
}

if ($Mask) {
    $target = [int64][Convert]::ToInt64($Mask -replace '^0x', '', 'IgnoreCase')
} else {
    if ($Cpus -ge 32) { throw '-Cpus must be 1..31; 32+ is exactly what the game cannot handle.' }
    $target = [int64]((1L -shl $Cpus) - 1L)
}

foreach ($p in $steam) {
    $before = [int64]$p.ProcessorAffinity
    $p.ProcessorAffinity = [IntPtr]$target
    Write-Host ("steam pid {0}: affinity 0x{1:X} -> 0x{2:X} ({3} CPUs)" -f `
        $p.Id, $before, [int64]$p.ProcessorAffinity, $Cpus)
}

Write-Host ''
Write-Host 'Now launch the game from Steam. Use -Restore to undo.' -ForegroundColor Green
