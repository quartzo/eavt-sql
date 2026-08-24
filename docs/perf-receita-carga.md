# Carga da Receita Federal — instrumento, referência e knobs

Metodologia oficial para os exercícios de carga (1k→50k empresas) e a
extrapolação para a base completa. Referência desta rodada: **2026-08-24,
commit `9622628`+** (arena plana, cursor preguiçoso corrigido, fila única
de replicação, root broadcast no flush assíncrono).

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
| empresas | 22.557 | 2,2 s |
| estabs   | **5.326** | 12,2 s |
| simples  | 28.558 | 1,9 s |
| sócios   | 16.231 | 1,8 s |

Degradação suave entre 1k→50k: estabs −17%, demais ±5%.

## Extrapolação da carga completa (@ taxas de 50k)

```
empresas   46M / 22.557/s → 0,57 h
estabs     73M /  5.326/s → 3,81 h   ← domina
simples    50M / 28.558/s → 0,49 h
sócios     28M / 16.231/s → 0,48 h
TOTAL ≈ 5,3 h
```

## Knobs relevantes

| Knob | Default | Quando mexer |
|---|---|---|
| `EAVT_PAGE_CACHE_SIZE` / `--page-cache-size` | 64 MB | Neutro no exercício @≤50k (working set cabe). **Carga completa**: working set materializado ultrapassa 64MB — recomendado 512MB–1GB |
| `index_cache_bytes` | 32 MB | Índices parseados; acompanhar com page_cache |
| `hydrated_max_bytes` | 1 GiB | Fast path CF-0; aumentar se entidades quentes > budget |
| `gc_max_age_secs` / `gc_root_count` | 12 h / 10 | Retenção antes do GC; réplica consome raizes com lag |

## Correções que compõem esta referência (histórico)

- `7124ad8` flush assíncrono broadcasta root à réplica + seal na captura
- `5f0328c` fila única ordenada — wal nunca atravessa seal/root
- `6411e1c` folhas materializadas em arena plana (seek 310→23 µs)
- `3c30333` cursores preguiçosos do scanPrefixActive
- `bd28381` cat4 single-alloc + move de chaves no batchWrite
