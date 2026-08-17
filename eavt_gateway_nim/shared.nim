## shared.nim — Gateway shared state (schema snapshot cache).
##
## Single-threaded by construction: the gateway runs on one chronos event
## loop, so this is a plain object — no locks.

import std/[times, json, options, tables]
import chronos
import msgpack4nim/msgpack2json
import stats
import downstream

const SCHEMA_TTL_SECONDS = 30.0

type
  GatewayState* = ref object
    stats*: CompileStats
    fetchedAt*: float
    downstreamPath*: string

proc initGatewayState*(downstream: string): GatewayState =
  result = GatewayState(
    fetchedAt: -1.0,
    downstreamPath: downstream,
  )

proc fetchSnapshot*(ds: DownstreamConn): Future[CompileStats] {.async.} =
  var node = newJObject()
  node["type"] = %"schema"
  await ds.sendJson(node)
  let body = await ds.readFrame()
  if body.len == 0:
    raise newException(IOError, "data server closed connection during schema fetch")
  let resp = toJsonNode(body)
  if resp.hasKey("error") and resp["error"].getStr.len > 0:
    raise newException(IOError, "schema fetch failed: " & resp["error"].getStr)
  statsFromJson(resp["schema"])

proc getSnapshot*(gw: GatewayState; ds: DownstreamConn): Future[CompileStats] {.async.} =
  ## Cached snapshot with TTL. Staleness only degrades plan quality —
  ## programs are position-independent (intern-a), never correctness.
  if gw.fetchedAt > 0 and epochTime() - gw.fetchedAt < SCHEMA_TTL_SECONDS and
     gw.stats.attrIds.len > 0:
    return gw.stats
  result = await fetchSnapshot(ds)
  gw.stats = result
  gw.fetchedAt = epochTime()

proc refreshSnapshot*(gw: GatewayState; ds: DownstreamConn): Future[CompileStats] {.async.} =
  result = await fetchSnapshot(ds)
  gw.stats = result
  gw.fetchedAt = epochTime()
