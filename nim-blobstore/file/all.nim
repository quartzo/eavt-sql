## all.nim (file backend)
##
## Single compilation entry point for libnim_blobstore_file.a.
## Produces: nim_blob_file_open / nim_blob_file_close / nim_blob_file_free_str

import abi
import spinlock
import backend
