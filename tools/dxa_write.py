# DXA archive builder for Murasaki (v4 header, compression v1)
# Strategy: keep names area / rec_offs / FILETIMEs / trailer verbatim,
# re-lay only the data area (file blobs) and entry data_off/orig/stored.
import struct
from dxa import decrypt, encrypt, KEY


def read_dxa_full(path):
    """Parse an archive preserving everything needed for a faithful rebuild.

    Returns (hdr, names_area, recs_by_off, entries, trailer, d) where each
    entry has rec_off/attr/fts/data_off/orig/stored/blob/name1."""
    raw = open(path, 'rb').read()
    d = decrypt(raw)
    assert d[:4] == b'DX\x04\x00', 'not DXA v4'
    hdr = {'dir_size': struct.unpack_from('<I', d, 4)[0],
           'data_start': struct.unpack_from('<I', d, 8)[0],
           'dir_off': struct.unpack_from('<I', d, 0xc)[0],
           'f10': struct.unpack_from('<I', d, 0x10)[0],
           'f14': struct.unpack_from('<I', d, 0x14)[0],
           'ver': struct.unpack_from('<I', d, 0x18)[0]}
    doff = hdr['dir_off']
    f10, f14 = hdr['f10'], hdr['f14']
    names_area = d[doff:doff + f10]
    # parse name records sequentially -> {record offset: (name1, name2)}
    recs_by_off = {0: (None, None)}
    off = 4
    while off < f10:
        A, B = struct.unpack_from('<HH', names_area, off)
        if A == 0:
            recs_by_off[off] = (None, None)
            off += 4
            continue
        p = off + 4
        def rd(p):
            e = names_area.index(b'\x00', p)
            s = names_area[p:e]
            return s, (e + 1 + 3) & ~3
        n1, p = rd(p)
        n2, p = rd(p)
        assert p - off == 4 + ((len(n1) + 1 + 3) & ~3) + ((len(n2) + 1 + 3) & ~3), off
        recs_by_off[off] = (n1.decode('cp932'), n2.decode('cp932'))
        off = p
    nent = (f14 - f10) // 44
    assert (f14 - f10) % 44 == 0
    entries = []
    for k in range(nent):
        eb = d[doff + f10 + k * 44:doff + f10 + (k + 1) * 44]
        no, attr = struct.unpack_from('<II', eb, 0)
        fts = eb[8:0x20]
        fo, osz, ssz = struct.unpack_from('<III', eb, 0x20)
        blob = d[hdr['data_start'] + fo:hdr['data_start'] + fo + (osz if ssz == 0xFFFFFFFF else ssz)]
        n1, n2 = recs_by_off.get(no, (None, None))
        entries.append({'rec_off': no, 'attr': attr, 'fts': fts, 'data_off': fo,
                        'orig': osz, 'stored': ssz, 'blob': blob, 'name1': n1, 'name2': n2})
    trailer = d[doff + f14:doff + hdr['dir_size']]
    return hdr, names_area, recs_by_off, entries, trailer, d


def build_dxa(hdr, names_area, entries, trailer, data_seq):
    """Rebuild archive. data_seq: file entries in data-area placement order.
    Dir entries (attr&0x10) keep their data_off (dir IDs) verbatim.
    rec_offs, attrs, FILETIMEs and the names area are written verbatim."""
    data = bytearray()
    for e in data_seq:
        if e['attr'] & 0x10:
            continue
        e['data_off'] = len(data)
        data += e['blob']
        data += b'\x00' * ((-len(e['blob'])) & 3)
    entblob = bytearray()
    for e in entries:
        entblob += struct.pack('<II', e['rec_off'], e['attr'])
        entblob += e['fts']
        entblob += struct.pack('<III', e['data_off'], e['orig'], e['stored'])
    f10 = len(names_area)
    f14 = f10 + len(entblob)
    dirdata = names_area + bytes(entblob) + trailer
    nhdr = struct.pack('<4sIIIIII', b'DX\x04\x00', len(dirdata), 0x1c,
                       0x1c + len(data), f10, f14, hdr['ver'])
    assert len(nhdr) == 0x1c
    return encrypt(nhdr + bytes(data) + dirdata)


def lz_literal(data, esc=0xfd):
    """Store data as valid LZ stream with only literals (esc bytes doubled)."""
    out = bytearray()
    for b in data:
        out.append(b)
        if b == esc:
            out.append(esc)
    return bytes(out)


def make_blob(data, esc=0xfd):
    """Compressed blob {V0=orig, size=total, esc, stream}."""
    stream = lz_literal(data, esc)
    blob = struct.pack('<IIB', len(data), 9 + len(stream), esc) + stream
    return blob, len(data), 9 + len(stream)
