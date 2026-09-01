## test_replication_queue.nim — ordem de eventos na fila do Subscriber.
##
## Regressão: as três filas paralelas antigas (buf/seals/roots) eram drenadas
## buf-primeiro, então uma escrita pós-captura entrava no MESMO frame wal
## que precedia o seal/root — a réplica selava dados pós-seal junto com os
## pré-seal e o root event descartava a diferença (perda intermitente de
## datoms/db.* sob carga, sintoma "attribute resolution failed" @50k).

import std/[unittest, strutils, sequtils]
import replication

suite "replication: ordem da fila de eventos":

  test "wal nunca atravessa seal/root — um frame por evento":
    let hub = initReplicationHub("/tmp/nonexistent")
    let s = Subscriber()
    hub.register(s)

    block:
      var d = @[byte(1), byte(2)]
      broadcastWal(addr hub, addr d[0], d.len)
    broadcastSeal(addr hub, 7)
    block:
      var d = @[byte(3)]
      broadcastWal(addr hub, addr d[0], d.len)
    broadcastRoot(addr hub, "root_x")

    let frames = s.collectOutgoing()
    check frames.len == 4

    let tags = frames.mapIt(
      if it.find("\xA3wal") >= 0: "wal"
      elif it.find("\xA4seal") >= 0: "seal"
      elif it.find("\xA4root") >= 0: "root"
      else: "?")
    check tags == @["wal", "seal", "wal", "root"]

  test "agregação continua permitida ENTRE marcadores":
    let hub = initReplicationHub("/tmp/nonexistent")
    let s = Subscriber()
    hub.register(s)

    block:
      var d = @[byte(1)]
      broadcastWal(addr hub, addr d[0], d.len)
    var d2 = @[byte(2)]
    broadcastWal(addr hub, addr d2[0], d2.len)  # sem marcador no meio → agrega
    broadcastSeal(addr hub, 3)

    let frames = s.collectOutgoing()
    check frames.len == 2                # [wal(1+2 agregados)] [seal]

  test "wal vazio não gera frame":
    let hub = initReplicationHub("/tmp/nonexistent")
    let s = Subscriber()
    hub.register(s)
    var dz: seq[byte] = @[]
    broadcastWal(addr hub, if dz.len > 0: addr dz[0] else: nil, 0)
    broadcastRoot(addr hub, "r")
    let frames = s.collectOutgoing()
    check frames.len == 1
    check frames[0].find("\xA4root") >= 0

  test "response enfileirada DEPOIS dos bytes wal da mesma request":
    # Invariante central da fila única: o sink roda durante a execução
    # (broadcastWal → buf); o handler enfileira a response depois —
    # flushBuf no enqueue garante wal-antes-de-response no fio.
    let hub = initReplicationHub("/tmp/nonexistent")
    let s = Subscriber()
    hub.register(s)

    block:
      var d = @[byte(9), byte(9)]
      broadcastWal(addr hub, addr d[0], d.len)
    s.enqueueResponse("\xDE\xAD\xBE\xEF")  # frame de resposta da request

    let frames = s.collectOutgoing()
    check frames.len == 2
    check frames[0].find("\xA3wal") >= 0
    check frames[1].find("\xDE\xAD\xBE\xEF") >= 0

    # Response em conexão SEM wal pendente não altera a ordem
    let s2 = Subscriber()
    hub.register(s2)
    s2.enqueueResponse("only")
    check s2.collectOutgoing().len == 1

  test "backlog acima do limite fecha o subscriber":
    let hub = initReplicationHub("/tmp/nonexistent")
    let s = Subscriber()
    hub.register(s)
    check not s.closed

    # 8 * 10 MiB = 80 MiB > ReplicationBacklogMaxBytes (64 MiB)
    var chunk: seq[byte]
    chunk.setLen(10 * 1024 * 1024)
    for i in 0..<8:
      broadcastWal(addr hub, addr chunk[0], chunk.len)
      if s.closed: break

    check s.closed
    # Subscriber fechado não recebe mais bytes: o pendente congela
    let pendingAtClose = s.pendingCount()
    check pendingAtClose > 0
    var d = @[byte(1)]
    broadcastWal(addr hub, addr d[0], d.len)
    check s.pendingCount() == pendingAtClose

  test "enqueueResponse respeita subscriber fechado":
    let hub = initReplicationHub("/tmp/nonexistent")
    let s = Subscriber()
    hub.register(s)
    s.closed = true
    s.enqueueResponse("ignored")
    check s.pendingCount() == 0
