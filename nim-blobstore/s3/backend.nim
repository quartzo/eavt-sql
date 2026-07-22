## blobstore_s3.nim
##
## S3-backed BlobStore using AWS Signature V4 + std/httpclient.
## Implements the `BlobStore` trait.

import std/[httpclient, strutils, algorithm, uri, tables, options]
import ../common
import ../blobstore
import sigv4
import spinlock

proc lastSegment(s: string; sep: char): string =
  let idx = s.rfind(sep)
  if idx < 0: s else: s.substr(idx + 1)

type
  S3BlobStore* = ref object of BlobStore
    lock: SpinLock
    initialized*: bool
    endpoint*: string
    bucketName*: string
    region*: string
    accessKey*: string
    secretKey*: string
    prefix*: string
    pathStyle*: bool

proc ensureInit(b: S3BlobStore; cfg: Table[string, string]): Option[string] =
  if b.initialized: return none(string)
  if not cfg.hasKey("endpoint"): return some("missing endpoint")
  if not cfg.hasKey("bucket_name"): return some("missing bucket_name")
  if not cfg.hasKey("access_key"): return some("missing access_key")
  if not cfg.hasKey("secret_key"): return some("missing secret_key")
  b.endpoint = cfg["endpoint"]
  b.bucketName = cfg["bucket_name"]
  b.region = if cfg.hasKey("region"): cfg["region"] else: "us-east-1"
  b.accessKey = cfg["access_key"]
  b.secretKey = cfg["secret_key"]
  b.prefix = if cfg.hasKey("prefix"): cfg["prefix"] else: ""
  b.pathStyle = not (cfg.hasKey("path_style") and cfg["path_style"] == "true")
  b.initialized = true
  result = none(string)

# ── key helpers ──────────────────────────────────────────────────────────────

proc uuidToHexStr(id: ByteArr16): string =
  const hexChars = "0123456789abcdef"
  result = newString(32)
  for i, b in id:
    result[i*2] = hexChars[(b shr 4) and 0xF]
    result[i*2+1] = hexChars[b and 0xF]

proc newUuidBytes16(): ByteArr16 =
  newUuidBytes(addr result[0])

proc prefixedKey(b: S3BlobStore; key: string): string =
  if b.prefix.len == 0: key else: b.prefix & "/" & key

proc blobKeyForId(b: S3BlobStore; id: ByteArr16): string =
  let hex = uuidToHexStr(id)
  b.prefixedKey("blobs/" & hex[0..1] & "/" & hex[2..3] & "/" & hex)

proc rootKeyForName(b: S3BlobStore; name: string): string =
  b.prefixedKey("roots/" & name)

# ── URL building + HTTP ─────────────────────────────────────────────────────

proc buildHost(b: S3BlobStore): string =
  let u = parseUri(b.endpoint)
  result = u.hostname
  if u.port.len > 0: result.add(":" & u.port)

proc buildObjectUrl(b: S3BlobStore; objectKey, queryString: string): string =
  let u = parseUri(b.endpoint)
  var scheme = u.scheme
  if scheme.len == 0: scheme = "https"
  if b.pathStyle:
    var url = scheme & "://" & u.hostname
    if u.port.len > 0: url.add(":" & u.port)
    if objectKey.len == 0:
      url.add("/" & b.bucketName)
    else:
      url.add("/" & b.bucketName & "/" & encodeUrl(objectKey, usePlus = false))
    if queryString.len > 0: url.add("?" & queryString)
    result = url
  else:
    var url = scheme & "://" & b.bucketName & "." & u.hostname
    if u.port.len > 0: url.add(":" & u.port)
    url.add("/" & encodeUrl(objectKey, usePlus = false))
    if queryString.len > 0: url.add("?" & queryString)
    result = url

proc doRequest(b: S3BlobStore; httpMethod, objectKey, queryString: string;
               payload: seq[byte]; expectBody: bool):
    tuple[code: int; body: seq[byte]; err: Option[string]] =
  let url = b.buildObjectUrl(objectKey, queryString)
  let host = b.buildHost()
  let signed = signAwsRequestV4(
    accessKey = b.accessKey, secretKey = b.secretKey,
    region = b.region, service = "s3", endpoint = b.endpoint,
    bucketName = b.bucketName, httpMethod = httpMethod,
    objectKey = objectKey, queryString = queryString,
    extraHeaders = @[], payload = payload,
  )
  var client: HttpClient
  try:
    client = newHttpClient(timeout = 30000)
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
  let bodyBytes: seq[byte] = if resp.body.len == 0: @[] else: cast[seq[byte]](resp.body)
  result = (codeInt, bodyBytes, none(string))

proc s3Put(b: S3BlobStore; key: string; data: seq[byte]): Option[string] =
  let (code, _, err) = doRequest(b, "PUT", key, "", data, expectBody = false)
  if err.isSome(): return err
  if code >= 300: return some("s3 put failed: HTTP " & $code)
  result = none(string)

proc s3Get(b: S3BlobStore; key: string): tuple[ok: bool; data: seq[byte]; err: Option[string]] =
  let (code, body, err) = doRequest(b, "GET", key, "", @[], expectBody = true)
  if err.isSome(): return (false, @[], err)
  if code == 404: return (true, @[], none(string))
  if code >= 300: return (false, @[], some("s3 get failed: HTTP " & $code))
  return (true, body, none(string))

proc s3Delete(b: S3BlobStore; key: string): Option[string] =
  let (code, _, err) = doRequest(b, "DELETE", key, "", @[], expectBody = false)
  if err.isSome(): return err
  if code == 404: return none(string)
  if code >= 300: return some("s3 delete failed: HTTP " & $code)
  result = none(string)

# ── ListObjectsV2 ────────────────────────────────────────────────────────────

proc extractTags(xml, tagName: string): seq[string] =
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

proc s3ListAll(b: S3BlobStore; prefix: string): tuple[ok: bool; items: seq[string]; err: Option[string]] =
  var allItems: seq[string] = @[]
  var continuationToken = ""
  var first = true
  while first or continuationToken.len > 0:
    first = false
    var qs = "list-type=2&prefix=" & encodeUrl(prefix, usePlus = false)
    if continuationToken.len > 0:
      qs.add("&continuation-token=" & encodeUrl(continuationToken, usePlus = false))
    let (code, body, err) = doRequest(b, "GET", "", qs, @[], expectBody = true)
    if err.isSome(): return (false, @[], err)
    if code >= 300: return (false, @[], some("s3 list failed: HTTP " & $code))
    let xml = if body.len == 0: "" else: cast[string](body)
    for key in extractTags(xml, "Key"): allItems.add(key)
    let nextTokens = extractTags(xml, "NextContinuationToken")
    let isTruncatedTags = extractTags(xml, "IsTruncated")
    let isTruncated = isTruncatedTags.len > 0 and isTruncatedTags[0] == "true"
    continuationToken = if isTruncated and nextTokens.len > 0: nextTokens[0] else: ""
  result = (true, allItems, none(string))

# ── hex decode helper ────────────────────────────────────────────────────────

proc uuidFromHexStr(s: string): Option[ByteArr16] =
  if s.len != 32: return none(ByteArr16)
  proc hexCharVal(c: char): Option[byte] =
    case c
    of '0'..'9': some(byte(ord(c) - ord('0')))
    of 'a'..'f': some(byte(ord(c) - ord('a') + 10))
    of 'A'..'F': some(byte(ord(c) - ord('A') + 10))
    else: none(byte)
  var bytes: ByteArr16
  for i in 0 ..< 16:
    let hi = hexCharVal(s[i*2])
    let lo = hexCharVal(s[i*2+1])
    if hi.isNone() or lo.isNone(): return none(ByteArr16)
    bytes[i] = (hi.get() shl 4) or lo.get()
  result = some(bytes)

# ══════════════════════════════════════════════════════════════════════════════
# BlobStore trait methods
# ══════════════════════════════════════════════════════════════════════════════

method createBucket*(s: S3BlobStore) =
  ## Create the configured bucket via S3 CreateBucket API.
  let signed = signAwsRequestV4(
    accessKey = s.accessKey, secretKey = s.secretKey,
    region = s.region, service = "s3", endpoint = s.endpoint,
    bucketName = s.bucketName, httpMethod = "PUT", objectKey = "",
    queryString = "", extraHeaders = @[], payload = @[],
  )
  let url = s.buildObjectUrl("", "")
  let host = s.buildHost()
  var client: HttpClient
  try:
    client = newHttpClient(timeout = 30000)
  except OSError, IOError:
    raise newException(IOError, "createBucket http: " & getCurrentExceptionMsg())
  defer: client.close()
  client.headers = newHttpHeaders({
    "Authorization": signed.authorization,
    "x-amz-date": signed.xAmzDate,
    "x-amz-content-sha256": signed.xAmzContentSha256,
    "Host": host,
  })
  let resp = client.request(url, HttpPut, "")
  if resp.code != Http200:
    raise newException(IOError, "createBucket failed: HTTP " & $resp.code)

method put*(s: S3BlobStore; data: openArray[byte]): ByteArr16 =
  var payload: seq[byte] = newSeq[byte](data.len)
  if data.len > 0: copyMem(addr payload[0], unsafeAddr data[0], data.len)
  result = newUuidBytes16()
  let key = s.blobKeyForId(result)
  s.lock.acquire()
  try:
    let e = s3Put(s, key, payload)
    if e.isSome(): raise newException(IOError, "s3 put: " & e.get())
  finally: s.lock.release()

method putAt*(s: S3BlobStore; id: ByteArr16; data: openArray[byte]) =
  var payload: seq[byte] = newSeq[byte](data.len)
  if data.len > 0: copyMem(addr payload[0], unsafeAddr data[0], data.len)
  let key = s.blobKeyForId(id)
  s.lock.acquire()
  try:
    let e = s3Put(s, key, payload)
    if e.isSome(): raise newException(IOError, "s3 putAt: " & e.get())
  finally: s.lock.release()

method get*(s: S3BlobStore; id: ByteArr16): Option[seq[byte]] =
  let key = s.blobKeyForId(id)
  s.lock.acquire()
  try:
    let (ok, data, err) = s3Get(s, key)
    if not ok: raise newException(IOError, "s3 get: " & err.get(""))
    if data.len == 0: return none(seq[byte])
    result = some(data)
  finally: s.lock.release()

method delete*(s: S3BlobStore; id: ByteArr16) =
  let key = s.blobKeyForId(id)
  s.lock.acquire()
  try:
    let e = s3Delete(s, key)
    if e.isSome(): raise newException(IOError, "s3 delete: " & e.get())
  finally: s.lock.release()

method list*(s: S3BlobStore): seq[ByteArr16] =
  let prefix = s.prefixedKey("blobs/")
  s.lock.acquire()
  try:
    let (ok, keys, err) = s3ListAll(s, prefix)
    if not ok: raise newException(IOError, "s3 list: " & err.get(""))
    for key in keys:
      let basename = lastSegment(key, '/')
      let idOpt = uuidFromHexStr(basename)
      if idOpt.isSome(): result.add(idOpt.get())
  finally: s.lock.release()

method putRoot*(s: S3BlobStore; name: string; data: openArray[byte]) =
  var payload: seq[byte] = newSeq[byte](data.len)
  if data.len > 0: copyMem(addr payload[0], unsafeAddr data[0], data.len)
  let key = s.rootKeyForName(name)
  s.lock.acquire()
  try:
    let e = s3Put(s, key, payload)
    if e.isSome(): raise newException(IOError, "s3 putRoot: " & e.get())
  finally: s.lock.release()

method getRoot*(s: S3BlobStore; name: string): Option[seq[byte]] =
  let key = s.rootKeyForName(name)
  s.lock.acquire()
  try:
    let (ok, data, err) = s3Get(s, key)
    if not ok: raise newException(IOError, "s3 getRoot: " & err.get(""))
    if data.len == 0: return none(seq[byte])
    result = some(data)
  finally: s.lock.release()

method listRoots*(s: S3BlobStore): seq[string] =
  let prefix = s.prefixedKey("roots/")
  s.lock.acquire()
  try:
    let (ok, keys, err) = s3ListAll(s, prefix)
    if not ok: raise newException(IOError, "s3 listRoots: " & err.get(""))
    var names: seq[string] = @[]
    for k in keys:
      let basename = lastSegment(k, '/')
      if basename.startsWith("root_"): names.add(basename)
    names.sort(cmp[string])
    result = names
  finally: s.lock.release()

method deleteRoot*(s: S3BlobStore; name: string) =
  let key = s.rootKeyForName(name)
  s.lock.acquire()
  try:
    let e = s3Delete(s, key)
    if e.isSome(): raise newException(IOError, "s3 deleteRoot: " & e.get())
  finally: s.lock.release()

# ══════════════════════════════════════════════════════════════════════════════
# Constructor (must come after all method definitions for forward ref)
# ══════════════════════════════════════════════════════════════════════════════

proc newS3BlobStore*(cfg: Table[string, string]; autoCreateBucket = false): S3BlobStore =
  result = S3BlobStore()
  initSpinLock(result.lock)
  let e = ensureInit(result, cfg)
  if e.isSome():
    raise newException(IOError, "s3 init: " & e.get())
  if autoCreateBucket:
    result.createBucket()