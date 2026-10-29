# =====================================================================
# clean.awk — adapta a saída do qgen (template TPC-H) ao PostgreSQL
#
# Recebe o qnum via -v qn=N. Regras:
#   * remove cabeçalhos/linhas de log do qgen ($ID$, 'arquivo', etc.)
#   * Q1:  remove o marcador "day (3)" (instrução de contagem da spec)
#   * "where rownum <= -1"  -> removida (sem limite de linhas)
#   * "where rownum <= N"   -> vira "limit N;" (e o ";" que fechava a
#     query principal na linha anterior é anexado ao limit)
#   * Q15: descarta o "create view revenue0" (a view já existe no schema
#     base, db/init/02-tpch-schema.sql) e o "drop view revenue0";
#     a query fixada é APENAS o SELECT — statement único para o benchmark
#
# Buffer: cada linha é guardada em `buf` e IMPRESSA no início da linha
# seguinte (ou no END), para permitir juntar o "limit" com o ";" da
# linha anterior.
# =====================================================================
/^[ \t]*--/            { next }   # cabeçalhos do qgen
/^[ \t]*'/             { next }   # linha 'caminho' de log
/^\$ID\$/             { next }

# Q15: descarta o "create view revenue0" (a view já existe no schema base).
# O body do create view é indentado (tab); só o "select" principal
# (sem indentação) encerra o descarte.
qn == 15 && /^create view revenue0/ { skip15 = 1 }
skip15 {
    if ($0 ~ /^select$/) skip15 = 0
    else next
}
# Q15: descarta o "drop view revenue0;" (a view permanece no schema base)
qn == 15 && /drop view revenue0/    { next }

{
    sub(/[ \t]+day \(3\)$/, " day")                    # marcador Q1
    if ($0 ~ /rownum <= -1/) next                     # sem limite
    if ($0 ~ /where rownum <= [0-9]+/) {
        n = $0
        sub(/.*rownum <= /, "", n)
        sub(/;.*$/, ";", n)
        if (buf ~ /;$/) sub(/;$/, "", buf)            # anexa ao limit
        if (buf != "") print buf
        print "limit " n
        buf = ""
        next
    }
    if (buf != "") print buf                          # flush da linha anterior
    buf = $0
}
END { if (buf != "") print buf }
