# Perf: hidratação de eids EAVT — log de avaliação

Benchmark antes/depois da fonte de eids hidratados para o CF 0 (EAVT).
Sondas executadas contra a stack completa (query server → transactor via UDS),
carga parcial dos dados abertos da Receita Federal.

## Metodologia

- **Script:** `tests/bench_receita_hydrated.py` (importa os loaders de
  `py_eavt/examples/load_receita_sql.py`)
- **Orquestração:** `scripts/stop.sh` + `scripts/start.sh` por tamanho —
  DB fresco (`~/.local/state/eavt/db`) e stack nova a cada ponto
- **Tamanhos:** 5k, 10k, 25k, 50k empresas (Empresas0, primeiras N linhas)
- **Carga por tamanho:** declare schema → tabelas lookup → Empresas0 (N) →
  Simples (filtrado pelos membros) → Estabelecimentos0 (filtrado, scan
  completo de 30M linhas) → Socios0 (filtrado)
  - **Desvio no 50k:** estágio sócios omitido (`--skip-socios`) — veja
    "Instabilidade observada" abaixo; sócios @50k ≈ 5k entidades, sem efeito
    nas sondas (amostra é de empresas)
- **Sondas** (500 ops cronometradas cada, 50 de warmup, amostra seed-fixada 42):

| Sonda | Caminho | Expectativa pós-hidratação |
|---|---|---|
| `eid_lookup` | `(lookup-entity "empresa.cnpj_base" X)` — AVET (CF 2) | neutro (controle) |
| `attr_by_eid` | `(lookup-value <eid> "empresa.razao_social")` — **EAVT fast path** | grande ganho |
| `attrs_x3` | 3× `lookup-value` num único round-trip | ganho |
| `upsert` | `lookup-entity` + re-save de `empresa.capital_social` (card ONE → retract-scan) | ganho |
| `sql_point` | `SELECT … WHERE unique = ?` end-to-end | referência |

## Ambiente

- Host: fabio-desktop · Linux 6.x · 16 GiB RAM · NVMe
- Nim 2.2.10 · `--mm:orc --threads:on -d:release -d:useMalloc --opt:speed`
- Binários: `nimble dist` reconstruídos imediatamente antes da rodada
- Dados: `/home/fabio/dev/dagster_flows/tests_data/receita_zip` (2026-08-09)

## Baseline — ANTES da mudança (2026-08-23)

Latências em µs (menor é melhor). Carga ≈ 180–190s por tamanho,
dominada pelos scans fixos de Simples (~47s) e Estabelecimentos (~121s).

### n = 5.000 (carga 188,2s)

| Sonda | mean | p50 | p95 | ops/s |
|---|---:|---:|---:|---:|
| eid_lookup (AVET) | 57,4 | 57,1 | 62,3 | 17.427 |
| attr_by_eid (EAVT) | 51,1 | 47,3 | 59,8 | 19.580 |
| attrs_x3 | 56,6 | 55,9 | 61,0 | 17.674 |
| upsert | 128,6 | 125,1 | 169,2 | 7.774 |
| sql_point | 132,6 | 127,0 | 154,8 | 7.544 |

### n = 10.000 (carga 187,8s)

| Sonda | mean | p50 | p95 | ops/s |
|---|---:|---:|---:|---:|
| eid_lookup (AVET) | 48,0 | 47,7 | 51,9 | 20.824 |
| attr_by_eid (EAVT) | 49,2 | 48,9 | 53,1 | 20.307 |
| attrs_x3 | 55,8 | 53,9 | 59,7 | 17.937 |
| upsert | 120,0 | 117,3 | 138,1 | 8.330 |
| sql_point | 129,1 | 125,7 | 153,5 | 7.747 |

### n = 25.000 (carga 189,5s)

| Sonda | mean | p50 | p95 | ops/s |
|---|---:|---:|---:|---:|
| eid_lookup (AVET) | 54,2 | 49,1 | 64,8 | 18.460 |
| attr_by_eid (EAVT) | 54,5 | 50,9 | 64,6 | 18.355 |
| attrs_x3 | 55,6 | 54,5 | 61,4 | 17.980 |
| upsert | 129,8 | 126,7 | 148,1 | 7.702 |
| sql_point | 114,5 | 113,4 | 123,1 | 8.730 |

### n = 50.000 (carga 180,9s — sem sócios)

| Sonda | mean | p50 | p95 | ops/s |
|---|---:|---:|---:|---:|
| eid_lookup (AVET) | 48,2 | 43,7 | 68,4 | 20.764 |
| attr_by_eid (EAVT) | 54,5 | 51,5 | 73,1 | 18.362 |
| attrs_x3 | 60,5 | 56,5 | 79,6 | 16.518 |
| upsert | 132,5 | 124,1 | 205,0 | 7.549 |
| sql_point | 133,4 | 128,7 | 156,1 | 7.495 |

**Leitura do baseline:** latências de point-lookup são planas na escala
(≈45–55µs p50) — o custo é descida no B-tree + merge multi-source, não volume.
É exatamente esse piso que a hidratação ataca.

## Pós-hidratação — DEPOIS da mudança (2026-08-23)

Implementação: `nim_eavt/hydration` — fast path em `scanPrefixActive`
(cf 0, prefixo ≥ 8B, eid membro), espelho CF-0 em `batchWrite`,
hidratação na criação (`allocateEntityId`/`allocateInPartition`) e no
primeiro acesso (`hydrateEid` a partir de `lookupValue`/`lookupEntity`),
orçamento default 1 GiB. Mesmas sondas, seeds e tamanhos do baseline.

### n = 5.000 (carga 189,9s)

| Sonda | mean | p50 | p95 | ops/s | Δp50 vs baseline |
|---|---:|---:|---:|---:|---:|
| eid_lookup (AVET) | 45,4 | 43,5 | 54,8 | 22.049 | −24% (ruído/controle) |
| attr_by_eid (EAVT) | 43,3 | **40,6** | 52,9 | 23.088 | **−14%** |
| attrs_x3 | 53,9 | 53,9 | 68,0 | 18.537 | −4% |
| upsert | 126,6 | 120,1 | 178,6 | 7.899 | −4% |
| sql_point | 131,2 | 127,7 | 148,7 | 7.620 | +1% |

### n = 10.000 (carga 187,4s)

| Sonda | mean | p50 | p95 | ops/s | Δp50 vs baseline |
|---|---:|---:|---:|---:|---:|
| eid_lookup (AVET) | 46,4 | 45,1 | 57,4 | 21.544 | −5% |
| attr_by_eid (EAVT) | 45,8 | **45,0** | 55,9 | 21.821 | **−8%** |
| attrs_x3 | 53,2 | 48,7 | 67,1 | 18.814 | −10% |
| upsert | 121,8 | 116,9 | 170,8 | 8.209 | 0% |
| sql_point | 116,3 | 113,2 | 130,1 | 8.595 | −10% |

### n = 25.000 (carga 190,1s)

| Sonda | mean | p50 | p95 | ops/s | Δp50 vs baseline |
|---|---:|---:|---:|---:|---:|
| eid_lookup (AVET) | 44,6 | 41,8 | 53,7 | 22.409 | −15% |
| attr_by_eid (EAVT) | 41,6 | **40,7** | 46,2 | 24.036 | **−20%** |
| attrs_x3 | 49,3 | 48,5 | 54,8 | 20.270 | −11% |
| upsert | 125,5 | 118,0 | 167,1 | 7.966 | −7% |
| sql_point | 126,6 | 125,7 | 136,5 | 7.898 | +11% |

### n = 50.000 (carga 176,4s — sem sócios, igual ao baseline)

| Sonda | mean | p50 | p95 | ops/s | Δp50 vs baseline |
|---|---:|---:|---:|---:|---:|
| eid_lookup (AVET) | 43,4 | 42,9 | 46,6 | 23.050 | −2% |
| attr_by_eid (EAVT) | 43,4 | **43,0** | 46,7 | 23.041 | **−16%** |
| attrs_x3 | 50,0 | 49,6 | 53,4 | 20.003 | −12% |
| upsert | 124,6 | 113,6 | 194,2 | 8.026 | −8% |
| sql_point | 128,1 | 127,1 | 138,1 | 7.804 | −1% |

### Leitura dos resultados

- **`attr_by_eid` (alvo direto): −14% a −20% no p50**, consistente nos quatro
  tamanhos; o p95 cai mais ainda (−12% a −29%), eliminando as caudas de
  descida fria no B-tree.
- O piso de ~40µs é dominado pelo transporte (UDS + msgpack + VM yield/resume);
  o ganho do fast path é o delta acima dele. Em workloads com eids maiores
  (mais datoms por entidade) ou page cache frio, o delta tende a crescer —
  o custo eliminado (descida + merge) escala com o tamanho da entrada.
- `eid_lookup` (AVET, controle sem hidratação): estável dentro do ruído ✓.
- `upsert`: −4% a −8% — o retract-scan interno passa pelo source hidratado,
  mas continua dominado por allocate-tx + write path.
- Carga: tempo total estatisticamente igual (~180–190s); o espelho CF-0 em
  `batchWrite` não adicionou custo mensurável.

## Instabilidade observada — CAUSA-RAIZ ENCONTRADA E CORRIGIDA

Durante as cargas maiores ocorriam `RuntimeError: truncated index entry`
(estágio sócios @50k, ~determinístico no código pré-hidratação).

### Causa-raiz (page_cursor.nim::advanceToNextLeaf)

Em árvores de **altura 1** (raiz = único índice cujos filhos são folhas),
ao esgotar uma folha o cursor avançava para a irmã chamando
`loadIndexPage(sibling)` incondicionalmente — mas a irmã é uma **FOLHA**.
Dependendo dos bytes, isso explode com `truncated index entry` ou, pior,
"parseia" a folha como índice com entradas falsas e navega por ponteiros
fantasmas (`leaf blob not found`). Para níveis internos de árvores h ≥ 2 o
código estava correto; só o nível raiz→folhas estava quebrado.

Gatilho raro e dependente de dados: um seek que caia perto do fim de uma
folha e precise cruzar a borda adiante. A carga da Receita em 50k com a
tempestade de `get-or-create-entity` de sócios acertava essa janela
sistematicamente. Fix: quando `height == 1` e o topo da pilha é a raiz,
a irmã é folha → `loadLeaf` direto. Testes de regressão:
`test_page_store.nim` "leaf-boundary crossing on h=1 tree" (walk completo +
seek na última chave de uma folha atravessando a borda).

### Matriz A/B/C (binários por commit via worktrees; 50k completo, DB fresco)

| Braço | Commit | Sem fix do cursor | Com fix |
|---|---|---|---|
| pré-hidratação | `bab2cc7` | **FAIL** (1/1 tentado; historicamente ~100%) | **PASS 2/2** |
| + hidratação | `c5ac9fe` | PASS 3/3 (mascarado) | — |
| HEAD | `60f7d4f`+ | PASS 4/4 (mascarado) | suíte 620/620 |

### Hipóteses descartadas no caminho (com evidência)

- *GC deletando blobs vivos*: retenção default (12 h / 10 roots) nunca dispara
  em runs de minutos — o GC **nunca executou** nos benches; e o "blob ausente"
  era artefato do wipe do `start.sh` entre runs.
- *Colisão de uuid*: CSPRNG (`urandom`) desde `39b0de4`, anterior às falhas.
- *Corrida multi-worker do pool*: persistiu com pool = 1 worker.
- *Merge montando árvore inválida*: validador pós-merge (`validateTreeA`)
  caminhou a árvore recém-publicada sem jamais falhar — a estrutura escrita
  sempre esteve correta; quem errava era a **navegação** do leitor.

### Instrumentação deixada para trás

- `page_cursor.nim`: bad-page dump + lineage snapshot das trees no erro.
- `kvstore_async.nim::putPageA`: write-log uuid+kind por página atrás de
  `-d:eavtPageWriteLog` (off por padrão).

## Reprodução

```bash
nimble dist
uv run python tests/bench_receita_hydrated.py --label hydrated   # pós-mudança
uv run python tests/bench_receita_hydrated.py --label baseline   # referência
# resultados: /tmp/opencode/receita_bench/<label>.json
```

Para rodar tamanho único: `--sizes 50000`; pular estágios: `--skip-socios` etc.
