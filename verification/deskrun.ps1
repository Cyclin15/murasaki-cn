# deskrun.ps1 - run a game exe on a private desktop, send keys, capture screenshots
# Steps spec (semicolon-separated):
#   k<secs>  - wait up to N secs for the game window to appear
#   w<secs>  - sleep
#   c<name>  - capture window client to <name>.png in OutDir
#   z|x|esc|up|down|left|right - key press (hold 120ms)
#   f        - try to force focus
param(
  [Parameter(Mandatory=$true)][string]$ExePath,
  [Parameter(Mandatory=$true)][string]$WorkDir,
  [Parameter(Mandatory=$true)][string]$OutDir,
  [string]$Steps = "k30;w12;c;t0",
  [string]$DeskName = "mutest",
  [string]$DllPath = ""
)
$ErrorActionPreference = 'Stop'

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Imaging;
using System.Text;
using System.Threading;
using System.Collections.Generic;

public class DR {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr CreateDesktopW([MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr dev, IntPtr devmode, uint flags, uint access, IntPtr attrs);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SetThreadDesktop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);

  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct STARTUPINFO { public int cb; public string lpReserved; public string lpDesktop; public string lpTitle; public int dwX,dwY,dwXSize,dwYSize,dwXCountChars,dwYCountChars,dwFillAttribute,dwFlags; public short wShowWindow,cbReserved2; public IntPtr lpReserved2; public IntPtr hStdInput,hStdOutput,hStdError; }
  [StructLayout(LayoutKind.Sequential)] public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool CreateProcessW(string app, string cmd, IntPtr psa, IntPtr tsa, bool inh, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, ref PROCESS_INFORMATION pi);

  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll", EntryPoint="GetWindowRect")] public static extern bool GetWindowRect2(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowDC(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr hdc);
  [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
  [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint act, uint param, IntPtr v1, uint winini);
  [DllImport("user32.dll", EntryPoint="SystemParametersInfo")] public static extern bool SystemParametersInfoGet(uint act, uint param, ref uint v1, uint winini);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
  [DllImport("kernel32.dll")] public static extern IntPtr GetModuleHandleW([MarshalAs(UnmanagedType.LPWStr)] string name);
  [DllImport("kernel32.dll")] public static extern IntPtr GetProcAddress(IntPtr mod, [MarshalAs(UnmanagedType.LPStr)] string name);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr CreateRemoteThread(IntPtr hProc, IntPtr sa, uint sz, IntPtr start, IntPtr param, uint flags, out uint tid);
  [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeThread(IntPtr h, out uint code);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr addr, UIntPtr size, uint alloc, uint prot);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteProcessMemory(IntPtr h, IntPtr base_, byte[] buf, UIntPtr size, out IntPtr written);
  [DllImport("kernel32.dll")] public static extern uint ResumeThread(IntPtr h);
  public static string CfgDll;
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  public static void MouseClick() {
    INPUT[] inp = new INPUT[2];
    inp[0].type = 0; inp[0].u.mi.dwFlags = 0x0002; // LEFTDOWN
    inp[1].type = 0; inp[1].u.mi.dwFlags = 0x0004; // LEFTUP
    SendInput(2, inp, Marshal.SizeOf(typeof(INPUT)));
  }
  [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int n);

  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }

  [StructLayout(LayoutKind.Explicit)]
  public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
  [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);

  [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inh, int pid);
  [DllImport("kernel32.dll")] public static extern bool ReadProcessMemory(IntPtr h, IntPtr baseAddr, byte[] buf, UIntPtr size, out IntPtr read);
  [DllImport("kernel32.dll")] public static extern Int32 VirtualQueryEx(IntPtr h, IntPtr addr, ref MBI mbi, uint len);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct MBI { public IntPtr BaseAddress; public IntPtr AllocationBase; public uint AllocationProtect; public IntPtr RegionSize; public uint State; public uint Protect; public uint Type; }

  public static void MemDump(int pid, string outdir, string tag) {
    IntPtr h = OpenProcess(0x0410 | 0x0010, false, pid); // QUERY_INFORMATION | VM_READ
    if (h == IntPtr.Zero) { Log.Add("memdump: OpenProcess failed " + Marshal.GetLastWin32Error()); return; }
    System.IO.Directory.CreateDirectory(outdir);
    var manifest = new List<string>();
    ulong addr = 0; int saved = 0; long total = 0;
    while (true) {
      MBI mbi = new MBI();
      if (VirtualQueryEx(h, (IntPtr)addr, ref mbi, (uint)Marshal.SizeOf(typeof(MBI))) == 0) break;
      long size = (long)mbi.RegionSize;
      bool readable = mbi.State == 0x1000 && (mbi.Protect & 0x100) == 0 && (mbi.Protect & 0xEE) != 0; // committed, no guard, readable-ish
      if (readable && size >= 0x10000 && size <= 0x4000000) {
        byte[] buf = new byte[size];
        IntPtr got;
        if (ReadProcessMemory(h, mbi.BaseAddress, buf, (UIntPtr)size, out got) && got.ToInt64() == size) {
          // variance check: sample bytes
          int dist = 0; byte first = buf[0];
          for (long i = 0; i < size; i += 4096) { if (buf[i] != first) { dist++; } }
          if (dist >= 8) {
            string f = System.IO.Path.Combine(outdir, tag + "_" + ((long)mbi.BaseAddress).ToString("x") + "_" + size.ToString("x") + ".bin");
            System.IO.File.WriteAllBytes(f, buf);
            manifest.Add(((long)mbi.BaseAddress).ToString("x") + " size=" + size + " prot=" + mbi.Protect.ToString("x") + " type=" + mbi.Type);
            saved++; total += size;
          }
        }
      }
      addr = (ulong)((long)mbi.BaseAddress + size);
      if (addr >= 0x7fffffffffff) break;
    }
    CloseHandle(h);
    System.IO.File.WriteAllLines(System.IO.Path.Combine(outdir, tag + "_manifest.txt"), manifest.ToArray());
    Log.Add("memdump " + tag + ": " + saved + " regions, " + (total/1048576) + "MB");
  }

  public static List<string> Log = new List<string>();
  public static string CfgExe, CfgWd, CfgOut, CfgSteps, CfgDesk;

  public static void ThreadMain() {
    try { RunAll(CfgExe, CfgWd, CfgOut, CfgSteps, CfgDesk); }
    catch (Exception e) { Log.Add("FATAL: " + e.Message); }
  }

  public static void RunAll(string exe, string wd, string outdir, string steps, string deskName) {
    RunAll2(exe, wd, outdir, steps, deskName, CfgDll);
  }
  public static void RunAll2(string exe, string wd, string outdir, string steps, string deskName, string dllPath) {
    SetProcessDPIAware();
    IntPtr desk = CreateDesktopW(deskName, IntPtr.Zero, IntPtr.Zero, 0, 0x01FF, IntPtr.Zero);
    if (desk == IntPtr.Zero) { Log.Add("CreateDesktop failed: " + Marshal.GetLastWin32Error()); return; }
    if (!SetThreadDesktop(desk)) { Log.Add("SetThreadDesktop failed: " + Marshal.GetLastWin32Error()); CloseDesktop(desk); return; }
    Log.Add("desktop ok: " + deskName);

    STARTUPINFO si = new STARTUPINFO();
    si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
    si.lpDesktop = "WinSta0\\" + deskName;
    PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
    uint flags = 0;
    if (dllPath != null && dllPath.Length > 0) flags |= 0x4; // CREATE_SUSPENDED
    if (!CreateProcessW(exe, null, IntPtr.Zero, IntPtr.Zero, false, flags, IntPtr.Zero, wd, ref si, ref pi)) {
      Log.Add("CreateProcess failed: " + Marshal.GetLastWin32Error()); CloseDesktop(desk); return;
    }
    int gamePid = pi.dwProcessId;
    Log.Add("launched pid=" + gamePid);
    if (flags != 0) {
      // clean stale control files
      try {
        System.IO.File.Delete(System.IO.Path.Combine(wd, "padstate.txt"));
        System.IO.File.Delete(System.IO.Path.Combine(wd, "shot.flag"));
        System.IO.File.Delete(System.IO.Path.Combine(wd, "inj_ready.txt"));
        System.IO.File.Delete(System.IO.Path.Combine(wd, "inj_log.txt"));
      } catch {}
      foreach (string old in System.IO.Directory.GetFiles(wd, "shot_*.bmp")) { try { System.IO.File.Delete(old); } catch {} }
      IntPtr hProc = OpenProcess(0x1F0FFF, false, (int)gamePid);
      if (hProc == IntPtr.Zero) { Log.Add("inject: OpenProcess failed " + Marshal.GetLastWin32Error()); }
      else {
        byte[] dllBytes = System.Text.Encoding.ASCII.GetBytes(dllPath + "\0");
        IntPtr mem = VirtualAllocEx(hProc, IntPtr.Zero, (UIntPtr)dllBytes.Length, 0x3000, 0x04);
        IntPtr written;
        if (mem == IntPtr.Zero || !WriteProcessMemory(hProc, mem, dllBytes, (UIntPtr)dllBytes.Length, out written)) {
          Log.Add("inject: write failed " + Marshal.GetLastWin32Error());
        } else {
          IntPtr k32 = GetModuleHandleW("kernel32.dll");
          IntPtr llA = GetProcAddress(k32, "LoadLibraryA");
          uint tid;
          IntPtr hTh = CreateRemoteThread(hProc, IntPtr.Zero, 0, llA, mem, 0, out tid);
          if (hTh == IntPtr.Zero) { Log.Add("inject: remote thread failed " + Marshal.GetLastWin32Error()); }
          else {
            WaitForSingleObject(hTh, 10000);
            uint ec = 0; GetExitCodeThread(hTh, out ec);
            CloseHandle(hTh);
            Log.Add("inject: LoadLibrary exit=" + ec);
            string ready = System.IO.Path.Combine(wd, "inj_ready.txt");
            DateTime dl = DateTime.Now.AddSeconds(15);
            while (DateTime.Now < dl && !System.IO.File.Exists(ready)) Thread.Sleep(200);
            Log.Add("inject: ready=" + System.IO.File.Exists(ready));
          }
        }
        CloseHandle(hProc);
      }
      ResumeThread(pi.hThread);
      Log.Add("resumed");
    }

    Dictionary<string,ushort> scans = new Dictionary<string,ushort>();
    scans["z"]=0x2C; scans["x"]=0x2D; scans["esc"]=0x01; scans["enter"]=0x1C;
    scans["space"]=0x39; scans["lshift"]=0x2A; scans["tab"]=0x0F;
    scans["up"]=0x48; scans["down"]=0x50; scans["left"]=0x4B; scans["right"]=0x4D;

    try {
      foreach (string step in steps.Split(';')) {
        string s = step.Trim();
        if (s.Length == 0) continue;
        char c = s[0]; string arg = s.Substring(1);
        if (c == 'k') {
          DateTime dl = DateTime.Now.AddSeconds(double.Parse(arg));
          IntPtr h = IntPtr.Zero;
          while (DateTime.Now < dl && h == IntPtr.Zero) {
            h = FindWnd((uint)gamePid);
            if (h == IntPtr.Zero) Thread.Sleep(500);
          }
          if (h != IntPtr.Zero) Log.Add("window: " + WndInfo(h));
          else Log.Add("NO WINDOW FOUND");
        } else if (c == 'w') {
          Thread.Sleep((int)(double.Parse(arg) * 1000));
        } else if (c == 'c') {
          IntPtr h = FindWnd((uint)gamePid);
          if (h == IntPtr.Zero) Log.Add("capture " + arg + ": no window");
          else { Cap(h, System.IO.Path.Combine(outdir, arg + ".png")); Log.Add("captured " + arg); }
        } else if (c == 'f') {
          IntPtr h = FindWnd((uint)gamePid);
          if (h != IntPtr.Zero) { ForceFocus(h); Log.Add("focus forced"); }
        } else if (c == 'g') {
          IntPtr h = FindWnd((uint)gamePid);
          if (h != IntPtr.Zero) {
            uint pid2; uint gt = GetWindowThreadProcessId(h, out pid2);
            uint me = GetCurrentThreadId();
            AttachThreadInput(me, gt, true);
            bool fg = SetForegroundWindow(h);
            SetFocus(h);
            AttachThreadInput(me, gt, false);
            Log.Add("setforeground=" + fg);
          }
        } else if (c == 'G') {
          IntPtr h = FindWnd((uint)gamePid);
          if (h != IntPtr.Zero) {
            uint pid2; uint gt = GetWindowThreadProcessId(h, out pid2);
            uint me = GetCurrentThreadId();
            // trick 1: ALT keypress grants SetForegroundWindow rights
            KeyDown(0x38, false); Thread.Sleep(80);
            AttachThreadInput(me, gt, true);
            bool fg1 = SetForegroundWindow(h);
            KeyUp(0x38, false);
            Thread.Sleep(300);
            IntPtr fgA = GetForegroundWindow();
            bool ok1 = (fgA == h);
            // trick 2: zero the foreground lock timeout
            uint oldLock = 0;
            SystemParametersInfoGet(0x2000, 0, ref oldLock, 0);   // SPI_GETFOREGROUNDLOCKTIMEOUT
            SystemParametersInfo(0x2001, 0, IntPtr.Zero, 0x01|0x02); // SPI_SETFOREGROUNDLOCKTIMEOUT
            bool fg2 = SetForegroundWindow(h);
            SystemParametersInfo(0x2001, 0, (IntPtr)(long)oldLock, 0x01|0x02); // restore
            Thread.Sleep(300);
            IntPtr fgB = GetForegroundWindow();
            bool ok2 = (fgB == h);
            SetFocus(h);
            AttachThreadInput(me, gt, false);
            Log.Add("G: alt-trick setfg=" + fg1 + " fgIsGame=" + ok1 + " | lockfix setfg=" + fg2 + " fgIsGame=" + ok2 + " oldLock=" + oldLock);
          }
        } else if (c == 'C') {
          IntPtr h = FindWnd((uint)gamePid);
          if (h != IntPtr.Zero) {
            RECT r; GetWindowRect2(h, out r);
            int cx=(r.L+r.R)/2, cy=(r.T+r.B)/2;
            bool sp = SetCursorPos(cx, cy);
            POINT p1; GetCursorPos(out p1);
            // absolute move via SendInput
            INPUT[] mv = new INPUT[1];
            mv[0].type = 0; mv[0].u.mi.dx = (cx * 65535) / GetSystemMetrics(0); mv[0].u.mi.dy = (cy * 65535) / GetSystemMetrics(1);
            mv[0].u.mi.dwFlags = 0x0001 | 0x8000; // MOVE | ABSOLUTE
            uint src = SendInput(1, mv, Marshal.SizeOf(typeof(INPUT)));
            Thread.Sleep(200);
            POINT p2; GetCursorPos(out p2);
            Log.Add("C: rect=" + r.L + "," + r.T + "-" + r.R + "," + r.B + " setcursor=" + sp + " after=" + p1.X + "," + p1.Y + " sendinput=" + src + " now=" + p2.X + "," + p2.Y);
          }
        } else if (c == 'V') {
          short z0 = GetAsyncKeyState(0x5A);
          short lb0 = GetAsyncKeyState(0x01);
          KeyDown(0x2C, false);
            Thread.Sleep(150);
          short z1 = GetAsyncKeyState(0x5A);
          KeyUp(0x2C, false);
          Thread.Sleep(100);
          short z2 = GetAsyncKeyState(0x5A);
          Log.Add("V: async Z before=" + z0.ToString("X") + " down=" + z1.ToString("X") + " up=" + z2.ToString("X") + " lbtn=" + lb0.ToString("X"));
        } else if (c == 'R') {
          // CreateRemoteThread in game process calling SetForegroundWindow(hwnd)
          IntPtr h = FindWnd((uint)gamePid);
          if (h != IntPtr.Zero) {
            IntPtr hProc = OpenProcess((int)(0x0002|0x0008|0x0010|0x0020|0x0400), false, (int)gamePid);
            if (hProc == IntPtr.Zero) { Log.Add("R: OpenProcess failed " + Marshal.GetLastWin32Error()); }
            else {
              IntPtr user32 = GetModuleHandleW("user32.dll");
              IntPtr sfgw = GetProcAddress(user32, "SetForegroundWindow");
              uint tid;
              IntPtr hTh = CreateRemoteThread(hProc, IntPtr.Zero, 0, sfgw, h, 0, out tid);
              if (hTh == IntPtr.Zero) { Log.Add("R: CreateRemoteThread failed " + Marshal.GetLastWin32Error()); }
              else {
                WaitForSingleObject(hTh, 3000);
                uint ec = 0; GetExitCodeThread(hTh, out ec);
                CloseHandle(hTh);
                Thread.Sleep(300);
                IntPtr fg = GetForegroundWindow();
                Log.Add("R: remote SetForegroundWindow exit=" + ec + " fgIsGame=" + (fg == h));
              }
              CloseHandle(hProc);
            }
          }
        } else if (c == 'b') {
          // pad buttons: b<hex>[,<holdms>] — writes padstate.txt in game dir
          string[] parts = arg.Split(',');
          string padFile = System.IO.Path.Combine(wd, "padstate.txt");
          System.IO.File.WriteAllText(padFile, parts[0]);
          if (parts.Length > 1) {
            Thread.Sleep(int.Parse(parts[1]));
            System.IO.File.WriteAllText(padFile, "0");
          }
          Log.Add("pad " + parts[0]);
        } else if (c == 'n') {
          // shot: create shot.flag, wait for a new bmp, copy to OutDir\<name>.bmp
          string padFile = System.IO.Path.Combine(wd, "shot.flag");
          string[] before = System.IO.Directory.GetFiles(wd, "shot_*.bmp");
          System.IO.File.WriteAllText(padFile, "1");
          string newest = null; DateTime dl = DateTime.Now.AddSeconds(8);
          while (DateTime.Now < dl) {
            string[] after = System.IO.Directory.GetFiles(wd, "shot_*.bmp");
            if (after.Length > before.Length) { newest = after[after.Length-1]; break; }
            Thread.Sleep(150);
          }
          if (newest == null) { Log.Add("shot " + arg + ": NO BMP PRODUCED"); }
          else {
            string dst = System.IO.Path.Combine(outdir, arg + ".bmp");
            System.IO.File.Copy(newest, dst, true);
            Log.Add("shot " + arg + " <- " + System.IO.Path.GetFileName(newest));
          }
        } else if (c == 'j') {
          // late inject into the running process
          IntPtr hProc = OpenProcess(0x1F0FFF, false, (int)gamePid);
          if (hProc == IntPtr.Zero) { Log.Add("late-inject: OpenProcess failed " + Marshal.GetLastWin32Error()); }
          else {
            byte[] dllBytes = System.Text.Encoding.ASCII.GetBytes(dllPath + "\0");
            IntPtr mem = VirtualAllocEx(hProc, IntPtr.Zero, (UIntPtr)dllBytes.Length, 0x3000, 0x04);
            IntPtr written;
            if (mem == IntPtr.Zero || !WriteProcessMemory(hProc, mem, dllBytes, (UIntPtr)dllBytes.Length, out written)) {
              Log.Add("late-inject: write failed " + Marshal.GetLastWin32Error());
            } else {
              IntPtr k32 = GetModuleHandleW("kernel32.dll");
              IntPtr llA = GetProcAddress(k32, "LoadLibraryA");
              uint tid;
              IntPtr hTh = CreateRemoteThread(hProc, IntPtr.Zero, 0, llA, mem, 0, out tid);
              if (hTh == IntPtr.Zero) { Log.Add("late-inject: remote thread failed " + Marshal.GetLastWin32Error()); }
              else {
                WaitForSingleObject(hTh, 10000);
                uint ec = 0; GetExitCodeThread(hTh, out ec);
                CloseHandle(hTh);
                Log.Add("late-inject: LoadLibrary exit=" + ec);
                string ready = System.IO.Path.Combine(wd, "inj_ready.txt");
                DateTime dl = DateTime.Now.AddSeconds(15);
                while (DateTime.Now < dl && !System.IO.File.Exists(ready)) Thread.Sleep(200);
                Log.Add("late-inject: ready=" + System.IO.File.Exists(ready));
              }
            }
            CloseHandle(hProc);
          }
        } else if (c == 'l') {
          // remote-load test: l<dllpath> -> CreateRemoteThread LoadLibraryA
          IntPtr hProc = OpenProcess(0x1F0FFF, false, (int)gamePid);
          if (hProc == IntPtr.Zero) { Log.Add("loadtest: OpenProcess failed"); }
          else {
            byte[] dllBytes = System.Text.Encoding.ASCII.GetBytes(arg + "\0");
            IntPtr mem = VirtualAllocEx(hProc, IntPtr.Zero, (UIntPtr)dllBytes.Length, 0x3000, 0x04);
            IntPtr written;
            WriteProcessMemory(hProc, mem, dllBytes, (UIntPtr)dllBytes.Length, out written);
            IntPtr k32 = GetModuleHandleW("kernel32.dll");
            IntPtr llA = GetProcAddress(k32, "LoadLibraryA");
            uint tid;
            IntPtr hTh = CreateRemoteThread(hProc, IntPtr.Zero, 0, llA, mem, 0, out tid);
            WaitForSingleObject(hTh, 10000);
            uint ec = 0; GetExitCodeThread(hTh, out ec);
            CloseHandle(hTh);
            Log.Add("loadtest " + arg + " -> 0x" + ec.ToString("X"));
            CloseHandle(hProc);
          }
        } else if (c == 'M') {
          try { MemDump(gamePid, System.IO.Path.Combine(outdir, "mem"), arg); }
          catch (Exception e) { Log.Add("memdump err: " + e.Message); }
        } else if (c == 'a') {
          IntPtr h = FindWnd((uint)gamePid);
          if (h != IntPtr.Zero) {
            PostMessageW(h, 0x001C, (IntPtr)1, IntPtr.Zero);   // WM_ACTIVATEAPP: active
            PostMessageW(h, 0x0006, (IntPtr)1, IntPtr.Zero);   // WM_ACTIVATE: WA_ACTIVE
            ForceFocus(h);
            Log.Add("activation sent");
          }
        } else if (c == 'e') {
          // enumerate all top-level windows of the game process (dialogs incl.)
          EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint wp; GetWindowThreadProcessId(h, out wp);
            if (wp == (uint)gamePid) {
              StringBuilder wb = new StringBuilder(256); GetWindowTextW(h, wb, 256);
              StringBuilder wc = new StringBuilder(256); GetClassNameW(h, wc, 256);
              RECT r; GetWindowRect2(h, out r);
              Log.Add("wnd: hwnd=" + h.ToString("X") + " class=" + wc.ToString() + " title=[" + wb.ToString() +
                      "] rect=" + r.L + "," + r.T + "-" + r.R + "," + r.B + " vis=" + IsWindowVisible(h));
            }
            return true;
          }, IntPtr.Zero);
        } else if (c == 'q') {
          IntPtr fg = GetForegroundWindow();
          IntPtr h = FindWnd((uint)gamePid);
          uint fgp = 0;
          string fgi = "none";
          if (fg != IntPtr.Zero) { uint t; GetWindowThreadProcessId(fg, out t); fgp = t; fgi = WndInfo(fg); }
          bool isGame = (fg == h);
          POINT pt; GetCursorPos(out pt);
          Log.Add("probe: fg=" + (fg==IntPtr.Zero?"NULL":fgi) + " isGame=" + isGame + " cursor=" + pt.X + "," + pt.Y);
        } else if (c == 'm') {
          // click at window center (or x,y if given)
          IntPtr h = FindWnd((uint)gamePid);
          if (h == IntPtr.Zero) { Log.Add("click: no window"); }
          else {
            RECT r; GetWindowRect2(h, out r);
            int cx = (r.L + r.R) / 2, cy = (r.T + r.B) / 2;
            if (arg.Length > 0) { string[] xy = arg.Split(','); cx = r.L + int.Parse(xy[0]); cy = r.T + int.Parse(xy[1]); }
            SetCursorPos(cx, cy);
            Thread.Sleep(300);
            MouseClick();
            Thread.Sleep(400);
            Log.Add("clicked " + cx + "," + cy);
          }
        } else if (c == 'p') {
          try {
            var pr = System.Diagnostics.Process.GetProcessById(gamePid);
            Log.Add("cpu=" + pr.TotalProcessorTime + " ws=" + (pr.WorkingSet64/1024) + "K respond=" + pr.Responding);
          } catch (Exception e) { Log.Add("p: " + e.Message); }
        } else if (scans.ContainsKey(s)) {
          ushort sc = scans[s]; bool ext = (s=="up"||s=="down"||s=="left"||s=="right");
          KeyDown(sc, ext); Thread.Sleep(120); KeyUp(sc, ext); Thread.Sleep(260);
          Log.Add("key " + s);
        } else {
          Log.Add("unknown step: " + s);
        }
      }
    } finally {
      try { System.Diagnostics.Process.GetProcessById(gamePid).Kill(); } catch {}
      Thread.Sleep(500);
      CloseDesktop(desk);
      Log.Add("done");
    }
  }

  public static IntPtr FindWnd(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint wp; GetWindowThreadProcessId(h, out wp);
      if (wp == pid && IsWindowVisible(h)) {
        RECT r; GetClientRect(h, out r);
        if ((r.R - r.L) > 100 && (r.B - r.T) > 100) { found = h; return false; }
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static string WndInfo(IntPtr h) {
    StringBuilder sb = new StringBuilder(256); GetWindowTextW(h, sb, 256);
    StringBuilder sb2 = new StringBuilder(256); GetClassNameW(h, sb2, 256);
    return sb2.ToString() + " / " + sb.ToString();
  }

  public static void Cap(IntPtr h, string path) {
    RECT r; GetWindowRect2(h, out r);
    int w = r.R - r.L, hh = r.B - r.T;
    using (Bitmap b2 = new Bitmap(w, hh)) {
      IntPtr hdcWin = GetWindowDC(h);
      if (hdcWin != IntPtr.Zero) {
        using (Graphics g = Graphics.FromImage(b2)) {
          IntPtr hdc = g.GetHdc();
          BitBlt(hdc, 0, 0, w, hh, hdcWin, 0, 0, 0x00CC0020 | 0x40000000u);
          g.ReleaseHdc(hdc);
        }
        ReleaseDC(h, hdcWin);
      }
      b2.Save(path, ImageFormat.Png);
    }
    using (Bitmap b3 = new Bitmap(w, hh)) {
      using (Graphics g = Graphics.FromImage(b3)) {
        IntPtr hdc = g.GetHdc();
        PrintWindow(h, hdc, 0);
        g.ReleaseHdc(hdc);
      }
      b3.Save(path.Replace(".png", "_pw.png"), ImageFormat.Png);
    }
    int sw = GetSystemMetrics(0), sh = GetSystemMetrics(1);
    using (Bitmap bd = new Bitmap(sw, sh)) {
      IntPtr hdcScr = GetDC(IntPtr.Zero);
      if (hdcScr != IntPtr.Zero) {
        using (Graphics g = Graphics.FromImage(bd)) {
          IntPtr hdc = g.GetHdc();
          BitBlt(hdc, 0, 0, sw, sh, hdcScr, 0, 0, 0x00CC0020 | 0x40000000u);
          g.ReleaseHdc(hdc);
        }
        ReleaseDC(IntPtr.Zero, hdcScr);
      }
      bd.Save(path.Replace(".png", "_dt.png"), ImageFormat.Png);
    }
    Log.Add("cap " + System.IO.Path.GetFileName(path));
  }

  public static void KeyDown(ushort scan, bool ext) {
    INPUT[] inp = new INPUT[1];
    inp[0].type = 1; inp[0].u.ki.wScan = scan;
    inp[0].u.ki.dwFlags = 0x0008 | (ext ? 0x0001u : 0u);
    SendInput(1, inp, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void KeyUp(ushort scan, bool ext) {
    INPUT[] inp = new INPUT[1];
    inp[0].type = 1; inp[0].u.ki.wScan = scan;
    inp[0].u.ki.dwFlags = 0x0008 | 0x0002 | (ext ? 0x0001u : 0u);
    SendInput(1, inp, Marshal.SizeOf(typeof(INPUT)));
  }

  public static void ForceFocus(IntPtr h) {
    uint pid; uint guiThread = GetWindowThreadProcessId(h, out pid);
    uint me = GetCurrentThreadId();
    AttachThreadInput(me, guiThread, true);
    SetFocus(h);
    AttachThreadInput(me, guiThread, false);
  }
}
"@

[DR]::CfgExe   = [System.IO.Path]::GetFullPath($ExePath)
[DR]::CfgWd    = [System.IO.Path]::GetFullPath($WorkDir)
[DR]::CfgOut   = [System.IO.Path]::GetFullPath($OutDir)
[DR]::CfgSteps = $Steps
[DR]::CfgDesk  = $DeskName
[DR]::CfgDll   = if ($DllPath) { [System.IO.Path]::GetFullPath($DllPath) } else { "" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$ts = [System.Delegate]::CreateDelegate([System.Threading.ThreadStart], [DR], 'ThreadMain')
$th = New-Object System.Threading.Thread($ts)
$th.Start()
$th.Join()

[DR]::Log | ForEach-Object { Write-Host $_ }
