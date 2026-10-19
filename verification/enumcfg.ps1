# enumcfg.ps1 - run config.exe on a private desktop, dump all window/control texts
param(
  [Parameter(Mandatory=$true)][string]$ExePath,
  [string]$WorkDir = "",
  [string]$DeskName = "mutest",
  [string]$ShotPath = ""
)
$ErrorActionPreference = 'Stop'
Get-Process config -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill() } catch {} }
Start-Sleep -Milliseconds 500
Write-Host "STAGE1: before Add-Type"
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public class EC {
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr CreateDesktopW([MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr dev, IntPtr devmode, uint flags, uint access, IntPtr attrs);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SetThreadDesktop(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool CloseDesktop(IntPtr h);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct STARTUPINFO { public int cb; public string lpReserved; public string lpDesktop; public string lpTitle; public int dwX,dwY,dwXSize,dwYSize,dwXCountChars,dwYCountChars,dwFillAttribute,dwFlags; public short wShowWindow,cbReserved2; public IntPtr lpReserved2; public IntPtr hStdInput,hStdOutput,hStdError; }
  [StructLayout(LayoutKind.Sequential)] public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool CreateProcessW(string app, string cmd, IntPtr psa, IntPtr tsa, bool inh, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, ref PROCESS_INFORMATION pi);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern int SendMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll", EntryPoint="SendMessageW", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageW2(IntPtr h, uint msg, IntPtr w, StringBuilder l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll", EntryPoint="GetWindowRect")] public static extern bool GetWindowRect2(IntPtr h, out RECT r);
  [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowDC(IntPtr h);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr hdc);
  public static string ShotPath = "";
  public static List<string> Log = new List<string>();
  public static string CfgExe, CfgWd, CfgDesk;
  static bool IsConfigPid(uint pid) {
    try { var pr = System.Diagnostics.Process.GetProcessById((int)pid); return pr != null && pr.ProcessName == "config"; }
    catch { return false; }
  }
  public static void ThreadMain() {
    try { Run(CfgExe, CfgWd, CfgDesk); }
    catch (Exception e) { Log.Add("THREAD EXCEPTION: " + e.ToString()); }
  }
  static int CountBright(System.Drawing.Bitmap bmp, int w, int hh) {
    int bright = 0;
    for (int yy = 0; yy < hh; yy += 3) for (int xx = 0; xx < w; xx += 3) {
      System.Drawing.Color c = bmp.GetPixel(xx, yy);
      if (c.R > 180 || c.G > 180 || c.B > 180) bright++;
    }
    return bright;
  }
  static void DumpWnd(IntPtr h, string indent) {
    StringBuilder wt = new StringBuilder(512); GetWindowTextW(h, wt, 512);
    StringBuilder wc = new StringBuilder(256); GetClassNameW(h, wc, 256);
    string cn = wc.ToString();
    Log.Add(indent + cn + " | [" + wt.ToString() + "] vis=" + IsWindowVisible(h) + " hwnd=" + h.ToString("X"));
    if (cn.IndexOf("COMBOBOX") >= 0) {
      int cnt = SendMessageW(h, 0x0146, IntPtr.Zero, IntPtr.Zero);
      for (int i = 0; i < cnt && i < 40; i++) {
        StringBuilder it = new StringBuilder(256);
        SendMessageW2(h, 0x0148, (IntPtr)i, it);
        Log.Add(indent + "  item[" + i + "] " + it.ToString());
      }
    }
    EnumChildWindows(h, delegate(IntPtr ch, IntPtr l) { DumpWnd(ch, indent + "  "); return true; }, IntPtr.Zero);
  }
  public static void Run(string exe, string wd, string deskName) {
    IntPtr desk = CreateDesktopW(deskName, IntPtr.Zero, IntPtr.Zero, 0, 0x01FF, IntPtr.Zero);
    if (desk == IntPtr.Zero) { Log.Add("CreateDesktop failed " + Marshal.GetLastWin32Error()); return; }
    if (!SetThreadDesktop(desk)) { Log.Add("SetThreadDesktop failed " + Marshal.GetLastWin32Error()); return; }
    STARTUPINFO si = new STARTUPINFO(); si.cb = Marshal.SizeOf(typeof(STARTUPINFO)); si.lpDesktop = "WinSta0\\" + deskName;
    PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
    if (!CreateProcessW(exe, null, IntPtr.Zero, IntPtr.Zero, false, 0, IntPtr.Zero, wd, ref si, ref pi)) {
      Log.Add("CreateProcess failed " + Marshal.GetLastWin32Error()); CloseDesktop(desk); return;
    }
    Log.Add("launched pid=" + pi.dwProcessId);
    System.Threading.Thread.Sleep(9000);
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint wp; GetWindowThreadProcessId(h, out wp);
      if (IsWindowVisible(h) && IsConfigPid(wp)) DumpWnd(h, "");
      return true;
    }, IntPtr.Zero);
    if (ShotPath.Length > 0) {
      int idx = 0;
      EnumWindows(delegate(IntPtr h, IntPtr l) {
        uint wp; GetWindowThreadProcessId(h, out wp);
        if (IsWindowVisible(h) && IsConfigPid(wp)) {
          RECT r; GetWindowRect2(h, out r);
          int w = r.R - r.L, hh = r.B - r.T;
          int my = idx; idx++;
          try {
            System.Drawing.Bitmap bmp = new System.Drawing.Bitmap(w, hh);
            string how = "";
            using (System.Drawing.Graphics g = System.Drawing.Graphics.FromImage(bmp)) {
              IntPtr hdc = g.GetHdc();
              if (PrintWindow(h, hdc, 2)) how = "PW2";
              if (PrintWindow(h, hdc, 0)) how = how + "+PW0";
              g.ReleaseHdc(hdc);
            }
            int bright = CountBright(bmp, w, hh);
            if (bright == 0) {
              try {
                using (System.Drawing.Graphics g = System.Drawing.Graphics.FromImage(bmp)) {
                  g.CopyFromScreen(r.L, r.T, 0, 0, new System.Drawing.Size(w, hh));
                }
                bright = CountBright(bmp, w, hh);
                if (bright > 0) how = "CFS";
              } catch (Exception e2) { Log.Add("cfs err " + e2.Message); }
            }
            string p = ShotPath + "." + my + ".bmp";
            bmp.Save(p, System.Drawing.Imaging.ImageFormat.Bmp);
            Log.Add("saved print " + p + " rect=" + w + "x" + hh + " how=" + how + " brightpx=" + bright);
          } catch (Exception e) { Log.Add("shot err " + e.Message); }
        }
        return true;
      }, IntPtr.Zero);
    }
    try {
      foreach (System.Diagnostics.Process pc in System.Diagnostics.Process.GetProcessesByName("config"))
        try { pc.Kill(); } catch {}
    } catch {}
    System.Threading.Thread.Sleep(300);
    CloseDesktop(desk);
    Log.Add("done");
  }
}
"@
[EC]::CfgExe = [System.IO.Path]::GetFullPath($ExePath)
[EC]::CfgWd = if ($WorkDir) { $WorkDir } else { [System.IO.Path]::GetDirectoryName($ExePath) }
[EC]::CfgDesk = $DeskName
[EC]::ShotPath = if ($ShotPath) { [System.IO.Path]::GetFullPath($ShotPath) } else { "" }
Write-Host "STAGE2: Add-Type ok, starting thread"
$ts = [System.Delegate]::CreateDelegate([System.Threading.ThreadStart], [EC], 'ThreadMain')
$th = New-Object System.Threading.Thread($ts)
$th.Start()
Write-Host "STAGE3: thread started, joining"
$th.Join()
Write-Host "STAGE4: join returned, dumping log"
[EC]::Log | ForEach-Object { Write-Output $_ }
