#include <windows.h>
#include <stdio.h>
int main(int argc, char** argv){
  HMODULE m = LoadLibraryA(argv[1]);
  printf("handle=%p err=%d\n", m, GetLastError());
  fflush(stdout);
  Sleep(1500);  // let Worker install hooks
  if (argc > 3 && argv[3][0] == 'g') {
    // call GetGlyphOutlineW through the hook like DXLib does
    HDC dc = GetDC(0);
    MAT2 mt; memset(&mt, 0, sizeof(mt));
    { DWORD one = 0x00010000; memcpy(&mt.eM11, &one, 4); memcpy(&mt.eM22, &one, 4); }
    GLYPHMETRICS gm;
    unsigned int codes[] = {' ', 'A', 0x554A, 0x6253, 0x6270};  // space, A, 啊, 打, 扰
    for (int i = 0; i < 5; i++) {
      DWORD n = GetGlyphOutlineW(dc, codes[i], 1 /*GGO_BITMAP*/, &gm, 0, NULL, &mt);
      printf("GetGlyphOutlineW U+%04X -> %d (GLE=%d)\n", codes[i], n, GetLastError());
      fflush(stdout);
    }
    ReleaseDC(0, dc);
  }
  Sleep(argc > 2 ? atoi(argv[2]) : 5000);
  printf("done\n");
  return 0;
}
