<#
.SYNOPSIS
  Per-key keyboard chatter filter (debouncer) for Windows.

.DESCRIPTION
  Installs a low-level keyboard hook. When a key is pressed again less than
  -ThresholdMs after it was released, that press is treated as switch chatter
  and dropped (together with its matching release). Other keys are never
  affected, so normal fast typing and real double letters still work.

  Every dropped press is logged with the key name and the gap, so you can see
  which switches chatter and tune the threshold.

  Turn Windows "Bounce keys" OFF while using this, or both filters stack.

.PARAMETER ThresholdMs
  Re-press window in milliseconds treated as chatter. 30-60 is typical.
  Raise it if a bad key still doubles; lower it if real double letters get eaten.

.PARAMETER Keys
  Optional list of keys to filter (e.g. -Keys E,L,Space). Default: all keys.
  Names are .NET System.Windows.Forms.Keys names: A-Z, D0-D9, Space, Return,
  Back, OemPeriod, Oemcomma, LShiftKey, ...

.PARAMETER LogFile
  Optional path; dropped presses are appended there as well as to the console.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File chatter-filter.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File chatter-filter.ps1 -ThresholdMs 60 -Keys E,L
#>
param(
    [ValidateRange(5, 500)][int]$ThresholdMs = 40,
    [string[]]$Keys = @(),
    [string]$LogFile = ''
)

Add-Type -AssemblyName System.Windows.Forms

# One instance per user session; a second copy would just log every drop twice.
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\KeyboardChatterFilter', [ref]$createdNew)
if (-not $createdNew) {
    Write-Host 'Chatter filter is already running.' -ForegroundColor Yellow
    exit
}

$source = @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public static class ChatterFilter
{
    const int WH_KEYBOARD_LL = 13;
    const int WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105;
    const int WM_QUIT = 0x0012;
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
    [DllImport("user32.dll")] static extern bool PostThreadMessage(uint threadId, int msg, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", CharSet = CharSet.Auto)] static extern IntPtr GetModuleHandle(string name);

    static HookProc proc = Hook;          // keep the delegate alive for the hook's lifetime
    static IntPtr hook;
    static uint loopThread;
    static uint threshold;
    static bool[] filtered = new bool[256];
    static bool[] isDown = new bool[256];
    static bool[] suppressed = new bool[256];
    static uint[] lastUp = new uint[256];
    static uint[] suppressedAt = new uint[256];
    static bool[] seenUp = new bool[256];
    static int[] dropCount = new int[256];
    static int totalDrops;

    // Logging happens off the hook thread: a slow or paused console must never stall the hook,
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
                            logQueue.Add(string.Format("{0:HH:mm:ss.fff}  dropped {1,-12} gap {2,3} ms  (this key: {3}, total: {4})",
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

    static void LogWriter()
    {
        foreach (var line in logQueue.GetConsumingEnumerable())
        {
            Console.WriteLine(line);
            if (!string.IsNullOrEmpty(logFile))
                try { File.AppendAllText(logFile, line + Environment.NewLine); } catch { }
        }
    }

    public static void Run(int thresholdMs, int[] vkList, string logPath)
    {
        threshold = (uint)thresholdMs;
        logFile = logPath;
        for (int i = 0; i < 256; i++) filtered[i] = vkList.Length == 0;
        foreach (var vk in vkList) filtered[vk & 0xFF] = true;

        new Thread(LogWriter) { IsBackground = true }.Start();

        loopThread = GetCurrentThreadId();
        Console.CancelKeyPress += (s, e) => { e.Cancel = true; PostThreadMessage(loopThread, WM_QUIT, IntPtr.Zero, IntPtr.Zero); };

        hook = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(null), 0);
        if (hook == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());

        MSG m;
        while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }

        UnhookWindowsHookEx(hook);
        Console.WriteLine("Stopped. Dropped {0} chatter press(es) this session.", totalDrops);
    }
}
'@

if (-not ('ChatterFilter' -as [type])) {
    Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms
}

$vks = foreach ($name in $Keys) {
    foreach ($part in ($name -split ',')) {
        if ($part.Trim()) { [int][System.Windows.Forms.Keys]::Parse([System.Windows.Forms.Keys], $part.Trim(), $true) }
    }
}
$vks = @($vks)

$scope = if ($vks.Count) { ($Keys -join ', ') } else { 'all keys' }
Write-Host "Chatter filter running: $scope, window $ThresholdMs ms. Press Ctrl+C or close this window to stop." -ForegroundColor Green
if ($LogFile) {
    Write-Host "Logging dropped presses to $LogFile"
    Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  started: $scope, window $ThresholdMs ms" -f (Get-Date))
}

[ChatterFilter]::Run($ThresholdMs, [int[]]$vks, $LogFile)
