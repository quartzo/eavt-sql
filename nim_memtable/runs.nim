## runs.nim — memtable como escada de runs ordenados (M8).
##
## Substitui o treap COW: escritas fazem append O(1) de um registro
## auto-descritivo no arena da geração; a materialização (scan/flush/merge)
## ordena só o delta desde a última; as queries consomem runs imutáveis por
## bisect — sem readerCount, sem path-copy, sem rotações.
##
## Registro no arena (auto-contido, o put copia os bytes da chave):
##   key-only: [flags:u8][klen:u32 BE][key]               (flags = 0)
##   kv:       [flags:u8][klen:u32 BE][key][vlen:u32 BE][value]
##             bit0 de flags = tombstone.
## A chave começa SEMPRE em p+5 — comparação unificada nos dois formatos.
##
## Escada por CF: buf (delta não ordenado, append) → runs ativos (antigo →
## novo, ordenados, ≤ 8 — merge de offsets quando passa) → draining
## (capturados pelo flush, legíveis até o publish).  Entre captures há UMA
## geração de arena: runs ativos compartilham o bufArena, então o merge é
## concat+sort de ponteiros (zero byte copy).
##
## Recência: buf (mais novo, varredura backward) → runs do fim pro começo →
## draining.  Duplicatas de chave: dedup mantendo a versão mais nova
## (materialize e drainSorted).  Sem lock — KVStore serializa escritas.

import std/[options, algorithm]
import memtypes

const MaxActiveRuns = 8
const MaxBufEntries = 65536   ## M9: teto do delta antes de materializar
                              ## incrementalmente (buf gigante → sort/alloc
                              ## de 8MB+ num tiro — e o crash do estabs@1M
                              ## acontece exatamente nesse materialize)

type
  Run* = ref object
    ptrs*: seq[ptr UncheckedArray[byte]]  ## ordenados → registros no arena
    arena*: Arena                          ## geração dona dos bytes
    kv*: bool

  MemTable* = ref object
    numCf*: int
    gen*: uint64                ## bump em materialize/merge/freeze/publish
    runs*: seq[seq[Run]]        ## ativos por CF (antigo → novo)
    draining*: seq[seq[Run]]    ## capturados por CF (pending flush publish)
    buf*: seq[seq[ptr UncheckedArray[byte]]]  ## delta não ordenado por CF
    bufArena*: Arena
    cfSize*: seq[int]           ## bytes de chave ativos por CF (threshold)

  KvLookup* = enum
    klAbsent   ## não está no memtable (consultar pagestore)
    klDeleted  ## presente como tombstone
    klValue    ## presente ativo

# ── acesso a registro (layout unificado) ──────────────────────────────────────

proc recKlen*(p: ptr UncheckedArray[byte]): int {.inline.} =
  (int(p[1]) shl 24) or (int(p[2]) shl 16) or (int(p[3]) shl 8) or int(p[4])

proc recDeleted*(p: ptr UncheckedArray[byte]): bool {.inline.} =
  (p[0] and 1) != 0

proc recKeyPtr*(p: ptr UncheckedArray[byte]): ptr UncheckedArray[byte] {.inline.} =
  cast[ptr UncheckedArray[byte]](addr p[5])

proc recVlen*(p: ptr UncheckedArray[byte]): int {.inline.} =
  let klen = recKlen(p)
  (int(p[5 + klen]) shl 24) or (int(p[6 + klen]) shl 16) or
  (int(p[7 + klen]) shl 8) or int(p[8 + klen])

proc recValuePtr*(p: ptr UncheckedArray[byte]): ptr UncheckedArray[byte] {.inline.} =
  cast[ptr UncheckedArray[byte]](addr p[9 + recKlen(p)])

proc cmpRec*(a, b: ptr UncheckedArray[byte]): int {.inline.} =
  ## Byte-lexicográfico pela chave (klen em p+1, key em p+5).
  let alen = recKlen(a)
  let blen = recKlen(b)
  let ka = recKeyPtr(a)
  let kb = recKeyPtr(b)
  let n = min(alen, blen)
  for i in 0 ..< n:
    if ka[i] != kb[i]:
      return if ka[i] < kb[i]: -1 else: 1
  cmp(alen, blen)

# ── construtores ──────────────────────────────────────────────────────────────

proc newMemTable*(numCf: int): MemTable =
  if numCf <= 0: raise newException(ValueError, "numCf must be > 0")
  result = MemTable(
    numCf: numCf,
    runs: newSeq[seq[Run]](numCf),
    draining: newSeq[seq[Run]](numCf),
    buf: newSeq[seq[ptr UncheckedArray[byte]]](numCf),
    bufArena: newArena(),
    cfSize: newSeq[int](numCf),
  )

proc size*(mt: MemTable): uint64 =
  var sz = 0
  for s in mt.cfSize: sz += s
  cast[uint64](sz)

proc arenaScratch*(mt: MemTable): Arena {.inline.} =
  ## Arena de rascunho para quem pré-escreve bytes antes do put (o put
  ## copia para o registro — o rascunho morre com a geração).
  mt.bufArena

# ── escrita (append O(1), registro copiado) ───────────────────────────────────


proc sortIdx*(order: var seq[int]; cmp: proc (a, b: int): int {.gcsafe, raises: [].}) =
  ## Heapsort in-place sobre índices com comparator raises-free — o sort
  ## da std injeta `raises: Exception` pelo tipo do closure, quebrando a
  ## inferência de batchMove → put → materialize (contexto restrito).
  let n = order.len
  if n < 2: return
  var start = n div 2 - 1
  while start >= 0:
    var root = start
    while true:
      let l = 2 * root + 1
      let r = l + 1
      var m = root
      if l < n and cmp(order[l], order[m]) > 0: m = l
      if r < n and cmp(order[r], order[m]) > 0: m = r
      if m == root: break
      swap(order[root], order[m])
      root = m
    dec start
  for e in countdown(n - 1, 1):
    swap(order[0], order[e])
    var root = 0
    while true:
      let l = 2 * root + 1
      let r = l + 1
      var m = root
      if l < e and cmp(order[l], order[m]) > 0: m = l
      if r < e and cmp(order[r], order[m]) > 0: m = r
      if m == root: break
      swap(order[root], order[m])
      root = m

proc materialize(mt: MemTable; cf: int) {.gcsafe, raises: [].}   # fwd
proc maybeMerge(mt: MemTable; cf: int) {.gcsafe, raises: [].}   # forward (definida adiante)

proc appendRec(mt: MemTable; cf: int; klen: int; deleted: bool;
               key: openArray[byte]; value: openArray[byte]): uint64 {.
    gcsafe, raises: [].} =
  let vlen = if cf >= 10: value.len else: 0
  let total = 5 + klen + (if cf >= 10: 4 + vlen else: 0)
  let p = mt.bufArena.allocKeyBytes(total)
  p[0] = byte((if deleted: 1 else: 0) or (if cf >= 10: 2 else: 0))
  p[1] = byte((klen shr 24) and 0xFF); p[2] = byte((klen shr 16) and 0xFF)
  p[3] = byte((klen shr 8) and 0xFF); p[4] = byte(klen and 0xFF)
  if klen > 0: copyMem(addr p[5], unsafeAddr key[0], klen)
  if cf >= 10:
    p[5 + klen] = byte((vlen shr 24) and 0xFF); p[6 + klen] = byte((vlen shr 16) and 0xFF)
    p[7 + klen] = byte((vlen shr 8) and 0xFF); p[8 + klen] = byte(vlen and 0xFF)
    if vlen > 0: copyMem(addr p[9 + klen], unsafeAddr value[0], vlen)
  mt.buf[cf].add(p)
  mt.cfSize[cf] += klen
  if mt.buf[cf].len >= MaxBufEntries:
    mt.materialize(cf)
    mt.maybeMerge(cf)
  mt.size()

proc put*(mt: MemTable; cf: int; key: openArray[byte]): uint64 {.raises: [ValueError].} =
  if cf < 0 or cf >= mt.numCf: raise newException(ValueError, "invalid cf")
  mt.appendRec(cf, key.len, false, key, [])

proc putKv*(mt: MemTable; cf: int; key, value: openArray[byte]): uint64 =
  if cf < 0 or cf >= mt.numCf: raise newException(ValueError, "invalid cf")
  mt.appendRec(cf, key.len, false, key, value)

proc deleteKv*(mt: MemTable; cf: int; key: openArray[byte]) =
  if cf < 0 or cf >= mt.numCf: raise newException(ValueError, "invalid cf")
  discard mt.appendRec(cf, key.len, true, key, [])

proc batchMove*(mt: MemTable; entries: var seq[CfKey]): uint64 {.raises: [ValueError].} =
  ## M8: copia os bytes para o registro (o contrato de referência do treap
  ## morreu — chaves emprestadas de frames WAL/scratch são bem-vindas).
  for i in 0 ..< entries.len:
    let cf = entries[i].cf.int
    if cf < 0 or cf >= mt.numCf: continue
    discard mt.put(cf, entries[i].key.toSeq())
  mt.size()

proc batch*(mt: MemTable; entries: seq[CfKey]): uint64 =
  for e in entries:
    let cf = e.cf.int
    if cf < 0 or cf >= mt.numCf: continue
    discard mt.put(cf, e.key.toSeq())
  mt.size()

# ── materialização / merge ────────────────────────────────────────────────────

proc materialize(mt: MemTable; cf: int) =
  ## Sort do delta do CF → run (dedup: igual-adjacente mantém o mais novo —
  ## sort decorado por (chave, índice de append) com dedup do maior índice).
  if mt.buf[cf].len == 0: return
  var bufSum = 0
  for p in mt.buf[cf]: inc bufSum, recKlen(p)
  var order = newSeq[int](mt.buf[cf].len)
  for i in 0 ..< order.len: order[i] = i
  let bufAddr = addr mt.buf[cf]
  sortIdx(order, proc (a, b: int): int {.gcsafe, raises: [].} =
    let c = cmpRec(bufAddr[][a], bufAddr[][b])
    if c != 0: return c
    return cmp(a, b)   # empate: append mais tarde = mais novo
  )
  var ptrs = newSeqOfCap[ptr UncheckedArray[byte]](order.len)
  var keptBytes = 0
  var i = 0
  while i < order.len:
    # último de cada grupo igual = mais novo
    var j = i
    while j + 1 < order.len and
          cmpRec(bufAddr[][order[j]], bufAddr[][order[j + 1]]) == 0: inc j
    ptrs.add(bufAddr[][order[j]])
    inc keptBytes, recKlen(bufAddr[][order[j]])
    i = j + 1
  mt.runs[cf].add(Run(ptrs: ptrs, arena: mt.bufArena,
                      kv: cf >= 10))
  mt.buf[cf] = @[]
  # contagem: o buf tinha duplicatas — cfSize perde só o que o dedup cortou
  mt.cfSize[cf] -= bufSum - keptBytes
  inc mt.gen

proc maybeMerge(mt: MemTable; cf: int) {.gcsafe, raises: [].} =
  ## Escada passa de MaxActiveRuns: merge dos ativos (arena compartilhada —
  ## concat+sort de ponteiros; recência: run mais novo ganha no empate).
  if mt.runs[cf].len <= MaxActiveRuns: return
  var merged = newSeqOfCap[ptr UncheckedArray[byte]](0)
  var origin = newSeq[int](0)   # runIdx de cada ptr (recência: maior = novo)
  for ri, r in mt.runs[cf]:
    for p in r.ptrs:
      merged.add(p)
      origin.add(ri)
  var order = newSeq[int](merged.len)
  for i in 0 ..< order.len: order[i] = i
  sortIdx(order, proc (a, b: int): int {.gcsafe, raises: [].} =
    let c = cmpRec(merged[a], merged[b])
    if c != 0: return c
    return cmp(origin[a], origin[b])   # mais novo por último → dedup fica com ele
  )
  var ptrs = newSeqOfCap[ptr UncheckedArray[byte]](order.len)
  var i = 0
  while i < order.len:
    var j = i
    while j + 1 < order.len and
          cmpRec(merged[order[j]], merged[order[j + 1]]) == 0: inc j
    ptrs.add(merged[order[j]])
    i = j + 1
  let arena = mt.runs[cf][^1].arena
  mt.runs[cf] = @[Run(ptrs: ptrs, arena: arena, kv: cf >= 10)]
  inc mt.gen

proc ensureMaterialized*(mt: MemTable; cf: int) =
  ## Ponto de entrada dos scans: materializa o delta do CF antes de coletar
  ## fontes (bisect só enxerga runs). Gen bump garante rebuild dos cursores.
  mt.materialize(cf)
  mt.maybeMerge(cf)

proc maybeCapBuf*(mt: MemTable; cf: int) =
  ## Delta acima do teto → materializa incrementalmente (M9): evita o
  ## sort/newSeqOfCap gigante que crasha no estabs@1M.
  if mt.buf[cf].len >= MaxBufEntries:
    mt.materialize(cf)
    mt.maybeMerge(cf)

proc materializeAll*(mt: MemTable) =
  for cf in 0 ..< mt.numCf:
    mt.materialize(cf)
    mt.maybeMerge(cf)

# ── captura / publish ─────────────────────────────────────────────────────────

proc freezeAll*(mt: MemTable) =
  ## Captura (flush/seal): delta → run, ativos → draining, geração nova.
  ## Os draining continuam legíveis (cursors seguram o Run por ARC) até o
  ## publish — o "flushRoots" de hoje.
  mt.materializeAll()
  for cf in 0 ..< mt.numCf:
    mt.draining[cf] = mt.runs[cf]
    mt.runs[cf] = @[]
    mt.buf[cf] = @[]
    mt.cfSize[cf] = 0
  mt.bufArena = newArena()
  inc mt.gen

proc publish*(mt: MemTable) =
  ## Flush publicado: draining vira pagestore — descartado.
  for cf in 0 ..< mt.numCf: mt.draining[cf] = @[]
  inc mt.gen

proc clear*(mt: MemTable) =
  for cf in 0 ..< mt.numCf:
    mt.runs[cf] = @[]
    mt.draining[cf] = @[]
    mt.buf[cf] = @[]
    mt.cfSize[cf] = 0
  mt.bufArena = newArena()
  inc mt.gen

# ── leitura pontual (KV e contains) ───────────────────────────────────────────

proc findBuf(mt: MemTable; cf: int; key: openArray[byte]): ptr UncheckedArray[byte] =
  ## Match mais novo no delta (varredura backward — buf não é ordenado).
  var i = mt.buf[cf].len - 1
  while i >= 0:
    let p = mt.buf[cf][i]
    let klen = recKlen(p)
    if klen == key.len:
      let kp = recKeyPtr(p)
      var eq = true
      for j in 0 ..< klen:
        if kp[j] != key[j]: eq = false; break
      if eq: return p
    dec i
  nil

proc findRun(r: Run; key: openArray[byte]): ptr UncheckedArray[byte] =
  ## Bisect: primeiro registro com chave >= key; match exato ou nil.
  var lo = 0
  var hi = r.ptrs.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    let p = r.ptrs[mid]
    let klen = recKlen(p)
    let kp = recKeyPtr(p)
    var c = 0
    let n = min(klen, key.len)
    for j in 0 ..< n:
      if kp[j] != key[j]: c = (if kp[j] < key[j]: -1 else: 1); break
    if c == 0: c = cmp(klen, key.len)
    if c < 0: lo = mid + 1
    else: hi = mid
  if lo < r.ptrs.len:
    let p = r.ptrs[lo]
    if recKlen(p) == key.len:
      let kp = recKeyPtr(p)
      var eq = true
      for j in 0 ..< key.len:
        if kp[j] != key[j]: eq = false; break
      if eq: return p
  nil

proc lookupKv*(mt: MemTable; cf: int; key: openArray[byte]): KvLookup =
  ## Recência: buf (backward) → runs do fim pro começo → draining (o mais
  ## novo primeiro).  Tombstone presente ⇒ klDeleted (não consultar ps).
  let b = mt.findBuf(cf, key)
  if b != nil:
    return (if recDeleted(b): klDeleted else: klValue)
  for i in countdown(mt.runs[cf].len - 1, 0):
    let p = mt.runs[cf][i].findRun(key)
    if p != nil:
      return (if recDeleted(p): klDeleted else: klValue)
  for i in countdown(mt.draining[cf].len - 1, 0):
    let p = mt.draining[cf][i].findRun(key)
    if p != nil:
      return (if recDeleted(p): klDeleted else: klValue)
  klAbsent

proc getValue*(mt: MemTable; cf: int; key: openArray[byte]): Option[Value] =
  case mt.lookupKv(cf, key)
  of klValue:
    # re-localiza: mesmo caminho do lookupKv (barato; KV é frio)
    let b = mt.findBuf(cf, key)
    if b != nil and not recDeleted(b):
      let vlen = recVlen(b)
      var v = newSeq[byte](vlen)
      if vlen > 0: copyMem(addr v[0], recValuePtr(b), vlen)
      return some(v)
    for i in countdown(mt.runs[cf].len - 1, 0):
      let p = mt.runs[cf][i].findRun(key)
      if p != nil and not recDeleted(p):
        let vlen = recVlen(p)
        var v = newSeq[byte](vlen)
        if vlen > 0: copyMem(addr v[0], recValuePtr(p), vlen)
        return some(v)
    for i in countdown(mt.draining[cf].len - 1, 0):
      let p = mt.draining[cf][i].findRun(key)
      if p != nil and not recDeleted(p):
        let vlen = recVlen(p)
        var v = newSeq[byte](vlen)
        if vlen > 0: copyMem(addr v[0], recValuePtr(p), vlen)
        return some(v)
    none(Value)
  else: none(Value)

proc containsAny*(mt: MemTable; cf: int; key: openArray[byte]): bool =
  ## Chave presente em qualquer estado (inclusive tombstone) no memtable.
  case mt.lookupKv(cf, key)
  of klAbsent: false
  else: true

# ── drain (flush) — k-way sobre runs congelados, newest-wins ─────────────────

proc drainSorted*(runs: seq[Run]): seq[seq[byte]] =
  ## Chaves em ordem ascendente, dedup exato (run mais novo vence).
  ## runs em ordem antigo → novo.
  let k = runs.len
  if k == 0: return
  var heads = newSeq[int](k)
  var total = 0
  for r in runs: total += r.ptrs.len
  result = newSeqOfCap[seq[byte]](total)
  while true:
    # menor chave entre as cabeças; empate → run mais novo (maior índice)
    var best = -1
    for i in 0 ..< k:
      if heads[i] >= runs[i].ptrs.len: continue
      if best < 0:
        best = i
        continue
      let c = cmpRec(runs[i].ptrs[heads[i]], runs[best].ptrs[heads[best]])
      if c < 0 or (c == 0 and i > best):
        best = i
    if best < 0: break
    let win = runs[best].ptrs[heads[best]]
    let winKlen = recKlen(win)
    var key = newSeq[byte](winKlen)
    if winKlen > 0: copyMem(addr key[0], recKeyPtr(win), winKlen)
    result.add(key)
    inc heads[best]
    # suprime duplicatas da mesma chave em runs mais velhos
    for i in 0 ..< k:
      if i == best: continue
      while heads[i] < runs[i].ptrs.len and
            cmpRec(runs[i].ptrs[heads[i]], win) == 0:
        inc heads[i]

proc drainKvSorted*(runs: seq[Run]):
    tuple[pairs: seq[(seq[byte], seq[byte])], deleted: seq[seq[byte]]] =
  ## KV: pares ativos + tombstones, newest-wins por chave.
  let k = runs.len
  if k == 0: return
  var heads = newSeq[int](k)
  var total = 0
  for r in runs: total += r.ptrs.len
  result.pairs = newSeqOfCap[(seq[byte], seq[byte])](total)
  while true:
    var best = -1
    for i in 0 ..< k:
      if heads[i] >= runs[i].ptrs.len: continue
      if best < 0:
        best = i
        continue
      let c = cmpRec(runs[i].ptrs[heads[i]], runs[best].ptrs[heads[best]])
      if c < 0 or (c == 0 and i > best):
        best = i
    if best < 0: break
    let win = runs[best].ptrs[heads[best]]
    let winKlen = recKlen(win)
    var key = newSeq[byte](winKlen)
    if winKlen > 0: copyMem(addr key[0], recKeyPtr(win), winKlen)
    if recDeleted(win):
      result.deleted.add(key)
    else:
      let vlen = recVlen(win)
      var v = newSeq[byte](vlen)
      if vlen > 0: copyMem(addr v[0], recValuePtr(win), vlen)
      result.pairs.add((key, v))
    inc heads[best]
    for i in 0 ..< k:
      if i == best: continue
      while heads[i] < runs[i].ptrs.len and
            cmpRec(runs[i].ptrs[heads[i]], win) == 0:
        inc heads[i]
