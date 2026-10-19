#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Install the Chinese patch into a Murasaki / Murasaki Tsurugi install dir.

Applies, for each game dir given:
  1. data archives:  copies the built CN .dat files from tools/out/ over the
     originals (lang.dat, data/txt.dat, patch/<v>/data/txt.dat)
  2. config.exe:     in-place #US heap patch (window title / error messages,
                     file size unchanged)
  3. data/config.txt: translated settings UI text (UTF-8 with BOM, CRLF)

Usage:
  python install.py --m1 <path-to-Murasaki>            # game 1 only
  python install.py --m2 <path-to-Murasaki2-Murasaki2> # game 2 only
  python install.py --m1 ... --m2 ...                  # both

The dirs are the ones containing mu.exe, e.g.
  <Steam>\\steamapps\\common\\Murasaki\\Murasaki
  <Steam>\\steamapps\\common\\Murasaki2\\Murasaki2

Run build_m1.py / build_m2.py first (or download the release zip, which
already contains the built files).
"""
import argparse
import os
import struct
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out')

# ---------------------------------------------------------------- config.txt
CONFIG_TXT = {
    1: """\
ScreenMode\t显示模式
ScreenModeWindow\t窗口
ScreenModeFullScreen1\t全屏
ScreenModeFullScreen2\t全屏（保持比例）
Resolution\t画面尺寸
BgmVolume\tBGM 音量
SeVolume\t 音效音量
Button1\t确定／射击
Button2\t返回／必杀
Button3\t暂停
KeyMapping\t键盘
PadMapping\t手柄
SaveAndExit\t    保存设置
CancelAndExit\t不保存退出
CurrentVersion\t当前版本：
LatestVersion\t最新版本：
Processing\t获取中……
RevertToDefault\t恢复默认
Update\t更新版本
UpdateCompleted\t已更新。
PatchMessage1\t
PatchMessage2\t
PadNum\t手柄数量
""",
    # game 2 formats version lines as "{0}:{1}" itself -> no colon in the labels
    2: """\
ScreenMode\t显示模式
ScreenModeWindow\t窗口
ScreenModeFullScreen1\t全屏
ScreenModeFullScreen2\t全屏（保持比例）
Resolution\t画面尺寸
BgmVolume\tBGM 音量
SeVolume\t 音效音量
Button1\t确定／射击
Button2\t返回／必杀
Button3\t暂停
KeyMapping\t键盘
PadMapping\t手柄
SaveAndExit\t    保存设置
CancelAndExit\t不保存退出
CurrentVersion\t当前版本
LatestVersion\t最新版本
Processing\t获取中……
RevertToDefault\t恢复默认
Update\t更新版本
UpdateCompleted\t已更新。
PatchMessage1\t
PatchMessage2\t
PadNum\t手柄数量
""",
}

# ------------------------------------------------------------------ #US data
US_PATCHES_COMMON = {
    'config':        '设置',        # window title
    'errro!':        '出错了！',
    'Load Error.':   '加载失败。',
    'File Not Found:': '找不到文件：',
    'File not found:': '找不到文件：',
}
# game 2 builds version labels via String.Format("{0}:{1}" / "{0}:????")
US_PATCHES_GAME2 = {
    '{0}:{1}':   '{0}：{1}',
    '{0}:????':  '{0}：????',
}

# ------------------------------------------------------------- .NET metadata
def rva_to_off(sections, rva):
    for va, vs, raw, rsize in sections:
        if va <= rva < va + max(vs, rsize):
            return raw + (rva - va)
    raise ValueError('rva 0x%x not in any section' % rva)


def find_us_heap(data):
    """Locate the #US stream of a .NET assembly. Returns (file_offset, size)."""
    if data[:2] != b'MZ':
        raise ValueError('not a PE file')
    pe = struct.unpack_from('<I', data, 0x3C)[0]
    if data[pe:pe+4] != b'PE\0\0':
        raise ValueError('bad PE signature')
    nsec = struct.unpack_from('<H', data, pe + 6)[0]
    opt = pe + 24
    magic = struct.unpack_from('<H', data, opt)[0]
    ddoff = opt + (96 if magic == 0x10b else 112)   # data directories
    clr_rva = struct.unpack_from('<I', data, ddoff + 14 * 8)[0]
    if not clr_rva:
        raise ValueError('not a .NET assembly (no CLR header)')
    sections = []
    so = opt + struct.unpack_from('<H', data, pe + 20)[0]
    for i in range(nsec):
        s = so + i * 40
        vs, va, rsize, raw = struct.unpack_from('<IIII', data, s + 8)
        sections.append((va, vs, raw, rsize))
    md_rva = struct.unpack_from('<I', data, rva_to_off(sections, clr_rva) + 8)[0]
    md = rva_to_off(sections, md_rva)
    if data[md:md+4] != b'BSJB':
        raise ValueError('bad metadata signature')
    vlen = struct.unpack_from('<I', data, md + 12)[0]
    p = md + 16 + vlen + 2                     # skip past version string + flags
    nstreams = struct.unpack_from('<H', data, p)[0]
    p += 2
    for _ in range(nstreams):
        off, size = struct.unpack_from('<II', data, p)
        p += 8
        name = b''
        while data[p] != 0:
            name += data[p:p+1]
            p += 1
        p += 1
        p = (p + 3) & ~3                       # name is padded to 4 bytes
        if name == b'#US':
            return md + off, size
    raise ValueError('#US stream not found')


def parse_us(s):
    """Yield (entry_offset, prefix_len, text) for each #US entry."""
    p = 1                                       # byte 0 is reserved
    while p < len(s):
        start = p
        b = s[p]; p += 1
        if b & 0x80 == 0:
            ln = b & 0x7F
        elif b & 0xC0 == 0x80:
            ln = ((b & 0x3F) << 8) | s[p]; p += 1
        else:
            ln = ((b & 0x1F) << 24) | (s[p] << 16) | (s[p+1] << 8) | s[p+2]; p += 3
        data = s[p:p+ln]; p += ln
        txt = data[:-1].decode('utf-16-le', errors='replace') if ln else ''
        yield start, ln, txt


def us_prefix(n):
    if n < 0x80:
        return bytes([n])
    if n < 0x4000:
        return bytes([0x80 | (n >> 8), n & 0xFF])
    return bytes([0xC0 | (n >> 24), (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF])


def patch_config_exe(path, game, backup=True):
    """In-place #US patch. New entries are <= old ones; the tail of each old
    entry is zeroed (dead space) so every other entry offset stays valid."""
    data = bytearray(open(path, 'rb').read())
    us_off, us_size = find_us_heap(data)
    s = bytes(data[us_off:us_off + us_size])
    patches = dict(US_PATCHES_COMMON)
    if game == 2:
        patches.update(US_PATCHES_GAME2)
    found = {}
    for start, ln, txt in parse_us(s):
        if txt in patches and txt not in found:
            found[txt] = (start, ln)
    missing = [t for t in patches if t not in found]
    if missing:
        raise RuntimeError('strings not found in %s: %r' % (path, missing))
    for txt, cn in patches.items():
        start, ln = found[txt]
        new = us_prefix(len(cn) * 2 + 1) + cn.encode('utf-16-le') + b'\x00'
        if len(new) > 1 + ln:
            raise RuntimeError('replacement for %r does not fit' % txt)
        pos = us_off + start
        data[pos:pos + 1 + ln] = new + b'\x00' * (1 + ln - len(new))
    # verify the heap still parses to the exact end
    p = 1
    for start, ln, txt in parse_us(bytes(data[us_off:us_off + us_size])):
        pass
    if backup and not os.path.exists(path + '.bak'):
        shutil.copy2(path, path + '.bak')
    open(path, 'wb').write(bytes(data))
    print('  config.exe: %d #US strings patched (title, errors)' % len(patches))


# ------------------------------------------------------------------- install
def install(game, gdir):
    print('game %d: %s' % (game, gdir))
    dats = {1: [('murasaki_lang_cn.dat', 'lang.dat'),
                ('murasaki_txt_cn.dat', 'data/txt.dat'),
                ('murasaki_txt_cn.dat', 'patch/5/data/txt.dat')],
            2: [('m2_lang_cn.dat', 'lang.dat'),
                ('m2_txt_cn.dat', 'data/txt.dat'),
                ('m2_patch3_txt_cn.dat', 'patch/3/data/txt.dat')]}[game]
    for src, dst in dats:
        sp = os.path.join(OUT, src)
        if not os.path.exists(sp):
            raise RuntimeError('missing %s - run build_m%d.py first' % (sp, game))
        dp = os.path.join(gdir, dst)
        os.makedirs(os.path.dirname(dp), exist_ok=True)
        shutil.copy2(sp, dp)
        print('  %s <- %s' % (dst, src))
    patch_config_exe(os.path.join(gdir, 'config.exe'), game)
    cfg = os.path.join(gdir, 'data', 'config.txt')
    os.makedirs(os.path.dirname(cfg), exist_ok=True)
    with open(cfg, 'wb') as f:
        f.write(b'\xef\xbb\xbf' + CONFIG_TXT[game].replace('\n', '\r\n').encode('utf-8'))
    print('  data/config.txt written (settings UI)')


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--m1', help='Murasaki install dir (contains mu.exe)')
    ap.add_argument('--m2', help='Murasaki Tsurugi install dir (contains mu.exe)')
    ap.add_argument('--no-backup', action='store_true',
                    help='do not keep config.exe.bak')
    args = ap.parse_args()
    if not args.m1 and not args.m2:
        ap.error('give --m1 and/or --m2')
    if args.m1:
        install(1, args.m1)
    if args.m2:
        install(2, args.m2)


if __name__ == '__main__':
    main()
