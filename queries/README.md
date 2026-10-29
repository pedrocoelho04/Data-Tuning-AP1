# Queries TPC-H do projeto

## Estrutura

| Caminho | Conteúdo |
|---|---|
| `queries/*.sql` (1…22) | **templates originais** do TPC-H (com variáveis `:1`, `:2`… e `where rownum`) — referência |
| `queries/fixed/*.sql` | **queries fixadas com parâmetros oficiais** (qgen `-d`), adaptadas ao PostgreSQL — **é estas que o benchmark usa** |
| `queries/clean.awk` | conversão template → Postgres (usada pelo `generate.sh`) |
| `queries/generate.sh` | regenera `fixed/` para qualquer SF: `sh queries/generate.sh 0.1` |
| `queries/run.sh` | executor: `sh queries/run.sh 6` (resultado) / `sh queries/run.sh 6 -e` (EXPLAIN ANALYZE) / `all` |
| `queries/plans/` | planos de execução salvos (`run.sh all -e`) |
| `queries/baseline-SF01.md` | linha de base de tempos (SF=0.1, baseline de fábrica) |

## Parâmetros oficiais (T = 7.000.000 dias; D = 0.10; Q = 24)

- `:1` = `DATE '1996-01-01'` · `:2` = `0.10` · `:3` = `24`
- `:4` = `DATE '1995-01-01'` · `:5` = `DATE '1995-10-01'`
- `:6` = `0.06` · `:7` = `24`

## Adaptações aplicadas (decisões registradas)

1. **`where rownum <= N` → `limit N`** — Postgres não tem `rownum`.
   Afeta Q2 (100), Q3 (10), Q10 (20), Q18 (100), Q21 (100).
   `rownum <= -1` (sem limite) é removido.
2. **Q1: marcador `day (3)` removido** — na spec o `(3)` indica o número
   de linhas esperadas no resultado, não é SQL.
3. **Q15: statement único `SELECT`** — o template original faz
   `create view revenue0` + `select` + `drop view`. Para o benchmark
   rodar com `EXPLAIN (ANALYZE, BUFFERS)` (1 statement), a view
   `revenue0` foi criada **no schema base** (`db/init/02-tpch-schema.sql`,
   colunas `supplier_no`/`total_revenue` conforme o template) e a Q15
   fixada é apenas o `SELECT`.
4. **Cabeçalhos do qgen removidos** (`$ID$`, `'arquivo'`, `-- using
   default substitutions`).

## Como (re)gerar

```bash
# imagem do dbgen precisa estar buildada (docker build -t data-tuning-dbgen dbgen/)
sh queries/generate.sh 0.1     # SF=0.1 (padrão)
sh queries/generate.sh 1       # SF=1 (entrega)
```

> Trocar o SF das queries **não exige** trocar os parâmetros de data —
> o qgen `-d` aplica os padrões oficiais independentemente do SF.

## Como medir (passo 1 — linha de base / passo 3 — ganho)

```bash
sh queries/run.sh all -e      # as 22 com EXPLAIN (ANALYZE, BUFFERS) -> plans/
sh queries/run.sh 17 -e       # uma específica
```

Extrair os tempos de execução de um log:

```bash
awk '/^=== Q[0-9]+ —/{q=$2} /^ *Execution Time:/{print q" | "$3" "$4}' /tmp/all22.log
```
