# Plano: Nim branch passar em 100% dos testes do main

**Objetivo:** `682` testes passando na branch `eavt-repl-nim` (hoje: **501 pass, 168 fail, 4 xfail, 9 errors**).

**Linha base:** `origin/main` (`/home/fabio/dev/eavt-sql`) — 682/682 passam, stack 100% Rust.

**Estado atual:** `eavt-repl-nim` (`/home/fabio/dev/eavt-sql-nim`) — storage + transactor + KVStore +
esquema evaluator portados para Nim. Compilador SQL (sql-parse → datalog → planner → compiler)
ainda em Rust. Query engine em Nim (`query/`) compilado mas não integrado nos testes Python.

---

## Categorias de falhas (~168 falhas + 9 erros)

### 1. Rust evaluator: variáveis não vinculadas (~80 testes)
**Sintoma:** `scheme eval error: unbound: _v_X_Y`, `type error: expected int, got ...`
**Raiz:** O compilador Rust gera Scheme IR que referencia variáveis que o evaluator Rust não vincula
corretamente. O evaluator Nim (`scheme.nim`) lê valores direto do scanner, resolvendo naturalmente.
**Solução:** Integrar `query/engine.nim` (SchemeHostFns + streaming) como backend de execução do
`spier_eavt_query_py`, substituindo `SchemeSession`/`SelectSchemeSession` Rust.
**Arquivos:** `spier-eavt-query/src/engine/scheme.rs`, `spier-eavt-query-py/src/lib.rs`

### 2. Journal / persistência (resolvido ✅)
**Sintoma:** `unknown attribute` após close/reopen, dados perdidos.
**Raiz:** `kvBatchWrite` só gravava memtable, sem journal. `recover_journal` sempre retornava vazio.
**Solução:** Commit `153f624` — journal recording em `kvBatchWrite` + replay em `openKvStore` +
truncate em `kvFlush`.
**Status:** Corrigido. Nenhum teste adicional esperado.

### 3. KV-level bindings ausentes (~3 testes — S3)
**Sintoma:** `ModuleNotFoundError: No module named 'spier_kvstore_py'`
**Raiz:** `spier-kvstore-py` deletado na fusão com `spier-page-store-nim`. Testes S3 usavam
`put`/`get`/`scan` raw KV que não estão expostos no `spier_eavt_query_py`.
**Solução:** Expor operações KV-level (`put`, `get`, `scan`, `open_cursor_direct`) no
`spier-eavt-query-py` via wrappers do `NimKVStore` já existente em `spier-page-store-nim/src/lib.rs`.
**Arquivos:** `spier-eavt-query-py/src/lib.rs`, `tests/test_config_s3_moto.py`

### 4. Journal file tests (~11 testes)
**Sintoma:** `ERROR tests/test_spier_journal.py` — importa `spier_kvstore_py` deletado.
**Raiz:** Testes de journal usam API KV-level para append/read/truncate.
**Solução:** Mesma da categoria 3 — expor operações KV-level.
**Arquivos:** `tests/test_spier_journal.py`, `tests/test_spier_transactor.py`

### 5. Erros de tipo no evaluator Rust (~30 testes)
**Sintoma:** `type error: expected int, got "SomeString"`
**Raiz:** O evaluator Rust converte tipos de valor incorretamente em algumas queries.
**Solução:** Integrar evaluator Nim (Fase 1).

### 6. Erros de importação em testes legados (~9 erros)
**Sintoma:** `ERROR collecting test_*.py` — `spier_kvstore_py`, `spier_transactor_py`
**Raiz:** Crates deletados, imports não atualizados.
**Solução:** A maioria já foi corrigida (seds nos arquivos de teste). Restam `test_spier_journal.py`
e `test_spier_transactor.py` que dependem da solução da categoria 3.

---

## Plano de execução (por nível de impacto)

### Fase 1: Integrar Nim evaluator como backend de execução (~110 testes)
**Impacto:** Resolve `unbound` e `type error` — o evaluator Nim (`scheme.nim` + `hostfns.nim`)
lê valores direto do scanner, eliminando as falhas de binding do evaluator Rust.

1. Serializar Scheme IR compilado (Rust) → passar ao Nim evaluator via C-ABI.
2. Nim evaluator executa e retorna resultado no formato de batch Python.
3. Modificar `spier-eavt-query/src/lib.rs` para usar Nim em vez de `SchemeSession` Rust.

### Fase 2: Expor operações KV-level no PyO3 (~14 testes)
**Impacto:** Resolve testes S3 (`test_config_s3_moto.py`) e journal (`test_spier_journal.py`,
`test_spier_transactor.py`) que dependem de `put`/`get`/`scan` raw KV.

1. Adicionar métodos KV-level ao `PyEngine` em `spier-eavt-query-py/src/lib.rs`.
2. Delegar ao `NimKVStore` já disponível via `TransactorState`.

### Fase 3: Corrigir bugs restantes no Nim storage/transactor
**Impacto:** Falhas que sobrarem após fases 1-2 são bugs reais na camada Nim
(encoding de chaves, flush, scan, etc). Corrigir diretamente no código Nim.

---

## Riscos e dependências

| Risco | Mitigação |
|---|---|
| Nim evaluator tem bugs não detectados | Escrever testes Nim para `scanner.nim` e `hostfns.nim` antes da integração |
| Formato de batch Python incompatível | Usar mesmo `query_codec::encode_one` do Rust via FFI ou reimplementar em Nim |
| Concorrência Rust↔Nim no evaluator | Thread-local state, sem compartilhamento de estado mutável entre threads |
| Regressão nos 490 testes que já passam | Rodar suite completa a cada fase, não commitar com regressões |

---

## Ordem de prioridade

1. **Fase 1** (maior impacto: ~110 testes) — Integrar Nim evaluator
2. **Fase 2** (~14 testes) — Expor KV-level ops
3. **Fase 3** (restante) — Ajustes finos

Estimativa: ~2-3 sessões de trabalho.
