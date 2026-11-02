<#
.SYNOPSIS
    Builds src\LcgolAffinityGuard.cs into dist\LcgolAffinityGuard.exe.

.DESCRIPTION
    Uses the C# compiler that ships with .NET Framework 4.x (csc.exe), so no
    Visual Studio / SDK / NuGet download is required. Output is an AnyCPU WinExe
    (no console window) with no external dependencies.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Build-Guard.ps1
#>
[CmdletBinding()]
param(
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'src\LcgolAffinityGuard.cs'
if (-not (Test-Path $src)) { throw "Source not found: $src" }
if (-not $OutFile) { $OutFile = Join-Path $root 'dist\LcgolAffinityGuard.exe' }

$csc = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe')
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $csc) { throw 'csc.exe (.NET Framework 4) was not found; install .NET Framework 4.x.' }

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

Write-Host "compiler : $csc"
Write-Host "source   : $src"
Write-Host "output   : $OutFile"

& $csc /nologo /target:winexe /optimize+ /platform:anycpu "/out:$OutFile" $src
if ($LASTEXITCODE -ne 0) { throw "csc.exe failed with exit code $LASTEXITCODE" }

Get-Item $OutFile | Select-Object FullName, Length, LastWriteTime
