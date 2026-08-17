## downstream.nim — async client to the data server (chronos).
##
## Same framing as eavt_server_nim/client (4-byte BE length + msgpack), but
## on a chronos StreamTransport so the gateway never blocks its event loop.
## One upstream client owns one downstream connection; streaming responses
## are relayed frame by frame.

import std/[json, os]
import chronos
import msgpack4nim/msgpack2json

type
  DownstreamConn* = ref object
    transp*: StreamTransport

proc connectDownstream*(path: string): Future[DownstreamConn] {.async.} =
  let address = initTAddress(path)
  let transp = await address.connect()
  return DownstreamConn(transp: transp)

proc close*(ds: DownstreamConn) {.async: (raises: []).} =
  try:
    if ds.transp != nil and not ds.transp.closed:
      await ds.transp.closeWait()
  except CatchableError:
    discard

proc sendFrame*(ds: DownstreamConn; body: string) {.async.} =
  var buf = newSeq[byte](4 + body.len)
  buf[0] = byte(body.len shr 24); buf[1] = byte(body.len shr 16)
  buf[2] = byte(body.len shr 8); buf[3] = byte(body.len)
  if body.len > 0:
    copyMem(addr buf[4], addr body[0], body.len)
  discard await ds.transp.write(buf)

proc sendJson*(ds: DownstreamConn; node: JsonNode) {.async.} =
  await ds.sendFrame(msgpack2json.fromJsonNode(node))

proc readFrame*(ds: DownstreamConn): Future[string] {.async.} =
  ## One msgpack frame body. Empty string = connection closed.
  try:
    var hdr: array[4, byte]
    await ds.transp.readExactly(addr hdr[0], 4)
    let len = int(hdr[0]) shl 24 or int(hdr[1]) shl 16 or
              int(hdr[2]) shl 8 or int(hdr[3])
    if len <= 0 or len > 100_000_000:
      return ""
    result = newString(len)
    if len > 0:
      await ds.transp.readExactly(addr result[0], len)
  except CatchableError:
    return ""
