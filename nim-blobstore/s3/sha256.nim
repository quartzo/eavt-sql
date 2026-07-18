## sha256.nim (s3 backend)
##
## Thin OpenSSL libcrypto wrapper for SHA-256 + HMAC-SHA256.
## Linked with -lcrypto. Works with OpenSSL 1.1 and 3.x (uses non-deprecated
## EVP_Digest / HMAC entry points).

type
  Sha256Digest* = array[32, byte]

# OpenSSL's EVP_MD is an opaque struct. We treat it as `pointer` to avoid
# const-correctness friction at the C boundary.
proc EVP_sha256*(): pointer {.importc, header: "<openssl/evp.h>", cdecl.}

# int EVP_Digest(const void *data, size_t count, unsigned char *md,
#                unsigned int *size, const EVP_MD *type, ENGINE *e);
proc EVP_Digest*(data: pointer, count: csize_t, md: ptr byte, size: ptr cuint,
                 typ: pointer, eng: pointer): cint
    {.importc, header: "<openssl/evp.h>", cdecl.}

# unsigned char *HMAC(const EVP_MD *evp_md, const void *key, int key_len,
#                     const unsigned char *d, size_t n, unsigned char *md,
#                     unsigned int *md_len);
proc HMAC*(evpMd: pointer, key: pointer, keyLen: cint,
           data: ptr byte, dataLen: csize_t,
           md: ptr byte, mdLen: ptr cuint): ptr byte
    {.importc, header: "<openssl/hmac.h>", cdecl.}

# ---------------------------------------------------------------------------
# SHA-256
# ---------------------------------------------------------------------------

proc sha256*(data: openArray[byte]): Sha256Digest =
  var mdLen: cuint = 0
  discard EVP_Digest(
    if data.len > 0: unsafeAddr data[0] else: nil,
    data.len.csize_t,
    addr result[0], addr mdLen, EVP_sha256(), nil)

proc sha256String*(s: string): Sha256Digest =
  if s.len == 0:
    result = sha256(newSeq[byte](0))
  else:
    result = sha256(cast[seq[byte]](s))

# ---------------------------------------------------------------------------
# HMAC-SHA256
# ---------------------------------------------------------------------------

proc hmacSha256*(key, msg: openArray[byte]): Sha256Digest =
  var mdLen: cuint = 0
  discard HMAC(EVP_sha256(),
               if key.len > 0: unsafeAddr key[0] else: nil, key.len.cint,
               if msg.len > 0: unsafeAddr msg[0] else: nil, msg.len.csize_t,
               addr result[0], addr mdLen)

proc hmacSha256Strings*(key, msg: string): Sha256Digest =
  let k = if key.len == 0: newSeq[byte](0) else: cast[seq[byte]](key)
  let m = if msg.len == 0: newSeq[byte](0) else: cast[seq[byte]](msg)
  result = hmacSha256(k, m)

# ---------------------------------------------------------------------------
# Hex
# ---------------------------------------------------------------------------

const hexChars = "0123456789abcdef"

proc toHexLower*(d: Sha256Digest): string =
  result = newString(64)
  for i, b in d:
    result[i*2] = hexChars[(b shr 4) and 0xF]
    result[i*2 + 1] = hexChars[b and 0xF]

# ---------------------------------------------------------------------------
# Self-test (run with: nim c -r s3/sha256.nim)
# ---------------------------------------------------------------------------

when isMainModule:
  let h = sha256String("").toHexLower()
  echo "empty sha256: ", h
  doAssert h == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  # RFC 4231 Test Case 1
  var key0b = newSeq[byte](20)
  for i in 0 ..< key0b.len: key0b[i] = 0x0b
  let h1 = hmacSha256(key0b, cast[seq[byte]]("Hi There")).toHexLower()
  echo "RFC 4231 TC1: ", h1
  doAssert h1 == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
  echo "sha256 OK"
