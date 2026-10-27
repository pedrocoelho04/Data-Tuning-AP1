# Data-Tuning-AP1
Estudo independente orientado pelas Unidades de Aprendizagem, resolução de estudos de caso, atendimento do professor nos fóruns e nos encontros síncronos e desenvolvimento do projeto final. Ao fim, os alunos deverão entregar um projeto de tunning aplicado a um banco de dados com volume representativo de dados, comprovando os ganhos obtidos.

## Estrutura

| Caminho | Conteúdo |
|---|---|
| `docker-compose.yml` | Ambiente: PostgreSQL 16 (porta 5433), volume durável, healthcheck, volume `dbgen` |
| `db/init/00-extensions.sql` | Extensões de medição: `pg_stat_statements` |
| `db/init/01-baseline.sql` | Configuração de fábrica documentada (baseline do passo 1) |
| `db/init/02-tpch-schema.sql` | DDL do modelo TPC-H (8 tabelas, somente PKs, comentários em TEXT) |
| `db/load-tpch.sh` | Script de load do dataset TPC-H no Postgres (idempotente) |
| `dbgen/Dockerfile` | Imagem que compila o `dbgen` oficial — sem precisar de compilador no host |
| `docs/ESPECIFICACOES-SGBD.md` | Especificações do SGBD, modelo, volume e baseline |

## Fluxo completo (testado em Linux; funciona igual no Windows com Docker Desktop)

```bash
# 1. Sobe o Postgres (na 1ª subida aplica extensões, baseline e schema)
docker compose up -d

# 2. (uma vez) builda a imagem do gerador TPC-H
docker build -t data-tuning-dbgen dbgen/

# 3. Gera o dataset (SF=0.1 p/ dev; SF=1 ou 10 p/ entrega)
docker run --rm -v data-tuning-ap1_dbgen:/work data-tuning-dbgen \
  "cp -r /opt/tpch/. /work/ && cd /work && chmod +x dbgen qgen && ./dbgen -s 0.1 -f"

# 4. Carrega no Postgres (idempotente: limpa e reimporta)
sh db/load-tpch.sh

# 5. Verifica
docker compose exec postgres psql -U tuner -d tpch \
  -c "SELECT 'lineitem' t, count(*) FROM lineitem UNION ALL SELECT 'orders', count(*) FROM orders;"
```

Reiniciar do zero (apaga dados e reaplica baseline + schema):

```bash
docker compose down -v && docker compose up -d
```

> Scripts de `db/init` rodam apenas na 1ª inicialização (volume vazio).
> O `-f` no `dbgen` sobrescreve `.tbl` já existentes; `-s` define o scale
> factor (0.1 / 1 / 10). As 22 queries oficiais ficam em
> `data-tuning-ap1_dbgen:/work/queries/` para uso nos passos 2 e 3. 
