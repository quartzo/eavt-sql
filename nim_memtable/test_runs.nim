## nim_memtable/test_runs.nim
##
## Unit tests for the run-ladder memtable (M8): buf delta → runs ordenados
## (bisect) → draining (captura) — sem treap, sem COW.

import std/[unittest, options, algorithm]
import memtypes
import runs
import run_cursor

# ══════════════════════════════════════════════════════════════════════════════
# basic put + size
# ══════════════════════════════════════════════════════════════════════════════

suite "runs: put + size":
  test "single put increases size":
    let mt = newMemTable(2)
    let sz = mt.put(0, @[byte(1), 2, 3])
    check sz > 0

  test "different keys accumulate size":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(1)])
    discard mt.put(0, @[byte(2), 3])
    discard mt.put(0, @[byte(4)])
    check mt.size() == 4  # 1 + 2 + 1 bytes de chave

  test "separate CFs are independent":
    let mt = newMemTable(3)
    discard mt.put(0, @[byte(10)])
    discard mt.put(1, @[byte(20), 30])
    discard mt.put(2, @[byte(40)])
    check mt.size() > 0

  test "empty key has zero-byte size":
    let mt = newMemTable(1)
    let sz0 = mt.size()
    discard mt.put(0, @[])
    check mt.size() == sz0

  test "clear zera tudo":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(1)])
    mt.clear()
    check mt.size() == 0

# ══════════════════════════════════════════════════════════════════════════════
# batch
# ══════════════════════════════════════════════════════════════════════════════

suite "runs: batch":
  test "batch of 3 keys increases size":
    let mt = newMemTable(1)
    let k1 = @[byte(1)]; let k2 = @[byte(2)]; let k3 = @[byte(3)]
    let entries = @[
      CfKey(cf: 0, key: toKeyRef(k1)),
      CfKey(cf: 0, key: toKeyRef(k2)),
      CfKey(cf: 0, key: toKeyRef(k3)),
    ]
    let sz = mt.batch(entries)
    check sz == 3

# ══════════════════════════════════════════════════════════════════════════════
# materialização + cursor (bisect)
# ══════════════════════════════════════════════════════════════════════════════

suite "runs: materialize + RunCursor":
  test "materialize ordena o buf e o cursor itera ascendente":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(3)])
    discard mt.put(0, @[byte(1)])
    discard mt.put(0, @[byte(2)])
    mt.materializeAll()
    check mt.runs[0].len == 1
    let c = newRunCursor(mt.runs[0][0])
    check c.next().get == @[byte(1)]
    check c.next().get == @[byte(2)]
    check c.next().get == @[byte(3)]
    check c.next().isNone

  test "materialize deduplica mantendo a versão mais recente":
    # dedup por chave EXATA: mesmo key put duas vezes (mesmos bytes)
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(7)])
    discard mt.put(0, @[byte(7)])
    mt.materializeAll()
    check mt.runs[0][0].ptrs.len == 1
    check mt.size() == 1  # cfSize ajustado pelo materialize

  test "chaves com sufixo diferente são distintas":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(1), 0])
    discard mt.put(0, @[byte(1), 5])
    mt.materializeAll()
    check mt.runs[0][0].ptrs.len == 2

  test "seek avança ao alvo (bisect)":
    let mt = newMemTable(1)
    for i in 1..50:
      discard mt.put(0, @[byte(i)])
    mt.materializeAll()
    let c = newRunCursor(mt.runs[0][0])
    c.seek(@[byte(30)])
    let k = c.peek()
    check k.isSome and k.get[0] >= 30

  test "seek além do fim → none":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(1)])
    mt.materializeAll()
    let c = newRunCursor(mt.runs[0][0])
    c.seek(@[byte(9), 9])
    check c.peek().isNone
    check c.atEnd

  test "run vazio → atEnd":
    let mt = newMemTable(1)
    mt.materializeAll()  # buf vazio — nenhum run criado
    check mt.runs[0].len == 0

  test "escada passa de 8 runs → merge (1 run, ordenado)":
    let mt = newMemTable(1)
    for round in 1 .. 9:
      for i in 0 ..< 5:
        discard mt.put(0, @[byte(round), byte(i)])
      mt.materializeAll()
    check mt.runs[0].len == 1   # merge no 9º
    let c = newRunCursor(mt.runs[0][0])
    var prev: seq[byte] = @[]
    var count = 0
    while true:
      let k = c.next()
      if k.isNone: break
      if prev.len > 0: check cmpKeysByte(prev, k.get) < 0
      prev = k.get
      inc count
    check count == 45

suite "runs: recência (buf → runs → draining)":

  test "buf é mais novo que o run — getValue vê o delta":
    let mt = newMemTable(12)
    discard mt.putKv(10, @[byte(1)], @[byte(100)])
    mt.materializeAll()
    discard mt.putKv(10, @[byte(1)], @[byte(200)])   # delta mais novo
    check mt.getValue(10, @[byte(1)]) == some(@[byte(200)])

  test "tombstone no delta mata o valor do run":
    let mt = newMemTable(12)
    discard mt.putKv(10, @[byte(1)], @[byte(100)])
    mt.materializeAll()
    mt.deleteKv(10, @[byte(1)])
    check mt.getValue(10, @[byte(1)]).isNone      # tombstone → none
    check mt.containsAny(10, @[byte(1)])          # mas presente

  test "run mais novo vence run mais velho":
    let mt = newMemTable(12)
    discard mt.putKv(10, @[byte(1)], @[byte(100)])
    mt.materializeAll()
    discard mt.putKv(10, @[byte(1)], @[byte(200)])
    mt.materializeAll()
    check mt.getValue(10, @[byte(1)]) == some(@[byte(200)])

  test "freezeAll move para draining; getValue continua vendo":
    let mt = newMemTable(12)
    discard mt.putKv(10, @[byte(1)], @[byte(100)])
    mt.freezeAll()
    check mt.runs[10].len == 0
    check mt.draining[10].len == 1
    check mt.getValue(10, @[byte(1)]) == some(@[byte(100)])
    check mt.size() == 0                          # ativos zerados (threshold)

  test "publish descarta draining":
    let mt = newMemTable(12)
    discard mt.putKv(10, @[byte(1)], @[byte(100)])
    mt.freezeAll()
    mt.publish()
    check mt.getValue(10, @[byte(1)]).isNone
    check not mt.containsAny(10, @[byte(1)])

# ══════════════════════════════════════════════════════════════════════════════
# drain (k-way, newest-wins)
# ══════════════════════════════════════════════════════════════════════════════

suite "runs: drainSorted":
  test "drain intercala runs em ordem ascendente":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(1)]); discard mt.put(0, @[byte(5)])
    mt.materializeAll()
    discard mt.put(0, @[byte(2)]); discard mt.put(0, @[byte(9)])
    mt.materializeAll()
    let ks = drainSorted(mt.runs[0])
    check ks == @[@[byte(1)], @[byte(2)], @[byte(5)], @[byte(9)]]

  test "drain deduplica exato (run mais novo vence)":
    let mt = newMemTable(1)
    discard mt.put(0, @[byte(1), 1])   # versão velha (mesma chave? não — sufixo distinto)
    discard mt.put(0, @[byte(2)])
    mt.materializeAll()
    discard mt.put(0, @[byte(2)])      # dup exato no delta novo
    mt.materializeAll()
    let ks = drainSorted(mt.runs[0])
    check ks.len == 2                  # (1,1) e (2) — dup (2) suprimido

  test "drainKvSorted classifica pares e tombstones":
    let mt = newMemTable(12)
    discard mt.putKv(10, @[byte(1)], @[byte(10)])
    discard mt.putKv(10, @[byte(2)], @[byte(20)])
    mt.deleteKv(10, @[byte(2)])
    mt.materializeAll()
    let (pairs, deleted) = drainKvSorted(mt.runs[10])
    check pairs == @[( @[byte(1)], @[byte(10)] )]
    check deleted == @[@[byte(2)]]
