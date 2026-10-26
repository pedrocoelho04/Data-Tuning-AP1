# Especificações do SGBD — Passo 1 (Caracterização do ambiente)

> Documento de referência do projeto de Data Tuning (AP1).
> **Qualquer mudança neste documento a partir daqui é uma 
> ação de tuning** e deve ser registrada com baseline → novo
> valor + justificativa (passo 3).

## 1. SGBD

| Item | Especificação |
|---|---|
| Produto | PostgreSQL |
| Versão | 16 (imagem `postgres:16-alpine` do Docker Hub) |
| Engine de armazenamento | Heap (MVCC) + índices B-tree |
| Modo de execução | Container Docker (compose), rede bridge |
| Porta no host | **5433** (mapeada para 5432 do container — evita conflito com Postgres local) |
| Banco de dados | `tpch` |
| Usuário | `tuner` (superuser do container) |

## 2. Recurso computacional (container)

| Recurso | Alocação |
|---|---|
| CPU | compartilhada com o host (limite não imposto) |
| Memória | sem limite por cgroup — os parâmetros de memória abaixo são o controle efetivo |
| Shared memory (`shm_size`) | 512 MB (necessário para `shared_buffers` até ~256 MB) |
| Disco | volume Docker `pgdata` (durável, sobrevive a `down` sem `-v`) |

> **Registro a completar no seu ambiente**: preencher com as specs reais da
> máquina (modelo, CPU, RAM total, disco SSD/HDD, SO) antes de entregar.
> A linha de base só é válida se o hardware estiver documentado.

## 3. Modelo de dados

**TPC-H** (benchmark analítico/OLAP clássico do Transaction Processing
Performance Council) — 8 tabelas + 1 view:

| Tabela | Registros (SF=0.1) | Registros (SF=1) | PK | Papel no benchmark |
|---|---|---|---|---|
| `region` | 0,5 | 5 | `r_regionkey` | regiões do mundo |
| `nation` | 2,5 | 25 | `n_nationkey` | nações (FK→region) |
| `part` | 20.000 | 200.000 | `p_partkey` | catálogo de peças |
| `supplier` | 1.000 | 10.000 | `s_suppkey` | fornecedores (FK→nation) |
| `partsupp` | 80.000 | 800.000 | `(ps_partkey, ps_suppkey)` | estoque por fornecedor |
| `customer` | 15.000 | 150.000 | `c_custkey` | clientes (FK→nation) |
| `orders` | 150.000 | 1.500.000 | `o_orderkey` | pedidos (FK→customer) |
| `lineitem` | ~600.000 | ~6.000.000 | `(l_orderkey, l_linenumber)` | itens dos pedidos (tabela quente) |
| **Total** | **~834.000** | **~8.340.000** | | |

Decisões de projeto do DDL (`db/init/02-tpch-schema.sql`):
- **Somente PRIMARY KEYs** — nenhum índice secundário na baseline.
  Consequência registrada: as queries analíticas fazem seq scans e sorts
  em disco. Isso é **intencional** e cria as oportunidades de tuning
  dos passos 2 e 3.
- **FKs não declaradas** — o gerador `dbgen` garante consistência
  referencial; omitir FKs acelera o load em milhões de linhas.
- **View `revenue0`** — pré-agregação usada pelas queries Q5/Q6 do TPC-H.

## 4. Volume de dados (escala)

| Scale factor | Lineitem | Orders | Tamanho em disco (aprox.) | Uso |
|---|---|---|---|---|
| **SF=0.1 (padrão do compose)** | ~600 mil | 150 mil | ~100 MB | desenvolvimento e CI — rápido |
| SF=1 | ~6 mi | 1,5 mi | ~1 GB | recomendado para o trabalho |
| SF=10 | ~60 mi | 15 mi | ~10 GB | volume "representativo" pleno |

> A escala é controlada pelo `dbgen` (gerador oficial do TPC-H,
> repositório `electrum/tpch-dbgen`): `./dbgen -s 1 -S 42`.
> O SF=0.1 fica como padrão do compose para iteração rápida; **a
> entrega final deve usar SF=1 ou SF=10** — registrar qual foi usado.

## 5. Configuração de baseline (valores de fábrica)

Arquivo: `db/init/01-baseline.sql` (aplicado na 1ª inicialização via
`ALTER SYSTEM` → `postgresql.auto.conf`).

| Parâmetro | Baseline | Por que está no documento |
|---|---|---|
| `shared_buffers` | 128 MB | padrão de fábrica; com SF=0.1 o buffer é apertado de propósito |
| `work_mem` | 4 MB | padrão; sorts > 4 MB vão para disco (gargalo a diagnosticar) |
| `effective_cache_size` | 4 GB | padrão; influencia só as estimativas do planner |
| `maintenance_work_mem` | 64 MB | padrão; VACUUM/CREATE INDEX |
| `random_page_cost` | 4.0 | padrão calibrado p/ HDD; em SSD o ajuste é tuning legítimo |
| `max_parallel_workers_per_gather` | 2 | padrão |
| `shared_preload_libraries` | `pg_stat_statements` | **medição** (passo 2); obrigatório p/ a extensão coletar |
| `pg_stat_statements.track` | all | **medição** (passo 2), não tuning |
| `log_min_duration_statement` | 1000 (1 s) | rede de segurança para queries lentas |

## 6. Ferramentas de medição habilitadas (não são tuning)

| Ferramenta | Função no projeto |
|---|---|
| `pg_stat_statements` (extensão) | ranquear consultas por tempo total/médio — **passo 2** |
| `EXPLAIN (ANALYZE, BUFFERS)` | plano de execução com tempos reais e I/O — **passo 2** |
| `pgbench` (nativo) | carga de escrita/OLTP para medir efeito colateral — **passo 3** |
| `log_min_duration_statement` | log de queries > 1 s |

## 7. Como subir o ambiente

```bash
cd Data-Tuning-AP1
docker compose up -d            # sobe o Postgres + aplica init/
docker compose ps               # aguardar "healthy"
docker compose exec postgres psql -U tuner -d tpch -c '\dt'
```

Reiniciar do zero (apaga dados e reaplica a baseline de fábrica):

```bash
docker compose down -v && docker compose up -d
```

## 8. Carga de trabalho (resumo — detalhe no passo 1 final)

- **OLAP**: queries do conjunto TPC-H (22 queries padronizadas) contra o
  dataset gerado — `lineitem` e `orders` são as tabelas quentes.
- **OLTP** (efeito colateral de escrita): `pgbench` contra schema
  transacional, para medir o custo de INSERT/UPDATE antes × depois de
  cada ação de tuning.
