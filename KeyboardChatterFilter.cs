// Per-key keyboard chatter filter (debouncer) for Windows, as a standalone program.
// Same logic as chatter-filter.ps1, compiled so it shows up as KeyboardChatterFilter.exe
// in Task Manager. It has no window: dropped presses are written to the log file.
//
// Build (no install needed, uses the compiler that ships with .NET Framework):
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe
//     /out:KeyboardChatterFilter.exe /r:System.Windows.Forms.dll KeyboardChatterFilter.cs
//
// Options (same names as the script):
//   -ThresholdMs 40     re-press window in ms treated as chatter (5-500)
//   -Keys E,L,Space     only filter these keys (System.Windows.Forms.Keys names); default all
//   -LogFile path       log file; default chatter.log next to the exe
//
// Stop it from Task Manager (Details tab, KeyboardChatterFilter.exe, End task).

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

[assembly: AssemblyTitle("Keyboard Chatter Filter")]
[assembly: AssemblyProduct("Keyboard Chatter Filter")]
[assembly: AssemblyDescription("Per-key keyboard chatter filter (debouncer)")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

public static class ChatterFilter
{
    const int WH_KEYBOARD_LL = 13;
    const int WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105;
    const uint LLKHF_INJECTED = 0x10;

    [StructLayout(LayoutKind.Sequential)]
    struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)]
    struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }

    delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc fn, IntPtr hMod, uint threadId);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto)] static extern IntPtr GetModuleHandle(string name);

    static HookProc proc = Hook;          // keep the delegate alive for the hook's lifetime
    static IntPtr hook;
    static uint threshold;
    static bool[] filtered = new bool[256];
    static bool[] isDown = new bool[256];
    static bool[] suppressed = new bool[256];
    static uint[] lastUp = new uint[256];
    static uint[] suppressedAt = new uint[256];
    static bool[] seenUp = new bool[256];
    static int[] dropCount = new int[256];
    static int totalDrops;

    // Logging happens off the hook thread: slow file I/O must never stall the hook,
    // or Windows silently removes it.
    static BlockingCollection<string> logQueue = new BlockingCollection<string>();
    static string logFile;

    static string KeyName(uint vk) { return ((System.Windows.Forms.Keys)vk).ToString(); }

    static IntPtr Hook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            uint vk = k.vkCode & 0xFF;
            int msg = wParam.ToInt32();
            if ((k.flags & LLKHF_INJECTED) == 0 && filtered[vk])
            {
                if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN)
                {
                    if (suppressed[vk])
                    {
                        // Auto-repeat while a chatter press is suppressed: the key is really being held,
                        // so let it through once it outlives the window.
                        if (k.time - suppressedAt[vk] <= threshold) return (IntPtr)1;
                        suppressed[vk] = false;
                        isDown[vk] = true;
                    }
                    else if (!isDown[vk])
                    {
                        uint gap = k.time - lastUp[vk];
                        if (seenUp[vk] && gap < threshold)
                        {
                            suppressed[vk] = true;
                            suppressedAt[vk] = k.time;
                            dropCount[vk]++;
                            totalDrops++;
                            logQueue.Add(string.Format("{0:yyyy-MM-dd HH:mm:ss.fff}  dropped {1,-12} gap {2,3} ms  (this key: {3}, total: {4})",
                                DateTime.Now, KeyName(vk), gap, dropCount[vk], totalDrops));
                            return (IntPtr)1;
                        }
                        isDown[vk] = true;
                    }
                }
                else if (msg == WM_KEYUP || msg == WM_SYSKEYUP)
                {
                    if (suppressed[vk])
                    {
                        suppressed[vk] = false;
                        return (IntPtr)1;
                    }
                    isDown[vk] = false;
                    lastUp[vk] = k.time;
                    seenUp[vk] = true;
                }
            }
        }
        return CallNextHookEx(hook, nCode, wParam, lParam);
    }

    static void Log(string line)
    {
        try { File.AppendAllText(logFile, line + Environment.NewLine); } catch { }
    }

    static void LogWriter()
    {
        foreach (var line in logQueue.GetConsumingEnumerable()) Log(line);
    }

    static int Fail(string message)
    {
        if (logFile != null) Log(string.Format("{0:yyyy-MM-dd HH:mm:ss}  error: {1}", DateTime.Now, message));
        return 1;
    }

    public static int Main(string[] args)
    {
        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        int thresholdMs = 40;
        var keyNames = new List<string>();
        logFile = Path.Combine(exeDir, "chatter.log");

        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i].TrimStart('-', '/').ToLowerInvariant();
            string v = i + 1 < args.Length ? args[i + 1] : null;
            if (a == "thresholdms" && v != null) { int.TryParse(v, out thresholdMs); i++; }
            else if (a == "keys" && v != null) { keyNames.AddRange(v.Split(',')); i++; }
            else if (a == "logfile" && v != null) { logFile = Path.GetFullPath(v); i++; }
            else return Fail("unknown option " + args[i]);
        }
        if (thresholdMs < 5 || thresholdMs > 500) return Fail("ThresholdMs must be between 5 and 500");

        var vks = new List<int>();
        foreach (var name in keyNames)
        {
            if (name.Trim().Length == 0) continue;
            System.Windows.Forms.Keys key;
            if (!Enum.TryParse(name.Trim(), true, out key)) return Fail("unknown key name " + name.Trim());
            vks.Add((int)key);
        }

        // One instance per user session (shared with chatter-filter.ps1).
        bool createdNew;
        using (var mutex = new Mutex(true, @"Local\KeyboardChatterFilter", out createdNew))
        {
            if (!createdNew) return Fail("already running, this copy exits");

            threshold = (uint)thresholdMs;
            for (int i = 0; i < 256; i++) filtered[i] = vks.Count == 0;
            foreach (var vk in vks) filtered[vk & 0xFF] = true;

            string scope = vks.Count == 0 ? "all keys" : string.Join(", ", keyNames.ToArray());
            Log(string.Format("{0:yyyy-MM-dd HH:mm:ss}  started: {1}, window {2} ms", DateTime.Now, scope, thresholdMs));

            new Thread(LogWriter) { IsBackground = true }.Start();

            hook = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(null), 0);
            if (hook == IntPtr.Zero) return Fail("could not install keyboard hook, error " + Marshal.GetLastWin32Error());

            MSG m;
            while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }

            UnhookWindowsHookEx(hook);
        }
        return 0;
    }
}
