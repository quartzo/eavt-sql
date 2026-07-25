## kvstore.nim — Nim KVStore (put, get, scan, flush, GC, cursor merge).
##
## Orchestration layer: coordinates MemTable + PageStore + Journal.

import std/[tables, strutils, os, options]
import page_store

import std/locks

import nim_memtable/treap_backend as mt_be
import treap_cursor
import page_cursor
import query/cursor
export cursor

# ═══════════════════════════════════════════════════════════════════════════════
# KVStore

type
  KVStore* = ref object
    ps*: ptr PageStoreInner
    mt*: mt_be.MemTable
    mtSize*: uint64
    flushRoots*: seq[mt_be.TreapNode]
    lock: Lock
    config*: Table[string, string]
    path*: string
    readOnly*: bool
    numCf*: int
    flushThreshold*: uint64
    gcMaxAgeSecs*: uint64
    gcMaxRootCount*: int

# ═══════════════════════════════════════════════════════════════════════════════
# KVStore operations

# ═══════════════════════════════════════════════════════════════════════════════
# KVStore operations
# ═══════════════════════════════════════════════════════════════════════════════

proc newKVStore*(config: Table[string, string]): KVStore =
  let readOnly = config.getOrDefault("read_only", "false") == "true"
  let ps = newPageStore(config)
  if ps == nil: return nil
  let mt = mt_be.newMemTable(4)
  if mt == nil: closePageStore(ps); return nil
  result = KVStore()
  result.ps = ps; result.mt = mt
  result.config = config
  result.path = config.getOrDefault("path", ":memory:")
  result.readOnly = readOnly
  result.numCf = 4
  result.flushThreshold = parseUInt(config.getOrDefault("flush_threshold", "67108864")).uint64
  result.gcMaxAgeSecs = parseUInt(config.getOrDefault("gc_max_age_secs", "43200")).uint64
  result.gcMaxRootCount = parseInt(config.getOrDefault("gc_max_root_count", "10"))
  initLock(result.lock)
  # Replay journal
  if result.path.len > 0 and result.path != ":memory:" and result.path != "":
    let journalPath = result.path / "journal" / "journal"
    if fileExists(journalPath):
      try:
        let data = readFile(journalPath)
        var pos = 0; var ops = newSeq[byte](0)
        while pos + 4 <= data.len:
          let klen = int(uint32(byte(data[pos])) shl 24 or uint32(byte(data[pos+1])) shl 16 or
                         uint32(byte(data[pos+2])) shl 8 or uint32(byte(data[pos+3])))
          pos += 4
          if pos + klen + 4 > data.len: break
          let cf = byte(data[pos])
          pos += klen
          let vlen = int(uint32(byte(data[pos])) shl 24 or uint32(byte(data[pos+1])) shl 16 or
                         uint32(byte(data[pos+2])) shl 8 or uint32(byte(data[pos+3])))
          pos += 4
          if pos + vlen > data.len: break
          pos += vlen
          if klen >= 20:
            ops.add(0'u8); ops.add(byte((klen shr 24) and 0xFF))
            ops.add(byte((klen shr 16) and 0xFF)); ops.add(byte((klen shr 8) and 0xFF))
            ops.add(byte(klen and 0xFF))
            for i in 0..<klen: ops.add(byte(data[pos - 4 - vlen - klen + i]))
          elif klen >= 1 and cf <= 3:
            ops.add(cf); ops.add(byte(((klen-1) shr 24) and 0xFF))
            ops.add(byte(((klen-1) shr 16) and 0xFF)); ops.add(byte(((klen-1) shr 8) and 0xFF))
            ops.add(byte((klen-1) and 0xFF))
            for i in 1..<klen: ops.add(byte(data[pos - 4 - vlen - klen + i]))
        if ops.len > 0: result.mtSize = result.mt.batch(ops)
      except: discard

proc close*(kv: KVStore) {.gcsafe.} =
  if kv != nil:
    kv.lock.withLock:
      if kv.ps != nil: closePageStore(kv.ps); kv.ps = nil

proc put*(kv: KVStore; cf: int; key: openArray[byte]) {.gcsafe.} =
  var k = newSeq[byte](key.len)
  if key.len > 0: copyMem(addr k[0], unsafeAddr key[0], key.len)
  kv.lock.withLock:
    kv.mtSize = kv.mt.put(cf, k)
    if kv.path.len > 0 and kv.path != ":memory:" and not kv.readOnly:
      try:
        let journalPath = kv.path / "journal" / "journal"
        createDir(parentDir(journalPath))
        var f = open(journalPath, fmAppend)
        var jk = newSeq[byte](1 + key.len)
        jk[0] = byte(cf)
        if key.len > 0: copyMem(addr jk[1], unsafeAddr key[0], key.len)
        let totKlen = 1 + key.len
        var hdr = newSeq[byte](4 + totKlen + 4 + 1)
        hdr[0] = byte((totKlen shr 24) and 0xFF); hdr[1] = byte((totKlen shr 16) and 0xFF)
        hdr[2] = byte((totKlen shr 8) and 0xFF); hdr[3] = byte(totKlen and 0xFF)
        copyMem(addr hdr[4], addr jk[0], totKlen)
        hdr[4 + totKlen] = 0; hdr[5 + totKlen] = 0; hdr[6 + totKlen] = 0; hdr[7 + totKlen] = 1
        hdr[8 + totKlen] = 0
        discard f.writeBytes(hdr, 0, hdr.len)
        f.close()
      except: discard

proc get*(kv: KVStore; cf: int; key: openArray[byte]): bool {.gcsafe.} =
  var k = newSeq[byte](key.len)
  if key.len > 0: copyMem(addr k[0], unsafeAddr key[0], key.len)
  var liveRoot, flushRoot: mt_be.TreapNode
  kv.lock.withLock:
    liveRoot = kv.mt.hnd.live[cf]
    if kv.flushRoots.len > 0:
      flushRoot = kv.flushRoots[cf]
  if liveRoot != nil and mt_be.containsKey(liveRoot, k): return true
  if flushRoot != nil and mt_be.containsKey(flushRoot, k): return true
  keyExists(kv.ps[], cf, k)

proc flush*(kv: KVStore) {.gcsafe.} =
  if kv.readOnly: return
  var roots: seq[mt_be.TreapNode]
  kv.lock.withLock:
    if kv.flushRoots.len > 0: return
    roots = kv.mt.hnd.live
    kv.mt.clear(); kv.mtSize = 0
    kv.flushRoots = roots
  var keysByCf: seq[(int, seq[seq[byte]])] = @[]
  for cf in 0..<kv.numCf:
    if roots[cf] != nil:
      var keys: seq[seq[byte]] = @[]
      let tc = newTreapCursor(roots[cf])
      while not tc.atEnd:
        let k = tc.next()
        if k.isSome: keys.add(k.get)
      if keys.len > 0: keysByCf.add (cf, keys)
  if keysByCf.len > 0: commitMerge(kv.ps[], keysByCf, true)
  kv.lock.withLock:
    kv.flushRoots = @[]; kv.mtSize = 0

proc batchWrite*(kv: KVStore; ops: openArray[byte]) {.gcsafe.} =
  kv.lock.withLock:
    if kv.path.len > 0 and kv.path != ":memory:" and not kv.readOnly:
      var journalPath = kv.path / "journal" / "journal"
      try:
        createDir(parentDir(journalPath)); var f = open(journalPath, fmAppend)
        let raw = cast[ptr UncheckedArray[byte]](unsafeAddr ops[0]); var pos = 0
        while pos + 5 <= ops.len:
          let cf = raw[pos]
          let klen = int(uint32(raw[pos+1]) shl 24 or uint32(raw[pos+2]) shl 16 or
                        uint32(raw[pos+3]) shl 8 or uint32(raw[pos+4]))
          let totKlen = 1 + klen
          var hdr = newSeq[byte](4 + totKlen + 4 + 1)
          hdr[0] = byte((totKlen shr 24) and 0xFF); hdr[1] = byte((totKlen shr 16) and 0xFF)
          hdr[2] = byte((totKlen shr 8) and 0xFF); hdr[3] = byte(totKlen and 0xFF)
          hdr[4] = cf
          if klen > 0: copyMem(addr hdr[5], addr raw[pos+5], klen)
          hdr[5+klen] = 0; hdr[6+klen] = 0; hdr[7+klen] = 0; hdr[8+klen] = 1; hdr[9+klen] = 0
          discard f.writeBytes(hdr, 0, hdr.len); pos += 5 + klen
        f.close()
      except: discard
    kv.mtSize = kv.mt.batch(ops)

proc memtableSize*(kv: KVStore): uint64 {.gcsafe.} = kv.mtSize

# ── Streaming scan entry point ──

proc openScanCursor*(kv: KVStore; cf: int): MergedCursor {.gcsafe.} =
  var sources: seq[Cursor] = @[]

  var psSnap: PageStoreSnapshot
  var flushRoot, liveRoot: mt_be.TreapNode

  kv.lock.withLock:
    let tree = kv.ps[].trees[cf]
    psSnap = PageStoreSnapshot(rootUuid: tree.rootUuid, height: tree.height)
    if kv.flushRoots.len > 0:
      flushRoot = kv.flushRoots[cf]
    liveRoot = kv.mt.hnd.live[cf]

  if psSnap.rootUuid != default(array[16, byte]):
    sources.add pageStoreCursor(PageStoreCursor(
      s: kv.ps, cf: cf, rootUuid: psSnap.rootUuid, height: psSnap.height))

  if flushRoot != nil:
    let tc = newTreapCursor(flushRoot)
    if not tc.atEnd:
      sources.add treapCursor(tc)

  if liveRoot != nil:
    let tc = newTreapCursor(liveRoot)
    if not tc.atEnd:
      sources.add treapCursor(tc)

  result = newMergedCursor(sources)
