# -*- coding: utf-8 -*-
"""Build Chinese archives for Murasaki Tsurugi (game 2).

Game 2 install dir (containing mu.exe) is taken from the MURASAKI2_DIR env
var, defaulting to ../Murasaki2/Murasaki2 relative to this file. Writes
results to tools/out/.
"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from build_patch import load_cn, build

os.chdir(HERE)
G2 = os.environ.get('MURASAKI2_DIR',
                    os.path.normpath(os.path.join(HERE, '..', 'Murasaki2', 'Murasaki2')))

FILES = ['ending.txt', 'items.txt', 'items_cnd.txt', 'musics.txt', 'stage1.txt',
         'stage2.txt', 'stage3.txt', 'stage4.txt', 'stage5.txt', 'stage6.txt',
         'stages.txt', 'system.txt']

def cn_map(prefix, files):
    m = {}
    for f in files:
        c = load_cn(prefix + '_' + f)
        if c:
            m[f] = c
    return m

def mint_raw(name):
    return b'\xfe\xff' + open(os.path.join(HERE, '..', 'cn', name), encoding='utf-8', newline='').read().encode('utf-16-be')

out = os.path.join(HERE, 'out')
os.makedirs(out, exist_ok=True)

m = cn_map('m2', FILES)
raws = {'mint1.txt': mint_raw('m2_mint1.txt'),
        'mint2.txt': mint_raw('m2_mint2.txt'),
        'mint3.txt': mint_raw('m2_mint3.txt')}

build(os.path.join(G2, 'lang.dat'), m, 'out/m2_lang_cn.dat')
build(os.path.join(G2, 'data', 'txt.dat'), m, 'out/m2_txt_cn.dat', raw_map=raws)
build(os.path.join(G2, 'patch', '3', 'data', 'txt.dat'), m, 'out/m2_patch3_txt_cn.dat')
print('done')
