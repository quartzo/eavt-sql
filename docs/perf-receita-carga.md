# Carga da Receita Federal — instrumento, referência e knobs

Metodologia oficial para os exercícios de carga (1k→50k empresas) e a
extrapolação para a base completa. Referência desta rodada: **2026-09-05,
M6/M7/M8** (treap COW eliminado — escada de runs; instrumento executado
via wrapper com `ATTRIBUTE` traduzido para tx EDN — a superfície SQL é
fase C).  Referência anterior: **2026-09-04, M1..M4 + WAL CF-0-only** (`5e8412c`: entrada hidratada como memtable do
CF-0 com watermark/tombstones; CF-1/CF-3 deferidos; âncora CF-2 como hash;
entrada parcial para eids frios; journal CF-0-only com replay resiliente;
`param` no slot E — probes de plano pontual).  Referência histórica scheme:
**2026-09-01, `e73d61d`+** (save-many + cache de eids client-side — loader
re-portado em `load_receita_sql.py`, roda no build atual a 7,3k estabs/s).

## Instrumento

`tests/bench_receita_hydrated.py` — modo padrão **goc dessincronizado**; `--stack nim|go` escolhe qual stack o `scripts/start.sh` sobe (mesmo cliente Python, mesmo protocolo, mesmo host — só o servidor muda):

- cada estágio lê apenas as primeiras linhas dos arquivos (proporcionais ao
  tamanho), sem filtro de membros — cada linha ancora sua entidade por
  atributo único no servidor (`get-or-create-entity`); ordem do arquivo é
  irrelevante por construção;
- subsets proporcionais às razões da base completa:
  `estabs = 1,3N · simples = 1,1N · sócios = 0,5N`;
- orquestração: `scripts/stop.sh` + `start.sh` por tamanho (DB fresco);
- probes pós-carga (500 ops): `eid_lookup` (AVET, controle), `attr_by_eid`
  (EAVT fast path), `attrs_x3`, `upsert` (retract-scan), `sql_point`;
- saída: taxas de escrita por estágio + EXTRAPOLAÇÃO da carga completa
  (`FULL_ROWS / taxa` do maior tamanho).

`--legacy-filter` preserva o modo antigo (varredura nacional com membership)
para comparações.

## Referência M6/M7/M8 (@10k e @25k — wrapper tx; 2026-09-05)

| estágio | M8 @10k | M8 @25k | M1..M4 @50k |
|---|---|---|---|
| empresas | 28.220 | 28.298 | 24.040 |
| estabs   | **6.525** | **6.181** | 5.519 |
| simples  | 36.201 | 30.064 | 29.405 |
| sócios   | 8.196 | 11.691 | 9.158 |

Probes @25k (p50): eid_lookup 78,5 µs · attr_by_eid **107 µs** (era 143) ·
attrs_x3 **220 µs** (era 363) · upsert **52 µs** (era 63).

Extrapolação completa (@25k): **empresas 0,45 h · estabs 3,28 h ·
simples 0,46 h · sócios 0,67 h → TOTAL ≈ 4,9 h** (era 5,5 h).

**BLOCKER na validação de escala**: o ponto 1M quebra no estágio estabs
com SIGSEGV no dispatcher de completions do blob pool
(`dispatchCompletion → newSeq[byte](job.outLen)` com outLen corrompido —
coredump confirmado). **Pré-existente**: reproduz idêntico no checkout
M7 — não é regressão do M8. O smoke histórico de 1M era só empresas
(estabs@1M nunca rodou). Empresas 1M + simples 1,1M carregam ilesos em
ambos (M8: 15,4k/s empresas no debug, 20k/s no M7 release). Investigação
própria: ciclo de vida de job no pool (cancel/recycle vs completion) —
arquivo como Known Issue no AGENTS.md.

## Referência Go (port da stack, 2026-10-03)

Rodada com o **mesmo harness e o mesmo cliente**: `uv run python
tests/bench_receita_hydrated.py --stack go --label go --sizes
10000,25000,50000` (JSON: `/tmp/opencode/receita_bench/go.json`). A única
variável é o servidor (stack Go em vez da Nim); a guarda `ulimit -v 3 GB`
do `start.sh` vale só para o Nim (o Go fica abaixo dela naturalmente).

### Taxas (rows/s)

| estágio | Go @10k | Go @25k | Go @50k | Nim ref @25k (M8) |
|---|---|---|---|---|
| empresas | 26.223 | 27.102 | 25.738 | 28.298 |
| estabs   | **6.978** | **7.450** | 7.774 | 6.181 |
| simples  | 32.856 | 29.070 | 30.848 | 30.064 |
| sócios   | **12.671** | **14.232** | 13.333 | 11.691 |
| load total | 3,1 s | 7,2 s | 14,1 s | — |

### Probes (p50, 500 ops)

| probe | Go @10k | Go @25k | Go @50k | Nim ref @25k |
|---|---|---|---|---|
| eid_lookup (AVET) | 40,9 µs | **36,7 µs** | 38,7 µs | 78,5 µs |
| attr_by_eid (EAVT) | 41,4 µs | **41,3 µs** | 40,5 µs | 107 µs |
| attrs_x3 | 82,2 µs | **85,8 µs** | 79,9 µs | 220 µs |
| upsert (retract-scan) | 71,3 µs | 80,6 µs | 72,6 µs | **52 µs** |

### Extrapolação da carga completa (@ taxas de 50k, Go)

```
empresas   46M / 25.738/s → 0,50 h
estabs     73M /  7.774/s → 2,61 h   ← continua dominando
simples    50M / 30.848/s → 0,45 h
sócios     28M / 13.333/s → 0,58 h
TOTAL ≈ 4,1 h   (Nim @25k: 4,9 h)
```

**Leitura**: a stack Go fica **dentro de ±5%** das taxas de escrita do Nim
(empresas −4%, simples −3%) e é **20–22% mais rápida** em estabs/sócios; os
probes pontuais ficam **2,1–2,6× mais rápidos** (eid_lookup/attr_by_eid/
attrs_x3). O único regresso é o **upsert (tx)**, ~1,55× mais lento — o
caminho de tx Go passa por `TransactTx` (decode + lookup único + retract
scan) sem o atalho do `hasDatom` do editor. A extrapolação total cai de
4,9 h → 4,1 h.

Rodada nesta data com o código do port já incluindo as correções de perf
(`hydrated` M6, `anchor` M7, blob pool do flush, arena plana do page store,
drain fora do lock, credit do backlog de replicação). Contagem fixa
(declare+lookups) ≈ 0,1 s.

## Referência @50k (todas as taxas em linhas/s)

| estágio | M1..M4 final | M1+M2 (anterior) | scheme (histórica) |
|---|---|---|---|
| empresas | 24.040 | **28.089** | 26.327 |
| estabs   | 5.519 | 5.687 | 8.747¹ |
| simples  | 29.405 | **35.413** | 35.123 |
| sócios   | 9.158 | 9.464² | 19.598² |

¹ o comparador direto hoje: scheme re-medido no build atual = 7.351/s
(ponto 65k); o 8.747 da doc antiga não é reproduzível (outra condição de
código/máquina).
² sócios EDN escreve 2 entidades/linha (pessoa dedup por socio/chave +
aresta de participação com cargo próprio) — modelo grafo, não comparável.

Degradação suave entre 1k→50k. Estabs via tx upsert por linha (âncora
cnpj_completo + empresa), sem cache client-side — seguro sob concorrência.
As taxas M1..M4 caíram ~15% vs M1+M2 (o write path novo tem custo próprio:
roteamento hyd/deferred/hash); o ganho estrutural está na memória e no
journal (CF-0-only, −60-70% de volume), não na taxa.

## Probes @50k (p50, 500 ops — M1..M4 final)

| probe | p50 | vazão |
|---|---|---|
| eid_lookup (AVET) | 87 µs | 11.198/s |
| attr_by_eid (EAVT) | **143 µs** | 7.015/s |
| attrs_x3 | 363 µs | 2.738/s |
| upsert (retract-scan) | 63 µs | 14.526/s |

`attr_by_eid`/`attrs_x3` exigem o fix do `:in` no slot E (`5e8412c`): sem
ele o plano iterava o índice inteiro do attr (391 ms / 1,15 s) e — pior —
retornava TODAS as entidades em vez da vinculada (bug de corretude).

## Escala: smoke 1M empresas (mesma rodada)

1M empresas em 60,6 s (16,5k/s; ~40 flushes async + GC auto):
probes eid_lookup 102 µs, attr_by_eid 282 µs (p95 2,0 ms — miss de page
cache), upsert 61 µs. Réplica acompanhou por stream (2.400 frames /
266 MB WAL, 232 roots adotados) e fechou com **1.000.000 exatos**.
Restart `--keep-db` restaura 1M em ~12 s (pagestore + replay CF-0-only
com resync de segmento rasgado). 10 roots retidos / 2.284 page blobs
(GC `gc_root_count`=10 ativo).

## Extrapolação da carga completa (@ taxas de 50k, M1..M4)

```
empresas   46M / 24.040/s → 0,53 h
estabs     73M /  5.519/s → 3,67 h   ← domina
simples    50M / 29.405/s → 0,47 h
sócios     28M /  9.158/s → 0,85 h
TOTAL ≈ 5,5 h
```

Próximos alvos de perf (perfil da sessão M4): insertKeyAt churn (11% do
CPU, O(k) no buf flat) e sort do worker (12%, off-loop) — ambos no estabs,
o estágio que domina a extrapolação.

## Knobs relevantes

| Knob | Default | Quando mexer |
|---|---|---|
| `EAVT_PAGE_CACHE_SIZE` / `--page-cache-size` | **512 MB** | Neutro no exercício @≤50k. Default elevado pós-experimento: carga completa tem working set materializado >> 64MB |
| `index_cache_bytes` | 32 MB | Índices parseados; acompanhar com page_cache |
| `hydrated_max_bytes` | 1 GiB | Fast path CF-0; aumentar se entidades quentes > budget |
| `gc_max_age_secs` / `gc_root_count` | 12 h / 10 | Retenção antes do GC; réplica consome raizes com lag |

## Correções que compõem esta referência (histórico)

- `7124ad8` flush assíncrono broadcasta root à réplica + seal na captura
- `5f0328c` fila única ordenada — wal nunca atravessa seal/root
- `6411e1c` folhas materializadas em arena plana (seek 310→23 µs)
- `3c30333` cursores preguiçosos do scanPrefixActive
- `bd28381` cat4 single-alloc + move de chaves no batchWrite
