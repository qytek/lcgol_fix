# Lara Croft and the Guardian of Light — instant crash-on-launch fix

Fixes the crash where `lcgol.exe` (build **1.3.149.0**, Steam app **35130**) dies one or two
seconds after launch, before the game window ever appears, on Windows 10/11 machines that report
**32 or more logical processors**.

Tested on:

| | |
|---|---|
| OS | Windows 10 Pro 22H2 (build 19045) |
| CPU | AMD Ryzen 9 3950X — 16 cores / **32 logical processors** |
| GPU | NVIDIA RTX 4060 Ti (driver 32.0.16.1088) |
| Game | `lcgol.exe` 1.3.149.0, Steam build 11395, Valve-signed, unmodified |

---

## 1. Symptom

Pressing Play in Steam shows the "starting executable" notification, then nothing. The process
is gone within ~2 s. `%LOCALAPPDATA%\CrashDumps` fills up with `lcgol.exe.<pid>.dmp` files, and the
Windows Application log (event ID 1000) records **two** errors per attempt:

```
Faulting application name: lcgol.exe, version: 1.3.149.0, time stamp: 0x4cfd752c
Faulting module name: lcgol.exe, version: 1.3.149.0, time stamp: 0x4cfd752c
Exception code: 0xc0000409
Fault offset: 0x0030117d
```

```
Faulting application name: lcgol.exe ...
Faulting module name: unknown, version 0.0.0.0 ...
Exception code: 0xc0000005
Fault offset: 0x00000000
```

The second one (`0xc0000005` at offset `0`, faulting module `unknown`) is the game's crash handler /
minidump writer falling over *after* the real crash. Ignore it — the first event is the real bug.

## 2. Root cause

`0xC0000409` is `STATUS_STACK_BUFFER_OVERRUN`, raised when a `/GS` stack cookie check fails.

Every single launch produced an identical exception record:

| field | value |
|---|---|
| Exception code | `0xC0000409`, info[0] = `0x15` |
| Exception address | `0x0070117D` (`lcgol.exe` image base `0x400000` + RVA **`0x30117D`**) |
| EIP / ESP / EBP | `0x0070117D` / `0x0019E4D4` / `0x0019E8A4` |
| EDI / EAX | `0x000014D8` / `0x00000000` |

The faulting instruction is

```asm
0070117D  88 84 3D 84 02 00 00   mov byte ptr [ebp+edi+284h], al
```

and `EBP + EDI + 0x284 = 0x001A0000`, which is *exactly* one byte past the end of the thread's stack
region — i.e. the game writes one byte past the end of a fixed-size table on the stack, corrupting
the frame, and the stack-cookie check terminates the process.

The table is indexed by the processor count, and it has **32 entries**. The boundary is exact:

| logical CPUs | affinity mask | result |
|---|---|---|
| **32** | `0xFFFFFFFF` | **crash `0xC0000409` @ `lcgol.exe+0x30117D`** |
| 31 | `0x7FFFFFFF` | runs |
| 30 | `0x3FFFFFFF` | runs |

This matches reports from other owners of high-core-count CPUs: an i9-14900K (32 threads) and a
Ryzen 9 7950X (32 threads) fail, while a 7900X (24 threads) works — see
[this Steam discussion](https://steamcommunity.com/app/35130/discussions/0/792200849038252558).
The game is from 2010 and simply assumes no machine will ever report more than 31 processors.

## 3. Fix

A ~5 KB background helper, **`LcgolAffinityGuard.exe`**, watches for `lcgol.exe` and immediately
limits that process to **30 logical CPUs** (mask `0x3FFFFFFF`) — before the game reaches the
failing code (~1.6 s after process creation). Nothing else is touched: no game file is patched,
Steam is not modified, no other game is affected.

The reason a guard is used instead of editing `lcgol.exe`: the executable is Valve-signed and
Steam-managed, so any byte patch would be silently reverted by "Verify integrity of game files"
and could break Steam's DRM. The guard survives game updates.

While running, the guard costs about **1.5 % of one core** (≈0.05 % of a 32-thread machine) and
~16 MB of RAM.

## 4. Install

```powershell
git clone git@github.com:qytek/lcgol_fix.git
cd lcgol_fix
powershell -ExecutionPolicy Bypass -File .\scripts\Install-LcgolFix.ps1
```

That will:

1. copy the guard to `%LOCALAPPDATA%\LcgolFix\` (building it from `src\` with the .NET Framework
   `csc.exe` if needed),
2. put a shortcut in your Startup folder so it runs at every logon,
3. start it right now.

Then just press **Play** in Steam as usual.

### Verify

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Test-LcgolLaunch.ps1
```

It launches the game through Steam exactly as a user would, waits, reports the process affinity,
whether any new crash dump or event-log error appeared, and optionally saves screenshots.

A healthy result looks like:

```
[  4.5s] game pid=10656 started 20:32:21 affinity=0x3FFFFFFF
RESULT: RUNNING for 120s  WS=241MB  title='Lara Croft and the Guardian of Light'
new crash dumps: 0
new app-crash events: 0
```

Guard activity is logged to `%LOCALAPPDATA%\LcgolFix\guard.log`:

```
2026-11-02 20:32:21  pid 10656: affinity 0xFFFFFFFF -> 0x3FFFFFFF
```

### Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Uninstall-LcgolFix.ps1
```

Removes the Startup shortcut, stops the guard and deletes `%LOCALAPPDATA%\LcgolFix`
(add `-KeepLogs` to keep the log).

## 5. Manual workaround (no helper installed)

Limit `steam.exe` itself to 30 CPUs; every game it launches inherits the mask, and the guard is not
needed:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Set-SteamAffinity.ps1 -Cpus 30
```

This lasts until Steam restarts and also applies to every other Steam game (they lose 2 of 32
threads, which is irrelevant in practice). `-Restore` puts Steam back to all CPUs.

## 6. Repository layout

```
README.md                        this file
docs/diagnosis.md                full forensic write-up (dumps, registers, hypothesis tests)
docs/verification.md             test matrix and measured results
docs/images/                     screenshots proving the game now runs
src/LcgolAffinityGuard.cs        guard source (C#, .NET Framework 4)
dist/LcgolAffinityGuard.exe      prebuilt guard (AnyCPU, no dependencies)
scripts/Install-LcgolFix.ps1     install + autostart
scripts/Uninstall-LcgolFix.ps1   remove everything
scripts/Build-Guard.ps1          compile src -> dist with csc.exe
scripts/Test-LcgolLaunch.ps1     end-to-end launch/verification harness
scripts/Set-SteamAffinity.ps1    manual Steam-wide workaround
scripts/Get-MinidumpInfo.ps1     reusable crash-dump inspector (exception, registers, stack)
```

## 7. Notes

- **Diagnosing a different game?** `Get-MinidumpInfo.ps1` is generic: it decodes the exception
  record, x86 context, loaded modules, memory ranges and a stack-return-address backtrace from any
  Windows minidump, without WinDbg.
- If the game ever launches but shows **"Failed to initialize Direct3D with current settings"**,
  lower the resolution in the game's display settings, and/or set NVIDIA *Vertical Sync* for
  `lcgol.exe` to On/Off instead of "Use the 3D application setting"
  ([Steam guide](https://steamcommunity.com/sharedfiles/filedetails/?id=3311708995)).
- Other Crystal Dynamics titles of that era (Tomb Raider: Underworld, Lara Croft and the Temple of
  Osiris) share the same processor-table bug and respond to the same affinity cap. The guard only
  matches `lcgol.exe`; add file names to `TargetName` and rebuild if you want to cover more.
- The Windows 7 compatibility flag that was set on `lcgol.exe` during earlier troubleshooting is
  unrelated to this crash and was left untouched.

## License

MIT — see `LICENSE`.
