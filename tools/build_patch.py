# -*- coding: utf-8 -*-
"""Build Chinese DXA archives: apply cn/ translations onto original archives."""
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dxa_write
from dxa import lz_decode, read_dxa
from dxa_write import read_dxa_full, build_dxa, make_blob

FLAG_RE = re.compile(r'^(?:\[[^\]\[]*\])+')


def split_flags(s):
    m = FLAG_RE.match(s)
    return (m.group(0), s[m.end():]) if m else ('', s)

HERE = os.path.dirname(os.path.abspath(__file__))


def load_cn(name):
    """cn file -> {key: [field-list, ...]} preserving order for duplicate keys."""
    path = None
    for base in (os.path.join(HERE, '..', 'cn'), os.path.join(HERE, 'cn')):
        p = os.path.join(base, name)
        if os.path.exists(p):
            path = p
            break
    if path is None:
        return None
    cn = {}
    raw = open(path, encoding='utf-8', newline='').read()
    for l in raw.replace('\r\n', '\n').split('\n'):
        if not l.strip():
            continue
        parts = l.split('\t')
        cn.setdefault(parts[0], []).append(parts[1:])
    return cn


def decode_orig(e):
    """Original file bytes from an entry dict (blob/orig/stored)."""
    blob = e['blob']
    if e['stored'] == 0xFFFFFFFF:
        return bytes(blob)
    v0 = blob[0] | (blob[1] << 8) | (blob[2] << 16) | (blob[3] << 24)
    return lz_decode(blob[9:], blob[8], v0)


def _clean(s):
    """Game text contains only printable chars plus tab/cr/lf."""
    return all(c == '\t' or c == '\r' or c == '\n' or c >= ' ' for c in s)


def decode_text(b):
    """-> (text, enc) following the file's own encoding convention.
    enc in {'utf-16' (LE+BOM), 'utf-16-be' (BOM), 'utf-16-le' (no BOM),
    'ascii', 'cp932'}."""
    if b[:2] == b'\xff\xfe':
        return b[2:].decode('utf-16-le'), 'utf-16'
    if b[:2] == b'\xfe\xff':
        return b[2:].decode('utf-16-be'), 'utf-16-be'
    if all(c < 0x80 and (c in (9, 10, 13) or c >= 0x20) for c in b):
        return b.decode('ascii'), 'ascii'
    # cp932 first: genuine UTF-16LE text contains NULs when misread as cp932,
    # so the control-char check rejects it; genuine cp932 text never has NULs.
    try:
        t = b.decode('cp932')
        if _clean(t):
            return t, 'cp932'
    except UnicodeDecodeError:
        pass
    return b.decode('utf-16-le'), 'utf-16-le'


def encode_text(text, enc, force_utf16=False):
    if force_utf16 or enc == 'utf-16':
        return b'\xff\xfe' + text.encode('utf-16-le')
    if enc == 'utf-16-be':
        return b'\xfe\xff' + text.encode('utf-16-be')
    if enc == 'utf-16-le':
        return text.encode('utf-16-le')
    if enc == 'ascii' and text.isascii():
        return text.encode('ascii')
    try:
        if enc == 'cp932':
            return text.encode('cp932')
    except UnicodeEncodeError:
        pass
    return b'\xff\xfe' + text.encode('utf-16-le')


def translate_text(orig_bytes, cn):
    """Replace values line-by-line (key + occurrence order), keep everything else.
    Leading flag groups of each original field are preserved (JP/EN layers differ,
    e.g. [speed:6.8] vs [speed:3.0][size:20]); flags inside the cn text stay."""
    txt, bom = decode_text(orig_bytes)
    lines = txt.split('\r\n')
    out, used = [], {}
    n = 0
    for l in lines:
        if '\t' in l:
            parts = l.split('\t')
            k = parts[0]
            vals = cn.get(k)
            if vals:
                i = used.get(k, 0)
                if i < len(vals):
                    used[k] = i + 1
                    newf = []
                    for j, cnf in enumerate(vals[i]):
                        oflags, _ = split_flags(parts[1 + j]) if 1 + j < len(parts) else ('', '')
                        _, crest = split_flags(cnf)
                        newf.append(oflags + crest)
                    # keep original trailing fields the cn file omitted (e.g. empty title)
                    if len(parts) > len(vals[i]) + 1:
                        newf += parts[len(vals[i]) + 1:]
                    l = k + '\t' + '\t'.join(newf)
                    n += 1
        out.append(l)
    return '\r\n'.join(out), bom, n


def build(archive_path, cn_map, out_path, force_utf16=(), raw_map=None):
    """cn_map: {filename.lower(): cn dict}; raw_map: {filename.lower(): bytes}
    to replace whole files verbatim (e.g. mint1-3.txt)."""
    hdr, names_area, recs, entries, trailer, d = read_dxa_full(archive_path)
    expected = {}
    nkeys = 0
    raw_map = raw_map or {}
    for e in entries:
        if e['attr'] & 0x10:
            continue
        name = e['name1'].lower() if e['name1'] else ''
        if name in raw_map:
            nb = raw_map[name]
            blob2, osz, ssz = make_blob(nb)
            e['blob'] = blob2
            e['orig'] = osz
            e['stored'] = ssz
            expected[name] = nb
        elif name in cn_map and cn_map[name]:
            ob = decode_orig(e)
            newtxt, bom, n = translate_text(ob, cn_map[name])
            nkeys += n
            nb = encode_text(newtxt, bom, force_utf16=(name in force_utf16))
            if nb != ob:
                blob2, osz, ssz = make_blob(nb)
                e['blob'] = blob2
                e['orig'] = osz
                e['stored'] = ssz
            expected[name] = nb
    seq = sorted([e for e in entries if not (e['attr'] & 0x10)], key=lambda e: e['data_off'])
    out = build_dxa(hdr, names_area, entries, trailer, seq)
    with open(out_path, 'wb') as f:
        f.write(out)
    # verify: re-read the new archive, decoded bytes must equal expected
    files, meta = read_dxa(out_path)
    bad = [n for n, b in expected.items() if files.get(n) != b]
    print(f'{os.path.basename(os.path.dirname(archive_path))}/{os.path.basename(archive_path)} -> {out_path}: '
          f'{len(out)} bytes, {len(expected)} files, {nkeys} lines, verify: {"OK" if not bad else "FAILED " + repr(bad)}')
    return out
