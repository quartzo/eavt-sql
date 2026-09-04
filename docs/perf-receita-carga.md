# Carga da Receita Federal — instrumento, referência e knobs

Metodologia oficial para os exercícios de carga (1k→50k empresas) e a
extrapolação para a base completa. Referência desta rodada: **2026-09-04,
M1..M4 + WAL CF-0-only** (`5e8412c`: entrada hidratada como memtable do
CF-0 com watermark/tombstones; CF-1/CF-3 deferidos; âncora CF-2 como hash;
entrada parcial para eids frios; journal CF-0-only com replay resiliente;
`param` no slot E — probes de plano pontual).  Referência histórica scheme:
**2026-09-01, `e73d61d`+** (save-many + cache de eids client-side — loader
re-portado em `load_receita_sql.py`, roda no build atual a 7,3k estabs/s).

## Instrumento

`tests/bench_receita_hydrated.py` — modo padrão **goc dessincronizado**:

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
