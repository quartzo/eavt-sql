## shared.nim — Gateway shared state (schema snapshot cache).

import std/[locks, times, json, options, tables]
import msgpack4nim/msgpack2json
import stats
import eavt_server_nim/client

const SCHEMA_TTL_SECONDS = 30.0

type
  SharedGateway* = ref object
    lock*: Lock
    stats*: CompileStats
    fetchedAt*: float
    downstreamPath*: string

proc initSharedGateway*(downstream: string = downstreamSocketPath()): SharedGateway =
  result = SharedGateway(
    fetchedAt: -1.0,
    downstreamPath: downstream,
  )
  result.lock.initLock()

proc fetchSnapshot*(ds: var EavtClient): CompileStats =
  var node = newJObject()
  node["type"] = %"schema"
  ds.sendFrame(msgpack2json.fromJsonNode(node))
  let body = ds.recvFrame()
  if body.len == 0:
    raise newException(IOError, "data server closed connection during schema fetch")
  let resp = toJsonNode(body)
  if resp.hasKey("error") and resp["error"].getStr.len > 0:
    raise newException(IOError, "schema fetch failed: " & resp["error"].getStr)
  statsFromJson(resp["schema"])

proc getSnapshot*(gw: ptr SharedGateway; ds: var EavtClient): CompileStats =
  ## Cached snapshot with TTL. Staleness only degrades plan quality —
  ## programs are position-independent (intern-a), never correctness.
  block cached:
    gw.lock.withLock:
      if gw.fetchedAt > 0 and epochTime() - gw.fetchedAt < SCHEMA_TTL_SECONDS and
         gw.stats.attrIds.len > 0:
        return gw.stats
  result = fetchSnapshot(ds)
  gw.lock.withLock:
    gw.stats = result
    gw.fetchedAt = epochTime()

proc refreshSnapshot*(gw: ptr SharedGateway; ds: var EavtClient): CompileStats =
  result = fetchSnapshot(ds)
  gw.lock.withLock:
    gw.stats = result
    gw.fetchedAt = epochTime()
