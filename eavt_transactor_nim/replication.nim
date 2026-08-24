## replication.nim — Push-based replication hub for the transactor.
##
## The server registers its WAL sink, seal and root publish hooks through
## the replication hub.  Connected replicas receive:
##
##   1. snapshot: sealed segment paths (immutable on shared fs) +
##      open-tail bytes (the volatile in-memory buffer) + root + blob dir
##   2. wal : immediate forward of every journal record (the sink callback,
##             under kv.lock — only memcpy here, socket writes are async)
##   3. seal: segment rotation (live treap → pending; fresh live takes over)
##   4. root: flush published — load new root, discard pending treap
##
## Protocol: length-prefixed msgpack frames (same framing as client protocol),
## one-way server → replica, keyed by "ev" field.

import std/[os, strutils, algorithm, streams]
import msgpack4nim
import chronos
import kvstore
import common
import wire
import logutil

# ── Subscriber ──────────────────────────────────────────────────────────────

type
  EvKind* = enum evWal, evSeal, evRoot

  Ev = object
    case kind: EvKind
    of evWal: data: seq[byte]
    of evSeal: idx: int
    of evRoot: name: string

  Subscriber* = ref object
    transp*: StreamTransport
    ## Ordenação de geração à prova de batching: wal acumula em `buf` (append
    ## quente, um memcpy); ao ENFILEIRAR um marcador (seal/root), o buf
    ## pendente é descarregado na fila ANTES do marcador — um frame wal nunca
    ## atravessa uma fronteira de geração. As três filas paralelas antigas
    ## drenavam buf-primeiro invertendo essa fronteira quando escritas
    ## pós-captura entravam antes do tick (réplica selava pós-seal junto com
    ## pré-seal; o root descartava a diferença → perda intermitente de db.*).
    buf: seq[byte]
    queue: seq[Ev]
    closed*: bool

proc flushBuf(s: Subscriber) =
  ## Descarrega wal pendente como evento ANTES do marcador seguinte.
  if s.buf.len > 0:
    s.queue.add Ev(kind: evWal, data: s.buf)
    s.buf = @[]

proc sendFrame(s: Subscriber; body: string) {.async.} =
  if s.closed: return
  var frame = newSeq[byte](4 + body.len)
  frame[0] = byte(body.len shr 24); frame[1] = byte(body.len shr 16)
  frame[2] = byte(body.len shr 8); frame[3] = byte(body.len)
  if body.len > 0:
    copyMem(addr frame[4], unsafeAddr body[0], body.len)
  try:
    discard await s.transp.write(frame)
  except CatchableError:
    s.closed = true

proc sendEvent(s: Subscriber; body: string) {.async.} =
  await s.sendFrame(body)

# ── Frame builders (puros — testáveis sem socket) ───────────────────────────

proc walFrame*(data: seq[byte]): string =
  var ms = MsgStream.init(64 + data.len)
  ms.pack_map(2)
  ms.pack("ev"); ms.pack("wal")
  ms.pack("data")
  ms.pack_bin(data.len)
  if data.len > 0:
    var tmp = newString(data.len)
    copyMem(addr tmp[0], unsafeAddr data[0], data.len)
    appendRaw(ms, tmp)
  ms.data

proc sealFrame*(idx: int): string =
  var ms = MsgStream.init(32)
  ms.pack_map(2)
  ms.pack("ev"); ms.pack("seal")
  ms.pack("idx"); ms.pack(idx)
  ms.data

proc rootFrame*(name: string): string =
  var ms = MsgStream.init(64)
  ms.pack_map(2)
  ms.pack("ev"); ms.pack("root")
  ms.pack("name"); ms.pack(name)
  ms.data

## Monta os frames SAÍDA na ordem exata da fila — sem tocar socket.
proc collectOutgoing*(s: Subscriber): seq[string] =
  ## Eventos wal CONSECUTIVOS agregam-se num único frame (como no formato
  ## antigo); o marcador seal/root sempre fecha o frame corrente — uma
  ## fronteira de geração nunca é atravessada por bytes de outra geração.
  result = @[]
  var i = 0
  while i < s.queue.len:
    let ev = s.queue[i]
    inc i
    case ev.kind
    of evWal:
      var data = ev.data
      while i < s.queue.len and s.queue[i].kind == evWal:
        data.add s.queue[i].data
        inc i
      if data.len > 0:
        result.add walFrame(data)
    of evSeal:
      result.add sealFrame(ev.idx)
    of evRoot:
      result.add rootFrame(ev.name)
  s.queue.setLen(0)

# ── Snapshot construction ───────────────────────────────────────────────────

proc collectSnapshot*(dir: string; rootName: string): seq[string] =
  ## List sealed journal segment paths (numerically sorted).
  let jdir = dir / "journal"
  var segs: seq[tuple[idx: int, path: string]] = @[]
  if dirExists(jdir):
    for kind, name in walkDir(jdir):
      let base = lastPathPart(name)
      if kind == pcFile and base.startsWith("journal."):
        try:
          segs.add((parseInt(base[8..^1]), name))
        except ValueError:
          # Non-numeric entry in journal dir — filter, not an error.
          logDebug("replication", "skipping non-segment file " & base)
  segs.sort(proc(a, b: tuple[idx: int, path: string]): int = cmp(a.idx, b.idx))
  for s in segs: result.add(s.path)

proc sendSnapshot*(s: Subscriber; sealed: seq[string]; openSeg: seq[byte];
                   rootName: string; blobDir: string) {.async.} =
  ## Send the full initial snapshot. Sealed segments are listed by path
  ## (immutable files on the shared filesystem — the replica reads them
  ## directly). The open-tail bytes (current in-memory WAL buffer, volatile)
  ## go in the frame. The replica reconstructs: PageStore trees from
  ## rootName + replays sealed segments into its pending treap + replays
  ## openTail into its live treap.
  var ms = MsgStream.init(256 + openSeg.len)
  ms.pack_map(5)
  ms.pack("ev"); ms.pack("snapshot")
  ms.pack("sealed")
  ms.pack_array(sealed.len)
  for p in sealed: ms.pack(p)
  ms.pack("openTail")
  # Encode as msgpack bin (raw bytes) instead of JSON int array
  ms.pack_bin(openSeg.len)
  if openSeg.len > 0:
    var tmp = newString(openSeg.len)
    copyMem(addr tmp[0], unsafeAddr openSeg[0], openSeg.len)
    appendRaw(ms, tmp)
  ms.pack("root"); ms.pack(rootName)
  ms.pack("blobDir"); ms.pack(blobDir)
  await s.sendEvent(ms.data)

# ── Replication hub ──────────────────────────────────────────────────────────

type
  ReplicationHub* = ref object
    subscribers*: seq[Subscriber]
    blobDir: string

proc initReplicationHub*(blobDir: string): ReplicationHub =
  result = ReplicationHub(blobDir: blobDir)

proc register*(hub: ReplicationHub; s: Subscriber) =
  hub.subscribers.add(s)

proc remove*(hub: ReplicationHub; s: Subscriber) =
  let idx = hub.subscribers.find(s)
  if idx >= 0: hub.subscribers.delete(idx)

proc broadcastWal*(hub: ptr ReplicationHub; data: seq[byte]) =
  ## Called under kv.lock on the loop thread (journal sink).  Only memcpy.
  if hub == nil or hub.subscribers.len == 0: return
  for s in hub.subscribers.items:
    if not s.closed: s.buf.add(data)

proc broadcastSeal*(hub: ptr ReplicationHub; segIdx: int) =
  if hub == nil or hub.subscribers.len == 0: return
  for s in hub.subscribers.items:
    if not s.closed:
      s.flushBuf()
      s.queue.add Ev(kind: evSeal, idx: segIdx)

proc broadcastRoot*(hub: ptr ReplicationHub; rootName: string) =
  if hub == nil or hub.subscribers.len == 0: return
  for s in hub.subscribers.items:
    if not s.closed:
      s.flushBuf()
      s.queue.add Ev(kind: evRoot, name: rootName)

# ── Subscriber drain loop ───────────────────────────────────────────────────

proc drain*(s: Subscriber; kv: KVStore) {.async.} =
  ## Emite UM frame POR evento na ordem de enfileiramento — wal agrega
  ## apenas bytes entre marcadores, nunca atravessando seal/root.
  if s.closed: return
  for body in collectOutgoing(s):
    await s.sendEvent(body)

proc subscriberLoop*(kv: KVStore; s: Subscriber; hub: ptr ReplicationHub) {.async.} =
  try:
    while not s.closed:
      await s.drain(kv)
      if s.closed: break
      await sleepAsync(2.milliseconds)
  except CatchableError as e:
    # Expected: replica socket closed mid-drain.
    logDebug("replication", "subscriber loop ended (" & excMsg(e) & ")")
  finally:
    s.closed = true
    hub[].remove(s)
