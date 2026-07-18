## all.nim (s3 backend)
##
## Single compilation entry point for libnim_blobstore_s3.a.
## Produces: nim_blob_s3_open / nim_blob_s3_close / nim_blob_s3_free_str
## Links: -lcrypto (OpenSSL SHA-256 + HMAC-SHA256 for SigV4).

import abi
import spinlock
import sha256
import sigv4
import backend
