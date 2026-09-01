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

import std/[os, tables]
import chronos
import std/streams
import msgpack4nim
import msgpack_scan
import logutil

type
  PendingReq = ref object
    transp: StreamTransport   # client transport to relay responses to
    fut: Future[void]         # completed when more=false
  PendingReqCollect = ref object
    buf: string               # collected raw response frames
    fut: Future[string]       # completed with the collected bytes when more=false

  OnEvent* = proc(frame: string) {.gcsafe, raises: [].}

  MultiplexedConn* = ref object
    path*: string
    transp: StreamTransport
    pending: Table[string, PendingReq]
    pendingCollect: Table[string, PendingReqCollect]
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

proc sendRaw(conn: MultiplexedConn; raw: string) {.async.} =
  await conn.sendFrame(raw)

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
  var ms = MsgStream.init(64)
  ms.pack_map(2)
  ms.pack("error"); ms.pack(msg)
  ms.pack("more"); ms.pack(false)
  await transp.writeFrameAsync(ms.data)

# ── Pending table helpers ───────────────────────────────────────────────────

proc failAllPending(conn: MultiplexedConn) =
  for id, p in conn.pending:
    if not p.fut.finished:
      p.fut.fail(newException(IOError, "transactor disconnected"))
  conn.pending.clear()
  for id, p in conn.pendingCollect:
    if not p.fut.finished:
      p.fut.complete(p.buf)  # surface ""/partial — caller inspects for error
  conn.pendingCollect.clear()

proc nextIdStr(conn: MultiplexedConn): string =
  inc conn.nextId
  result = $conn.nextId

# ── Reader task (demultiplexer) ─────────────────────────────────────────────

proc readerLoop(conn: MultiplexedConn) {.async.} =
  ## Reads frames forever.  Replication events ("ev") go to the onEvent
  ## callback; responses ("id") are relayed to the matching pending
  ## client transport and the pending future is completed on more=false.
  ## Frames are scanned by top-level key only — no full msgpack→JsonNode
  ## conversion.
  while true:
    let body = await conn.readFrame()
    if body.len == 0:
      return  # disconnect — connectLoop will reconnect
    if hasTopKey(body, "ev"):
      if conn.onEvent != nil:
        conn.onEvent(body)
    elif hasTopKey(body, "id"):
      let id = getTopStr(body, "id")
      let p = conn.pending.getOrDefault(id)
      if p != nil:
        try:
          await p.transp.writeFrameAsync(body)
        except CatchableError as e:
          # Expected: client disconnected while its response was in flight.
          logDebug("downstream", "relay to client failed (" & excMsg(e) & ")")
        if not getTopBool(body, "more"):
          p.fut.complete()
          conn.pending.del(id)
      else:
        let pc = conn.pendingCollect.getOrDefault(id)
        if pc != nil:
          # Store FRAMED bytes (4B length prefix + body) so the collector can
          # relay frames verbatim to its client.
          pc.buf.add chr(byte(body.len shr 24) and 0xFF)
          pc.buf.add chr(byte((body.len shr 16) and 0xFF))
          pc.buf.add chr(byte((body.len shr 8) and 0xFF))
          pc.buf.add chr(byte(body.len and 0xFF))
          pc.buf.add body
          if not getTopBool(body, "more"):
            pc.fut.complete(pc.buf)
            conn.pendingCollect.del(id)

# ── Subscribe (send replicate request) ──────────────────────────────────────

proc sendReplicate(conn: MultiplexedConn) {.async.} =
  var ms = MsgStream.init(32)
  ms.pack_map(1)
  ms.pack("type"); ms.pack("replicate")
  await conn.sendRaw(ms.data)

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
    except CatchableError as e:
      # Reconnect cycle: normal operation, visible only at debug.
      logDebug("downstream", "connection to transactor lost (" &
        excMsg(e) & "); retrying in 1s")
    conn.connected = false
    conn.failAllPending()
    if conn.transp != nil:
      try: await conn.transp.closeWait()
      except CatchableError as e:
        logDebug("downstream", "closeWait failed (" & excMsg(e) & ")")
    await sleepAsync(1000.milliseconds)

# ── Public API ──────────────────────────────────────────────────────────────

proc openMultiplexed*(path: string; onEvent: OnEvent): MultiplexedConn =
  ## Create and start the multiplexed connection.  The connect loop runs
  ## as a background task on the current chronos event loop.
  result = MultiplexedConn(path: path, onEvent: onEvent)
  asyncSpawn result.connectLoop()

proc requestCollect*(conn: MultiplexedConn; body: string): Future[string] {.async.} =
  ## Send a raw msgpack request to the transactor and COLLECT the response
  ## frames (concatenated raw bodies) instead of relaying them to a client.
  ## Used by the tx path: the tx-report must be inspected locally (tempids →
  ## UPSERT rows) before anything reaches the client.  Completes with ""
  ## when the transactor is down; error frames surface in the collected
  ## bytes (the caller inspects "error" keys).
  ## NB (chronos): single unconditional `await` at the end of one flat code
  ## path — chronos's async transform is brittle with early returns.
  result = ""
  if conn.connected and body.len > 0:
    let id = conn.nextIdStr()
    let framed = injectTopPair(body, "id", id)
    if framed.len > 0:
      let p = PendingReqCollect(fut: newFuture[string]("requestCollect"))
      conn.pendingCollect[id] = p
      var sendOk = true
      try:
        await conn.sendFrame(framed)
      except CatchableError as e:
        conn.pendingCollect.del(id)
        sendOk = false
        logDebug("downstream", "tx send failed (" & excMsg(e) & ")")
      if sendOk:
        result = await p.fut

proc request*(conn: MultiplexedConn; body: string;
              clientTransp: StreamTransport) {.async.} =
  ## Send a raw msgpack request to the transactor and relay all response
  ## frames to the client transport until more=false.  The request body
  ## gets an injected "id" field via injectTopPair.
  if not conn.connected:
    await clientTransp.writeErrorAsync("transactor disconnected")
    return
  let id = conn.nextIdStr()
  let framed = injectTopPair(body, "id", id)
  if framed.len == 0:
    await clientTransp.writeErrorAsync("parse error: request must be an object")
    return
  let fut = newFuture[void]("mux-request")
  conn.pending[id] = PendingReq(transp: clientTransp, fut: fut)
  try:
    await conn.sendFrame(framed)
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
  ## transactor.  The correlation id is injected by appending ("id", n)
  ## to the top-level map — no parse, no re-serialization; the payload
  ## bytes pass through untouched.
  if not conn.connected:
    await clientTransp.writeErrorAsync("transactor disconnected")
    return
  let id = conn.nextIdStr()
  let framed = injectTopPair(raw, "id", id)
  if framed.len == 0:
    await clientTransp.writeErrorAsync("parse error: request must be an object")
    return
  let fut = newFuture[void]("mux-forward-raw")
  conn.pending[id] = PendingReq(transp: clientTransp, fut: fut)
  try:
    await conn.sendFrame(framed)
  except CatchableError:
    conn.pending.del(id)
    await clientTransp.writeErrorAsync("transactor write failed")
    return
  try:
    await fut
  except CatchableError:
    await clientTransp.writeErrorAsync("transactor disconnected")

proc close*(conn: MultiplexedConn) {.async: (raises: []).} =
  try:
    if conn.transp != nil and not conn.transp.closed:
      await conn.transp.closeWait()
  except CatchableError as e:
    logDebug("downstream", "close failed (" & excMsg(e) & ")")

proc downstreamSocketPath*(): string =
  ## Default transactor socket path.
  let xdg = getEnv("XDG_RUNTIME_DIR")
  if xdg.len > 0:
    return xdg / "eavt" / "eavt-transactor.sock"
  return getHomeDir() / ".local" / "state" / "eavt" / "eavt-transactor.sock"
