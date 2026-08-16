import std/[os, nativesockets, posix]
import spawn
import eavt_server_nim/client
import shared, connection

proc serveClient(gw: ptr SharedGateway; fd: SocketHandle) {.gcsafe.} =
  handleGatewayConnection(gw, fd)
  discard posix.close(cint(fd))

proc getSocketPath(): string =
  let xdg = getEnv("XDG_RUNTIME_DIR")
  if xdg.len > 0:
    return xdg / "eavt" / "eavt.sock"
  return getHomeDir() / ".local" / "state" / "eavt" / "eavt.sock"

proc createUnixSocket(sockPath: string): SocketHandle =
  result = nativesockets.createNativeSocket(posix.AF_UNIX, posix.SOCK_STREAM, 0)
  if result == osInvalidSocket:
    raiseOSError(osLastError(), "socket()")
  let sockDir = sockPath.parentDir()
  if not dirExists(sockDir): createDir(sockDir)

  # Check if another server is already running (or stale socket from crash)
  block:
    var testFd = nativesockets.createNativeSocket(posix.AF_UNIX, posix.SOCK_STREAM, 0)
    var addr_un: Sockaddr_un
    addr_un.sun_family = TSaFamily(posix.AF_UNIX)
    copyMem(addr addr_un.sun_path, addr sockPath[0], min(sockPath.len, 108))
    let rc = posix.connect(testFd, cast[ptr SockAddr](addr addr_un), sizeof(Sockaddr_un).SockLen)
    discard posix.close(cint(testFd))
    if rc >= 0:
      stderr.writeLine "Gateway already running on ", sockPath
      quit(1)
    # Stale socket from crashed server — clean it up
    try: removeFile(sockPath) except: discard

  var addr_un: Sockaddr_un
  addr_un.sun_family = TSaFamily(posix.AF_UNIX)
  copyMem(addr addr_un.sun_path, addr sockPath[0], min(sockPath.len, 108))
  if bindSocket(result, cast[ptr SockAddr](addr addr_un), sizeof(Sockaddr_un).SockLen) < 0:
    raiseOSError(osLastError(), "bind()")
  if nativesockets.listen(result) < 0:
    raiseOSError(osLastError(), "listen()")

proc acceptClient(serverFd: SocketHandle): SocketHandle =
  var addr_un: Sockaddr_un
  var addrLen = sizeof(Sockaddr_un).SockLen
  result = posix.accept(serverFd, cast[ptr SockAddr](addr addr_un), addr addrLen)
  if result == osInvalidSocket:
    raiseOSError(osLastError(), "accept()")

proc main() =
  var sockPath = getSocketPath()
  var downstream = downstreamSocketPath()
  var args = commandLineParams()
  var i = 0
  while i < args.len:
    if args[i] == "--socket-path" and i + 1 < args.len:
      sockPath = args[i + 1]
      inc i
    elif args[i] == "--downstream-path" and i + 1 < args.len:
      downstream = args[i + 1]
      inc i
    elif args[i] == "--print-socket-path":
      echo sockPath
      return
    inc i
  echo "EAVT gateway starting on ", sockPath, " → ", downstream
  initSpawn()
  var gw = initSharedGateway(downstream)
  echo "Gateway initialized"
  let serverFd = createUnixSocket(sockPath)
  defer: discard posix.close(cint(serverFd))
  echo "Listening..."
  while true:
    let clientFd = acceptClient(serverFd)
    spawn(proc() {.gcsafe.} = serveClient(addr gw, clientFd))
when isMainModule: main()
