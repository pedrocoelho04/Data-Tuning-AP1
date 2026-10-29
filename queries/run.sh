#!/bin/sh
# =====================================================================
# run.sh — executor das queries TPC-H fixadas (queries/fixed/)
#
# Uso (a partir da raiz do projeto, container postgres deve estar up):
#   sh queries/run.sh 6          # roda a Q6 (resultado)
#   sh queries/run.sh 6 -e      # roda a Q6 com EXPLAIN (ANALYZE, BUFFERS)
#   sh queries/run.sh all       # roda as 22 (resultado)
#   sh queries/run.sh all -e    # roda as 22 com EXPLAIN -> queries/plans/
#
# As queries usam os parâmetros OFICIAIS do TPC-H já substituídos
# (geradas pelo qgen com -d, SF de referência 0.1).
# =====================================================================
set -e
cd "$(dirname "$0")/.."

Q="$1"
MODE="r"                       # r = resultado | e = explain analyze
[ "$2" = "-e" ] && MODE="e"

[ -z "$Q" ] && { echo "Uso: sh queries/run.sh <N|all> [-e]"; exit 1; }

psql() { docker compose exec -T postgres psql -U tuner -d tpch "$@"; }

if [ "$Q" = "all" ]; then LIST=$(seq 1 22); else LIST="$Q"; fi

for i in $LIST; do
  f="queries/fixed/$i.sql"
  [ -f "$f" ] || { echo "  [aviso] $f não existe, pulando"; continue; }
  if [ "$MODE" = "e" ]; then
    echo "=== Q$i — EXPLAIN (ANALYZE, BUFFERS) ==="
    mkdir -p queries/plans
    psql -q -c "EXPLAIN (ANALYZE, BUFFERS) $(cat "$f")" | tee "queries/plans/$i.plan"
  else
    echo "=== Q$i ==="
    psql -c "$(cat "$f")"
  fi
done
