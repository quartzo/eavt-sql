# Carga da Receita Federal — instrumento, referência e knobs

Metodologia oficial para os exercícios de carga (1k→50k empresas) e a
extrapolação para a base completa. Referência desta rodada: **2026-09-03,
M1+M2** (EDN tx nativo: entrada hidratada como memtable do CF-0 com
watermark/tombstones; CF-1/CF-3 deferidos com drain no flush; journal
completo via journalOnly; interpretador flat sem SExpr; keywords
internadas).  Referência histórica scheme: **2026-09-01, `e73d61d`+**
(save-many + cache de eids client-side — loader re-portado em
`load_receita_sql.py`, roda no build atual a 7,3k estabs/s).

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

| estágio | M1+M2 (EDN tx) | scheme (histórica) |
|---|---|---|
| empresas | **28.089** | 26.327 |
| estabs   | 5.687 | 8.747¹ |
| simples  | **35.413** | 35.123 |
| sócios   | 9.464² | 19.598² |

¹ o comparador direto hoje: scheme re-medido no build atual = 7.351/s
(ponto 65k); o 8.747 da doc antiga não é reproduzível (outra condição de
código/máquina).
² sócios EDN escreve 2 entidades/linha (pessoa dedup por socio/chave +
aresta de participação com cargo próprio) — modelo grafo, não comparável.

Degradação suave entre 1k→50k. Estabs via tx upsert por linha (âncora
cnpj_completo + empresa), sem cache client-side — seguro sob concorrência.

## Extrapolação da carga completa (@ taxas de 50k, M1+M2)

```
empresas   46M / 28.089/s → 0,45 h
estabs     73M /  5.687/s → 3,57 h   ← domina
simples    50M / 35.413/s → 0,39 h
sócios     28M /  9.464/s → 0,82 h
TOTAL ≈ 5,2 h
```

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
