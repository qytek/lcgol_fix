<#
.SYNOPSIS
    End-to-end launch test: starts the game through Steam, watches it, and
    reports affinity, crash dumps and event-log errors.

.DESCRIPTION
    Reproduces exactly what a user does (Steam -> Play) and measures:

      * whether lcgol.exe appears and with which CPU affinity,
      * whether the game window is created and how long it survives,
      * how many new %LOCALAPPDATA%\CrashDumps\*.dmp files appeared,
      * how many new Application-log event 1000 entries appeared,
      * the tail of the guard log (if the guard is installed).

    Exits with code 0 when the game survived -RunFor seconds, 1 when it crashed.

.PARAMETER AppId
    Steam app id. Default 35130 (Lara Croft and the Guardian of Light).

.PARAMETER RunFor
    Seconds to keep the game running after it is detected. Default 60.

.PARAMETER WaitStart
    Seconds to wait for the process to appear. Default 120 (Steam can be slow).

.PARAMETER Screenshots
    Save screenshots (to -OutDir) at 15/40/70 % of the run.

.PARAMETER OutDir
    Screenshot directory. Default: %TEMP%\lcgol-fix\shots

.PARAMETER KeepRunning
    Do not close the game at the end (leave it running for the user).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Test-LcgolLaunch.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Test-LcgolLaunch.ps1 -RunFor 120 -Screenshots -KeepRunning
#>
[CmdletBinding()]
param(
    [int]$AppId = 35130,
    [string]$ProcessName = 'lcgol',
    [int]$RunFor = 60,
    [int]$WaitStart = 120,
    [switch]$Screenshots,
    [string]$OutDir = (Join-Path $env:TEMP 'lcgol-fix\shots'),
    [switch]$KeepRunning
)

$ErrorActionPreference = 'Stop'
if ($Screenshots) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
}

function Save-Shot([string]$tag) {
    try {
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($vs.Location, [System.Drawing.Point]::Empty, $vs.Size)
        $path = Join-Path $OutDir ("launch-{0}.png" -f $tag)
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        return $path
    } catch { return $null }
}

function Get-GameEvents {
    @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000 } -MaxEvents 500 -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match $ProcessName })
}

$dumpDir = Join-Path $env:LOCALAPPDATA 'CrashDumps'
$dumpsBefore = @(Get-ChildItem $dumpDir -Filter '*.dmp' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
$eventsBefore = (Get-GameEvents).Count

$guard = Get-Process LcgolAffinityGuard -ErrorAction SilentlyContinue
$steam = Get-Process steam -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Host '=== launch test ===' -ForegroundColor Cyan
Write-Host ("guard running   : {0}" -f ([bool]$guard))
if ($steam) { Write-Host ("steam affinity  : 0x{0:X}" -f [int64]$steam.ProcessorAffinity) }
else { Write-Host 'steam is not running - the game will not start' }

$launch = Get-Date
Write-Host ("launching steam://rungameid/{0} ..." -f $AppId)
Start-Process ("steam://rungameid/{0}" -f $AppId) | Out-Null

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$proc = $null
while (-not $proc -and $sw.Elapsed.TotalSeconds -lt $WaitStart) {
    Start-Sleep -Milliseconds 200
    $proc = Get-Process $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { $_.StartTime -gt $launch.AddSeconds(-3) } | Select-Object -First 1
}

if (-not $proc) {
    Write-Host "RESULT: game process never appeared within $WaitStart s" -ForegroundColor Red
    exit 1
}

Write-Host ("[{0,5:N1}s] process up: pid={1} affinity=0x{2:X}" -f `
    $sw.Elapsed.TotalSeconds, $proc.Id, [int64]$proc.ProcessorAffinity) -ForegroundColor Green

$shotAt = @([int]($RunFor * 0.15), [int]($RunFor * 0.40), [int]($RunFor * 0.70))
$shotDone = @{}
$exited = $false
$run = [System.Diagnostics.Stopwatch]::StartNew()

while ($run.Elapsed.TotalSeconds -lt $RunFor) {
    Start-Sleep -Milliseconds 200
    try { $proc.Refresh() } catch {}
    if ($proc.HasExited) { $exited = $true; break }
    if ($Screenshots) {
        foreach ($s in $shotAt) {
            if ($run.Elapsed.TotalSeconds -ge $s -and -not $shotDone.ContainsKey($s)) {
                $shotDone[$s] = $true
                $p = Save-Shot ("t{0}" -f $s)
                if ($p) { Write-Host ("[{0,5:N1}s] screenshot: {1}" -f $run.Elapsed.TotalSeconds, $p) }
            }
        }
    }
}

if ($exited) {
    $code = 'unknown'
    try { $code = ('0x{0:X8}' -f $proc.ExitCode) } catch {}
    Write-Host ("RESULT: game EXITED after {0:N1}s (code {1})" -f $run.Elapsed.TotalSeconds, $code) -ForegroundColor Red
} else {
    Write-Host ("RESULT: game still running after {0:N0}s, WS={1:N0} MB, title='{2}'" -f `
        $run.Elapsed.TotalSeconds, ($proc.WorkingSet64 / 1MB), $proc.MainWindowTitle) -ForegroundColor Green
    if ($Screenshots) {
        $p = Save-Shot 'final'
        if ($p) { Write-Host "final screenshot: $p" }
    }
    if (-not $KeepRunning) {
        try { $proc.Kill(); Write-Host '(test instance closed)' } catch {}
    } else {
        Write-Host '(left running on purpose)'
    }
}

Start-Sleep -Milliseconds 1500
$newDumps = @(Get-ChildItem $dumpDir -Filter '*.dmp' -ErrorAction SilentlyContinue |
    Where-Object { $dumpsBefore -notcontains $_.Name })
$newEvents = @((Get-GameEvents) | Select-Object -Skip $eventsBefore)

Write-Host ("new crash dumps  : {0}" -f $newDumps.Count)
foreach ($d in $newDumps) { Write-Host ("   {0}" -f $d.Name) }
Write-Host ("new crash events : {0}" -f $newEvents.Count)
foreach ($e in $newEvents) {
    $m = $e.Message
    $mod  = if ($m -match 'Faulting module name: ([^,]+),') { $matches[1] } else { '?' }
    $code = if ($m -match 'Exception code: (\S+)') { $matches[1] } else { '?' }
    $off  = if ($m -match 'Fault offset: (\S+)') { $matches[1] } else { '?' }
    Write-Host ("   {0}: module={1} code={2} offset={3}" -f $e.TimeCreated.ToString('HH:mm:ss'), $mod, $code, $off)
}

$guardLog = Join-Path $env:LOCALAPPDATA 'LcgolFix\guard.log'
if (Test-Path $guardLog) {
    Write-Host '--- guard log (tail) ---'
    Get-Content $guardLog -Tail 4
}

if ($exited -or $newDumps.Count -gt 0) { exit 1 } else { exit 0 }
