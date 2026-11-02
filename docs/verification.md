# Verification — measurements and run log

All runs were done on the machine described in [diagnosis.md](diagnosis.md) by launching the game
through Steam (`steam://rungameid/35130`) exactly as a user would. "Dumps" counts new
`%LOCALAPPDATA%\CrashDumps\lcgol.exe*.dmp` files; "events" counts new Application-log ID 1000
entries for `lcgol.exe`.

## 1. Before the fix — baseline

| run | CPU mask seen by game | result | dumps | events |
|---|---|---|---|---|
| baseline | `0xFFFFFFFF` (32) | process gone ~1.6 s after start, window never appears | 2 | 2 |
| baseline (repeat) | `0xFFFFFFFF` (32) | identical fault `0xC0000409 @ +0x30117D` | 2 | 2 |

Screenshots from the baseline run show only Steam's "starting executable" notification — the game
window is never created.

## 2. Isolating the processor count

| run | mask | logical CPUs | result | dumps | events |
|---|---|---|---|---|---|
| A | `0xFFFFFFFF` | 32 | **crash** `0xC0000409 @ lcgol.exe+0x30117D` | 2 | 2 |
| B | `0x7FFFFFFF` | 31 | window at 6 s, still running at 28 s | 0 | 0 |
| C | `0x3FFFFFFF` | 30 | window at 6 s, still running at 30 s, splash + intro video rendering | 0 | 0 |

Masks were applied to `steam.exe` before launch so the game inherited them (the game itself cannot
be pre-restricted, because launching `lcgol.exe` directly only triggers Steam's
"restart through Steam" path and exits with code 0).

## 3. After the fix — guard installed, Steam unrestricted

`LcgolAffinityGuard.exe` running, `steam.exe` at `0xFFFFFFFF`:

| run | game pid | affinity applied | survived | dumps | events |
|---|---|---|---|---|---|
| D | 10656 | `0xFFFFFFFF → 0x3FFFFFFF` immediately after creation | 120 s, main menu reached (Single Player / Multiplayer / Leaderboards) | 0 | 0 |
| E | 36452 | `0xFFFFFFFF → 0x3FFFFFFF` | 45 s (harness then closed it) | 0 | 0 |
| F | 34584 | `0xFFFFFFFF → 0x3FFFFFFF` | gameplay: intro → first temple level, HUD, enemies, tutorial prompts; alive and playable | 0 | 0 |

Guard log for those runs:

```
2026-11-02 20:42:35  pid 36452: affinity 0xFFFFFFFF -> 0x3FFFFFFF
2026-11-02 20:43:43  pid 34584: affinity 0xFFFFFFFF -> 0x3FFFFFFF
```

Timing margin: the guard detects a new process within one 500 ms poll, while the game needs ~1.6 s
to reach the failing instruction, so the mask is always in place before the overflow happens. The
log confirms the mask is applied to the process while it is still at its initial full mask.

## 4. Guard cost

Measured over 60 s of idle running on the 32-thread Ryzen 9 3950X:

| metric | value |
|---|---|
| CPU time | 0.94 s per 60 s → **1.56 % of one core**, ≈0.05 % of total CPU |
| private memory | ~16.5 MB |
| threads / windows | 1 background thread, no window, no tray icon |
| writes | only `%LOCALAPPDATA%\LcgolFix\guard.log`, capped at 64 KB |

`EnumProcesses()` costs ~7 ms per call on this machine (285 processes, likely due to installed
system-monitoring software), which is why the poll interval is 500 ms rather than something
smaller, and why only *newly appeared* PIDs ever get a name lookup.

## 5. Reproducing the verification

```powershell
# end-to-end: launches the game via Steam, reports affinity, dumps and event-log deltas
powershell -ExecutionPolicy Bypass -File .\scripts\Test-LcgolLaunch.ps1 -RunFor 120

# manual A/B: restrict Steam to 30 CPUs (same effect as the guard) and launch by hand
powershell -ExecutionPolicy Bypass -File .\scripts\Set-SteamAffinity.ps1 -Cpus 30
# ... later
powershell -ExecutionPolicy Bypass -File .\scripts\Set-SteamAffinity.ps1 -Restore
```

## 6. Screenshots

| file | shows |
|---|---|
| `images/splash.jpg` | title screen rendering with the guard active |
| `images/level-loading.jpg` | "Temple of Light" level loading screen — the engine completed initialisation and streams a level |
| `images/gameplay.jpg` | first level in play: Lara + Totec, both HUDs, enemies on screen |
| `images/menu-attract-demo.jpg` | the main menu's background is an attract-mode gameplay video — a reason not to mistake a menu for proof of gameplay |
