## pthread_mutex binding (no std/locks dependency, no --threads:on).
## Works in static libs linked into cdylibs (no TLS relocation issues).

type
  PthreadMutexT* {.importc: "pthread_mutex_t", header: "<pthread.h>", bycopy.} = object
    data*: array[40, byte]  # sizeof(pthread_mutex_t) = 40 on glibc x86_64

  PthreadMutexAttrT* {.importc: "pthread_mutexattr_t", header: "<pthread.h>", bycopy.} = object
    data*: array[4, byte]

proc pthreadMutexInit*(m: var PthreadMutexT; attr: ptr PthreadMutexAttrT): cint
  {.importc: "pthread_mutex_init", header: "<pthread.h>", cdecl.}
proc pthreadMutexDestroy*(m: var PthreadMutexT): cint
  {.importc: "pthread_mutex_destroy", header: "<pthread.h>", cdecl.}
proc pthreadMutexLock*(m: var PthreadMutexT): cint
  {.importc: "pthread_mutex_lock", header: "<pthread.h>", cdecl.}
proc pthreadMutexUnlock*(m: var PthreadMutexT): cint
  {.importc: "pthread_mutex_unlock", header: "<pthread.h>", cdecl.}

type
  SpinLock* = object
    m*: PthreadMutexT

proc initSpinLock*(s: var SpinLock) =
  discard pthreadMutexInit(s.m, nil)

proc deinitSpinLock*(s: var SpinLock) =
  discard pthreadMutexDestroy(s.m)

proc acquire*(s: var SpinLock) =
  discard pthreadMutexLock(s.m)

proc release*(s: var SpinLock) =
  discard pthreadMutexUnlock(s.m)

template withLock*(s: var SpinLock; body: untyped) =
  acquire(s)
  try:
    body
  finally:
    release(s)
