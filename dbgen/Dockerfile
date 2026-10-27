# =====================================================================
# Gerador TPC-H (dbgen) em container — funciona em Linux e Windows.
# Compila o dbgen oficial (electrum/tpch-dbgen) e devolve binários +
# dists.dss + as 22 queries oficiais num volume compartilhado, sem
# exigir compilador no host.
#
# Build (uma vez, a imagem fica cacheada):
#   docker build -t data-tuning-dbgen dbgen/
#
# Gerar dataset SF=0.1 no volume (a partir da raiz do projeto):
#   docker run --rm -v data-tuning-ap1_dbgen:/work data-tuning-dbgen \
#     sh -c "cp -r /opt/tpch/. /work/ && cd /work && chmod +x dbgen qgen && ./dbgen -s 0.1 -S 42 -D /work"
#
# Ver arquivos gerados:
#   docker run --rm -v data-tuning-ap1_dbgen:/work alpine ls -lh /work
# =====================================================================
FROM alpine:3.20

RUN apk add --no-cache git make gcc musl-dev

# Clona e compila o gerador oficial do TPC-H (MACHINE=LINUX p/ config.h)
RUN git clone --depth 1 https://github.com/electrum/tpch-dbgen.git /src \
    && cd /src \
    && make MACHINE=LINUX \
    && mkdir -p /opt/tpch/queries \
    && cp dbgen qgen dists.dss /opt/tpch/ \
    && cp queries/*.sql /opt/tpch/queries/

# O volume /work pode já existir (mascara a camada da imagem), então os
# arquivos-fonte ficam em /opt/tpch e o runtime os copia para /work.
WORKDIR /work
ENTRYPOINT ["sh", "-c"]
CMD ["cp -r /opt/tpch/. /work/ && chmod +x /work/dbgen /work/qgen && ls -lh /work"]
