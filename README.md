# Data-Tuning-AP1
Estudo independente orientado pelas Unidades de Aprendizagem, resolução de estudos de caso, atendimento do professor nos fóruns e nos encontros síncronos e desenvolvimento do projeto final. Ao fim, os alunos deverão entregar um projeto de tunning aplicado a um banco de dados com volume representativo de dados, comprovando os ganhos obtidos.

## Estrutura

| Caminho | Conteúdo |
|---|---|
| `docker-compose.yml` | Ambiente: PostgreSQL 16 (porta 5433), volume durável, healthcheck |
| `db/init/00-extensions.sql` | Extensões de medição: `pg_stat_statements` |
| `db/init/01-baseline.sql` | Configuração de fábrica documentada (baseline do passo 1) |
| `db/init/02-tpch-schema.sql` | DDL do modelo TPC-H (8 tabelas, somente PKs) |
| `docs/ESPECIFICACOES-SGBD.md` | Especificações do SGBD, modelo, volume e baseline |

## Como subir

```bash
docker compose up -d
docker compose exec postgres psql -U tuner -d tpch -c '\dt'
```

Reiniciar do zero (apaga dados e reaplica a baseline):

```bash
docker compose down -v && docker compose up -d
```

> Scripts de `db/init` rodam apenas na 1ª inicialização (volume vazio).
> Para carregar o dataset TPC-H, use o `dbgen` (SF=0.1, 1 ou 10) —
> ver `docs/ESPECIFICACOES-SGBD.md` §4. 
