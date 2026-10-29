#!/bin/sh
# =====================================================================
# generate.sh — regenera as queries fixadas (queries/fixed/) com os
# parâmetros OFICIAIS do TPC-H (qgen -d), adaptadas ao PostgreSQL
# (conversão em queries/clean.awk).
#
# Uso (a partir da raiz do projeto, imagem data-tuning-dbgen buildada):
#   sh queries/generate.sh [SF]        # SF padrão: 0.1
# =====================================================================
set -e
cd "$(dirname "$0")/.."
SF="${1:-0.1}"
mkdir -p queries/fixed

# Monta queries/ (contém clean.awk) em /hostq e a saída em /out.
# SF é passado como variável de ambiente para o container.
docker run --rm \
  -e SF="$SF" \
  -v data-tuning-ap1_dbgen:/work \
  -v "$(pwd)/queries:/hostq:ro" \
  -v "$(pwd)/queries/fixed:/out" \
  alpine sh -c '
    cd /work/queries
    for i in $(seq 1 22); do
      ../qgen -s "$SF" -d -o /work "$i" 2>/dev/null \
        | awk -v qn="$i" -f /hostq/clean.awk > /out/"$i".sql
    done
    echo "Geradas: $(ls /out/*.sql | wc -l)"
  '
