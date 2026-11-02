// LcgolAffinityGuard
//
// Lara Croft and the Guardian of Light (lcgol.exe, build 1.3.149.0) crashes at
// startup on machines reporting 32 or more logical processors:
//     0xC0000409 (STATUS_STACK_BUFFER_OVERRUN) at lcgol.exe+0x30117D
// The game overruns a fixed 32-entry processor table, one byte past the top of
// its stack frame. Capping the process to 30 logical CPUs makes it start and
// play normally. See README.md / docs/diagnosis.md.
//
// A small guard is used instead of patching the executable because the game is
// Valve-signed and Steam-managed: any byte patch would be reverted by
// "Verify integrity of game files" and could break Steam's DRM.
//
// Detection is deliberately cheap: EnumProcesses() returns just a PID array, and
// only newly appeared PIDs get their image name queried. When a target process
// is seen, the CPU mask is applied immediately - the game needs ~1.6 s to reach
// the failing code, so even a 500 ms poll has margin.
//
// Optional config file (next to the exe): LcgolAffinityGuard.ini
//     Cpus=30
//     Targets=lcgol.exe
// (Targets is comma separated; useful for tru.exe / Temple of Osiris, which
// share the same bug.)

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class LcgolAffinityGuard
{
    const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    const uint PROCESS_SET_INFORMATION = 0x0200;

    // Process enumeration costs ~7 ms on a busy machine, so keep the rate low.
    const int PollMs = 500;

    static long cpuCap = 0x3FFFFFFF;                       // CPUs 0..29
    static readonly HashSet<string> targets =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "lcgol.exe" };

    static readonly string InstallDir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LcgolFix");
    static readonly string LogFile = Path.Combine(InstallDir, "guard.log");

    static readonly uint[] pidBuffer = new uint[8192];
    static readonly HashSet<uint> known = new HashSet<uint>();

    [DllImport("psapi.dll", SetLastError = true)]
    static extern bool EnumProcesses(uint[] pProcessIds, uint cb, out uint cbNeeded);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool QueryFullProcessImageNameW(IntPtr hProcess, uint dwFlags,
        StringBuilder lpExeName, ref uint lpdwSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetProcessAffinityMask(IntPtr hProcess,
        out UIntPtr lpProcessAffinityMask, out UIntPtr lpSystemAffinityMask);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetProcessAffinityMask(IntPtr hProcess, UIntPtr dwProcessAffinityMask);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    static void Main()
    {
        bool createdNew;
        using (var mutex = new Mutex(true, @"Local\LcgolAffinityGuard", out createdNew))
        {
            if (!createdNew) return; // already running

            LoadConfig();
            Log("guard started: cap=0x" + cpuCap.ToString("X") + " (" + PopCount(cpuCap) + " CPUs), " +
                "targets=" + string.Join(",", targets) + ", system=" + Environment.ProcessorCount + " logical CPUs");

            while (true)
            {
                try { Sweep(); }
                catch { }
                Thread.Sleep(PollMs);
            }
        }
    }

    static void LoadConfig()
    {
        try
        {
            string exeDir = Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
            string ini = Path.Combine(exeDir, "LcgolAffinityGuard.ini");
            if (!File.Exists(ini)) return;

            foreach (string raw in File.ReadAllLines(ini))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line.StartsWith(";") || line.StartsWith("#")) continue;
                int eq = line.IndexOf('=');
                if (eq <= 0) continue;
                string key = line.Substring(0, eq).Trim();
                string val = line.Substring(eq + 1).Trim();

                if (key.Equals("Cpus", StringComparison.OrdinalIgnoreCase))
                {
                    int n;
                    if (int.TryParse(val, NumberStyles.Integer, CultureInfo.InvariantCulture, out n))
                    {
                        if (n < 1) n = 1;
                        if (n > 31) n = 31; // 32+ is exactly what the game cannot handle
                        cpuCap = (1L << n) - 1;
                    }
                }
                else if (key.Equals("Targets", StringComparison.OrdinalIgnoreCase))
                {
                    var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    foreach (string t in val.Split(','))
                    {
                        string name = t.Trim();
                        if (name.Length > 0) set.Add(name);
                    }
                    if (set.Count > 0)
                    {
                        targets.Clear();
                        foreach (string t in set) targets.Add(t);
                    }
                }
            }
        }
        catch { /* keep defaults */ }
    }

    static int PopCount(long v)
    {
        int c = 0;
        while (v != 0) { c += (int)(v & 1); v >>= 1; }
        return c;
    }

    static void Sweep()
    {
        uint needed;
        if (!EnumProcesses(pidBuffer, (uint)(pidBuffer.Length * 4), out needed)) return;

        int count = (int)(needed / 4);
        if (count > pidBuffer.Length) count = pidBuffer.Length;

        // Rebuild the live PID set each sweep: exited PIDs drop out, so a
        // recycled PID is always re-examined. Only new PIDs cost a name query.
        var alive = new HashSet<uint>(count);
        for (int i = 0; i < count; i++)
        {
            uint pid = pidBuffer[i];
            if (pid != 0) alive.Add(pid);
        }

        foreach (uint pid in alive)
        {
            if (known.Contains(pid)) continue;
            string name = GetImageName(pid);
            if (name == null) continue;
            if (!targets.Contains(name)) continue;
            TryCap(pid);
        }

        known.Clear();
        known.UnionWith(alive);
    }

    static string GetImageName(uint pid)
    {
        IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return null;
        try
        {
            var sb = new StringBuilder(260);
            uint size = 260;
            if (!QueryFullProcessImageNameW(h, 0, sb, ref size)) return null;
            string full = sb.ToString();
            int slash = full.LastIndexOf('\\');
            return slash >= 0 ? full.Substring(slash + 1) : full;
        }
        finally { CloseHandle(h); }
    }

    static void TryCap(uint pid)
    {
        IntPtr h = OpenProcess(PROCESS_SET_INFORMATION | PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return;
        try
        {
            UIntPtr procMask, sysMask;
            if (!GetProcessAffinityMask(h, out procMask, out sysMask)) return;

            long mask = (long)(ulong)procMask;
            if ((mask & ~cpuCap) == 0) return; // already inside the cap

            if (!SetProcessAffinityMask(h, new UIntPtr((uint)cpuCap))) return;

            Log("pid " + pid + ": affinity 0x" + mask.ToString("X") + " -> 0x" + cpuCap.ToString("X"));
        }
        finally { CloseHandle(h); }
    }

    static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(InstallDir);
            if (File.Exists(LogFile) && new FileInfo(LogFile).Length > 64 * 1024)
                File.Delete(LogFile);
            File.AppendAllText(LogFile,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + message + Environment.NewLine);
        }
        catch { }
    }
}
