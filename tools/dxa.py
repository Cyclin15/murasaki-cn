# Murasaki DXA archive library (encryption + dir parse + LZ decode)
import struct

def rol(v,n): return ((v<<n)|(v>>(8-n)))&0xFF
def ror(v,n): return ((v>>n)|(v<<(8-n)))&0xFF
def derive_key2(keystr):
    b = bytearray(12)
    if keystr is None: return bytes([0xAA]*12)
    ln = len(keystr)
    if ln > 12: b[:] = keystr[:12]
    else:
        off = 0
        while off < 12:
            n = min(ln, 12-off); b[off:off+n] = keystr[:n]; off += ln
    return bytes([(~b[0])&0xFF, rol(b[1],4), b[2]^0x8A, (~rol(b[3],4))&0xFF, (~b[4])&0xFF,
                  b[5]^0xAC, (~b[6])&0xFF, (~ror(b[7],3))&0xFF, rol(b[8],3), b[9]^0x7F,
                  rol(b[10],4)^0xD6, b[11]^0xCC])
KEY = derive_key2(b"mr.popo")

def decrypt(data, key=KEY, start_index=0):
    out = bytearray(data); kl = len(key)
    for i in range(len(out)): out[i] ^= key[(start_index+i)%kl]
    return bytes(out)

def encrypt(data, key=KEY):
    return decrypt(data, key)

def lz_decode(data, esc, V0=0):
    # DXLib DxArchive LZ: b1'=b1-(b1>esc); len=((b1'>>3)|((b1'&4)?b3<<5:0))+4
    # dist width by b1'&3: 0=1B,1=2B,2=3B,3=reuse(prev+1); dist=V+1
    out=bytearray(); i=0; stored=V0
    while i<len(data):
        b=data[i]
        if b==esc:
            b1=data[i+1]
            if b1==esc:
                out.append(esc); i+=2; continue
            i+=2
            if b1>esc: b1-=1
            ln=b1>>3
            if b1&4:
                ln|=data[i]<<5; i+=1
            ln+=4
            c=b1&3
            if c==0:
                stored=data[i]; i+=1
            elif c==1:
                stored=data[i]|(data[i+1]<<8); i+=2
            elif c==2:
                stored=data[i]|(data[i+1]<<8)|(data[i+2]<<16); i+=3
            dist=stored+1; stored=dist
            for k in range(ln): out.append(out[-dist])
        else:
            out.append(b); i+=1
    return bytes(out)

def _read_name(d,p):
    e=d.index(b'\0',p)
    s=d[p:e]
    nxt=e+1
    if nxt&1: nxt+=1
    return s,nxt

def read_dxa(path):
    """Returns dict name(lower) -> bytes, and dict name -> (attr,fo,osz,ssz)."""
    raw=open(path,'rb').read()
    d=decrypt(raw)
    assert d[:2]==b'DX', 'not DXA: '+path
    doff=struct.unpack_from('<I',d,0xc)[0]
    f10,f14=struct.unpack_from('<II',d,0x10)
    nent=(f14-f10)//44
    files={}; meta={}
    for n in range(nent):
        e=d[doff+f10+n*44:doff+f10+(n+1)*44]
        no,attr=struct.unpack_from('<II',e,0)
        fo,osz,ssz=struct.unpack_from('<III',e,0x20)
        p=doff+no+4
        nm,_=_read_name(d,p)
        name=nm.decode('cp932')
        meta[name]=(attr,fo,osz,ssz)
        if attr&0x20:
            if ssz==0xFFFFFFFF:
                files[name.lower()]=d[0x1c+fo:0x1c+fo+osz]
            else:
                blob=d[0x1c+fo:0x1c+fo+ssz]
                V0,size,esc=struct.unpack_from('<IIB',blob,0)
                data=lz_decode(blob[9:],esc,V0)
                assert len(data)==osz,(name,len(data),osz)
                files[name.lower()]=data
    return files,meta
