# Especificações do SGBD — Passo 1 (Caracterização do ambiente)

> Documento de referência do projeto de Data Tuning (AP1).
> **Qualquer mudança neste documento a partir daqui é uma 
> ação de tuning** e deve ser registrada com baseline → novo
> valor + justificativa (passo 3).

## 1. SGBD

| Item | Especificação |
|---|---|
| Produto | PostgreSQL |
| Versão | 16 |
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

## 2. Recurso computacional (Host)

| Recurso | Alocação |
|---|---|
| CPU | AMD Ryzen 7 5825U, 8 nucleos, 16 Threads |
| Memória | 16 Gb DDR4 |
| Armazenamento | NVMe M.2 PCIe 4.0 |
| SO | Fedora 44 |

## 3. Modelo de dados

**TPC-H** (benchmark analítico/OLAP clássico do Transaction Processing
Performance Council) — 8 tabelas + 1 view:

| Tabela | Registros (SF=0.1) | Registros (SF=1) | PK | Papel no benchmark |
|---|---|---|---|---|
| `region` | 5 | 5 | `r_regionkey` | regiões do mundo |
| `nation` | 25 | 25 | `n_nationkey` | nações (FK→region) |
| `part` | 20.000 | 200.000 | `p_partkey` | catálogo de peças |
| `supplier` | 1.000 | 10.000 | `s_suppkey` | fornecedores (FK→nation) |
| `partsupp` | 80.000 | 800.000 | `(ps_partkey, ps_suppkey)` | estoque por fornecedor |
| `customer` | 15.000 | 150.000 | `c_custkey` | clientes (FK→nation) |
| `orders` | 150.000 | 1.500.000 | `o_orderkey` | pedidos (FK→customer) |
| `lineitem` | ~600.000 | ~6.000.000 | `(l_orderkey, l_linenumber)` | itens dos pedidos (tabela quente) |
| **Total** | **~866.600** | **~8.340.000** | | |

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
| **SF=0.1 (padrão do compose e da entrega)** | ~600 mil | 150 mil | ~100 MB | **escala usada no projeto** |
| SF=1 | ~6 mi | 1,5 mi | ~1 GB | opcional (ver nota) |
| SF=10 | ~60 mi | 15 mi | ~10 GB | volume "representativo" pleno |

> A escala é controlada pelo `dbgen` (gerador oficial do TPC-H,
> repositório `electrum/tpch-dbgen`), compilado em container:
> `./dbgen -s 0.1 -f` (SF=0.1), `./dbgen -s 1 -f` (SF=1), etc.
> O `-f` sobrescreve `.tbl` já existentes.
>
> **Decisão de escala do projeto (SF=0.1)**: a entrega usa SF=0.1. O
> SF=1 foi gerado e carregado durante o desenvolvimento, mas a medição
> baseline ficou inviável — a Q17 sem índice levou **>1 h** (e a Q20,
> similar), por causa da super-linearidade das subqueries correlacionadas.
> O ganho relativo comprovado em SF=0.1 (−97%) é o valor de referência;
> em SF maior o ganho absoluto tende a ser ainda maior. Detalhes em
> `docs/PROCESSO-E-DIAGNOSTICO.md` (D.3.5 e D.5.3).

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
| `pg_stat_statements.track` | all | **medição** (Foi comentado essa parte por já estar ativo de forma default nessa versão) |
| `log_min_duration_statement` | 1000 (1 s) | rede de segurança para queries lentas |

## 6. Ferramentas de medição habilitadas

| Ferramenta | Função no projeto |
|---|---|
| `pg_stat_statements` (extensão) | ranquear consultas por tempo total/médio — **passo 2** |
| `EXPLAIN (ANALYZE, BUFFERS)` | plano de execução com tempos reais e I/O — **passo 2** |
| `pgbench` (nativo) | carga de escrita/OLTP para medir efeito colateral — **passo 3** |
| `log_min_duration_statement` | log de queries > 1 s |

## 7. Como subir o ambiente e gerar os dados

> Testado em Linux; no Windows (Docker Desktop + WSL2) os comandos são
> idênticos, pois tudo roda em container.

```bash
cd Data-Tuning-AP1

# 1. Sobe o Postgres (na 1ª subida aplica extensões, baseline e schema)
docker compose up -d
docker compose ps               # aguardar "healthy"

# 2. (uma vez) builda a imagem do gerador TPC-H (compila o dbgen)
docker build -t data-tuning-dbgen dbgen/

# 3. Gera o dataset no volume compartilhado (SF=0.1 p/ dev; 1 ou 10 p/ entrega)
docker run --rm -v data-tuning-ap1_dbgen:/work data-tuning-dbgen \
  "cp -r /opt/tpch/. /work/ && cd /work && chmod +x dbgen qgen && ./dbgen -s 0.1 -f"

# 4. Carrega no Postgres (idempotente: limpa e reimporta as 8 tabelas)
sh db/load-tpch.sh

# 5. Verifica contagens e tamanho
docker compose exec postgres psql -U tuner -d tpch \
  -c "SELECT 'lineitem' t, count(*) FROM lineitem
      UNION ALL SELECT 'orders', count(*) FROM orders
      UNION ALL SELECT 'partsupp', count(*) FROM partsupp;"
```

Reiniciar do zero (apaga dados e reaplica baseline + schema):

```bash
docker compose down -v && docker compose up -d
```

Notas:
- Scripts de `db/init` rodam **apenas** na 1ª inicialização (volume vazio).
- `-f` no `dbgen` sobrescreve `.tbl` já existentes; troque `0.1` por `1`
  ou `10` para o volume de entrega (regerar + `sh db/load-tpch.sh`).
- As 22 queries oficiais ficam no volume em `/work/queries/` (Q1…Q22) —
  são a carga de trabalho dos passos 2 e 3.
- O load usa `sed 's/|$//'` para remover o `|` extra no fim de cada linha
  (particularidade do build ORACLE do dbgen) antes do `\copy`.


## 8. Carga de trabalho (resumo — detalhe no passo 1 final)

- **OLAP**: as 22 queries do conjunto TPC-H contra o dataset gerado —
  `lineitem` e `orders` são as tabelas quentes.
  - **Fixadas para o benchmark**: `queries/fixed/*.sql` (parâmetros
    oficiais via `qgen -d`, adaptadas ao Postgres) — ver
    `queries/README.md` e `queries/baseline-SF01.md`.
  - Gerar: `sh queries/generate.sh <SF>` · Medir: `sh queries/run.sh all -e`
- **OLTP** (efeito colateral de escrita): `pgbench` contra schema
  transacional, para medir o custo de INSERT/UPDATE antes × depois de
  cada ação de tuning.
