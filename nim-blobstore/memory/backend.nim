## blobstore_memory.nim
##
## In-memory BlobStore backend.  Implements the `BlobStore` trait.

import std/[tables, algorithm, options]
import ../common
import ../blobstore
import spinlock

type
  MemBlobStore* = ref object of BlobStore
    lock: SpinLock
    blobs*: Table[ByteArr16, seq[Byte]]
    roots*: Table[string, seq[Byte]]

proc newMemBlobStore*(): MemBlobStore =
  result = MemBlobStore()
  result.blobs = initTable[ByteArr16, seq[Byte]]()
  result.roots = initTable[string, seq[Byte]]()
  initSpinLock(result.lock)

method put*(s: MemBlobStore; data: openArray[byte]): ByteArr16 =
  var dataCopy = newSeq[Byte](data.len)
  if data.len > 0: copyMem(addr dataCopy[0], unsafeAddr data[0], data.len)
  newUuidBytes(addr result[0])
  s.lock.acquire()
  try: s.blobs[result] = dataCopy
  finally: s.lock.release()

method putAt*(s: MemBlobStore; id: ByteArr16; data: openArray[byte]) =
  var dataCopy = newSeq[Byte](data.len)
  if data.len > 0: copyMem(addr dataCopy[0], unsafeAddr data[0], data.len)
  s.lock.acquire()
  try: s.blobs[id] = dataCopy
  finally: s.lock.release()

method get*(s: MemBlobStore; id: ByteArr16): Option[seq[byte]] =
  s.lock.acquire()
  try:
    if s.blobs.hasKey(id): result = some(s.blobs[id])
  finally: s.lock.release()

method delete*(s: MemBlobStore; id: ByteArr16) =
  s.lock.acquire()
  try: s.blobs.del(id)
  finally: s.lock.release()

method list*(s: MemBlobStore): seq[ByteArr16] =
  s.lock.acquire()
  try:
    for k in s.blobs.keys: result.add(k)
  finally: s.lock.release()

method putRoot*(s: MemBlobStore; name: string; data: openArray[byte]) =
  var dataCopy = newSeq[Byte](data.len)
  if data.len > 0: copyMem(addr dataCopy[0], unsafeAddr data[0], data.len)
  s.lock.acquire()
  try: s.roots[name] = dataCopy
  finally: s.lock.release()

method getRoot*(s: MemBlobStore; name: string): Option[seq[byte]] =
  s.lock.acquire()
  try:
    if s.roots.hasKey(name): result = some(s.roots[name])
  finally: s.lock.release()

method listRoots*(s: MemBlobStore): seq[string] =
  s.lock.acquire()
  try:
    for k in s.roots.keys: result.add(k)
  finally: s.lock.release()
  result.sort(cmp[string])

method deleteRoot*(s: MemBlobStore; name: string) =
  s.lock.acquire()
  try: s.roots.del(name)
  finally: s.lock.release()
