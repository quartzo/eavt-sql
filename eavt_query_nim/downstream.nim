## downstream.nim — Multiplexed query-server↔transactor connection (chronos).
##
## One shared connection carries ALL traffic between the query server and the
## transactor: forwarded requests from every client AND the replication
## event stream (wal/seal/root/snapshot).  Demultiplexing is by frame
## shape:
##
##   • frames with an "ev" key  → replication event (server-push)
##   • frames with an "id" key  → response to a forwarded request
##
## The two key sets are disjoint by construction — the transactor never
## puts both "ev" and "id" in the same frame.  No correlation IDs are
## needed for replication events (there is exactly one stream per
## connection); request correlation is by the monotonic id assigned here.
##
## Writes from concurrent sources (response relay + replication drain)
## are safe on a chronos StreamTransport: each write() enqueues a complete
## vector — frames are never interleaved at the byte level.
##
## Reconnection: if the transport drops, all pending requests fail
## immediately and a reconnect loop (1 s backoff) re-opens the socket
## and re-subscribes.

import std/[json, os, tables]
import chronos
import msgpack4nim/msgpack2json

type
  PendingReq = ref object
    transp: StreamTransport   # client transport to relay responses to
    fut: Future[void]         # completed when more=false

  OnEvent* = proc(frame: JsonNode) {.gcsafe, raises: [].}

  MultiplexedConn* = ref object
    path*: string
    transp: StreamTransport
    pending: Table[string, PendingReq]
    nextId: uint64
    connected*: bool
    onEvent*: OnEvent         # called for every replication "ev" frame

# ── Framing helpers ─────────────────────────────────────────────────────────

proc sendFrame(conn: MultiplexedConn; body: string) {.async.} =
  var buf = newSeq[byte](4 + body.len)
  buf[0] = byte(body.len shr 24); buf[1] = byte(body.len shr 16)
  buf[2] = byte(body.len shr 8); buf[3] = byte(body.len)
  if body.len > 0:
    copyMem(addr buf[4], addr body[0], body.len)
  discard await conn.transp.write(buf)

proc sendJson(conn: MultiplexedConn; node: JsonNode) {.async.} =
  await conn.sendFrame(msgpack2json.fromJsonNode(node))

proc readFrame(conn: MultiplexedConn): Future[string] {.async.} =
  ## Read one length-prefixed msgpack frame.  Empty string = closed.
  try:
    var hdr: array[4, byte]
    await conn.transp.readExactly(addr hdr[0], 4)
    let len = int(hdr[0]) shl 24 or int(hdr[1]) shl 16 or
              int(hdr[2]) shl 8 or int(hdr[3])
    if len <= 0 or len > 100_000_000:
      return ""
    result = newString(len)
    if len > 0:
      await conn.transp.readExactly(addr result[0], len)
  except CatchableError:
    return ""

proc writeFrameAsync*(transp: StreamTransport; body: string) {.async.} =
  ## Utility: write one framed msgpack body to any transport (used by the
  ## gateway's client-facing connection to relay response frames).
  var buf = newSeq[byte](4 + body.len)
  buf[0] = byte(body.len shr 24); buf[1] = byte(body.len shr 16)
  buf[2] = byte(body.len shr 8); buf[3] = byte(body.len)
  if body.len > 0:
    copyMem(addr buf[4], addr body[0], body.len)
  discard await transp.write(buf)

proc writeErrorAsync*(transp: StreamTransport; msg: string) {.async.} =
  var node = newJObject()
  node["error"] = %msg
  node["more"] = %false
  await transp.writeFrameAsync(msgpack2json.fromJsonNode(node))

# ── Pending table helpers ───────────────────────────────────────────────────

proc failAllPending(conn: MultiplexedConn) =
  for id, p in conn.pending:
    if not p.fut.finished:
      p.fut.fail(newException(IOError, "transactor disconnected"))
  conn.pending.clear()

proc nextIdStr(conn: MultiplexedConn): string =
  inc conn.nextId
  result = $conn.nextId

# ── Reader task (demultiplexer) ─────────────────────────────────────────────

proc readerLoop(conn: MultiplexedConn) {.async.} =
  ## Reads frames forever.  Replication events ("ev") go to the onEvent
  ## callback; responses ("id") are relayed to the matching pending
  ## client transport and the pending future is completed on more=false.
  while true:
    let body = await conn.readFrame()
    if body.len == 0:
      return  # disconnect — connectLoop will reconnect
    var frame: JsonNode
    try:
      frame = toJsonNode(body)
    except CatchableError:
      continue  # malformed — skip
    if frame.hasKey("ev"):
      if conn.onEvent != nil:
        conn.onEvent(frame)
    elif frame.hasKey("id"):
      let id = frame["id"].getStr
      let p = conn.pending.getOrDefault(id)
      if p != nil:
        try:
          await p.transp.writeFrameAsync(body)
        except CatchableError:
          discard  # client gone — pending will be cleaned up
        if not frame.getOrDefault("more").getBool(false):
          p.fut.complete()
          conn.pending.del(id)

# ── Subscribe (send replicate request) ──────────────────────────────────────

proc sendReplicate(conn: MultiplexedConn) {.async.} =
  var node = newJObject()
  node["type"] = %"replicate"
  await conn.sendJson(node)

# ── Connect + reconnect loop ────────────────────────────────────────────────

proc connectLoop(conn: MultiplexedConn) {.async.} =
  ## Long-lived task: (re)connect to the transactor, subscribe to the
  ## replication stream, and run the reader loop until disconnect.
  ## All pending requests are failed on each disconnect; the query server's
  ## client handlers see "transactor disconnected" and surface it.
  while true:
    try:
      let address = initTAddress(conn.path)
      conn.transp = await address.connect()
      await conn.sendReplicate()
      conn.connected = true
      await conn.readerLoop()
    except CatchableError:
      discard
    conn.connected = false
    conn.failAllPending()
    if conn.transp != nil:
      try: await conn.transp.closeWait()
      except CatchableError: discard
    await sleepAsync(1000.milliseconds)

# ── Public API ──────────────────────────────────────────────────────────────

proc openMultiplexed*(path: string; onEvent: OnEvent): MultiplexedConn =
  ## Create and start the multiplexed connection.  The connect loop runs
  ## as a background task on the current chronos event loop.
  result = MultiplexedConn(path: path, onEvent: onEvent)
  asyncSpawn result.connectLoop()

proc request*(conn: MultiplexedConn; body: JsonNode;
              clientTransp: StreamTransport) {.async.} =
  ## Send a request to the transactor and relay all response frames to
  ## the client transport until more=false.  The request body gets an
  ## injected "id" field; the transactor echoes it in every response.
  if not conn.connected:
    await clientTransp.writeErrorAsync("transactor disconnected")
    return
  let id = conn.nextIdStr()
  body["id"] = %id
  let fut = newFuture[void]("mux-request")
  conn.pending[id] = PendingReq(transp: clientTransp, fut: fut)
  try:
    await conn.sendJson(body)
  except CatchableError:
    conn.pending.del(id)
    await clientTransp.writeErrorAsync("transactor write failed")
    return
  try:
    await fut
  except CatchableError:
    await clientTransp.writeErrorAsync("transactor disconnected")

proc forwardRaw*(conn: MultiplexedConn; raw: string;
                 clientTransp: StreamTransport) {.async.} =
  ## Forward a raw msgpack frame (scheme/admin/kv) from a client to the
  ## transactor.  Parses the frame to inject the correlation id, then
  ## relays responses back to the client.
  var body: JsonNode
  try:
    body = toJsonNode(raw)
  except CatchableError as e:
    await clientTransp.writeErrorAsync("parse error: " & e.msg)
    return
  await conn.request(body, clientTransp)

proc close*(conn: MultiplexedConn) {.async: (raises: []).} =
  try:
    if conn.transp != nil and not conn.transp.closed:
      await conn.transp.closeWait()
  except CatchableError:
    discard

proc downstreamSocketPath*(): string =
  ## Default transactor socket path.
  let xdg = getEnv("XDG_RUNTIME_DIR")
  if xdg.len > 0:
    return xdg / "eavt" / "eavt-transactor.sock"
  return getHomeDir() / ".local" / "state" / "eavt" / "eavt-transactor.sock"
