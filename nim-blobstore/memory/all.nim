## all.nim (memory backend)
##
## Single compilation entry point for libnim_blobstore_memory.a.
## Produces: nim_blob_memory_open / nim_blob_memory_close / nim_blob_memory_free_str

import abi
import spinlock
import backend
