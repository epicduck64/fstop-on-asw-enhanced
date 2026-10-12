# VPK reading — notes

Notes on the engine VPK reader, the VPK format itself, and the state of the v2
support attempt. Written to be standalone: format first, then what this engine's
reader actually does, then what a v2 implementation needs.

Engine binary: `game/bin/filesystem_stdio.dll` (Valve, Oct 2019 build, x86,
preferred base `0x10000000`, **relocatable** — ASLR moves it at runtime, so all
addresses below are VAs (preferred base) and must be adjusted by the load base;
for this DLL `file offset == RVA == VA - 0x10000000`).

---

## 1. VPK format (canonical)

Source of truth: [`vpkpp`](https://github.com/craftablescience/sourcepp/tree/main/src/vpkpp/format)
(the backend of [VPKEdit](https://github.com/craftablescience/VPKEdit), MIT). It
supports "VPK pre-v1, v1-2, v54". Reference implementation of the struct:

```cpp
constexpr uint32_t VPK_SIGNATURE = 0x55aa1234;
constexpr uint16_t VPK_DIR_INDEX = 0x7fff;   // archiveIndex: data lives in the _dir file
constexpr uint16_t VPK_ENTRY_TERM = 0xffff;  // entry terminator

struct Header1 {          // present in every version
    uint32_t signature;   // 0x55aa1234
    uint32_t version;     // 1 or 2 (54 = CS2/zstd variant)
    uint32_t treeSize;
};

struct Header2 {          // present only in v2+ ("extended header")
    uint32_t fileDataSectionSize;
    uint32_t archiveMD5SectionSize;
    uint32_t otherMD5SectionSize;   // always 48 when present (3 x 16-byte MD5s)
    uint32_t signatureSectionSize;
};
```

Layout on disk:

```
v1 (12-byte header):
  Header1                                  (12)
  <tree>                                   (treeSize)
  <file data>                              (rest)

v2 (28-byte header):
  Header1                                  (12)
  Header2                                  (16)
  <tree>                                   (treeSize)
  <file data>                              (fileDataSectionSize, skip it)
  <archive MD5 entries>                    (archiveMD5SectionSize)
  <MD5 checksums>                          (otherMD5SectionSize = 48)
  <signature section>                      (signatureSectionSize, optional)
```

Tree (identical v1/v2) — extension → directory → file, each a null-terminated
string; empty string ends a level. Entry:

```
cstring  extension
cstring  directory          (" " == root)
cstring  filename-stem
uint32   crc32
uint16   preloadBytes
uint16   archiveIndex       (0x7fff == data is in the _dir file)
uint32   offset
uint32   length
uint32   compressedLength   (v54/zstd only)
uint16   terminator         (0xffff)
uint8[]  preloadData        (preloadBytes)
```

Reading an entry:

- `archiveIndex != 0x7fff` → data is in `<filestem>_NNN.vpk` at `offset`, `length` bytes.
- `archiveIndex == 0x7fff` → data is in the `_dir.vpk` at
  `headerLength + treeSize + offset`, where `headerLength` is `12` (v1) or `28` (v2).

So the only structural difference between v1 and v2 for *content* is the **28-byte
header** (tree at +28, data-in-dir base at +28) plus the **post-tree sections**
(fileDataSize skip, archive-MD5, other-MD5, signature) that must be walked past.
All current retail v2 `_dir.vpk` files have `fileDataSectionSize == 0`.

---

## 2. What this engine's reader does

The reader is `CPackedStore` (symbols from `src/lib/public/vpklib.lib`, whose
disassembly has real names: `CPackedStore::Init/OpenFile/ReadData/FindFileEntry`,
`VPKDirHeader_t`, `CFileHeaderFixedData`, `GetDataFileName`, `CBaseFile::Seek/Size`).
`VPKDirHeader_t`'s ctor stages only `{ sig = 0x55aa1234, version = 1 }` — there is
no v2 field, and no `fileDataSize`/`archiveMD5`/`signatureSection` string anywhere
in the binary. **The reader is v1-only by construction.**

The mount path is the `CPackedStore` constructor around **VA `0x1002B7xx`**:

```
1002B7E8  ecx = [10050304h] ; +4            ; the IFileSystem interface (see below)
1002B7F2  [esp+24h] = 55AA1234h             ; stage signature
1002B7FA  [esp+28h] = 1                     ; stage version
1002B806  push 0Ch ; Read(buf, 12)          ; read the header
1002B80F  cmp read, 0Ch ; jne fail
1002B814  cmp buf[0], 55AA1234h ; jne fail
1002B81E  eax = version
1002B822  cmp eax,1 ; jle ok                ; <-- hard v1 gate
1002B827  Error("Unknown version %d for vpk %s")
1002B83E  edi = [buf+8] (treeSize) ; ok flag = 1
1002B875  ... ; Read(treeBuf, treeSize)     ; tree read, sequential from current pos
1002B8AE  ...
1002B8F0  eax = fileSize - 12 - treeSize    ; post-tree region size (header size hardcoded 12)
1002B8FD  je skip if 0
1002BF..  walk it, inserting into the path hash table
```

Filesystem interface (from `CBaseFile::Seek`/`Size` in vpklib):

- interface `this` = `[g_pFullFileSystem] + 4` (here `[10050304h] + 4`)
- vtable: **Read = slot 0, Seek = slot 4 (+0x10), Size = slot 7 (+0x1C)**
- `Read` is called *curried* — `Read(this, buf, size)`; the file handle is implicit.

`GetDataFileName(archiveIndex)`: `0x7fff` → `%s_dir.vpk`, else `%s_%03d.vpk`.

### 2a. Discovery: only `pakNN_dir.vpk`

Mounting a search-path dir enumerates **`<dir>/pak%02d_dir.vpk`** for NN = 01..99
and stops at the first miss (`VA 0x1000D4A0`–`0x1000D4FA`; format strings
`%s/pak%02d_dir.vpk` / `%s/pak%02d`, in `.rdata` at `0x1004269C` / `0x10042690`).

Consequence: a retail game whose VPKs aren't named `pakNN` is **never opened**.
Confirmed by a cdb trace at the reader, which saw exactly:

```
version 1  game\core/pak01
version 1  game\core/pak02
version 1  game\platform/pak01
version 1  game\steam_portal2/pak01   (Portal 2 names its VPK pak01_dir.vpk)
version 1  game\steam_l4d2/pak01      (L4D2 likewise)
```

`steam_hl2` (`hl2_misc_dir.vpk`…), `steam_ep2` (`ep2_pak_dir.vpk`),
`steam_portal` (`portal_pak_dir.vpk`) and `steam_tf` (`tf2_misc_dir.vpk`…) are
**never opened at all** — not rejected, never attempted. (CS:GO's is literally
`pak01_dir.vpk`, which is why *it* was reached and produced the original
`Unknown version 2 for vpk game\steam_csgo/pak01`.) Games mounted this way can be
made discoverable by naming/hard-linking their VPKs (and chunks) as `pakNN`.

### 2b. Current local patch ("variant B") and why it fails

A local patch acceptance-tests v2 so the tree parses:

- `0x2B822` `83 F8 01` → `83 F8 02` (accept version ≤ 2)
- `0x2B83E` rewritten to `jmp 0x10040CA5` (code cave), with NOPs in between
- code cave at **VA `0x10040CA5`** (file offset `0x40CA5`; `~859` zero bytes at
  the `.text` tail) does the v2 "skip the 16 extra header bytes" step:

```
10040CA5  mov edi,[esp+28h]                 ; treeSize
10040CA9  cmp eax,2
10040CAC  jne 10040CCC                      ; v1 falls through untouched
10040CAE  call $+5 / pop ecx / add ecx,0F651h   ; PC-relative -> [10050304h]
10040CBA  mov ecx,[ecx] / add ecx,4 / mov edx,[ecx] / mov edx,[edx]   ; vtable[0]=Read
10040CC3  push 10h / lea eax,[esp+28h] / push eax / call edx          ; Read(buf,16)
10040CCC  mov byte [esp+13h],1              ; "header ok" flag
10040CD1  jmp 1002B875
```

**This is broken and was never exercised.** No v2 VPK was ever mounted (see
discovery above), so the "verified, no Unknown version" note in earlier versions
of this file was vacuous.

Under cdb, mounting a single v2 VPK (`hl2_misc_dir.vpk` hardlinked as `pak01`)
faults at startup, before any console output:

```
Access violation c0000005 at filesystem_stdio+0x1F80
  cmp dword ptr [ecx+0x10],0FFFFFFFFh        ; ecx = 3
eax=00000010  ecx=00000003  edx=0019c870
```

Every *normal* read reaches that helper with the valid interface pointer
(`0x023d85f0`); the cave's `Read(buf,0x10)` arrives with `ecx=3` — the curried
read path hands back a bogus handle when re-invoked there. (Pointing the skip
read's destination at the header buffer instead of FS stack locals, i.e.
`0x40CC8` `28h`→`24h`, made no difference — the read itself is the problem, not
where it writes.)

So a read-based skip can't work; a correct v2 reader must advance to offset 28
**without a second read**: e.g. `Seek(+16, SEEK_CUR)` on the interface (slot 4),
reconstructing the handle the way `CBaseFile::Seek` does (`mov ecx,[ecx]` off the
object), or a single 28-byte measured read. After that, the reader still needs
the v2 post-tree handling (see §1) — skip `fileDataSectionSize`, then the
archive-MD5 / other-MD5 / signature sections.

Patch offsets currently in play: `0x2B807`, `0x2B811`, `0x2B824` (header read +
checks), `0x2B83E` (branch to cave), cave body at `0x40CA5`, `-12` immediate at
`0x2B8F1`/`0x2B8F0`.

### 2c. Reading the tree buffer

`treeSize` is at `hdr+8` in both versions and the tree read is sequential from the
current file position — so a v2 file only needs the position advanced to 28
before the tree read. `VPKDirHeader_t` ctor and the version gate are the only
version-aware spots in the stock reader.

### 2d. The read path / object model (resolved)

- `[10050304h]` holds the `IFileSystem*` (`P`). The reader's file object is `P+4`
  (its `IBaseFileSystem` sub-object) — that is what `mov ecx,[10050304h]; add
  ecx,4` yields.
- The reader's `Read` is `[[P+4]]` slot 0 — a **thunk at VA `0x100019C0`** that
  forwards to **`[[P]+0x11C]` = `IFileSystem::Read` at VA `0x10002BC0`**, with
  `this = P` and a file handle.
- `IFileSystem::Read(buf, size, handle)` validates and calls the inner helper at
  **VA `0x10001F80`** — the function a v2 mount currently faults inside.
- `IBaseFileSystem` vtable (at `[P+4]`): **Read = 0, Open = 2, Close = 3,
  Seek = 4 (+0x10), Size = 7 (+0x1C)** (cf. `CBaseFile::Seek`/`Size` in
  `vpklib.lib`). `Seek(handle, pos, whence)`; the file position is the FS's
  `FileHandleTracker_t.m_nCurOfs` for that handle.

So the v2 skip must be a `Seek(+16, SEEK_CUR)` through slot 4 — mirroring the
read thunk's shape — not a second `Read`.

---

## 3. State of the attempt / open items

- **v2 reader: implementation in progress.** The read/seek path is now resolved
  (§2d) — the remaining work is the cave `Seek(+16)` for v2 plus the post-tree
  section skip. The format/read order is fully defined by `vpkpp` (§1).
- **Discovery**: v2 games mount only if their VPKs are named `pakNN` (or the
  `0x1000D4A0` probe is patched to enumerate `*_dir.vpk`, which is a larger change).
- **Alternative that meets "mount from a fresh retail install, distribute
  nothing" today:** a setup step that re-materialises the needed retail files
  locally from the user's own installs (extract from their VPKs / loose trees)
  into a gitignored dir, mounted as loose content — no engine patch. The exact
  file list is `retail-removal-list.txt`.

## 4. Tooling / references

- **VPKEdit** — https://github.com/craftablescience/VPKEdit (CLI `vpkeditcli`,
  GUI, can create/read/write and "switch version of existing VPKs").
- **sourcepp / vpkpp** — https://github.com/craftablescience/sourcepp
  (`src/vpkpp/format/VPK.cpp` is the reader/writer quoted in §1).
- Valve's `vpk.exe` and `vpk_extract.ps1` (this repo) for extracting/repacking.
