# 运行时验证工具

汉化完成后用于验证「游戏真的把每个汉字都渲染出来了」的工具集。均为 Windows 专用,是一次性验证流程的整理,供复现与参考。

## 字体渲染验证(mudev.c / host.c)

游戏(DX Library)通过 `GetGlyphOutlineW` 把文字栅格化成位图再绘制。钩住该 API 即可记录游戏运行时**实际渲染的每一个码点**:

- `mudev.c` —— 32 位注入 DLL。除 `GetGlyphOutlineW` 外还处理了 D3D9 设备被包装(桌面悬浮层代理注入)导致截图困难的问题(见文件头注释)。
- `host.c` —— 简单宿主,用于脱机测试钩子行为。

构建(任意 C 编译器,以 tcc 为例):

```
tcc -shared -o mudev.dll mudev.c user32.dll gdi32.dll
tcc -o host.exe host.c
```

把 `mudev.dll` 放到游戏目录,游戏启动时由 DX Library 的 DLL 搜索链加载(或用注入器注入),运行游戏后读取其输出的码点日志,与译文字符集做差集 —— 两款游戏均验证为**零缺字**(所有译文汉字都出现在栅格化码点流中)。

## 私有桌面测试台(deskrun.ps1 / enumcfg.ps1)

以 PowerShell + Win32 API(32 位 PowerShell 运行)在**独立桌面**(`CreateDesktopW`)上启动被测程序,不干扰当前桌面:

- `deskrun.ps1` —— 启动游戏 exe,支持等待窗口、延时、按键(z/x/esc/方向)、窗口客户区截图,用于自动推进到有文本的画面。
- `enumcfg.ps1` —— 启动 config.exe,枚举其全部窗口/控件文本(`GetWindowTextW`)与下拉框条目(`CB_GETLBTEXT`),并用 `PrintWindow` 强制把窗口绘制到位图保存,供像素级检查(豆腐块检测)。

运行示例:

```
%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -File enumcfg.ps1 `
  -ExePath <游戏目录>\config.exe -ShotPath out\cfg.bmp
```

注意事项(踩过的坑):

- `SetThreadDesktop` 不能在主线程调用(错误 170),所有桌面操作放到后台线程。
- config.exe 是单实例程序,残留进程会挡住新实例,测试前后要清理。
- 跨进程 `WM_PRINT` 传本进程 hdc 无效(GDI 句柄进程私有),用 `PrintWindow` 代替。
- .NET 线程未捕获异常会带崩宿主,线程体必须 try/catch。
