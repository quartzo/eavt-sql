## nim-blobstore/s3/tests.nim
##
## Unit tests for the S3 blobstore backend using a local rustfs server.
##
## Prerequisites: `rustfs` binary on PATH.
##
## Build & run:
##   cd nim-blobstore/s3 && nimble test

import std/[unittest, os, osproc, httpclient, times, tables, strutils, options]
import backend   # S3BlobStore, newS3BlobStore
import ../common # ByteArr16

var gServer: Process
var gPort: int

# ── rustfs lifecycle ────────────────────────────────────────────────────────

proc startServer() =
  let dir = "/tmp/s3test_" & $getTime().toUnix() & "_" & $getTime().nanosecond
  createDir(dir)
  gPort = 19000 + (abs(getTime().nanosecond) mod 1000)
  let rustfs = findExe("rustfs")
  if rustfs.len == 0:
    raise newException(IOError, "rustfs not found on PATH")
  gServer = startProcess(rustfs,
    args = [dir, "--address", ":" & $gPort,
            "--access-key", "test", "--secret-key", "test"],
    options = {poParentStreams})
  # Wait for server to be ready
  var ready = false
  for attempt in 1..60:
    sleep(250)
    try:
      let c = newHttpClient(timeout = 2000)
      let r = c.request("http://127.0.0.1:" & $gPort & "/health/ready", HttpGet, "")
      c.close()
      if r.code == Http200:
        ready = true
        break
    except OSError, IOError:
      discard
  if not ready:
    gServer.terminate()
    raise newException(IOError, "rustfs did not start")

proc stopServer() =
  if gServer != nil:
    try: gServer.terminate()
    except: discard
    try: gServer.close()
    except: discard

# ── helpers ──────────────────────────────────────────────────────────────────

proc cfg(): Table[string, string] =
  result = {
    "endpoint": "http://127.0.0.1:" & $gPort,
    "bucket_name": "test-bucket",
    "region": "us-east-1",
    "access_key": "test",
    "secret_key": "test",
    "path_style": "true",
  }.toTable

proc `==`(a, b: openArray[byte]): bool =
  if a.len != b.len: return false
  for i in 0..<a.len:
    if a[i] != b[i]: return false
  true

# ══════════════════════════════════════════════════════════════════════════════
# put + get
# ══════════════════════════════════════════════════════════════════════════════

suite "s3: put + get":
  setup:
    startServer()
    var tmpS = newS3BlobStore(cfg(), autoCreateBucket = false)

  teardown:
    stopServer()

  test "single blob round-trip":
    let s = newS3BlobStore(cfg())
    let data = @[byte(10), 20, 30]
    let id = s.put(data)
    let r = s.get(id)
    check r.isSome()
    check r.get() == data

  test "get missing id → none":
    let s = newS3BlobStore(cfg())
    var id: ByteArr16
    for i in 0..15: id[i] = 0xFF
    check s.get(id).isNone()

  test "empty blob (0 bytes)":
    let s = newS3BlobStore(cfg())
    let id = s.put(newSeq[byte]())
    let r = s.get(id)
    check r.isSome()
    check r.get().len == 0

  test "binary data with null bytes":
    let s = newS3BlobStore(cfg())
    let data = @[byte(0), 0, 1, 0, 2]
    let id = s.put(data)
    check s.get(id).get() == data

# ══════════════════════════════════════════════════════════════════════════════
# overwrite
# ══════════════════════════════════════════════════════════════════════════════

suite "s3: overwrite":
  setup:
    startServer()
    var tmpS = newS3BlobStore(cfg(), autoCreateBucket = false)

  teardown:
    stopServer()

  test "putAt replaces data at same id":
    let s = newS3BlobStore(cfg())
    var id: ByteArr16
    for i in 0..15: id[i] = byte(i)
    s.putAt(id, @[byte(1), 1, 1])
    s.putAt(id, @[byte(2), 2])
    check s.get(id).get() == @[byte(2), 2]

# ══════════════════════════════════════════════════════════════════════════════
# delete
# ══════════════════════════════════════════════════════════════════════════════

suite "s3: delete":
  setup:
    startServer()
    var tmpS = newS3BlobStore(cfg(), autoCreateBucket = false)

  teardown:
    stopServer()

  test "put → delete → gone":
    let s = newS3BlobStore(cfg())
    let id = s.put(@[byte(9)])
    check s.get(id).isSome()
    s.delete(id)
    check s.get(id).isNone()

# ══════════════════════════════════════════════════════════════════════════════
# list
# ══════════════════════════════════════════════════════════════════════════════

suite "s3: list":
  setup:
    startServer()
    var tmpS = newS3BlobStore(cfg(), autoCreateBucket = false)

  teardown:
    stopServer()

  test "empty store → 0":
    let s = newS3BlobStore(cfg())
    check s.list().len == 0

# ══════════════════════════════════════════════════════════════════════════════
# roots
# ══════════════════════════════════════════════════════════════════════════════

suite "s3: roots":
  setup:
    startServer()
    var tmpS = newS3BlobStore(cfg(), autoCreateBucket = false)

  teardown:
    stopServer()

  test "putRoot + getRoot round-trip":
    let s = newS3BlobStore(cfg())
    s.putRoot("root_one", @[byte(7), 8, 9])
    let r = s.getRoot("root_one")
    check r.isSome()
    check r.get() == @[byte(7), 8, 9]

  test "getRoot missing → none":
    let s = newS3BlobStore(cfg())
    check s.getRoot("never_there").isNone()

  test "deleteRoot removes root":
    let s = newS3BlobStore(cfg())
    s.putRoot("temp", @[byte(1)])
    check s.getRoot("temp").isSome()
    s.deleteRoot("temp")
    check s.getRoot("temp").isNone()
