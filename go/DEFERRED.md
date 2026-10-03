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

- **Fatiamento do drain em ~256 KiB.** O Nim fatia o drain em fatias de
  ~256 KiB com `await sleepAsync(0)` (serve queries no próprio loop do drain).
  No Go isso não é necessário para a *latência*: o `PrepareFlush` roda numa
  goroutine **fora** do `e.mu`, e queries rodam em outras goroutines — ver a
  entrada resolvida `Flush + blob pool` abaixo. O que fica de fora é
  fatiar um único CF gigante em merges intermediários (o Go faz um passe
  ordenado por CF); o worker pool já paraleliza a compressão/escrita.
- ~~**Cursor hidratado do scanner — variante `/as-of`/history.**~~ **Resolvido
  no Go (mais estrito que o Nim).** O modo hid do `MergedCursor` só é ligado
  para CF-0 em scanners **não** history/as-of: `EngineOps.OpenCursor(cfID,
  prefix, history)` recebe a flag e `QueryStore.OpenCursor` só seta
  `mc.Hyd` quando `!history`; o `scannerOpen` passa `history || HasAsOfTx`.
  No Nim o cursor hidratado também só tem chaves ativas, então um as-of que
  ancore num eid hidratado lá perderia versões antigas — no Go isso não
  acontece. Regressão: `TestOpenCursorHydGuard`.
- ~~**Backends de blobstore S3 e journal.**~~ **S3 portado** (ver a entrada
  resolvida). O `Journal` (marcador sequencial do page store) também foi
  portado como primitiva testada, mas **não é fiado** ao commit do page store
  (o WAL + journal legacy do kvstore já cobrem durabilidade; fiá-lo apagaria
  o journal legacy no modo sem sink). O facade async/pool do blobstore
  continua sem uso — o transactor Go usa o worker pool do flush.
- **Arena plana do PageStore** (`FlatLeafKeys`/`FlatLeafKV`). O cursor Go usa
  `[][]byte`/`[][2][]byte`; é mais alocação por troca de folha.
- **Buckets de nanossegundos e `eavtScanDiag`.** Os *counts* e o `memledger`
  foram portados (ver a entrada resolvida). Fica de fora o detalhamento de
  tempo (`saveLookupAttrNs`, `saveRetractSeekNs`, `spOpenCursorNs`, `bwNs`,
  `execWallNs`, …), que no Nim é `when perfCounters* = false` (compile-time,
  desligado por padrão) e o `-d:eavtScanDiag`. Portá-los exigiria instrumentar
  ~10 call-sites com `clock_gettime`; os *counts* já dão a visão de volume.
- ~~**Loader de receita** (`load_receita`)~~ — portado (ver a entrada
  resolvida `Loader de receita em Go`).
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
- **Loader de receita em Go** — `internal/loader` + `cmd/eavt-load` (build:
  `eavt-sql-load-go`), porta do loader de referência `load_receita`: schema como
  tx-data (eids 1000+i), depois lookups/empresas/simples/estabelecimentos/
  sócios em lotes de `tx` pelo socket do query server, usando tempids
  negativos + upsert de attr único para get-or-create. Lê os zips
  (`archive/zip` + `encoding/csv` com `;`), converte latin-1→UTF-8, e
  reproduz a chave de sócio (cpf visível + 6 chars base64url de sha256 do
  nome normalizado). Opções `--n/--data-dir/--sock/--batch/--demo-only/
  --skip-*/--max-estabs/--max-socios`. Testes com zips sintéticos e um
  `Txer` fake (`TestLoadLookupsSynthetic`, `TestLoadEmpresasSynthetic`,
  `TestSocioChaveStable`, `TestLatin1ToUTF8`); E2E contra a stack Go OK.
- **Backend S3 do blobstore** — `internal/blobstore` ganhou a interface
  `BlobStore`, o `S3BlobStore` + SigV4 (`sigv4.go`, HMAC/SHA-256 da stdlib) e
  a factory `Open` (file|s3). Wire: `pagestore.Store.blobs` passou a
  `blobstore.BlobStore`, `pagestore.Open` seleciona pelo `Backend`,
  `kvstore`/`replica`/transactor e query server carregam as chaves S3
  (`EAVT_BACKEND` + `EAVT_S3_{ENDPOINT,BUCKET,ACCESS_KEY,SECRET_KEY,REGION,
  PREFIX,PATH_STYLE}` / flags `--backend --s3-*`). O WAL continua local; os
  blobs vão para o bucket. Testes: vetor de signing key da AWS, HMAC/SHA,
  round-trip S3 contra um S3 in-process (blobstore e pagestore), read-only e
  config faltando; E2E transactor+query ambos em S3 OK (write→flush→query).
- **`logutil` + `memledger` + `stats`** — `internal/logutil` porta o logger do
  Nim (níveis DEBUG<INFO<WARN<ERROR, threshold `EAVT_LOG`, uma linha
  timestamped no stderr, concorrência-safe). O transactor ganhou o
  **memledger** periódico (10s, `EAVT_MEM_LEDGER` != "0"): RSS
  (`/proc/self/statm`) + `hyd` bytes/eids + `anchor` bytes/eids + memtable
  bytes + runs ativos/draining + `gen` + `flushActive` — o mesmo instrumento
  do M9, agora no Go. Contadores de volume (`internal/eavt` scans/scanKeys,
  `internal/engine` saves/lookups/execs, `internal/kvstore` batchWrites/
  writtenKeys) são expostos por `.stats` e zerados por `.stats-reset`
  (comandos admin; o `.help` fica idêntico ao Nim para não quebrar a parity).
  Erros do WAL e do flush passam por `logutil`.
- **Flush + blob pool + auto-flush** — `internal/pagestore` ganhou o blob pool
  (`blobPutPages`): compressão zstd + escrita de blobs em paralelo num pool
  limitado a 2–4 workers, com `putPageList`/`putIndexPages` usados por
  `PrepareMerge`/`PrepareMergeKv`/`buildIndexTree`/`writeIndexLevel`; há um
  `yieldPageWork` (Gosched) nas fronteiras de CF (o análogo Go do
  `sleepAsync(0)`). No transactor, o auto-flush por threshold agora está
  **armado** (`OnFlushRequest = requestFlush`) com um driver single-flight que
  coalesce pedidos (o Nim `AsyncFlusher`); `.flush` enfileira e `.flush-sync`
  espera (`flushSync`). Falha de prepare agora libera a captura
  (`AbortFlush`) em vez de travar o store com `flushActive` preso.
  Testes: `TestPooledMergeIntoExistingTree`, `TestAbortFlushReleasesCapture`,
  `TestAutoFlushOnThreshold`.
- **`hydrated` (cache de leitura por eid, M6)** — portado em
  `internal/hydrated`: buffer plano por entrada + array de offsets, LRU com
  orçamento, `applyKey` (write-through), `hydrate`/`hydrateEmpty`,
  `hasAttrKey`/`lookupRange`/`keysFrom`. Cada método pega o mutex interno e
  devolve cópias (o Nim é single-threaded e empresta a entrada ao cursor).
  Wire: `eavt.BatchWrite` espelha CF-0, `ScanPrefixActive` serve seeks CF-0
  ancorados num eid hidratado, `HydrateEID` no read-time, `Allocate*` marca
  entidades novas; no engine, `HasDatomW` ("skip provado") e os lookups
  hidratam; o `MergedCursor` tem modo hid (snapshot de chaves no seek).
  Config: `EAVT_HYDRATED_ENABLED`/`EAVT_HYDRATED_MAX_BYTES` (default 256 MiB).
- **`anchor_index` (hash AV→eid, M7)** — portado em `internal/anchor`: hash
  empacotado com arena + recs de índice estável, FNV-1a sem concatenação,
  LRU/eviction, rehash com compactação, mutex interno. Wire:
  `eavt.BatchWrite` espelha CF-2 (put/del), `RecoverWriteState` reconstrói do
  resíduo CF-0, `BatchLookupAvet`/`LookupEntityByValue` e os lookups do engine
  fazem probe antes do scan CF-2. Config: `EAVT_ANCHOR_INDEX_MAX_BYTES`.
- **CF-2 de atributo `:db/unique` não era derivado na réplica (bug real,
  pré-M6).** A réplica atualizava o resolver **antes** de gravar o chunk de
  schema, então o `:db/unique` do próprio chunk não era visível a `IsIndexed`
  e as chaves CF-2 (AVET) nunca eram derivadas — queries em attr unique
  voltavam vazias até um flush/adoção de root trazer o CF-2 do transactor
  (o Nim não exibe isso). Corrigido em `internal/replica` `applyRecords`:
  grava primeiro os CF-0 do chunk, atualiza o resolver, depois deriva os
  índices. Regressão: `TestWalSchemaRefreshBeforeDerive`.

---

## 2. Deixado errado / divergências conhecidas

- **KV CFs (>= 10) só são duráveis via flush** (limitação do Nim, não bug do
  port). Com sink WAL instalado, `PutKv`/`DeleteKv` **não journalam** — o WAL é
  CF-0-only por design (o datom é a verdade) e CFs KV são duráveis quando o
  flush publica no page-store. Sem sink, caem no arquivo legacy `journal/`
  **com o valor** (o `journalRecord` agora emite o formato exato do parser:
  key-only `vlen=1/value=0x00`, valor `vlen=len(value)`; o formato antigo
  tinha um byte extra e era inconsistente com `journalRecordLenAt`). O
  `ParseJournalRecords` continua processando só `cf <= 3`, então KV não é
  *replayado* (igual ao Nim). **O caminho de datoms (CF 0-3) está correto**
  (WAL CF-0), então datalog/tx estão íntegros. Correção anterior de
  fidelidade: o Go escrevia um record WAL só-chave para `PutKv` (valor
  descartado, e o Nim não escreve nada com sink) e `DeleteKv` ignorava o sink
  — agora ambos seguem a regra do Nim (`JournalSink == nil`).
- ~~**`slotToPackedValue` de keyword.**~~ **Corrigido no Go (divergência
  deliberada).** O slot `TskKw` guarda só o símbolo internado (como no Nim), e
  o `slotToPackedValue` do Nim retornava `v.s` (vazio) — keyword usada como
  valor de datom codificava `""`. Agora `SlotToValueForType`/
  `slotToPackedValue` recebem o symtab e resolvem o nome para `TskKw`.
  Regressão: `TestKeywordValueEncodesName` + E2E (`:person/status :active`
  volta `active`).
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
- ~~**`admin tree` não existe.**~~ **Implementado no Go (extensão):** o REPL
  já anunciava `.tree` mas o handler respondia `unknown`; agora `tree`
  reporta por CF (`cf= height= leaves= root=`). `status` segue igual ao Nim
  (`memtable: N bytes`); o detalhe fica em `.stats`.
- **`deleteKv`/`putKv` com sink**: resolvido — ambos não journalam com sink
  (`JournalSink == nil`); sem sink, gravam o valor/tombstone no legacy com o
  formato correto. Ver o primeiro item.

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
  thread-pool. O `Sink` escreve para o arquivo (page cache do OS) **na hora**;
  o fsync fica no tick de ~100 ms → crash de processo não perde nada, crash de
  máquina perde ≤ ~100 ms.
- **Transactor**: `e.mu` serializa apenas a aplicação de tx/exec (como o
  single-loop do Nim) e as janelas curtas de capture/publish do flush e do GC.
  Leituras (scheme query, kv get/scan, dump, schema) e o I/O de blobs do flush
  (`PrepareFlush`) rodam **sem** esse lock. Writes continuam na memtable
  **ativa** enquanto o flush drena a **congelada** (draining), liberada só no
  publish. Estado compartilhado restante é atômico/lockado internamente
  (`memSize`/`flushActive` atômicos, WAL com mutex próprio, hub com mutex).
- **Query server**: goroutine por conexão, **sem lock global**. A consistência
  vem da snapshot isolation (ver §"Snapshot" abaixo): o cursor pina runs +
  root no open e itera lock-free. WAL apply e queries não se bloqueiam.
- **`EncodeCompileStats`**: usa encoding de int mínimo em vez do `uint64`
  explícito do Nim — compatível com os decoders (Nim/Go), bytes
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
- **Transactor** (`internal/transactor/server.go`): mesma dualidade
  ativa/congelada — tx escrevem na ativa (min/max do ladder), o flush congela
  via `FreezeAllCapture` e drena a congelada, que segue legível pelos cursores
  até o `PublishFlush` (limpa draining + troca o root sob `snapshotMu`).

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
- **Restart/recovery** agora coberto por `scripts/restart_recovery.sh`
  (Alice flushed + Bob via WAL replay + bootstrap no WAL, sem legacy journal).
- **Sem teste de concorrência do transactor** (o `-race` cobre o query server,
  não vários clientes concorrentes no transactor).
- **Sem teste E2E do auto-GC pós-flush** (só unitário do `gcFull`).
- **WAL delete-durável** coberto só em unitário, não em E2E.
- ~~**`ocaml/` no repo / `dune` no `dist`.**~~ **Resolvido**: a trilha OCaml
  (abandonada) foi removida — `ocaml/` apagado, o passo `dune` saiu do
  `nimble dist`, o `dev.sh` não sobe mais o front OCaml e os binários stale
  (`eavt-query-front-ocaml`, `test_frontend`) foram removidos. O front Go
  (`eavt-sql-query-front-go`) é o sucessor.

---

## 6. Mapa rápido por arquivo

| Item | Onde |
|---|---|
| Flush faseado (sem pause) | `internal/kvstore/kvstore.go`, `internal/pagestore/store.go`, `internal/transactor/server.go` |
| KV não WAL'd (só flush) | `internal/kvstore/kvstore.go` (`PutKv`/`DeleteKv`/`journalRecord`) |
| hydrated (M6) / anchor (M7) | `internal/hydrated/*`, `internal/anchor/*`, `internal/eavt/*`, `internal/engine/{engine,write}.go`, `internal/cursor/cursor.go` |
| Cursor hid + history (latente) | `internal/cursor/cursor.go`, `internal/engine/engine.go` (`OpenCursor`) |
| CF-2 unique derivado na réplica | `internal/replica/replica.go` (`applyRecords`) |
| Planner blind-first | `internal/datalog/planner.go` |
| Snapshot (memtable/kvstore) | `internal/memtable/memtable.go`, `internal/kvstore/kvstore.go`, `internal/pagestore/{store,cache}.go`, `internal/eavt/resolver.go` |
| Snapshot da réplica é síncrono no reader (latência) | `internal/querysrv/server.go`, `internal/replica/replica.go` |
| Snapshot WAL do segmento corrente | `internal/wal/wal.go` (`Segments`), `internal/transactor/server.go` |
| Re-encodação de frames | `internal/downstream/downstream.go` |
| Só backend file | `internal/blobstore` |
| `gcFull` / GC | `internal/pagestore/gc.go` |
| `explain` | `internal/datalog/explain.go` |
| Float `$float` | `internal/numfmt/numfmt.go` |
