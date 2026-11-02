<#
.SYNOPSIS
    Installs the CPU-affinity guard for Lara Croft and the Guardian of Light.

.DESCRIPTION
    Copies LcgolAffinityGuard.exe to %LOCALAPPDATA%\LcgolFix, writes its .ini
    (CPU cap + target executables), adds a Startup-folder shortcut so it runs at
    every logon, and starts it immediately.

    No administrator rights are required and no game file is modified.

.PARAMETER Cpus
    Number of logical CPUs the game may use. Default 30 (the game overflows its
    32-entry processor table at 32). Must be 1..31.

.PARAMETER Targets
    Executable names to guard, comma separated. Default 'lcgol.exe'.
    Use e.g. 'lcgol.exe,tru.exe' for Tomb Raider: Underworld as well.

.PARAMETER NoStartup
    Do not create the Startup-folder shortcut (run the guard manually only).

.PARAMETER NoStart
    Do not start the guard at the end of the installation.

.PARAMETER ForceBuild
    Recompile from src\ even if dist\LcgolAffinityGuard.exe already exists.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Install-LcgolFix.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Install-LcgolFix.ps1 -Cpus 16 -Targets 'lcgol.exe,tru.exe'
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 31)][int]$Cpus = 30,
    [string]$Targets = 'lcgol.exe',
    [switch]$NoStartup,
    [switch]$NoStart,
    [switch]$ForceBuild
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$installDir = Join-Path $env:LOCALAPPDATA 'LcgolFix'
$exe = Join-Path $installDir 'LcgolAffinityGuard.exe'
$ini = Join-Path $installDir 'LcgolAffinityGuard.ini'
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Lcgol Affinity Guard.lnk'

Write-Host '=== LcgolFix installer ===' -ForegroundColor Cyan
Write-Host "install dir : $installDir"
Write-Host "CPU cap     : $Cpus logical CPUs"
Write-Host "targets     : $Targets"

# --- 1. build if needed -------------------------------------------------------
$distExe = Join-Path $root 'dist\LcgolAffinityGuard.exe'
if ($ForceBuild -or -not (Test-Path $distExe)) {
    Write-Host 'building guard...'
    & (Join-Path $PSScriptRoot 'Build-Guard.ps1') -OutFile $distExe | Out-Host
}
if (-not (Test-Path $distExe)) { throw 'Guard executable is missing.' }

# --- 2. stop a running instance ----------------------------------------------
$running = Get-Process LcgolAffinityGuard -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "stopping running guard (pid $($running.Id))..."
    $running | Stop-Process -Force
    Start-Sleep -Milliseconds 500
}

# --- 3. deploy ---------------------------------------------------------------
if (-not (Test-Path $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }
Copy-Item -Path $distExe -Destination $exe -Force
@(
    '; LcgolAffinityGuard configuration'
    '; Cpus    = number of logical CPUs allowed (1..31; the game crashes at 32)'
    '; Targets = executable names to guard, comma separated'
    "Cpus=$Cpus"
    "Targets=$Targets"
) | Set-Content -Path $ini -Encoding ASCII

# --- 4. autostart shortcut ---------------------------------------------------
if (-not $NoStartup) {
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($startupLnk)
    $sc.TargetPath = $exe
    $sc.WorkingDirectory = $installDir
    $sc.WindowStyle = 7
    $sc.Description = 'Keeps Lara Croft and the Guardian of Light inside the CPU limit so it launches'
    $sc.Save()
    Write-Host "startup shortcut: $startupLnk"
}

# --- 5. start ----------------------------------------------------------------
if (-not $NoStart) {
    Start-Process -FilePath $exe
    Start-Sleep -Seconds 2
    $g = Get-Process LcgolAffinityGuard -ErrorAction SilentlyContinue
    if (-not $g) { throw 'Guard did not start.' }
    Write-Host "guard running : pid $($g.Id)" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Installed. Launch the game from Steam normally.' -ForegroundColor Green
Write-Host "Log: $(Join-Path $installDir 'guard.log')"
if (Test-Path (Join-Path $installDir 'guard.log')) {
    Write-Host '--- last log lines ---'
    Get-Content (Join-Path $installDir 'guard.log') -Tail 5
}
