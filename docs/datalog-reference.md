# Datalog EDN — Referência da Linguagem de Consulta

## Status

Implementado (fase B, passo 2). Esta é a superfície de consulta Datomic-style
do eavt-sql — substitui o SQL customizado. O protocolo de escrita EDN
(`docs/tx-protocol.md`) cobre as escritas; este documento cobre as consultas.

A gramática completa está em `nim_datalog/query_edn.nim` (header). O parser
produz `DatalogIR` diretamente — sem AST SQL intermediário — e o pipeline
resolve → plan → compile é o mesmo do SQL.

---

## 1. Sintaxe geral

```edn
[:find   ?var1 ?var2 ...
 (:in    $ ?param1 ?param2 ...)?
 :where  clause+
 (:history)?]
```

Um query Datalog é um vetor EDN com seções prefixadas por keyword:

| Seção | Obrigatória | Conteúdo |
|-------|-------------|----------|
| `:find` | sim | vars de projeção `?name` — a ordem define as colunas |
| `:in` | não | `$` (input db) seguido de vars paramétricos `?x` |
| `:where` | sim | clauses (patterns, predicates, or) |
| `:history` | não | sem valor; inclui datoms retracted no scan |

---

## 2. Patterns (clauses de dados)

```edn
[?e :person/name ?name]     e var, attr keyword, v var
[?e :person/name "Alice"]   v constante string
[?e :fin/price 10]          v constante int
[_ :person/name ?v]         e blank — var anônima
[101 :person/name ?v]       e constante eid
```

| Slot | Formas aceitas | Semântica |
|------|---------------|-----------|
| `e` | `?var`, `_`, eid literal | var → join com outros patterns; `_` → var anônima; int → eid fixo |
| `attr` | `:ns/name` (obrigatório) | keyword com namespace. Aceita dot (`:dl.name`) ou slash (`:dl/name`) — normaliza para slash canônico (`dl/name`) no storage. Wildcard `_` **não suportado** no v1 |
| `v` | `?var`, `_`, constante | var → bind ou join; `_` → var anônima; constante → filtro exato |

**Var names**: `?name` → o IR armazena `name` (sem prefixo `?`). Vars compartilhadas
entre patterns fazem join automaticamente (o planner unifica pelos nomes).

**Tipos de valor**: string (`"..."`), int, float, bool (`true`/`false`),
keyword (`:status/active` → valor string `:status/active`). Bytes e blob
**não suportados** no v1 (o IR os aceita mas o parser não os emite).

**REJTED datoms**: por padrão só datoms ativos são visíveis. Com `:history`
o scan inclui versões retracted (mesma semântica do `SELECT HISTORY` SQL).

---

## 3. Predicates (clauses de filtro)

```edn
[(> ?p 5)]                    faixa aberta
[(<= ?p 100)]                 faixa fechada
[(!= ?v "x")]                 exclusão
[(:!= ?v "x")]                forma alternativa (keyword op)
[(= ?v 10)]                   igualdade exata (mesmo que pattern com v constante)
[(> ?p ?lim)]                 com param do :in
```

| Operador | Significado |
|----------|-------------|
| `:>` / `>` | maior |
| `:<` / `<` | menor |
| `:>=` / `>=` | maior ou igual |
| `:<=` / `<=` | menor ou igual |
| `:=` / `=` | igual (filtro; **não** join entre vars no v1) |
| `:!=` / `!=` | diferente |

O op aceita keyword (`:>`) ou symbol (`>`). O **var** deve estar bound por
um pattern value slot — um predicate sobre var não-bound levanta
`DatalogSyntaxError`.

**Valores do lado direito**: constante, ou `?param` (var do `:in`).
**Não suportado**: aritmética (`(+ 1 2)`), comparação entre duas vars
(`[(= ?a ?b)]` — use o mesmo var nos patterns), regex, full-text.

---

## 4. OR (disjunção de faixas)

```edn
[(or [(> ?p 5)] [(< ?p 0)])]
```

Branches sobre o **mesmo var** — o IR mapeia para `rangeBounds` branches
(a mesma estrutura do SQL `OR`). Cada branch é uma disjunção independente;
múltiplos predicates sem `or` no mesmo var são AND.

**Não suportado no v1**: `or` sobre patterns diferentes (isso exigiria
union no planner), `or` entre vars diferentes, `not`.

---

## 5. Params (`:in`)

```edn
[:find ?name
 :in $ ?email
 :where [?e :person/email ?email]
        [?e :person/name ?name]]
```

- `$` marca o input db — sempre ignorado (a réplica é implícita).
- Os vars após `$` ligam-se **posicionalmente** aos args da chamada:
  o primeiro arg → param 1, o segundo → param 2, etc.
- Pattern slots que referenciam um var do `:in` viram **constantes paramétricas**
  (`dsConst(bvParam)` no IR) — resolvidos em runtime via `[:param N]`.
- Predicates sobre vars do `:in` — o valor do range é `bvParam` também.

---

## 6. Projeção (`:find`)

A ordem dos vars em `:find` define as colunas do resultado. A resposta
inclui `columns` com os nomes (sem o prefixo `?`):

```json
{"columns": ["name"], "rows": [["widget"]], "more": false}
```

**`SELECT *`** (star) não tem equivalente — Datalog sempre projeta vars
explícitas. Para "todas as propriedades de uma entidade" use o wildcard
`d1.attr`/`d1.val` do SQL (ainda disponível) ou declare as attrs.

---

## 7. EXPLAIN

```python
c.request({"type": "datalog", "query": "...", "explain": True})
```

Retorna o plano (join order, index choice, custos) + o programa EDN
compilado — o mesmo formato do EXPLAIN SQL. O programa é EDN:
`[:begin [:set! ?s0 [:scanner-open "AEVT"]] ...]`.

---

## 8. Protocolo

Request: `{"type": "datalog", "query": "[:find ...]", "params": [...], "explain": bool}`
Response: mesmo formato de streaming do SQL (`{"columns": [...], "rows": [...], "more": bool}`).
Erros: `{"error": "datalog: ...", "more": false}`.

A compilação usa o mesmo stale-schema retry do SQL (2 tentativas, snapshot
TTL 30s na réplica). A execução é **na réplica** — consistência eventual
por desenho (§2 de tx-protocol.md).

---

## 9. Escritas — EDN tx (resumo do protocolo)

Ver `docs/tx-protocol.md` para a spec completa. Resumo da cobertura:

| Op | Sintaxe | Suportado |
|----|---------|-----------|
| add | `[:db/add e :attr v]` | ✓ — e: eid, tempid, lookup ref, `:db/current-tx` |
| retract | `[:db/retract e :attr v]` | ✓ — e: eid ou lookup ref |
| schema | `[:db/add eid :db/ident :ns/name]` + valueType/cardinality/unique | ✓ — agrupados → `eavtDeclareAttr` |
| tempid | int64 negativo (ex. `-1`) | ✓ — upsert por `:db.unique/identity` ou alocação |
| lookup ref | `[:ns/attr valor]` | ✓ — resolvido in-tx; miss = erro |
| chaining | `[:db/add -1 :ref -2]` | ✓ — tempid referencia outro tempid da mesma tx |
| idempotência | re-add de datom existente = no-op | ✓ — both cardinalities |
| `:db/current-tx` | metadados da tx | ✓ — `[:db/add :db/current-tx :audit/user "x"]` |
| schema rollback | schema datoms não fazem rollback se data op falhar | ⚠ documentado (§7) |
| `:db/retractEntity` | cascatas VAET | ✗ — fase futura |
| `:db.fn` / tx functions | | ✗ — fase futura |
| `:db.tempid/:db.part/tx` | tempid na partição tx | ✗ — use `:db/current-tx` |

---

## 10. Cobertura Datalog vs SQL — comparativo

| Feature | SQL | Datalog EDN |
|---------|-----|-------------|
| Projeção de attrs | `SELECT d1.ns.attr` | `[:find ?v]` + pattern |
| Projeção de eid | `SELECT d1.eid` | `[:find ?e]` + pattern e slot |
| Projeção de tx | `SELECT d1.tx` | ✗ — fase futura |
| Wildcard attr/val | `d1.attr`, `d1.val` | ✗ — v1 requer attr keyword |
| Star (`SELECT *`) | ✓ | ✗ |
| Equality filter | `WHERE attr = v` | pattern v constante, ou `[(= ?v val)]` |
| Range filter | `>`, `<`, `>=`, `<=`, `!=` | ✓ mesmos ops |
| IN | `IN (v1, v2)` | ✗ — use múltiplos predicates (ou `or`) |
| OR | `WHERE a OR b` | ✓ sobre ranges do mesmo var (`(or ...)`) |
| NOT | `WHERE NOT cond` | ✗ — fase futura |
| EXISTS | `SELECT 1 WHERE ...` | ✗ — fase futura |
| HISTORY | `SELECT HISTORY` | ✓ `:history` |
| JOIN | `d1.x = d2.y` | ✓ vars compartilhados entre patterns |
| Params | `%1`, `%2` | ✓ `:in $ ?x` (posicional) |
| EXPLAIN | ✓ | ✓ (`"explain": true`) |
| Aggregates | ✗ | ✗ |
| Pull | ✗ | ✗ |
| Rules | ✗ | ✗ |
| Reflexão (eid()) | `eid('ns.attr', 'val')` | ✗ — use lookup ref na escrita |

---

## 11. Exemplos

```edn
;; Lookup simples
[:find ?name :where [?e :person/name ?name]]

;; Com filtro de valor
[:find ?name
 :where [?e :fin/price ?p]
        [(> ?p 5)]
        [?e :fin/name ?name]]

;; Com param
[:find ?name
 :in $ ?email
 :where [?e :person/email ?email]
        [?e :person/name ?name]]

;; OR de faixas
[:find ?name
 :where [?e :fin/price ?p]
        [(or [(> ?p 100)] [(< ?p 0)])]
        [?e :fin/name ?name]]

;; Join entre patterns
[:find ?pname :where [?e :person/employer ?emp]
                     [?emp :company/name ?cname]
                     [?emp :person/name ?pname]]

;; Eid constante
[:find ?name :where [101 :person/name ?name]]

;; History (inclui retracted)
[:find ?name ?v :where [?e :person/name ?name] :history]
```

---

## 12. Erros

| Erro | Quando |
|------|--------|
| `datalog: pattern must be a 3-element vector` | pattern com ≠ 3 elementos |
| `datalog: attr keyword must be namespaced` | attr sem `/` ou `.` |
| `datalog: unsupported value` | valor de tipo não reconhecido |
| `datalog: predicate var must be ?var` | op sem var no meio |
| `datalog: unsupported predicate op` | op fora da lista |
| `datalog: predicate var ?x is not bound` | predicate sobre var não-pattern |
| `datalog: :find is required` | query sem :find |
| `datalog: :where with at least one pattern` | query sem patterns |
| `datalog: unknown query section` | keyword não reconhecida |
| `attribute resolution failed` | attr não declarada no schema |
| `datalog: EDN parse error` | EDN malformado |

---

## 13. Related documents

- `docs/tx-protocol.md` — protocolo de transação EDN (escritas)
- `docs/scheme-transport.md` — framing msgpack, encoding EDN-like (§3.3)
- `docs/sql-reference.md` — superfície SQL legacy (remoção na fase C)
- `AGENTS.md` — storage key encoding, threading model
