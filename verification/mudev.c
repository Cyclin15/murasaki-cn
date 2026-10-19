// mudev.c v4 - 32-bit DLL injected into mu.exe (DXLib 3.12e game)
// The game's D3D9 device is a WRAPPER object with a heap-allocated vtable of
// unknown length (overlay/proxy injection - QQ etc.). Empirically:
//   - wrapper vtable slot 17 (Present) is a valid mirror entry: hooking works
//   - wrapper vtable slot 113 (PresentEx) was NOT valid: first call crashed
// Strategy:
//   - patch wrapper slot 17 (Present) -> hkPresent   [proven safe]
//   - obtain the REAL device via wrapper->GetSwapChain(0) (returns the real
//     d3d9 swapchain) -> swapchain->GetDevice; keep it for screenshots
//   - PresentEx: patch wrapper slot 113 ONLY if it equals the real device's
//     slot 113 (full-length mirror); otherwise inline-hotpatch the real d3d9
//     PresentEx function (mov edi,edi prologue required)
//   - swapchain Present (slot 3, real static vtable) hooked as well
// All control files use ABSOLUTE paths based on the game exe's directory.
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

typedef long HR;
typedef unsigned long U32;

static HINSTANCE g_hInst = NULL;
static char g_dir[MAX_PATH] = ".";

static void Log(const char* fmt, ...) {
  char buf[512];
  va_list ap; va_start(ap, fmt);
  _vsnprintf(buf, sizeof(buf)-2, fmt, ap);
  va_end(ap);
  int n = lstrlenA(buf); buf[n] = '\r'; buf[n+1] = '\n';
  char path[MAX_PATH];
  sprintf(path, "%s\\inj_log.txt", g_dir);
  HANDLE f = CreateFileA(path, FILE_APPEND_DATA, FILE_SHARE_READ|FILE_SHARE_WRITE, NULL, OPEN_ALWAYS, 0, NULL);
  if (f != INVALID_HANDLE_VALUE) { DWORD w; WriteFile(f, buf, n+2, &w, NULL); CloseHandle(f); }
}

static void** VT(void* obj) { return *(void***)obj; }

// ---------- inline hotpatch (mov edi,edi + E9) ----------
typedef struct { unsigned char code[16]; } Tramp;
static int HookFunc(void* func, void* stub, Tramp* t) {
  unsigned char* p = (unsigned char*)func;
  if (p[0] != 0x8B || p[1] != 0xFF) { Log("hotpatch: bad prologue at %p (%02X %02X)", func, p[0], p[1]); return 0; }
  memcpy(t->code, p, 5);
  t->code[5] = 0xE9;
  *(int*)(t->code+6) = (int)((char*)func + 5 - (char*)(t->code + 10));
  DWORD old;
  if (!VirtualProtect(func, 5, PAGE_EXECUTE_READWRITE, &old)) { Log("hotpatch: protect failed %p err=%d", func, GetLastError()); return 0; }
  *(unsigned char*)func = 0xE9;
  *(int*)((char*)func+1) = (int)((char*)stub - ((char*)func + 5));
  VirtualProtect(func, 5, old, &old);
  FlushInstructionCache(GetCurrentProcess(), func, 5);
  return 1;
}

// ---------- vtable registries ----------
#define MAXVT 8
static void** g_cdVts[MAXVT];  static void*  g_cdOrig[MAXVT];  static int g_cdN;
static void** g_cdxVts[MAXVT]; static void*  g_cdxOrig[MAXVT]; static int g_cdxN;
static void** g_prVts[MAXVT];  static void*  g_prOrig[MAXVT];  static int g_prN;
static void** g_prxVts[MAXVT]; static void*  g_prxOrig[MAXVT]; static int g_prxN;
static void** g_scVts[MAXVT];  static void*  g_scOrig[MAXVT];  static int g_scN;

static int PatchSlot(void** vt, int idx, void* hk, void** origOut) {
  if (vt[idx] == hk) return 1;
  DWORD old;
  if (!VirtualProtect(&vt[idx], 4, PAGE_READWRITE, &old)) {
    Log("patch: protect failed vt=%p idx=%d err=%d", vt, idx, GetLastError());
    return 0;
  }
  if (origOut) *origOut = vt[idx];
  vt[idx] = hk;
  VirtualProtect(&vt[idx], 4, old, &old);
  FlushInstructionCache(GetCurrentProcess(), &vt[idx], 4);
  return 1;
}
static void* FindOrig(void** vt, void** vts, void** origs, int n) {
  for (int i = 0; i < n; i++) if (vts[i] == vt) return origs[i];
  return NULL;
}
static int Register(void** vt, void* orig, void** vts, void** origs, int* n) {
  for (int i = 0; i < *n; i++) if (vts[i] == vt) return 0;
  if (*n >= MAXVT) return 0;
  vts[*n] = vt; origs[*n] = orig; (*n)++;
  return 1;
}

// ---------- signatures ----------
typedef HR     (WINAPI* CreateDevice_t)(void*, U32, U32, HWND, U32, void*, void**);
typedef HR     (WINAPI* CreateDeviceEx_t)(void*, U32, U32, HWND, U32, void*, void*, void**);
typedef HR     (WINAPI* Present_t)(void*, const RECT*, const RECT*, HWND, const void*);
typedef HR     (WINAPI* PresentEx_t)(void*, const RECT*, const RECT*, HWND, const void*, U32);
typedef HR     (WINAPI* GetSwapChain_t)(void*, U32, void**);
typedef HR     (WINAPI* SCGetDevice_t)(void*, void**);
typedef HR     (WINAPI* QI_t)(void*, const void*, void**);
typedef ULONG  (WINAPI* Release_t)(void*);
typedef HR     (WINAPI* GetBackBuffer_t)(void*, U32, U32, U32, void**);
typedef HR     (WINAPI* GetDesc_t)(void*, void*);
typedef HR     (WINAPI* LockRect_t)(void*, void*, const RECT*, U32);
typedef HR     (WINAPI* UnlockRect_t)(void*);

// IID_IDirect3DDevice9Ex = {B18B10CE-2649-405A-870F-95F777D4313A}
static const unsigned char IID_Dev9Ex[16] =
  {0xCE,0x10,0x8B,0xB1, 0x49,0x26, 0x5A,0x40, 0x87,0x0F,0x95,0xF7,0x77,0xD4,0x31,0x3A};

static long g_shotCounter = 0;
static long g_presentFrame = 0;
static volatile LONG g_inShot = 0;
static void* g_realDev = NULL;         // the real d3d9 device (AddRef'd) - safe vtable
static Tramp g_tPresentEx;             // inline-hook trampoline for real PresentEx
static int   g_inlinePresentEx = 0;

// D3DSURFACE_DESC: Format,Type,Usage,Pool,MS,Quality,Width,Height (all 4-byte)
typedef struct { unsigned long fmt, type, usage, pool, mst, msq; unsigned int w, h; } SurfDesc;

static void SaveShot(void* dev) {
  char flagPath[MAX_PATH]; sprintf(flagPath, "%s\\shot.flag", g_dir);
  DeleteFileA(flagPath);
  char name[64];
  sprintf(name, "%s\\shot_%04d.bmp", g_dir, (int)++g_shotCounter);
  void* target = dev;
  if (g_realDev) target = g_realDev;   // prefer real device: static, safe vtable
  void** vt = VT(target);
  GetBackBuffer_t getBB = (GetBackBuffer_t)vt[18];
  void* bb = NULL;
  if (getBB(target, 0, 0, 0, &bb) != 0 || !bb) { Log("shot: GetBackBuffer failed"); return; }
  void** svt = VT(bb);
  SurfDesc desc; memset(&desc, 0, sizeof(desc));
  ((GetDesc_t)svt[12])(bb, &desc);
  struct { long pitch; void* bits; } lr; memset(&lr, 0, sizeof(lr));
  LockRect_t lockR = (LockRect_t)svt[13];
  UnlockRect_t unlR = (UnlockRect_t)svt[14];
  Release_t rel = (Release_t)svt[2];
  HR rc = lockR(bb, &lr, NULL, 0x10);
  if (rc != 0) rc = lockR(bb, &lr, NULL, 0);
  if (rc != 0 || !lr.bits) { Log("shot: LockRect failed hr=%x", rc); rel(bb); return; }
  unsigned int w = desc.w, h = desc.h;
  Log("shot %s: %ux%u pitch=%d dev=%s", name, w, h, lr.pitch, target==g_realDev?"real":"wrapper");
  HANDLE f = CreateFileA(name, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
  if (f != INVALID_HANDLE_VALUE) {
    unsigned int rowSize = w * 4;
    unsigned int imgSize = rowSize * h;
    unsigned char fh[14]; memset(fh, 0, sizeof(fh));
    fh[0]='B'; fh[1]='M'; *(unsigned int*)(fh+2) = 14 + 40 + imgSize; *(unsigned int*)(fh+10) = 14 + 40;
    unsigned char ih[40]; memset(ih, 0, sizeof(ih));
    *(unsigned int*)(ih+0) = 40; *(int*)(ih+4) = (int)w; *(int*)(ih+8) = (int)h;
    *(unsigned short*)(ih+12) = 1; *(unsigned short*)(ih+14) = 32;
    *(unsigned int*)(ih+20) = imgSize;
    DWORD wr;
    WriteFile(f, fh, 14, &wr, NULL);
    WriteFile(f, ih, 40, &wr, NULL);
    unsigned char* row = (unsigned char*)LocalAlloc(0, rowSize);
    if (row) {
      for (int y = (int)h - 1; y >= 0; y--) {
        memcpy(row, (char*)lr.bits + (long)y * lr.pitch, rowSize);
        for (unsigned int x = 0; x < w; x++) { unsigned char tmp = row[x*4]; row[x*4] = row[x*4+2]; row[x*4+2] = tmp; }
        WriteFile(f, row, rowSize, &wr, NULL);
      }
      LocalFree(row);
    }
    CloseHandle(f);
  }
  unlR(bb);
  rel(bb);
}

static void MaybeShot(void* dev) {
  if ((g_presentFrame & 7) != 0) return;
  char flagPath[MAX_PATH]; sprintf(flagPath, "%s\\shot.flag", g_dir);
  if (GetFileAttributesA(flagPath) == 0xFFFFFFFF) return;
  if (InterlockedCompareExchange(&g_inShot, 1, 0) != 0) return;
  SaveShot(dev);
  g_inShot = 0;
}

static HR WINAPI hkPresent(void* self, const RECT* a, const RECT* b, HWND c, const void* d) {
  static long cnt = 0;
  Present_t orig = (Present_t)FindOrig(VT(self), g_prVts, g_prOrig, g_prN);
  if (!orig) { Log("hkPresent: NO ORIG for vt=%p", VT(self)); return 0x88760870; }
  if (++cnt <= 3) Log("hkPresent #%d self=%p", cnt, self);
  HR hr = orig(self, a, b, c, d);
  g_presentFrame++;
  MaybeShot(self);
  return hr;
}
static HR WINAPI hkPresentEx(void* self, const RECT* a, const RECT* b, HWND c, const void* d, U32 e) {
  static long cnt = 0;
  PresentEx_t orig = (PresentEx_t)FindOrig(VT(self), g_prxVts, g_prxOrig, g_prxN);
  if (!orig) { Log("hkPresentEx: NO ORIG for vt=%p", VT(self)); return 0x88760870; }
  if (++cnt <= 3) Log("hkPresentEx(vtable) #%d self=%p", cnt, self);
  HR hr = orig(self, a, b, c, d, e);
  g_presentFrame++;
  MaybeShot(self);
  return hr;
}
static HR WINAPI hkPresentExInline(void* self, const RECT* a, const RECT* b, HWND c, const void* d, U32 e) {
  static long cnt = 0;
  if (++cnt <= 3) Log("hkPresentEx(inline) #%d self=%p", cnt, self);
  HR hr = ((PresentEx_t)(void*)g_tPresentEx.code)(self, a, b, c, d, e);
  g_presentFrame++;
  MaybeShot(self);
  return hr;
}
static HR WINAPI hkSwapPresent(void* self, const RECT* a, const RECT* b, HWND c, const void* d, U32 e) {
  static long cnt = 0;
  PresentEx_t orig = (PresentEx_t)FindOrig(VT(self), g_scVts, g_scOrig, g_scN);
  if (!orig) { Log("hkSwapPresent: NO ORIG for vt=%p", VT(self)); return 0x88760870; }
  if (++cnt <= 3) Log("hkSwapPresent #%d self=%p", cnt, self);
  HR hr = orig(self, a, b, c, d, e);
  g_presentFrame++;
  MaybeShot(g_realDev ? g_realDev : self);
  return hr;
}

static void HookSwapChain(void* dev) {
  void** dvt = VT(dev);
  GetSwapChain_t gsc = (GetSwapChain_t)dvt[14];
  void* sc = NULL;
  if (gsc(dev, 0, &sc) != 0 || !sc) { Log("GetSwapChain(0) failed"); return; }
  void** svt = VT(sc);
  if (!FindOrig(svt, g_scVts, g_scOrig, g_scN)) {
    void* orig = svt[3];
    if (Register(svt, orig, g_scVts, g_scOrig, &g_scN))
      if (PatchSlot(svt, 3, &hkSwapPresent, NULL))
        Log("swapchain vt=%p Present(orig)=%p hooked", svt, orig);
  }
  return; // caller releases
}

static void HookDevice(void* dev) {
  if (!dev) return;
  void** vt = VT(dev);
  if (!FindOrig(vt, g_prVts, g_prOrig, g_prN)) {
    void* orig = vt[17];
    if (Register(vt, orig, g_prVts, g_prOrig, &g_prN))
      if (PatchSlot(vt, 17, &hkPresent, NULL))
        Log("device vt=%p Present(orig)=%p hooked", vt, orig);
  }

  // find the REAL device: GetSwapChain(0) -> (real) swapchain -> GetDevice
  void** dvt = VT(dev);
  GetSwapChain_t gsc = (GetSwapChain_t)dvt[14];
  void* sc = NULL;
  if (gsc(dev, 0, &sc) == 0 && sc) {
    void** svt = VT(sc);
    HookSwapChain(dev); // reuse the sc we hold (hooks svt slot 3)
    void* realDev = NULL;
    ((SCGetDevice_t)svt[8])(sc, &realDev);
    if (realDev) {
      void** rvt = VT(realDev);
      Log("realDev=%p vt=%p (dev=%p vt=%p)", realDev, rvt, dev, vt);
      // Ex check on the REAL device (static full-length vtable)
      void* exObj = NULL;
      if (((QI_t)rvt[0])(realDev, IID_Dev9Ex, &exObj) == 0 && exObj) {
        ((Release_t)VT(exObj)[2])(exObj);
        void* realPEx = rvt[113];
        Log("real PresentEx=%p wrapper[113]=%p", realPEx, vt[113]);
        if (vt[113] == realPEx) {
          // table self-consistent; still, calling slot 113 crashed the process
          // earlier -> DO NOT patch slot 113. Log ground truth only.
          Log("NOT patching slot 113 (crashed before); real PresentEx=%p", realPEx);
        } else {
          // wrapper table too short: inline-hook the real PresentEx function
          if (!g_inlinePresentEx) {
            g_inlinePresentEx = HookFunc(realPEx, &hkPresentExInline, &g_tPresentEx);
            Log("inline PresentEx hook at %p: %s", realPEx, g_inlinePresentEx ? "OK" : "FAILED");
          }
        }
        // keep the real device alive for screenshots (safe static vtable)
        g_realDev = realDev; // holds the AddRef from GetDevice
      } else {
        Log("realDev is not Ex?");
      }
      if (g_realDev != realDev) ((Release_t)rvt[2])(realDev);
    } else Log("swapchain GetDevice failed");
    ((Release_t)svt[2])(sc);
  } else Log("GetSwapChain(0) failed (hookdevice)");
}

static HR WINAPI hkCreateDevice(void* self, U32 a, U32 b, HWND c, U32 d, void* e, void** ppDev) {
  CreateDevice_t orig = (CreateDevice_t)FindOrig(VT(self), g_cdVts, g_cdOrig, g_cdN);
  HR hr = orig(self, a, b, c, d, e, ppDev);
  Log("CreateDevice hr=%x dev=%p", hr, (ppDev ? *ppDev : NULL));
  if (hr == 0 && ppDev && *ppDev) HookDevice(*ppDev);
  return hr;
}
static HR WINAPI hkCreateDeviceEx(void* self, U32 a, U32 b, HWND c, U32 d, void* e, void* f, void** ppDev) {
  CreateDeviceEx_t orig = (CreateDeviceEx_t)FindOrig(VT(self), g_cdxVts, g_cdxOrig, g_cdxN);
  HR hr = orig(self, a, b, c, d, e, f, ppDev);
  Log("CreateDeviceEx hr=%x dev=%p", hr, (ppDev ? *ppDev : NULL));
  if (hr == 0 && ppDev && *ppDev) HookDevice(*ppDev);
  return hr;
}

static unsigned long PadBits(void);  // defined below (DI keyboard section)

// ---------- fake keyboard via user32 GetKeyboardState ----------
// DXLib 3.12e keyboard update (DxInput.cpp ~2356): when UseDirectInputFlag is
// FALSE (default) on Vista+ it reads the keyboard via GetKeyboardState(), NOT
// DirectInput -> hook it inline and OR our pad bits in as VK codes.
typedef BOOL (WINAPI* GetKeyboardState_t)(unsigned char*);
static Tramp g_tGKS;
static GetKeyboardState_t g_realGKS;
static BOOL WINAPI hkGetKeyboardState(unsigned char* buf) {
  static long cnt = 0;
  BOOL r = g_realGKS(buf);
  unsigned long bits = PadBits();
  if (++cnt <= 5) Log("GetKeyboardState #%d r=%d bits=%x", cnt, r, bits);
  if (r && bits && buf) {
    static const struct { int bit; int vk; } map[] = {
      {0,0x26},{1,0x28},{2,0x25},{3,0x27},   // UP DOWN LEFT RIGHT
      {4,0x5A},{5,0x58},{6,0x43},            // Z X C
      {7,0x0D},{8,0x1B},{9,0x20},{10,0x10}   // ENTER ESC SPACE LSHIFT
    };
    for (unsigned int i = 0; i < sizeof(map)/sizeof(map[0]); i++)
      if (bits >> map[i].bit & 1) buf[map[i].vk] |= 0x80;
  }
  return r;
}
static void HookUser32Keyboard(void) {
  HMODULE u32 = GetModuleHandleA("user32.dll");
  if (!u32) { Log("user32 not loaded?"); return; }
  unsigned char* p = (unsigned char*)GetProcAddress(u32, "GetKeyboardState");
  if (!p) { Log("no GetKeyboardState proc"); return; }
  Log("user32=%p GetKeyboardState=%p bytes=%02X%02X%02X%02X%02X%02X",
      u32, p, p[0],p[1],p[2],p[3],p[4],p[5]);
  if (p[0] == 0xFF && p[1] == 0x25) {
    // export is a 6-byte "jmp [iat_slot]" thunk: patch the thunk itself so
    // every caller (mu.exe IAT) is intercepted
    void** slot = *(void***)(p + 2);
    if (IsBadReadPtr(slot, 4)) { Log("GKS thunk slot %p unreadable", slot); return; }
    g_realGKS = (GetKeyboardState_t)*slot;
    if (!g_realGKS) { Log("GKS slot empty"); return; }
    unsigned char* rp = (unsigned char*)g_realGKS;
    Log("GKS thunk %p slot=%p real=%p realbytes=%02X%02X%02X", p, slot, g_realGKS, rp[0],rp[1],rp[2]);
    DWORD old;
    if (!VirtualProtect(p, 6, PAGE_EXECUTE_READWRITE, &old)) { Log("GKS thunk protect failed %d", GetLastError()); return; }
    p[0] = 0xE9;
    *(int*)(p+1) = (int)((char*)&hkGetKeyboardState - (char*)(p + 5));
    p[5] = 0x90;
    VirtualProtect(p, 6, old, &old);
    FlushInstructionCache(GetCurrentProcess(), p, 6);
    Log("GKS thunk patched -> hkGetKeyboardState");
  } else {
    // normal function: standard mov edi,edi hotpatch
    if (HookFunc(p, &hkGetKeyboardState, &g_tGKS))
      Log("GetKeyboardState %p inline hooked", p);
  }
}

// ---------- fake keyboard via DirectInput (class vtable patch) ----------
// padstate.txt semantic bits (game-level):
//   bit0=UP bit1=DOWN bit2=LEFT bit3=RIGHT bit4=Z bit5=X bit6=C(ESC)
//   bit7=ENTER bit8=ESC bit9=SPACE bit10=LSHIFT
// IID_IDirectInput7A = {9A4CB684-236D-11D3-8E9D-00C04F6844AE}
static const unsigned char IID_DI7A[16] =
  {0x84,0xB6,0x4C,0x9A, 0x6D,0x23, 0xD3,0x11, 0x8E,0x9D,0x00,0xC0,0x4F,0x68,0x44,0xAE};
// IID_IDirectInput8A = {BF798030-483A-4DA2-AA99-5D64ED369700}
static const unsigned char IID_DI8A[16] =
  {0x30,0x80,0x79,0xBF, 0x3A,0x48, 0xA2,0x4D, 0xAA,0x99,0x5D,0x64,0xED,0x36,0x97,0x00};
// GUID_SysKeyboard = {6F1D2B61-D5A0-11CF-BFC7-444553540000}
static const unsigned char GUID_SysKeyboard[16] =
  {0x61,0x2B,0x1D,0x6F, 0xA0,0xD5, 0xCF,0x11, 0xBF,0xC7,0x44,0x45,0x53,0x54,0x00,0x00};

typedef HR (WINAPI* DICreate7Ex_t)(void*, U32, const void*, void**, void*);
typedef HR (WINAPI* DICreate8_t)(void*, U32, const void*, void**, void*);
typedef HR (WINAPI* DICreateDevice_t)(void*, const void*, void**, void*);
typedef HR (WINAPI* DIGetDeviceState_t)(void*, U32, void*);

static void** g_kbVts[MAXVT]; static void* g_kbOrig[MAXVT]; static int g_kbN;

static unsigned long g_padBits = 0;
static unsigned long g_padCheck = 0;
static unsigned long PadBits(void) {
  unsigned long now = GetTickCount();
  if (now - g_padCheck < 8) return g_padBits;
  g_padCheck = now;
  char p[MAX_PATH]; sprintf(p, "%s\\padstate.txt", g_dir);
  HANDLE f = CreateFileA(p, GENERIC_READ, FILE_SHARE_READ|FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
  if (f == INVALID_HANDLE_VALUE) g_padBits = 0;
  else {
    char buf[64]; DWORD rd = 0;
    ReadFile(f, buf, 63, &rd, NULL); CloseHandle(f);
    buf[rd] = 0;
    g_padBits = strtoul(buf, NULL, 16);
  }
  return g_padBits;
}

static HR WINAPI hkKbdGetDeviceState(void* self, U32 cb, void* data) {
  static long cnt = 0;
  DIGetDeviceState_t orig = (DIGetDeviceState_t)FindOrig(VT(self), g_kbVts, g_kbOrig, g_kbN);
  if (!orig) { Log("hkKbdGetDeviceState: NO ORIG vt=%p", VT(self)); return 0x88760870; }
  HR hr = orig(self, cb, data);
  if (++cnt <= 5) Log("kbd GetDeviceState #%d hr=%x cb=%d bits=%x", cnt, hr, cb, PadBits());
  if (cb == 256 && data) {
    unsigned long bits = PadBits();
    if (bits) {
      if (hr != 0) memset(data, 0, 256);
      static const struct { int bit; int dik; } map[] = {
        {0,0xC8},{1,0xD0},{2,0xCB},{3,0xCD},{4,0x2C},{5,0x2D},{6,0x2E},
        {7,0x1C},{8,0x01},{9,0x39},{10,0x2A}
      };
      for (unsigned int i = 0; i < sizeof(map)/sizeof(map[0]); i++)
        if (bits >> map[i].bit & 1) ((unsigned char*)data)[map[i].dik] = 0x80;
    }
  }
  return hr;
}

static void HookKeyboard(void) {
  // try dinput.dll (DI7) then dinput8.dll (DI8): create our own keyboard
  // device object just to reach its CLASS vtable (slot 9 = GetDeviceState)
  struct { const char* dll; const char* fn; const unsigned char* iid; U32 ver; } paths[] = {
    {"dinput.dll",   "DirectInputCreateEx", IID_DI7A, 0x0700},
    {"dinput8.dll",  "DirectInput8Create",  IID_DI8A, 0x0800},
  };
  for (int i = 0; i < 2; i++) {
    HMODULE m = LoadLibraryA(paths[i].dll);
    if (!m) continue;
    void* create = (void*)GetProcAddress(m, paths[i].fn);
    if (!create) continue;
    void* di = NULL;
    HR hr;
    if (i == 0) hr = ((DICreate7Ex_t)create)(GetModuleHandleA(NULL), paths[i].ver, paths[i].iid, &di, NULL);
    else        hr = ((DICreate8_t)create)(GetModuleHandleA(NULL), paths[i].ver, paths[i].iid, &di, NULL);
    if (hr != 0 || !di) { Log("%s create failed hr=%x", paths[i].dll, hr); continue; }
    void** dvt = VT(di);
    void* dev = NULL;
    hr = ((DICreateDevice_t)dvt[3])(di, GUID_SysKeyboard, &dev, NULL);
    if (hr != 0 || !dev) { Log("%s CreateDevice(kbd) failed hr=%x", paths[i].dll, hr); ((Release_t)dvt[2])(di); continue; }
    void** vt = VT(dev);
    if (!FindOrig(vt, g_kbVts, g_kbOrig, g_kbN)) {
      void* orig = vt[9];
      if (Register(vt, orig, g_kbVts, g_kbOrig, &g_kbN))
        if (PatchSlot(vt, 9, &hkKbdGetDeviceState, NULL))
          Log("%s kbd vt=%p GetDeviceState(orig)=%p hooked", paths[i].dll, vt, orig);
    }
    ((Release_t)vt[2])(dev);
    ((Release_t)dvt[2])(di);
  }
}

// ---------- text-render spies: gdi32 TextOutW + GetGlyphOutlineW ----------
// mu.exe imports exactly TextOutW + GetGlyphOutlineW from gdi32 (DXLib text
// pipeline). Log rendered strings + glyph code points to prove what is drawn.
typedef BOOL (WINAPI* TextOutW_t)(void*, int, int, unsigned int, void*, const wchar_t*, unsigned int, const int*);
typedef unsigned long (WINAPI* GGO_t)(void*, unsigned int, unsigned int, void*, unsigned long, void*, const void*);
static TextOutW_t g_origTextOutW;
static GGO_t g_origGGO;
static long g_toCalls = 0;
static long g_ggoCalls = 0;
static long g_ggoCJK = 0;
static unsigned char g_seen[8192];   // bitmap of logged code points
static long g_seenN = 0;

static BOOL WINAPI hkTextOutW(void* dc, int x, int y, unsigned int o, void* rc, const wchar_t* s, unsigned int c, const int* dx) {
  if (g_toCalls < 30 && s && c && c < 256) {
    char buf[600]; int n = 0;
    for (unsigned int i = 0; i < c && n < 500; i++)
      n += sprintf(buf + n, "%s%04X,", i ? " " : "", (unsigned)s[i]);
    Log("TextOutW#%d (%d,%d) len=%d: %s", (int)g_toCalls, x, y, (int)c, buf);
  }
  g_toCalls++;
  TextOutW_t orig = g_origTextOutW;
  if (!orig) return 0;
  return orig(dc, x, y, o, rc, s, c, dx);
}
static unsigned long WINAPI hkGetGlyphOutline(void* dc, unsigned int code, unsigned int fmt, void* gm, unsigned long cb, void* buf, const void* mt) {
  g_ggoCalls++;
  if ((code >= 0x2E80 && code <= 0x9FFF) || (code >= 0xFF00 && code <= 0xFFEF)) g_ggoCJK++;
  if (g_seenN < 200 && code < 0x10000 && !(g_seen[code >> 3] & (1 << (code & 7)))) {
    g_seen[code >> 3] |= (unsigned char)(1 << (code & 7));
    g_seenN++;
    if (g_seenN <= 80) Log("glyph U+%04X", code);
  }
  GGO_t orig = g_origGGO;
  if (!orig) return (unsigned long)-1;
  return orig(dc, code, fmt, gm, cb, buf, mt);
}
// patch mu.exe's IAT entry for dll!func -> hook; save original in *origOut
static int PatchIAT(const char* dllName, const char* funcName, void* hook, void** origOut) {
  unsigned char* base = (unsigned char*)GetModuleHandleA(NULL);
  if (!base) return 0;
  unsigned int pe = *(unsigned int*)(base + 0x3c);
  unsigned int opt = pe + 24;
  unsigned int impRva = *(unsigned int*)(base + opt + 96 + 8);
  if (!impRva) return 0;
  unsigned char* imp = base + impRva;
  for (int i = 0; ; i++) {
    unsigned int oft = *(unsigned int*)(imp + i*20 + 0);
    unsigned int nameRva = *(unsigned int*)(imp + i*20 + 12);
    unsigned int iat = *(unsigned int*)(imp + i*20 + 16);
    if (!nameRva) break;
    const char* dn = (const char*)(base + nameRva);
    if (_stricmp(dn, dllName) != 0) continue;
    unsigned char* thunk = base + (oft ? oft : iat);
    unsigned char* iatArr = base + iat;
    for (int j = 0; ; j++) {
      unsigned int v = *(unsigned int*)(thunk + j*4);
      if (!v) break;
      if (!(v & 0x80000000)) {
        const char* fn = (const char*)(base + v + 2);
        if (strcmp(fn, funcName) == 0) {
          void** slot = (void**)(iatArr + j*4);
          void* old = *slot;
          if (old == hook) return 1;
          DWORD prot;
          if (!VirtualProtect(slot, 4, PAGE_READWRITE, &prot)) return 0;
          *slot = hook;
          VirtualProtect(slot, 4, prot, &prot);
          if (origOut) *origOut = old;
          Log("IAT %s!%s: %p -> hook (orig %p)", dllName, funcName, slot, old);
          return 1;
        }
      }
    }
  }
  return 0;
}
static void HookTextRender(void) {
  PatchIAT("gdi32.dll", "TextOutW", &hkTextOutW, (void**)&g_origTextOutW);
  PatchIAT("gdi32.dll", "GetGlyphOutlineW", &hkGetGlyphOutline, (void**)&g_origGGO);
}

// ---------- watchdog ----------
static DWORD WINAPI Watchdog(LPVOID unused) {
  (void)unused;
  for (;;) {
    Sleep(3000);
    char cwd[MAX_PATH]; GetCurrentDirectoryA(MAX_PATH, cwd);
    Log("stat frames=%d shots=%d kbd=%d bits=%x glyphs=%d cjk=%d textout=%d cwd=%s", g_presentFrame, g_shotCounter, g_kbN, PadBits(), g_ggoCalls, g_ggoCJK, g_toCalls, cwd);
  }
}

// ---------- init ----------
static DWORD WINAPI Worker(LPVOID unused) {
  (void)unused;
  char self[MAX_PATH];
  if (GetModuleFileNameA(NULL, self, MAX_PATH)) {
    char* s = strrchr(self, '\\');
    if (s) { *s = 0; lstrcpynA(g_dir, self, MAX_PATH); }
  }
  CreateThread(NULL, 0, Watchdog, NULL, 0, NULL);
  HMODULE d3d9 = LoadLibraryA("d3d9.dll");
  if (!d3d9) { Log("no d3d9: %d", GetLastError()); }
  else {
    typedef void* (WINAPI* C9_t)(unsigned int);
    typedef HR (WINAPI* C9x_t)(unsigned int, void**);
    C9_t  pC9  = (C9_t)(void*)GetProcAddress(d3d9, "Direct3DCreate9");
    C9x_t pC9x = (C9x_t)(void*)GetProcAddress(d3d9, "Direct3DCreate9Ex");
    if (pC9) {
      void* o = pC9(32);
      if (o) {
        void** vt = VT(o);
        if (!FindOrig(vt, g_cdVts, g_cdOrig, g_cdN)) {
          void* orig = vt[16];
          if (Register(vt, orig, g_cdVts, g_cdOrig, &g_cdN))
            PatchSlot(vt, 16, &hkCreateDevice, NULL) ? Log("IDirect3D9 vt=%p CreateDevice(orig)=%p hooked", vt, orig) : 0;
        }
        ((Release_t)vt[2])(o);
        Log("Direct3DCreate9 done");
      } else Log("Direct3DCreate9 returned NULL");
    }
    if (pC9x) {
      void* o = NULL;
      if (pC9x(32, &o) == 0 && o) {
        void** vt = VT(o);
        if (!FindOrig(vt, g_cdVts, g_cdOrig, g_cdN)) {
          void* orig = vt[16];
          if (Register(vt, orig, g_cdVts, g_cdOrig, &g_cdN))
            PatchSlot(vt, 16, &hkCreateDevice, NULL) ? Log("D3D9Ex vt=%p CreateDevice(orig)=%p hooked", vt, orig) : 0;
        }
        if (!FindOrig(vt, g_cdxVts, g_cdxOrig, g_cdxN)) {
          void* orig = vt[20];
          if (Register(vt, orig, g_cdxVts, g_cdxOrig, &g_cdxN))
            PatchSlot(vt, 20, &hkCreateDeviceEx, NULL) ? Log("D3D9Ex vt=%p CreateDeviceEx(orig)=%p hooked", vt, orig) : 0;
        }
        ((Release_t)vt[2])(o);
        Log("Direct3DCreate9Ex done");
      } else Log("Direct3DCreate9Ex unavailable/failed");
    }
  }
  HookUser32Keyboard();
  HookTextRender();
  HookKeyboard();
  char path[MAX_PATH];
  sprintf(path, "%s\\inj_ready.txt", g_dir);
  HANDLE f = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
  if (f != INVALID_HANDLE_VALUE) { DWORD w; WriteFile(f, "ok", 2, &w, NULL); CloseHandle(f); }
  Log("mudev ready dir=%s", g_dir);
  return 0;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID lp) {
  (void)lp;
  if (reason == DLL_PROCESS_ATTACH) {
    g_hInst = h;
    DisableThreadLibraryCalls(h);
    CreateThread(NULL, 0, Worker, NULL, 0, NULL);
  }
  return TRUE;
}
