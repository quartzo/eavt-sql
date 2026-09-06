## memtypes.nim — POD types shared by the memtable stack (M8).
##
## Extracted from the old treap_backend.nim: the byte arena, borrowed key
## views, write commands and the byte-lexicographic comparator.  No treap
## here — the memtable backend lives in runs.nim.

const
  KeyBlockSize* = 16 * 1024            ## bytes per key-arena block

type
  ArenaObj* = object
    keyBlocks*: seq[ptr UncheckedArray[byte]]
    keyBump*: int
    large*: seq[ptr UncheckedArray[byte]]  ## records larger than KeyBlockSize

  Arena* = ref ArenaObj

  Key* = seq[byte]
  Value* = seq[byte]

  KeyRef* = object
    ## Borrowed key bytes: pointer + length. Points into an arena (hot path)
    ## or into a caller-owned buffer (journal frames, tests).
    p*: ptr UncheckedArray[byte]
    len*: int

  CfKey* = object
    ## Write command: column family + key bytes.
    cf*: uint8
    key*: KeyRef

proc `=destroy`(a: var ArenaObj) =
  ## Free every block owned by the arena when its refcount drops to zero.
  ## Coarse lifetime: no per-record free — the whole generation dies at once.
  for b in a.keyBlocks: deallocShared(b)
  for b in a.large: deallocShared(b)
  a.keyBlocks = @[]; a.large = @[]

when defined(arenaRedzone):
  ## Modo de caça M9: cada registro é uma alocação própria com redzones
  ## envenenadas (ASan) — qualquer write além do `len` pedido dispara com
  ## o stack do culpado.  Uso: -d:arenaRedzone + ASan.  Perf irrelevante
  ## (só para depuração).
  proc asanPoison(p: pointer; size: int) {.importc: "__asan_poison_memory_region", noconv.}
  proc asanUnpoison(p: pointer; size: int) {.importc: "__asan_unpoison_memory_region", noconv.}
  const Redzone = 16

proc allocKeyBytes*(a: Arena; len: int): ptr UncheckedArray[byte] =
  ## Reserve `len` bytes in the arena. Records larger than a block get their
  ## own allocation (tracked in `large`, freed with the arena).
  if len <= 0: return nil
  when defined(arenaRedzone):
    let raw = cast[ptr UncheckedArray[byte]](allocShared0(len + 2 * Redzone))
    asanPoison(addr raw[0], Redzone)
    asanPoison(addr raw[Redzone + len], Redzone)
    a.large.add(raw)
    return cast[ptr UncheckedArray[byte]](addr raw[Redzone])
  if len > KeyBlockSize:
    let p = cast[ptr UncheckedArray[byte]](allocShared0(len))
    a.large.add(p)
    return p
  if a.keyBlocks.len == 0 or a.keyBump + len > KeyBlockSize:
    let b = cast[ptr UncheckedArray[byte]](allocShared0(KeyBlockSize))
    a.keyBlocks.add(b)
    a.keyBump = 0
  result = cast[ptr UncheckedArray[byte]](addr a.keyBlocks[^1][a.keyBump])
  inc a.keyBump, len

proc newArena*(): Arena =
  Arena(keyBlocks: @[], keyBump: 0, large: @[])

proc toKeyRef*(key: openArray[byte]): KeyRef =
  if key.len > 0:
    KeyRef(p: cast[ptr UncheckedArray[byte]](unsafeAddr key[0]), len: key.len)
  else:
    KeyRef(p: nil, len: 0)

proc toSeq*(k: KeyRef): seq[byte] =
  ## Owned copy of a borrowed key (journal replay, hydrated set, etc.).
  if k.len > 0:
    result = newSeqOfCap[byte](k.len)
    result.setLen(k.len)
    copyMem(addr result[0], k.p, k.len)
  else:
    result = @[]

proc cmpKeysByte*(a, b: seq[byte]): int =
  ## Byte-lexicographic key comparator (sort/merge helper).
  let n = min(a.len, b.len)
  for i in 0 ..< n:
    if a[i] != b[i]: return cmp(a[i], b[i])
  cmp(a.len, b.len)
