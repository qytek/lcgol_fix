<#
.SYNOPSIS
    Decodes a Windows minidump (.dmp) without WinDbg: exception record, CPU
    context, loaded modules, memory ranges and a stack backtrace.

.DESCRIPTION
    Works on dumps written by Windows Error Reporting / %LOCALAPPDATA%\CrashDumps
    (MiniDumpNormal and friends), for both x86 and x64 processes.

    For the Lara Croft crash this is what produced:
        code 0xC0000409, address 0x0070117D (lcgol.exe+0x30117D)
        EIP/ESP/EBP/EDI identical on every launch
        write target = exactly one byte past the top of the thread stack

.PARAMETER Path
    Dump file. Defaults to the newest *.dmp in %LOCALAPPDATA%\CrashDumps.

.PARAMETER StackBytes
    How many bytes of the faulting thread's stack to scan for return addresses.
    Default 1024.

.PARAMETER ShowModules
    List every loaded module.

.PARAMETER ShowMemory
    List the memory ranges stored in the dump.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Get-MinidumpInfo.ps1

.EXAMPLE
    .\Get-MinidumpInfo.ps1 -Path 'C:\Users\me\AppData\Local\CrashDumps\game.exe.1234.dmp' -ShowModules
#>
[CmdletBinding()]
param(
    [string]$Path,
    [int]$StackBytes = 1024,
    [switch]$ShowModules,
    [switch]$ShowMemory
)

$ErrorActionPreference = 'Stop'

if (-not $Path) {
    $dir = Join-Path $env:LOCALAPPDATA 'CrashDumps'
    $Path = (Get-ChildItem $dir -Filter '*.dmp' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    if (-not $Path) { throw "No .dmp found in $dir" }
}
if (-not (Test-Path $Path)) { throw "Not found: $Path" }

$bytes = [System.IO.File]::ReadAllBytes($Path)

function U16([int]$o) { [BitConverter]::ToUInt16($bytes, $o) }
function U32([int]$o) { [BitConverter]::ToUInt32($bytes, $o) }
function U64([int]$o) { [BitConverter]::ToUInt64($bytes, $o) }

function Get-MiniString([int]$rva) {
    if ($rva -le 0) { return '' }
    $len = U32 $rva
    if ($len -le 2) { return '' }
    # Length is a byte count that already includes the terminating NUL
    $s = [System.Text.Encoding]::Unicode.GetString($bytes, $rva + 4, [int]$len)
    return $s.TrimEnd([char]0)
}

$sig = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4)
if ($sig -ne 'MDMP') { throw "Not a minidump (signature '$sig')" }
$version = U32 4
$nStreams = U32 8
$dirRva = U32 12
$stamp = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc).AddSeconds((U32 20)).ToLocalTime()

# stream directory
$streams = @()
for ($i = 0; $i -lt $nStreams; $i++) {
    $o = $dirRva + $i * 12
    $streams += [pscustomobject]@{ Type = (U32 $o); Size = (U32 ($o + 4)); Rva = (U32 ($o + 8)) }
}
function Get-Stream([int]$type) { $streams | Where-Object { $_.Type -eq $type } | Select-Object -First 1 }
$streamNames = @{
    3='ThreadList';4='ModuleList';5='MemoryList';6='Exception';7='SystemInfo';8='ThreadExList';
    9='Memory64List';12='HandleData';14='UnloadedModuleList';15='MiscInfo';16='MemoryInfoList';
    17='ThreadInfoList';21='SystemMemoryInfo';22='ProcessVmCounters'
}

Write-Host ''
Write-Host '=== MINIDUMP ===' -ForegroundColor Cyan
Write-Host ("file       : {0}" -f $Path)
Write-Host ("size       : {0:N0} bytes" -f $bytes.Length)
Write-Host ("version    : 0x{0:X8}   streams: {1}   timestamp: {2:yyyy-MM-dd HH:mm:ss}" -f $version, $nStreams, $stamp)

$names = ($streams | Where-Object { $_.Size -gt 0 } | ForEach-Object {
    $n = $streamNames[[int]$_.Type]
    if ($n) { $n } else { "Type$($_.Type)" }
}) -join ', '
Write-Host ("streams    : {0}" -f $names)

# --- SystemInfo ---------------------------------------------------------------
$si = Get-Stream 7
$arch = 0; $cpus = 0; $osv = ''
if ($si) {
    $arch = U16 $si.Rva
    $cpus = $bytes[$si.Rva + 6]
    $osv = "{0}.{1}.{2}" -f (U32 ($si.Rva + 8)), (U32 ($si.Rva + 12)), (U32 ($si.Rva + 16))
}
$archName = switch ($arch) { 0 { 'x86' } 9 { 'x64' } 5 { 'ARM' } 12 { 'ARM64' } default { "arch$arch" } }
Write-Host ("process    : {0}, OS {1}, {2} processors" -f $archName, $osv, $cpus)

# --- modules ------------------------------------------------------------------
$mods = @()
$ml = Get-Stream 4
if ($ml) {
    $n = U32 $ml.Rva
    for ($i = 0; $i -lt $n; $i++) {
        $o = $ml.Rva + 4 + $i * 108
        $mods += [pscustomobject]@{
            Base = [uint64](U64 $o)
            End  = [uint64](U64 $o) + [uint64](U32 ($o + 8))
            Name = (Get-MiniString (U32 ($o + 20)))
        }
    }
}

function Format-Address([uint64]$addr) {
    $m = $mods | Where-Object { $addr -ge $_.Base -and $addr -lt $_.End } | Select-Object -First 1
    if ($m) {
        $leaf = Split-Path $m.Name -Leaf
        return ("{0}+0x{1:X}" -f $leaf, ($addr - $m.Base))
    }
    return ''
}

# --- exception ---------------------------------------------------------------
$ex = Get-Stream 6
$friendly = @{
    '0xC0000005' = 'STATUS_ACCESS_VIOLATION'
    '0xC0000409' = 'STATUS_STACK_BUFFER_OVERRUN'
    '0xC00000FD' = 'STATUS_STACK_OVERFLOW'
    '0xC000001D' = 'STATUS_ILLEGAL_INSTRUCTION'
    '0xC0000374' = 'STATUS_HEAP_CORRUPTION'
    '0xC000041D' = 'STATUS_FATAL_USER_CALLBACK_EXCEPTION'
    '0x80000003' = 'STATUS_BREAKPOINT'
    '0xE06D7363' = 'C++ exception'
}
if ($ex) {
    $code = U32 ($ex.Rva + 8)
    $addr = [uint64](U64 ($ex.Rva + 24))
    $np = U32 ($ex.Rva + 32)
    Write-Host ''
    Write-Host '=== EXCEPTION ===' -ForegroundColor Cyan
    $f = $friendly[('0x{0:X8}' -f $code)]
    if (-not $f) { $f = 'unknown' }
    Write-Host ("code       : 0x{0:X8}  ({1})" -f $code, $f)
    $mapped = Format-Address $addr
    if ($mapped) { Write-Host ("address    : 0x{0:X8}  -> {1}" -f $addr, $mapped) }
    else { Write-Host ("address    : 0x{0:X8}" -f $addr) }
    Write-Host ("thread id  : {0}" -f (U32 $ex.Rva))
    if ($np -gt 0) {
        $ps = @()
        for ($i = 0; $i -lt $np; $i++) { $ps += ('0x{0:X}' -f (U64 ($ex.Rva + 40 + $i * 8))) }
        Write-Host ("parameters : [{0}]" -f ($ps -join ', '))
    }

    # context
    $ctxSize = U32 ($ex.Rva + 160)
    $ctxRva = U32 ($ex.Rva + 164)
    Write-Host ''
    Write-Host ("=== CONTEXT ({0}, {1} bytes) ===" -f $archName, $ctxSize) -ForegroundColor Cyan
    if ($arch -eq 9) {
        $off = [ordered]@{ Rip = 0xF8; Rsp = 0x98; Rbp = 0xA0; Rax = 0x78; Rbx = 0x90; Rcx = 0x80; Rdx = 0x88; Rsi = 0xA8; Rdi = 0xB0; R8 = 0xB8; R9 = 0xC0; R10 = 0xC8; R11 = 0xD0; R12 = 0xD8; R13 = 0xE0; R14 = 0xE8; R15 = 0xF0 }
        $ipName = 'Rip'; $spName = 'Rsp'; $bpName = 'Rbp'
        foreach ($k in $off.Keys) { Write-Host ("  {0,-4} = 0x{1:X16}" -f $k, (U64 ($ctxRva + $off[$k]))) }
    } else {
        $off = [ordered]@{ Eip = 184; Esp = 196; Ebp = 180; Eax = 176; Ebx = 164; Ecx = 172; Edx = 168; Esi = 160; Edi = 156; EFlags = 192 }
        $ipName = 'Eip'; $spName = 'Esp'; $bpName = 'Ebp'
        foreach ($k in $off.Keys) { Write-Host ("  {0,-6} = 0x{1:X8}" -f $k, (U32 ($ctxRva + $off[$k]))) }
    }
    $ip = if ($arch -eq 9) { [uint64](U64 ($ctxRva + 0xF8)) } else { [uint64](U32 ($ctxRva + 184)) }
    $sp = if ($arch -eq 9) { [uint64](U64 ($ctxRva + 0x98)) } else { [uint64](U32 ($ctxRva + 196)) }
    $bp = if ($arch -eq 9) { [uint64](U64 ($ctxRva + 0xA0)) } else { [uint64](U32 ($ctxRva + 180)) }
    $ipMapped = Format-Address $ip
    if ($ipMapped) { Write-Host ("  -> {0} = {1}" -f $ipName, $ipMapped) -ForegroundColor Yellow }
}

# --- memory ranges -----------------------------------------------------------
$ranges = @()
$mm = Get-Stream 5
if ($mm) {
    $n = U32 $mm.Rva
    for ($i = 0; $i -lt $n; $i++) {
        $o = $mm.Rva + 4 + $i * 16
        $ranges += [pscustomobject]@{
            Start = [uint64](U64 $o)
            Size  = [uint64](U32 ($o + 8))
            Rva   = (U32 ($o + 12))
        }
    }
} else {
    $m64 = Get-Stream 9
    if ($m64) {
        $n = U64 $m64.Rva
        $base = [uint64](U64 ($m64.Rva + 8))
        for ($i = 0; $i -lt $n; $i++) {
            $o = $m64.Rva + 16 + $i * 16
            $ranges += [pscustomobject]@{ Start = [uint64](U64 $o); Size = [uint64](U64 ($o + 8)); Rva = [int]($base) }
            $base += [uint64](U64 ($o + 8))
        }
    }
}

if ($ShowModules) {
    Write-Host ''
    Write-Host ("=== MODULES ({0}) ===" -f $mods.Count) -ForegroundColor Cyan
    $mods | Sort-Object Base | ForEach-Object {
        Write-Host ("  0x{0:X8}-0x{1:X8}  {2}" -f $_.Base, ($_.End - 1), $_.Name)
    }
}

if ($ShowMemory) {
    Write-Host ''
    Write-Host ("=== MEMORY RANGES ({0}) ===" -f $ranges.Count) -ForegroundColor Cyan
    $ranges | ForEach-Object {
        Write-Host ("  0x{0:X8}-0x{1:X8}  size 0x{2:X}  data@0x{3:X}" -f $_.Start, ($_.Start + $_.Size - 1), $_.Size, $_.Rva)
    }
}

# --- stack scan --------------------------------------------------------------
if ($ex -and $ranges.Count -gt 0) {
    $stack = $ranges | Where-Object { $sp -ge $_.Start -and $sp -lt ($_.Start + $_.Size) } | Select-Object -First 1
    Write-Host ''
    Write-Host ("=== STACK of faulting thread ({0}=0x{1:X}) ===" -f $spName, $sp) -ForegroundColor Cyan
    if (-not $stack) {
        Write-Host '  no dumped memory range contains the stack pointer'
    } else {
        Write-Host ("  range 0x{0:X8}-0x{1:X8}  (size 0x{2:X})" -f $stack.Start, ($stack.Start + $stack.Size - 1), $stack.Size)
        if ($bp -ge $stack.Start -and $bp -lt ($stack.Start + $stack.Size)) {
            Write-Host ("  frame base {0}=0x{1:X}  (locals: {2} bytes above {3})" -f $bpName, $bp, ($bp - $sp), $spName)
        }
        $wordSize = if ($arch -eq 9) { 8 } else { 4 }
        $available = [int]($stack.Size - ($sp - $stack.Start))
        $limit = [Math]::Min($StackBytes, $available)
        Write-Host ("  scanning {0} bytes from {1} for return addresses into loaded modules:" -f $limit, $spName)
        $hits = 0
        for ($o = 0; $o + $wordSize -le $limit; $o += $wordSize) {
            $fileOff = [int]($stack.Rva + ($sp - $stack.Start) + $o)
            $val = if ($arch -eq 9) { [uint64](U64 $fileOff) } else { [uint64](U32 $fileOff) }
            $mapped = Format-Address $val
            if ($mapped) {
                Write-Host ("    [{0}+0x{1:X4}] = 0x{2:X8}   {3}" -f $spName, $o, $val, $mapped)
                $hits++
            }
        }
        if ($hits -eq 0) { Write-Host '    (none - frame pointers/stack may not be dumped)' }
    }
}

Write-Host ''
Write-Host 'hint: run with -ShowModules to list every DLL, -ShowMemory for the stored ranges.' -ForegroundColor DarkGray
