-- =====================================================================
-- 02-tpch-schema.sql
-- Modelo de dados TPC-H (benchmark OLAP clássico) — 8 tabelas.
--
-- DECISÃO DE PROJETO (registrada para o passo 1):
--   - Somente PRIMARY KEYs são criadas (constraint de integridade).
--   - NÃO há índices secundários: o plano de execução das queries
--     analíticas ficará "pior de propósito" (seq scans + sorts em disco),
--     criando as oportunidades de tuning dos passos 2 e 3.
--   - FKs não são declaradas para acelerar o load (o dbgen garante a
--     consistência referencial); as relações são documentadas abaixo.
--
-- Cardinalidades por scale factor (SF):
--   region   5*SF      nation   25*SF
--   part     200k*SF   supplier 10k*SF
--   customer 150k*SF   partsupp 800k*SF
--   orders   1.5M*SF   lineitem ~6M*SF
--
-- Relações:
--   region 1--N nation 1--N customer
--   region 1--N nation 1--N supplier
--   supplier 1--N partsupp N--1 part
--   customer 1--N orders 1--N lineitem N--1 part
-- =====================================================================

CREATE TABLE region (
    r_regionkey   INT NOT NULL,
    r_name        VARCHAR(25) NOT NULL,
    r_comment     VARCHAR(152),
    CONSTRAINT region_pkey PRIMARY KEY (r_regionkey)
);

CREATE TABLE nation (
    n_nationkey   INT NOT NULL,
    n_name        VARCHAR(25) NOT NULL,
    n_regionkey   INT NOT NULL,
    n_comment     VARCHAR(152),
    CONSTRAINT nation_pkey PRIMARY KEY (n_nationkey)
);

CREATE TABLE part (
    p_partkey     INT NOT NULL,
    p_name        VARCHAR(250) NOT NULL,
    p_mfgr        VARCHAR(25) NOT NULL,
    p_brand       VARCHAR(10) NOT NULL,
    p_type        VARCHAR(250) NOT NULL,
    p_size        INT NOT NULL,
    p_container   VARCHAR(10) NOT NULL,
    p_unitprice   NUMERIC(10,2) NOT NULL,
    p_comment     VARCHAR(23),
    CONSTRAINT part_pkey PRIMARY KEY (p_partkey)
);

CREATE TABLE supplier (
    s_suppkey     INT NOT NULL,
    s_name        VARCHAR(25) NOT NULL,
    s_address     VARCHAR(100) NOT NULL,
    s_nationkey   INT NOT NULL,
    s_phone       VARCHAR(15) NOT NULL,
    s_acctbal     NUMERIC(10,2) NOT NULL,
    s_comment     VARCHAR(104),
    CONSTRAINT supplier_pkey PRIMARY KEY (s_suppkey)
);

CREATE TABLE partsupp (
    ps_partkey    INT NOT NULL,
    ps_suppkey    INT NOT NULL,
    ps_availqty   INT NOT NULL,
    ps_supplycost NUMERIC(10,2) NOT NULL,
    ps_comment    VARCHAR(115),
    CONSTRAINT partsupp_pkey PRIMARY KEY (ps_partkey, ps_suppkey)
);

CREATE TABLE customer (
    c_custkey     INT NOT NULL,
    c_name        VARCHAR(25) NOT NULL,
    c_address     VARCHAR(40) NOT NULL,
    c_nationkey   INT NOT NULL,
    c_phone       VARCHAR(15) NOT NULL,
    c_acctbal     NUMERIC(10,2) NOT NULL,
    c_mktsegment  VARCHAR(10) NOT NULL,
    c_comment     VARCHAR(117),
    CONSTRAINT customer_pkey PRIMARY KEY (c_custkey)
);

CREATE TABLE orders (
    o_orderkey      INT NOT NULL,
    o_custkey       INT NOT NULL,
    o_orderstatus   CHAR(1) NOT NULL,
    o_totalprice    NUMERIC(10,2) NOT NULL,
    o_orderdate     DATE NOT NULL,
    o_orderpriority VARCHAR(40) NOT NULL,
    o_clerk         VARCHAR(15) NOT NULL,
    o_shippriority  INT NOT NULL,
    o_comment       VARCHAR(79) NOT NULL,
    CONSTRAINT orders_pkey PRIMARY KEY (o_orderkey)
);

CREATE TABLE lineitem (
    l_orderkey    INT NOT NULL,
    l_partkey     INT NOT NULL,
    l_suppkey     INT NOT NULL,
    l_linenumber  INT NOT NULL,
    l_quantity    NUMERIC(10,2) NOT NULL,
    l_extendedprice NUMERIC(10,2) NOT NULL,
    l_discount    NUMERIC(10,2) NOT NULL,
    l_tax         NUMERIC(10,2) NOT NULL,
    l_shipdate    DATE NOT NULL,
    l_shipinstruct VARCHAR(25) NOT NULL,
    l_shipmode    VARCHAR(10) NOT NULL,
    l_comment     VARCHAR(44) NOT NULL,
    CONSTRAINT lineitem_pkey PRIMARY KEY (l_orderkey, l_linenumber)
);

-- =====================================================================
-- VIEW de conveniência (usada por queries do TPC-H)
-- =====================================================================
CREATE VIEW revenue0 AS
SELECT l_suppkey AS supplierno,
       sum(l_extendedprice * (1 - l_discount)) AS totalrevenue
FROM lineitem
WHERE l_shipdate >= date '1996-01-01'
  AND l_shipdate < date '1996-01-01' + interval '3' month
GROUP BY l_suppkey;
