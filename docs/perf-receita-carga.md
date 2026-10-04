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

`tests/bench_client_split.py --data-dir <zips da Receita>` — decompõe o
pipeline em fases do cliente (`read` = inflate+CSV · build · `to_wire` · pack
· send · **recv = round-trip do servidor** · unpack) e mede o CPU real de
cada processo; `--depth N` põe N batches em voo, `--clients N` roda N
processos-cliente (ver "Quem limita o throughput"). Sem `--data-dir` usa
linhas sintéticas do mesmo formato.

`tests/bench_cpu_dist.py -- <cliente>` — amostra `/proc/<pid>/stat` a cada
50 ms nos três processos (transactor, query, cliente) durante uma carga real e
reporta CPU-s, % de 1 núcleo (média e pico) e fatia do total; `--cmd2` roda um
segundo cliente em paralelo (ver "Ocupação de CPU — configuração real").

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
| empresas | 26.774 | 27.518 | 26.378 | 28.298 |
| estabs   | **7.275** | **7.746** | 7.937 | 6.181 |
| simples  | 34.206 | 29.450 | 31.527 | 30.064 |
| sócios   | **13.044** | **14.114** | 13.859 | 11.691 |
| load total | 3,0 s | 7,0 s | 13,7 s | — |

### Probes (p50, 500 ops)

| probe | Go @10k | Go @25k | Go @50k | Nim ref @25k |
|---|---|---|---|---|
| eid_lookup (AVET) | 39,8 µs | **39,9 µs** | 41,5 µs | 78,5 µs |
| attr_by_eid (EAVT) | 40,3 µs | **42,8 µs** | 46,3 µs | 107 µs |
| attrs_x3 | 79,9 µs | **82,8 µs** | 92,4 µs | 220 µs |
| upsert (retract-scan) | 75,3 µs | 72,6 µs | 71,6 µs | **52 µs** |

### Extrapolação da carga completa (@ taxas de 50k, Go)

```
empresas   46M / 26.378/s → 0,48 h
estabs     73M /  7.937/s → 2,55 h   ← continua dominando
simples    50M / 31.527/s → 0,44 h
sócios     28M / 13.859/s → 0,56 h
TOTAL ≈ 4,0 h   (Nim @25k: 4,9 h)
```

**Leitura**: a stack Go fica **dentro de ±5%** das taxas de escrita do Nim
(empresas −3%, simples −2%) e é **20–28% mais rápida** em estabs/sócios; os
probes pontuais ficam **1,9–2,6× mais rápidos** (eid_lookup/attr_by_eid/
attrs_x3). A extrapolação total cai de 4,9 h → 4,0 h.

### Onde o tempo do `upsert` (tx) vai — medição de hop a hop

Sonda sintética com o **mesmo cliente Go** em dois caminhos (benchmarks
`BenchmarkTxUpsert{,Remote}` em `internal/eavt...`/`internal/e2e`,
`EAVT_PROBE_SOCK` aponta para o transactor [1 hop] ou o query server
[2 hops]; `EAVT_FLUSH_THRESHOLD` alto para não interferir o auto-flush):

| caminho | Nim | Go |
|---|---|---|
| transactor (1 hop) | 20,5 µs | 22,3 µs (≈ a par) |
| query server (2 hops) | 40,3 µs | **57,1 µs** (+41%) |

Conclusões e correções aplicadas nesta rodada:

- **O custo não é compute** (o `execTx` puro é ~4,5 µs): é a **latência de
  round-trip** (espera em syscall ~50%, futex ~12%). Num 1-hop o Go emparelha
  com o Nim.
- Correções: `WriteFrame`/`client.sendFrame` passam a **um writev** (antes 2
  syscalls/handoff por frame — divisor de wakeup por leitura); o
  `Subscriber.drain` escreve **toda a fila num writev** (o WAL e a resposta
  ficam na mesma escrita → o leitor acorda uma vez, não duas). Isso levou o
  2-hop de 82,6 µs → 57,1 µs.
- O que **não** se pode fazer: mandar a resposta numa conexão dedicada (já
  testado — remove um handoff, mas perde a ordem `[WAL][resposta]` e o read-
  your-writes quebra; idem para "flush do WAL imediato na fila"). O gap
  restante (+15 µs no hop do query server) é overhead de handoff do Go
  runtime (goroutine wake/futex vs o loop único do chronos) — não é compute.

Rodada nesta data com o código do port já incluindo as correções de perf
(`hydrated` M6, `anchor` M7, blob pool do flush, arena plana do page store,
drain fora do lock, credit do backlog de replicação, writev + drain
coalesced). Contagem fixa (declare+lookups) ≈ 0,1 s.

## Quem limita o throughput — cliente Python × servidor (2026-10-04)

**Pergunta**: a carga da Receita é limitada pelo servidor ou pelo cliente
Python? As tabelas acima medem só o wall agregado; aqui o pipeline é
decomposto fase a fase e o CPU de cada processo é medido.

**Instrumento**: `tests/bench_client_split.py --data-dir …` — reproduz o
pipeline EXATO do harness de referência (serial, 1 batch em voo, mesmo
cliente, mesmos builders de ops do `load_receita_edn`) e cronometra: `read`
(inflate do zip + decode CSV + filtro), `build` (montar ops), `wire`
(`to_wire()` recursivo), `pack`, `send`, **`recv` (tempo bloqueado no
round-trip do servidor)**, `unpack`. CPU real por processo:
`time.process_time()` no cliente, `Δ(utime+stime)` de `/proc/<pid>/stat` em
query e transactor.

**Dados e ambiente**: zips **REAIS** da Receita em
`/home/ubuntu/dev/dagster_flows/tests_data/receita_zip` (o loader traz o
caminho hardcoded da máquina original `/home/fabio/...`; aqui se passa
`--data-dir`). Host ubuntu · 12 cores · 8 GiB · Python 3.13 (uv),
`--n 50000`, `batch 500`, 2 hops (query). Os binários Nim são os de `build/`
(06-09) e os Go os de 03-10 — o Nim desta máquina fica abaixo da referência
da doc (tabela seguinte), então comparar **entre si, mesma rodada**, não com
as tabelas da seção Go/M8 acima.

### Reprodução da referência (harness oficial, dados reais, nesta máquina)

`tests/bench_receita_hydrated.py --data-dir …` vs. o que a doc registra:

| estágio | doc Go @25k | **aqui Go @25k** | doc Nim @25k (M8) | **aqui Nim @25k** |
|---|---:|---:|---:|---:|
| empresas | 27.518 | **26.875** | 28.298 | **24.137** |
| estabs   |  7.746 | **7.612**  |  6.181 | **5.932**  |
| simples  | 29.450 | **28.621** | 30.064 | **25.034** |
| sócios   | 14.114 | **14.167** | 11.691 | **11.549** |

@50k: **Go** 25.743 / 7.794 / 30.408 / 13.160 → extrapolação **4,1 h** (doc
4,0 h) · **Nim** 20.315 / 6.111 / 24.524 / 10.024 → **5,3 h** (doc 4,9 h).
Probes @50k (p50): Go eid_lookup 40,5 µs · attr_by_eid 56,9 µs · attrs_x3
81,6 µs · upsert 73,9 µs; Nim 81,3 / 108,2 / 237,6 / 64,4 µs. O Go reproduz
a doc dentro de −1…−5%; o Nim está ~15% abaixo (build mais antigo/máquina).

### Pipeline serial (como o harness) — quem paga o wall

| estágio | stack | rows/s | read | build | to_wire | pack | **recv (servidor)** | CPU cliente | CPU transactor |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| empresas | Nim | 21.194 | 3,1% | 12,5% | 25,3% | 2,8% | **55,7%** | 42,4% | 46,6% |
| empresas | Go  | 25.883 | 3,7% | 15,1% | 30,7% | 3,3% | **46,5%** | 51,8% | 65,2% |
| estabs   | Nim |  5.697 | 2,2% | 13,8% | 27,0% | 3,1% | **53,4%** | 44,7% | 57,2% |
| estabs   | Go  |  7.657 | 3,0% | 18,9% | 34,3% | 3,8% | **39,0%** | 60,0% | 68,7% |

Leitura: o wall é **~metade round-trip do servidor / ~metade cliente Python**,
com o cruzamento invertido por stack — agregado empresas+estabs o **Go fica
59,6% cliente / 40,4% servidor** (6,21s vs 4,21s) e o **Nim 46,2% / 53,8%**
(6,36s vs 7,41s; o round-trip do Nim é mais caro). Pelo teto medido, o Go
daria **27,3k rows/s** com um cliente instantâneo mas o cliente só sustenta
**18,5k** com o servidor instantâneo (cliente é o limite mais apertado); no
Nim é o contrário por pouco (servidor 15,5k × cliente 18,1k). Nenhum dos
processos passa de ~1 núcleo. `read` (inflate do zip + decode CSV **reais**)
é barato: 2–4% — o custo está em `to_wire` + `build`.

### Com pipelining (`--depth 8`, 1 cliente)

| estágio | stack | rows/s | Δ vs serial | recv | CPU cliente |
|---|---|---:|---:|---:|---:|
| empresas | Nim | 34.064 | **+61%** | 0,7% | 68,1% |
| empresas | Go  | 41.556 | **+61%** | 0,6% | 84,9% |
| estabs   | Nim |  8.690 | **+53%** | 0,5% | 71,3% |
| estabs   | Go  | 11.136 | **+45%** | 0,4% | 92,3% |

O round-trip some (recv ~0,5% do wall) e a taxa atinge o teto "servidor
ideal" medido (Go estabs: 11.136 medido vs 11.182 de teto). Cliente em
**92% de um núcleo** (Go) / **71%** (Nim) → o gargalo passa a ser o Python
nas duas stacks.

### 2 processos-cliente (`--depth 8`, Go)

| estágio | rows/s | CPU cliente (soma) | CPU transactor | CPU query |
|---|---:|---:|---:|---:|
| empresas | 35.087 | 89,0% | 88,4% | 50,5% |
| estabs   | **14.194** | **163,9%** | **146,7%** | 76,0% |

**+27% em estabs só dobrando o cliente** (11.136 → 14.194): o transactor
sobe de 1,03 → 1,47 núcleo e o query de 0,52 → 0,76 (12 cores disponíveis).
Prova de que um único processo Python é o limite imediato — mas o ganho já
não é linear, então depois de corrigir o cliente o servidor volta a pesar.

### Cliente Go × Python (mesma carga, mesma stack — `build/eavt-sql-load-go`)

O loader Go (`go/cmd/eavt-load`) com as **mesmíssimas contagens** do harness
Python (verificado: simples 55.129 · estabs 65.000 · sócios 25.001 idênticos
nos dois clientes), `-n 50000 -max-simples 55000 -max-estabs 65000
-max-socios 25000`, mesmos zips, 2 hops. Instrumentação nova no loader:
flag `-max-simples` + linhas `[t]` (rows/s por estágio).

| cliente × servidor | empresas | simples | estabs | sócios | wall do load |
|---|---:|---:|---:|---:|---:|
| Python × Nim | 20.315 | 24.524 | 6.111 | 10.024 | 17,9 s |
| Python × Go  | 25.743 | 30.408 | 7.794 | 13.160 | 14,1 s |
| **Go × Nim** | 29.938 | 31.133 | 8.096 | 13.330 | 13,4 s |
| **Go × Go**  | **37.620** | **44.058** | **11.236** | **18.831** | **9,7 s** |

Extrapolação da carga completa (46M/73M/50M/28M linhas):

| combinação | estimativa |
|---|---:|
| Python × Nim (doc: 4,9 h) | 5,3 h |
| Python × Go (doc: 4,0 h) | 4,1 h |
| Go × Nim | 4,0 h |
| **Go × Go** | **2,9 h** |

Leitura (estabs, o estágio que domina a extrapolação): trocar o **cliente**
Python pelo Go vale **+44%** no servidor Go e **+33%** no Nim; trocar o
**servidor** Nim pelo Go vale **+28%** com o cliente Python e **+39%** com o
Go. **O efeito do cliente é do mesmo tamanho (um pouco maior) que o do
servidor** — confirmação direta de que a metade "cliente" do wall medida acima
não é artefato do instrumento. Os dois ganhos se multiplicam:
6.111 → 11.236 rows/s = **+84%**, extrapolação 5,3 h → **2,9 h**.

### Ocupação de CPU — configuração real, tudo Go (`tests/bench_cpu_dist.py`)

O medidor amostra `/proc/<pid>/stat` (utime+stime) a cada 50 ms nos três
processos durante a carga real (mesmos parâmetros da matriz acima: **195.130
linhas** em cada rodada) e reporta CPU-s, % de 1 núcleo e a fatia do CPU total.

**1 cliente Go, 2 hops (query → transactor) — wall 9,69 s · 20.137 rows/s**

| processo | cpu-s | % de 1 núcleo | pico (janela 200 ms) | fatia |
|---|---:|---:|---:|---:|
| transactor | 10,23 | **105,6%** | 232% | 53,4% |
| query | 6,72 | **69,4%** | 167% | 35,1% |
| **cliente Go** | **2,22** | **22,9%** | 40% | 11,6% |
| TOTAL | 19,17 | ≈2,0 cores de 12 | | |

**Comparação das configurações** (mesmas 195.130 linhas, mesmos zips):

| configuração | wall | rows/s | transactor | query | cliente |
|---|---:|---:|---:|---:|---:|
| Python × Go (2 hops)¹ | 14,1 s | 13,8k | 64% | 41% | **46,5%** |
| Go × Go (2 hops) | 9,7 s | 20,1k | 106% | 69% | **23%** |
| Go × Go (2 hops), **2 clientes** | 8,3 s | 23,5k | 128% | 89% | 22% + 6% |
| Go × **transactor direto (1 hop)**² | 7,4 s | 26,2k | 141% | 68% | 28% |

¹ `bench_receita_hydrated.py`; a janela do medidor inclui o restart do stack e
os probes, daí o wall de 15,6 s contra os 14,1 s do load. Consistência: o
transactor gasta **o mesmo CPU-s nos dois casos** (9,99 vs 10,23) — o trabalho
dos servidores é função dos dados, o cliente só define a velocidade de
alimentação.
² `-sock eavt-transactor.sock`; o `Demo` final falha (`unknown request type:
datalog` — o transactor não serve `datalog`) depois de todo o load ter rodado.

**Quem é a restrição: não é o cliente Go e não é a máquina.**

- **Cliente Go: 22,9% de um núcleo** — 77% do tempo bloqueado no round-trip
  (`TxData` é `sendFrame → recvMap`, 1 batch em voo). Mesmo com 2 clientes,
  cada um fica em 22% e 6%.
- **Máquina: ≈2 cores de 12.**
- **É o lado servidor, no caminho serial de tx:**
  - o **transactor é o mais ocupado** (106% → **141%** quando se elimina o
    hop do query; picos de 232–266% vêm do flush/zstd nos workers);
  - o **hop do query server vale ~22% do tempo da carga** (9,69 → 7,44 s para
    as mesmas linhas); os 5,0 CPU-s do query no modo 1-hop são a aplicação da
    réplica (custo fixo, fora do caminho de requests);
  - **concorrência de cliente rende pouco**: 2 clientes → **+17%** agregado
    (20,1k → 23,5k rows/s) enquanto o transactor vai a 128% e o query a 89% —
    os servidores já estão perto do próprio teto serial.

Alavancas, em ordem: (1) tirar o hop do query do caminho de carga (ou abrir
conexões paralelas no transactor), (2) pipelining no cliente (hoje `TxData` é
bloqueante, igual ao harness Python), (3) só então o encode do cliente — que
já é irrelevante em Go (2 CPU-s) mas é **metade do wall no harness Python**.

### Veredito

- **No modo serial do harness o wall é ~metade round-trip / ~metade cliente
  Python**: Go 59,6% cliente · Nim 46,2% cliente. O cliente Python é
  primeira grandeza nas duas stacks — e já é o maior custo no Go.
- **Com pipelining a conclusão é unívoca**: `recv` cai a ~0,5% do wall e as
  duas stacks ficam limitadas pelo cliente (Go 92% / Nim 71% de um núcleo,
  taxa batendo no teto "servidor ideal" medido).
- **Dois efeitos independentes no serial**: (1) round-trip ocioso em 39–54%
  do wall (pipeline de 1 batch em voo); (2) custo por lote do cliente
  `read`+`build`+`to_wire`+`pack` = 46–60% do wall — com `to_wire` (passe
  recursivo com `isinstance` sobre cada op) sozinho em 25–34%.
- **A stack tem folga, mas não infinita**: no serial o transactor fica em
  ≤0,7 núcleo; com 2 clientes ele vai a 1,47 núcleo e o ganho cai para +27%
  — corrigido o cliente, o servidor volta a pesar.
- **Cliente Go medido (matriz 2×2 acima)**: trocar Python → Go no cliente vale
  **+44%** (servidor Go) / **+33%** (servidor Nim) em estabs — mesmo tamanho
  do efeito de trocar Nim → Go no servidor.

### Achado lateral: `--depth ≥ 16` trava (sem fluxo de controle de resposta)

Com `batch 500` e 16 batches em voo o pipeline **trava de vez** (Go; timeout de
5 min sem progresso). Evidências:

- dump de goroutines (`SIGQUIT`) do query server: `Gateway.serve →
  Conn.Request → downstream.WriteFrame` **[IO wait]** — o servidor está
  escrevendo a resposta no cliente e não lê mais os requests;
- cliente: `wchan = sock_alloc_send_pskb` (sendall bloqueado);
- `ss -x -m`: fila de saída do query server em 230.400 B, transactor ocioso
  (`memledger` parado);
- aritmética: resposta de tx de estabs = **22.447 B** ×16 em voo = 359 KB >
  208 KB (`rb212992`) do buffer default; `batch 100` (16 × 4,5 KB = 72 KB)
  com o mesmo `depth 16` **roda normalmente** (9.206 rows/s em estabs;
  rodada sintética — o mecanismo é função do tamanho do payload, não dos
  dados).

Ou seja: o `serve` escreve a resposta no mesmo goroutine que lê os requests —
se o cliente ainda está escrevendo e não lê, os dois buffers enchem e os dois
lados travam. Aumentar `SO_RCVBUF` para 8 MB no cliente **não** evitou o
travamento no teste (mesmo ponto de bloqueio no dump) — causa exata a fechar.
Até lá: `depth ≤ 8` (medido, estável).

### Próximos passos de perf (por ordem de retorno)

1. **Pipelining no harness** (`--depth 8`): +45–61% sem tocar o servidor.
2. **Mathe o `to_wire` recursivo**: codificar `Kw → ExtType(0x06)` na
   construção da op (1 passe) em vez de varrer a estrutura de novo — maior
   fase do cliente. Ou empacotar direto com `Packer` streaming.
3. **Adotar o cliente Go na carga** (`build/eavt-sql-load-go`, medido acima):
   **+44%** no servidor Go / **+33%** no Nim e extrapolação 4,1 h → **2,9 h**.
   O harness Python continua sendo o instrumento oficial de A/B.
4. **Fluxo de controle de resposta** (créditos) antes de suportar depth alto.

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
