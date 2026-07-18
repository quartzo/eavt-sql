## aws_sigv4.nim
##
## Hand-rolled AWS Signature V4 implementation (RFC: AWS SigV4 signing protocol).
## Zero external deps beyond Nim stdlib (std/sha256, std/hmac not needed — we
## hand-roll HMAC-SHA256 on top of std/sha256).
##
## Reference: https://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html

import std/strutils
import std/times
import std/uri
import std/algorithm

import sha256

# ---------------------------------------------------------------------------
# SHA-256 + HMAC-SHA256
# ---------------------------------------------------------------------------

type Bytes* = seq[byte]
type Digest32* = Sha256Digest  # array[32, byte]

proc sha256Bytes*(data: Bytes | string): Digest32 =
  when data is string:
    result = sha256String(data)
  else:
    result = sha256(data)

proc sha256HexLower*(data: Bytes | string): string =
  result = sha256Bytes(data).toHexLower()

proc hmacSha256*(key: Bytes | string, msg: Bytes | string): Digest32 =
  ## Type-dispatch wrapper around sha256.nim's `rawHmacSha256`. Named the
  ## same as the underlying proc for API symmetry; the explicit `rawHmacSha256`
  ## call below avoids infinite recursion.
  when key is string:
    when msg is string:
      result = hmacSha256Strings(key, msg)
    else:
      let kSeq: Bytes = if key.len == 0: @[] else: cast[Bytes](key)
      result = rawHmacSha256(kSeq, msg)
  else:
    when msg is string:
      let mSeq: Bytes = if msg.len == 0: @[] else: cast[Bytes](msg)
      result = rawHmacSha256(key, mSeq)
    else:
      result = rawHmacSha256(key, msg)

proc hexLower*(d: Digest32): string =
  result = d.toHexLower()

proc bytesFromString*(s: string): Bytes =
  result = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc stringFromBytes*(b: Bytes): string =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], unsafeAddr b[0], b.len)

# ---------------------------------------------------------------------------
# URI / query encoding
# ---------------------------------------------------------------------------

proc encodePathSegment*(s: string): string =
  ## RFC 3986 encode for path components. Slash `/` is NOT encoded (preserves
  ## path structure); other reserved chars are encoded.
  for c in s:
    case c
    of 'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~', '/':
      result.add(c)
    else:
      result.add('%')
      result.add(toHex(ord(c), 2))

proc encodeQueryKey*(s: string): string =
  ## Encode for query parameter keys/values; slash IS encoded here.
  for c in s:
    case c
    of 'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~':
      result.add(c)
    else:
      result.add('%')
      result.add(toHex(ord(c), 2))

# ---------------------------------------------------------------------------
# SigV4 signing
# ---------------------------------------------------------------------------

type
  SignedRequest* = object
    authorization*: string
    xAmzDate*: string       # value for the `x-amz-date` header
    xAmzContentSha256*: string  # value for `x-amz-content-sha256` header

proc hmacSha256Seq(key: Digest32, msg: string): Digest32 =
  var keySeq = newSeq[byte](32)
  copyMem(addr keySeq[0], unsafeAddr key[0], 32)
  result = rawHmacSha256(keySeq, cast[seq[byte]](msg))

proc deriveSigningKey(secretKey, dateYyyymmdd, region, service: string): Digest32 =
  ## kSecret → kDate → kRegion → kService → kSigning
  let kSecret = "AWS4" & secretKey
  let kDate = hmacSha256(kSecret, dateYyyymmdd)
  let kRegion = hmacSha256Seq(kDate, region)
  let kService = hmacSha256Seq(kRegion, service)
  result = hmacSha256Seq(kService, "aws4_request")

# ---------------------------------------------------------------------------
# signAwsRequestV4
# ---------------------------------------------------------------------------

proc buildCanonicalRequest(
    httpMethod, canonicalUri, canonicalQueryString: string,
    sortedHeaders: seq[(string, string)],
    payloadHash: string): string =
  var parts: seq[string] = @[]
  parts.add(httpMethod.toUpperAscii())
  parts.add(canonicalUri)
  parts.add(canonicalQueryString)
  # CanonicalHeaders: each "key:value\n" lowercased + trimmed, sorted by key.
  var sortedHeadersCopy = sortedHeaders
  sortedHeadersCopy.sort(proc(a, b: (string, string)): int =
    cmpIgnoreCase(a[0], b[0]))
  var canonicalHeaders = ""
  var signedHeadersList: seq[string] = @[]
  for (k, v) in sortedHeadersCopy:
    let kk = k.toLowerAscii().strip()
    let vv = v.strip()
    canonicalHeaders.add(kk & ":" & vv & "\n")
    signedHeadersList.add(kk)
  parts.add(canonicalHeaders)
  parts.add(signedHeadersList.join(";"))
  parts.add(payloadHash)
  result = parts.join("\n")

proc signAwsRequestV4*(
    accessKey, secretKey, region, service: string,
    endpoint, bucketName: string,
    httpMethod, objectKey: string,
    queryString: string,
    extraHeaders: seq[(string, string)],
    payload: Bytes): SignedRequest =
  ## Sign an S3 request using SigV4. Returns headers to attach.
  let payloadHash = sha256HexLower(payload)
  let now = now().utc()
  let dateStamp = now.format("yyyyMMdd")
  let amzDate = now.format("yyyyMMdd'T'HHmmss'Z'")

  # Build host header (path-style: endpoint host + bucket; vhost-style: bucket.host)
  let endpointUri = parseUri(endpoint)
  let host = endpointUri.hostname  # may include port? strip if needed

  # Canonical URI: /bucket/key (path-style) — Rust impl uses path-style by default
  let canonicalUri = encodePathSegment("/" & bucketName & "/" & objectKey)

  # Canonical query string: keys + values sorted by key
  var qs: seq[(string, string)] = @[]
  if queryString.len > 0:
    for kv in queryString.split('&'):
      if kv.len == 0: continue
      let eq = kv.find('=')
      if eq < 0:
        qs.add((kv, ""))
      else:
        qs.add((kv[0 ..< eq], kv[eq+1 ..^ 1]))
  qs.sort(proc(a, b: (string, string)): int = cmp(a[0], b[0]))
  var canonicalQueryParts: seq[string] = @[]
  for (k, v) in qs:
    canonicalQueryParts.add(encodeQueryKey(k) & "=" & encodeQueryKey(v))
  let canonicalQueryString = canonicalQueryParts.join("&")

  # Required headers
  var headers: seq[(string, string)] = @[
    ("host", host),
    ("x-amz-content-sha256", payloadHash),
    ("x-amz-date", amzDate),
  ]
  for (k, v) in extraHeaders:
    headers.add((k, v))

  let canonicalRequest = buildCanonicalRequest(
    httpMethod, canonicalUri, canonicalQueryString, headers, payloadHash)

  let credentialScope = dateStamp & "/" & region & "/" & service & "/aws4_request"
  let stringToSign = "AWS4-HMAC-SHA256\n" &
    amzDate & "\n" &
    credentialScope & "\n" &
    sha256HexLower(canonicalRequest)

  let signingKey = deriveSigningKey(secretKey, dateStamp, region, service)
  let signature = hmacSha256Seq(signingKey, stringToSign)
  let signatureHex = hexLower(signature)

  var signedHeadersList: seq[string] = @[]
  var sortedHeadersCopy = headers
  sortedHeadersCopy.sort(proc(a, b: (string, string)): int =
    cmpIgnoreCase(a[0], b[0]))
  for (k, _) in sortedHeadersCopy:
    signedHeadersList.add(k.toLowerAscii().strip())
  let signedHeaders = signedHeadersList.join(";")

  let authorization = "AWS4-HMAC-SHA256 " &
    "Credential=" & accessKey & "/" & credentialScope & ", " &
    "SignedHeaders=" & signedHeaders & ", " &
    "Signature=" & signatureHex

  result.authorization = authorization
  result.xAmzDate = amzDate
  result.xAmzContentSha256 = payloadHash

# ---------------------------------------------------------------------------
# Self-test (only runs under `nim c -r`, not via cargo test)
# ---------------------------------------------------------------------------

when isMainModule:
  # Sanity: verify known SHA-256 test vector
  let h = sha256HexLower("")
  echo "empty sha256: ", h  # e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
  doAssert h == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  # HMAC of "Sample message" with key "wrong key" - verify it differs from "right key"
  let h1 = hexLower(hmacSha256("key1", "msg"))
  let h2 = hexLower(hmacSha256("key2", "msg"))
  doAssert h1 != h2
  echo "sigv4 sanity OK"
