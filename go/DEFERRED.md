# Port Nim → Go: adiado, divergências e atalhos

Este documento lista, de forma explícita, **tudo o que foi adiado, ficou
diferente do Nim ou foi feito por atalho** no port Go (`go/`). O objetivo é
não deixar dívida escondida.

Estado geral: a stack Go está **funcional de ponta a ponta** — REPL,
compilador datalog (25/25 wire byte-idêntico + explain 25/25), query server
(réplica + execução local) e transactor (write path + tx + WAL + replicação +
GC). O que segue são os buracos conhecidos.

Referência dos binários: `build/eavt-sql-{cli-go,query-front-go,query-go,transactor-go}`.

---

## 1. Adiado (não implementado)

- **Flush chunked + pool de blobs.** O flush Go agora é **faseado**
  (`CaptureFlush` sob o lock → `PrepareFlush` **fora** do lock → `PublishFlush`
  sob o lock), então o I/O de blobs **não segura o engine**. O que ainda falta
  em relação ao Nim: o Nim **fatia** o drain em ~256 KiB com
  `await sleepAsync(0)` entre fatias (serve queries durante o próprio drain) e
  usa o blob pool (zstd + I/O em workers). No Go o `PrepareFlush` é uma única
  passada bloqueante numa goroutine (não fatia) e o zstd roda nessa mesma
  goroutine, sem pool. Arquivos: `internal/kvstore/kvstore.go`,
  `internal/pagestore/store.go` (`PrepareMerge`/`PrepareMergeKv`),
  `internal/transactor/server.go` (`runFlush`).
- **`hydrated` (cache de leitura por eid, M6).** Não portado; `hydrateEid`
  é no-op. Como consequência, os *fast paths* de escrita que dependem de
  `probeComplete` (`skip provado` do retract scan e do `hasDatom`) **nunca
  são tomados** — sempre faz scan. Correto, mais lento. (`internal/eavt/*`.)
- **`anchor_index` (hash AV→eid, M7).** Não portado. `LookupEntity`,
  `LookupEntityW` e `BatchLookupAvet` caem sempre no scan CF-2. Correto,
  mais lento. (`internal/eavt/write.go`, `internal/engine/write.go`.)
- **Backends de blobstore S3 e journal.** Só o backend `file` foi portado
  (`internal/blobstore`). O facade async/pool de blobstore não é usado pelo
  transactor Go.
- **Arena plana do PageStore** (`FlatLeafKeys`/`FlatLeafKV`). O cursor Go usa
  `[][]byte`/`[][2][]byte`; é mais alocação por troca de folha.
- **Contadores/diagnóstico de performance** (`memledger`, `printSavePerf`,
  `printSpPerf`, `printBwPerf`, `eavtScanDiag`, `spCounters`): não portados.
- **Loader de receita** (`load_receita`): existe em OCaml/Python, **não foi
  portado para Go**.
- **`scheme` VM**: portado o suficiente para queries (e os special forms de
  exec). `scanner-iterate` (special form legado) foi portado mas é código
  morto — o compilador emite keyword opcodes.
- **`edn` maps/sets**: rejeitados por design (o surface tx-data não os usa).

### Resolvidos depois de terem sido adiados
- **GC do pagestore** — implementado em `internal/pagestore/gc.go`
  (`GcFull`/`HasOldRoots`/`ClassifyRoots`), wire em `.gc`/`.gc-dry` e
  auto-GC pós-flush.
- **`explain`** — renderer portado (`internal/datalog/explain.go`), golden
  25/25.
- **Concorrência do query server** — o mutex global foi removido. Agora vale
  a **lógica de snapshot real**: a MemTable tem mutex interno e expõe
  `SnapshotRuns`/`FreezeAllCapture` (runs imutáveis), o PageStore tem
  `treeMu` + cache com mutex, o Resolver tem RWMutex, e o KVStore usa um
  `snapshotMu` para tornar atômico "capturar runs + root" vs. o publish
  (troca do root + limpa draining). Cada query pina seu snapshot no open e
  conclui sem lock; WAL apply e outras queries rodam em paralelo.
- **Flush stop-the-world no transactor** — o flush passou a ser
  capture/prepare/publish; só o capture e o publish (curtos) seguram o lock.
  O `PrepareFlush` (I/O de blobs) roda **fora** do lock.

---

## 2. Deixado errado / divergências conhecidas

- **KV CFs (>= 10) NÃO são duráveis nem replicam (bug real).**
  - `PutKv` (`internal/kvstore/kvstore.go`) chama `journalDeliver` com um
    `CfKey` **só-chave** — o **valor é descartado**. No replay,
    `ParseJournalRecords` só processa `cf <= 3`, então o registro KV nem é
    lido. Resultado: `.kv-put`/`PutKv` não sobrevivem a restart.
  - `DeleteKv` grava direto no arquivo legacy `journal/journal`, **ignorando o
    sink WAL** (divergente do Nim, que não grava nada quando o sink existe).
  - Impacto: superfície KV (`.kv-*`, qualquer uso de CF >= 10) não é durável
    nem replicada. **O caminho de datoms (CF 0-3) está correto** (WAL CF-0),
    então datalog/tx estão íntegros.
- **`slotToPackedValue` de keyword** (`internal/query/edn_tx.go`): para
  `TskKw` retorna `v.S`, que é vazio (o slot guarda só `Sym`). Espelha o
  comportamento do Nim, mas keyword usada **como valor de datom** codifica
  vazio — bug latente compartilhado.
- **Planner com cardinalidade minúscula** (`internal/datalog/planner.go`):
  quando `total_eavt` é pequeno, a busca de custo pode escolher uma ordem
  "blind-first" que gera programa inválido (var sem scanner no depth). É a
  **mesma aritmética de custo do Nim** (não é bug do port), mas é uma
  fragilidade: com store de 1 datom só, a query pode vir vazia. Dados
  realistas escolhem a ordem correta.
- **Sessão de paridade anterior estava furada.** `go/testdata/parity_session.txt`
  usava `:db.type/double`, que **o próprio Nim rejeita** (o tipo é
  `:db.type/float`). A paridade "OK" de 44 linhas passava com **ambos errando**
  e nunca exercitava float de verdade. Corrigido para `float` (agora 51 linhas).
- **Replica lê segmentos do snapshot de forma síncrona** na goroutine do
  reader do downstream (`internal/querysrv/server.go` → `replica.ApplySnapshot`).
  Um snapshot grande bloqueia a entrega de respostas/eventos durante a
  leitura. O Nim usa leitura async (chronos-file).
- **Corrida no snapshot do WAL**: `wal.Segments` lista inclusive o segmento
  **corrente**, que pode estar sendo appendado durante a montagem do
  snapshot. O parser tem resync de tail torn e duplicatas são puts
  idempotentes, mas existe uma janela (a mesma do Nim).
- **`admin tree` não existe** (retorna `unknown admin command: tree`) e
  `status` só reporta `memtable: N bytes` — igual ao Nim, porém pobre.
- **`deleteKv`/`putKv` com sink**: ver o primeiro item. `journalDeliver` do Go
  usa o sink para puts (mas perde o valor) e o `DeleteKv` nem usa o sink.

---

## 3. Atalhos

- **Framing/forward**: para despachar e para injetar o `id` de correlação eu
  **decodifico o frame inteiro** com msgpack e re-encodo
  (`internal/downstream/downstream.go` `injectID`, `internal/querysrv`,
  `internal/transactor`). O Nim usa `injectTopPair` (append cru no mapa),
  preservando os bytes originais. Semanticamente igual; a re-encodação pode
  mudar bytes (ordem de chaves, largura de int) e custa O(payload).
- **PageStore cache**: guarda formas decodificadas (`[][]byte`), sem arena
  plana; um único orçamento de bytes (o `index_cache_bytes` do Nim era só
  log).
- **WAL**: goroutine + `os.WriteAt` + ticker de 100 ms em vez do chronos-file
  thread-pool. Mesma semântica de durabilidade (fsync por intervalo ~100 ms;
  crash de processo sempre seguro, crash de máquina perde ≤ ~100 ms).
- **Transactor**: um único `e.mu` serializa a aplicação de tx e as janelas
  curtas de capture/publish do flush e do GC. A aplicação de tx é CPU-bound
  curta (o Nim, single-loop, também serializa). O I/O de blobs do flush roda
  fora do lock. Ainda há concorrência entre o ciclo do WAL, os drains de
  replicação (mutex próprio) e os handlers.
- **Query server**: goroutine por conexão, **sem lock global**. A consistência
  vem da snapshot isolation (ver §"Snapshot" abaixo): o cursor pina runs +
  root no open e itera lock-free. WAL apply e queries não se bloqueiam.
- **`EncodeCompileStats`**: usa encoding de int mínimo em vez do `uint64`
  explícito do Nim — compatível com os decoders (Nim/OCaml/Go), bytes
  diferentes.
- **Testes de paridade**: o harness compara REPL e front, não a stack
  transactor-vs-transactor byte a byte.
- **`scheme.String` de float**: portado do `$float` do Nim (dragonbox) e
  golden 45 vetores; usado também pelo pretty-printer do explain.

---

## 4. Snapshot (implementação correta)

A concorrência segue a semântica do Nim (runs congelados + COW root),
**sem lock global**:

- **MemTable** (`internal/memtable/memtable.go`): mutex interno para a
  escada; `SnapshotRuns(cf)` materializa o delta e devolve os `*Run`
  **imutáveis** (draining + ativos); `FreezeAllCapture()` congela e devolve
  as runs capturadas. Runs nunca são mutadas depois de criadas.
- **PageStore** (`internal/pagestore/store.go`, `cache.go`): `treeMu`
  (RWMutex) guarda `trees`/`currentRoot`; a cache de páginas tem mutex
  próprio. `Tree(cf)`/`BaseTrees()` dão o snapshot do root; `PublishTrees`/
  `LoadRoot` trocam sob write lock.
- **KVStore** (`internal/kvstore/kvstore.go`): `snapshotMu` (RWMutex) torna
  **atômico** `OpenScanCursor` (capturar runs + root) contra
  `PublishFlush`/`PublishRoot` (trocar root + limpar draining). Sem isso, um
  cursor aberto no meio do publish veria o root novo **e** as runs draining
  antigas, contando o dado duas vezes.
- **Resolver** (`internal/eavt/resolver.go`): RWMutex; leituras concorrentes
  (queries) sob RLock, escrita (WAL/schema) sob Lock.
- **Query server** (`internal/querysrv/server.go`): sem lock de engine; só o
  cache de `CompileStats` tem mutex. Cada query pina o snapshot no open do
  cursor e conclui; WAL apply roda em paralelo.

Validado com `-race`: query server (e transactor) com `-race`, 4 clientes
lendo (8 queries cada) enquanto um writer faz `tx` (WAL → réplica) →
**sem data races**; e `TestSnapshotIsolation` prova que um cursor aberto antes
de um flush continua vendo o snapshot antigo.

---

## 5. Lacunas de verificação (o que não foi testado)

- **Sem paridade A/B da stack completa** (transactor Go × Nim) além do REPL
  (51 linhas). A stack Go foi validada funcionalmente (tx/kv/dump/query/float),
  não byte-a-byte em todas as combinações.
- **Sem teste E2E de replicação** (transactor Go → réplica Go) além do teste
  de ordem do hub (`internal/replication/replication_test.go`); a réplica foi
  exercitada indiretamente pelo query server Go no E2E.
- **Sem teste E2E de restart/recovery** (replay do WAL + `recoverWriteState`)
  na stack Go.
- **Sem teste de concorrência do transactor** (o `-race` cobre o query server,
  não vários clientes concorrentes no transactor).
- **Sem teste E2E do auto-GC pós-flush** (só unitário do `gcFull`).
- **WAL delete-durável** coberto só em unitário, não em E2E.
- **`ocaml/` permanece no repo** e o `nimble dist` ainda tenta compilar o front
  OCaml (abandonado) — dívida a remover; hoje isso pode quebrar `dist` se o
  `dune` não estiver no PATH.

---

## 6. Mapa rápido por arquivo

| Item | Onde |
|---|---|
| Flush faseado (sem pause) | `internal/kvstore/kvstore.go`, `internal/pagestore/store.go`, `internal/transactor/server.go` |
| KV não durável | `internal/kvstore/kvstore.go` (`PutKv`/`DeleteKv`/`journalDeliver`) |
| hydrated/anchor ausentes | `internal/eavt/*`, `internal/engine/write.go` |
| Planner blind-first | `internal/datalog/planner.go` |
| Snapshot (memtable/kvstore) | `internal/memtable/memtable.go`, `internal/kvstore/kvstore.go`, `internal/pagestore/{store,cache}.go`, `internal/eavt/resolver.go` |
| Snapshot da réplica é síncrono no reader (latência) | `internal/querysrv/server.go`, `internal/replica/replica.go` |
| Snapshot WAL do segmento corrente | `internal/wal/wal.go` (`Segments`), `internal/transactor/server.go` |
| Re-encodação de frames | `internal/downstream/downstream.go` |
| Só backend file | `internal/blobstore` |
| `gcFull` / GC | `internal/pagestore/gc.go` |
| `explain` | `internal/datalog/explain.go` |
| Float `$float` | `internal/numfmt/numfmt.go` |
