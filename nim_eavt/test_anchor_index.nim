## test_anchor_index.nim — Unit tests for the packed anchor index (nim_eavt).

import std/[unittest, options, strutils]
import keys
import anchor_index

proc av(aid: uint32; v: string): seq[byte] =
  ## AV bytes como os probes reais constroem: [aid 4B BE][val]
  result = @[byte(aid shr 24), byte((aid shr 16) and 0xFF),
            byte((aid shr 8) and 0xFF), byte(aid and 0xFF)]
  for c in v: result.add byte(c)

suite "anchor index: probe / put / update":

  test "put + probe hit com eid correto":
    let idx = newAnchorIndex()
    let k = av(100'u32, "cnpj_12345678")
    idx.put(100'u32, k.toOpenArray(4, k.len - 1), 42)
    check idx.probe(100'u32, k.toOpenArray(4, k.len - 1)) == some(42'i64)
    check idx.len == 1
    check idx.hits == 1
    check idx.misses == 0

  test "probe miss em aid/val ausente":
    let idx = newAnchorIndex()
    let k = av(100'u32, "x")
    check idx.probe(100'u32, k.toOpenArray(4, k.len - 1)).isNone
    check idx.misses == 1

  test "mesmo AV re-put atualiza o eid (last write wins)":
    let idx = newAnchorIndex()
    let k = av(100'u32, "dup")
    idx.put(100'u32, k.toOpenArray(4, k.len - 1), 1)
    idx.put(100'u32, k.toOpenArray(4, k.len - 1), 2)
    check idx.len == 1
    check idx.probe(100'u32, k.toOpenArray(4, k.len - 1)) == some(2'i64)

  test "aids diferentes não colidem (prefixo aid no hash e na igualdade)":
    let idx = newAnchorIndex()
    let k1 = av(100'u32, "v")
    let k2 = av(200'u32, "v")
    idx.put(100'u32, k1.toOpenArray(4, k1.len - 1), 1)
    idx.put(200'u32, k2.toOpenArray(4, k2.len - 1), 2)
    check idx.probe(100'u32, k1.toOpenArray(4, k1.len - 1)) == some(1'i64)
    check idx.probe(200'u32, k2.toOpenArray(4, k2.len - 1)) == some(2'i64)

  test "val vazio (klen=4) funciona":
    let idx = newAnchorIndex()
    idx.put(100'u32, @[], 7)
    check idx.probe(100'u32, @[]) == some(7'i64)

suite "anchor index: del / tombstones / reuso":

  test "del remove e o probe cai no miss":
    let idx = newAnchorIndex()
    let k = av(100'u32, "gone")
    idx.put(100'u32, k.toOpenArray(4, k.len - 1), 1)
    idx.del(100'u32, k.toOpenArray(4, k.len - 1))
    check idx.probe(100'u32, k.toOpenArray(4, k.len - 1)).isNone
    check idx.len == 0
    check idx.curBytes == 0

  test "del + re-put reusa rec (sem crescimento de recs)":
    let idx = newAnchorIndex()
    let k = av(100'u32, "reuse")
    for i in 1 .. 50:
      idx.put(100'u32, k.toOpenArray(4, k.len - 1), i)
      idx.del(100'u32, k.toOpenArray(4, k.len - 1))
    idx.put(100'u32, k.toOpenArray(4, k.len - 1), 99)
    check idx.len == 1
    check idx.probe(100'u32, k.toOpenArray(4, k.len - 1)) == some(99'i64)
    check idx.recsLen <= 3   # free-list reusa os índices mortos

  test "tabela só de tombstones não trava o put (rehash compacta)":
    let idx = newAnchorIndex()
    var ks: seq[seq[byte]] = @[]
    for i in 1 .. 40:
      ks.add av(100'u32, "k" & $i)
    for k in ks:
      idx.put(100'u32, k.toOpenArray(4, k.len - 1), 1)
    for k in ks:
      idx.del(100'u32, k.toOpenArray(4, k.len - 1))
    check idx.len == 0 and idx.tombsCount == 40
    # put sobre tabela 100% tombstoned: findSlot precisa de Empty garantido
    let nk = av(100'u32, "novo")
    idx.put(100'u32, nk.toOpenArray(4, nk.len - 1), 5)
    check idx.probe(100'u32, nk.toOpenArray(4, nk.len - 1)) == some(5'i64)

suite "anchor index: rehash / crescimento":

  test "crescimento além de MinSlots preserva todos os registros":
    let idx = newAnchorIndex()
    for i in 1 .. 3000:
      let k = av(100'u32, "chave_" & $i)
      idx.put(100'u32, k.toOpenArray(4, k.len - 1), i)
    check idx.len == 3000
    check idx.capacity > 1024           # cresceu
    for i in 1 .. 3000:
      let k = av(100'u32, "chave_" & $i)
      check idx.probe(100'u32, k.toOpenArray(4, k.len - 1)) == some(i.int64)
    check idx.rehashes >= 2

  test "compação do rehash remove bytes mortos do arena":
    let idx = newAnchorIndex()
    for i in 1 .. 400:
      let k = av(100'u32, "v" & $i)
      idx.put(100'u32, k.toOpenArray(4, k.len - 1), i)
    for i in 1 .. 300:                    # mata 3/4
      let k = av(100'u32, "v" & $i)
      idx.del(100'u32, k.toOpenArray(4, k.len - 1))
    let cur = idx.curBytes
    idx.rehashForTest()                   # compacta
    check idx.arenaLen < cur             # bytes mortos fora
    for i in 301 .. 400:
      let k = av(100'u32, "v" & $i)
      check idx.probe(100'u32, k.toOpenArray(4, k.len - 1)) == some(i.int64)

suite "anchor index: LRU / budget":

  test "budget estourado evicta a cauda LRU (a mais fria)":
    # entrada típica: klen(12) + 8 + sizeof(AnchorRec) + 4 — budget para ~4
    let idx = newAnchorIndex(maxBytes = 4 * 40)
    for i in 1 .. 6:
      let k = av(100'u32, "k" & $i)
      idx.put(100'u32, k.toOpenArray(4, k.len - 1), i)
    check idx.len < 6
    check idx.evictions > 0
    # todas as restantes respondem corretamente
    for i in 1 .. 6:
      let k = av(100'u32, "k" & $i)
      let got = idx.probe(100'u32, k.toOpenArray(4, k.len - 1))
      if got.isSome: check got.get == i.int64

  test "touch protege os quentes (LRU de verdade)":
    # 4 cabem; aquece k1..k3 repetidamente, insere novos — k1..k3 sobrevivem
    let idx = newAnchorIndex(maxBytes = 256)   # 3 quentes + 2 frios cabem
    for i in 1 .. 3:
      let k = av(100'u32, "hot" & $i)
      idx.put(100'u32, k.toOpenArray(4, k.len - 1), i)
    for round in 1 .. 3:
      for i in 1 .. 3:                     # martela os quentes
        let k = av(100'u32, "hot" & $i)
        discard idx.probe(100'u32, k.toOpenArray(4, k.len - 1))
      let k = av(100'u32, "cold" & $round)
      idx.put(100'u32, k.toOpenArray(4, k.len - 1), round)
    for i in 1 .. 3:
      let k = av(100'u32, "hot" & $i)
      check idx.probe(100'u32, k.toOpenArray(4, k.len - 1)).isSome

  test "registro maior que o budget inteiro é rejeitado":
    let idx = newAnchorIndex(maxBytes = 64)
    let before = idx.rejected
    idx.put(100'u32, av(100'u32, "x".repeat(196)).toOpenArray(4, 199), 1)
    check idx.rejected == before + 1
    check idx.len == 0

suite "anchor index: clear":

  test "clear reseta tudo":
    let idx = newAnchorIndex()
    for i in 1 .. 50:
      let k = av(100'u32, "k" & $i)
      idx.put(100'u32, k.toOpenArray(4, k.len - 1), i)
    idx.clear()
    check idx.len == 0
    check idx.curBytes == 0
    let k1 = av(100'u32, "k1")
    check idx.probe(100'u32, k1.toOpenArray(4, k1.len - 1)).isNone
    # reutilizável pós-clear
    let kn = av(100'u32, "novo")
    idx.put(100'u32, kn.toOpenArray(4, kn.len - 1), 9)
    check idx.probe(100'u32, kn.toOpenArray(4, kn.len - 1)) == some(9'i64)
