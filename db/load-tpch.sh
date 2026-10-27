#!/bin/sh
# =====================================================================
# load-tpch.sh — carrega o dataset TPC-H (gerado pelo dbgen) no Postgres
#
# Os .tbl do dbgen (build ORACLE) usam delimiter "|", NÃO têm header
# (a 1ª linha já é dados) e emitem UM "|" extra no final de cada linha.
# Por isso o sed remove o delimitador de fim antes do \copy.
# Ordem importa: region -> nation -> part -> supplier -> partsupp ->
# customer -> orders -> lineitem.
#
# Uso (a partir da raiz do projeto, container postgres deve estar up):
#   sh db/load-tpch.sh
#
# Para recarregar do zero:
#   docker compose exec postgres psql -U tuner -d tpch \
#     -c "TRUNCATE lineitem, orders, customer, partsupp, supplier, part, nation, region CASCADE;" \
#   sh db/load-tpch.sh
# =====================================================================
set -e

DBGEN_DIR="${DBGEN_DIR:-/dbgen}"  # volume dbgen montado no container postgres

# roda o psql dentro do container postgres do compose
psql() { docker compose exec -T postgres psql -U tuner -d tpch "$@"; }

echo ">> Limpando tabelas existentes (idempotente)..."
psql -c "TRUNCATE lineitem, orders, customer, partsupp, supplier, part, nation, region CASCADE;"

echo ">> Importando (ordem: region -> nation -> part -> supplier -> partsupp -> customer -> orders -> lineitem)..."

importar() {
  tabela="$1"
  echo "   - $tabela"
  # Remove o "|" extra no final de cada linha (build ORACLE do dbgen)
  docker compose exec -T postgres sh -c "sed 's/|$//' $DBGEN_DIR/$tabela.tbl" | \
    psql -q -c "\copy $tabela from stdin with (format text, delimiter '|')"
}

importar region
importar nation
importar part
importar supplier
importar partsupp
importar customer
importar orders
importar lineitem

echo ">> Estatísticas do planner (ANALYZE) e contagem final:"
psql -c "ANALYZE;"
psql -c "SELECT 'region' t, count(*) FROM region
        UNION ALL SELECT 'nation', count(*) FROM nation
        UNION ALL SELECT 'part', count(*) FROM part
        UNION ALL SELECT 'supplier', count(*) FROM supplier
        UNION ALL SELECT 'partsupp', count(*) FROM partsupp
        UNION ALL SELECT 'customer', count(*) FROM customer
        UNION ALL SELECT 'orders', count(*) FROM orders
        UNION ALL SELECT 'lineitem', count(*) FROM lineitem;"
psql -c "SELECT pg_size_pretty(pg_database_size('tpch')) AS tamanho_banco;"
