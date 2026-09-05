## run_cursor.nim — cursor sobre um run ordenado imutável (M8).
##
## Seek = bisect nos ponteiros de registro; next = avanço de ponteiro.
## Sem readerCount, sem guard — o Run é imutável e o cursor o segura por
## ARC (a geração do arena morre junto quando o último cursor solta).
##
## Interface espelha a antiga TreapCursor 1:1 para o cursor.nim:
## peek/next (todas as chaves, inclusive tombstones), peekKv/nextKv
## (pula tombstones), nextDeleted (só tombstones), seek.

import std/options
import memtypes
import runs

type
  RunCursor* = ref object
    run: Run
    pos: int
    atEndF: bool

proc newRunCursor*(run: Run): RunCursor =
  result = RunCursor(run: run)
  result.atEndF = run == nil or run.ptrs.len == 0

proc seekStack(c: RunCursor; target: openArray[byte]) =
  ## Bisect: primeiro registro com chave >= target.
  let r = c.run
  var lo = 0
  var hi = r.ptrs.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    let p = r.ptrs[mid]
    let klen = recKlen(p)
    let kp = recKeyPtr(p)
    var cmpv = 0
    let n = min(klen, target.len)
    for j in 0 ..< n:
      if kp[j] != target[j]:
        cmpv = (if kp[j] < target[j]: -1 else: 1)
        break
    if cmpv == 0: cmpv = cmp(klen, target.len)
    if cmpv < 0: lo = mid + 1
    else: hi = mid
  c.pos = lo

proc advance(c: RunCursor) =
  if c.atEndF: return
  inc c.pos
  if c.pos >= c.run.ptrs.len: c.atEndF = true

proc ensure(c: RunCursor) =
  discard  # pos/atEndF são diretos — sem lazy current

proc peek*(c: RunCursor): Option[Key] =
  if c.atEndF or c.pos >= c.run.ptrs.len: return none(Key)
  let p = c.run.ptrs[c.pos]
  let klen = recKlen(p)
  var k = newSeq[byte](klen)
  if klen > 0: copyMem(addr k[0], recKeyPtr(p), klen)
  some(k)

proc next*(c: RunCursor): Option[Key] =
  result = c.peek()
  if result.isSome: c.advance()

proc peekKv*(c: RunCursor): Option[(seq[byte], seq[byte])] =
  ## Próximo par ativo (pula tombstones).
  while not c.atEndF:
    let p = c.run.ptrs[c.pos]
    if not recDeleted(p):
      let klen = recKlen(p)
      var k = newSeq[byte](klen)
      if klen > 0: copyMem(addr k[0], recKeyPtr(p), klen)
      let vlen = recVlen(p)
      var v = newSeq[byte](vlen)
      if vlen > 0: copyMem(addr v[0], recValuePtr(p), vlen)
      return some((k, v))
    c.advance()
  none((seq[byte], seq[byte]))

proc nextKv*(c: RunCursor): Option[(seq[byte], seq[byte])] =
  let got = c.peekKv()
  if got.isSome: c.advance()
  got

proc nextDeleted*(c: RunCursor): Option[seq[byte]] =
  ## Próxima tombstone (pula ativos).
  while not c.atEndF:
    let p = c.run.ptrs[c.pos]
    if recDeleted(p):
      let klen = recKlen(p)
      var k = newSeq[byte](klen)
      if klen > 0: copyMem(addr k[0], recKeyPtr(p), klen)
      c.advance()
      return some(k)
    c.advance()
  none(seq[byte])

proc seek*(c: RunCursor; target: Key) =
  c.seekStack(target)
  c.atEndF = c.pos >= c.run.ptrs.len

proc atEnd*(c: RunCursor): bool {.inline.} = c.atEndF

proc setAtEnd*(c: RunCursor; v: bool) {.inline.} =
  ## Para o invalidate() do cursor.nim.
  c.atEndF = v

proc release*(c: RunCursor) =
  ## Compat: runs são imutáveis — nada a soltar.
  discard
