# -*- coding: utf-8 -*-
"""Build Chinese archives for Murasaki (game 1).

Game 1 install dir (containing mu.exe) is taken from the MURASAKI1_DIR env
var, defaulting to ../Murasaki relative to this file (repo checked out next
to the game folders). Writes results to tools/out/.
"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from build_patch import load_cn, build

os.chdir(HERE)
G1 = os.environ.get('MURASAKI1_DIR', os.path.normpath(os.path.join(HERE, '..', 'Murasaki')))

FILES = ['ending.txt', 'items.txt', 'musics.txt', 'stage1.txt', 'stage2.txt',
         'stage3.txt', 'stage4.txt', 'stage4b.txt', 'stage5.txt', 'stage6.txt',
         'stages.txt', 'system.txt', 'tl_notes.txt']

def cn_map(prefix, files):
    m = {}
    for f in files:
        c = load_cn(prefix + '_' + f)
        if c:
            m[f] = c
    return m

out = os.path.join(HERE, 'out')
os.makedirs(out, exist_ok=True)

# M1 lang.dat (EN layer): all text files incl. stage4b/tl_notes
build(os.path.join(G1, 'lang.dat'), cn_map('m1', FILES), 'out/murasaki_lang_cn.dat',
      force_utf16=('tl_notes.txt',))

# M1 txt.dat (JP base layer + patch5 layer): no stage4b/tl_notes there
TFILES = [f for f in FILES if f not in ('stage4b.txt', 'tl_notes.txt')]
build(os.path.join(G1, 'data', 'txt.dat'), cn_map('m1', TFILES), 'out/murasaki_txt_cn.dat')
print('done')
