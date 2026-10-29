# Linha de base de desempenho — TPC-H SF=0.1 (PostgreSQL 16, baseline de fábrica)

> **Condições de medição** (passo 1 do projeto):
> - SGBD: PostgreSQL 16 (`postgres:16-alpine`), configurações de fábrica
>   (`db/init/01-baseline.sql`: `shared_buffers=128MB`, `work_mem=4MB`,
>   `random_page_cost=4.0`, `max_parallel_workers_per_gather=2`)
> - Dataset: TPC-H SF=0.1 (~866 mil registros; `lineitem` 600.572, ~105 MB)
> - Queries: `queries/fixed/*.sql` (parâmetros oficiais, qgen `-d`)
> - Método: `EXPLAIN (ANALYZE, BUFFERS)` por query, 2 execuções
>   (rodada 1 = cache frio/parte; rodada 2 = estabilizada)
> - Hardware do host: **COMPLETAR** (CPU, RAM, disco, SO)
> - Data da medição: 2025-02-11

## Tempos de execução (ms)

| Query | Rodada 1 (ms) | Rodada 2 (ms) | Δ | Observação |
|---|---|---|---|---|
| Q1  | 461.7 | 460.1 | -0.4% | seq scan lineitem + group agg |
| Q2  | 68.8  | 82.8  | +20.3% | subquery min(ps_supplycost) |
| Q3  | 126.7 | 134.0 | +5.8%  | seq scan orders/lineitem |
| Q4  | 241.8 | 247.3 | +2.3%  | join + avg |
| Q5  | 78.6  | 79.6  | +1.3%  | join em cadeia (7 tabelas) |
| Q6  | 74.1  | 75.7  | +2.2%  | seq scan lineitem (filtro) |
| Q7  | 114.0 | 113.0 | -0.9%  | join nacional |
| Q8  | 102.4 | 102.8 | +0.4%  | join em cadeia (8 tabelas) |
| Q9  | 265.3 | 267.5 | +0.8%  | subquery price no join |
| Q10 | 145.9 | 151.8 | +4.0%  | union all (customer/supplier) |
| Q11 | 83.1  | 84.7  | +1.9%  | partsupp + subquery |
| Q12 | 160.4 | 162.4 | +1.2%  | shipping + sum |
| Q13 | 219.6 | 220.8 | +0.5%  | group by + count |
| Q14 | 86.5  | 87.4  | +1.0%  | percentual |
| Q15 | 146.1 | 146.9 | +0.5%  | view revenue0 |
| Q16 | 106.5 | 106.0 | -0.4%  | like + not in |
| Q17 | 27445.2 | 27519.6 | +0.3% | **subquery não-correlacionada pesada** |
| Q18 | 490.9 | 486.0 | -1.0%  | max join |
| Q19 | 75.6  | 77.0  | +1.9%  | or em update-equivalent |
| Q20 | 45141.6 | 45849.2 | +1.6% | **subquery correlacionada (pior query)** |
| Q21 | 95.8  | 96.6  | +0.8%  | 2x subquery count |
| Q22 | 54.3  | 53.4  | -1.7%  | count + ratio |
| **Total** | **~75.7 s** | **~76.4 s** | — | soma das 22 |

## Leitura da baseline

- **Q17 e Q20 concentram ~97% do tempo total** (27,5 s + 45,8 s de ~76 s).
  São o alvo prioritário do passo 2/3 (subquery com `avg` sobre lineitem /
  correlacionada com `customer`).
- Q1, Q4, Q9, Q13, Q18 (100–500 ms) formam o segundo grupo de interesse.
- As demais (50–160 ms) servem de controle: qualquer ação de tuning global
  (ex.: `work_mem`) deve mantê-las estáveis ou melhorá-las.
- Reprodutibilidade entre rodadas: Δ ≤ 20% (Q2), demais < 5% — variância
  aceitável; para a entrega final, rodar 5× e usar a mediana.

## Como reproduzir

```bash
sh queries/run.sh all -e          # gera queries/plans/N.plan
awk '/^=== Q[0-9]+ —/{q=$2} /^ *Execution Time:/{print q" | "$3" "$4}' /tmp/all22.log
```
