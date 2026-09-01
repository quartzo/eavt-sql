# Carga da Receita Federal — instrumento, referência e knobs

Metodologia oficial para os exercícios de carga (1k→50k empresas) e a
extrapolação para a base completa. Referência desta rodada: **2026-09-01,
commit `e73d61d`+** (save-many storage-batched, fix REF, word-store nos
encoders, skip de retract por (eid, attr) hidratado, fix do rootName do
flush worker, estabs via carga bulk com cache de eids client-side).

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

| estágio | taxa | tempo do estágio |
|---|---|---|
| empresas | 26.327 | 1,9 s |
| estabs   | **8.747** | 7,4 s |
| simples  | 35.123 | 1,6 s |
| sócios   | 19.598 | 1,3 s |

Degradação suave entre 1k→50k. Estabs usa a carga bulk (`load_estabs_bulk`,
save-many + cache de eids; `--flat-estabs` mantém o caminho per-datom para
comparação: 6.577 rows/s).

## Extrapolação da carga completa (@ taxas de 50k)

```
empresas   46M / 26.327/s → 0,49 h
estabs     73M /  8.747/s → 2,32 h   ← domina
simples    50M / 35.123/s → 0,40 h
sócios     28M / 19.598/s → 0,40 h
TOTAL ≈ 3,6 h
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
