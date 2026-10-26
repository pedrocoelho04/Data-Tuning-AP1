-- =====================================================================
-- 00-extensions.sql
-- Extensões necessárias para MEDIÇÃO (não são ações de tuning).
-- pg_stat_statements: agrega tempo total/médio por query -> usado no
-- passo 2 para ranquear as consultas mais custosas.
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
