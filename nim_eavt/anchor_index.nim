## anchor_index.nim — packed hash [aid+val] → eid for UNIQUE attrs (M7).
##
## Permanent read index over the unique anchors, replacing the M3'
## `Table[seq[byte], (int64, int64)]`:
##   * records packed in a byte arena + stable-index rec array — no per-key
##     seq allocation (~40-60 B/âncora vs ~90-130 B na Table);
##   * probe is zero-alloc: FNV-1a over aid+val (no concatenation),
##     equality by memcmp into the arena;
##   * LRU eviction under `maxBytes` — an evicted (or never-cached) anchor
##     falls back to the CF-2 scan, which is always correct: the index is a
##     mirror kept current by batchWrite (write-through) and recovery.
##     Entradas nunca ficam stale: escrever atualiza/remove; evictar remove.
##
## Layout CF-2 espelhado: [aid 4B][val] → eid.  Sem t no registro: com o
## índice permanente não há publish-drop, e o t não tem consumidor de
## leitura (as-of no anchor precisaria de histórico — é scan).
##
## Single-threaded by construction (event loop); no locks.

import std/options

const
  DefaultAnchorMaxBytes* = 256 * 1024 * 1024  ## cfg `anchor_index_max_bytes`
  MinSlots = 1024                              ## potência de 2
  MaxKeyLen = 32_000                           ## teto do klen: int16
  EmptySlot = -1
  TombSlot = -2

type
  AnchorRec = object
    off: int32        ## AV bytes ([aid 4B][val]) no arena
    klen: int16       ## 4 + val.len
    slotPos: int32    ## posição no slots (O(1) tombstone na evicção)
    eid: int64
    prev, next: int32 ## LRU intrusiva por índice de rec (-1 = nenhum)
    live: bool

  AnchorIndex* = ref object
    slots: seq[int32]
    mask: int
    live: int
    tombs: int
    recs: seq[AnchorRec]
    free: seq[int32]    ## recs mortos reutilizáveis (índices estáveis)
    arena: seq[byte]
    head, tail: int32   ## LRU por índice de rec (-1 = sentinela)
    maxBytes*: int
    curBytes*: int      ## bytes vivos: arena(klen+8 por rec) + rec + slot
    hits*: int64
    misses*: int64
    evictions*: int64
    rehashes*: int64
    rejected*: int64    ## registro maior que o budget inteiro

proc newAnchorIndex*(maxBytes: int = DefaultAnchorMaxBytes): AnchorIndex =
  result = AnchorIndex(
    slots: @[EmptySlot.int32, EmptySlot.int32],  # cresce no primeiro rehash
    mask: 1,
    head: -1, tail: -1,
    maxBytes: maxBytes,
  )

proc len*(idx: AnchorIndex): int {.inline.} = idx.live

proc bytes*(idx: AnchorIndex): int {.inline.} = idx.curBytes

# ── diagnóstico (testes/admin) ────────────────────────────────────────────────

proc capacity*(idx: AnchorIndex): int {.inline.} = idx.slots.len
proc tombsCount*(idx: AnchorIndex): int {.inline.} = idx.tombs
proc recsLen*(idx: AnchorIndex): int {.inline.} = idx.recs.len
proc arenaLen*(idx: AnchorIndex): int {.inline.} = idx.arena.len

proc rehash(idx: AnchorIndex; newCap: int)  # forward (definida adiante)

proc rehashForTest*(idx: AnchorIndex) =
  ## Compaction exposure for tests (same-size rehash).
  idx.rehash(idx.slots.len)

# ── hash / comparação (zero-alloc — sem concatenação) ────────────────────────

proc fnv(aid: uint32; val: openArray[byte]): uint64 {.inline.} =
  var h = 0xcbf29ce484222325'u64
  h = (h xor uint64(byte(aid shr 24))) * 0x100000001b3'u64
  h = (h xor uint64(byte((aid shr 16) and 0xFF))) * 0x100000001b3'u64
  h = (h xor uint64(byte((aid shr 8) and 0xFF))) * 0x100000001b3'u64
  h = (h xor uint64(byte(aid and 0xFF))) * 0x100000001b3'u64
  for b in val:
    h = (h xor uint64(b)) * 0x100000001b3'u64
  h

proc keyEq(idx: AnchorIndex; r: int; aid: uint32; val: openArray[byte]): bool {.
    inline.} =
  let rec = addr idx.recs[r]
  if rec.klen.int != 4 + val.len: return false
  let off = rec.off.int
  if byte(aid shr 24) != idx.arena[off] or
     byte((aid shr 16) and 0xFF) != idx.arena[off + 1] or
     byte((aid shr 8) and 0xFF) != idx.arena[off + 2] or
     byte(aid and 0xFF) != idx.arena[off + 3]:
    return false
  for i, b in val:
    if idx.arena[off + 4 + i] != b: return false
  true

# ── LRU intrusiva (por índice de rec) ─────────────────────────────────────────

proc lruUnlink(idx: AnchorIndex; i: int32) {.inline.} =
  let r = addr idx.recs[i]
  if r.prev >= 0: idx.recs[r.prev].next = r.next else: idx.head = r.next
  if r.next >= 0: idx.recs[r.next].prev = r.prev else: idx.tail = r.prev
  r.prev = -1
  r.next = -1

proc lruPush(idx: AnchorIndex; i: int32) {.inline.} =
  idx.recs[i].prev = -1
  idx.recs[i].next = idx.head
  if idx.head >= 0: idx.recs[idx.head].prev = i else: idx.tail = i
  idx.head = i

proc touch(idx: AnchorIndex; i: int32) {.inline.} =
  if idx.head != i:
    idx.lruUnlink(i)
    idx.lruPush(i)

# ── probe / busca de slot ─────────────────────────────────────────────────────

proc findSlot(idx: AnchorIndex; aid: uint32; val: openArray[byte];
              h: uint64): tuple[pos: int, rec: int32, tomb: int] =
  ## pos = slot do hit ou do ponto de inserção (primeiro tomb reutilizável
  ## ou o empty que encerra a sonda); rec = índice do rec no hit (-1 miss);
  ## tomb = primeiro tombstone da sonda (-1 se não houver).
  result.tomb = -1
  result.rec = -1
  var p = int(h and uint64(idx.mask))   # máscara ANTES do cast — int(h) estoura
  while true:
    let s = idx.slots[p]
    if s == EmptySlot:
      result.pos = (if result.tomb >= 0: result.tomb else: p)
      return
    if s == TombSlot:
      if result.tomb < 0: result.tomb = p
    elif idx.keyEq(s, aid, val):
      result.pos = p
      result.rec = s
      return
    p = (p + 1) and idx.mask

proc probe*(idx: AnchorIndex; aid: uint32; val: openArray[byte]): Option[int64] =
  ## O(1) zero-alloc: hash incremental sobre aid+val, igualdade por memcmp
  ## na arena.  Touch LRU no hit.
  if idx.live == 0:
    inc idx.misses
    return none(int64)
  let (pos, rec, _) = idx.findSlot(aid, val, fnv(aid, val))
  if rec >= 0:
    idx.touch(rec)
    inc idx.hits
    return some(idx.recs[rec].eid)
  inc idx.misses
  discard pos

# ── remoção (tombstone + LRU + free-list) ─────────────────────────────────────

proc killRec(idx: AnchorIndex; r: int32) {.inline.} =
  ## Tombstone O(1) via rec.slotPos — sem re-probe.  Os bytes na arena
  ## permanecem até a compactação do rehash (curBytes desconta na hora).
  let rec = addr idx.recs[r]
  idx.slots[rec.slotPos] = TombSlot
  inc idx.tombs
  idx.lruUnlink(r)
  rec.live = false
  rec.prev = -1
  rec.next = -1
  rec.slotPos = EmptySlot
  idx.free.add(r)
  dec idx.live
  dec idx.curBytes, rec.klen.int + 8 + sizeof(AnchorRec) + 4

proc del*(idx: AnchorIndex; aid: uint32; val: openArray[byte]) =
  if idx.live == 0: return
  let (_, rec, _) = idx.findSlot(aid, val, fnv(aid, val))
  if rec >= 0:
    idx.killRec(rec)

# ── rehash (slots rebuild; arena compaction in-place) ─────────────────────────

proc fnvAt(idx: AnchorIndex; off: int; klen: int): uint64 {.inline.} =
  ## FNV sobre klen bytes do arena a partir de off — sem toOpenArray
  ## (val vazio ⇒ klen=4 ⇒ slice first>last seria RangeDefect).
  var h = 0xcbf29ce484222325'u64
  for i in 0 ..< klen:
    h = (h xor uint64(idx.arena[off + i])) * 0x100000001b3'u64
  h

proc rehash(idx: AnchorIndex; newCap: int) =
  ## Reconstrói os slots (índices de rec são ESTÁVEIS — a LRU não mexe) e
  ## compacta o arena (offs reescritos por rec, bytes mortos descartados).
  var newSlots = newSeq[int32](newCap)
  for i in 0 ..< newCap: newSlots[i] = EmptySlot
  var total = 0
  for r in 0 ..< idx.recs.len:
    if idx.recs[r].live: inc total, idx.recs[r].klen.int
  var newArena = newSeq[byte](total)
  var write = 0
  for r in 0 ..< idx.recs.len:
    let rec = addr idx.recs[r]
    if not rec.live: continue
    let klen = rec.klen.int
    let h = idx.fnvAt(rec.off.int, klen)
    var p = int(h and uint64(newCap - 1))
    while newSlots[p] != EmptySlot: p = (p + 1) and (newCap - 1)
    newSlots[p] = int32(r)
    rec.slotPos = int32(p)
    if klen > 0:
      copyMem(addr newArena[write], addr idx.arena[rec.off.int], klen)
    rec.off = int32(write)
    inc write, klen
  idx.slots = newSlots
  idx.mask = newCap - 1
  idx.arena = newArena
  idx.tombs = 0
  inc idx.rehashes

# ── inserção ──────────────────────────────────────────────────────────────────

proc evictUntilFits(idx: AnchorIndex; incoming: int) =
  ## Evicta a cauda LRU até `incoming` caber.  Registro maior que o budget
  ## inteiro: tratado pelo chamador (não insere).
  while idx.curBytes + incoming > idx.maxBytes and idx.live > 0:
    let v = idx.tail
    if v < 0: break
    idx.killRec(v)
    inc idx.evictions

proc put*(idx: AnchorIndex; aid: uint32; val: openArray[byte]; eid: int64) =
  ## Write-through: existe → atualiza eid + touch; novo → insere com
  ## admissão por budget (LRU evict).  Chave maior que o budget inteiro
  ## não entra (fallback scan cobre).
  if 4 + val.len > MaxKeyLen:
    inc idx.rejected
    return
  let klen = 4 + val.len
  let entryBytes = klen + 8 + sizeof(AnchorRec) + 4  # arena + eid + rec + slot
  # capacidade ANTES de sondar: garante ≥1 slot Empty (findSlot de put não
  # pode varrer uma tabela só de tombs — loop infinito)
  # capacidade: cresce/compacta antes de inserir quando o fill passa de 0.7
  # (e ANTES de sondar: findSlot de put precisa de ≥1 Empty na tabela)
  if (idx.live + idx.tombs + 1) * 10 >= idx.slots.len * 7:
    if idx.tombs > idx.live div 4:
      idx.rehash(idx.slots.len)              # compacta mesmo tamanho
    else:
      idx.rehash(max(MinSlots, idx.slots.len * 2))
  let (pos, rec, _) = idx.findSlot(aid, val, fnv(aid, val))
  if rec >= 0:
    idx.recs[rec].eid = eid
    idx.touch(rec)
    return
  if entryBytes > idx.maxBytes:
    inc idx.rejected
    return
  let r: int32 =
    if idx.free.len > 0: idx.free.pop()
    else:
      idx.recs.add AnchorRec()
      int32(idx.recs.len - 1)
  let p = pos   # sem rehash pós-findSlot: pos é válido (tomb reutilizável ou empty)
  idx.evictUntilFits(entryBytes)
  let rec2 = addr idx.recs[r]
  rec2.off = int32(idx.arena.len)
  rec2.klen = int16(klen)
  rec2.slotPos = int32(p)
  rec2.eid = eid
  rec2.live = true
  idx.arena.setLen(idx.arena.len + klen)
  idx.arena[rec2.off.int] = byte(aid shr 24)
  idx.arena[rec2.off.int + 1] = byte((aid shr 16) and 0xFF)
  idx.arena[rec2.off.int + 2] = byte((aid shr 8) and 0xFF)
  idx.arena[rec2.off.int + 3] = byte(aid and 0xFF)
  if val.len > 0:
    copyMem(addr idx.arena[rec2.off.int + 4], unsafeAddr val[0], val.len)
  idx.slots[p] = r
  inc idx.live
  inc idx.curBytes, entryBytes
  idx.lruPush(r)

proc clear*(idx: AnchorIndex) =
  idx.slots = newSeq[int32](MinSlots)
  for i in 0 ..< MinSlots: idx.slots[i] = EmptySlot
  idx.mask = MinSlots - 1
  idx.live = 0
  idx.tombs = 0
  idx.recs = @[]
  idx.free = @[]
  idx.arena = @[]
  idx.head = -1
  idx.tail = -1
  idx.curBytes = 0
