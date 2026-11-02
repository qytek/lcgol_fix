# Diagnosis — `lcgol.exe` crash `0xC0000409` at `lcgol.exe+0x30117D`

Notes from the original troubleshooting session, kept in full so the reasoning can be re-checked
(or reused for another Crystal Dynamics title of the same era).

## 1. Environment

| item | value |
|---|---|
| OS | Windows 10 Pro 22H2, build 10.0.19045 |
| CPU | AMD Ryzen 9 3950X — 16 cores / **32 logical processors** |
| GPU | NVIDIA GeForce RTX 4060 Ti, driver 32.0.16.1088 (2026-07-22) |
| RAM | 63.9 GB |
| Display | 3440×1440 desktop, game runs at 2560×1440 fullscreen |
| Game | app id **35130**, Steam build **11395**, `lcgol.exe` **1.3.149.0** |
| exe | SHA-256 `E110CA45F04B0D6EB64F7A90D69283F4710E93A2946ED47C33571B4756DD736D` |
| exe signature | Authenticode **valid**, CN=Valve Corp. (so: unmodified Steam file, not a crack) |

Installed files are stock: `bigfile.000/001`, `patch.000/001`, `PACK4.000`, `binkw32.dll`,
`fmodex.dll`, `steam_api.dll`, `movies\*.bik`. The bundled `redist\dx90c` and
`redist\vcredist\vcredist_x86.exe` had already been installed by Steam's install script.

## 2. What Windows logged

Every launch produced exactly two Application-log events (ID 1000), ~1 s apart:

```
Faulting application name: lcgol.exe, version: 1.3.149.0, time stamp: 0x4cfd752c
Faulting module name: lcgol.exe, version: 1.3.149.0, time stamp: 0x4cfd752c
Exception code: 0xc0000409
Fault offset: 0x0030117d
```

```
Faulting application name: lcgol.exe, version: 1.3.149.0, time stamp: 0x4cfd752c
Faulting module name: unknown, version: 0.0.0.0, time stamp: 0x00000000
Exception code: 0xc0000005
Fault offset: 0x00000000
```

and a WER "BEX" bucket:

```
Event Name: BEX
P1: lcgol.exe   P2: 1.3.149.0   P3: 4cfd752c
P4: lcgol.exe   P5: 1.3.149.0   P6: 4cfd752c
P7: 0030117d    P8: c0000409    P9: 00000015
```

Each attempt also wrote **two** minidumps to `%LOCALAPPDATA%\CrashDumps`
(`lcgol.exe.<pid>.dmp` and `lcgol.exe(1).<pid>.dmp`, ~30 MB each), 10 files in total from
5 attempts before the fix.

`0xC0000409` is `STATUS_STACK_BUFFER_OVERRUN` (the exception a failed `/GS` stack-cookie check
raises). The second event is **not** a separate bug: after the real crash the game's own crash
handler / minidump writer dereferences NULL (`EIP = 0`), which is why the faulting module is
reported as `unknown` at offset `0`. Ignoring the second event is the correct move.

## 3. Reading the minidumps

`scripts/Get-MinidumpInfo.ps1` was written for this (no WinDbg required). The dump is x86
(`SystemInfo.ProcessorArchitecture = 0`, OS 10.0.19045) and contains 13 streams: ThreadList,
ModuleList, UnloadedModuleList, MemoryList, Exception, SystemInfo, MiscInfo, SystemMemoryInfo,
ProcessVmCounters.

Exception stream:

| field | value |
|---|---|
| `ExceptionCode` | `0xC0000409` |
| `NumberParameters` | 1 |
| `ExceptionInformation[0]` | `0x15` |
| `ExceptionAddress` | `0x0070117D` |

Context of the faulting thread:

| register | value |
|---|---|
| EIP | `0x0070117D` |
| ESP | `0x0019E4D4` |
| EBP | `0x0019E8A4` |
| EDI | `0x000014D8` |
| EAX | `0x00000000` |
| EBX | `0x18200800` |
| EDX | `0x69746EFF` |
| ECX / ESI | `0x00000000` |
| EFlags | `0x00210246` |
| SegCs / SegSs | `0x23` / `0x2B` |

`0x0070117D` is `ImageBase 0x400000` + RVA **`0x30117D`**, which matches WER's `Fault offset`.
The image is a 32-bit PE with sections `.text` (RVA `0x1000`, raw `0x1000`) — so for `.text` the
file offset equals the RVA and the faulting bytes can be read straight out of `lcgol.exe`:

```asm
0030117D  88 84 3D 84 02 00 00      mov byte ptr [ebp+edi+284h], al
```

Substituting the live registers:

```
EBP + EDI + 0x284 = 0x0019E8A4 + 0x000014D8 + 0x284 = 0x001A0000
```

The dump's stack memory range for this thread is `0x0019DE1C – 0x0019FFFF`, i.e. **`0x001A0000`
is exactly one byte past the end of the stack**. The game writes a single byte past the top of its
own stack frame — the last element of a fixed-size table — corrupting the frame. The `/GS` cookie
check then fails and the process is terminated with `0xC0000409`.

### It is perfectly deterministic

Five launches, five dumps — identical registers every time:

| pid | EIP | ESP | EBP | EDI | EAX |
|---|---|---|---|---|---|
| 21636 | `0x0070117D` | `0x0019E4D4` | `0x0019E8A4` | `0x14D8` | `0` |
| 13132 | `0x0070117D` | `0x0019E4D4` | `0x0019E8A4` | `0x14D8` | `0` |
| 38744 | `0x0070117D` | `0x0019E4D4` | `0x0019E8A4` | `0x14D8` | `0` |
| 39104 | `0x0070117D` | `0x0019E4D4` | `0x0019E8A4` | `0x14D8` | `0` |
| 25764 | `0x0070117D` | `0x0019E4D4` | `0x0019E8A4` | `0x14D8` | `0` |

A driver or overlay problem would move the fault around; identical registers on every run means a
fixed code path with a fixed index — a logic bug, not a crash caused by the environment per se.

### What had loaded by the time it crashed

78 modules, including `d3d9.dll`, `nvd3dum.dll`, `nvgpucomp32.dll` (NVIDIA UMD), `binkw32.dll`,
`steam_api.dll`, `steamclient.dll`, `gameoverlayrenderer.dll`, `apphelp.dll` + `AcLayers.dll`
(a `WIN7RTM` compatibility layer was set on the exe) and `msvcr80.dll` from WinSxS
(`8.0.50727.9672`). `fmodex.dll` and `d3dx9_42.dll` were **not** loaded — the crash happens during
early engine/thread setup, before audio and D3DX initialisation.

## 4. Hypotheses tested and rejected

| hypothesis | test | result |
|---|---|---|
| Missing DirectX 9.0c (June 2010) runtime | `SysWOW64\d3dx9_42.dll` `9.27.952.3001`, `d3dx9_43`, `XAudio2_7`, `x3daudio1_7`, `xapofx1_5` present | rejected |
| Missing VC++ runtime | `msvcr80.dll` present in WinSxS and **loaded in the crash dump** | rejected |
| Cracked / modified exe | Authenticode signature valid (Valve Corp.), stock SHA-256, Steam `StateFlags 4`, no pending update | rejected |
| Windows 7 compatibility shim | `WIN7RTM` layer was active in *both* the crashing and the working runs (layers: `HKCU\...\AppCompatFlags\Layers`) | rejected — left untouched |
| Corrupt game settings in registry | `HKCU\Software\Crystal Dynamics\Lara Croft: GoL` inspected; crash happened before any settings were read (audio/D3DX modules never loaded) | rejected |
| Ultrawide 3440×1440 / resolution | same fault at the same address regardless; the game switches to 2560×1440 only after the crash point | rejected |
| Steam overlay (`gameoverlayrenderer.dll`) | loaded in both crashing and working runs | rejected |
| DEP / missing DEP exclusion | fault is a `/GS` failure inside the game's own code, not an NX fault | rejected |
| **Number of logical processors** | affinity A/B test, see below | **confirmed** |

Community data points agree: an i9-14900K (32 threads) and a Ryzen 9 7950X (32 threads) fail, a
7900X (24 threads) and various laptops work — see
[Steam discussion "Game won't start on Windows 11 25H2"](https://steamcommunity.com/app/35130/discussions/0/792200849038252558).

## 5. The decisive experiment

Launch through Steam with Steam's own affinity restricted, so the game inherits the mask
(`scripts/Set-SteamAffinity.ps1`):

| CPU mask | logical CPUs | outcome |
|---|---|---|
| `0xFFFFFFFF` | 32 | crash, `0xC0000409` @ `+0x30117D`, 2 dumps |
| `0x7FFFFFFF` | 31 | game window appears at ~6 s, alive after 28 s, **0 dumps** |
| `0x3FFFFFFF` | 30 | game window appears at ~6 s, alive after 30 s, **0 dumps**, renders splash + Bink intro |

So the table that overflows has **32 entries**, and the overflow is by exactly one entry when the
machine reports 32 processors. 31 is already enough to avoid it; 30 is used in the shipped fix for
one CPU of margin.

## 6. Conclusion

`lcgol.exe` (2010) sizes a processor table at 32 and indexes it with the logical-processor count.
On a 32-thread CPU the write lands one byte past the end of the stack frame, the `/GS` cookie check
fails and the process dies before it can even create its window. Capping the game process to 30
logical CPUs removes the overflow. No game file needs to be modified.
