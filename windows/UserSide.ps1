# Runs INSIDE the target user's interactive session (launched by a temporary
# "Interactive" scheduled task from HwTest.Common.ps1 / Invoke-UserTask). Non-elevated.
#   -Action StartAgent   : start openlogi-agent.exe with OPENLOGI_LOG set (so hooks/tray live on the real desktop)
#   -Action StartProcess : start an arbitrary exe (used by the Options+ restore)
#   -Action Inject       : SendInput mouse motion to a screen edge, write timestamps as JSON
# Windows PowerShell 5.1 compatible.
param(
    [Parameter(Mandatory = $true)][ValidateSet('StartAgent', 'StartProcess', 'Inject')][string]$Action,
    [string]$Exe,
    [string]$LogFilter,
    [string]$OutFile,
    [ValidateSet('left', 'right', 'top', 'bottom')][string]$Edge = 'right',
    [int]$ApproachPx = 300,
    [int]$Steps = 20,
    [int]$StepMs = 8,
    [int]$DwellMs = 600
)
$ErrorActionPreference = 'Stop'

function Write-Out([string]$Text) { if ($OutFile) { [IO.File]::WriteAllText($OutFile, $Text, (New-Object Text.UTF8Encoding($false))) } }

if ($Action -eq 'StartAgent') {
    try {
        $env:OPENLOGI_LOG = $LogFilter
        $p = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe) -PassThru
        Write-Out ('{"ok":true,"pid":' + $p.Id + '}')
    }
    catch { Write-Out ('{"ok":false,"error":' + (ConvertTo-Json ([string]$_)) + '}') }
    exit 0
}
if ($Action -eq 'StartProcess') {
    try { Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe) | Out-Null } catch {}
    exit 0
}

# ---------------------------------------------------------------- Inject (SendInput)
# NOTE: OpenLogi's WH_MOUSE_LL hook drops injected motion before the Flow edge detector sees it
# (crates/openlogi-hook/src/windows/hook.rs: `if data.flags & LLMHF_INJECTED != 0 { return None; }`).
# This probe is kept to measure that fact on the real machine; a crossing is NOT expected.
$src = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
public static class HtInject {
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr lprc, IntPtr data);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
    [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO info);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    public static long Now() { return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; }
    public static List<RECT> Monitors() {
        var list = new List<RECT>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate (IntPtr h, IntPtr dc, IntPtr r, IntPtr d) {
            var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
            if (GetMonitorInfo(h, ref mi)) { list.Add(mi.rcMonitor); }
            return true; }, IntPtr.Zero);
        return list;
    }
    static uint sent = 0, failed = 0;
    static int vx, vy, vw, vh;
    static void Move(int x, int y) {
        var inp = new INPUT[1];
        inp[0].type = 0; // INPUT_MOUSE
        inp[0].mi.dx = (int)Math.Round((x - vx) * 65535.0 / Math.Max(1, vw - 1));
        inp[0].mi.dy = (int)Math.Round((y - vy) * 65535.0 / Math.Max(1, vh - 1));
        inp[0].mi.dwFlags = 0x0001 | 0x8000 | 0x4000; // MOVE | ABSOLUTE | VIRTUALDESK
        uint r = SendInput(1, inp, Marshal.SizeOf(typeof(INPUT)));
        if (r == 1) sent++; else failed++;
    }
    public static string Run(string edge, int approach, int steps, int stepMs, int dwellMs) {
        SetThreadDpiAwarenessContext(new IntPtr(-4)); // PER_MONITOR_AWARE_V2: physical pixels, same space as MSLLHOOKSTRUCT.pt
        vx = GetSystemMetrics(76); vy = GetSystemMetrics(77); vw = GetSystemMetrics(78); vh = GetSystemMetrics(79);
        var mons = Monitors();
        if (mons.Count == 0) return "{\"ok\":false,\"error\":\"no monitors\"}";
        RECT m = mons[0];
        foreach (var r in mons) {
            if (edge == "right" && r.Right > m.Right) m = r;
            if (edge == "left" && r.Left < m.Left) m = r;
            if (edge == "top" && r.Top < m.Top) m = r;
            if (edge == "bottom" && r.Bottom > m.Bottom) m = r;
        }
        int cx = (m.Left + m.Right) / 2, cy = (m.Top + m.Bottom) / 2;
        int tx = cx, ty = cy, sx = cx, sy = cy;
        if (edge == "right") { tx = m.Right - 1; sx = tx - approach; }
        if (edge == "left") { tx = m.Left; sx = tx + approach; }
        if (edge == "top") { ty = m.Top; sy = ty + approach; }
        if (edge == "bottom") { ty = m.Bottom - 1; sy = ty - approach; }
        POINT before; GetCursorPos(out before);
        long tStart = Now(), tEdge = 0;
        for (int i = 0; i <= steps; i++) {
            int x = sx + (tx - sx) * i / steps, y = sy + (ty - sy) * i / steps;
            Move(x, y);
            if (i == steps) tEdge = Now();
            Thread.Sleep(stepMs);
        }
        long dwellEnd = Now() + dwellMs;
        while (Now() < dwellEnd) { Move(tx, ty); Thread.Sleep(16); }
        long tEnd = Now();
        POINT after; GetCursorPos(out after);
        return "{\"ok\":" + (failed == 0 ? "true" : "false") + ",\"method\":\"SendInput\",\"edge\":\"" + edge + "\",\"sent\":" + sent + ",\"failed\":" + failed +
            ",\"t_start_ms\":" + tStart + ",\"t_edge_ms\":" + tEdge + ",\"t_end_ms\":" + tEnd +
            ",\"target\":[" + tx + "," + ty + "],\"cursor_before\":[" + before.X + "," + before.Y + "],\"cursor_after\":[" + after.X + "," + after.Y + "]}";
    }
}
'@
try {
    Add-Type -TypeDefinition $src -Language CSharp
    Write-Out ([HtInject]::Run($Edge, $ApproachPx, $Steps, $StepMs, $DwellMs))
}
catch { Write-Out ('{"ok":false,"error":' + (ConvertTo-Json ([string]$_)) + '}') }
exit 0
