-- =====================================================================
-- 01-baseline.sql
-- Configuração de FÁBRICA (baseline) — valores padrão do PostgreSQL 16.
--
-- Este arquivo NÃO é tuning: ele apenas torna explícita a linha de base
-- do passo 1, para que qualquer alteração futura (passo 3) seja uma
-- mudança documentada em cima destes valores.
--
-- IMPORTANTE: a imagem oficial do PostgreSQL NÃO lê arquivos .conf em
-- /docker-entrypoint-initdb.d (apenas .sql e .sh). Por isso a baseline
-- é aplicada com ALTER SYSTEM, que grava em postgresql.auto.conf e é
-- lida na partida final do servidor (sobrepõe o postgresql.conf).
--
-- Regra do projeto: cada parâmetro ajustado depois deve ser registrado
-- em docs/ESPECIFICACOES-SGBD.md com valor baseline -> valor novo.
-- =====================================================================

-- --- Memória -----------------------------------------------------------
-- shared_buffers: 128MB é o padrão de fábrica. Com ~100MB de dataset TPC-H
-- SF=0.1, o buffer fica apertado de propósito: parte da leitura vai ao
-- disco, o que dá margem para o tuning (ex.: 25% da RAM do container).
ALTER SYSTEM SET shared_buffers = '128MB';

-- work_mem: 4MB é o padrão. Sorts/aggregations maiores que 4MB vão para
-- disco (external merge) — gargalo clássico a ser diagnosticado no passo 2.
ALTER SYSTEM SET work_mem = '4MB';

-- effective_cache_size: 4GB é o padrão. Afeta só o planner (estimativas).
ALTER SYSTEM SET effective_cache_size = '4GB';

-- maintenance_work_mem: 64MB é o padrão (VACUUM, CREATE INDEX).
ALTER SYSTEM SET maintenance_work_mem = '64MB';

-- --- Planner / I/O -----------------------------------------------------
-- random_page_cost = 4.0 (padrão, calibrado para HDD). Em SSD o valor
-- real é ~1.1-1.5; ajustar é uma ação de tuning legítima (passo 3).
ALTER SYSTEM SET random_page_cost = 4.0;

-- --- Paralelismo -------------------------------------------------------
ALTER SYSTEM SET max_parallel_workers_per_gather = 2;
ALTER SYSTEM SET max_worker_processes = 8;

-- --- Monitoramento (medição, não tuning) -------------------------------
-- shared_preload_libraries é obrigatório para o pg_stat_statements
-- efetivamente coletar dados (parâmetro de postmaster: só vale na
-- partida). Sem ele a view existe, mas fica sempre vazia.
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';
-- Coleta de estatísticas por statement para o diagnóstico do passo 2.
ALTER SYSTEM SET pg_stat_statements.track = 'all';
ALTER SYSTEM SET pg_stat_statements.max = 10000;

-- --- Logs --------------------------------------------------------------
-- Log de queries lentas (acima de 1s) como rede de segurança do diagnóstico.
-- O padrão de fábrica é -1 (desligado); aqui fica explícito na baseline.
ALTER SYSTEM SET log_min_duration_statement = 1000;
