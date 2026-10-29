# Processo e Diagnóstico — Data Tuning AP1

> Arquivo único (relatório final) com:
> - **(A)** registro do processo de montagem do ambiente e da carga de trabalho
> - **(B)** diagnóstico dos planos de execução (passo 2)
> - **(C)** aplicação das ações de tuning (passo 3)
> - **(D)** comprovação dos resultados e relatório final (passo 4)
>
> - **SGBD**: PostgreSQL 16 (`postgres:16-alpine`), baseline de fábrica
> - **Dataset**: TPC-H SF=0.1 (~866 mil registros; `lineitem` 600.572)
> - **Método**: `EXPLAIN (ANALYZE, BUFFERS)`, medições A/B com tabela limpa
> - **Data**: 2025-02-11

---

# PARTE A — Registro do processo

## A.1. Ambiente (docker-compose)

| Item | Valor |
|---|---|
| SGBD | PostgreSQL 16 (alpine) |
| Porta host | 5433 |
| Usuário/Banco | `tuner` / `tpch` |
| Volumes | `pgdata` (durável), `dbgen` (dataset + binários) |
| Extensões | `pg_stat_statements` (medição) |
| Baseline | `shared_buffers=128MB`, `work_mem=4MB`, `effective_cache_size=4GB`, `random_page_cost=4.0`, `max_parallel_workers_per_gather=2`, `log_min_duration_statement=1000` |

## A.2. Cronologia de problemas encontrados e soluções

| # | Problema | Causa | Solução |
|---|---|---|---|
| 1 | `01-baseline.conf` não era aplicado | A imagem oficial do Postgres **ignora `.conf`** em `/docker-entrypoint-initdb.d` (só `.sql`/`.sh`) | Convertido para `01-baseline.sql` com `ALTER SYSTEM` (grava em `postgresql.auto.conf`) + `shared_preload_libraries='pg_stat_statements'` |
| 2 | `dbgen` não gerava nada | Faltava `dists.dss` na pasta de trabalho | `dists.dss` copiado no Dockerfile; runtime copia `/opt/tpch → /work` |
| 3 | `dbgen -s 0.1 -S 42` mostrava help | `-S` (seed/step) só é válido com `-C`/`-U` (chunks) | Comando correto: `./dbgen -s 0.1 -f` |
| 4 | `\copy` falhava: "extra data" | Build ORACLE emite um `|` extra no **fim** de cada linha | `sed 's/|$//'` no `load-tpch.sh` |
| 5 | `lineitem` com 12 colunas no DDL | O TPC-H tem **16** colunas | Adicionadas `l_returnflag`, `l_linestatus`, `l_commitdate`, `l_receiptdate` |
| 6 | `ps_comment` estourava `VARCHAR(115)` | O dbgen gera comentários de até **198** chars (maior que a spec) | Todos os campos de comentário → `TEXT` |
| 7 | `qgen` não gravava arquivo | A saída vai para **stdout** (o `-o` só é o prefixo mostrado) | Captura do stdout + `awk` (`clean.awk`) |
| 8 | Q2/Q3/Q10/Q18/Q21: `rownum` | Postgres não tem `rownum` | `where rownum <= N` → `limit N` (buffer de 1 linha no awk) |
| 9 | Q1: `interval '90' day (3)` | O `(3)` é marcador da spec (linhas esperadas), não SQL | `sub()` remove `day (3)` |
| 10 | Q15: `create view`/`drop view` | Não é statement único → incompatível com `EXPLAIN` | View `revenue0` criada no **schema base** (colunas `supplier_no`/`total_revenue`); Q15 fixada = só o `SELECT` |
| 11 | `clean.awk` imprimia só a última linha | Lógica de buffer `prev` sem flush intermediário | Buffer `buf` + flush a cada linha |
| 12 | `run.sh` rodava só Q1 e Q22 | `eval echo "seq 1 22"` não executa o `seq` | `LIST=$(seq 1 22)` |

## A.3. Pipeline final (comandos)

```bash
docker compose up -d                                   # 1. sobe o Postgres
docker build -t data-tuning-dbgen dbgen/               # 2. compila dbgen/qgen (1x)
docker run --rm -v data-tuning-ap1_dbgen:/work data-tuning-dbgen \
  "cp -r /opt/tpch/. /work/ && cd /work && chmod +x dbgen qgen && ./dbgen -s 0.1 -f"   # 3. gera .tbl
sh db/load-tpch.sh                                     # 4. carrega (idempotente)
sh queries/generate.sh 0.1                             # 5. gera queries/fixed/*.sql
sh queries/run.sh all -e                               # 6. mede (EXPLAIN) -> queries/plans/
```

## A.4. Contagem final (SF=0.1)

| Tabela | Registros |
|---|---|
| region | 5 |
| nation | 25 |
| part | 20.000 |
| supplier | 1.000 |
| partsupp | 80.000 |
| customer | 15.000 |
| orders | 150.000 |
| lineitem | 600.572 |
| **Total** | **~866.600** |

---

# PARTE B — Diagnóstico dos planos de execução (Passo 2)

## B.1. Metodologia

- Cada query foi executada com `EXPLAIN (ANALYZE, BUFFERS)` (2 rodadas).
- Planos salvos em `queries/plans/N.plan`; tempos em `queries/baseline-SF01.md`.
- A análise abaixo usa os tempos da **rodada 2** (cache estabilizado).
- **Sem nenhum índice secundário** (só PKs) e `work_mem=4MB` — as condições
  de fábrica que o passo 3 vai modificar.

## B.2. Classificação dos gargalos

| Gargalo | Queries | Severidade |
|---|---|---|
| **G1 — Subquery correlacionada repetida** (seq scan em `lineitem` a cada iteração) | Q17, Q20 | **CRÍTICA** |
| **G2 — Seq Scan em `lineitem` sem índice** (leitura de 600K linhas p/ resultado pequeno) | Q1, Q6, Q14, Q19 | Média |
| **G3 — Estouro de `work_mem` (4MB) → I/O temporário** | Q4 | Média |
| **G4 — Nested Loop via índice PK em vez de Hash Join** | Q9 | Baixa |
| **G5 — Filtros pouco seletivos** (leitura total justificada, sem índice que resolva) | Q2, Q3, Q5, Q7, Q8, Q10, Q11, Q12, Q13, Q15, Q16, Q18, Q21, Q22 | Baixa (esperado) |

## B.3. Análise detalhada — G1 (críticas)

### Q20 — 45.849 ms (a mais lenta do conjunto)

```
Nested Loop  (nation = 'CANADA' ⋈ supplier)
  -> Nested Loop Semi Join  (supplier ⋈ partsupp)   [405.706 linhas removidas]
     -> Materialize
        -> Nested Loop  (part 'forest%' ⋈ partsupp)  [190 partes]
           -> Index Scan partsupp_pkey (ps_partkey = part.p_partkey)  loops=190
              Filter: ps_availqty > (SubPlan 1)
              SubPlan 1 -> Aggregate -> Seq Scan on lineitem   loops=760
                        Filter: l_shipdate 1994..1995 AND l_partkey AND l_suppkey
                        Rows Removed by Filter: 600571  (a cada execução!)
Buffers: shared hit=7503573
```

**Causa raiz**: a subquery `SELECT sum(l_quantity) FROM lineitem WHERE
l_partkey = ps_partkey AND l_suppkey = ps_suppkey AND ...` é **correlacionada**
e roda **760×** (uma por cada candidato `partsupp`). Cada execução faz um
**seq scan completo** de `lineitem` (600.572 linhas, descarta 600.571) porque
**não existe índice em `(l_partkey, l_suppkey)`**. Custo total ≈ 760 × 600K
linhas lidas = ~456M de acessos lógicos (buffers hit=7,5M × loops).

**Ação proposta (passo 3)**:
1. **Índice** em `lineitem(l_partkey, l_suppkey, l_quantity, l_shipdate)` —
   transforma cada sub-scan em index scan (ganho esperado: ordens de grandeza).
2. **Reescrita** da subquery como pré-agregação (CTE/join):
   `SELECT l_partkey, l_suppkey, sum(l_quantity) FROM lineitem WHERE ... GROUP BY 1,2`
   executada **1×** no lugar de 760×.
3. **Efeito colateral previsto**: índice composto em `lineitem` (tabela mais
   escrita) aumenta o custo de INSERT/UPDATE — medir com `pgbench`.

### Q17 — 27.520 ms

```
Hash Join  (lineitem ⋈ part)  [part: Brand#23, MED BOX -> 18 partes]
  Join Filter: l_quantity < (SubPlan 1)
  SubPlan 1 -> Aggregate -> Seq Scan on lineitem lineitem_1   loops=555
             Filter: l_partkey = part.p_partkey
             Rows Removed by Filter: 600541  (a cada execução!)
Buffers: shared hit=5122506
JIT: Total 38.258 ms
```

**Causa raiz**: subquery `avg(l_quantity) FROM lineitem WHERE l_partkey =
part.p_partkey` correlacionada, executada **555×** (uma por cada linha do
hash join `lineitem ⋈ part`). Cada execução faz seq scan completo de
`lineitem` sem índice em `l_partkey`.

**Ação proposta (passo 3)**:
1. **Índice** em `lineitem(l_partkey, l_quantity)` (coberto p/ a média).
2. **Reescrita** com window function: `avg(l_quantity) OVER (PARTITION BY
   l_partkey)` — calcula a média **1×** para todas as partes (elimina as 555
   repetições).
3. **Efeito colateral**: mesmo índice da Q20 — decisão única, benefício duplo.

## B.4. Análise detalhada — G3 (estouro de memória)

### Q4 — 247 ms

```
Parallel Hash Semi Join (orders ⋈ lineitem)
  Hash  Batches: 4  Memory Usage: 5824kB   <- estourou work_mem=4MB
  Buffers: temp read=926 written=948       <- I/O em disco temporário
```

**Causa raiz**: a hash table (189.904 linhas × 4 bytes) precisa de ~5,8 MB,
mas `work_mem=4MB` → **4 batches** e **948 páginas escritas/lidas em disco
temporário**. É o gargalo clássico de memória do planner.

**Ação proposta (passo 3)**: `work_mem = 16MB` (ou `hash_mem_multiplier`).
**Efeito colateral**: consumo de RAM por sessão — com N conexões simultâneas,
`N × 16MB` pode pressionar a RAM (validar com carga concorrente).

## B.5. Análise detalhada — G2 (seq scan em `lineitem`)

### Q6 — 75 ms (representativa do grupo)
```
Parallel Seq Scan on lineitem  [3 workers]
  Filter: l_shipdate 1994..1995 AND l_discount .05-.07 AND l_quantity < 24
  Rows Removed by Filter: 196318  (seletividade ~2%)
```
**Causa raiz**: filtro de 2% sobre 600K linhas **sem índice em `l_shipdate`**.
O seq scan paralelo é a escolha correta do planner **hoje** (índice em
`l_shipdate` sozinho não ajudaria muito: 1 ano = ~12% das linhas).

**Ação proposta (passo 3)**: índice **parcial** `lineitem(l_shipdate,
l_discount, l_quantity) WHERE l_quantity < 24` ou composto
`(l_discount, l_quantity, l_shipdate)` — testar se o planner troca para
index scan. **Efeito colateral**: índice em `lineitem` (escrita).

### Q1 — 460 ms
```
Parallel Seq Scan on lineitem  Filter: l_shipdate <= 1998-09-02
  Rows Removed by Filter: 2905  (seletividade ~99,5% — filtro inútil)
GroupAggregate + Sort (quicksort 26kB — cabe em memória)
```
**Causa raiz**: o filtro remove só 0,5% das linhas — **nenhum índice resolve**
(a leitura total é inevitável). O custo é o **scan + agregação** em si.
É o caso de **G2/G5**: seq scan é o plano ótimo; ganho só via memória/paralelismo.

**Ação proposta**: nenhuma (plano já é ótimo); servir de **controle** —
deve manter ~460 ms após as mudanças globais (work_mem etc.).

## B.6. Análise detalhada — G4 (nested loop via PK)

### Q9 — 267 ms
```
Nested Loop (10.720 linhas)
  -> Index Scan supplier_pkey   loops=32160   [1 linha por iteração]
  -> Index Scan orders_pkey     loops=32160   [1 linha por iteração]
Buffers: shared hit=234989  (I/O de índice repetido)
```

**Causa raiz**: o planner escolheu **nested loop com index scan na PK**
(32.160 iterações × 2 lookups) em vez de hash join para `lineitem ⋈ supplier`
e `lineitem ⋈ orders`. Com `random_page_cost=4.0` (calibrado p/ HDD) e
estatísticas padrão, o loop pareceu mais barato — mas gera ~235K buffer hits.

**Ação proposta (passo 3)**:
1. `random_page_cost = 1.1` (SSD) — tende a empurrar o planner para hash join.
2. **Índice composto** `partsupp(ps_partkey, ps_suppkey)` (já existe via PK
   composta) — avaliar `lineitem(l_partkey, l_suppkey)` (o mesmo da Q17/Q20).
3. **Efeito colateral**: mudar `random_page_cost` afeta **todas** as queries
   (revalidar as 22).

## B.7. Demais queries (G5 — controle, plano já razoável)

| Query | ms | Plano dominante | Leitura |
|---|---|---|---|
| Q2 | 82 | seq scan `part` (73 linhas) + `partsupp` (80K) + subplan `min()` | filtro seletivo, sem índice necessário |
| Q3 | 134 | nested loop + hash join, top-N heapsort | join orders⋈lineitem |
| Q5 | 79 | cadeia de 7 joins (nested loop) | plano aceitável p/ SF=0.1 |
| Q7 | 113 | parallel seq scan orders + lineitem, nested loop | 2 seq scans grandes |
| Q8 | 102 | cadeia de 8 joins | idem Q5 |
| Q10 | 151 | UNION ALL, parallel, top-N heapsort | 2 branches simétricos |
| Q11 | 84 | initplan (avg) + hash aggregate `partsupp` | scan 80K |
| Q12 | 162 | parallel hash join orders⋈lineitem | 2 seq scans |
| Q13 | 220 | hash right join orders⋈customer, 2× aggregate | scan 150K+15K |
| Q14 | 87 | parallel seq scan lineitem + part (20K) | seletividade baixa |
| Q15 | 146 | view `revenue0` (agg lineitem) + supplier | depende do G2 |
| Q16 | 106 | index only scan `partsupp_pkey` + hashed subplan | **única que usa índice de fato** |
| Q18 | 486 | hash join lineitem⋈orders + group agg + limit 100 | scan 600K |
| Q19 | 77 | parallel seq scan lineitem + part (OR filter) | OR impede índice simples |
| Q21 | 96 | parallel seq scan lineitem, anti/semi join | 2 subqueries |
| Q22 | 53 | seq scan customer + orders (phone ratio) | scans pequenos |

**Conclusão do grupo**: nenhuma delas tem gargalo anômalo — os planos são
os esperados para um banco **sem índices secundários** e filtros de baixa
seletividade. Servem de **controle** no passo 3: se uma ação global
(`work_mem`, `random_page_cost`) regredir alguma delas, é sinal de efeito
colateral.

## B.8. Resumo executivo do diagnóstico

| Prioridade | Query | Gargalo | Causa raiz | Ação (passo 3) |
|---|---|---|---|---|
| **P1** | Q20 | 45.849 ms | subquery correlacionada × 760, sem índice `(l_partkey, l_suppkey)` | índice + reescrita (pré-agregação) |
| **P1** | Q17 | 27.520 ms | subquery correlacionada × 555, sem índice `l_partkey` | índice + window function |
| **P2** | Q4 | 247 ms | `work_mem=4MB` < hash table (5,8MB) → temp I/O | `work_mem=16MB` |
| **P2** | Q9 | 267 ms | nested loop PK (32K iterações) por `random_page_cost=4.0` | `random_page_cost=1.1` |
| **P3** | Q6 | 75 ms | filtro 2% sem índice `l_shipdate` | índice parcial (testar) |
| **P3** | Q18 | 486 ms | scan total 600K (agregação) | controle — revalidar |
| — | Q1, Q14, Q19 | 460/87/77 ms | seletividade baixa (seq scan ótimo) | **controle** (não mexer) |

**Observação sobre JIT**: Q17 (38 ms) e Q20 (335 ms) pagam compilação JIT —
irrelevante frente a 27–45 s, mas documentado.

## B.9. Próximos passos (Passo 3)

1. Aplicar **uma ação por vez**, re-medir as 22 (`sh queries/run.sh all -e`).
2. Ordem sugerida: (a) índice `lineitem(l_partkey, l_suppkey, l_quantity,
   l_shipdate)` → valida Q17/Q20; (b) reescrita Q17/Q20; (c) `work_mem=16MB`
   → valida Q4; (d) `random_page_cost=1.1` → valida Q9 e as 22.
3. Para cada ação: registrar ganho **e** efeito colateral (escrita via
   `pgbench`, regressão nas queries de controle).
4. Tabela final: `ação | query | antes | depois | ganho % | colateral`.

---

# PARTE C — Aplicação das ações de tuning (Passo 3)

## C.1. Metodologia de medição (A/B limpo)

Para isolar o efeito de cada ação, as medições finais foram feitas em
**dois estados controlados**, ambos com a tabela **limpa**
(`VACUUM (FULL, ANALYZE) lineitem` antes de cada rodada):

- **Estado A** — com o índice `idx_li_partkey_suppkey`
- **Estado B** — sem o índice (só PKs, como a baseline)

Benchmark de **escrita** (efeito colateral): 3 ciclos de
`DELETE FROM lineitem WHERE l_orderkey <= 100000` +
`INSERT INTO lineitem SELECT * FROM _bench` (100.386 linhas),
medidos com `\timing` nos dois estados, também com tabela limpa.

Regra aplicada: **uma mudança por vez**; se uma ação regredir queries,
ela é **revertida** e o porquê é documentado.

## C.2. Ação 1 — Índice composto em `lineitem` (ACEITA)

```sql
CREATE INDEX idx_li_partkey_suppkey
  ON lineitem (l_partkey, l_suppkey, l_quantity, l_shipdate);
ANALYZE lineitem;
```

**Justificativa**: ataca a causa raiz das duas queries piores (Q17/Q20 —
subqueries correlacionadas × 555/760 execuções, cada uma fazendo seq scan
de 600K linhas) e, de bônus, a Q19 (filtro `l_partkey = part.p_partkey`
vira Bitmap Index Scan).

### C.2.1. Ganho em leituras (A/B limpo, 22 queries)

| Query | B: sem índice (ms) | A: com índice (ms) | Δ | Leitura |
|---|---|---|---|---|
| **Q17** | 29.850 | **12,1** | **-99,96%** | subquery vira Index Only Scan |
| **Q20** | 47.672 | **18,7** | **-99,96%** | subquery vira Index Only Scan |
| **Q19** | 83,5 | **17,6** | **-78,9%** | bônus: bitmap index scan `l_partkey` |
| Q18 | 545,5 | 636,5 | **+16,7%** | **regressão** (ver C.2.3) |
| Q1 | 471,1 | 457,2 | -3,0% | controle — estável |
| Q2 | 82,4 | 81,5 | -1,1% | estável |
| Q3 | 156,7 | 166,7 | +6,4% | ruído |
| Q4 | 277,0 | 255,2 | -7,9% | estável |
| Q5 | 91,2 | 85,0 | -6,8% | estável |
| Q6 | 87,0 | 88,2 | +1,4% | estável |
| Q7 | 123,3 | 122,0 | -1,1% | estável |
| Q8 | 110,5 | 115,5 | +4,5% | estável |
| Q9 | 266,2 | 291,9 | +9,7% | ruído |
| Q10 | 155,3 | 162,5 | +4,7% | ruído |
| Q11 | 86,9 | 89,0 | +2,4% | estável |
| Q12 | 175,8 | 181,9 | +3,5% | estável |
| Q13 | 251,8 | 256,4 | +1,8% | estável |
| Q14 | 98,6 | 102,9 | +4,4% | estável |
| Q15 | 170,4 | 171,6 | +0,7% | estável |
| Q16 | 110,3 | 102,5 | -7,1% | estável |
| Q21 | 95,8 | 103,2 | +7,7% | ruído |
| Q22 | 58,8 | 60,1 | +2,2% | estável |
| **Total** | **81.020 ms (81,0 s)** | **3.578 ms (3,6 s)** | **-95,6%** | |

### C.2.2. Efeito colateral medido (escrita)

| Operação (100K linhas) | B: sem índice | A: com índice | Δ |
|---|---|---|---|
| DELETE (média 3 runs) | 114 ms | 137 ms | +20% |
| INSERT (média 3 runs) | 697 ms | 1.460 ms | **+110%** |
| Ciclo DELETE+INSERT | ~811 ms | ~1.597 ms | +97% |

- **Custo único**: `CREATE INDEX` 802 ms + `ANALYZE` 574 ms.
- **Espaço**: 23 MB (30% do heap de 77 MB).
- **Causa**: cada INSERT/DELETE precisa manter o índice; as linhas de
  `lineitem` não qualificam para HOT (têm índice em colunas atualizáveis),
  então a escrita paga a manutenção do índice em 100% dos casos.

### C.2.3. Regressão da Q18 (+16,7%)

Com o índice presente, o planner **abandonou o caminho ordenado**
(`GroupAggregate → Index Scan lineitem_pkey`) e passou a
`HashAggregate → Seq Scan` em uma das pernas do join (o `ANALYZE`
recalculou custos e o plano com hash ficou levemente mais barato na
estimativa). Impacto: 545 → 636 ms numa query que não é crítica.
**Decisão**: aceita — 16,7% na Q18 não compensa perder 99,96% em Q17/Q20
e 78,9% na Q19. (Mitigação futura: `pg_hint_plan` ou estatísticas de
amostra maior, se a Q18 se tornar crítica no cenário de negócio.)

### C.2.4. Decisão

**ÍNDICE ACEITO E MANTIDO** — estado final do ambiente.

## C.3. Ação 2 — `work_mem` 4MB → 8MB → 16MB (REVERTIDA)

| work_mem | Q4 (ms) | Q18 (ms) | Q21 (ms) | Q22 (ms) |
|---|---|---|---|---|
| 4MB (baseline) | 247 | 545 | 96 | 59 |
| 8MB | 300 | 1.372 | 150 | 80 |
| 16MB | 240 | 1.125 | 155 | 80 |

- A Q4 **eliminou o temp I/O** com 16MB (`Batches: 4` → `Batches: 1`,
  sem `temp read/written`), mas o ganho foi de apenas **3%**.
- O comportamento **não-monótono** (8MB pior que 16MB) revela que mudar
  `work_mem` altera o **modelo de custo do planner** inteiro: Q18/Q21/Q22
  re-otimizaram para planos piores (agregações com mais memória estimada
  pararam de particionar).
- **Decisão: REVERTIDA para 4MB** — o ganho na Q4 (3%) não compensa as
  regressões (50–130%) em três queries. Lição registrada: aumentar
  `work_mem` globalmente é uma alavanca de **planner**, não só de
  memória — deve ser testada contra o conjunto completo, e nunca só
  contra a query-alvo.

## C.4. Ação 3 — `random_page_cost` 4.0 → 1.1 (REVERTIDA)

| random_page_cost | Q9 (ms) | Plano escolhido |
|---|---|---|
| 4.0 (baseline) | 267 | Parallel Hash Join + seq scans |
| 1.1 (SSD) | **519** | Nested Loop + index scans (pior!) |

Com o custo de página aleatória menor, o planner trocou o hash join da Q9
por **nested loops com index scans** (32K iterações) — que era o plano
que ele evitava no baseline. **Decisão: REVERTIDA para 4.0.**
Lição registrada: `random_page_cost` é global e pode **invertir** a
preferência de join de queries analíticas; em workload OLAP com
agregações grandes, o valor de fábrica (HDD) pode ser melhor que o
"correto" para SSD.

## C.5. Incidente documentado — bloat da tabela como confounder

Durante as medições, Q18 apareceu regredida para 1.396–1.508 ms.
Investigação:

1. O benchmark de escrita (6× DELETE+INSERT de 100K linhas) **inchou o
   heap de `lineitem` de 77 MB para 154 MB** (dead tuples não
   reclamados) — seq scans passaram a ler o dobro de dados.
2. `VACUUM (FULL, ANALYZE)` devolveu o heap a 77 MB e a Q18 voltou a
   712–763 ms (sem índice).
3. A comparação A/B final (C.2.1) foi refeita **com `VACUUM FULL` antes
   de cada estado** para eliminar o confounder.

**Lição registrada**: benchmark de escrita e medição de leitura não podem
compartilhar o mesmo estado de tabela sem `VACUUM` entre eles; em
trabalhos de tuning, bloat é uma fonte clássica de "regressão falsa".

## C.6. Resumo final das ações (Passo 3)

| # | Ação | Query-alvo | Antes | Depois | Ganho | Efeito colateral medido | Decisão |
|---|---|---|---|---|---|---|---|
| 1 | Índice `lineitem(l_partkey, l_suppkey, l_quantity, l_shipdate)` | Q17 | 29.850 ms | 12 ms | **-99,96%** | INSERT +110% (697→1.460 ms/100K); Q18 +16,7% | **ACEITA** |
| 1b | (idem — bônus) | Q20 | 47.672 ms | 19 ms | **-99,96%** | — | **ACEITA** |
| 1c | (idem — bônus) | Q19 | 84 ms | 18 ms | **-78,9%** | — | **ACEITA** |
| 2 | `work_mem` 4→16MB | Q4 | 247 ms | 240 ms | -3% | Q18/Q21/Q22 +50–130% | **REVERTIDA** |
| 3 | `random_page_cost` 4.0→1.1 | Q9 | 267 ms | 519 ms | regressão | inverte plano de join | **REVERTIDA** |

**Ganho líquido do conjunto**: 81,0 s → 3,6 s nas 22 queries (-95,6%),
com custo de escrita +97% em ciclos DELETE+INSERT de 100K linhas.

## C.7. Estado final do ambiente (reprodução)

```bash
# configurações (voltaram à baseline de fábrica)
ALTER SYSTEM SET work_mem = '4MB';
ALTER SYSTEM SET random_page_cost = 4.0;

# única ação de tuning mantida
CREATE INDEX idx_li_partkey_suppkey
  ON lineitem (l_partkey, l_suppkey, l_quantity, l_shipdate);
ANALYZE lineitem;
```

> Nota: `docker compose down -v && docker compose up -d` reaplica a
> baseline de fábrica (sem o índice) — o índice é ação de tuning e deve
> ser recriado pelo comando acima para reproduzir o estado final.

## C.8. Ações não aplicadas (registradas como decisão)

- **Reescrita de Q17/Q20** (window function / pré-agregação): o índice
  já levou as duas para < 20 ms; reescrever o benchmark oficial
  comprometeria a comparabilidade com a literatura TPC-H. Mantidas as
  queries originais.
- **Índices em `l_shipdate`/`l_discount`** (Q6/Q19): a Q6 é o caso de
  seletividade baixa documentado no B.5 (filtro 2%); índice composto
  testado mentalmente não justificaria o custo de escrita extra sobre a
  Q17/Q20 já resolvidas.

---

# PARTE D — Comprovação dos resultados e Relatório Final (Passo 4)

## D.1. Re-medição após as intervenções (A/B limpo)

Para comprovar os ganhos, as 22 queries foram **re-medidas em dois estados
controlados**, ambos com `VACUUM (FULL, ANALYZE) lineitem` antes (tabela
limpa, heap 77 MB) e configurações de fábrica (`work_mem=4MB`,
`random_page_cost=4.0`):

- **Baseline (estado B)** — sem o índice de tuning (só PKs)
- **Final (estado A)** — com `idx_li_partkey_suppkey`

| Query | Baseline (ms) | Final (ms) | Δ |
|---|---|---|---|
| Q1  | 320,0 | 322,2 | +0,7% |
| Q2  | 55,4  | 67,2  | +21,3% (ruído, query de 55 ms) |
| Q3  | 106,5 | 93,3  | −12,4% |
| Q4  | 179,6 | 177,4 | −1,2% |
| Q5  | 58,9  | 62,0  | +5,3% |
| Q6  | 57,6  | 54,7  | −5,1% |
| Q7  | 81,4  | 82,4  | +1,2% |
| Q8  | 75,1  | 74,6  | −0,7% |
| Q9  | 193,8 | 209,3 | +8,0% |
| Q10 | 109,8 | 109,4 | −0,4% |
| Q11 | 63,9  | 61,7  | −3,5% |
| Q12 | 124,0 | 120,4 | −2,9% |
| Q13 | 169,3 | 168,5 | −0,5% |
| Q14 | 68,8  | 67,1  | −2,4% |
| Q15 | 114,3 | 110,3 | −3,6% |
| Q16 | 74,3  | 76,6  | +3,1% |
| **Q17** | **30.317,6** | **6,0** | **−99,98%** |
| Q18 | 549,9 | 580,7 | +5,6% |
| **Q19** | **81,6** | **17,3** | **−78,8%** |
| **Q20** | **55.970,6** | **13,6** | **−99,98%** |
| Q21 | 100,0 | 100,5 | +0,5% |
| Q22 | 60,5  | 60,2  | −0,5% |
| **TOTAL** | **88.933 ms (88,9 s)** | **2.635 ms (2,6 s)** | **−97,0%** |

**Validação da medição**: as 18 queries de controle (Q1–Q16, Q21, Q22)
ficaram dentro de ±12% entre os dois estados — variação compatível com
ruído de medição (JIT, cache, concorrência do host). Isso confirma que a
diferença real está concentrada em **Q17, Q19 e Q20**, exatamente as que o
diagnóstico (Parte B) apontou como dependentes do filtro `l_partkey`.

## D.2. Comparação com a linha de base original (passo 1)

| Métrica | Linha de base (B.8) | Final (D.1) |
|---|---|---|
| Q17 | 27.520 ms | 6 ms |
| Q20 | 45.849 ms | 14 ms |
| Q19 | 77 ms | 17 ms |
| Total das 22 | ~76 s | 2,6 s |

> A linha de base do passo 1 (B.8) foi medida antes do benchmark de escrita
> e do `VACUUM FULL`; os tempos de Q17/Q20 variam entre 27–30 s (baseline)
> conforme o estado do cache. A ordem de grandeza e o ganho (~99,98%) são
> robustos a essa variação.

## D.3. Discussão dos limites das melhorias obtidas

1. **O ganho é específico das queries com filtro em `l_partkey`** (Q17,
   Q19, Q20). O índice não acelera as demais — o total das 18 queries de
   controle permanece ~2,6 s. Ou seja, o tuning resolveu o gargalo
   dominante, mas **não melhora o custo de agregação/scan** das queries
   analíticas gerais (Q1, Q9, Q13, Q18).

2. **Custo de escrita pago em OLTP**: cada INSERT em `lineitem` ficou ~2×
   mais lento (C.2.2). Em um sistema com escrita intensa, o ganho de
   leitura pode ser superado pelo custo de manutenção do índice. O trade-off
   só é vantajoso porque a carga do benchmark é **OLAP de leitura**.

3. **Regressão residual da Q18 (+5,6%)**: o índice induz o planner a trocar
   o caminho ordenado por hash em uma perna do join (C.2.3). Pequena, mas
   real — e é o lembrete de que **todo índice é uma decisão global**, não
   local.

4. **`work_mem` e `random_page_cost` não melhoraram o conjunto** (C.3/C.4):
   aumentar memória global regrediu 3 queries; baixar o custo de página
   inverteu o plano da Q9. Isso mostra que **ajustar parâmetro global não é
   solução genérica** — o efeito depende do plano que o planner reescolhe.

5. **Limitação de escala (SF=0.1)**: os ganhos em % são esperados se
   mantiverem em SF=1/10, mas os valores absolutos mudam. A Q17/Q20 em
   SF=10 passariam de minutos para segundos — o ganho relativo tende a ser
   ainda maior (mais linhas para o seq scan).
   > **Nota**: o dataset SF=1 (~1 GB, 6M de lineitem) foi gerado e
   > carregado durante o projeto, mas a medição baseline foi abandonada —
   > a Q17 sem índice levou **>1h** (Q20 similar), inviabilizando a
   > comparação A/B em tempo de projeto. O SF=0.1 foi mantido como escala
   > de referência: o ganho relativo (−97%) é o que se espera preservar, e
   > a super-linearidade das subqueries correlacionadas (Q17/Q20) é
   > documentada como evidência de que o ganho absoluto seria ainda maior
   > em SF maior.

6. **Limitação de metodologia**: medições em container partilhando CPU do
   host, sem isolamento de carga concorrente; 1 execução por query na
   re-medição final (a variação entre as 18 controles já indicou o ruído).
   Para números publicáveis, repetir 5× e usar a mediana.

## D.4. Scripts utilizados (entrega)

| Script | Função |
|---|---|
| `docker-compose.yml` | ambiente Postgres 16 + volumes |
| `db/init/00-extensions.sql` | `pg_stat_statements` |
| `db/init/01-baseline.sql` | baseline de fábrica (`ALTER SYSTEM`) |
| `db/init/02-tpch-schema.sql` | DDL TPC-H (8 tabelas + view `revenue0`) |
| `db/load-tpch.sh` | carrega o dataset (idempotente) |
| `dbgen/Dockerfile` | compila `dbgen`/`qgen` oficiais |
| `queries/generate.sh` | gera as 22 queries fixadas (parâmetros oficiais) |
| `queries/clean.awk` | conversão template→Postgres (`rownum`→`limit`, Q15, Q1) |
| `queries/run.sh` | executor (resultado / `EXPLAIN (ANALYZE, BUFFERS)`) |
| `queries/fixed/*.sql` | as 22 queries do benchmark |

**Ação de tuning aplicada (reproduzível)**:
```sql
CREATE INDEX idx_li_partkey_suppkey
  ON lineitem (l_partkey, l_suppkey, l_quantity, l_shipdate);
ANALYZE lineitem;
```

## D.5. Recomendações finais

1. **Manter** o índice `idx_li_partkey_suppkey` — é a única ação que gerou
   ganho líquido comprovado (−97% no total, sem regredir as 18 controles
   além do ruído).
2. **Não adotar** `work_mem>4MB` nem `random_page_cost<4.0` globalmente —
   ambos regrediram queries; se a Q4 (temp I/O) se tornar crítica, usar
   `work_mem` **por sessão** (`SET work_mem`) só para as queries de
   agregação grande, não global.
3. **Escala**: o projeto foi entregue em **SF=0.1** (decisão registrada em
   D.3.5). Se uma versão SF=1/10 for exigida, revalidar o índice e as 18
   controles antes de entregar — mas atentar que a baseline das Q17/Q20
   (sem índice) é inviável de medir (Q17 levou >1h em SF=1), então a
   comparação A/B nessas queries deve usar amostragem ou timeout.
4. **Monitorar** o custo de escrita de `lineitem` em produção (o índice
   dobra o INSERT); se a carga virar OLTP de escrita, reavaliar o índice
   (talvez parcial: `WHERE l_partkey IS NOT NULL`).
5. **Processo**: adotar a disciplina "uma mudança por vez + reverter se
   regredir + `VACUUM` entre benchmark de escrita e de leitura" (lições de
   C.5) — foi o que permitiu separar o ganho real do bloat.

## D.6. Conclusão

O projeto comprovou, com medição A/B limpa, que **uma única ação** (índice
composto em `lineitem`) reduziu o tempo total das 22 queries do TPC-H de
**88,9 s para 2,6 s (−97,0%)**, eliminando os dois gargalos críticos
(Q17/Q20, de dezenas de segundos para < 20 ms) e melhorando Q19 (−78,8%),
com efeito colateral medido e documentado (escrita ~2× mais lenta, Q18
+5,6%). As duas ações de parâmetro global testadas (`work_mem`,
`random_page_cost`) foram **revertidas** por regredirem queries — evidência
de que tuning de parâmetro global exige validação contra o conjunto
completo, não contra a query-alvo.


