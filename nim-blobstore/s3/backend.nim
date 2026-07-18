## blobstore_s3.nim
##
## S3-backed BlobStore backend using AWS Signature V4 + std/httpclient (sync).
## Port of spier-blobstore-s3/src/lib.rs. Exports `nim_blob_s3_open` /
## `nim_blob_s3_close`.
##
## Config keys: endpoint, bucket_name, region, access_key, secret_key,
## prefix (optional), path_style (optional, "true" → virtual-host style).
##
## The signing key (SigV4) is hand-rolled in aws_sigv4.nim (no AWS library
## dependency). The HTTP transport uses Nim's std/httpclient.

import std/httpclient
import std/strutils
import std/algorithm
import std/uri
import std/tables
import std/options

import abi
import sigv4
import spinlock

proc lastSegment(s: string; sep: char): string =
  let idx = s.rfind(sep)
  if idx < 0: s else: s.substr(idx + 1)

# ---------------------------------------------------------------------------
# Backend type
# ---------------------------------------------------------------------------

type
  S3Backend* = ref object
    lock: SpinLock
    initialized: bool
    endpoint: string         # e.g. "http://localhost:9000" or "https://s3.us-east-1.amazonaws.com"
    bucketName: string
    region: string
    accessKey: string
    secretKey: string
    prefix: string           # optional, prepended to all keys
    pathStyle: bool          # true = path-style (default), false = vhost

  ListEntry = tuple[key: string]

# ---------------------------------------------------------------------------
# Global registry
# ---------------------------------------------------------------------------

var regLock: SpinLock
var registry: Table[pointer, S3Backend]
initSpinLock(regLock)

proc registerBackend(b: S3Backend): pointer =
  let key = cast[pointer](b)
  regLock.acquire()
  try: registry[key] = b
  finally: regLock.release()
  result = key

proc unregisterBackend(key: pointer): S3Backend =
  regLock.acquire()
  try:
    result = registry.getOrDefault(key, nil)
    if result != nil: registry.del(key)
  finally: regLock.release()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc newUuidBytes16(): ByteArr16 =
  newUuidBytes(addr result[0])

proc hexCharVal(c: char): Option[byte] =
  case c
  of '0'..'9': some(byte(ord(c) - ord('0')))
  of 'a'..'f': some(byte(ord(c) - ord('a') + 10))
  of 'A'..'F': some(byte(ord(c) - ord('A') + 10))
  else: none(byte)

proc uuidToHexStr(id: ByteArr16): string =
  const hexChars = "0123456789abcdef"
  result = newString(32)
  for i, b in id:
    result[i*2] = hexChars[(b shr 4) and 0xF]
    result[i*2+1] = hexChars[b and 0xF]

proc uuidFromHexStr(s: string): Option[ByteArr16] =
  if s.len != 32: return none(ByteArr16)
  var bytes: ByteArr16
  for i in 0 ..< 16:
    let hi = hexCharVal(s[i*2])
    let lo = hexCharVal(s[i*2+1])
    if hi.isNone or lo.isNone: return none(ByteArr16)
    bytes[i] = (hi.get() shl 4) or lo.get()
  result = some(bytes)

proc ensureInit(b: S3Backend; cfg: Table[string, string]): Option[string] =
  ## Lazy init — validates required config. Returns some(error) on failure.
  if b.initialized: return none(string)
  if not cfg.hasKey("endpoint"): return some("missing endpoint")
  if not cfg.hasKey("bucket_name"): return some("missing bucket_name")
  b.endpoint = cfg["endpoint"]
  b.bucketName = cfg["bucket_name"]
  b.region = if cfg.hasKey("region"): cfg["region"] else: "us-east-1"
  if not cfg.hasKey("access_key"): return some("missing access_key")
  if not cfg.hasKey("secret_key"): return some("missing secret_key")
  b.accessKey = cfg["access_key"]
  b.secretKey = cfg["secret_key"]
  b.prefix = if cfg.hasKey("prefix"): cfg["prefix"] else: ""
  b.pathStyle = not (cfg.hasKey("path_style") and cfg["path_style"] == "true")
  b.initialized = true
  result = none(string)

proc prefixedKey(b: S3Backend, key: string): string =
  if b.prefix.len == 0: key else: b.prefix & "/" & key

proc blobKeyForId(b: S3Backend, id: ByteArr16): string =
  let hex = uuidToHexStr(id)
  b.prefixedKey("blobs/" & hex[0..1] & "/" & hex[2..3] & "/" & hex)

proc rootKeyForName(b: S3Backend, name: string): string =
  b.prefixedKey("roots/" & name)

# ---------------------------------------------------------------------------
# URL building + HTTP execution
# ---------------------------------------------------------------------------

proc buildHost(b: S3Backend): string =
  let u = parseUri(b.endpoint)
  result = u.hostname
  if u.port.len > 0:
    result.add(":" & u.port)

proc buildObjectUrl(b: S3Backend, objectKey: string, queryString: string = ""): string =
  ## Full HTTP URL for the object. Path-style: endpoint/bucket/key
  ## Vhost-style: endpoint host with bucket as subdomain.
  let u = parseUri(b.endpoint)
  var scheme = u.scheme
  if scheme.len == 0: scheme = "https"
  if b.pathStyle:
    var url = scheme & "://" & u.hostname
    if u.port.len > 0: url.add(":" & u.port)
    url.add("/" & b.bucketName & "/" & encodeUrl(objectKey, usePlus = false))
    if queryString.len > 0:
      url.add("?" & queryString)
    result = url
  else:
    var url = scheme & "://" & b.bucketName & "." & u.hostname
    if u.port.len > 0: url.add(":" & u.port)
    url.add("/" & encodeUrl(objectKey, usePlus = false))
    if queryString.len > 0:
      url.add("?" & queryString)
    result = url

proc doRequest(
    b: S3Backend,
    httpMethod, objectKey, queryString: string,
    payload: Bytes,
    expectBody: bool): tuple[code: int, body: Bytes, err: Option[string]] =
  ## Execute a signed S3 request. Returns (http_code, body, error).
  let url = b.buildObjectUrl(objectKey, queryString)
  let host = b.buildHost()

  # Build canonical path: bucket + "/" + objectKey. SigV4 needs the
  # *un-encoded* path (encoding happens during canonicalization).
  let canonicalPath = "/" & b.bucketName & "/" & objectKey

  # Build the canonical request using aws_sigv4. Use the raw key (not URL-encoded).
  let signed = signAwsRequestV4(
    accessKey = b.accessKey,
    secretKey = b.secretKey,
    region = b.region,
    service = "s3",
    endpoint = b.endpoint,
    bucketName = b.bucketName,
    httpMethod = httpMethod,
    objectKey = objectKey,
    queryString = queryString,
    extraHeaders = @[],
    payload = payload,
  )

  var client: HttpClient
  try:
    client = newHttpClient(timeout = 30000)  # 30s, matches Rust impl
  except OSError, IOError:
    return (0, @[], some("httpClient create: " & getCurrentExceptionMsg()))

  defer: client.close()
  client.headers = newHttpHeaders({
    "Authorization": signed.authorization,
    "x-amz-date": signed.xAmzDate,
    "x-amz-content-sha256": signed.xAmzContentSha256,
    "Content-Type": "application/octet-stream",
    "Host": host,
  })

  let httpVerb = parseEnum[HttpMethod](httpMethod.toUpperAscii())
  let bodyStr = if payload.len == 0: "" else: cast[string](payload)
  var resp: Response
  try:
    resp = client.request(url, httpVerb, bodyStr)
  except OSError, IOError, HttpRequestError, OverflowError, ValueError:
    return (0, @[], some("http request: " & getCurrentExceptionMsg()))

  let codeInt = int(resp.code)
  let bodyBytes: Bytes = if resp.body.len == 0: @[] else: cast[Bytes](resp.body)
  result = (codeInt, bodyBytes, none(string))

proc s3Put(b: S3Backend, key: string, data: Bytes): Option[string] =
  let (code, _, err) = doRequest(b, "PUT", key, "", data, expectBody = false)
  if err.isSome: return err
  if code >= 300:
    return some("s3 put failed: HTTP " & $code)
  result = none(string)

proc s3Get(b: S3Backend, key: string): tuple[ok: bool, data: Bytes, err: Option[string]] =
  let (code, body, err) = doRequest(b, "GET", key, "", @[], expectBody = true)
  if err.isSome:
    return (false, @[], err)
  if code == 404:
    return (true, @[], none(string))  # None
  if code >= 300:
    return (false, @[], some("s3 get failed: HTTP " & $code))
  return (true, body, none(string))

proc s3Delete(b: S3Backend, key: string): Option[string] =
  let (code, _, err) = doRequest(b, "DELETE", key, "", @[], expectBody = false)
  if err.isSome: return err
  if code == 404: return none(string)  # Idempotent delete
  if code >= 300:
    return some("s3 delete failed: HTTP " & $code)
  result = none(string)

# ---------------------------------------------------------------------------
# ListObjectsV2 parsing + pagination
# ---------------------------------------------------------------------------

proc extractTags(xml, tagName: string): seq[string] =
  ## Naive XML tag extraction. Returns text content of each `<tagName>...</tagName>`.
  let openTag = "<" & tagName & ">"
  let closeTag = "</" & tagName & ">"
  var pos = 0
  while true:
    let s = xml.find(openTag, start = pos)
    if s < 0: break
    let after = s + openTag.len
    let e = xml.find(closeTag, start = after)
    if e < 0: break
    result.add(xml[after ..< e])
    pos = e + closeTag.len

proc s3ListAll(b: S3Backend, prefix: string): tuple[ok: bool, items: seq[string], err: Option[string]] =
  ## Paginate ListObjectsV2; return all object keys under `prefix`.
  var allItems: seq[string] = @[]
  var continuationToken = ""
  var first = true
  while first or continuationToken.len > 0:
    first = false
    var qs = "list-type=2&prefix=" & encodeUrl(prefix, usePlus = false)
    if continuationToken.len > 0:
      qs.add("&continuation-token=" & encodeUrl(continuationToken, usePlus = false))
    # The continuation-token query value must be passed to signing too.
    let (code, body, err) = doRequest(b, "GET", "", qs, @[], expectBody = true)
    if err.isSome:
      return (false, @[], err)
    if code >= 300:
      return (false, @[], some("s3 list failed: HTTP " & $code))
    let xml = if body.len == 0: "" else: cast[string](body)
    for key in extractTags(xml, "Key"):
      allItems.add(key)
    let nextTokens = extractTags(xml, "NextContinuationToken")
    let isTruncatedTags = extractTags(xml, "IsTruncated")
    let isTruncated = isTruncatedTags.len > 0 and isTruncatedTags[0] == "true"
    continuationToken = if isTruncated and nextTokens.len > 0: nextTokens[0] else: ""
  result = (true, allItems, none(string))

# ---------------------------------------------------------------------------
# Trait-method implementations
# ---------------------------------------------------------------------------

proc s3PutImpl(h: pointer, data: ptr Byte, len: csize_t,
               idOut: ptr Byte, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[S3Backend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  b.lock.acquire()
  try:
    var payload: Bytes = newSeq[byte](len.int)
    if len.int > 0:
      copyMem(addr payload[0], data, len.int)
    let id = newUuidBytes16()
    let key = b.blobKeyForId(id)
    let e = s3Put(b, key, payload)
    if e.isSome:
      setErr(errOut, ErrIo); return 1'i32
    copyMem(idOut, unsafeAddr id[0], 16)
  finally:
    b.lock.release()
  result = 0'i32

proc s3PutAtImpl(h: pointer, id: ptr Byte, data: ptr Byte, len: csize_t,
                 errOut: ptr cint): cint {.cdecl.} =
  let b = cast[S3Backend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  b.lock.acquire()
  try:
    var idArr: ByteArr16
    copyMem(addr idArr[0], id, 16)
    var payload: Bytes = newSeq[byte](len.int)
    if len.int > 0:
      copyMem(addr payload[0], data, len.int)
    let key = b.blobKeyForId(idArr)
    let e = s3Put(b, key, payload)
    if e.isSome:
      setErr(errOut, ErrIo); return 1'i32
  finally:
    b.lock.release()
  result = 0'i32

proc s3DeleteImpl(h: pointer, id: ptr Byte, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[S3Backend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  b.lock.acquire()
  try:
    var idArr: ByteArr16
    copyMem(addr idArr[0], id, 16)
    let key = b.blobKeyForId(idArr)
    let e = s3Delete(b, key)
    if e.isSome:
      setErr(errOut, ErrIo); return 1'i32
  finally:
    b.lock.release()
  result = 0'i32

proc s3GetImpl(h: pointer, id: ptr Byte,
               outBuf: ptr pointer, outLen: ptr csize_t,
               outPresent: ptr cint, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[S3Backend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  b.lock.acquire()
  try:
    var idArr: ByteArr16
    copyMem(addr idArr[0], id, 16)
    let key = b.blobKeyForId(idArr)
    let (ok, data, err) = s3Get(b, key)
    if not ok:
      setErr(errOut, ErrIo); return 1'i32
    if data.len == 0:
      # 404 / missing
      outPresent[] = 0'i32
      outBuf[] = nil
      outLen[] = 0
    else:
      outPresent[] = 1'i32
      let buf = allocByteBuf(data.len)
      copyMem(buf, addr data[0], data.len)
      outBuf[] = cast[pointer](buf)
      outLen[] = data.len.csize_t
  finally:
    b.lock.release()
  result = 0'i32

proc s3ListImpl(h: pointer, outBuf: ptr pointer, outLen: ptr csize_t,
                errOut: ptr cint): cint {.cdecl.} =
  let b = cast[S3Backend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  b.lock.acquire()
  try:
    let prefix = b.prefixedKey("blobs/")
    let (ok, keys, err) = s3ListAll(b, prefix)
    if not ok:
      setErr(errOut, ErrIo); return 1'i32
    var ids: seq[ByteArr16] = @[]
    for key in keys:
      let basename = lastSegment(key, '/')
      let idOpt = uuidFromHexStr(basename)
      if idOpt.isSome:
        ids.add(idOpt.get())
    let total = ids.len * 16
    let buf = allocByteBuf(total)
    let dst = cast[BytePtr](buf)
    for i, id in ids:
      copyMem(addr dst[i * 16], unsafeAddr id[0], 16)
    outBuf[] = cast[pointer](buf)
    outLen[] = total.csize_t
  finally:
    b.lock.release()
  result = 0'i32

proc s3PutRootImpl(h: pointer, name: cstring, data: ptr Byte, len: csize_t,
                   errOut: ptr cint): cint {.cdecl.} =
  let b = cast[S3Backend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  b.lock.acquire()
  try:
    var payload: Bytes = newSeq[byte](len.int)
    if len.int > 0:
      copyMem(addr payload[0], data, len.int)
    let key = b.rootKeyForName($name)
    let e = s3Put(b, key, payload)
    if e.isSome:
      setErr(errOut, ErrIo); return 1'i32
  finally:
    b.lock.release()
  result = 0'i32

proc s3GetRootImpl(h: pointer, name: cstring,
                   outBuf: ptr pointer, outLen: ptr csize_t,
                   outPresent: ptr cint, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[S3Backend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  b.lock.acquire()
  try:
    let key = b.rootKeyForName($name)
    let (ok, data, err) = s3Get(b, key)
    if not ok:
      setErr(errOut, ErrIo); return 1'i32
    if data.len == 0:
      outPresent[] = 0'i32
      outBuf[] = nil
      outLen[] = 0
    else:
      outPresent[] = 1'i32
      let buf = allocByteBuf(data.len)
      copyMem(buf, addr data[0], data.len)
      outBuf[] = cast[pointer](buf)
      outLen[] = data.len.csize_t
  finally:
    b.lock.release()
  result = 0'i32

proc s3ListRootsImpl(h: pointer, outBuf: ptr pointer, outCount: ptr csize_t,
                     errOut: ptr cint): cint {.cdecl.} =
  let b = cast[S3Backend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  b.lock.acquire()
  try:
    let prefix = b.prefixedKey("roots/")
    let (ok, keys, err) = s3ListAll(b, prefix)
    if not ok:
      setErr(errOut, ErrIo); return 1'i32
    var names: seq[string] = @[]
    for k in keys:
      let basename = lastSegment(k, '/')
      if basename.startsWith("root_"):
        names.add(basename)
    names.sort(cmp[string])
    let count = names.len
    let arr = cast[CStringArr](allocShared0(sizeof(cstring) * max(count, 1)))
    for i, n in names:
      let cs = allocShared0(n.len + 1)
      if n.len > 0:
        copyMem(cs, unsafeAddr n[0], n.len)
      arr[i] = cast[cstring](cs)
    outBuf[] = cast[pointer](arr)
    outCount[] = count.csize_t
  finally:
    b.lock.release()
  result = 0'i32

proc s3DeleteRootImpl(h: pointer, name: cstring, errOut: ptr cint): cint {.cdecl.} =
  let b = cast[S3Backend](h)
  if b == nil: setErr(errOut, ErrInvalidHandle); return 1'i32
  b.lock.acquire()
  try:
    let key = b.rootKeyForName($name)
    let e = s3Delete(b, key)
    if e.isSome:
      setErr(errOut, ErrIo); return 1'i32
  finally:
    b.lock.release()
  result = 0'i32

# ---------------------------------------------------------------------------
# free helpers
# ---------------------------------------------------------------------------

proc s3FreeBuf(p: pointer) {.cdecl.} = freeShared(p)

proc s3FreeStrs(arr: CStringArr, count: csize_t) {.cdecl.} =
  if arr == nil: return
  for i in 0 ..< count.int:
    if arr[i] != nil:
      deallocShared(cast[pointer](arr[i]))
  deallocShared(cast[pointer](arr))

# ---------------------------------------------------------------------------
# Exported open / close
# ---------------------------------------------------------------------------

proc nim_blob_s3_open*(keys, vals: CStringArr, n: csize_t,
                      errOut: ptr cint): NimBlobVtablePtr
                      {.exportc, cdecl.} =
  let cfg = parseConfig(keys, vals, n)
  let b = S3Backend()
  initSpinLock(b.lock)
  let initErr = ensureInit(b, cfg)
  if initErr.isSome:
    setErr(errOut, ErrConfig)
    # b ref goes out of scope; arc frees it. No vtable allocated yet.
    return nil
  let key = registerBackend(b)
  let vt = newVtable()
  vt.handle = key
  vt.put = s3PutImpl
  vt.putAt = s3PutAtImpl
  vt.delete = s3DeleteImpl
  vt.get = s3GetImpl
  vt.list = s3ListImpl
  vt.putRoot = s3PutRootImpl
  vt.getRoot = s3GetRootImpl
  vt.listRoots = s3ListRootsImpl
  vt.deleteRoot = s3DeleteRootImpl
  vt.freeBuf = s3FreeBuf
  vt.freeStrs = s3FreeStrs
  result = vt

proc nim_blob_s3_close*(vt: NimBlobVtablePtr) {.exportc, cdecl.} =
  if vt == nil: return
  let h = vt.handle
  let b = unregisterBackend(h)
  if b != nil:
    discard  # arc frees on release
  freeVtable(vt)
